#!/usr/bin/env python3
"""
Append one event row to the SQLite events DB.

Usage:
    log-event.py KIND SEVERITY SOURCE MESSAGE

Schema (auto-created):
    events(id PK, ts UTC ISO8601, kind, severity, source, message)

Designed to be called from shell scripts. Quiet on success.
"""
from __future__ import annotations

import datetime
import os
import sqlite3
import sys
from pathlib import Path

DB = Path(os.environ.get("EVENTS_DB", Path.home() / ".openclaw-monitor" / "events.db"))


def init(conn: sqlite3.Connection) -> None:
    conn.execute(
        """CREATE TABLE IF NOT EXISTS events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ts TEXT NOT NULL,
            kind TEXT NOT NULL,
            severity TEXT NOT NULL,
            source TEXT NOT NULL,
            message TEXT NOT NULL
        )"""
    )
    conn.execute("CREATE INDEX IF NOT EXISTS idx_events_ts ON events (ts)")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_events_kind_ts ON events (kind, ts)")


def main() -> int:
    if len(sys.argv) != 5:
        print("usage: log-event.py KIND SEVERITY SOURCE MESSAGE", file=sys.stderr)
        return 2
    kind, severity, source, message = sys.argv[1:5]
    DB.parent.mkdir(parents=True, exist_ok=True)
    ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    with sqlite3.connect(str(DB)) as conn:
        init(conn)
        conn.execute(
            "INSERT INTO events (ts, kind, severity, source, message) VALUES (?, ?, ?, ?, ?)",
            (ts, kind, severity, source, message),
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
