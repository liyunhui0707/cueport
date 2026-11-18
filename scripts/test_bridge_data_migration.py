"""Behavior checks for a stopped synthetic bridge profile; no daily preferences."""
import fcntl
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("migration", Path(__file__).with_name("manage_bridge_data.py"))
migration = importlib.util.module_from_spec(spec)
spec.loader.exec_module(migration)


class MigrationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="aar-data-migration-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.source, self.destination = self.root / "source", self.root / "destination"
        self.source.mkdir(mode=0o700)
        (self.source / "inbox").mkdir(mode=0o700)
        self.state = self.source / "state.json"
        self.state.write_text('{"schema":1,"sessions":{},"processed":[]}')
        self.state.chmod(0o600)
        self.helper = self.root / "aar"

    def stopped(self, *_):
        return {"active_registered_clients": 0, "active_bridge_workers": 0, "unknown_worker_tickets": 0}

    def apply(self):
        expected = migration.fingerprint(self.source)
        with patch.object(migration, "inspect_clients", self.stopped), patch.object(migration, "remember_destination") as remember:
            result = migration.apply(self.source, self.destination, self.helper, expected)
        return result, remember

    def testCopyPreservesAllCurrentDataAndNeverReplacesDestinationOnRepeat(self):
        original = self.state.read_bytes()
        result, remember = self.apply()
        self.assertEqual(result["status"], "migrated")
        remember.assert_called_once()
        self.assertEqual((self.destination / "state.json").read_bytes(), original)
        self.assertEqual(self.state.read_bytes(), original)
        self.assertTrue((self.source / "bridge-relocated.json").is_file())
        (self.destination / "state.json").write_bytes(b'{"newer":"must survive"}')
        result, remember = self.apply()
        self.assertEqual(result["status"], "already-migrated")
        remember.assert_not_called()
        self.assertEqual((self.destination / "state.json").read_bytes(), b'{"newer":"must survive"}')

    def testLiveClientsChangedInputAndExistingDestinationAreRefused(self):
        expected = migration.fingerprint(self.source)
        with patch.object(migration, "inspect_clients", return_value={"active_registered_clients": 1}):
            with self.assertRaises(ValueError): migration.apply(self.source, self.destination, self.helper, expected)
        self.assertFalse(self.destination.exists())
        with patch.object(migration, "inspect_clients", self.stopped):
            with self.assertRaises(ValueError): migration.apply(self.source, self.destination, self.helper, "0" * 64)
        self.destination.mkdir(mode=0o700)
        (self.destination / "current.json").write_text("newer data")
        with patch.object(migration, "inspect_clients", self.stopped):
            with self.assertRaises(ValueError): migration.apply(self.source, self.destination, self.helper, expected)
        self.assertEqual((self.destination / "current.json").read_text(), "newer data")

    def testEvenAnIdenticalPreexistingDestinationIsNotAdoptedSilently(self):
        self.destination.mkdir(mode=0o700)
        copied = self.destination / "state.json"
        copied.write_bytes(self.state.read_bytes()); copied.chmod(0o600)
        expected = migration.fingerprint(self.source)
        with patch.object(migration, "inspect_clients", self.stopped), patch.object(migration, "remember_destination") as remember:
            with self.assertRaises(ValueError): migration.apply(self.source, self.destination, self.helper, expected)
        remember.assert_not_called()

    def testConsumerWriterLocksSymlinksAndUnexpectedFilesAreRefused(self):
        expected = migration.fingerprint(self.source)
        for name in ["consumer.lock", "writers.lock"]:
            with (self.source / name).open("a+") as lock:
                (self.source / name).chmod(0o600)
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                with self.assertRaises(ValueError): self.apply()
        link = self.source / "inbox/link.json"
        link.symlink_to(self.state)
        with self.assertRaises(ValueError): migration.fingerprint(self.source)
        link.unlink()
        (self.source / "unexpected.txt").write_text("must not be read")
        with self.assertRaises(ValueError): migration.fingerprint(self.source)

    def testActivationFailureLeavesSourceAndVerifiedCopyRecoverable(self):
        original = self.state.read_bytes()
        expected = migration.fingerprint(self.source)
        with patch.object(migration, "inspect_clients", self.stopped), patch.object(migration, "remember_destination", side_effect=ValueError("injected activation failure")):
            with self.assertRaises(ValueError): migration.apply(self.source, self.destination, self.helper, expected)
        self.assertEqual(self.state.read_bytes(), original)
        self.assertEqual((self.destination / "state.json").read_bytes(), original)
        self.assertFalse((self.source / "bridge-relocated.json").exists())


if __name__ == "__main__":
    unittest.main()
