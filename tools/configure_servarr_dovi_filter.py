#!/usr/bin/env python3
"""Configure Sonarr/Radarr to reject DV web releases without HDR fallback."""

from __future__ import annotations

import argparse
import json
import os
import secrets
import stat
import urllib.parse
import urllib.request
from datetime import datetime
from pathlib import Path
from typing import Any

FORMAT_NAME = "DV (w/o HDR fallback)"
DEFAULT_SCORE = -10000


class _RejectRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, _req, _fp, _code, _msg, _headers, _newurl):
        return None


HTTP_OPENER = urllib.request.build_opener(_RejectRedirects())


def validate_base_url(base_url: str) -> str:
    if not base_url or base_url != base_url.strip():
        raise ValueError("Servarr base URL cannot be blank or contain outer whitespace")
    if any(ord(character) < 32 for character in base_url):
        raise ValueError("Servarr base URL cannot contain control characters")

    parsed = urllib.parse.urlsplit(base_url)
    if parsed.scheme.lower() not in {"http", "https"} or not parsed.hostname:
        raise ValueError("Servarr base URL must be an HTTP(S) URL with a host")
    if parsed.username is not None or parsed.password is not None:
        raise ValueError("Servarr base URL cannot contain user information")
    if "?" in base_url or "#" in base_url:
        raise ValueError("Servarr base URL cannot contain a query or fragment")
    try:
        parsed.port
    except ValueError as exc:
        raise ValueError("Servarr base URL contains an invalid port") from exc
    return base_url.rstrip("/")


def parse_env(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip().strip('"').strip("'")
    return values


def api_request(
    base_url: str, api_key: str, method: str, endpoint: str, payload: Any = None
) -> Any:
    base_url = validate_base_url(base_url)
    body = None if payload is None else json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        base_url + endpoint,
        data=body,
        method=method,
        headers={
            "Accept": "application/json",
            "Content-Type": "application/json",
            "X-Api-Key": api_key,
        },
    )
    with HTTP_OPENER.open(request, timeout=45) as response:
        data = response.read()
    return None if not data else json.loads(data.decode("utf-8"))


def field(name: str, value: Any) -> dict[str, Any]:
    return {"name": name, "value": value}


def spec(
    name: str,
    implementation: str,
    *,
    value: Any,
    negate: bool = False,
    required: bool = False,
) -> dict[str, Any]:
    return {
        "name": name,
        "implementation": implementation,
        "negate": negate,
        "required": required,
        "fields": [field("value", value)],
    }


def custom_format_payload(kind: str) -> dict[str, Any]:
    if kind == "sonarr":
        source_specs = [
            spec("WEB", "SourceSpecification", value=3),
            spec("WEBRIP", "SourceSpecification", value=4),
        ]
    elif kind == "radarr":
        source_specs = [
            spec("WEBDL", "SourceSpecification", value=7),
            spec("WEBRIP", "SourceSpecification", value=8),
        ]
    else:
        raise ValueError(f"Unsupported Servarr kind: {kind}")

    return {
        "name": FORMAT_NAME,
        "includeCustomFormatWhenRenaming": False,
        "specifications": [
            spec(
                "Dolby Vision",
                "ReleaseTitleSpecification",
                value=r"\b(dv|dovi|dolby[ ._-]?v(ision)?)\b",
                required=True,
            ),
            *source_specs,
            spec(
                "Not RlsGrp",
                "ReleaseGroupSpecification",
                value=r"\b(Flights)\b",
                negate=True,
                required=True,
            ),
            spec(
                "Not HDR",
                "ReleaseTitleSpecification",
                value=r"\bHDR(\b|\d)",
                negate=True,
                required=True,
            ),
            spec(
                "Not Hulu",
                "ReleaseTitleSpecification",
                value=r"\b(hulu)\b",
                negate=True,
                required=True,
            ),
        ],
    }


def instances_from_env(
    values: dict[str, str], include_hd_instances: bool
) -> list[dict[str, str]]:
    instances = [
        {
            "kind": "sonarr",
            "label": "PlexTV",
            "url": values.get("SONARR_TV_URL", ""),
            "api_key": values.get("SONARR_TV_API_KEY", ""),
        },
        {
            "kind": "radarr",
            "label": "PlexFilms",
            "url": values.get("RADARR_FILMS_URL", ""),
            "api_key": values.get("RADARR_FILMS_API_KEY", ""),
        },
    ]
    if include_hd_instances:
        instances.extend(
            [
                {
                    "kind": "sonarr",
                    "label": "PlexTVHD",
                    "url": values.get("SONARR_TVHD_URL", ""),
                    "api_key": values.get("SONARR_TVHD_API_KEY", ""),
                },
                {
                    "kind": "radarr",
                    "label": "PlexFilmsHD",
                    "url": values.get("RADARR_FILMSHD_URL", ""),
                    "api_key": values.get("RADARR_FILMSHD_API_KEY", ""),
                },
            ]
        )
    return instances


