#!/usr/bin/env python3
"""Durable Servarr recovery outbox for deleted Dolby Vision Profile 5 media.

Servarr command delivery is intentionally at least once. If the remote API accepts a
rescan or search and the process exits before the acceptance is committed locally, a
later drain repeats the command rather than risking a lost recovery request.
"""

from __future__ import annotations

import argparse
import json
import os
import sqlite3
import sys
from typing import Optional, Sequence

from dovi5_ops.config import (
    DEFAULT_API_TIMEOUT,
    DEFAULT_SUPERSEDED_RETENTION_SECONDS,
    MAX_SUPERSEDED_RETENTION_SECONDS,
    Config,
    ConfigurationError,
    MappingConfig,
    OutboxError,
    ServarrAPIError,
    load_config,
)
from dovi5_ops.outbox import (
    ACTIVE_PHASES,
    DEFAULT_DB,
    SCHEMA_VERSION,
    Fingerprint,
    Outbox,
)
from dovi5_ops.servarr import (
    APIClient,
    best_path_match,
    season_number_from_path,
    verify_api,
)


__all__ = [
    "ACTIVE_PHASES",
    "APIClient",
    "Config",
    "ConfigurationError",
    "DEFAULT_API_TIMEOUT",
    "DEFAULT_DB",
    "DEFAULT_SUPERSEDED_RETENTION_SECONDS",
    "Fingerprint",
    "MAX_SUPERSEDED_RETENTION_SECONDS",
    "MappingConfig",
    "Outbox",
    "OutboxError",
    "SCHEMA_VERSION",
    "ServarrAPIError",
    "best_path_match",
    "load_config",
    "main",
    "season_number_from_path",
    "verify_api",
]


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", default=os.environ.get("SERVARR_OUTBOX_DB", DEFAULT_DB))
    parser.add_argument("--env-file")
    subparsers = parser.add_subparsers(dest="operation", required=True)

    check = subparsers.add_parser("check-config")
    check.add_argument("--verify-api", action="store_true")

    enqueue_parser = subparsers.add_parser("enqueue")
    enqueue_parser.add_argument("--label", required=True)
    enqueue_parser.add_argument("--path", required=True)
    enqueue_parser.add_argument("--fingerprint", required=True)

    cancel_parser = subparsers.add_parser("cancel")
    cancel_parser.add_argument("--job-id", type=int, required=True)
    cancel_parser.add_argument(
        "--reason", default="source changed before destructive operation"
    )

    subparsers.add_parser("drain")
    subparsers.add_parser("count")
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = _build_parser()
    args = parser.parse_args(argv)
    try:
        if args.operation == "check-config":
            config = load_config(env_file=args.env_file)
            if args.verify_api:
                verify_api(config)
            print(
                json.dumps(
                    {
                        "configured": sorted(config.mappings),
                        "api_verified": bool(args.verify_api),
                    },
                    sort_keys=True,
                )
            )
            return 0
        if args.operation == "count":
            with Outbox(args.db) as outbox:
                print(json.dumps(outbox.count(), sort_keys=True))
            return 0

        config = load_config(env_file=args.env_file)
        dry_run = os.environ.get("SERVARR_DRY_RUN", "0") == "1"
        with Outbox(args.db, config, dry_run=dry_run) as outbox:
            if args.operation == "enqueue":
                job_id = outbox.enqueue(
                    args.label,
                    args.path,
                    Fingerprint.parse(args.fingerprint),
                )
                print(job_id)
                return 0
            if args.operation == "cancel":
                outbox.cancel(args.job_id, args.reason)
                print(json.dumps({"cancelled": args.job_id}, sort_keys=True))
                return 0
            if args.operation == "drain":
                result = outbox.drain()
                print(json.dumps(result, sort_keys=True))
                return 1 if result["errors"] else 0
    except (ConfigurationError, OutboxError, OSError, sqlite3.DatabaseError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2
    parser.error("unsupported operation")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
