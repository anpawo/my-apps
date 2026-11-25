#!/usr/bin/env python3
import fcntl
import hashlib
import json
import os
import sqlite3
import stat
import subprocess
import sys
import time
import uuid
from pathlib import Path

from conversation_archive import safe_database, validate_ancestors, validate_owned_file


LSOF_TIMEOUT = 5
PENDING_GLOB = ".trace-migration-*.jsonl"
IMPORT_BATCH_BYTES = 1_048_576
SCHEMA = """
CREATE TABLE IF NOT EXISTS events (
    id INTEGER PRIMARY KEY, time TEXT, session TEXT, thread TEXT, type TEXT,
    payload BLOB NOT NULL, legacy_file TEXT, legacy_offset INTEGER,
    UNIQUE(legacy_file, legacy_offset));
CREATE TABLE IF NOT EXISTS trace_imports (
    name TEXT PRIMARY KEY, sha256 TEXT NOT NULL, byte_count INTEGER NOT NULL,
    line_count INTEGER NOT NULL, imported_at INTEGER NOT NULL);
"""


def fingerprint(path):
    value = path.lstat()
    if not stat.S_ISREG(value.st_mode):
        raise ValueError("Trace source is not a regular file")
    return (value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns, value.st_ctime_ns)


def has_open_handles(path):
    result = subprocess.run(["/usr/sbin/lsof", "-F", "f", "--", str(path)],
                            capture_output=True, timeout=LSOF_TIMEOUT)
    if result.returncode not in (0, 1) or result.stderr:
        raise RuntimeError("Trace source handles could not be checked")
    return result.returncode == 0 or bool(result.stdout)


def quarantine(state):
    for name in ("trace.jsonl.1", "trace.jsonl"):
        path = state / name
        try:
            fingerprint(path)
            path.rename(state / (".trace-migration-" + uuid.uuid4().hex + ".jsonl"))
        except FileNotFoundError:
            continue


def event_fields(payload):
    try:
        entry = json.loads(payload)
        return tuple(entry.get(key) if isinstance(entry.get(key), str) else None
                     for key in ("time", "record", "thread", "type"))
    except (ValueError, TypeError, AttributeError):
        return (None, None, None, "legacy")


def verify_rows(database, name, expected):
    digest, size, count = hashlib.sha256(), 0, 0
    for offset, payload in database.execute(
            "SELECT legacy_offset,payload FROM events WHERE legacy_file=? ORDER BY legacy_offset", (name,)):
        if offset != size:
            raise ValueError("Archived trace offsets are not contiguous")
        digest.update(payload)
        size += len(payload)
        count += 1
    if (digest.hexdigest(), size, count) != expected:
        raise ValueError("Archived trace bytes do not match the sealed source")


def insert_batch(state, name, batch):
    with safe_database(state, writable=True) as database:
        database.executescript(SCHEMA)
        database.execute("BEGIN IMMEDIATE")
        for offset, payload in batch:
            database.execute("INSERT OR IGNORE INTO events(time,session,thread,type,payload,legacy_file,legacy_offset) "
                             "VALUES(?,?,?,?,?,?,?)", (*event_fields(payload), payload, name, offset))
        database.commit()


def import_file(state, path, sealed):
    digest, offset, count, batch = hashlib.sha256(), 0, 0, []
    batch_bytes = 0
    with safe_database(state, writable=True) as database:
        database.executescript(SCHEMA)
        database.execute("DELETE FROM events WHERE legacy_file=? AND NOT EXISTS "
                         "(SELECT 1 FROM trace_imports WHERE name=?)", (path.name, path.name))
        database.commit()
    with path.open("rb") as source:
        for payload in source:
            digest.update(payload)
            batch.append((offset, payload))
            offset += len(payload)
            count += 1
            batch_bytes += len(payload)
            if batch_bytes >= IMPORT_BATCH_BYTES:
                insert_batch(state, path.name, batch)
                batch, batch_bytes = [], 0
    if batch:
        insert_batch(state, path.name, batch)
    if fingerprint(path) != sealed:
        raise ValueError("Sealed trace source changed")
    return (digest.hexdigest(), offset, count)


def seal_file(state, path, expected):
    with safe_database(state, writable=True) as database:
        database.executescript(SCHEMA)
        database.execute("BEGIN IMMEDIATE")
        prior = database.execute("SELECT sha256,byte_count,line_count FROM trace_imports WHERE name=?",
                                 (path.name,)).fetchone()
        if prior is not None and tuple(prior) != expected:
            raise ValueError("Sealed trace source changed after commit")
        verify_rows(database, path.name, expected)
        database.execute("INSERT OR IGNORE INTO trace_imports VALUES(?,?,?,?,?)",
                         (path.name, *expected, time.time_ns()))
        database.commit()


def migrate_file(state, path, open_handles, after_commit):
    if open_handles(path):
        return False
    sealed = fingerprint(path)
    expected = import_file(state, path, sealed)
    if open_handles(path) or fingerprint(path) != sealed:
        raise ValueError("Sealed trace source is still in use")
    seal_file(state, path, expected)
    if after_commit:
        after_commit()
    if fingerprint(path) == sealed and not open_handles(path):
        path.unlink()
        return True
    return False


def migrate(state, open_handles=has_open_handles, after_commit=None):
    state = validate_ancestors(Path(state).resolve())
    result = {"migrated": 0, "pending": 0, "errors": 0}
    if not state.is_dir():
        return result
    descriptor = os.open(state / ".trace-migration.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        validate_owned_file(state / ".trace-migration.lock", descriptor)
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return result
        quarantine(state)
        for path in sorted(state.glob(PENDING_GLOB)):
            try:
                result["migrated"] += int(migrate_file(state, path, open_handles, after_commit))
            except (OSError, ValueError, RuntimeError, sqlite3.Error, subprocess.SubprocessError):
                result["errors"] += 1
        result["pending"] = sum(1 for _ in state.glob(PENDING_GLOB))
    finally:
        os.close(descriptor)
    return result


if __name__ == "__main__":
    try:
        result = migrate(json.load(sys.stdin)["state"])
        print(json.dumps({"ok": result["errors"] == 0, **result}))
    except Exception:
        print(json.dumps({"ok": False}))
