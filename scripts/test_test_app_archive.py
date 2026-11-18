import json
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch
import manage_test_apps as archive
import manage_install as installer


class ArchiveTests(unittest.TestCase):
    def setUp(self):
        hooks = patch.object(archive, "configured_hook_commands", return_value=[])
        hooks.start(); self.addCleanup(hooks.stop)
        self.temporary = tempfile.TemporaryDirectory(prefix="aar-archive-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve() / "build"
        self.root.mkdir()
        self.app = self.root / "test/Attention Router Test.app"
        contents = self.app / "Contents"
        contents.mkdir(parents=True)
        (contents / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "org.agentattentionrouter.review"}))
        (contents / "sentinel").write_bytes(b"unchanged bundle")
        self.receipt = self.root / "archive-plan.json"

    def testLiveExecutableAndResourcesProtectWholeBundle(self):
        for path in [self.app / "Contents/MacOS/aar", self.app / "Contents/Resources/Assets.car"]:
            result = archive.plan(self.root, [str(path)])
            self.assertEqual(result["entries"][0]["status"], "active-retained")

    def testActualRecoverableMovePreservesBytesAndLeavesDataRoot(self):
        data = self.root / "test/data"
        data.mkdir(); (data / "state.json").write_text("current metadata")
        plan = archive.plan(self.root, [])
        before = archive.fingerprint(self.app)
        with patch.object(archive, "active_paths", return_value=[]):
            result = archive.apply(plan, self.receipt)
        item = result["entries"][0]
        self.assertEqual(item["status"], "archived")
        self.assertFalse(self.app.exists())
        self.assertEqual(archive.fingerprint(Path(item["destination"])), before)
        self.assertEqual((data / "state.json").read_text(), "current metadata")
        self.assertEqual(archive.plan(self.root, [])["entries"], [])

    def testNewlyActiveChangedOrOutsideTargetsAreNeverMoved(self):
        plan = archive.plan(self.root, [])
        with patch.object(archive, "active_paths", return_value=[str(self.app / "Contents/MacOS/aar")]):
            archive.apply(plan, self.receipt)
        self.assertTrue(self.app.exists())
        plan = archive.plan(self.root, [])
        (self.app / "Contents/sentinel").write_bytes(b"changed after plan")
        with patch.object(archive, "active_paths", return_value=[]):
            result = archive.apply(plan, self.receipt)
        self.assertEqual(result["entries"][0]["status"], "changed-or-conflicting-retained")
        self.assertTrue(self.app.exists())
        plan = archive.plan(self.root, [])
        plan["entries"][0]["destination"] = str(self.root.parent / "outside.app")
        with self.assertRaises(ValueError): archive.apply(plan, self.receipt)
        self.assertTrue(self.app.exists())

    def testConfiguredHooksProtectUnmappedBundleAndAreRecheckedBeforeApply(self):
        command = "'" + str(self.app / "Contents/MacOS/aar") + "' hook"
        result = archive.plan(self.root, [], [command])
        self.assertEqual(result["entries"][0]["status"], "configured-hook-retained")
        reviewed = archive.plan(self.root, [], [])
        with patch.object(archive, "active_paths", return_value=[]), patch.object(archive, "configured_hook_commands", return_value=[command]):
            result = archive.apply(reviewed, self.receipt)
        self.assertEqual(result["entries"][0]["status"], "became-configured-retained")
        self.assertTrue(self.app.exists())

    def testHookDependencyInspectionPreservesForeignFieldsAndRefusesUnsafeFiles(self):
        hooks = self.root / "hooks.json"
        command = "'/synthetic/Other App.app/Contents/MacOS/helper' hook"
        original = json.dumps({"keep": {"enabled": True}, "hooks": {"Stop": [{"hooks": [{"type": "command", "command": command}]}]}}).encode()
        hooks.write_bytes(original); hooks.chmod(0o600)
        self.assertEqual(installer.configured_hook_commands(hooks), [command])
        self.assertEqual(hooks.read_bytes(), original)
        link = self.root / "linked-hooks.json"; link.symlink_to(hooks)
        with self.assertRaises(OSError): installer.configured_hook_commands(link)
        hooks.chmod(0o644)
        with self.assertRaises(ValueError): installer.configured_hook_commands(hooks)
        hooks.chmod(0o600); hooks.write_text('{"hooks": []}')
        with self.assertRaises(ValueError): installer.configured_hook_commands(hooks)



if __name__ == "__main__":
    unittest.main()
