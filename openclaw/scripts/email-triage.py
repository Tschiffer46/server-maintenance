#!/usr/bin/env python3
"""
Read-only IMAP triage.

For each configured inbox:
  - Open mailbox in EXAMINE mode (cannot modify flags / move / delete).
  - Find UIDs newer than the last UID seen for that inbox (state file).
  - Fetch only headers + first ~500 chars of plain-text body (minimal payload).
  - Ask Anthropic Claude to classify each as IMPORTANT | NORMAL | JUNK.
  - Send a Telegram alert for IMPORTANT messages (one per message).
  - Update state file.

First run on a fresh state file is silent: it records the current top UID
without classifying historical messages.

Constraints (security spec):
  - IMAP READ-ONLY (EXAMINE, no STORE/MOVE/EXPUNGE).
  - LLM payload limited to sender, subject, first N chars of body.
  - Full bodies are never written to disk.
  - Credentials read from ~/.openclaw-monitor/.env (mode 600).
"""

from __future__ import annotations

import email
import imaplib
import json
import os
import re
import ssl
import sys
import urllib.error
import urllib.request
from email.header import decode_header
from email.utils import parseaddr
from pathlib import Path
from typing import Iterable

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
CONF_FILE = Path(os.environ.get("EMAIL_CONF", REPO / "openclaw" / "config" / "email.conf"))
ENV_FILE = Path(os.environ.get("OPENCLAW_MONITOR_ENV", Path.home() / ".openclaw-monitor" / ".env"))
STATE_DIR = Path(os.environ.get("STATE_DIR", Path.home() / ".openclaw-monitor" / "state"))
LOG_FILE = Path(os.environ.get("LOG_FILE", Path.home() / ".openclaw-monitor" / "monitor.log"))
NOTIFY = HERE / "lib" / "notify-telegram.sh"

# Body excerpt size sent to Claude — keep small to minimise data exposure.
BODY_CHARS = 500


def log(msg: str) -> None:
    LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
    import datetime
    ts = datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
    with LOG_FILE.open("a") as f:
        f.write(f"{ts} email-triage: {msg}\n")


def parse_dotenv(path: Path) -> dict[str, str]:
    env: dict[str, str] = {}
    if not path.is_file():
        return env
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        env[k.strip()] = v.strip().strip('"').strip("'")
    return env


def parse_conf(path: Path) -> dict:
    """Parse the simple KEY=VALUE / INBOXES="..." config file."""
    text = path.read_text()
    out: dict = {}
    # Simple parser: handle KEY=VALUE and KEY="multi line"
    pattern = re.compile(r'^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(?:"([^"]*)"|(\S.*?))\s*$', re.M | re.S)
    # Pull triple-quoted-ish blocks with newlines
    inbox_match = re.search(r'^\s*INBOXES\s*=\s*"([^"]*)"\s*$', text, re.M | re.S)
    if inbox_match:
        out["INBOXES_RAW"] = inbox_match.group(1)
        text = text.replace(inbox_match.group(0), "")
    for m in pattern.finditer(text):
        k = m.group(1)
        v = m.group(2) if m.group(2) is not None else m.group(3)
        out[k] = v
    inboxes: list[tuple[str, str, str]] = []
    for line in out.get("INBOXES_RAW", "").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = [p.strip() for p in line.split("|")]
        if len(parts) != 3:
            continue
        inboxes.append((parts[0], parts[1], parts[2]))
    out["INBOXES"] = inboxes
    return out


def decode_mime_header(raw: str | None) -> str:
    if not raw:
        return ""
    try:
        parts = decode_header(raw)
    except Exception:
        return raw
    chunks: list[str] = []
    for value, charset in parts:
        if isinstance(value, bytes):
            try:
                chunks.append(value.decode(charset or "utf-8", errors="replace"))
            except (LookupError, TypeError):
                chunks.append(value.decode("utf-8", errors="replace"))
        else:
            chunks.append(value)
    return "".join(chunks).strip()


