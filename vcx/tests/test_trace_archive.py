import importlib.util
import json
import os
import sqlite3
import sys
import tempfile
import threading
import unittest
from pathlib import Path


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
SPEC = importlib.util.spec_from_file_location("trace_archive", Path(__file__).resolve().parents[1] / "trace_archive.py")
archive = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(archive)
CONTENTION_SECONDS = 0.05
THREAD_TIMEOUT = 5


class TraceArchiveTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.state = Path(self.temporary.name).resolve()
        self.source = self.state / "trace.jsonl"
        self.payload = (json.dumps({"time": "2026-11-25T10:00:00Z", "type": "sample", "text": "synthetic diagnostic"}) + "\n").encode()
        self.source.write_bytes(self.payload)

    def stored(self):
        with sqlite3.connect(self.state / "conversations.sqlite") as database:
            return database.execute("SELECT payload FROM events WHERE legacy_file IS NULL OR EXISTS "
                                    "(SELECT 1 FROM trace_imports WHERE name=legacy_file) ORDER BY id").fetchall()

    def test_imports_and_verifies_the_exact_legacy_trace_bytes_before_removing_jsonl(self):
        self.source.write_bytes(self.payload + b"unfinished trailing bytes")

        result = archive.migrate(self.state, open_handles=lambda _: False)

        self.assertEqual({"migrated": 1, "pending": 0, "errors": 0}, result)
        self.assertFalse(self.source.exists())
        self.assertEqual(self.payload + b"unfinished trailing bytes", b"".join(row[0] for row in self.stored()))

    def test_keeps_a_quarantined_trace_while_a_legacy_process_has_it_open(self):
        with self.source.open("ab") as legacy:
            result = archive.migrate(self.state)
            pending = list(self.state.glob(archive.PENDING_GLOB))
            self.assertEqual(1, result["pending"])
            self.assertEqual(0, result["migrated"])
            legacy.write(b"late legacy event\n")
            legacy.flush()

        resumed = archive.migrate(self.state)

        self.assertEqual(0, resumed["pending"])
        self.assertFalse(pending[0].exists())
        self.assertEqual(self.payload + b"late legacy event\n", b"".join(row[0] for row in self.stored()))

    def test_resumes_an_interrupted_migration_after_commit_without_duplicate_events(self):
        def interrupted():
            raise RuntimeError("synthetic interruption after commit")

        first = archive.migrate(self.state, open_handles=lambda _: False, after_commit=interrupted)
        committed = self.stored()
        second = archive.migrate(self.state, open_handles=lambda _: False)

        self.assertEqual(1, first["pending"])
        self.assertEqual(1, first["errors"])
        self.assertEqual({"migrated": 1, "pending": 0, "errors": 0}, second)
        self.assertEqual([(self.payload,)], committed)
        self.assertEqual(committed, self.stored())

    def test_rolls_back_when_a_sealed_trace_changes_during_import(self):
        calls = 0

        def changed(path):
            nonlocal calls
            calls += 1
            if calls == 2:
                with path.open("ab") as source:
                    source.write(b"late diagnostic\n")
            return False

        first = archive.migrate(self.state, open_handles=changed)
        rolled_back = self.stored()
        resumed = archive.migrate(self.state, open_handles=lambda _: False)

        self.assertEqual(1, first["errors"])
        self.assertEqual([], rolled_back)
        self.assertEqual(0, resumed["pending"])
        self.assertEqual(self.payload + b"late diagnostic\n", b"".join(row[0] for row in self.stored()))

    def test_imports_current_and_rotated_logs_into_the_same_database(self):
        rotated = self.state / "trace.jsonl.1"
        rotated.write_bytes(b"older diagnostic\n")

        result = archive.migrate(self.state, open_handles=lambda _: False)

        self.assertEqual({"migrated": 2, "pending": 0, "errors": 0}, result)
        self.assertCountEqual([(self.payload,), (b"older diagnostic\n",)], self.stored())
        self.assertFalse(rotated.exists())

    def test_waits_for_an_existing_sqlite_writer_without_losing_legacy_events(self):
        with archive.safe_database(self.state, writable=True) as database:
            database.executescript(archive.SCHEMA)
        writer = sqlite3.connect(self.state / "conversations.sqlite")
        self.addCleanup(writer.close)
        writer.execute("BEGIN IMMEDIATE")
        finished, results = threading.Event(), []

        def migrate():
            results.append(archive.migrate(self.state, open_handles=lambda _: False))
            finished.set()

        worker = threading.Thread(target=migrate)
        worker.start()
        blocked = not finished.wait(CONTENTION_SECONDS)
        writer.rollback()
        worker.join(THREAD_TIMEOUT)

        self.assertTrue(blocked)
        self.assertFalse(worker.is_alive())
        self.assertEqual([{"migrated": 1, "pending": 0, "errors": 0}], results)
        self.assertEqual([(self.payload,)], self.stored())

    def test_keeps_legacy_bytes_and_does_not_mutate_a_foreign_sqlite_database(self):
        path = self.state / "conversations.sqlite"
        with sqlite3.connect(path) as database:
            database.execute("CREATE TABLE foreign_data (value TEXT)")
        os.chmod(path, 0o600)
        before = path.read_bytes()

        result = archive.migrate(self.state, open_handles=lambda _: False)

        self.assertEqual(1, result["errors"])
        self.assertEqual(1, result["pending"])
        self.assertEqual(before, path.read_bytes())
        self.assertEqual(self.payload, next(self.state.glob(archive.PENDING_GLOB)).read_bytes())
        self.assertFalse(Path(str(path) + "-wal").exists())

    def test_keeps_legacy_bytes_and_does_not_mutate_a_corrupt_database(self):
        path = self.state / "conversations.sqlite"
        path.write_bytes(b"synthetic corrupt database")
        os.chmod(path, 0o600)
        before = path.read_bytes()

        result = archive.migrate(self.state, open_handles=lambda _: False)

        self.assertEqual(1, result["errors"])
        self.assertEqual(1, result["pending"])
        self.assertEqual(before, path.read_bytes())

    def test_rejects_a_database_symlink_before_mutating_its_target(self):
        target = self.state / "foreign.sqlite"
        with sqlite3.connect(target) as database:
            database.execute("CREATE TABLE foreign_data (value TEXT)")
        os.chmod(target, 0o600)
        before = target.read_bytes()
        (self.state / "conversations.sqlite").symlink_to(target)

        result = archive.migrate(self.state, open_handles=lambda _: False)

        self.assertEqual(1, result["errors"])
        self.assertEqual(1, result["pending"])
        self.assertEqual(before, target.read_bytes())

    def test_rejects_an_archive_lock_symlink_without_mutating_its_target(self):
        target = self.state / "foreign.lock"
        target.write_bytes(b"synthetic foreign lock")
        before = target.read_bytes()
        (self.state / ".archive.lock").symlink_to(target)

        result = archive.migrate(self.state, open_handles=lambda _: False)

        self.assertEqual(1, result["errors"])
        self.assertEqual(1, result["pending"])
        self.assertEqual(before, target.read_bytes())


if __name__ == "__main__":
    unittest.main()
