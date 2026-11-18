"""Review or apply a local app install/update/rollback. Never touches session data.

Python 3 and macOS tools only; this file can be shipped outside the source checkout.
Rollback uses the same command with a retained backup as --app.
"""
import argparse
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import uuid

NAME = "Cueport.app"
LEGACY_NAME = "Agent Attention Router.app"
BUNDLE_ID = "org.agentattentionrouter.local-development"


def check_ancestors(path):
    for item in [path, *path.parents]:
        if item.is_symlink():
            raise ValueError("Installation paths must not contain symlinks")


def manifest(app):
    check_ancestors(app)
    if not app.is_dir():
        raise ValueError("Application bundle is missing")
    files = {}
    for item in sorted(app.rglob("*")):
        if item.is_symlink():
            raise ValueError("Unexpected symlink in application bundle")
        if item.is_file():
            files[str(item.relative_to(app))] = {
                "sha256": hashlib.sha256(item.read_bytes()).hexdigest(),
                "mode": item.stat().st_mode & 0o777,
            }
    return files


def fingerprint(app):
    return hashlib.sha256(json.dumps(manifest(app), sort_keys=True).encode()).hexdigest()


def validate(app):
    manifest(app)
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != BUNDLE_ID or info.get("AARBuildChannel", "daily") != "daily":
        raise ValueError("Only the daily application can be installed here")
    executable = info.get("CFBundleExecutable")
    if executable not in {"CueportApp", "AgentAttentionRouter"}:
        raise ValueError("Unknown receiver executable")
    for name in ["aar", executable]:
        if not os.access(app / "Contents/MacOS" / name, os.X_OK):
            raise ValueError("Packaged executable is missing")
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)],
                   check=True, capture_output=True, timeout=30)


def receiver_running(app):
    result = subprocess.run(["/bin/ps", "-ww", "-axo", "comm="],
                            capture_output=True, text=True, check=True, timeout=10)
    executables = {str(app / "Contents/MacOS" / name) for name in ["CueportApp", "AgentAttentionRouter"]}
    return any(line.strip() in executables for line in result.stdout.splitlines())


def legacy_in_use(app):
    result = subprocess.run(["/bin/ps", "-ww", "-axo", "comm="],
                            capture_output=True, text=True, check=True, timeout=10)
    return any(line.strip().startswith(str(app) + "/Contents/") for line in result.stdout.splitlines())


def install(source, destination, expected, rename_from=None):
    source, destination = source.absolute(), destination.absolute()
    if destination.name != NAME or source == destination:
        raise ValueError("Choose a separate destination named " + NAME)
    check_ancestors(destination)
    if rename_from is not None:
        rename_from = rename_from.absolute()
        if rename_from != destination.parent / LEGACY_NAME or destination.exists():
            raise ValueError("Rename only the sibling legacy application into an unused Cueport destination")
        check_ancestors(rename_from)
        validate(rename_from)
    validate(source)
    if fingerprint(source) != expected:
        raise ValueError("Candidate fingerprint changed; review the plan again")
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.parent.stat().st_uid != os.getuid():
        raise ValueError("Destination must be owned by the current user")
    lock_path = destination.parent / ".attention-router-install.lock"
    fd = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        if os.fstat(fd).st_uid != os.getuid():
            raise ValueError("Unsafe installation lock")
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if receiver_running(destination):
            raise ValueError("Quit only the receiver at the destination before updating. Codex clients may stay open.")
        old = rename_from or destination
        if rename_from is not None and legacy_in_use(old):
            raise ValueError("Exit legacy Codex connections and quit the old receiver before renaming")
        previous = fingerprint(old) if old.exists() else None
        if previous is not None:
            validate(old)
        journal = destination.parent / ".Cueport Backups"
        check_ancestors(journal)
        journal.mkdir(mode=0o700, exist_ok=True)
        if journal.stat().st_uid != os.getuid() or journal.stat().st_mode & 0o077:
            raise ValueError("Unsafe backup directory")
        transaction = journal / (datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ-") + uuid.uuid4().hex[:12])
        transaction.mkdir(mode=0o700)
        staged = transaction / "candidate.app"
        backup = transaction / old.name
        shutil.copytree(source, staged)
        validate(staged)
        if fingerprint(staged) != expected or fingerprint(source) != expected:
            raise ValueError("Candidate changed during staging")
        if receiver_running(destination):
            raise ValueError("Destination receiver started during staging; installation cancelled")
        if rename_from is not None and (destination.exists() or legacy_in_use(old)):
            raise ValueError("Legacy application became active or Cueport appeared during staging")
        if (fingerprint(old) if old.exists() else None) != previous:
            raise ValueError("Destination changed during staging")
        moved = False
        installed = False
        try:
            if previous is not None:
                old.rename(backup)
                moved = True
            staged.rename(destination)
            installed = True
            validate(destination)
            if fingerprint(destination) != expected:
                raise ValueError("Installed bundle differs from the candidate")
        except Exception:
            # Preserve the failed payload too. Never restore or open a data snapshot.
            if installed and destination.exists():
                destination.rename(transaction / "failed.app")
            if moved:
                backup.rename(old)
            raise
        receipt = {"installed_fingerprint": expected, "previous_fingerprint": previous,
                   "destination": str(destination), "backup_app": str(backup) if moved else None,
                   "renamed_from": str(rename_from) if rename_from else None,
                   "session_data_modified": False, "preferences_modified": False,
                   "codex_processes_stopped": False, "signing": "ad-hoc; not notarized"}
        receipt_path = transaction / "receipt.json"
        receipt_path.write_text(json.dumps(receipt, indent=2) + "\n")
        receipt_path.chmod(0o600)
        return receipt
    finally:
        os.close(fd)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--destination", type=Path, default=Path.home() / "Applications" / NAME)
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--expected-fingerprint")
    parser.add_argument("--rename-from", type=Path, help="Explicit sibling Agent Attention Router.app to replace; requires no old connections")
    options = parser.parse_args()
    source, destination = options.app.absolute(), options.destination.absolute()
    validate(source)
    digest = fingerprint(source)
    if not options.apply:
        print(json.dumps({"action": "review only", "candidate_fingerprint": digest,
                          "destination": str(destination), "receiver_running_at_destination": receiver_running(destination),
                          "renamed_from": str(options.rename_from) if options.rename_from else None,
                          "legacy_in_use": legacy_in_use(options.rename_from) if options.rename_from else False,
                          "data_and_preferences": "never copied, reset or restored",
                          "apply": "Re-run with --apply --expected-fingerprint " + digest}, indent=2))
        return
    if not options.expected_fingerprint:
        parser.error("--apply requires the fingerprint from the reviewed plan")
    print(json.dumps(install(source, destination, options.expected_fingerprint, options.rename_from), indent=2))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        raise SystemExit("Installation stopped: " + str(error))
