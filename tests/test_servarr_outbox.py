import json
import sqlite3
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from servarr_outbox import (
    APIClient,
    ConfigurationError,
    Fingerprint,
    MappingConfig,
    Outbox,
    OutboxError,
    SCHEMA_VERSION,
    ServarrAPIError,
    best_path_match,
    load_config,
    season_number_from_path,
    verify_api,
)


class FakeServarr:
    def __init__(self):
        self.requests = []
        self.series = []
        self.movies = []
        self.roots = []
        self.command_status = "completed"
        self.command_result = "successful"
        self.command_get_status = 200
        self.missing_command_ids = set()
        self.fail_rescans = 0
        self.fail_searches = 0
        self.fail_history_gets = 0
        self.fail_mark_failed = 0
        self.history = []
        self.next_command_id = 40

        owner = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, _format, *_args):
                return

            def _reply(self, status, payload):
                body = json.dumps(payload).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):
                owner.requests.append(("GET", self.path, None))
                if self.path == "/api/v3/system/status":
                    self._reply(200, {"version": "test"})
                elif self.path == "/api/v3/rootfolder":
                    self._reply(200, [{"path": path} for path in owner.roots])
                elif self.path == "/api/v3/series":
                    self._reply(200, owner.series)
                elif self.path == "/api/v3/movie":
                    self._reply(200, owner.movies)
                elif self.path.startswith("/api/v3/history?"):
                    if owner.fail_history_gets:
                        owner.fail_history_gets -= 1
                        self._reply(503, {"message": "temporary"})
                        return
                    self._reply(
                        200, {"page": 1, "pageSize": 100, "records": owner.history}
                    )
                elif self.path.startswith("/api/v3/command/"):
                    command_id = int(self.path.rsplit("/", 1)[-1])
                    if command_id in owner.missing_command_ids:
                        self._reply(404, {"message": "not found"})
                        return
                    if owner.command_get_status != 200:
                        self._reply(owner.command_get_status, {"message": "temporary"})
                        return
                    self._reply(
                        200,
                        {
                            "status": owner.command_status,
                            "result": owner.command_result,
                        },
                    )
                else:
                    self._reply(404, {"message": "not found"})

            def do_POST(self):
                length = int(self.headers.get("Content-Length", "0"))
                payload = json.loads(self.rfile.read(length) or b"{}")
                owner.requests.append(("POST", self.path, payload))
                if self.path.startswith("/api/v3/history/failed/"):
                    if owner.fail_mark_failed:
                        owner.fail_mark_failed -= 1
                        self._reply(503, {"message": "temporary"})
                        return
                    self._reply(200, {})
                    return
                is_search = payload.get("name") in {
                    "SeasonSearch",
                    "SeriesSearch",
                    "MoviesSearch",
                }
                is_rescan = payload.get("name") in {"RescanSeries", "RescanMovie"}
                if is_rescan and owner.fail_rescans:
                    owner.fail_rescans -= 1
                    self._reply(503, {"message": "temporary"})
                    return
                if is_search and owner.fail_searches:
                    owner.fail_searches -= 1
                    self._reply(503, {"message": "temporary"})
                    return
                owner.next_command_id += 1
                self._reply(201, {"id": owner.next_command_id})

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    @property
    def url(self):
        return f"http://127.0.0.1:{self.server.server_port}"

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()


class RecordingHTTPServer:
    def __init__(self):
        self.requests = []
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, _format, *_args):
                return

            def _record(self):
                length = int(self.headers.get("Content-Length", "0"))
                body = self.rfile.read(length) if length else b""
                owner.requests.append(
                    (self.command, self.path, self.headers.get("X-Api-Key"), body)
                )
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", "2")
                self.end_headers()
                self.wfile.write(b"{}")

            do_GET = _record
            do_POST = _record

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    @property
    def url(self):
        return f"http://127.0.0.1:{self.server.server_port}"

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()


class RedirectHTTPServer:
    def __init__(self, target_url, status):
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, _format, *_args):
                return

            def _redirect(self):
                owner.requests.append((self.command, self.path))
                self.send_response(status)
                self.send_header("Location", f"{target_url}/redirected")
                self.send_header("Content-Length", "0")
                self.end_headers()

            do_GET = _redirect
            do_POST = _redirect

        self.requests = []
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    @property
    def url(self):
        return f"http://127.0.0.1:{self.server.server_port}"

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()


