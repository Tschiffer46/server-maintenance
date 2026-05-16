#!/usr/bin/env python3
"""
08:00 morning digest.

Queries the SQLite events DB for the last 24 hours and posts a single summary
message to Telegram. No external service calls. Designed to be cheap and
deterministic; the body is built directly from event rows.

Schema (created by lib/log-event.py and email-triage.py):
    events(id, ts, kind, severity, source, message)
        kind:      site | ssl | infra | email
        severity:  site:     down | recovered
                   ssl:      warn
                   infra:    warn | crit | bad-* | recovered
                   email:    important | normal | junk
"""
from __future__ import annotations

import datetime as dt
import os
import sqlite3
import subprocess
from collections import Counter, defaultdict
from pathlib import Path

HERE = Path(__file__).resolve().parent
DB = Path(os.environ.get("EVENTS_DB", Path.home() / ".openclaw-monitor" / "events.db"))
NOTIFY = HERE / "lib" / "notify-telegram.sh"
WINDOW_HOURS = int(os.environ.get("DIGEST_WINDOW_HOURS", "24"))
MAX_LINES_PER_SECTION = 8  # cap noisy sections so the message stays readable


def html_escape(s: str) -> str:
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def fetch_events(db: Path, since_iso: str) -> list[tuple[str, str, str, str, str]]:
    if not db.is_file():
        return []
    with sqlite3.connect(str(db)) as conn:
        rows = conn.execute(
            "SELECT ts, kind, severity, source, message FROM events "
            "WHERE ts >= ? ORDER BY ts ASC",
            (since_iso,),
        ).fetchall()
    return rows


def format_digest(rows: list[tuple[str, str, str, str, str]], window_h: int) -> str:
    now_local = dt.datetime.now().astimezone()
    date_str = now_local.strftime("%a %d %b %Y, %H:%M %Z")

    head = f"🌅 <b>Morning digest</b> — {html_escape(date_str)}\n(last {window_h}h)"

    if not rows:
        return head + "\n\n<i>No events recorded. Quiet night.</i>"

    by_kind: dict[str, list[tuple[str, str, str, str]]] = defaultdict(list)
    for ts, kind, severity, source, message in rows:
        by_kind[kind].append((ts, severity, source, message))

    sections: list[str] = []

    # --- sites ---
    if "site" in by_kind:
        downs = [r for r in by_kind["site"] if r[1] == "down"]
        recovers = [r for r in by_kind["site"] if r[1] == "recovered"]
        line = f"<b>🌐 Sites</b>: {len(downs)} down / {len(recovers)} recovered"
        sub: list[str] = []
        for ts, sev, source, msg in (downs + recovers)[-MAX_LINES_PER_SECTION:]:
            icon = "🚨" if sev == "down" else "✅"
            t = ts[11:16]  # HH:MM
            sub.append(f"  {icon} {t} {html_escape(source)} — {html_escape(msg)}")
        sections.append(line + ("\n" + "\n".join(sub) if sub else ""))

    # --- ssl ---
    if "ssl" in by_kind:
        items = by_kind["ssl"]
        line = f"<b>🔒 SSL</b>: {len(items)} expiring warning(s)"
        sub = []
        for ts, sev, source, msg in items[-MAX_LINES_PER_SECTION:]:
            sub.append(f"  ⚠️ {html_escape(source)} — {html_escape(msg)}")
        sections.append(line + ("\n" + "\n".join(sub) if sub else ""))

    # --- infra ---
    if "infra" in by_kind:
        items = by_kind["infra"]
        sev_counts = Counter(sev for _, sev, _, _ in items)
        bits = ", ".join(f"{n}× {sev}" for sev, n in sev_counts.items())
        line = f"<b>🖥 Server</b>: {len(items)} event(s) ({bits})"
        sub = []
        for ts, sev, source, msg in items[-MAX_LINES_PER_SECTION:]:
            icon = "✅" if sev == "recovered" else "🚨"
            t = ts[11:16]
            sub.append(f"  {icon} {t} {html_escape(source)} — {html_escape(msg)}")
        sections.append(line + ("\n" + "\n".join(sub) if sub else ""))

    # --- email ---
    if "email" in by_kind:
        items = by_kind["email"]
        sev_counts = Counter(sev for _, sev, _, _ in items)
        important_n = sev_counts.get("important", 0)
        normal_n = sev_counts.get("normal", 0)
        junk_n = sev_counts.get("junk", 0)
        line = (
            f"<b>📧 Email</b>: {len(items)} classified "
            f"({important_n} important · {normal_n} normal · {junk_n} junk)"
        )
        sub = []
        # Only list the important ones in the digest (junk/normal is noise).
        for ts, sev, source, msg in items:
            if sev != "important":
                continue
            t = ts[11:16]
            sub.append(f"  📧 {t} [{html_escape(source)}] {html_escape(msg)[:160]}")
        sub = sub[-MAX_LINES_PER_SECTION:]
        sections.append(line + ("\n" + "\n".join(sub) if sub else ""))

    return head + "\n\n" + "\n\n".join(sections)


def main() -> int:
    since = dt.datetime.now(dt.timezone.utc) - dt.timedelta(hours=WINDOW_HOURS)
    since_iso = since.strftime("%Y-%m-%dT%H:%M:%SZ")
    rows = fetch_events(DB, since_iso)
    body = format_digest(rows, WINDOW_HOURS)
    try:
        subprocess.run([str(NOTIFY), body], check=True, timeout=20)
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, FileNotFoundError) as e:
        print(f"notify failed: {e}", file=__import__("sys").stderr)
        return 1
    return 0


if __name__ == "__main__":
    import sys
    sys.exit(main())
