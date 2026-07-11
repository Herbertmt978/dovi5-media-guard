"""Static configuration and path identity for DoVi5 recovery operations."""

from __future__ import annotations

import hashlib
import os
import re
import shlex
import urllib.parse
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Mapping, Optional


DEFAULT_API_TIMEOUT = 30.0
DEFAULT_SUPERSEDED_RETENTION_SECONDS = 30 * 24 * 60 * 60
MAX_SUPERSEDED_RETENTION_SECONDS = 10 * 365 * 24 * 60 * 60


class OutboxError(RuntimeError):
    """An outbox operation could not be completed safely."""


class ConfigurationError(OutboxError):
    """Static or verified Servarr configuration is invalid."""


class ServarrAPIError(OutboxError):
    """A Servarr API request failed without exposing its credential."""

    def __init__(self, message: str, *, status_code: Optional[int] = None):
        super().__init__(message)
        self.status_code = status_code


@dataclass(frozen=True)
class MappingConfig:
    label: str
    kind: str
    root: str
    url: str
    api_key: str
    config_identity: str


@dataclass(frozen=True)
class Config:
    mappings: Mapping[str, MappingConfig]
    api_timeout: float = DEFAULT_API_TIMEOUT
    superseded_retention_seconds: int = DEFAULT_SUPERSEDED_RETENTION_SECONDS

    def mapping(self, label: str) -> MappingConfig:
        try:
            return self.mappings[label]
        except KeyError as exc:
            raise ConfigurationError(f"unknown Servarr label: {label}") from exc


MAPPING_SPECS = (
    (
        "PlexTV",
        "sonarr",
        "PLEX_TV_DIR",
        "SONARR_TV_URL",
        "SONARR_TV_API_KEY",
    ),
    (
        "PlexTVHD",
        "sonarr",
        "PLEX_TVHD_DIR",
        "SONARR_TVHD_URL",
        "SONARR_TVHD_API_KEY",
    ),
    (
        "PlexFilms",
        "radarr",
        "PLEX_FILMS_DIR",
        "RADARR_FILMS_URL",
        "RADARR_FILMS_API_KEY",
    ),
    (
        "PlexFilmsHD",
        "radarr",
        "PLEX_FILMSHD_DIR",
        "RADARR_FILMSHD_URL",
        "RADARR_FILMSHD_API_KEY",
    ),
)


def _read_env_file(path: os.PathLike[str] | str) -> dict[str, str]:
    values: dict[str, str] = {}
    try:
        lines = Path(path).read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        raise ConfigurationError(f"cannot read environment file: {exc}") from exc
    for number, original in enumerate(lines, 1):
        line = original.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[7:].lstrip()
        if "=" not in line:
            raise ConfigurationError(f"malformed environment file line {number}")
        name, raw_value = line.split("=", 1)
        name = name.strip()
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name):
            raise ConfigurationError(f"invalid environment name on line {number}")
        try:
            parsed = shlex.split(raw_value, comments=True, posix=True)
        except ValueError as exc:
            raise ConfigurationError(
                f"malformed environment file value on line {number}"
            ) from exc
        if len(parsed) > 1:
            raise ConfigurationError(
                f"environment file value has unquoted whitespace on line {number}"
            )
        values[name] = parsed[0] if parsed else ""
    return values


def _required(values: Mapping[str, str], name: str) -> str:
    value = values.get(name, "").strip()
    if not value:
        raise ConfigurationError(f"required setting {name} is blank")
    return value


def _canonical(path: os.PathLike[str] | str) -> str:
    return os.path.realpath(os.path.abspath(os.fspath(path)))


def _slash_path(path: str) -> str:
    normalized = path.replace("\\", "/")
    if normalized == "/":
        return normalized
    return normalized.rstrip("/")


def _path_within(path: str, root: str, *, allow_equal: bool = True) -> bool:
    normalized_path = _slash_path(path)
    normalized_root = _slash_path(root)
    if allow_equal and normalized_path == normalized_root:
        return True
    return normalized_path.startswith(f"{normalized_root}/")


def _validate_distinct_roots(mappings: Iterable[MappingConfig]) -> None:
    items = list(mappings)
    for index, first in enumerate(items):
        for second in items[index + 1 :]:
            if _path_within(first.root, second.root) or _path_within(
                second.root, first.root
            ):
                raise ConfigurationError(
                    f"library roots overlap: {first.label} and {second.label}"
                )


def _mapping_identity(kind: str, root: str, url: str) -> str:
    digest = hashlib.sha256()
    digest.update(b"dovi5-servarr-config-v1\0")
    for value in (kind, root, url):
        digest.update(value.encode("utf-8", errors="surrogateescape"))
        digest.update(b"\0")
    return digest.hexdigest()


def load_config(
    environ: Optional[Mapping[str, str]] = None,
    env_file: Optional[os.PathLike[str] | str] = None,
) -> Config:
    values: dict[str, str] = {}
    if env_file is not None:
        values.update(_read_env_file(env_file))
    values.update(dict(os.environ if environ is None else environ))

    mappings: dict[str, MappingConfig] = {}
    for label, kind, root_name, url_name, key_name in MAPPING_SPECS:
        root = _required(values, root_name)
        if not os.path.isabs(root):
            raise ConfigurationError(f"{root_name} must be an absolute path")
        url = _required(values, url_name).rstrip("/")
        if any(ord(character) < 32 for character in url):
            raise ConfigurationError(f"{url_name} cannot contain control characters")
        try:
            parsed = urllib.parse.urlsplit(url)
        except ValueError as exc:
            raise ConfigurationError(f"{url_name} is malformed") from exc
        if parsed.scheme not in {"http", "https"} or not parsed.hostname:
            raise ConfigurationError(f"{url_name} must be an http(s) URL")
        if parsed.username is not None or parsed.password is not None:
            raise ConfigurationError(f"{url_name} cannot contain user information")
        if "?" in url or "#" in url:
            raise ConfigurationError(f"{url_name} cannot contain a query or fragment")
        try:
            parsed.port
        except ValueError as exc:
            raise ConfigurationError(f"{url_name} contains an invalid port") from exc
        canonical_root = _canonical(root)
        mappings[label] = MappingConfig(
            label=label,
            kind=kind,
            root=canonical_root,
            url=url,
            api_key=_required(values, key_name),
            config_identity=_mapping_identity(kind, canonical_root, url),
        )

    _validate_distinct_roots(mappings.values())
    timeout_text = values.get(
        "SERVARR_API_TIMEOUT_SECONDS", str(DEFAULT_API_TIMEOUT)
    ).strip()
    try:
        timeout = float(timeout_text)
    except ValueError as exc:
        raise ConfigurationError("SERVARR_API_TIMEOUT_SECONDS must be numeric") from exc
    if timeout <= 0:
        raise ConfigurationError("SERVARR_API_TIMEOUT_SECONDS must be positive")
    retention_text = values.get(
        "SERVARR_SUPERSEDED_RETENTION_SECONDS",
        str(DEFAULT_SUPERSEDED_RETENTION_SECONDS),
    ).strip()
    try:
        retention = int(retention_text)
    except ValueError as exc:
        raise ConfigurationError(
            "SERVARR_SUPERSEDED_RETENTION_SECONDS must be an integer"
        ) from exc
    if retention <= 0 or retention > MAX_SUPERSEDED_RETENTION_SECONDS:
        raise ConfigurationError(
            "SERVARR_SUPERSEDED_RETENTION_SECONDS is outside the supported range"
        )
    return Config(
        mappings=mappings,
        api_timeout=timeout,
        superseded_retention_seconds=retention,
    )