class OutboxTestCase(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.root = Path(self.tempdir.name)
        self.roots = {
            "PlexTV": self.root / "PlexTV",
            "PlexTVHD": self.root / "PlexTVHD",
            "PlexFilms": self.root / "PlexFilms",
            "PlexFilmsHD": self.root / "PlexFilmsHD",
        }
        for root in self.roots.values():
            root.mkdir()
        self.server = FakeServarr()
        self.server.roots = [str(path) for path in self.roots.values()]
        self.env = {
            "PLEX_TV_DIR": str(self.roots["PlexTV"]),
            "PLEX_TVHD_DIR": str(self.roots["PlexTVHD"]),
            "PLEX_FILMS_DIR": str(self.roots["PlexFilms"]),
            "PLEX_FILMSHD_DIR": str(self.roots["PlexFilmsHD"]),
            "SONARR_TV_URL": self.server.url,
            "SONARR_TV_API_KEY": "tv-secret",
            "SONARR_TVHD_URL": self.server.url,
            "SONARR_TVHD_API_KEY": "tvhd-secret",
            "RADARR_FILMS_URL": self.server.url,
            "RADARR_FILMS_API_KEY": "films-secret",
            "RADARR_FILMSHD_URL": self.server.url,
            "RADARR_FILMSHD_API_KEY": "filmshd-secret",
        }
        self.config = load_config(self.env)
        self.db = self.root / "outbox.sqlite3"

    def tearDown(self):
        self.server.close()
        self.tempdir.cleanup()

    def make_file(self, relative="PlexTV/Show/Season 01/Episode.mkv"):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"media")
        return path

    def enqueue_missing(self, outbox, label, relative, fingerprint=None):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        if fingerprint is None:
            fingerprint = Fingerprint(1, 2, 3, 4, 5)
        return outbox.enqueue(label, str(path), fingerprint), path

    def test_configuration_rejects_blank_and_malformed_values(self):
        blank = dict(self.env)
        blank["SONARR_TV_API_KEY"] = "  "
        with self.assertRaises(ConfigurationError):
            load_config(blank)

        malformed = dict(self.env)
        malformed["RADARR_FILMS_URL"] = "not-a-url"
        with self.assertRaises(ConfigurationError):
            load_config(malformed)

        for unsafe_url in (
            "http://user:password@servarr.example.invalid:8989",
            "http://servarr.example.invalid:not-a-port",
            "http://:8989",
            "http://servarr.example.invalid:8989/base?",
            "http://servarr.example.invalid:8989/base#",
        ):
            with self.subTest(unsafe_url=unsafe_url):
                unsafe = dict(self.env)
                unsafe["RADARR_FILMS_URL"] = unsafe_url
                with self.assertRaises(ConfigurationError):
                    load_config(unsafe)

        oversized_retention = dict(self.env)
        oversized_retention["SERVARR_SUPERSEDED_RETENTION_SECONDS"] = str(
            1000 * 365 * 24 * 60 * 60
        )
        with self.assertRaises(ConfigurationError):
            load_config(oversized_retention)

    def test_config_identity_changes_for_target_but_not_api_key_rotation(self):
        original = getattr(self.config.mappings["PlexTV"], "config_identity", None)
        self.assertIsNotNone(original)

        rotated_key = dict(self.env)
        rotated_key["SONARR_TV_API_KEY"] = "rotated-secret"
        self.assertEqual(
            getattr(
                load_config(rotated_key).mappings["PlexTV"],
                "config_identity",
                None,
            ),
            original,
        )

        changed_url = dict(self.env)
        changed_url["SONARR_TV_URL"] = f"{self.server.url}/retargeted"
        self.assertNotEqual(
            getattr(
                load_config(changed_url).mappings["PlexTV"],
                "config_identity",
                None,
            ),
            original,
        )

        changed_root_path = self.root / "PlexTVRetargeted"
        changed_root_path.mkdir()
        changed_root = dict(self.env)
        changed_root["PLEX_TV_DIR"] = str(changed_root_path)
        self.assertNotEqual(
            getattr(
                load_config(changed_root).mappings["PlexTV"],
                "config_identity",
                None,
            ),
            original,
        )

    def test_verify_api_checks_status_and_exact_root_coverage(self):
        verify_api(self.config)
        self.server.roots.remove(str(self.roots["PlexTVHD"]))
        with self.assertRaisesRegex(ConfigurationError, "PlexTVHD"):
            verify_api(self.config)

    def test_enqueue_deduplicates_and_commits_a_durable_row(self):
        source = self.make_file()
        fingerprint = Fingerprint.from_path(source)
        with Outbox(self.db, self.config) as outbox:
            first = outbox.enqueue("PlexTV", str(source), fingerprint)
            second = outbox.enqueue("PlexTV", str(source), fingerprint)
            self.assertEqual(first, second)

        with Outbox(self.db, self.config) as reopened:
            self.assertEqual(reopened.count()["pending"], 1)
            job = reopened.get_job(first)
            self.assertEqual(job["phase"], "queued")
            self.assertEqual(job["fingerprint"], fingerprint.encode())
            self.assertIsNotNone(job.get("config_identity"))
            self.assertEqual(
                job.get("config_identity"),
                getattr(self.config.mappings["PlexTV"], "config_identity", None),
            )

    def test_url_retarget_retains_waiting_job_without_wrong_instance_requests(self):
        self.server.series = [{"id": 61, "path": str(self.roots["PlexTV"] / "Show")}]
        with Outbox(self.db, self.config) as outbox:
            job_id, missing = self.enqueue_missing(
                outbox,
                "PlexTV",
                "PlexTV/Show/Season 01/Episode.mkv",
            )
            outbox.drain()
            self.assertEqual(outbox.get_job(job_id)["phase"], "rescan_waiting")

        replacement = FakeServarr()
        replacement.roots = [str(path) for path in self.roots.values()]
        try:
            retargeted_env = dict(self.env)
            retargeted_env["SONARR_TV_URL"] = replacement.url
            retargeted = load_config(retargeted_env)
            with Outbox(self.db, retargeted) as outbox:
                result = outbox.drain()
                job = outbox.get_job(job_id)
                self.assertIsNotNone(job)
                if job is None:
                    return
                self.assertEqual(job["phase"], "rescan_waiting")
                self.assertIn("configuration identity mismatch", job["last_error"])
                self.assertEqual(result["errors"], 1)
                with self.assertRaisesRegex(OutboxError, "configuration identity"):
                    outbox.enqueue(
                        "PlexTV",
                        str(missing),
                        Fingerprint(1, 2, 3, 4, 5),
                    )
                with self.assertRaisesRegex(OutboxError, "configuration identity"):
                    outbox.enqueue(
                        "PlexTV",
                        str(missing),
                        Fingerprint(1, 2, 3, 4, 6),
                    )
            self.assertEqual(replacement.requests, [])
        finally:
            replacement.close()

    def test_root_retarget_retains_resolved_job_without_http_requests(self):
        self.server.series = [{"id": 62, "path": str(self.roots["PlexTV"] / "Show")}]
        self.server.fail_rescans = 1
        with Outbox(self.db, self.config) as outbox:
            job_id, _ = self.enqueue_missing(
                outbox,
                "PlexTV",
                "PlexTV/Show/Season 01/Episode.mkv",
            )
            outbox.drain()
            self.assertEqual(outbox.get_job(job_id)["phase"], "resolved")

        self.server.requests.clear()
        new_root = self.root / "PlexTVRetargeted"
        new_root.mkdir()
        retargeted_env = dict(self.env)
        retargeted_env["PLEX_TV_DIR"] = str(new_root)
        retargeted = load_config(retargeted_env)
        with Outbox(self.db, retargeted) as outbox:
            result = outbox.drain()
            job = outbox.get_job(job_id)
            self.assertEqual(job["phase"], "resolved")
            self.assertIn("configuration identity mismatch", job["last_error"])
            self.assertEqual(result["errors"], 1)
        self.assertEqual(self.server.requests, [])

    def test_existing_same_fingerprint_defers_and_different_fingerprint_supersedes(
        self,
    ):
        source = self.make_file()
        fingerprint = Fingerprint.from_path(source)
        with Outbox(self.db, self.config) as outbox:
            job_id = outbox.enqueue("PlexTV", str(source), fingerprint)
            result = outbox.drain()
            self.assertEqual(result["deferred"], 1)
            self.assertEqual(outbox.get_job(job_id)["phase"], "queued")

            source.write_bytes(b"different media")
            result = outbox.drain()
            self.assertEqual(result["superseded"], 1)
            self.assertEqual(outbox.count()["pending"], 0)
            self.assertEqual(outbox.get_job(job_id)["phase"], "superseded")

    def test_missing_jobs_share_one_catalog_get_and_resolve_most_specific_paths(self):
        self.server.series = [
            {"id": 10, "path": str(self.roots["PlexTV"] / "Show")},
            {"id": 11, "path": str(self.roots["PlexTV"] / "Show Extra")},
        ]
        with Outbox(self.db, self.config) as outbox:
            first, _ = self.enqueue_missing(
                outbox,
                "PlexTV",
                "PlexTV/Show/Season 01/One.mkv",
            )
            second, _ = self.enqueue_missing(
                outbox,
                "PlexTV",
                "PlexTV/Show Extra/Season 02/Two.mkv",
            )
            outbox.drain()
            self.assertEqual(outbox.get_job(first)["entity_id"], 10)
            self.assertEqual(outbox.get_job(second)["entity_id"], 11)

        catalog_gets = [
            request
            for request in self.server.requests
            if request[:2] == ("GET", "/api/v3/series")
        ]
        self.assertEqual(len(catalog_gets), 1)

    def test_missing_job_does_not_advance_unrelated_existing_source(self):
        self.server.series = [
            {"id": 12, "path": str(self.roots["PlexTV"] / "Missing Show")},
            {"id": 13, "path": str(self.roots["PlexTV"] / "Existing Show")},
        ]
        existing = self.make_file("PlexTV/Existing Show/Season 01/Episode.mkv")
        with Outbox(self.db, self.config) as outbox:
            existing_id = outbox.enqueue(
                "PlexTV", str(existing), Fingerprint.from_path(existing)
            )
            missing_id, _ = self.enqueue_missing(
                outbox,
                "PlexTV",
                "PlexTV/Missing Show/Season 01/Episode.mkv",
            )
            outbox.drain()

            self.assertEqual(outbox.get_job(existing_id)["phase"], "queued")
            self.assertEqual(outbox.get_job(missing_id)["phase"], "rescan_waiting")

    def test_matching_sonarr_import_is_marked_failed_before_rescan(self):
        self.server.series = [{"id": 14, "path": str(self.roots["PlexTV"] / "Show")}]
        with Outbox(self.db, self.config) as outbox:
            job_id, path = self.enqueue_missing(
                outbox,
                "PlexTV",
                "PlexTV/Show/Season 01/Episode.mkv",
            )
            self.server.history = [
                {
                    "id": 77,
                    "eventType": "downloadFolderImported",
                    "downloadId": "download-77",
                    "seriesId": 14,
                    "data": {"importedPath": str(path)},
                },
                {
                    "id": 177,
                    "eventType": "grabbed",
                    "downloadId": "download-77",
                    "seriesId": 14,
                    "data": {},
                },
            ]
            result = outbox.drain()

            self.assertEqual(result.get("blocklisted"), 1)
            self.assertEqual(outbox.get_job(job_id)["phase"], "rescan_waiting")

        failed_requests = [
            (index, request)
            for index, request in enumerate(self.server.requests)
            if request[:2] == ("POST", "/api/v3/history/failed/177")
        ]
        self.assertEqual(len(failed_requests), 1)
        failed_index = failed_requests[0][0]
        rescan_index = next(
            index
            for index, request in enumerate(self.server.requests)
            if request[0] == "POST" and request[2].get("name") == "RescanSeries"
        )
        self.assertLess(failed_index, rescan_index)
        history_get = next(
            request
            for request in self.server.requests
            if request[0] == "GET" and request[1].startswith("/api/v3/history?")
        )
        self.assertIn("seriesIds=14", history_get[1])

    def test_matching_radarr_import_is_marked_failed_before_rescan(self):
        self.server.movies = [
            {"id": 15, "path": str(self.roots["PlexFilms"] / "Movie")}
        ]
        with Outbox(self.db, self.config) as outbox:
            job_id, path = self.enqueue_missing(
                outbox,
                "PlexFilms",
                "PlexFilms/Movie/Movie.mkv",
            )
            self.server.history = [
                {
                    "id": 78,
                    "eventType": "downloadFolderImported",
                    "downloadId": "download-78",
                    "movieId": 15,
                    "data": {"importedPath": str(path)},
                },
                {
                    "id": 178,
                    "eventType": "grabbed",
                    "downloadId": "download-78",
                    "movieId": 15,
                    "data": {},
                },
            ]
            result = outbox.drain()

            self.assertEqual(result.get("blocklisted"), 1)
            self.assertEqual(outbox.get_job(job_id)["phase"], "rescan_waiting")

        self.assertIn(("POST", "/api/v3/history/failed/178", {}), self.server.requests)
        history_get = next(
            request
            for request in self.server.requests
            if request[0] == "GET" and request[1].startswith("/api/v3/history?")
        )
        self.assertIn("movieIds=15", history_get[1])

    def test_import_without_matching_grab_keeps_existing_recovery_path(self):
        self.server.series = [{"id": 16, "path": str(self.roots["PlexTV"] / "Show")}]
        with Outbox(self.db, self.config) as outbox:
            job_id, path = self.enqueue_missing(
                outbox,
                "PlexTV",
                "PlexTV/Show/Season 01/Episode.mkv",
            )
            self.server.history = [
                {
                    "id": 79,
                    "eventType": "downloadFolderImported",
                    "downloadId": "download-without-grab",
                    "seriesId": 16,
                    "data": {"importedPath": str(path)},
                }
            ]
            result = outbox.drain()
            self.assertEqual(result.get("blocklisted"), 0)
            self.assertEqual(outbox.get_job(job_id)["phase"], "rescan_waiting")

        self.assertFalse(
            any(
                request[0] == "POST"
                and request[1].startswith("/api/v3/history/failed/")
                for request in self.server.requests
            )
        )

    def test_history_api_failure_keeps_job_queued_without_rescan(self):
        self.server.series = [{"id": 17, "path": str(self.roots["PlexTV"] / "Show")}]
        self.server.fail_history_gets = 1
        with Outbox(self.db, self.config) as outbox:
            job_id, _ = self.enqueue_missing(
                outbox,
                "PlexTV",
                "PlexTV/Show/Season 01/Episode.mkv",
            )
            result = outbox.drain()
            self.assertEqual(result["errors"], 1)
            self.assertEqual(outbox.get_job(job_id)["phase"], "queued")
        self.assertFalse(
            any(
                request[0] == "POST" and request[2].get("name") == "RescanSeries"
                for request in self.server.requests
            )
        )

    def test_mark_failed_api_failure_retries_before_rescan(self):
        self.server.series = [{"id": 18, "path": str(self.roots["PlexTV"] / "Show")}]
        self.server.fail_mark_failed = 1
        with Outbox(self.db, self.config) as outbox:
            job_id, path = self.enqueue_missing(
                outbox,
                "PlexTV",
                "PlexTV/Show/Season 01/Episode.mkv",
            )
            self.server.history = [
                {
                    "id": 80,
                    "eventType": "downloadFolderImported",
                    "downloadId": "download-80",
                    "seriesId": 18,
                    "data": {"importedPath": str(path)},
                },
                {
                    "id": 180,
                    "eventType": "grabbed",
                    "downloadId": "download-80",
                    "seriesId": 18,
                    "data": {},
                },
            ]
            first = outbox.drain()
            self.assertEqual(first["errors"], 1)
            self.assertEqual(outbox.get_job(job_id)["phase"], "queued")

            second = outbox.drain()
            self.assertEqual(second.get("blocklisted"), 1)
            self.assertEqual(outbox.get_job(job_id)["phase"], "rescan_waiting")

        failed_posts = [
            request
            for request in self.server.requests
            if request[:2] == ("POST", "/api/v3/history/failed/180")
        ]
        self.assertEqual(len(failed_posts), 2)

    def test_enqueue_supersedes_other_fingerprint_and_reactivates_same_job_key(self):
        source = self.make_file()
        first_fingerprint = Fingerprint.from_path(source)
        second_fingerprint = Fingerprint(
            first_fingerprint.device,
            first_fingerprint.inode,
            first_fingerprint.size + 1,
            first_fingerprint.mtime_ns + 1,
            first_fingerprint.ctime_ns + 1,
        )
        with Outbox(self.db, self.config) as outbox:
            first_id = outbox.enqueue("PlexTV", str(source), first_fingerprint)
            second_id = outbox.enqueue("PlexTV", str(source), second_fingerprint)
            self.assertEqual(outbox.get_job(first_id)["phase"], "superseded")
            self.assertEqual(outbox.get_job(second_id)["phase"], "queued")

            outbox.cancel(second_id, "test cancellation")
            repeated_id = outbox.enqueue("PlexTV", str(source), second_fingerprint)
            self.assertEqual(repeated_id, second_id)
            self.assertEqual(outbox.get_job(second_id)["phase"], "queued")

    def test_rescan_and_search_both_wait_for_successful_command_completion(self):
        self.server.series = [{"id": 21, "path": str(self.roots["PlexTV"] / "Show")}]
        self.server.command_status = "started"
        with Outbox(self.db, self.config) as outbox:
            job_id, _ = self.enqueue_missing(
                outbox,
                "PlexTV",
                "PlexTV/Show/Season 03/Episode.mkv",
            )
            outbox.drain()
            job = outbox.get_job(job_id)
            self.assertEqual(job["phase"], "rescan_waiting")
            self.assertIsNotNone(job["command_id"])
            self.assertFalse(self._search_posts())

            outbox.drain()
            self.assertFalse(self._search_posts())
            self.server.command_status = "completed"
            self.server.command_result = "successful"
            outbox.drain()
            job = outbox.get_job(job_id)
            self.assertEqual(job["phase"], "search_waiting")
            self.assertIsNotNone(job["command_id"])
            self.assertEqual(self._search_posts()[0][2]["name"], "SeasonSearch")

            outbox.drain()
            self.assertIsNone(outbox.get_job(job_id))

    def test_completed_non_successful_rescan_resets_without_search(self):
        self.server.series = [{"id": 22, "path": str(self.roots["PlexTV"] / "Show")}]
        for outcome in ("failed", "unsuccessful"):
            with self.subTest(outcome=outcome):
                database = self.root / f"outbox-{outcome}.sqlite3"
                search_count = len(self._search_posts())
                self.server.command_status = "completed"
                self.server.command_result = outcome
                with Outbox(database, self.config) as outbox:
                    job_id, _ = self.enqueue_missing(
                        outbox,
                        "PlexTV",
                        "PlexTV/Show/Season 03/Episode.mkv",
                    )
                    outbox.drain()
                    outbox.drain()
                    job = outbox.get_job(job_id)
                    self.assertIsNotNone(job)
                    if job is None:
                        continue
                    self.assertEqual(job["phase"], "resolved")
                    self.assertIsNone(job["command_id"])
                    self.assertIn(outcome, job["last_error"])
                self.assertEqual(len(self._search_posts()), search_count)

    def test_failed_search_remains_ready_and_succeeds_without_another_rescan(self):
        self.server.movies = [
            {"id": 31, "path": str(self.roots["PlexFilms"] / "Movie")}
        ]
        self.server.fail_searches = 1
        with Outbox(self.db, self.config) as outbox:
            job_id, _ = self.enqueue_missing(
                outbox,
                "PlexFilms",
                "PlexFilms/Movie/Movie.mkv",
            )
            outbox.drain()
            outbox.drain()
            job = outbox.get_job(job_id)
            self.assertEqual(job["phase"], "search_ready")
            self.assertTrue(job["last_error"])

            outbox.drain()
            self.assertEqual(outbox.get_job(job_id)["phase"], "search_waiting")
            outbox.drain()
            self.assertIsNone(outbox.get_job(job_id))

        rescan_posts = [
            request
            for request in self.server.requests
            if request[0] == "POST" and request[2].get("name") == "RescanMovie"
        ]
        self.assertEqual(len(rescan_posts), 1)
        self.assertEqual(len(self._search_posts()), 2)

    def test_committed_rescan_phase_survives_reopen(self):
        self.server.series = [{"id": 41, "path": str(self.roots["PlexTV"] / "Show")}]
        with Outbox(self.db, self.config) as outbox:
            job_id, _ = self.enqueue_missing(
                outbox,
                "PlexTV",
                "PlexTV/Show/Season 01/Episode.mkv",
            )
            outbox.drain()

        with Outbox(self.db, self.config) as reopened:
            self.assertEqual(reopened.get_job(job_id)["phase"], "rescan_waiting")
            reopened.drain()
            self.assertEqual(reopened.get_job(job_id)["phase"], "search_waiting")

        with Outbox(self.db, self.config) as reopened:
            reopened.drain()
            self.assertIsNone(reopened.get_job(job_id))

    def test_committed_search_phase_survives_reopen_and_is_not_reposted(self):
        self.server.series = [{"id": 42, "path": str(self.roots["PlexTV"] / "Show")}]
        with Outbox(self.db, self.config) as outbox:
            job_id, _ = self.enqueue_missing(
                outbox,
                "PlexTV",
                "PlexTV/Show/Season 01/Episode.mkv",
            )
            outbox.drain()
            outbox.drain()
            job = outbox.get_job(job_id)
            self.assertEqual(job["phase"], "search_waiting")
            search_command_id = job["command_id"]

        search_count = len(self._search_posts())
        self.server.command_status = "started"
        with Outbox(self.db, self.config) as reopened:
            reopened.drain()
            job = reopened.get_job(job_id)
            self.assertEqual(job["phase"], "search_waiting")
            self.assertEqual(job["command_id"], search_command_id)
            self.assertEqual(len(self._search_posts()), search_count)

            self.server.command_status = "completed"
            self.server.command_result = "successful"
            reopened.drain()
            self.assertIsNone(reopened.get_job(job_id))

    def test_non_successful_search_commands_reset_ready_and_are_retained(self):
        self.server.movies = [
            {"id": 43, "path": str(self.roots["PlexFilms"] / "Movie")}
        ]
        outcomes = (
            ("completed", "failed", "failed"),
            ("completed", "unsuccessful", "unsuccessful"),
            ("aborted", None, "aborted"),
        )
        for index, (status, command_result, expected) in enumerate(outcomes):
            with self.subTest(status=status, result=command_result):
                database = self.root / f"search-outcome-{index}.sqlite3"
                self.server.command_status = "completed"
                self.server.command_result = "successful"
                with Outbox(database, self.config) as outbox:
                    job_id, _ = self.enqueue_missing(
                        outbox,
                        "PlexFilms",
                        f"PlexFilms/Movie/Movie-{index}.mkv",
                    )
                    outbox.drain()
                    outbox.drain()
                    self.assertEqual(outbox.get_job(job_id)["phase"], "search_waiting")

                    self.server.command_status = status
                    self.server.command_result = command_result
                    result = outbox.drain()
                    job = outbox.get_job(job_id)
                    self.assertEqual(job["phase"], "search_ready")
                    self.assertIsNone(job["command_id"])
                    self.assertIn(expected, job["last_error"])
                    self.assertEqual(result["errors"], 1)

    def test_crash_before_search_commit_retries_at_least_once(self):
        self.server.series = [{"id": 44, "path": str(self.roots["PlexTV"] / "Show")}]

        class CrashBeforeSearchCommitOutbox(Outbox):
            def _persist_search_acceptance(self, job_id, command_id):
                raise RuntimeError("simulated search crash")

        with CrashBeforeSearchCommitOutbox(self.db, self.config) as outbox:
            job_id, _ = self.enqueue_missing(
                outbox,
                "PlexTV",
                "PlexTV/Show/Season 01/Episode.mkv",
            )
            outbox.drain()
            with self.assertRaisesRegex(RuntimeError, "simulated search crash"):
                outbox.drain()

        with Outbox(self.db, self.config) as reopened:
            self.assertEqual(reopened.get_job(job_id)["phase"], "search_ready")
            reopened.drain()
            self.assertEqual(reopened.get_job(job_id)["phase"], "search_waiting")

        self.assertEqual(len(self._search_posts()), 2)

    def test_missing_rescan_command_resets_for_at_least_once_retry(self):
        self.server.series = [{"id": 45, "path": str(self.roots["PlexTV"] / "Show")}]
        with Outbox(self.db, self.config) as outbox:
            job_id, _ = self.enqueue_missing(
                outbox,
                "PlexTV",
                "PlexTV/Show/Season 01/Episode.mkv",
            )
            outbox.drain()
            command_id = outbox.get_job(job_id)["command_id"]
            self.server.missing_command_ids.add(command_id)

            result = outbox.drain()
            job = outbox.get_job(job_id)
            self.assertEqual(job["phase"], "resolved")
            self.assertIsNone(job["command_id"])
            self.assertIn("404", job["last_error"])
            self.assertEqual(result["errors"], 1)

            self.server.missing_command_ids.clear()
            outbox.drain()
            self.assertEqual(outbox.get_job(job_id)["phase"], "rescan_waiting")

        rescans = [
            request
            for request in self.server.requests
            if request[0] == "POST" and request[2].get("name") == "RescanSeries"
        ]
        self.assertEqual(len(rescans), 2)

    def test_non_404_rescan_poll_error_retains_waiting_command(self):
        self.server.series = [{"id": 46, "path": str(self.roots["PlexTV"] / "Show")}]
        with Outbox(self.db, self.config) as outbox:
            job_id, _ = self.enqueue_missing(
                outbox,
                "PlexTV",
                "PlexTV/Show/Season 01/Episode.mkv",
            )
            outbox.drain()
            command_id = outbox.get_job(job_id)["command_id"]
            self.server.command_get_status = 503

            result = outbox.drain()
            job = outbox.get_job(job_id)
            self.assertEqual(job["phase"], "rescan_waiting")
            self.assertEqual(job["command_id"], command_id)
            self.assertIn("503", job["last_error"])
            self.assertEqual(result["errors"], 1)

    def test_missing_search_command_resets_for_at_least_once_retry(self):
        self.server.movies = [
            {"id": 47, "path": str(self.roots["PlexFilms"] / "Movie")}
        ]
        with Outbox(self.db, self.config) as outbox:
            job_id, _ = self.enqueue_missing(
                outbox,
                "PlexFilms",
                "PlexFilms/Movie/Movie.mkv",
            )
            outbox.drain()
            outbox.drain()
            command_id = outbox.get_job(job_id)["command_id"]
            self.server.missing_command_ids.add(command_id)

            result = outbox.drain()
            job = outbox.get_job(job_id)
            self.assertEqual(job["phase"], "search_ready")
            self.assertIsNone(job["command_id"])
            self.assertIn("404", job["last_error"])
            self.assertEqual(result["errors"], 1)

            self.server.missing_command_ids.clear()
            outbox.drain()
            self.assertEqual(outbox.get_job(job_id)["phase"], "search_waiting")

        self.assertEqual(len(self._search_posts()), 2)

    def test_crash_before_rescan_commit_retries_at_least_once(self):
        self.server.series = [{"id": 51, "path": str(self.roots["PlexTV"] / "Show")}]

        class CrashBeforeCommitOutbox(Outbox):
            def _persist_rescan_acceptance(self, job_id, command_id):
                raise RuntimeError("simulated crash")

        with CrashBeforeCommitOutbox(self.db, self.config) as outbox:
            job_id, _ = self.enqueue_missing(
                outbox,
                "PlexTV",
                "PlexTV/Show/Season 01/Episode.mkv",
            )
            with self.assertRaisesRegex(RuntimeError, "simulated crash"):
                outbox.drain()

        with Outbox(self.db, self.config) as reopened:
            self.assertEqual(reopened.get_job(job_id)["phase"], "resolved")
            reopened.drain()

        rescan_posts = [
            request
            for request in self.server.requests
            if request[0] == "POST" and request[2].get("name") == "RescanSeries"
        ]
        self.assertEqual(len(rescan_posts), 2)

    def test_cancel_safely_supersedes_a_pending_job(self):
        with Outbox(self.db, self.config) as outbox:
            job_id, _ = self.enqueue_missing(
                outbox,
                "PlexTV",
                "PlexTV/Show/Season 01/Episode.mkv",
            )
            outbox.cancel(job_id, "source changed before delete")
            self.assertEqual(outbox.get_job(job_id)["phase"], "superseded")
            self.assertEqual(outbox.count()["pending"], 0)

    def test_drain_prunes_only_superseded_rows_older_than_default_retention(self):
        active_source = self.make_file("PlexTV/Active Show/Season 01/Episode.mkv")
        with Outbox(self.db, self.config) as outbox:
            old_id, _ = self.enqueue_missing(
                outbox,
                "PlexTV",
                "PlexTV/Old Show/Season 01/Episode.mkv",
            )
            recent_id, _ = self.enqueue_missing(
                outbox,
                "PlexTV",
                "PlexTV/Recent Show/Season 01/Episode.mkv",
            )
            active_id = outbox.enqueue(
                "PlexTV", str(active_source), Fingerprint.from_path(active_source)
            )
            outbox.cancel(old_id, "old terminal row")
            outbox.cancel(recent_id, "recent terminal row")
            with outbox.connection:
                outbox.connection.execute(
                    "UPDATE jobs SET updated_at=? WHERE id IN (?, ?)",
                    ("2000-01-01T00:00:00+00:00", old_id, active_id),
                )

            outbox.drain()

            self.assertIsNone(outbox.get_job(old_id))
            self.assertEqual(outbox.get_job(recent_id)["phase"], "superseded")
            self.assertEqual(outbox.get_job(active_id)["phase"], "queued")

    def test_dry_run_retains_missing_jobs_pending_without_network(self):
        with Outbox(self.db, self.config, dry_run=True) as outbox:
            job_id, _ = self.enqueue_missing(
                outbox,
                "PlexTV",
                "PlexTV/Show/Season 01/Episode.mkv",
            )
            result = outbox.drain()
            self.assertEqual(outbox.get_job(job_id)["phase"], "queued")
            self.assertEqual(outbox.count()["pending"], 1)
            self.assertEqual(result["completed"], 0)
        self.assertFalse(self.server.requests)

    def test_schema_v1_migration_preserves_active_job_and_adds_search_waiting(self):
        legacy = self.root / "legacy-v1.sqlite3"
        mapping = self.config.mappings["PlexTV"]
        connection = sqlite3.connect(legacy)
        connection.executescript(
            """
            CREATE TABLE jobs (
                id INTEGER PRIMARY KEY,
                job_key TEXT NOT NULL UNIQUE,
                label TEXT NOT NULL,
                kind TEXT NOT NULL,
                config_identity TEXT NOT NULL,
                canonical_path TEXT NOT NULL,
                fingerprint TEXT NOT NULL,
                phase TEXT NOT NULL CHECK (
                    phase IN (
                        'queued', 'resolved', 'rescan_waiting',
                        'search_ready', 'superseded'
                    )
                ),
                entity_id INTEGER,
                entity_path TEXT,
                season_number INTEGER,
                command_id INTEGER,
                attempts INTEGER NOT NULL DEFAULT 0,
                last_error TEXT,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );
            CREATE INDEX jobs_active_phase ON jobs(phase, label);
            PRAGMA user_version=1;
            """
        )
        connection.execute(
            """
            INSERT INTO jobs (
                id, job_key, label, kind, config_identity, canonical_path,
                fingerprint, phase, entity_id, entity_path, season_number,
                command_id, attempts, last_error, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                7,
                "legacy-key",
                "PlexTV",
                "sonarr",
                mapping.config_identity,
                str(self.roots["PlexTV"] / "Show" / "Episode.mkv"),
                "1:2:3:4:5",
                "search_ready",
                12,
                str(self.roots["PlexTV"] / "Show"),
                1,
                None,
                2,
                "legacy retry",
                "2026-01-01T00:00:00+00:00",
                "2026-01-02T00:00:00+00:00",
            ),
        )
        connection.commit()
        connection.close()

        with Outbox(legacy, self.config) as outbox:
            self.assertEqual(SCHEMA_VERSION, 2)
            self.assertEqual(
                outbox.connection.execute("PRAGMA user_version").fetchone()[0], 2
            )
            job = outbox.get_job(7)
            self.assertEqual(job["phase"], "search_ready")
            self.assertEqual(job["last_error"], "legacy retry")
            with outbox.connection:
                outbox.connection.execute(
                    "UPDATE jobs SET phase='search_waiting', command_id=99 WHERE id=7"
                )
            self.assertEqual(outbox.get_job(7)["phase"], "search_waiting")

    def test_corrupt_or_unknown_schema_fails_closed(self):
        corrupt = self.root / "corrupt.sqlite3"
        corrupt.write_bytes(b"not sqlite")
        with self.assertRaises(OutboxError):
            Outbox(corrupt, self.config)

        unknown = self.root / "unknown.sqlite3"
        connection = sqlite3.connect(unknown)
        connection.execute("PRAGMA user_version=99")
        connection.commit()
        connection.close()
        with self.assertRaises(OutboxError):
            Outbox(unknown, self.config)

    def _search_posts(self):
        return [
            request
            for request in self.server.requests
            if request[0] == "POST"
            and request[2].get("name")
            in {"SeasonSearch", "SeriesSearch", "MoviesSearch"}
        ]


class APIClientTransportTests(unittest.TestCase):
    def _mapping_for_url(self, url):
        tempdir = tempfile.TemporaryDirectory()
        self.addCleanup(tempdir.cleanup)
        root = Path(tempdir.name)
        return MappingConfig(
            "PlexTV",
            "sonarr",
            str(root),
            url,
            "redirect-secret",
            "test-identity",
        )

    def test_cross_origin_get_redirect_is_rejected_without_forwarding_api_key(self):
        target = RecordingHTTPServer()
        self.addCleanup(target.close)
        redirect = RedirectHTTPServer(target.url, 302)
        self.addCleanup(redirect.close)
        client = APIClient(self._mapping_for_url(redirect.url), 2)

        with self.assertRaises(ServarrAPIError) as caught:
            client.request("GET", "/api/v3/series")

        self.assertEqual(caught.exception.status_code, 302)
        self.assertNotIn("redirect-secret", str(caught.exception))
        self.assertEqual(target.requests, [])

    def test_post_redirects_are_rejected_without_forwarding_or_method_change(self):
        for status in (301, 302, 303):
            with self.subTest(status=status):
                target = RecordingHTTPServer()
                redirect = RedirectHTTPServer(target.url, status)
                try:
                    client = APIClient(self._mapping_for_url(redirect.url), 2)
                    with self.assertRaises(ServarrAPIError) as caught:
                        client.request(
                            "POST",
                            "/api/v3/command",
                            {"name": "RescanSeries", "seriesId": 1},
                        )
                    self.assertEqual(caught.exception.status_code, status)
                    self.assertNotIn("redirect-secret", str(caught.exception))
                    self.assertEqual(target.requests, [])
                finally:
                    redirect.close()
                    target.close()


class MatchingTests(unittest.TestCase):
    def test_path_matching_is_case_sensitive_boundary_aware_and_most_specific(self):
        records = [
            {"id": 1, "path": "/media/Show"},
            {"id": 2, "path": "/media/Show/Special"},
        ]
        self.assertEqual(
            best_path_match(records, "/media/Show/Special/file.mkv")["id"], 2
        )
        self.assertIsNone(best_path_match(records, "/media/Showcase/file.mkv"))
        self.assertIsNone(best_path_match(records, "/media/show/file.mkv"))

    def test_season_parsing_supports_directories_and_episode_names(self):
        self.assertEqual(season_number_from_path("/Show/Season 12/file.mkv"), 12)
        self.assertEqual(season_number_from_path("/Show/S03E07.mkv"), 3)
        self.assertIsNone(season_number_from_path("/Show/Specials/file.mkv"))


if __name__ == "__main__":
    unittest.main()
