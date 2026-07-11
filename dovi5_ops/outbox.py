"""SQLite outbox and durable Servarr recovery state machine."""

from __future__ import annotations

import hashlib
import os
import sqlite3
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Any, Mapping, Optional
from urllib.parse import urlencode

from .config import (
    Config,
    MappingConfig,
    OutboxError,
    ServarrAPIError,
    _canonical,
    _path_within,
)
from .servarr import APIClient, best_path_match, season_number_from_path
from .schema import SCHEMA_VERSION as SCHEMA_VERSION
from .schema import initialize_schema


ACTIVE_PHASES = (
    "queued",
    "resolved",
    "rescan_waiting",
    "search_ready",
    "search_waiting",
)
DEFAULT_DB = "/var/lib/dovi5-frigate-ops/servarr-outbox.sqlite3"


@dataclass(frozen=True)
class Fingerprint:
    device: int
    inode: int
    size: int
    mtime_ns: int
    ctime_ns: int

    @classmethod
    def from_path(cls, path: os.PathLike[str] | str) -> Fingerprint:
        stat_result = os.stat(path)
        return cls(
            stat_result.st_dev,
            stat_result.st_ino,
            stat_result.st_size,
            stat_result.st_mtime_ns,
            stat_result.st_ctime_ns,
        )

    @classmethod
    def parse(cls, encoded: str) -> Fingerprint:
        parts = encoded.split(":")
        if len(parts) != 5:
            raise OutboxError("fingerprint must contain five integer fields")
        try:
            values = [int(part) for part in parts]
        except ValueError as exc:
            raise OutboxError("fingerprint contains a non-integer field") from exc
        if any(value < 0 for value in values):
            raise OutboxError("fingerprint fields cannot be negative")
        return cls(*values)

    def encode(self) -> str:
        return ":".join(
            str(value)
            for value in (
                self.device,
                self.inode,
                self.size,
                self.mtime_ns,
                self.ctime_ns,
            )
        )


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def _job_key(label: str, canonical_path: str, fingerprint: str) -> str:
    digest = hashlib.sha256()
    for value in (label, canonical_path, fingerprint):
        digest.update(value.encode("utf-8", errors="surrogateescape"))
        digest.update(b"\0")
    return digest.hexdigest()


