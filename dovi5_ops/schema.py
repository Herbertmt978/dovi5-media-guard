"""Versioned SQLite schema for the durable Servarr outbox."""

from __future__ import annotations

import sqlite3

from .config import OutboxError


SCHEMA_VERSION = 2
JOB_COLUMNS = (
    "id",
    "job_key",
    "label",
    "kind",
    "config_identity",
    "canonical_path",
    "fingerprint",
    "phase",
    "entity_id",
    "entity_path",
    "season_number",
    "command_id",
    "attempts",
    "last_error",
    "created_at",
    "updated_at",
)
CREATE_JOBS_SQL = """
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
                'queued', 'resolved', 'rescan_waiting', 'search_ready',
                'search_waiting', 'superseded'
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
    )
"""


def _validate_columns(connection: sqlite3.Connection) -> None:
    columns = {row[1] for row in connection.execute("PRAGMA table_info(jobs)")}
    if columns != set(JOB_COLUMNS):
        raise OutboxError("outbox jobs schema does not match its declared version")


def _migrate_v1(connection: sqlite3.Connection) -> None:
    columns = ", ".join(JOB_COLUMNS)
    connection.execute("BEGIN IMMEDIATE")
    try:
        connection.execute("ALTER TABLE jobs RENAME TO jobs_v1")
        connection.execute("DROP INDEX jobs_active_phase")
        connection.execute(CREATE_JOBS_SQL)
        connection.execute("CREATE INDEX jobs_active_phase ON jobs(phase, label)")
        # JOB_COLUMNS is a fixed internal tuple, never input-derived.
        migration_sql = f"INSERT INTO jobs ({columns}) SELECT {columns} FROM jobs_v1"  # nosec B608
        connection.execute(migration_sql)
        connection.execute("DROP TABLE jobs_v1")
        connection.execute(f"PRAGMA user_version={SCHEMA_VERSION}")
        connection.commit()
    except Exception:
        connection.rollback()
        raise


def initialize_schema(connection: sqlite3.Connection) -> None:
    version = connection.execute("PRAGMA user_version").fetchone()[0]
    if version == 0:
        tables = {
            row[0]
            for row in connection.execute(
                "SELECT name FROM sqlite_master "
                "WHERE type='table' AND name NOT LIKE 'sqlite_%'"
            )
        }
        if tables:
            raise OutboxError("unversioned outbox schema is not trusted")
        connection.execute("BEGIN IMMEDIATE")
        try:
            connection.execute(CREATE_JOBS_SQL)
            connection.execute("CREATE INDEX jobs_active_phase ON jobs(phase, label)")
            connection.execute(f"PRAGMA user_version={SCHEMA_VERSION}")
            connection.commit()
        except Exception:
            connection.rollback()
            raise
        version = SCHEMA_VERSION
    if version == 1:
        _validate_columns(connection)
        _migrate_v1(connection)
        version = SCHEMA_VERSION
    if version != SCHEMA_VERSION:
        raise OutboxError(
            f"unsupported outbox schema version {version}; expected {SCHEMA_VERSION}"
        )
    _validate_columns(connection)
    synchronous = connection.execute("PRAGMA synchronous").fetchone()[0]
    if synchronous != 2:
        raise OutboxError("SQLite synchronous=FULL could not be enabled")
