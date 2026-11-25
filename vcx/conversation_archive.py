"""SQLite archive for closed VCX conversations and their byte-exact native history."""
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import stat
import subprocess
import sys
import tempfile
import time
import uuid
import zlib

BUSY_SECONDS = 30
MAX_RECENT = 40
CHUNK_BYTES = 1024 * 1024
ADAPTER_REVISION = 1
MAX_CODEX_HEADER_BYTES = 8 * CHUNK_BYTES
MAX_CLIENT_VERSION_LENGTH = 256
APPLICATION_ID = 0x56435841
SCHEMA_VERSION = 1
# The state folder was ~/.local/state/cx until 25/11/2026: manifests sealed before the move name it in their roots.
LEGACY_STATE = Path.home() / ".local/state/cx"
CURRENT_STATE = Path.home() / ".local/state/vcx"
SCHEMA = """CREATE TABLE IF NOT EXISTS conversations (
 id BLOB PRIMARY KEY CHECK(length(id)=16), record BLOB NOT NULL,
 updated_at INTEGER NOT NULL, native_thread TEXT NOT NULL, status TEXT NOT NULL, recent_summary TEXT NOT NULL DEFAULT '{}');
CREATE TABLE IF NOT EXISTS messages (
 id BLOB PRIMARY KEY CHECK(length(id)=16), client TEXT NOT NULL,
 provider TEXT NOT NULL, model TEXT NOT NULL,
 conversation_id BLOB NOT NULL REFERENCES conversations(id), message_id TEXT NOT NULL,
 sequence INTEGER NOT NULL, role TEXT NOT NULL, created_at INTEGER NOT NULL,
 updated_at INTEGER NOT NULL, content TEXT NOT NULL,
 metadata TEXT NOT NULL CHECK(json_valid(metadata)), UNIQUE(conversation_id,sequence));
CREATE TABLE IF NOT EXISTS blobs (
 hash BLOB PRIMARY KEY, bytes BLOB NOT NULL);
CREATE TABLE IF NOT EXISTS artifacts (
 conversation_id BLOB NOT NULL REFERENCES conversations(id), root TEXT NOT NULL, path TEXT NOT NULL,
 hash BLOB NOT NULL REFERENCES blobs(hash), mode INTEGER NOT NULL, mtime_ns INTEGER NOT NULL DEFAULT 0, source_key TEXT NOT NULL DEFAULT '',
 PRIMARY KEY(conversation_id,root,path));
CREATE INDEX IF NOT EXISTS artifacts_hash ON artifacts(hash);
CREATE INDEX IF NOT EXISTS conversations_recent ON conversations(updated_at DESC);
CREATE TABLE IF NOT EXISTS provider_verifications (provider TEXT PRIMARY KEY, adapter_revision INTEGER NOT NULL, verified_at INTEGER NOT NULL, client_version TEXT NOT NULL DEFAULT '');
CREATE TABLE IF NOT EXISTS aliases (alias TEXT NOT NULL, conversation_id BLOB NOT NULL REFERENCES conversations(id),
 PRIMARY KEY(alias,conversation_id));
"""


def validate_ancestors(path):
    path = Path(os.path.abspath(path))
    for ancestor in [path, *path.parents]:
        if ancestor.is_symlink():
            raise ValueError("Symlink archive path is unsafe")
    return path


def validate_owned_file(path, descriptor=None, allowed_links=(1,)):
    info = os.fstat(descriptor) if descriptor is not None else path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink not in allowed_links:
        raise ValueError("Unsafe archive database or lock")
    if stat.S_IMODE(info.st_mode) != 0o600:
        raise ValueError("Archive database or lock permissions are unsafe")
    return info


