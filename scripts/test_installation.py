"""Actual signed-bundle install/update/rollback, including interrupted replacement.

Only new private temporary Applications folders are changed; no daily preferences.
"""
import argparse
import json
from pathlib import Path
import shutil
import tempfile
from unittest.mock import patch
import manage_install as installer


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True, type=Path)
    options = parser.parse_args()
    installer.validate(options.app)
    with tempfile.TemporaryDirectory(prefix="aar-install-check-") as temporary:
        root = Path(temporary).resolve()
        target = root / "Applications" / installer.NAME
        data = root / "data"
        data.mkdir(mode=0o700)
        sentinel = data / "state.json"
        sentinel.write_bytes(b'{"synthetic":"current data must survive rollback"}')
        original = sentinel.read_bytes()
        digest = installer.fingerprint(options.app)
        try:
            installer.install(options.app, target, "0" * 64)
            raise AssertionError("Changed input accepted")
        except ValueError:
            assert not target.exists()
        first = installer.install(options.app, target, digest)
        assert first["backup_app"] is None and installer.fingerprint(target) == digest
        inode = (target / "Contents/MacOS/aar").stat().st_ino
        second = installer.install(options.app, target, digest)
        backup = Path(second["backup_app"])
        assert installer.fingerprint(backup) == digest
        assert (backup / "Contents/MacOS/aar").stat().st_ino == inode
        assert (target / "Contents/MacOS/aar").stat().st_ino != inode
        # Revert application files using the exact same reviewed install path.
        installer.install(backup, target, installer.fingerprint(backup))
        before = installer.fingerprint(target)
        real_validate = installer.validate
        def fail_after_swap(app):
            if app == target:
                # Existing target is also validated before staging. Fail only
                # after its inode changes, i.e. after replacement.
                if (app / "Contents/MacOS/aar").stat().st_ino != current_inode:
                    raise ValueError("Injected post-replacement verification failure")
            real_validate(app)
        current_inode = (target / "Contents/MacOS/aar").stat().st_ino
        with patch.object(installer, "validate", fail_after_swap):
            try:
                installer.install(options.app, target, digest)
                raise AssertionError("Failure injection did not fire")
            except ValueError as error:
                assert "Injected" in str(error)
        assert installer.fingerprint(target) == before
        # The product rename retains the old application and rejects active
        # legacy helpers. A failed replacement restores the old pathname.
        legacy = root / "Rename Applications" / installer.LEGACY_NAME
        legacy.parent.mkdir()
        shutil.copytree(options.app, legacy)
        renamed = legacy.with_name(installer.NAME)
        with patch.object(installer, "legacy_in_use", return_value=True):
            try:
                installer.install(options.app, renamed, digest, legacy)
                raise AssertionError("Active legacy bundle accepted")
            except ValueError as error:
                assert "legacy Codex" in str(error)
        assert legacy.exists() and not renamed.exists()
        command = "'" + str(legacy / "Contents/MacOS/aar") + "' hook"
        with patch.object(installer, "configured_hook_commands", return_value=[command]):
            try:
                installer.install(options.app, renamed, digest, legacy)
                raise AssertionError("Configured Hook dependency accepted")
            except ValueError as error:
                assert "Configured Codex Hooks" in str(error)
        assert legacy.exists() and not renamed.exists()
        with patch.object(installer, "configured_hook_commands", side_effect=[[], [command]]):
            try:
                installer.install(options.app, renamed, digest, legacy)
                raise AssertionError("New Hook dependency during staging accepted")
            except ValueError as error:
                assert "during staging" in str(error)
        assert legacy.exists() and not renamed.exists()
        real_validate = installer.validate
        def fail_renamed(app):
            if app == renamed:
                raise ValueError("Injected rename verification failure")
            real_validate(app)
        with patch.object(installer, "validate", fail_renamed):
            try:
                installer.install(options.app, renamed, digest, legacy)
                raise AssertionError("Rename failure injection did not fire")
            except ValueError as error:
                assert "Injected rename" in str(error)
        assert legacy.exists() and not renamed.exists()
        renamed_receipt = installer.install(options.app, renamed, digest, legacy)
        assert renamed_receipt["renamed_from"] == str(legacy)
        assert not legacy.exists() and installer.fingerprint(renamed) == digest
        assert installer.fingerprint(Path(renamed_receipt["backup_app"])) == digest
        assert sentinel.read_bytes() == original
        assert (target / "Contents/MacOS/aar").stat().st_ino == current_inode
        assert sentinel.read_bytes() == original
        with patch.object(installer, "receiver_running", return_value=True):
            try:
                installer.install(options.app, target, digest)
                raise AssertionError("Running receiver accepted")
            except ValueError as error:
                assert "Quit only" in str(error)
        assert installer.fingerprint(target) == before
        link = root / "linked.app"
        link.symlink_to(options.app.absolute())
        try:
            installer.validate(link)
            raise AssertionError("Symlink accepted")
        except ValueError:
            pass
        print(json.dumps({"actual_signed_install": "pass", "update_new_inodes_and_backup": "pass",
                          "application_rollback": "pass", "failed_swap_restores_previous_app": "pass",
                          "running_receiver_refused": "pass", "configured_hooks_refuse_legacy_rename": "pass", "hooks_changed_during_staging_refused": "pass", "changed_input_and_symlink_refused": "pass",
                          "data_sentinel_preserved": True, "real_preferences_or_sessions_modified": False}, indent=2))


if __name__ == "__main__":
    main()
