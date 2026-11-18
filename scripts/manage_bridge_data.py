"""Review/copy a stopped bridge profile and remember its new stable location.

Never overwrites a destination, deletes a source, changes Hooks or restores an
old snapshot over current data. Existing legacy clients must be closed manually.
"""
import argparse
from contextlib import ExitStack, contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import tempfile

FIXED = {"state.json", "runtime-health.json", "notification-health.json", "bridge-launch-diagnostic.json"}
LOCKS = {"consumer.lock", "writers.lock"}
MARKER = "bridge-relocated.json"
RECEIPT = re.compile(r"bridge-(?:worker-)?[0-9A-Fa-f-]{36}\.json\Z")


def safe_path(path):
    path = path.absolute()
    if path == Path("/") or path == Path.home() or ".." in path.parts or any(p == "secrets" or p.startswith(".env") for p in path.parts):
        raise ValueError("Refused broad or protected data path")
    for entry in [path, *path.parents]:
        if entry.is_symlink():
            raise ValueError("Data paths must not contain symbolic links")
    return path


def private_directory(path):
    safe_path(path)
    info = path.stat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError("Bridge profile must be a private directory owned by you")


def read_private(path, limit):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077 or info.st_nlink != 1 or info.st_size > limit:
            raise ValueError("Unsafe profile file")
        with os.fdopen(fd, "rb", closefd=False) as stream:
            data = stream.read(limit + 1)
        if len(data) > limit or len(data) != info.st_size:
            raise ValueError("Profile changed during inspection")
        return data, info.st_mode & 0o777
    finally:
        os.close(fd)


def manifest(root):
    private_directory(root)
    entries = sorted(root.iterdir())
    # Validate all names before opening content. Unexpected/secret files are
    # never inspected to discover whether they can be copied.
    for entry in entries:
        if entry.name not in FIXED | LOCKS | {MARKER, "inbox"} and not RECEIPT.fullmatch(entry.name):
            raise ValueError("Unexpected profile entry; review its name separately")
        if entry.is_symlink():
            raise ValueError("Profile contains a symbolic link")
    files = []
    for entry in entries:
        if entry.name in LOCKS | {MARKER}:
            continue
        if entry.name == "inbox":
            private_directory(entry)
            children = sorted(entry.iterdir())
            for child in children:
                if child.is_symlink() or not child.name.endswith(".json") or child.name.startswith(".env"):
                    raise ValueError("Unexpected inbox entry")
            files.extend(children)
        else:
            files.append(entry)
    result = {}
    for file in files:
        data, mode = read_private(file, 67_108_864 if file.name == "state.json" else 2_097_152)
        result[str(file.relative_to(root))] = {"sha256": hashlib.sha256(data).hexdigest(), "mode": mode, "size": len(data)}
    return result


def fingerprint(root):
    info = root.stat()
    value = {"device": info.st_dev, "inode": info.st_ino, "files": manifest(root)}
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def inspect_clients(helper, source):
    result = subprocess.run([str(helper.absolute()), "inspect-bridge-migration", "--data-dir", str(source)],
                            capture_output=True, timeout=20)
    if result.returncode or len(result.stdout) > 8192:
        raise ValueError("Native client/worker preflight could not be completed")
    value = json.loads(result.stdout)
    for key in ["active_registered_clients", "active_bridge_workers", "unknown_worker_tickets"]:
        if not isinstance(value.get(key), int) or value[key] < 0:
            raise ValueError("Invalid native preflight result")
    return value


def remember_destination(helper, destination):
    result = subprocess.run([str(helper.absolute()), "remember-bridge-startup", "--data-dir", str(destination), "--apply"],
                            capture_output=True, timeout=20)
    if result.returncode:
        raise ValueError("Copy is retained, but remembering the new startup folder failed")


@contextmanager
def exclusive_lock(path):
    fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise ValueError("Unsafe migration lock")
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise ValueError("Quit the profile's receiver and finish/exit its Codex clients before migration") from error
        yield
    finally:
        os.close(fd)


def apply(source, destination, helper, expected):
    source, destination = safe_path(source), safe_path(destination)
    private_directory(source)
    if source == destination or source in destination.parents or destination in source.parents:
        raise ValueError("Choose separate non-nested profile directories")
    marker = source / MARKER
    if marker.exists():
        previous = json.loads(read_private(marker, 16384)[0])
        if previous.get("destination") != str(destination) or previous.get("source_fingerprint") != expected:
            raise ValueError("Existing relocation does not match this reviewed plan")
        private_directory(destination)
        return {"status": "already-migrated", "destination": str(destination), "current_data_preserved": True}
    with ExitStack() as stack:
        for name in sorted(LOCKS):
            stack.enter_context(exclusive_lock(source / name))
        if any(inspect_clients(helper, source).values()):
            raise ValueError("Legacy clients/workers or unknown tickets still require manual resolution")
        if fingerprint(source) != expected:
            raise ValueError("Source changed; inspect a new migration plan")
        files = manifest(source)
        if destination.exists():
            raise ValueError("Destination already exists; it was not changed. Review a retained copy separately after a failed activation.")
        else:
            destination.parent.mkdir(parents=True, exist_ok=True)
            staged = Path(tempfile.mkdtemp(prefix=".aar-bridge-migration-", dir=destination.parent))
            staged.chmod(0o700)
            (staged / "inbox").mkdir(mode=0o700)
            for name, info in files.items():
                target = staged / name
                data, _ = read_private(source / name, 67_108_864)
                with target.open("xb") as output:
                    output.write(data)
                target.chmod(info["mode"])
            if manifest(staged) != files or fingerprint(source) != expected:
                raise ValueError("Copy changed during verification; staged files retained for review")
            staged.rename(destination)
        if any(inspect_clients(helper, source).values()) or fingerprint(source) != expected:
            raise ValueError("Source became active/changed; both copies retained without activation")
        for name in sorted(LOCKS):
            stack.enter_context(exclusive_lock(destination / name))
        remember_destination(helper, destination)
        receipt = {"schema": 1, "destination": str(destination), "source_fingerprint": expected,
                   "source_retained": True, "old_snapshot_restore_allowed": False}
        fd = os.open(marker, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "w") as output:
            json.dump(receipt, output, sort_keys=True)
        return {"status": "migrated", **receipt}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--destination", required=True, type=Path)
    parser.add_argument("--helper", required=True, type=Path)
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--expected-fingerprint")
    options = parser.parse_args()
    try:
        source, destination = safe_path(options.source), safe_path(options.destination)
        if options.apply:
            if not options.expected_fingerprint:
                raise ValueError("Review the source fingerprint before applying")
            result = apply(source, destination, options.helper, options.expected_fingerprint)
        else:
            result = {"source": str(source), "destination": str(destination), "source_fingerprint": fingerprint(source),
                      "native_preflight": inspect_clients(options.helper, source), "changes_applied": False}
        print(json.dumps(result, indent=2, sort_keys=True))
    except (ValueError, OSError, subprocess.SubprocessError, json.JSONDecodeError) as error:
        raise SystemExit(str(error))


if __name__ == "__main__":
    main()
