import json
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch
import manage_test_apps as archive


class ArchiveTests(unittest.TestCase):
    def setUp(self):
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


if __name__ == "__main__":
    unittest.main()