@contextlib.contextmanager
def safe_database(state, writable=False):
    root = validate_ancestors(Path(state).resolve())
    if not writable and not (root / "conversations.sqlite").exists():
        yield None
        return
    if writable:
        root.mkdir(parents=True, exist_ok=True, mode=0o700)
    lock = None
    try:
        if writable:
            lock = os.open(root / ".archive.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
            validate_owned_file(root / ".archive.lock", lock)
            fcntl.flock(lock, fcntl.LOCK_EX)
        with open_database(root, writable) as connection:
            yield connection
    finally:
        if lock is not None:
            os.close(lock)


@contextlib.contextmanager
def open_database(root, writable):
    path = validate_ancestors(root / "conversations.sqlite")
    created = False
    if writable and not path.exists():
        descriptor = os.open(path, os.O_CREAT | os.O_EXCL | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        os.close(descriptor)
        created = True
    before = validate_owned_file(path)
    for suffix in ["-wal", "-shm", "-journal"]:
        sidecar = validate_ancestors(Path(str(path) + suffix))
        if sidecar.exists():
            validate_owned_file(sidecar)
    mode = "rw" if writable else "ro"
    connection = sqlite3.connect(path.as_uri() + "?mode=" + mode, uri=True, timeout=BUSY_SECONDS)
    try:
        after = validate_owned_file(path)
        if (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino):
            raise ValueError("Archive database changed during open")
        app_id = connection.execute("PRAGMA application_id").fetchone()[0]
        version = connection.execute("PRAGMA user_version").fetchone()[0]
        if created:
            connection.execute("PRAGMA application_id=" + str(APPLICATION_ID))
            connection.execute("PRAGMA user_version=" + str(SCHEMA_VERSION))
        elif app_id != APPLICATION_ID or version != SCHEMA_VERSION:
            raise ValueError("Archive database identity is not recognized")
        if writable:
            connection.execute("PRAGMA foreign_keys=ON")
            connection.execute("PRAGMA journal_mode=WAL")
            connection.execute("PRAGMA synchronous=FULL")
        else:
            connection.execute("PRAGMA query_only=ON")
        yield connection
    finally:
        connection.close()


@contextlib.contextmanager
def database(state):
    with safe_database(state, writable=True) as connection:
        connection.executescript(SCHEMA)
        migrations = {"artifacts": {"mtime_ns": "INTEGER NOT NULL DEFAULT 0", "source_key": "TEXT NOT NULL DEFAULT ''"},
                      "provider_verifications": {"client_version": "TEXT NOT NULL DEFAULT ''"},
                      "conversations": {"recent_summary": "TEXT NOT NULL DEFAULT '{}'"}}
        for table, additions in migrations.items():
            columns = {row[1] for row in connection.execute("PRAGMA table_info(" + table + ")")}
            for column, definition in additions.items():
                if column not in columns:
                    connection.execute("ALTER TABLE " + table + " ADD COLUMN " + column + " " + definition)
        yield connection


def identifier(value):
    return uuid.UUID(value).bytes


def rooted_path(path, root):
    base = validate_ancestors(Path(root).resolve())
    candidate = Path(os.path.abspath(path))
    for ancestor in [candidate, *candidate.parents]:
        if ancestor.resolve() == base:
            return validate_ancestors(base / candidate.relative_to(ancestor))
    raise ValueError("Artifact is outside its native history root")


def locator(path, roots):
    for name, base in sorted(roots.items(), key=lambda pair: len(pair[1]), reverse=True):
        try:
            absolute = rooted_path(path, base)
            return name, str(absolute.relative_to(Path(base).resolve()))
        except ValueError:
            continue
    raise ValueError("Artifact is outside the native history roots")


def source_identity(source):
    provider = source["provider"]
    if provider not in ["claude", "codex", "agy", "qwen"]:
        raise ValueError("Unsupported native history provider")
    native = str(uuid.UUID(source["threadId"].split(":", 1)[-1]))
    home = str(validate_ancestors(Path(source["home"]).resolve()))
    return provider, home, native


def sources(record, homes):
    values = record.get("nativeSources") or [{"provider": record["provider"],
        "home": homes.get(record["provider"], ""), "threadId": record["threadId"],
        "nativeHistoryPath": record.get("nativeHistoryPath")}]
    result = {}
    for source in values:
        identity = source_identity(source)
        if not source["home"] or not Path(source["home"]).is_absolute():
            raise ValueError("Unsafe native history root")
        result[identity] = {**source, "home": identity[1]}
    return list(result.values())


def validate_codex_source(path, native_id):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor, "rb") as source:
        info = os.fstat(source.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
            raise ValueError("Unsafe native history source")
        header = source.readline(MAX_CODEX_HEADER_BYTES + 1)
    validate_codex_header(header, native_id)


def validate_codex_header(header, native_id):
    if len(header) > MAX_CODEX_HEADER_BYTES:
        raise ValueError("Codex history identity header exceeds validation limit")
    metadata = json.loads(header)
    if metadata.get("type") != "session_meta" or str(uuid.UUID(metadata["payload"]["id"])) != native_id:
        raise ValueError("Codex history identity does not match its source")


def native_files(source, allow_missing=False):
    provider, home, native_id = source_identity(source)
    home = Path(home)
    if provider == "claude":
        mains = list((home / "projects").glob("*/" + native_id + ".jsonl"))
        files = mains[:]
        for main in mains:
            files.extend(p for p in main.with_suffix("").rglob("*") if p.is_file())
        files.extend(p for p in (home / "file-history" / native_id).rglob("*") if p.is_file())
    elif provider == "codex":
        mains = [p for folder in ["sessions", "archived_sessions"]
                 for p in (home / folder).rglob("*" + native_id + ".jsonl")]
        files = mains[:]
        if source.get("nativeHistoryPath"):
            current = rooted_path(source["nativeHistoryPath"], home)
            if not current.is_relative_to(home) or current.suffix != ".jsonl":
                raise ValueError("Unsafe Codex history hint")
            if current.is_file():
                files.append(current)
                mains.append(current)
        for main in set(mains):
            validate_codex_source(main, native_id)
    elif provider == "agy":
        mains = [home / "conversations" / (native_id + ".db")]
        mains = [p for p in mains if p.is_file()]
        files = mains[:]
        files.extend(Path(str(p) + suffix) for p in mains for suffix in ["-wal", "-shm", "-journal"]
                     if Path(str(p) + suffix).is_file())
        files.extend(p for p in (home / "brain" / native_id).rglob("*") if p.is_file())
    else:
        return []
    if not mains and not allow_missing and not source.get("pendingCreation", False):
        raise ValueError("Native history is missing; source files kept")
    if any(not validate_ancestors(p).resolve().is_relative_to(home) for p in files):
        raise ValueError("Unsafe native history source")
    return sorted(set(files))


def source_key(source):
    return hashlib.sha256("\0".join(source_identity(source)).encode()).hexdigest()


def root_name(source, homes):
    provider, home, _ = source_identity(source)
    if homes.get(provider) and Path(homes[provider]).resolve() == Path(home):
        return provider
    return provider + "-" + hashlib.sha256(home.encode()).hexdigest()[:16]


def read_file(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor, "rb") as source:
        before = os.fstat(source.fileno())
        if not stat.S_ISREG(before.st_mode) or before.st_uid != os.getuid():
            raise ValueError("Unsafe archive source")
        data = source.read()
        after = os.fstat(source.fileno())
    if (before.st_ino, before.st_size, before.st_mtime_ns) != (after.st_ino, after.st_size, after.st_mtime_ns):
        raise ValueError("Native history changed during capture; source files kept")
    return data, stat.S_IMODE(before.st_mode)


def capture_file(path, native_id=None):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    digest, compressor = hashlib.sha256(), zlib.compressobj()
    with os.fdopen(descriptor, "rb") as source, tempfile.TemporaryFile() as compressed:
        before = os.fstat(source.fileno())
        if not stat.S_ISREG(before.st_mode) or before.st_uid != os.getuid():
            raise ValueError("Unsafe archive source")
        if native_id is not None:
            validate_codex_header(source.readline(MAX_CODEX_HEADER_BYTES + 1), native_id)
            source.seek(0)
        for chunk in iter(lambda: source.read(CHUNK_BYTES), b""):
            digest.update(chunk)
            compressed.write(compressor.compress(chunk))
        compressed.write(compressor.flush())
        after = os.fstat(source.fileno())
        if (before.st_ino, before.st_size, before.st_mtime_ns) != (after.st_ino, after.st_size, after.st_mtime_ns):
            raise ValueError("Native history changed during capture; source files kept")
        compressed.seek(0)
        return digest.digest(), compressed.read(), stat.S_IMODE(before.st_mode), before.st_mtime_ns


def file_digest(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    digest = hashlib.sha256()
    with os.fdopen(descriptor, "rb") as source:
        before = os.fstat(source.fileno())
        if not stat.S_ISREG(before.st_mode) or before.st_uid != os.getuid():
            raise ValueError("Unsafe archive source")
        for chunk in iter(lambda: source.read(CHUNK_BYTES), b""):
            digest.update(chunk)
        after = os.fstat(source.fileno())
        if (before.st_ino, before.st_size, before.st_mtime_ns) != (after.st_ino, after.st_size, after.st_mtime_ns):
            raise ValueError("Native history changed during verification; source files kept")
    return digest.digest()


def inflated_chunks(payload):
    decoder = zlib.decompressobj()
    for start in range(0, len(payload), CHUNK_BYTES):
        pending = payload[start:start + CHUNK_BYTES]
        while pending:
            yield decoder.decompress(pending, CHUNK_BYTES)
            pending = decoder.unconsumed_tail
    if not decoder.eof or decoder.unused_data:
        raise ValueError("Invalid compressed archive artifact")


def payload_digest(payload):
    digest = hashlib.sha256()
    for chunk in inflated_chunks(payload):
        digest.update(chunk)
    return digest.digest()


def no_open_files(paths):
    if not paths:
        return
    result = subprocess.run(["/usr/sbin/lsof", "-t", "--", *map(str, paths)],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=BUSY_SECONDS)
    if result.returncode != 1 or result.stdout or result.stderr:
        raise ValueError("Native history may still be open; source files kept")


def projection(connection, key, record):
    connection.execute("DELETE FROM messages WHERE conversation_id=?", (key,))
    namespace = uuid.UUID(bytes=key)
    now = int(time.time() * 1000)
    sequence = 0
    for row in record.get("rows", []):
        for item in row.get("items", []):
            sequence += 1
            native = str(item.get("id", sequence))
            role = {"user": "user", "assistant": "assistant", "activity": "tool"}.get(row.get("kind"), "system")
            content = item.get("text") or json.dumps(item.get("content", item), ensure_ascii=False)
            stamp = item.get("sentAt", item.get("stepStartedAt", now / 1000))
            created = int(stamp * 1000) if isinstance(stamp, (float, int)) else now
            origin = item.get("archiveOrigin")
            origin = origin if isinstance(origin, dict) else {}
            client, provider, model = (origin.get(field) if isinstance(origin.get(field), str) else ""
                                       for field in ["client", "provider", "model"])
            values = (uuid.uuid5(namespace, str(sequence) + ":" + native).bytes, client,
                      provider, model, key, native, sequence,
                      role, created, now, content, json.dumps(item, ensure_ascii=False))
            connection.execute("INSERT INTO messages VALUES (?,?,?,?,?,?,?,?,?,?,?,?)", values)


def save_aliases(connection, key, value):
    aliases = {str(uuid.UUID(bytes=key))}
    for source in value.get("nativeSources", []):
        provider, _, native = source_identity(source)
        aliases.update([native, provider + ":" + native])
    for alias in aliases:
        connection.execute("INSERT OR IGNORE INTO aliases VALUES (?,?)", (alias, key))


def archive(connection, request):
    record_path = rooted_path(request["recordPath"], request["state"])
    key = identifier(record_path.stem)
    previous = connection.execute("SELECT status FROM conversations WHERE id=?", (key,)).fetchone()
    if previous and previous[0] in ["sealed", "archived"]:
        return finish_cleanup(connection, key, request)
    data, _ = read_file(record_path)
    value = json.loads(data)
    value["nativeSources"] = sources(value, request.get("homes", {}))
    roots, files, owners, codex_ids = {"state": request["state"]}, [record_path], {}, {}
    for source in value["nativeSources"]:
        roots[root_name(source, request.get("homes", {}))] = source["home"]
        # A thread whose agent never wrote history (the window moved to another provider first) has nothing to lose;
        # one an earlier generation captured must still be there.
        captured = connection.execute("SELECT 1 FROM artifacts WHERE conversation_id=? AND source_key=? LIMIT 1", (key, source_key(source))).fetchone()
        discovered = native_files(source, allow_missing=captured is None)
        files.extend(discovered)
        owners.update((path.resolve(), source_key(source)) for path in discovered)
        if source["provider"] == "codex":
            codex_ids.update((path.resolve(), source_identity(source)[2]) for path in discovered)
    log_root = Path(request["state"]).resolve() / "logs"
    log = log_root / (str(uuid.UUID(bytes=key)).upper() + ".log")
    if log.exists():
        roots["vcxLogs"] = str(log_root)
        files.append(rooted_path(log, log_root))
    value["archiveRoots"] = roots
    no_open_files(files[1:])
    with connection:
        connection.execute("INSERT INTO conversations (id,record,updated_at,native_thread,status,recent_summary) VALUES (?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET record=excluded.record,updated_at=excluded.updated_at,native_thread=excluded.native_thread,status=excluded.status,recent_summary=excluded.recent_summary",
                           (key, zlib.compress(json.dumps(value).encode()), int(time.time() * 1000), value["threadId"], "sealed", json.dumps(recent_summary(value))))
        connection.execute("DELETE FROM artifacts WHERE conversation_id=?", (key,))
        for path in sorted(set(files)):
            digest, payload, mode, mtime_ns = capture_file(path, native_id=codex_ids.get(path.resolve()))
            connection.execute("INSERT OR IGNORE INTO blobs VALUES (?,?)", (digest, payload))
            root, relative = locator(path, roots)
            connection.execute("INSERT INTO artifacts (conversation_id,root,path,hash,mode,mtime_ns,source_key) VALUES (?,?,?,?,?,?,?)", (key, root, relative, digest, mode, mtime_ns, owners.get(path.resolve(), "")))
        for path in files:
            root, relative = locator(path, roots)
            expected = connection.execute("SELECT hash FROM artifacts WHERE conversation_id=? AND root=? AND path=?", (key, root, relative)).fetchone()[0]
            if file_digest(path) != expected:
                raise ValueError("Native history changed during capture; source files kept")
        no_open_files(files[1:])
        projection(connection, key, value)
        save_aliases(connection, key, value)
        connection.execute("DELETE FROM blobs WHERE NOT EXISTS (SELECT 1 FROM artifacts WHERE artifacts.hash=blobs.hash)")
    return finish_cleanup(connection, key, request)


def artifact_path(roots, root, relative):
    base = validate_ancestors(Path(roots[root]).resolve())
    path = validate_ancestors(base / relative)
    if Path(relative).is_absolute() or ".." in Path(relative).parts or path.is_symlink() or not path.resolve().is_relative_to(base):
        raise ValueError("Unsafe archive artifact path")
    return path


def cleanup_paths(connection, key, request, value):
    owned = {source_identity(source) for source in request.get("ownedSources", [])}
    versions = request.get("clientVersions", {})
    verified = {provider for provider, version in connection.execute(
        "SELECT provider,client_version FROM provider_verifications WHERE adapter_revision=?", (ADAPTER_REVISION,))
        if version and version == versions.get(provider)}
    if request.get("syntheticFixtureRoot"):
        base = Path(request["syntheticFixtureRoot"]).resolve()
        paths = [Path(request["state"]).resolve(), *[Path(s["home"]).resolve() for s in value["nativeSources"]]]
        if not base.name.startswith("vcx-archive-check-") or not all(p.is_relative_to(base) for p in paths):
            raise ValueError("Unsafe synthetic fixture override")
        verified.update(["claude", "codex", "agy", "qwen"])
    providers = set(request.get("pruneProviders", [])) & verified
    entries = connection.execute("SELECT root,path,hash,source_key FROM artifacts WHERE conversation_id=?", (key,)).fetchall()
    # A sealed manifest remains authoritative after an interrupted unlink.
    native = [(artifact_path(value["archiveRoots"], root, relative), digest)
              for root, relative, digest, _ in entries if root != "state"]
    eligible = {source_key(source) for source in value["nativeSources"]
                if source.get("managed") is True and source_identity(source) in owned and source["provider"] in providers
                and (request.get("syntheticFixtureRoot") or source.get("clientVersion") == versions.get(source["provider"]))}
    known = {path for path, _ in native}
    for source in value["nativeSources"]:
        if any(path not in known for path in native_files(source, allow_missing=True)):
            raise ValueError("Native history gained files; sealed generation and newer files kept")
    paths = [(artifact_path(value["archiveRoots"], root, relative), digest)
             for root, relative, digest, owner in entries
             if (root != "state" and owner in eligible) or (root == "vcxLogs" and request.get("childExited") is True)]
    no_open_files([path for path, _ in native if path.exists()])
    for path, digest in native:
        if path.exists() and file_digest(path) != digest:
            raise ValueError("Native history changed; the sealed generation and newer files are kept")
    return paths


def reconcile_snapshot(connection, key, request, value):
    path = rooted_path(request["recordPath"], request["state"])
    row = connection.execute("SELECT path,hash FROM artifacts WHERE conversation_id=? AND root='state'", (key,)).fetchone()
    if not path.exists() or file_digest(path) == row[1]:
        return value
    if locator(path, value["archiveRoots"]) != ("state", row[0]):
        raise ValueError("New draft location differs; committed generation and draft retained")
    payload, mode = read_file(path)
    latest = json.loads(payload)
    old_sources = value.get("nativeSources") or sources(value, request.get("homes", {}))
    new_sources = sources(latest, request.get("homes", {}))
    if {source_identity(s) for s in old_sources} != {source_identity(s) for s in new_sources}:
        raise ValueError("New draft changes native sources; committed generation and draft retained")
    latest["archiveRoots"], latest["nativeSources"] = value["archiveRoots"], old_sources
    digest = hashlib.sha256(payload).digest()
    with connection:
        connection.execute("INSERT OR IGNORE INTO blobs VALUES (?,?)", (digest, zlib.compress(payload)))
        connection.execute("UPDATE artifacts SET hash=?,mode=?,mtime_ns=? WHERE conversation_id=? AND root='state'", (digest, mode, path.stat().st_mtime_ns, key))
        connection.execute("UPDATE conversations SET record=?,updated_at=?,recent_summary=? WHERE id=?", (zlib.compress(json.dumps(latest).encode()), int(time.time() * 1000), json.dumps(recent_summary(latest)), key))
        projection(connection, key, latest)
    return latest


def finish_cleanup(connection, key, request):
    verify(connection, key)
    value = record(connection, key)
    # Older manifests are retained for retry, never recaptured from missing sources.
    value.setdefault("nativeSources", sources(value, request.get("homes", {})))
    paths = cleanup_paths(connection, key, request, value)
    value = reconcile_snapshot(connection, key, request, value)
    verify(connection, key)
    entries = connection.execute("SELECT root,path,hash FROM artifacts WHERE conversation_id=? AND root='state'", (key,)).fetchall()
    for root, relative, digest in entries:
        path = artifact_path(value["archiveRoots"], root, relative)
        if path.exists() and file_digest(path) != digest:
            raise ValueError("Conversation changed; the sealed generation and draft are kept")
    for path, digest in paths:
        if path.exists() and file_digest(path) != digest:
            raise ValueError("Native history changed during cleanup; sealed generation retained")
        path.unlink(missing_ok=True)
        sync_directory(path.parent)
    for root, relative, digest in entries:
        path = artifact_path(value["archiveRoots"], root, relative)
        if path.exists() and file_digest(path) != digest:
            raise ValueError("Conversation changed during cleanup; sealed generation retained")
        path.unlink(missing_ok=True)
        sync_directory(path.parent)
    with connection:
        connection.execute("UPDATE conversations SET status='archived' WHERE id=?", (key,))
    return {"archived": True, "client": value["provider"]}


def verify(connection, key):
    value = record(connection, key)
    if not value or not isinstance(value.get("archiveRoots"), dict):
        raise ValueError("Archive manifest is invalid")
    query = "SELECT artifacts.root,artifacts.path,artifacts.mode,artifacts.hash,blobs.bytes FROM artifacts LEFT JOIN blobs ON artifacts.hash=blobs.hash WHERE conversation_id=?"
    count, snapshots = 0, 0
    for root, relative, mode, digest, payload in connection.execute(query, (key,)):
        artifact_path(value["archiveRoots"], root, relative)
        if not isinstance(digest, bytes) or len(digest) != hashlib.sha256().digest_size or payload is None:
            raise ValueError("Archive manifest references missing or invalid content")
        if not isinstance(mode, int) or not 0 <= mode <= 0o777 or payload_digest(payload) != digest:
            raise ValueError("Archive verification failed; source files kept")
        count += 1
        snapshots += root == "state"
    if not count or snapshots != 1:
        raise ValueError("Archive does not contain one conversation snapshot")


def record(connection, key):
    row = connection.execute("SELECT record FROM conversations WHERE id=?", (key,)).fetchone()
    if not row:
        return None
    value = json.loads(zlib.decompress(row[0]))
    if isinstance(value.get("archiveRoots"), dict):
        value["archiveRoots"] = {name: relocated(base) for name, base in value["archiveRoots"].items()}
    return value


def relocated(base):
    path = Path(base)
    moved = LEGACY_STATE.is_symlink() or not LEGACY_STATE.is_dir()
    return str(CURRENT_STATE / path.relative_to(LEGACY_STATE)) if moved and path.is_relative_to(LEGACY_STATE) else base


def publish(path, mode, payload, compressed=False):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor, temporary = tempfile.mkstemp(prefix=".archive-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as destination:
            os.fchmod(destination.fileno(), mode)
            if compressed:
                for chunk in inflated_chunks(payload):
                    destination.write(chunk)
            else:
                destination.write(payload)
            destination.flush()
            os.fsync(destination.fileno())
        os.link(temporary, path)
        sync_directory(path.parent)
    finally:
        os.unlink(temporary)


def restore(connection, key, request):
    verify(connection, key)
    value = record(connection, key)
    roots = {**value["archiveRoots"], **(request.get("homes", {}) if request.get("relocateHomes") else {}), "state": request["state"]}
    if "vcxLogs" in roots:
        roots["vcxLogs"] = str(Path(request["state"]).resolve() / "logs")
    status = connection.execute("SELECT status FROM conversations WHERE id=?", (key,)).fetchone()[0]
    query = "SELECT root,path,mode,bytes FROM artifacts JOIN blobs ON artifacts.hash=blobs.hash WHERE conversation_id=? ORDER BY root='state'"
    # Validate the entire bundle before publishing any missing component.
    for root, relative, _, payload in connection.execute(query, (key,)):
        path = artifact_path(roots, root, relative)
        if path.exists() and file_digest(path) != payload_digest(payload):
            if root == "state" and request.get("preserveDraft"):
                continue
            raise ValueError("Newer native history exists; refusing to overwrite it")
    for root, relative, mode, payload in connection.execute(query, (key,)):
        path = artifact_path(roots, root, relative)
        if not path.exists():
            publish(path, mode, payload, compressed=True)
    with connection:
        connection.execute("UPDATE conversations SET status='materialized' WHERE id=?", (key,))
    return {"restored": True}


def resolve(connection, value):
    if value == "last":
        row = connection.execute("SELECT id FROM conversations ORDER BY updated_at DESC LIMIT 1").fetchone()
        return row[0] if row else None
    try:
        normalized = str(uuid.UUID(value.split(":", 1)[-1]))
    except ValueError:
        return None
    if ":" not in value:
        row = connection.execute("SELECT id FROM conversations WHERE id=?", (identifier(normalized),)).fetchone()
        if row:
            return row[0]
    alias = value.split(":", 1)[0].lower() + ":" + normalized if ":" in value else normalized
    matches = connection.execute("SELECT conversation_id FROM aliases WHERE alias=?", (alias,)).fetchall()
    return matches[0][0] if len(matches) == 1 else None


def backup_database(connection, target):
    target = validate_ancestors(target.parent.resolve() / target.name)
    descriptor, temporary = tempfile.mkstemp(prefix=".archive-backup-", dir=target.parent)
    os.close(descriptor)
    try:
        with contextlib.closing(sqlite3.connect(temporary)) as backup:
            connection.backup(backup)
            backup.execute("PRAGMA journal_mode=DELETE")
            if backup.execute("PRAGMA integrity_check").fetchone() != ("ok",):
                raise ValueError("Backup verification failed")
        with open(temporary, "rb") as source:
            os.fsync(source.fileno())
        os.link(temporary, target)
        sync_directory(target.parent)
    finally:
        for suffix in ["-wal", "-shm", "-journal", ""]:
            cleanup = Path(temporary + suffix)
            if cleanup.exists() or cleanup.is_symlink():
                validate_ancestors(cleanup)
                validate_owned_file(cleanup, allowed_links=(1, 2) if not suffix else (1,))
                cleanup.unlink()
    return {"backed_up": True}


def sync_directory(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def recent_summary(value):
    supplied = value.get("recentSummary")
    if isinstance(supplied, dict):
        return {key: supplied[key] for key in ["title", "preview", "fleetContext", "hasRows", "threadId"] if key in supplied}
    return {"title": value.get("title", ""), "fleetContext": value.get("fleetContext", ""),
            "hasRows": bool(value.get("rows")), "threadId": value.get("threadId", "")}


def alias_source(alias, key, value):
    if alias == "last" or (":" not in alias and identifier(alias) == key):
        return None
    native = str(uuid.UUID(alias.split(":", 1)[-1]))
    provider = alias.split(":", 1)[0].lower() if ":" in alias else None
    matches = [source for source in value.get("nativeSources", [])
               if source_identity(source)[2] == native and (provider is None or source["provider"] == provider)]
    if len(matches) != 1:
        raise ValueError("Native source alias is ambiguous")
    return matches[0]


def read_dispatch(request):
    with safe_database(request["state"]) as connection:
        action = request["action"]
        has_conversations = connection is not None and connection.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='conversations'").fetchone()
        if action == "list":
            if not has_conversations:
                return {"records": []}
            columns = {row[1] for row in connection.execute("PRAGMA table_info(conversations)")}
            summary = "recent_summary" if "recent_summary" in columns else "'{}'"
            rows = connection.execute("SELECT id," + summary + ",updated_at FROM conversations ORDER BY updated_at DESC LIMIT ?", (MAX_RECENT,))
            return {"records": [{"id": str(uuid.UUID(bytes=key)).upper(), "summary": json.loads(value), "updated_at": updated} for key, value, updated in rows]}
        key = resolve(connection, request["id"]) if has_conversations else None
        if action == "read":
            return {"record": record(connection, key) if key is not None else None}
        if key is None:
            return {"id": None}
        value = record(connection, key)
        status = connection.execute("SELECT status FROM conversations WHERE id=?", (key,)).fetchone()[0]
        return {"id": str(uuid.UUID(bytes=key)).upper(), "record": value, "status": status,
                "source": alias_source(request["id"], key, value)}


def dispatch(request):
    if request["action"] == "sourceFiles":
        return {"paths": sorted({str(path) for source in request["sources"] for path in native_files(source)})}
    if request["action"] in ["list", "read", "resolve"]:
        return read_dispatch(request)
    with database(request["state"]) as connection:
        action = request["action"]
        if action == "certifyProvider":
            provider = request["provider"]
            if provider not in ["claude", "codex", "agy", "qwen"] or request["adapterRevision"] != ADAPTER_REVISION:
                raise ValueError("Unsupported provider adapter certification")
            version = request.get("clientVersion", "")
            if not isinstance(version, str) or not version.strip() or len(version) > MAX_CLIENT_VERSION_LENGTH:
                raise ValueError("Native client version is required for certification")
            with connection:
                connection.execute("INSERT OR REPLACE INTO provider_verifications (provider,adapter_revision,verified_at,client_version) VALUES (?,?,?,?)", (provider, ADAPTER_REVISION, int(time.time() * 1000), version))
            return {"certified": True, "adapterRevision": ADAPTER_REVISION}
        if action == "archive":
            return archive(connection, request)
        if action == "backup":
            return backup_database(connection, Path(request["destination"]))
        key = resolve(connection, request["id"])
        if action == "restore":
            row = connection.execute("SELECT status FROM conversations WHERE id=?", (key,)).fetchone()
            if not row:
                return {"restored": False}
            return restore(connection, key, request)
        raise ValueError("Unknown archive action")


if __name__ == "__main__":
    try:
        print(json.dumps({"ok": True, **dispatch(json.load(sys.stdin))}))
    except Exception:
        # Native paths, messages and SQLite error details can contain private data.
        print(json.dumps({"ok": False, "error": "Conversation archive failed; committed data is retained and uncaptured files are kept."}))
        sys.exit(1)
