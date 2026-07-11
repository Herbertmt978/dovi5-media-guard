"""Servarr HTTP transport and catalog path helpers."""

from __future__ import annotations

import json
import re
import urllib.error
import urllib.request
from typing import Any, Iterable, Mapping, Optional

from .config import (
    Config,
    ConfigurationError,
    MappingConfig,
    ServarrAPIError,
    _slash_path,
)


class _RejectRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, _req, _fp, _code, _msg, _headers, _newurl):
        return None


class APIClient:
    def __init__(self, mapping: MappingConfig, timeout: float):
        self.mapping = mapping
        self.timeout = timeout
        self.opener = urllib.request.build_opener(_RejectRedirects())

    def request(
        self,
        method: str,
        endpoint: str,
        payload: Optional[Mapping[str, Any]] = None,
    ) -> Any:
        data = None
        if payload is not None:
            data = json.dumps(payload).encode("utf-8")
        request = urllib.request.Request(
            f"{self.mapping.url}{endpoint}",
            data=data,
            headers={
                "Content-Type": "application/json",
                "X-Api-Key": self.mapping.api_key,
            },
            method=method,
        )
        try:
            with self.opener.open(request, timeout=self.timeout) as response:
                body = response.read()
        except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError) as exc:
            status_code = exc.code if isinstance(exc, urllib.error.HTTPError) else None
            reason = getattr(exc, "reason", None)
            if status_code is not None:
                detail = f": HTTP {status_code}"
            elif reason is not None:
                detail = f": {reason}"
            else:
                detail = ""
            if isinstance(exc, urllib.error.HTTPError):
                exc.close()
            raise ServarrAPIError(
                f"{self.mapping.kind} {method} {endpoint} failed{detail}",
                status_code=status_code,
            ) from exc
        if not body:
            return None
        try:
            return json.loads(body.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise ServarrAPIError(
                f"{self.mapping.kind} {method} {endpoint} returned invalid JSON"
            ) from exc


def verify_api(config: Config) -> None:
    grouped: dict[tuple[str, str], list[MappingConfig]] = {}
    for mapping in config.mappings.values():
        grouped.setdefault((mapping.kind, mapping.url), []).append(mapping)
    for mappings in grouped.values():
        client = APIClient(mappings[0], config.api_timeout)
        status = client.request("GET", "/api/v3/system/status")
        if not isinstance(status, dict):
            raise ConfigurationError(
                f"{mappings[0].kind} system status response is invalid"
            )
        roots = client.request("GET", "/api/v3/rootfolder")
        if not isinstance(roots, list):
            raise ConfigurationError(
                f"{mappings[0].kind} root-folder response is invalid"
            )
        available = {
            _slash_path(str(record.get("path", "")))
            for record in roots
            if isinstance(record, dict) and record.get("path")
        }
        for mapping in mappings:
            if _slash_path(mapping.root) not in available:
                raise ConfigurationError(
                    f"{mapping.label} root is not configured in {mapping.kind}"
                )


def best_path_match(records: Iterable[Mapping[str, Any]], media_path: str):
    normalized_file = _slash_path(media_path)
    matches = []
    for record in records:
        record_path = record.get("path")
        if not isinstance(record_path, str) or not record_path:
            continue
        normalized_root = _slash_path(record_path)
        if normalized_file == normalized_root or normalized_file.startswith(
            f"{normalized_root}/"
        ):
            matches.append((len(normalized_root), record))
    if not matches:
        return None
    return max(matches, key=lambda item: item[0])[1]


def season_number_from_path(path: str) -> Optional[int]:
    for pattern in (
        r"(?:^|[\\/ ])Season[ ._-]*(\d+)(?:[\\/ ]|$)",
        r"(?:^|[^A-Za-z0-9])[Ss](\d{1,3})[Ee]\d{1,4}(?:[^0-9]|$)",
    ):
        match = re.search(pattern, path)
        if match:
            return int(match.group(1))
    return None