def extract_body_excerpt(msg: email.message.Message, limit: int = BODY_CHARS) -> str:
    """Return the first `limit` characters of the plain-text body."""
    text_parts: list[str] = []
    if msg.is_multipart():
        for part in msg.walk():
            ctype = part.get_content_type()
            disp = (part.get("Content-Disposition") or "").lower()
            if ctype == "text/plain" and "attachment" not in disp:
                try:
                    payload = part.get_payload(decode=True) or b""
                    charset = part.get_content_charset() or "utf-8"
                    text_parts.append(payload.decode(charset, errors="replace"))
                except Exception:
                    pass
                if sum(len(p) for p in text_parts) >= limit:
                    break
    else:
        try:
            payload = msg.get_payload(decode=True) or b""
            charset = msg.get_content_charset() or "utf-8"
            text_parts.append(payload.decode(charset, errors="replace"))
        except Exception:
            pass
    body = "\n".join(text_parts)
    # Strip excessive whitespace
    body = re.sub(r"\s+", " ", body).strip()
    return body[:limit]


def claude_classify(api_key: str, model: str, sender: str, subject: str, body: str) -> tuple[str, str]:
    """
    Call Anthropic Messages API. Returns (category, one_line_reason).
    Category is one of: IMPORTANT | NORMAL | JUNK.
    """
    prompt = (
        "Classify this email for a small business owner who runs e-commerce "
        "shops and consulting. Respond with EXACTLY this JSON:\n"
        '{"category": "IMPORTANT|NORMAL|JUNK", "reason": "<one short sentence>"}\n\n'
        "Rules:\n"
        "- IMPORTANT: customer issue, support ticket, legal/financial, security alert, "
        "personal message from a known contact, account/auth problem, urgent deadline.\n"
        "- JUNK: newsletter, marketing, promotional, cold sales outreach, automated "
        "system noise (e.g. CI logs, low-value notifications), spam.\n"
        "- NORMAL: everything else (routine transactional mail, receipts, normal updates).\n\n"
        f"From: {sender}\n"
        f"Subject: {subject}\n"
        f"Body (first {BODY_CHARS} chars):\n{body}\n"
    )
    payload = {
        "model": model,
        "max_tokens": 200,
        "messages": [{"role": "user", "content": prompt}],
    }
    req = urllib.request.Request(
        "https://api.anthropic.com/v1/messages",
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "x-api-key": api_key,
            "anthropic-version": "2023-06-01",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        data = json.loads(resp.read().decode("utf-8"))
    text = ""
    for block in data.get("content", []):
        if block.get("type") == "text":
            text += block.get("text", "")
    # Find JSON in response
    m = re.search(r"\{.*?\}", text, re.S)
    if not m:
        return "NORMAL", "(could not parse classifier response)"
    try:
        obj = json.loads(m.group(0))
    except json.JSONDecodeError:
        return "NORMAL", "(could not parse classifier response)"
    cat = (obj.get("category") or "").upper().strip()
    if cat not in {"IMPORTANT", "NORMAL", "JUNK"}:
        cat = "NORMAL"
    reason = (obj.get("reason") or "").strip()[:200]
    return cat, reason


def notify_telegram(text: str) -> bool:
    import subprocess
    try:
        subprocess.run([str(NOTIFY), text], check=True, timeout=20)
        return True
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, FileNotFoundError) as e:
        log(f"notify failed: {e}")
        return False


def html_escape(s: str) -> str:
    return (s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))


