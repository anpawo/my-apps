import importlib.util
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import uuid

SPEC = importlib.util.spec_from_file_location("conversation_archive", Path(__file__).resolve().parents[1] / "conversation_archive.py")
archive = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(archive)


class ArchiveTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="vcx-archive-check-")
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name).resolve()
        self.state = self.root / "state"
        self.key = str(uuid.uuid4()).upper()
        self.native = str(uuid.uuid4())
        self.snapshot = self.state / "native/project" / (self.key + ".json")
        self.homes = {name: str(self.root / name) for name in ["claude", "codex", "agy"]}

    def fixture(self, provider="claude"):
        self.snapshot.parent.mkdir(parents=True, exist_ok=True)
        thread = self.native if provider == "codex" else provider + ":" + self.native
        record = {"provider": provider, "threadId": thread, "model": "fixture", "cwd": str(self.root),
                  "nativeSources": [{"provider": provider, "home": self.homes[provider], "threadId": thread, "managed": True, "clientVersion": "fixture-version"}],
                  "rows": [{"kind": "user", "items": [{"id": "source-id", "text": "same"}]},
                           {"kind": "assistant", "items": [{"id": "reply-id", "text": "same"}]}]}
        self.snapshot.write_text(json.dumps(record))
        if provider == "claude":
            main = Path(self.homes[provider]) / "projects/project" / (self.native + ".jsonl")
            extra = main.with_suffix("") / "subagents/agent-fixture.jsonl"
            extra.parent.mkdir(parents=True)
            extra.write_bytes(b'{"tool":"fixture"}\n')
        elif provider == "codex":
            main = Path(self.homes[provider]) / "sessions/2026/11/25" / ("rollout-fixture-" + self.native + ".jsonl")
        else:
            main = Path(self.homes[provider]) / "conversations" / (self.native + ".db")
        main.parent.mkdir(parents=True, exist_ok=True)
        if provider == "agy":
            with sqlite3.connect(main) as connection:
                connection.execute("CREATE TABLE steps(value TEXT)")
                connection.execute("INSERT INTO steps VALUES ('fixture')")
            connection.close()
        elif provider == "codex":
            main.write_bytes(self.codex_payload(self.native))
        else:
            main.write_bytes(b'{"fixture":"resume-state"}\n')
        return main

    def codex_payload(self, native, text="fixture"):
        return (json.dumps({"type": "session_meta", "payload": {"id": native}}) + "\n" +
                json.dumps({"type": "fixture", "text": text}) + "\n").encode()

    def call(self, action, **values):
        return archive.dispatch({"state": str(self.state), "action": action, "id": self.key,
                                 "recordPath": str(self.snapshot), "homes": self.homes,
                                 "ownedSources": [{"provider": name, "home": home, "threadId": self.native} for name, home in self.homes.items()],
                                 "pruneProviders": list(self.homes), "syntheticFixtureRoot": str(self.root),
                                 "clientVersions": {name: "fixture-version" for name in self.homes}, **values})

    def test_closed_native_files_are_removed_only_after_verified_sqlite_capture(self):
        main = self.fixture()
        original = main.read_bytes()

        self.call("archive")
        records = self.call("list")["records"]
        self.call("restore")

        self.assertEqual(records[0]["id"], self.key)
        self.assertEqual(main.read_bytes(), original)
        self.assertTrue((main.with_suffix("") / "subagents/agent-fixture.jsonl").exists())
        with sqlite3.connect(self.state / "conversations.sqlite") as connection:
            self.assertEqual(connection.execute("SELECT role,sequence,length(id),length(conversation_id) FROM messages ORDER BY sequence").fetchall(),
                             [("user", 1, 16, 16), ("assistant", 2, 16, 16)])

    def test_backup_restores_into_new_state_and_native_roots_with_originals_absent(self):
        main = self.fixture()
        original = main.read_bytes()
        self.call("archive")
        new_state = self.root / "recovered-state"
        new_state.mkdir()
        self.call("backup", destination=str(new_state / "conversations.sqlite"))
        new_homes = {name: str(self.root / ("recovered-" + name)) for name in self.homes}

        self.call("restore", state=str(new_state), homes=new_homes, relocateHomes=True)

        recovered = Path(new_homes["claude"]) / main.relative_to(self.homes["claude"])
        self.assertEqual(recovered.read_bytes(), original)
        self.assertFalse(main.exists())
        self.assertTrue((new_state / self.snapshot.relative_to(self.state)).exists())

    def test_codex_and_agy_state_round_trip_without_text_conversion(self):
        for provider in ["codex", "agy"]:
            with self.subTest(provider=provider):
                main = self.fixture(provider)
                original = main.read_bytes()

                self.call("archive")
                absent = not main.exists()
                self.call("restore")

                self.assertTrue(absent)
                self.assertEqual(main.read_bytes(), original)

    def test_failed_verification_keeps_every_source_file(self):
        main = self.fixture()

        with patch.object(archive, "verify", side_effect=ValueError("fixture failure")):
            with self.assertRaises(ValueError):
                self.call("archive")

        self.assertTrue(main.exists())
        self.assertTrue(self.snapshot.exists())

    def test_open_native_file_prevents_archiving(self):
        main = self.fixture()

        with main.open("rb"):
            with self.assertRaises(ValueError):
                self.call("archive")

        self.assertTrue(main.exists())
        self.assertTrue(self.snapshot.exists())

    def test_transaction_failure_keeps_files_and_publishes_no_partial_conversation(self):
        main = self.fixture()

        with patch.object(archive, "projection", side_effect=RuntimeError("fixture failure")):
            with self.assertRaises(RuntimeError):
                self.call("archive")

        self.assertEqual(self.call("list")["records"], [])
        self.assertTrue(main.exists())

    def test_changed_native_history_is_never_overwritten_by_restore(self):
        main = self.fixture()
        self.call("archive")
        main.write_bytes(b"newer state")

        with self.assertRaises(ValueError):
            self.call("restore")

        self.assertEqual(main.read_bytes(), b"newer state")

    def test_repeated_close_after_resume_replaces_projection_without_duplicate_messages(self):
        main = self.fixture()
        self.call("archive")
        self.call("restore")
        main.write_bytes(main.read_bytes() + b'{"next":"turn"}\n')

        self.call("archive")
        self.call("restore")

        self.assertIn(b'"next":"turn"', main.read_bytes())
        with sqlite3.connect(self.state / "conversations.sqlite") as connection:
            self.assertEqual(connection.execute("SELECT count(*) FROM messages").fetchone()[0], 2)
            self.assertEqual(connection.execute("PRAGMA integrity_check").fetchone()[0], "ok")
            self.assertEqual(connection.execute("PRAGMA foreign_key_check").fetchall(), [])

    def test_partial_cleanup_retry_keeps_original_generation_and_missing_artifacts(self):
        main = self.fixture()
        extra = main.with_suffix("") / "subagents/agent-fixture.jsonl"
        original = main.read_bytes()
        unlink = Path.unlink
        failed = False

        def interrupted(path, *args, **kwargs):
            nonlocal failed
            if path.resolve() == extra.resolve() and not failed:
                failed = True
                raise OSError("fixture interruption")
            return unlink(path, *args, **kwargs)

        with patch.object(Path, "unlink", interrupted):
            with self.assertRaises(OSError):
                self.call("archive")
        self.assertFalse(main.exists())
        self.assertTrue(extra.exists())
        self.call("archive")
        self.call("restore")

        self.assertEqual(main.read_bytes(), original)
        self.assertTrue(extra.exists())

    def test_roots_sealed_under_the_legacy_state_folder_load_under_the_new_one(self):
        legacy, current = self.root / "cx", self.root / "vcx"
        self.state = legacy
        self.snapshot = self.state / "native/project" / (self.key + ".json")
        self.fixture()
        self.call("archive")
        legacy.rename(current)
        self.state = current

        with patch.object(archive, "LEGACY_STATE", legacy), patch.object(archive, "CURRENT_STATE", current):
            roots = self.call("read")["record"]["archiveRoots"]

        self.assertEqual(roots["state"], str(current))

    def test_cleanup_retry_after_snapshot_unlink_uses_stored_manifest(self):
        main = self.fixture()
        real_sync = archive.sync_directory

        def interrupted(path):
            if path.resolve() == self.snapshot.parent.resolve() and not self.snapshot.exists():
                raise OSError("fixture interruption")
            return real_sync(path)

        with patch.object(archive, "sync_directory", interrupted):
            with self.assertRaises(OSError):
                self.call("archive")
        self.call("archive")
        self.call("restore")

        self.assertTrue(main.exists())
        self.assertTrue(self.snapshot.exists())

    def test_changed_draft_during_sealed_retry_is_reconciled_with_original_native_manifest(self):
        main = self.fixture()
        with patch.object(archive, "verify", side_effect=ValueError("fixture interruption")):
            with self.assertRaises(ValueError):
                self.call("archive")
        self.snapshot.write_text(self.snapshot.read_text() + " ")

        self.call("archive")
        self.call("restore")

        self.assertTrue(main.exists())
        self.assertTrue(self.snapshot.read_text().endswith(" "))

    def test_restore_disk_full_leaves_snapshot_unpublished_and_retry_completes_bundle(self):
        main = self.fixture()
        self.call("archive")
        real_publish = archive.publish
        calls = 0

        def interrupted(path, mode, payload, **options):
            nonlocal calls
            calls += 1
            if calls == 2:
                raise OSError("fixture disk full")
            return real_publish(path, mode, payload, **options)

        with patch.object(archive, "publish", interrupted):
            with self.assertRaises(OSError):
                self.call("restore")
        self.assertFalse(self.snapshot.exists())
        self.call("restore")

        self.assertTrue(main.exists())
        self.assertTrue(self.snapshot.exists())

    def test_materialized_restore_repairs_missing_unchanged_bundle_component(self):
        main = self.fixture()
        self.call("archive")
        self.call("restore")
        main.unlink()

        self.call("restore")

        self.assertTrue(main.exists())

    def test_materialized_newer_database_does_not_receive_stale_sidecars(self):
        main = self.fixture("agy")
        sidecar = Path(str(main) + "-journal")
        sidecar.write_bytes(b"fixture journal")
        self.call("archive")
        self.call("restore")
        main.write_bytes(b"new materialized database")
        sidecar.unlink()

        with self.assertRaises(ValueError):
            self.call("restore")

        self.assertFalse(sidecar.exists())
        self.assertEqual(main.read_bytes(), b"new materialized database")

    def test_native_files_need_provider_certification_and_source_ownership_to_prune(self):
        main = self.fixture("codex")
        self.call("archive", syntheticFixtureRoot=None)
        self.assertTrue(main.exists())
        self.call("restore")
        self.call("certifyProvider", provider="codex", adapterRevision=archive.ADAPTER_REVISION, clientVersion="fixture-version")
        self.call("archive", syntheticFixtureRoot=None, ownedSources=[])
        self.assertTrue(main.exists())
        self.call("restore")

        self.call("archive", syntheticFixtureRoot=None)

        self.assertFalse(main.exists())

    def test_claude_is_copy_only_without_native_recall_certification(self):
        main = self.fixture()

        self.call("archive", syntheticFixtureRoot=None)

        self.assertTrue(main.exists())
        self.assertFalse(self.snapshot.exists())

    def test_all_profiles_are_captured_and_aliases_resolve_to_canonical_uuid(self):
        first = self.fixture("codex")
        second_home = self.root / "second-codex"
        second_id = str(uuid.uuid4())
        second = second_home / "sessions" / (second_id + ".jsonl")
        second.parent.mkdir(parents=True)
        second.write_bytes(self.codex_payload(second_id, "second profile"))
        value = json.loads(self.snapshot.read_text())
        value["nativeSources"] = [
            {"provider": "codex", "home": self.homes["codex"], "threadId": self.native, "managed": True, "clientVersion": "fixture-version"},
            {"provider": "codex", "home": str(second_home), "threadId": second_id, "managed": True, "clientVersion": "fixture-version"}]
        self.snapshot.write_text(json.dumps(value))
        owned = value["nativeSources"]

        self.call("archive", ownedSources=owned)
        resolved = [self.call("resolve", id=alias)["id"] for alias in
                    [self.key.lower(), self.native.upper(), "codex:" + second_id, second_id, "last"]]
        self.call("restore")

        self.assertEqual(resolved, [self.key] * 5)
        self.assertTrue(first.exists())
        self.assertEqual(second.read_bytes(), self.codex_payload(second_id, "second profile"))

    def test_missing_old_source_prevents_replacing_archive_with_incomplete_generation(self):
        main = self.fixture()
        self.call("archive")
        self.call("restore")
        main.unlink()

        with self.assertRaises(ValueError):
            self.call("archive")

        self.call("restore")
        self.assertTrue(main.exists())

    def test_pending_creation_source_can_archive_before_first_native_turn(self):
        self.fixture("codex").unlink()
        value = json.loads(self.snapshot.read_text())
        value["nativeSources"] = [{"provider": "codex", "home": self.homes["codex"],
                                    "threadId": self.native, "pendingCreation": True}]
        self.snapshot.write_text(json.dumps(value))

        self.call("archive")
        self.call("restore")

        self.assertTrue(self.snapshot.exists())

    def test_source_that_never_wrote_history_does_not_block_archive(self):
        main = self.fixture("codex")
        value = json.loads(self.snapshot.read_text())
        value["nativeSources"].insert(0, {"provider": "claude", "home": self.homes["claude"],
                                          "threadId": "claude:" + str(uuid.uuid4()), "pendingCreation": False})
        self.snapshot.write_text(json.dumps(value))

        self.call("archive")
        self.call("restore")

        self.assertEqual(main.read_bytes(), self.codex_payload(self.native))

    def test_atomic_publish_failure_leaves_no_partial_destination(self):
        target = self.root / "destination"

        with patch.object(archive.os, "fsync", side_effect=OSError("fixture disk full")):
            with self.assertRaises(OSError):
                archive.publish(target, 0o600, b"fixture content")

        self.assertFalse(target.exists())
        self.assertEqual(list(self.root.glob(".archive-*")), [])

    def test_backup_failure_never_publishes_a_partial_backup(self):
        self.fixture()
        self.call("archive")
        target = self.root / "backup.sqlite"

        with patch.object(archive.os, "fsync", side_effect=OSError("fixture disk full")):
            with self.assertRaises(OSError):
                self.call("backup", destination=str(target))

        self.assertFalse(target.exists())
        self.assertEqual(list(self.root.glob(".archive-backup-*")), [])

    def test_new_native_artifact_after_seal_prevents_source_deletion(self):
        main = self.fixture()
        with patch.object(archive, "verify", side_effect=ValueError("fixture interruption")):
            with self.assertRaises(ValueError):
                self.call("archive")
        extra = main.with_suffix("") / "subagents/new-agent.jsonl"
        extra.write_bytes(b"new native data")

        with self.assertRaises(ValueError):
            self.call("archive")

        self.assertTrue(main.exists())
        self.assertTrue(extra.exists())

    def test_native_capture_and_restore_stream_compressed_chunks(self):
        main = self.fixture()
        original = b"fixture native row\n" * 10000
        main.write_bytes(original)

        with patch.object(archive, "CHUNK_BYTES", 127):
            self.call("archive")
            self.call("restore")

        self.assertEqual(main.read_bytes(), original)

    def test_only_owned_thread_is_pruned_when_threads_share_one_native_home(self):
        first = self.fixture("codex")
        second_id = str(uuid.uuid4())
        second = first.parent / ("rollout-fixture-" + second_id + ".jsonl")
        second.write_bytes(self.codex_payload(second_id, "unowned native state"))
        value = json.loads(self.snapshot.read_text())
        owned = {"provider": "codex", "home": self.homes["codex"], "threadId": self.native, "managed": True, "clientVersion": "fixture-version"}
        value["nativeSources"] = [owned, {**owned, "threadId": second_id}]
        self.snapshot.write_text(json.dumps(value))

        self.call("archive", ownedSources=[owned])

        self.assertFalse(first.exists())
        self.assertEqual(second.read_bytes(), self.codex_payload(second_id, "unowned native state"))

    def test_legacy_native_source_without_managed_provenance_is_copy_only(self):
        main = self.fixture("codex")
        value = json.loads(self.snapshot.read_text())
        del value["nativeSources"]
        self.snapshot.write_text(json.dumps(value))

        self.call("archive")

        self.assertTrue(main.exists())
        self.assertFalse(self.snapshot.exists())

    def test_native_mutation_between_capture_and_commit_keeps_sources_and_rolls_back(self):
        main = self.fixture()
        capture = archive.capture_file

        def mutate_after_capture(path, **options):
            captured = capture(path, **options)
            if path.resolve() == main.resolve():
                main.write_bytes(b"new native generation")
            return captured

        with patch.object(archive, "capture_file", mutate_after_capture):
            with self.assertRaises(ValueError):
                self.call("archive")

        self.assertEqual(self.call("list")["records"], [])
        self.assertEqual(main.read_bytes(), b"new native generation")
        self.assertTrue(self.snapshot.exists())

    def test_prefixed_native_alias_does_not_resolve_another_providers_raw_alias(self):
        self.fixture("codex")
        self.call("archive")

        found = self.call("resolve", id="codex:" + self.native)["id"]
        missing = self.call("resolve", id="claude:" + self.native)["id"]

        self.assertEqual(found, self.key)
        self.assertIsNone(missing)

    def test_restore_rejects_manifest_path_traversal_before_publishing(self):
        main = self.fixture()
        self.call("archive")
        with sqlite3.connect(self.state / "conversations.sqlite") as connection:
            connection.execute("UPDATE artifacts SET path='../escape' WHERE rowid=(SELECT rowid FROM artifacts WHERE root='claude' LIMIT 1)")

        with self.assertRaises(ValueError):
            self.call("restore")

        self.assertFalse(main.exists())
        self.assertFalse((self.root / "escape").exists())

    def test_restore_rejects_symlink_destinations_without_overwriting_their_target(self):
        main = self.fixture()
        self.call("archive")
        target = self.root / "unrelated"
        target.write_bytes(b"unrelated native data")
        main.symlink_to(target)

        with self.assertRaises(ValueError):
            self.call("restore")

        self.assertEqual(target.read_bytes(), b"unrelated native data")

    def test_codex_hint_for_another_thread_never_captures_or_prunes_its_history(self):
        main = self.fixture("codex")
        other_id = str(uuid.uuid4())
        other = main.parent / ("rollout-fixture-" + other_id + ".jsonl")
        other.write_bytes(self.codex_payload(other_id, "unowned thread"))
        value = json.loads(self.snapshot.read_text())
        value["nativeSources"][0]["nativeHistoryPath"] = str(other)
        self.snapshot.write_text(json.dumps(value))

        with self.assertRaises(ValueError):
            self.call("archive")

        self.assertEqual(self.call("list")["records"], [])
        self.assertTrue(main.exists())
        self.assertEqual(other.read_bytes(), self.codex_payload(other_id, "unowned thread"))

    def test_codex_rollback_hint_uses_header_identity_when_filename_has_another_uuid(self):
        main = self.fixture("codex")
        renamed = main.with_name("rollback-" + str(uuid.uuid4()) + ".jsonl")
        main.rename(renamed)
        original = renamed.read_bytes()
        value = json.loads(self.snapshot.read_text())
        value["nativeSources"][0]["nativeHistoryPath"] = str(renamed)
        self.snapshot.write_text(json.dumps(value))

        self.call("archive")
        self.assertFalse(renamed.exists())
        self.call("restore")

        self.assertEqual(renamed.read_bytes(), original)

    def test_codex_filename_match_without_valid_header_identity_fails_closed(self):
        main = self.fixture("codex")
        for content in [b"malformed\n", b'{"type":"event_msg"}\n', self.codex_payload(str(uuid.uuid4()))]:
            with self.subTest(content_length=len(content)):
                main.write_bytes(content)

                with self.assertRaises((ValueError, KeyError)):
                    self.call("archive")

                self.assertTrue(main.exists())
                self.assertEqual(self.call("list")["records"], [])

    def test_source_files_lists_exact_bundle_without_creating_a_database(self):
        main = self.fixture()
        source = json.loads(self.snapshot.read_text())["nativeSources"][0]

        result = self.call("sourceFiles", sources=[source])

        self.assertEqual(set(result["paths"]), {str(main.resolve()), str((main.with_suffix("") / "subagents/agent-fixture.jsonl").resolve())})
        self.assertFalse((self.state / "conversations.sqlite").exists())

    def test_native_client_upgrade_requires_new_recall_certification_before_pruning(self):
        main = self.fixture("codex")
        self.call("certifyProvider", provider="codex", adapterRevision=archive.ADAPTER_REVISION, clientVersion="previous-version")

        self.call("archive", syntheticFixtureRoot=None)

        self.assertTrue(main.exists())

    def test_native_pruning_requires_a_known_current_client_version(self):
        main = self.fixture("codex")
        self.call("certifyProvider", provider="codex", adapterRevision=archive.ADAPTER_REVISION, clientVersion="fixture-version")

        self.call("archive", syntheticFixtureRoot=None, clientVersions={})

        self.assertTrue(main.exists())

    def test_historical_source_version_mismatch_keeps_native_files(self):
        main = self.fixture("codex")
        value = json.loads(self.snapshot.read_text())
        value["nativeSources"][0]["clientVersion"] = "historical-version"
        self.snapshot.write_text(json.dumps(value))
        self.call("certifyProvider", provider="codex", adapterRevision=archive.ADAPTER_REVISION, clientVersion="fixture-version")

        self.call("archive", syntheticFixtureRoot=None)

        self.assertTrue(main.exists())

    def test_codex_identity_is_rechecked_on_the_descriptor_used_for_capture(self):
        main = self.fixture("codex")
        inspect = archive.native_files

        def mutate_after_discovery(source, **options):
            paths = inspect(source, **options)
            main.write_bytes(self.codex_payload(str(uuid.uuid4())))
            return paths

        with patch.object(archive, "native_files", mutate_after_discovery):
            with self.assertRaises(ValueError):
                self.call("archive")

        self.assertEqual(self.call("list")["records"], [])
        self.assertTrue(main.exists())

    def test_projection_preserves_each_items_original_client_provider_and_model(self):
        self.fixture()
        value = json.loads(self.snapshot.read_text())
        value["provider"], value["model"] = "claude", "last-selected-model"
        value["rows"][0]["items"][0]["archiveOrigin"] = {
            "client": "codex", "provider": "openai", "model": "first-model",
            "source": {"provider": "codex", "home": self.homes["codex"], "threadId": self.native}}
        value["rows"][1]["items"][0]["archiveOrigin"] = {
            "client": "claude", "provider": "anthropic", "model": "second-model"}
        self.snapshot.write_text(json.dumps(value))

        self.call("archive")

        with sqlite3.connect(self.state / "conversations.sqlite") as connection:
            rows = connection.execute("SELECT client,provider,model,metadata FROM messages ORDER BY sequence").fetchall()
        self.assertEqual([row[:3] for row in rows], [
            ("codex", "openai", "first-model"), ("claude", "anthropic", "second-model")])
        self.assertEqual(json.loads(rows[0][3])["archiveOrigin"]["source"]["threadId"], self.native)

    def test_legacy_items_without_origin_do_not_inherit_the_last_selected_model(self):
        self.fixture()

        self.call("archive")

        with sqlite3.connect(self.state / "conversations.sqlite") as connection:
            rows = connection.execute("SELECT client,provider,model FROM messages ORDER BY sequence").fetchall()
        self.assertEqual(rows, [("", "", ""), ("", "", "")])

    def test_missing_blob_reference_prevents_cleanup_of_every_native_source(self):
        main = self.fixture()
        with patch.object(archive, "verify", side_effect=ValueError("fixture interruption")):
            with self.assertRaises(ValueError):
                self.call("archive")
        with sqlite3.connect(self.state / "conversations.sqlite") as connection:
            connection.execute("DELETE FROM blobs WHERE hash=(SELECT hash FROM artifacts WHERE root='claude' LIMIT 1)")

        with self.assertRaises(ValueError):
            self.call("archive")

        self.assertTrue(main.exists())
        self.assertTrue(self.snapshot.exists())

    def test_foreign_sqlite_database_is_rejected_without_mutation(self):
        self.state.mkdir()
        path = self.state / "conversations.sqlite"
        with sqlite3.connect(path) as connection:
            connection.execute("CREATE TABLE foreign_data(value TEXT)")
            connection.execute("INSERT INTO foreign_data VALUES ('fixture')")
        path.chmod(0o600)
        original = path.read_bytes()

        with self.assertRaises(ValueError):
            self.call("certifyProvider", provider="codex", adapterRevision=1, clientVersion="fixture-version")

        self.assertEqual(path.read_bytes(), original)

    def test_database_symlink_is_rejected_without_mutating_its_target(self):
        self.state.mkdir()
        target = self.root / "foreign.sqlite"
        target.write_bytes(b"foreign content")
        (self.state / "conversations.sqlite").symlink_to(target)

        with self.assertRaises(ValueError):
            self.call("list")

        self.assertEqual(target.read_bytes(), b"foreign content")

    def test_writer_lock_symlink_is_rejected_without_mutating_its_target(self):
        self.fixture()
        target = self.root / "foreign-lock"
        target.write_bytes(b"foreign lock data")
        (self.state / ".archive.lock").symlink_to(target)

        with self.assertRaises((ValueError, OSError)):
            self.call("archive")

        self.assertEqual(target.read_bytes(), b"foreign lock data")

    def test_native_symlink_ancestor_is_rejected_before_capture(self):
        main = self.fixture()
        projects = Path(self.homes["claude"]) / "projects"
        outside = self.root / "project-outside-root"
        (projects / "project").rename(outside)
        (projects / "project").symlink_to(outside, target_is_directory=True)

        with self.assertRaises(ValueError):
            self.call("archive")

        self.assertTrue(main.exists())
        self.assertFalse((self.state / "conversations.sqlite").exists() and self.call("list")["records"])

    def test_chosen_state_root_can_resolve_a_trusted_symlink_once(self):
        self.fixture()
        alias = self.root / "chosen-state-alias"
        alias.symlink_to(self.state, target_is_directory=True)

        self.call("archive", state=str(alias), recordPath=str(alias / self.snapshot.relative_to(self.state)))

        self.assertEqual(len(self.call("list")["records"]), 1)

    def test_recent_list_reads_only_small_summaries_without_writer_lock_or_snapshot_inflation(self):
        self.fixture()
        value = json.loads(self.snapshot.read_text())
        value["recentSummary"] = {"title": "latest answer", "hasRows": True, "threadId": value["threadId"]}
        self.snapshot.write_text(json.dumps(value))
        self.call("archive")

        with patch.object(archive.zlib, "decompress", side_effect=AssertionError("must not inflate snapshots")), patch.object(archive.fcntl, "flock", side_effect=AssertionError("must not lock readers")):
            result = self.call("list")

        self.assertEqual(result["records"][0]["summary"]["title"], "latest answer")
        self.assertNotIn("record", result["records"][0])

    def test_trace_first_database_identity_is_accepted_before_conversation_schema_exists(self):
        with archive.safe_database(self.state, writable=True) as connection:
            connection.execute("CREATE TABLE events(id INTEGER PRIMARY KEY,payload BLOB)")

        self.assertEqual(self.call("list"), {"records": []})
        self.fixture()
        self.call("archive")

        self.assertEqual(len(self.call("list")["records"]), 1)

    def test_normal_restore_ignores_current_profile_home_overrides(self):
        main = self.fixture("codex")
        self.call("archive")
        other_home = self.root / "different-profile"

        self.call("restore", homes={"codex": str(other_home)})

        self.assertTrue(main.exists())
        self.assertFalse(other_home.exists())

    def test_alias_resolve_returns_the_requested_earlier_native_source(self):
        self.fixture("codex")
        value = json.loads(self.snapshot.read_text())
        requested = value["nativeSources"][0]
        newer = {"provider": "claude", "home": self.homes["claude"], "threadId": "claude:" + str(uuid.uuid4()), "pendingCreation": True}
        value["nativeSources"].append(newer)
        value["provider"], value["threadId"] = newer["provider"], newer["threadId"]
        self.snapshot.write_text(json.dumps(value))
        self.call("archive")

        result = self.call("resolve", id="codex:" + self.native)

        self.assertEqual(result["source"]["threadId"], requested["threadId"])
        self.assertEqual(result["record"]["threadId"], newer["threadId"])

    def test_different_new_source_draft_can_recover_old_artifacts_then_close_successfully(self):
        main = self.fixture()
        with patch.object(archive, "verify", side_effect=ValueError("fixture interruption")):
            with self.assertRaises(ValueError):
                self.call("archive")
        main.unlink()
        value = json.loads(self.snapshot.read_text())
        source = {**value["nativeSources"][0], "threadId": "claude:" + str(uuid.uuid4()), "pendingCreation": True}
        value["nativeSources"].append(source)
        value["threadId"] = source["threadId"]
        self.snapshot.write_text(json.dumps(value))
        new_draft = self.snapshot.read_bytes()
        with self.assertRaises(ValueError):
            self.call("archive")

        self.call("restore", preserveDraft=True)
        self.assertTrue(main.exists())
        self.assertEqual(self.snapshot.read_bytes(), new_draft)
        self.call("archive")
        result = self.call("read")["record"]

        self.assertEqual(result["threadId"], source["threadId"])
        self.assertFalse(self.snapshot.exists())

    def test_sqlite_bundle_retry_preserves_original_wal_when_main_was_already_unlinked(self):
        main = self.fixture("agy")
        wal = Path(str(main) + "-wal")
        wal.write_bytes(b"fixture wal byte exact")
        original = main.read_bytes()
        unlink = Path.unlink
        failed = False

        def interrupted(path, *args, **kwargs):
            nonlocal failed
            if path == wal and not failed:
                failed = True
                raise OSError("fixture interruption")
            return unlink(path, *args, **kwargs)

        with patch.object(Path, "unlink", interrupted):
            with self.assertRaises(OSError):
                self.call("archive")
        self.assertFalse(main.exists())
        self.assertTrue(wal.exists())
        self.call("archive")
        self.call("restore")

        self.assertEqual(main.read_bytes(), original)
        self.assertEqual(wal.read_bytes(), b"fixture wal byte exact")

    def test_vcx_stderr_log_is_archived_and_pruned_only_after_child_exit(self):
        self.fixture()
        log = self.state / "logs" / (self.key + ".log")
        log.parent.mkdir()
        original = b"fixture stderr context\n"
        log.write_bytes(original)

        self.call("archive", childExited=False)
        self.assertEqual(log.read_bytes(), original)
        self.call("archive", childExited=True)
        self.assertFalse(log.exists())
        self.call("restore")

        self.assertEqual(log.read_bytes(), original)
        with sqlite3.connect(self.state / "conversations.sqlite") as connection:
            roots = connection.execute("SELECT root FROM artifacts WHERE root IN ('state','vcxLogs') ORDER BY root").fetchall()
        self.assertEqual(roots, [("state",), ("vcxLogs",)])

    def test_open_vcx_stderr_log_prevents_capture_and_deletion(self):
        main = self.fixture()
        log = self.state / "logs" / (self.key + ".log")
        log.parent.mkdir()
        log.write_bytes(b"fixture active stderr")

        with log.open("rb"):
            with self.assertRaises(ValueError):
                self.call("archive", childExited=True)

        self.assertTrue(log.exists())
        self.assertTrue(main.exists())


if __name__ == "__main__":
    unittest.main()