def allowed_quality_names(profile: dict[str, Any]) -> list[str]:
    names: list[str] = []
    for item in profile.get("items", []):
        if item.get("allowed") is False:
            continue
        if item.get("quality"):
            names.append(item["quality"].get("name", ""))
        for child in item.get("items", []) or []:
            if child.get("allowed") is False:
                continue
            if child.get("quality"):
                names.append(child["quality"].get("name", ""))
    return names


def has_2160(profile: dict[str, Any]) -> bool:
    return any(
        "2160" in name or "UHD" in name.upper()
        for name in allowed_quality_names(profile)
    )


InstanceKey = tuple[str, str]
InstanceSnapshot = dict[str, Any]


def instance_key(instance: dict[str, str]) -> InstanceKey:
    return instance["kind"], instance["label"]


def collect_state(
    instances: list[dict[str, str]],
) -> dict[InstanceKey, InstanceSnapshot]:
    """Fetch each configured instance once for backup and subsequent updates."""
    snapshots: dict[InstanceKey, InstanceSnapshot] = {}
    for instance in instances:
        if not instance["url"] or not instance["api_key"]:
            continue
        snapshots[instance_key(instance)] = {
            "customFormats": api_request(
                instance["url"], instance["api_key"], "GET", "/api/v3/customformat"
            ),
            "qualityProfiles": api_request(
                instance["url"], instance["api_key"], "GET", "/api/v3/qualityprofile"
            ),
        }
    return snapshots


def backup_state(
    instances: list[dict[str, str]],
    backup_dir: Path,
    *,
    snapshots: dict[InstanceKey, InstanceSnapshot] | None = None,
) -> Path:
    if snapshots is None:
        snapshots = collect_state(instances)
    backup = {
        "createdAt": datetime.now().isoformat(timespec="seconds"),
        "instances": [],
    }
    for instance in instances:
        snapshot = snapshots.get(instance_key(instance))
        if snapshot is None:
            continue
        backup["instances"].append(
            {
                "kind": instance["kind"],
                "label": instance["label"],
                **snapshot,
            }
        )

    payload = (json.dumps(backup, indent=2) + "\n").encode("utf-8")
    backup_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    filename = (
        "servarr-dovi-profile-backup-"
        f"{datetime.now().strftime('%Y%m%d-%H%M%S')}-"
        f"{secrets.token_hex(16)}.json"
    )
    backup_path = backup_dir / filename

    nofollow = getattr(os, "O_NOFOLLOW", 0)
    cloexec = getattr(os, "O_CLOEXEC", 0)
    directory = getattr(os, "O_DIRECTORY", 0)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | nofollow | cloexec
    directory_fd = None
    backup_fd = None
    created = False
    try:
        if os.name == "posix":
            if not nofollow or not directory:
                raise OSError("secure no-follow backup primitives are unavailable")
            directory_fd = os.open(
                backup_dir,
                os.O_RDONLY | directory | nofollow | cloexec,
            )
            if not stat.S_ISDIR(os.fstat(directory_fd).st_mode):
                raise OSError("backup destination is not a directory")
            backup_fd = os.open(filename, flags, 0o600, dir_fd=directory_fd)
        else:
            is_junction = getattr(os.path, "isjunction", lambda _path: False)
            if backup_dir.is_symlink() or is_junction(backup_dir):
                raise OSError("backup destination cannot be a link or junction")
            backup_fd = os.open(backup_path, flags, 0o600)
        created = True

        remaining = memoryview(payload)
        while remaining:
            written = os.write(backup_fd, remaining)
            if written <= 0:
                raise OSError("backup write failed")
            remaining = remaining[written:]
        if os.name == "posix":
            os.fchmod(backup_fd, 0o600)
        os.fsync(backup_fd)
        closing_fd = backup_fd
        backup_fd = None
        os.close(closing_fd)
        if directory_fd is not None:
            os.fsync(directory_fd)
    except BaseException:
        if backup_fd is not None:
            closing_fd = backup_fd
            backup_fd = None
            try:
                os.close(closing_fd)
            except OSError:
                pass
        if created:
            try:
                if directory_fd is not None:
                    os.unlink(filename, dir_fd=directory_fd)
                else:
                    backup_path.unlink()
            except OSError:
                pass
        if directory_fd is not None:
            closing_fd = directory_fd
            directory_fd = None
            try:
                os.close(closing_fd)
            except OSError:
                pass
        raise
    if directory_fd is not None:
        closing_fd = directory_fd
        directory_fd = None
        os.close(closing_fd)
    return backup_path