def process_inbox(
    slug: str,
    user: str,
    password: str,
    host: str,
    port: int,
    mailbox: str,
    api_key: str,
    model: str,
    max_per_run: int,
) -> None:
    state_file = STATE_DIR / f"email-{slug}.uid"
    last_uid = 0
    if state_file.is_file():
        try:
            last_uid = int(state_file.read_text().strip() or "0")
        except ValueError:
            last_uid = 0

    ctx = ssl.create_default_context()
    try:
        imap = imaplib.IMAP4_SSL(host, port, ssl_context=ctx)
    except OSError as e:
        log(f"{slug}: connect failed: {e}")
        return
    try:
        imap.login(user, password)
    except imaplib.IMAP4.error as e:
        log(f"{slug}: login failed: {e}")
        try: imap.logout()
        except Exception: pass
        return
    try:
        # readonly=True sends EXAMINE — server refuses STORE/EXPUNGE in this mode.
        # We use select(readonly=True) instead of examine() because the latter
        # raises "Unknown IMAP4 command: 'examine'" on some Python builds even
        # though it's a documented method; select is part of the same code path
        # and reliably present.
        typ, _ = imap.select(mailbox, readonly=True)
        if typ != "OK":
            log(f"{slug}: select (read-only) {mailbox} failed")
            return

        # Fetch the UID range we haven't seen yet.
        typ, data = imap.uid("search", None, "UID", f"{last_uid + 1}:*")
        if typ != "OK":
            log(f"{slug}: search failed")
            return
        uids_raw = data[0].split() if data and data[0] else []
        # IMAP returns at least one UID even when range is empty — filter.
        uids = [int(u) for u in uids_raw if int(u) > last_uid]
        uids.sort()

        first_run = last_uid == 0
        if first_run and uids:
            # Don't blast historical backlog. Just record the latest UID.
            new_top = max(uids)
            state_file.parent.mkdir(parents=True, exist_ok=True)
            state_file.write_text(str(new_top))
            log(f"{slug}: first run, recorded UID {new_top} (skipped {len(uids)} historical msgs)")
            return

        # Cap per-run to avoid runaway cost.
        if len(uids) > max_per_run:
            log(f"{slug}: capping {len(uids)} new messages to {max_per_run}")
            uids = uids[-max_per_run:]

        for uid in uids:
            try:
                typ, parts = imap.uid("fetch", str(uid), "(RFC822.HEADER BODY.PEEK[TEXT])")
            except imaplib.IMAP4.error as e:
                log(f"{slug}: fetch UID {uid} failed: {e}")
                continue
            if typ != "OK" or not parts:
                continue

            # Build a Message from the returned chunks.
            header_bytes = b""
            text_bytes = b""
            for p in parts:
                if isinstance(p, tuple) and len(p) >= 2:
                    blob = p[1]
                    if b"HEADER" in p[0]:
                        header_bytes = blob
                    elif b"TEXT" in p[0]:
                        text_bytes = blob
            if not header_bytes:
                continue
            msg = email.message_from_bytes(header_bytes + b"\r\n" + text_bytes)

            sender_raw = decode_mime_header(msg.get("From"))
            name, addr = parseaddr(sender_raw)
            sender = f"{name} <{addr}>" if name else addr or sender_raw
            subject = decode_mime_header(msg.get("Subject")) or "(no subject)"
            body = extract_body_excerpt(msg, BODY_CHARS)

            try:
                category, reason = claude_classify(api_key, model, sender, subject, body)
            except urllib.error.HTTPError as e:
                log(f"{slug}: claude HTTP {e.code} on UID {uid}; aborting batch")
                break
            except Exception as e:
                log(f"{slug}: classifier error on UID {uid}: {e}")
                category, reason = "NORMAL", "(classifier error)"

            log(f"{slug}: UID {uid} -> {category} | {subject[:80]}")

            if category == "IMPORTANT":
                text = (
                    f"📧 <b>IMPORTANT</b> [{html_escape(slug)}]\n"
                    f"<b>From:</b> {html_escape(sender)[:120]}\n"
                    f"<b>Subject:</b> {html_escape(subject)[:200]}\n"
                    f"<i>{html_escape(reason)}</i>"
                )
                notify_telegram(text)

            # Update state after each successful classification so a crash mid-batch
            # doesn't cause us to reprocess.
            state_file.parent.mkdir(parents=True, exist_ok=True)
            state_file.write_text(str(uid))
    finally:
        try: imap.logout()
        except Exception: pass


def main() -> int:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    if not CONF_FILE.is_file():
        log(f"missing config: {CONF_FILE}")
        return 1

    conf = parse_conf(CONF_FILE)
    env = parse_dotenv(ENV_FILE)
    # ANTHROPIC_API_KEY may also be in process env (from .env above; .env wins by design)
    api_key = env.get("ANTHROPIC_API_KEY") or os.environ.get("ANTHROPIC_API_KEY", "")
    if not api_key:
        log("ANTHROPIC_API_KEY missing from .env")
        return 1

    host = conf.get("IMAP_HOST", "")
    port = int(conf.get("IMAP_PORT", "993"))
    mailbox = conf.get("IMAP_MAILBOX", "INBOX")
    model = conf.get("CLASSIFIER_MODEL", "claude-haiku-4-5-20251001")
    max_per_run = int(conf.get("MAX_PER_RUN", "20"))
    inboxes: list[tuple[str, str, str]] = conf.get("INBOXES", [])

    if not host or not inboxes:
        log("config missing IMAP_HOST or INBOXES")
        return 1

    for slug, user, pass_var in inboxes:
        password = env.get(pass_var, "")
        if not password:
            log(f"{slug}: skipping (no password in {pass_var})")
            continue
        try:
            process_inbox(slug, user, password, host, port, mailbox,
                          api_key, model, max_per_run)
        except Exception as e:
            log(f"{slug}: unhandled error: {e}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