class Outbox:
    def __init__(
        self,
        database: os.PathLike[str] | str,
        config: Optional[Config] = None,
        *,
        dry_run: bool = False,
    ):
        self.database = _canonical(database)
        self.config = config
        self.dry_run = dry_run
        if config is not None:
            for mapping in config.mappings.values():
                if _path_within(self.database, mapping.root):
                    raise OutboxError("outbox database must not be inside a media root")
        parent = os.path.dirname(self.database)
        try:
            os.makedirs(parent, mode=0o700, exist_ok=True)
        except OSError as exc:
            raise OutboxError(f"cannot create outbox directory: {exc}") from exc
        try:
            self.connection = sqlite3.connect(self.database, timeout=30)
            self.connection.row_factory = sqlite3.Row
            self.connection.execute("PRAGMA journal_mode=DELETE")
            self.connection.execute("PRAGMA synchronous=FULL")
            self.connection.execute("PRAGMA foreign_keys=ON")
            initialize_schema(self.connection)
        except (OSError, sqlite3.DatabaseError, OutboxError) as exc:
            connection = getattr(self, "connection", None)
            if connection is not None:
                connection.close()
            if isinstance(exc, OutboxError):
                raise
            raise OutboxError(f"cannot open a valid outbox database: {exc}") from exc

    def __enter__(self) -> Outbox:
        return self

    def __exit__(self, _exc_type, _exc, _traceback) -> None:
        self.close()

    def close(self) -> None:
        self.connection.close()

    def _require_config(self) -> Config:
        if self.config is None:
            raise OutboxError("this operation requires Servarr configuration")
        return self.config

    def enqueue(
        self,
        label: str,
        source_path: os.PathLike[str] | str,
        fingerprint: Fingerprint | str,
    ) -> int:
        config = self._require_config()
        mapping = config.mapping(label)
        canonical_path = _canonical(source_path)
        if not _path_within(canonical_path, mapping.root, allow_equal=False):
            raise OutboxError(f"source path is outside the configured {label} root")
        if isinstance(fingerprint, str):
            fingerprint = Fingerprint.parse(fingerprint)
        encoded = fingerprint.encode()
        key = _job_key(label, canonical_path, encoded)
        now = _utc_now()
        try:
            self.connection.execute("BEGIN IMMEDIATE")
            mismatched = self.connection.execute(
                """
                SELECT 1 FROM jobs
                WHERE label=? AND canonical_path=? AND config_identity<>?
                  AND phase IN ('queued', 'resolved', 'rescan_waiting',
                                'search_ready', 'search_waiting')
                LIMIT 1
                """,
                (label, canonical_path, mapping.config_identity),
            ).fetchone()
            if mismatched is not None:
                raise OutboxError(
                    f"configuration identity mismatch for label {mapping.label}"
                )
            existing = self.connection.execute(
                "SELECT config_identity FROM jobs WHERE job_key=?", (key,)
            ).fetchone()
            if (
                existing is not None
                and existing["config_identity"] != mapping.config_identity
            ):
                raise OutboxError(
                    f"configuration identity mismatch for label {mapping.label}"
                )
            self.connection.execute(
                """
                UPDATE jobs
                SET phase='superseded',
                    last_error='superseded by a newly enqueued fingerprint',
                    updated_at=?
                WHERE label=? AND canonical_path=? AND job_key<>?
                  AND phase IN ('queued', 'resolved', 'rescan_waiting',
                                'search_ready', 'search_waiting')
                """,
                (now, label, canonical_path, key),
            )
            self.connection.execute(
                """
                INSERT INTO jobs (
                    job_key, label, kind, config_identity, canonical_path,
                    fingerprint, phase, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, 'queued', ?, ?)
                ON CONFLICT(job_key) DO UPDATE SET
                    phase='queued', entity_id=NULL, entity_path=NULL,
                    season_number=NULL, command_id=NULL, attempts=0,
                    last_error=NULL, updated_at=excluded.updated_at
                WHERE jobs.phase='superseded'
                """,
                (
                    key,
                    label,
                    mapping.kind,
                    mapping.config_identity,
                    canonical_path,
                    encoded,
                    now,
                    now,
                ),
            )
            row = self.connection.execute(
                "SELECT id FROM jobs WHERE job_key=?", (key,)
            ).fetchone()
            if row is None:
                raise OutboxError("durable enqueue did not produce a job")
            self.connection.commit()
            return int(row["id"])
        except Exception:
            self.connection.rollback()
            raise

    def cancel(self, job_id: int, reason: str) -> None:
        reason = reason.strip() or "cancelled"
        with self.connection:
            cursor = self.connection.execute(
                """
                UPDATE jobs
                SET phase='superseded', last_error=?, updated_at=?
                WHERE id=? AND phase IN ('queued', 'resolved', 'rescan_waiting',
                                         'search_ready', 'search_waiting')
                """,
                (reason[:500], _utc_now(), job_id),
            )
        if cursor.rowcount == 0 and self.get_job(job_id) is None:
            raise OutboxError(f"unknown outbox job id {job_id}")

    def get_job(self, job_id: int):
        row = self.connection.execute(
            "SELECT * FROM jobs WHERE id=?", (job_id,)
        ).fetchone()
        return dict(row) if row is not None else None

    def count(self) -> dict[str, int]:
        placeholders = ",".join("?" for _ in ACTIVE_PHASES)
        # Only the count of fixed SQLite parameter markers is interpolated.
        count_query = (
            "SELECT "  # nosec B608
            f"SUM(CASE WHEN phase IN ({placeholders}) THEN 1 ELSE 0 END), "
            f"SUM(CASE WHEN phase IN ({placeholders}) "
            "AND last_error IS NOT NULL THEN 1 ELSE 0 END), "
            "COUNT(*) FROM jobs"
        )
        row = self.connection.execute(
            count_query,
            (*ACTIVE_PHASES, *ACTIVE_PHASES),
        ).fetchone()
        return {
            "pending": int(row[0] or 0),
            "errors": int(row[1] or 0),
            "total": int(row[2] or 0),
        }

    def _active_rows(self, phase: Optional[str] = None) -> list[sqlite3.Row]:
        if phase is None:
            placeholders = ",".join("?" for _ in ACTIVE_PHASES)
            # Only the count of fixed SQLite parameter markers is interpolated.
            active_query = (
                f"SELECT * FROM jobs WHERE phase IN ({placeholders}) ORDER BY id"  # nosec B608
            )
            return list(
                self.connection.execute(
                    active_query,
                    ACTIVE_PHASES,
                )
            )
        return list(
            self.connection.execute(
                "SELECT * FROM jobs WHERE phase=? ORDER BY id", (phase,)
            )
        )

    def _set_error(self, job_id: int, error: Exception | str) -> None:
        text = str(error).replace("\n", " ")[:500]
        with self.connection:
            self.connection.execute(
                """
                UPDATE jobs
                SET last_error=?, attempts=attempts+1, updated_at=?
                WHERE id=?
                """,
                (text, _utc_now(), job_id),
            )

    def _supersede(self, job_id: int, reason: str) -> None:
        with self.connection:
            self.connection.execute(
                """
                UPDATE jobs
                SET phase='superseded', last_error=?, updated_at=?
                WHERE id=?
                """,
                (reason[:500], _utc_now(), job_id),
            )

    def _persist_resolution(
        self,
        job_id: int,
        entity_id: int,
        entity_path: str,
        season_number: Optional[int],
    ) -> None:
        with self.connection:
            self.connection.execute(
                """
                UPDATE jobs
                SET phase='resolved', entity_id=?, entity_path=?, season_number=?,
                    last_error=NULL, updated_at=?
                WHERE id=? AND phase='queued'
                """,
                (entity_id, entity_path, season_number, _utc_now(), job_id),
            )

    def _persist_rescan_acceptance(self, job_id: int, command_id: int) -> None:
        with self.connection:
            self.connection.execute(
                """
                UPDATE jobs
                SET phase='rescan_waiting', command_id=?, last_error=NULL,
                    updated_at=?
                WHERE id=? AND phase='resolved'
                """,
                (command_id, _utc_now(), job_id),
            )

    def _persist_search_acceptance(self, job_id: int, command_id: int) -> None:
        with self.connection:
            self.connection.execute(
                """
                UPDATE jobs
                SET phase='search_waiting', command_id=?, last_error=NULL,
                    updated_at=?
                WHERE id=? AND phase='search_ready'
                """,
                (command_id, _utc_now(), job_id),
            )

    def _mapping_for_job(self, job: Mapping[str, Any]) -> MappingConfig:
        mapping = self._require_config().mapping(str(job["label"]))
        if (
            mapping.kind != job["kind"]
            or mapping.config_identity != job["config_identity"]
        ):
            raise OutboxError(
                f"configuration identity mismatch for label {mapping.label}"
            )
        return mapping

    def _client_for_job(self, job: Mapping[str, Any]) -> APIClient:
        config = self._require_config()
        return APIClient(self._mapping_for_job(job), config.api_timeout)

    @staticmethod
    def _history_endpoint(kind: str, entity_id: int) -> str:
        entity_filter = "seriesIds" if kind == "sonarr" else "movieIds"
        parameters = {
            "page": 1,
            "pageSize": 250,
            "sortKey": "date",
            "sortDirection": "descending",
            entity_filter: entity_id,
        }
        if kind == "sonarr":
            parameters.update({"includeSeries": "false", "includeEpisode": "false"})
        else:
            parameters["includeMovie"] = "false"
        return f"/api/v3/history?{urlencode(parameters)}"

    @staticmethod
    def _matching_grabbed_history_id(
        response: Any,
        canonical_path: str,
        kind: str,
        entity_id: int,
    ) -> Optional[int]:
        if not isinstance(response, dict) or not isinstance(
            response.get("records"), list
        ):
            raise ServarrAPIError("history response did not contain a records list")
        entity_key = "seriesId" if kind == "sonarr" else "movieId"
        import_download_id = None
        for record in response["records"]:
            if not isinstance(record, dict):
                continue
            if record.get("eventType") != "downloadFolderImported":
                continue
            if record.get(entity_key) != entity_id:
                continue
            data = record.get("data")
            imported_path = data.get("importedPath") if isinstance(data, dict) else None
            if not isinstance(imported_path, str) or not imported_path:
                continue
            if _canonical(imported_path) != canonical_path:
                continue
            download_id = record.get("downloadId")
            if isinstance(download_id, str) and download_id.strip():
                import_download_id = download_id
                break
        if import_download_id is None:
            return None
        for record in response["records"]:
            if not isinstance(record, dict):
                continue
            if record.get("eventType") != "grabbed":
                continue
            if record.get(entity_key) != entity_id:
                continue
            if record.get("downloadId") != import_download_id:
                continue
            history_id = record.get("id")
            if isinstance(history_id, int):
                return history_id
        return None

    def _mark_matching_import_failed(
        self,
        client: APIClient,
        mapping: MappingConfig,
        entity_id: int,
        canonical_path: str,
    ) -> bool:
        history = client.request("GET", self._history_endpoint(mapping.kind, entity_id))
        history_id = self._matching_grabbed_history_id(
            history,
            canonical_path,
            mapping.kind,
            entity_id,
        )
        if history_id is None:
            return False
        response = client.request("POST", f"/api/v3/history/failed/{history_id}")
        if response is not None and not isinstance(response, dict):
            raise ServarrAPIError("mark-failed response is malformed")
        return True

    def _resolve_queued(self, eligible_ids: set[int], result: dict[str, int]) -> None:
        queued = [
            job for job in self._active_rows("queued") if job["id"] in eligible_ids
        ]
        grouped: dict[tuple[str, str], list[sqlite3.Row]] = {}
        for job in queued:
            mapping = self._mapping_for_job(job)
            grouped.setdefault((mapping.kind, mapping.url), []).append(job)
        for jobs in grouped.values():
            mapping = self._mapping_for_job(jobs[0])
            endpoint = "/api/v3/series" if mapping.kind == "sonarr" else "/api/v3/movie"
            client = APIClient(mapping, self._require_config().api_timeout)
            try:
                catalog = client.request("GET", endpoint)
                if not isinstance(catalog, list):
                    raise ServarrAPIError(
                        f"{mapping.kind} catalog response is not a list"
                    )
            except OutboxError as exc:
                for job in jobs:
                    self._set_error(job["id"], exc)
                    result["errors"] += 1
                continue
            for job in jobs:
                entity = best_path_match(catalog, job["canonical_path"])
                if entity is None:
                    self._set_error(
                        job["id"],
                        f"no {mapping.kind} catalog path matched the source path",
                    )
                    result["errors"] += 1
                    continue
                entity_id = entity.get("id")
                entity_path = entity.get("path")
                if not isinstance(entity_id, int) or not isinstance(entity_path, str):
                    self._set_error(job["id"], "matched catalog entity is malformed")
                    result["errors"] += 1
                    continue
                season = (
                    season_number_from_path(job["canonical_path"])
                    if mapping.kind == "sonarr"
                    else None
                )
                try:
                    if self._mark_matching_import_failed(
                        client,
                        mapping,
                        entity_id,
                        job["canonical_path"],
                    ):
                        result["blocklisted"] += 1
                except OutboxError as exc:
                    self._set_error(job["id"], exc)
                    result["errors"] += 1
                    continue
                self._persist_resolution(job["id"], entity_id, entity_path, season)
                result["resolved"] += 1

    @staticmethod
    def _rescan_payload(job: Mapping[str, Any]) -> dict[str, Any]:
        if job["kind"] == "sonarr":
            return {"name": "RescanSeries", "seriesId": job["entity_id"]}
        return {"name": "RescanMovie", "movieId": job["entity_id"]}

    @staticmethod
    def _search_payload(job: Mapping[str, Any]) -> dict[str, Any]:
        if job["kind"] == "radarr":
            return {"name": "MoviesSearch", "movieIds": [job["entity_id"]]}
        if job["season_number"] is None:
            return {"name": "SeriesSearch", "seriesId": job["entity_id"]}
        return {
            "name": "SeasonSearch",
            "seriesId": job["entity_id"],
            "seasonNumber": job["season_number"],
        }

    def _post_rescans(self, eligible_ids: set[int], result: dict[str, int]) -> None:
        for job in self._active_rows("resolved"):
            if job["id"] not in eligible_ids:
                continue
            try:
                response = self._client_for_job(job).request(
                    "POST", "/api/v3/command", self._rescan_payload(job)
                )
                if not isinstance(response, dict) or not isinstance(
                    response.get("id"), int
                ):
                    raise ServarrAPIError(
                        "rescan response did not contain a command id"
                    )
                self._persist_rescan_acceptance(job["id"], response["id"])
                result["rescans"] += 1
            except ServarrAPIError as exc:
                self._set_error(job["id"], exc)
                result["errors"] += 1

    def _reset_waiting(
        self, job_id: int, waiting_phase: str, retry_phase: str, error: str
    ) -> None:
        with self.connection:
            self.connection.execute(
                """
                UPDATE jobs
                SET phase=?, command_id=NULL, last_error=?,
                    attempts=attempts+1, updated_at=?
                WHERE id=? AND phase=?
                """,
                (retry_phase, error[:500], _utc_now(), job_id, waiting_phase),
            )

    def _observe_commands(
        self,
        waiting_ids: set[int],
        waiting_phase: str,
        retry_phase: str,
        operation: str,
        completion_key: str,
        result: dict[str, int],
    ) -> set[int]:
        completed: set[int] = set()
        for job_id in waiting_ids:
            job = self.get_job(job_id)
            if job is None or job["phase"] != waiting_phase:
                continue
            try:
                response = self._client_for_job(job).request(
                    "GET", f"/api/v3/command/{job['command_id']}"
                )
            except ServarrAPIError as exc:
                if exc.status_code == 404:
                    self._reset_waiting(
                        job_id,
                        waiting_phase,
                        retry_phase,
                        f"{operation} command not found: HTTP 404",
                    )
                else:
                    self._set_error(job_id, exc)
                result["errors"] += 1
                continue
            except OutboxError as exc:
                self._set_error(job_id, exc)
                result["errors"] += 1
                continue
            status = response.get("status") if isinstance(response, dict) else None
            command_result = (
                response.get("result") if isinstance(response, dict) else None
            )
            if status == "completed" and command_result == "successful":
                with self.connection:
                    if waiting_phase == "search_waiting":
                        self.connection.execute(
                            "DELETE FROM jobs WHERE id=?", (job_id,)
                        )
                    else:
                        self.connection.execute(
                            """
                            UPDATE jobs SET phase='search_ready', command_id=NULL,
                                last_error=NULL, updated_at=?
                            WHERE id=? AND phase=?
                            """,
                            (_utc_now(), job_id, waiting_phase),
                        )
                completed.add(job_id)
                result[completion_key] += 1
            elif status == "completed" or status in {"failed", "aborted"}:
                outcome = command_result if status == "completed" else status
                if not isinstance(outcome, str) or not outcome:
                    outcome = "missing"
                self._reset_waiting(
                    job_id,
                    waiting_phase,
                    retry_phase,
                    f"{operation} command ended with result {outcome}",
                )
                result["errors"] += 1
            elif not isinstance(status, str):
                self._set_error(job_id, "command status response is malformed")
                result["errors"] += 1
        return completed

    def _observe_rescans(
        self, waiting_ids: set[int], result: dict[str, int]
    ) -> set[int]:
        return self._observe_commands(
            waiting_ids,
            "rescan_waiting",
            "resolved",
            "rescan",
            "rescan_completed",
            result,
        )

    def _observe_searches(self, waiting_ids: set[int], result: dict[str, int]) -> None:
        self._observe_commands(
            waiting_ids,
            "search_waiting",
            "search_ready",
            "search",
            "completed",
            result,
        )

    def _post_searches(self, job_ids: set[int], result: dict[str, int]) -> None:
        for job_id in job_ids:
            job = self.get_job(job_id)
            if job is None or job["phase"] != "search_ready":
                continue
            try:
                response = self._client_for_job(job).request(
                    "POST", "/api/v3/command", self._search_payload(job)
                )
                if not isinstance(response, dict) or not isinstance(
                    response.get("id"), int
                ):
                    raise ServarrAPIError(
                        "search response did not contain a command id"
                    )
                self._persist_search_acceptance(job_id, response["id"])
            except OutboxError as exc:
                self._set_error(job_id, exc)
                result["errors"] += 1

    def _prune_superseded(self) -> int:
        config = self._require_config()
        cutoff = (
            datetime.now(timezone.utc)
            - timedelta(seconds=config.superseded_retention_seconds)
        ).isoformat(timespec="seconds")
        with self.connection:
            cursor = self.connection.execute(
                "DELETE FROM jobs WHERE phase='superseded' AND updated_at<?",
                (cutoff,),
            )
        return cursor.rowcount

    def drain(self) -> dict[str, int]:
        self._require_config()
        result = {
            "deferred": 0,
            "superseded": 0,
            "blocklisted": 0,
            "resolved": 0,
            "rescans": 0,
            "rescan_completed": 0,
            "completed": 0,
            "errors": 0,
            "pruned": self._prune_superseded(),
        }
        missing_ids: set[int] = set()
        for job in self._active_rows():
            try:
                self._mapping_for_job(job)
            except OutboxError as exc:
                self._set_error(job["id"], exc)
                result["errors"] += 1
                continue
            try:
                current = Fingerprint.from_path(job["canonical_path"])
            except FileNotFoundError:
                missing_ids.add(job["id"])
                continue
            except OSError as exc:
                self._set_error(job["id"], f"cannot fingerprint source: {exc}")
                result["errors"] += 1
                continue
            if current.encode() == job["fingerprint"]:
                result["deferred"] += 1
            else:
                self._supersede(
                    job["id"], "source path now has a different fingerprint"
                )
                result["superseded"] += 1

        if self.dry_run:
            return result

        if not missing_ids:
            return result

        waiting_at_start = {
            job["id"]
            for job in self._active_rows("rescan_waiting")
            if job["id"] in missing_ids
        }
        search_at_start = {
            job["id"]
            for job in self._active_rows("search_ready")
            if job["id"] in missing_ids
        }
        search_waiting_at_start = {
            job["id"]
            for job in self._active_rows("search_waiting")
            if job["id"] in missing_ids
        }
        self._resolve_queued(missing_ids, result)
        self._post_rescans(missing_ids, result)
        newly_ready = self._observe_rescans(waiting_at_start, result)
        self._post_searches(search_at_start | newly_ready, result)
        self._observe_searches(search_waiting_at_start, result)
        return result