def configure_instance(
    instance: dict[str, str],
    score: int,
    apply: bool,
    *,
    snapshot: InstanceSnapshot | None = None,
) -> list[str]:
    kind = instance["kind"]
    label = instance["label"]
    base_url = instance["url"]
    api_key = instance["api_key"]
    prefix = f"{kind} {label}:"

    if not base_url or not api_key:
        return [f"{prefix} skipped, API is not configured"]

    if snapshot is None:
        snapshot = {
            "customFormats": api_request(
                base_url, api_key, "GET", "/api/v3/customformat"
            ),
            "qualityProfiles": api_request(
                base_url, api_key, "GET", "/api/v3/qualityprofile"
            ),
        }
    custom_formats = snapshot["customFormats"]
    profiles = snapshot["qualityProfiles"]
    existing = next(
        (item for item in custom_formats if item.get("name") == FORMAT_NAME), None
    )
    payload = custom_format_payload(kind)
    messages = []

    if apply:
        if existing:
            payload["id"] = existing["id"]
            custom_format = api_request(
                base_url,
                api_key,
                "PUT",
                f"/api/v3/customformat/{existing['id']}",
                payload,
            )
            messages.append(f"{prefix} updated custom format id={custom_format['id']}")
        else:
            custom_format = api_request(
                base_url, api_key, "POST", "/api/v3/customformat", payload
            )
            messages.append(f"{prefix} created custom format id={custom_format['id']}")
        custom_format_id = custom_format["id"]
    else:
        custom_format_id = existing["id"] if existing else None
        action = "would update" if existing else "would create"
        messages.append(f"{prefix} {action} custom format {FORMAT_NAME}")

    touched = []
    for profile in profiles:
        if not has_2160(profile):
            continue
        touched.append(f"{profile['name']}#{profile['id']}")
        if not apply or custom_format_id is None:
            continue
        format_items = profile.setdefault("formatItems", [])
        item = next(
            (
                entry
                for entry in format_items
                if entry.get("format") == custom_format_id
            ),
            None,
        )
        changed = False
        if item:
            if item.get("name") != FORMAT_NAME or item.get("score") != score:
                item["name"] = FORMAT_NAME
                item["score"] = score
                changed = True
        else:
            format_items.append(
                {"format": custom_format_id, "name": FORMAT_NAME, "score": score}
            )
            changed = True
        if changed:
            api_request(
                base_url,
                api_key,
                "PUT",
                f"/api/v3/qualityprofile/{profile['id']}",
                profile,
            )

    verb = "applied" if apply else "would apply"
    messages.append(
        f"{prefix} {verb} score {score} to {len(touched)} 2160p profile(s): {', '.join(touched)}"
    )
    return messages


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--env-file", default="/home/frigate/dovi5-frigate-ops.env", type=Path
    )
    parser.add_argument(
        "--backup-dir", default="/mnt/media/_orphaned_quarantine", type=Path
    )
    parser.add_argument("--score", default=DEFAULT_SCORE, type=int)
    parser.add_argument(
        "--apply",
        action="store_true",
        help="Apply changes. Without this, only prints a dry run.",
    )
    parser.add_argument(
        "--include-hd-instances",
        action="store_true",
        help="Also touch PlexTVHD and PlexFilmsHD.",
    )
    args = parser.parse_args()

    values = parse_env(args.env_file)
    instances = instances_from_env(values, args.include_hd_instances)

    snapshots = collect_state(instances) if args.apply else None
    if snapshots is not None:
        backup_path = backup_state(instances, args.backup_dir, snapshots=snapshots)
        print(f"backup={backup_path}")
    else:
        print("dry-run: pass --apply to change Sonarr/Radarr")

    for instance in instances:
        snapshot = (
            snapshots.get(instance_key(instance)) if snapshots is not None else None
        )
        for message in configure_instance(
            instance, args.score, args.apply, snapshot=snapshot
        ):
            print(message)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
