"""Review/recoverably archive unused Cueport/legacy Attention Router build bundles.

Only project build outputs are eligible. No application is deleted, no data root
is moved, and any executable/resource reference held by an AAR process protects
its containing bundle. The review manifest is the restore map.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
from manage_install import configured_hook_commands, hooks_reference_application


def contained(path, root):
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False


def safe(path):
    if ".." in path.parts or any(p == "secrets" or p.startswith(".env") for p in path.parts):
        raise ValueError("Refused protected or non-normalized archive path")
    for item in [path, *path.parents]:
        if item.is_symlink():
            raise ValueError("Archive paths must not contain symbolic links")


def fingerprint(app):
    safe(app)
    values = {}
    for p in sorted(app.rglob("*")):
        if p.is_symlink():
            raise ValueError("Unexpected application symlink")
        if p.is_file():
            with p.open("rb") as source:
                digest = hashlib.sha256()
                for block in iter(lambda: source.read(1048576), b""):
                    digest.update(block)
            values[str(p.relative_to(app))] = [digest.hexdigest(), p.stat().st_mode & 0o777]
    return hashlib.sha256(json.dumps(values, sort_keys=True).encode()).hexdigest()


def active_paths():
    result = subprocess.run(["/bin/ps", "-ww", "-axo", "pid=,comm="], capture_output=True, text=True, check=True, timeout=15)
    paths, pids = [], []
    for line in result.stdout.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2 and Path(parts[1]).name in {"aar", "cueport", "CueportApp", "AgentAttentionRouter"}:
            paths.append(parts[1]); pids.append(parts[0])
    if pids:
        result = subprocess.run(["/usr/sbin/lsof", "-n", "-P", "-a", "-p", ",".join(pids), "-F", "n"],
                                capture_output=True, text=True, timeout=20)
        if result.returncode not in {0, 1}:
            raise ValueError("Active application references could not be inspected")
        paths.extend(line[1:] for line in result.stdout.splitlines() if line.startswith("n/") and ".app/" in line)
    return paths


def protected(app, paths):
    return any(contained(Path(p), app) for p in paths)


def plan(build_root, paths=None, hook_commands=None):
    build_root = build_root.absolute(); safe(build_root)
    if build_root.name != "build" or not build_root.is_dir():
        raise ValueError("Select this project's build directory")
    paths = active_paths() if paths is None else paths
    hook_commands = configured_hook_commands() if hook_commands is None else hook_commands
    entries = []
    apps = []
    for directory, names, _ in os.walk(build_root, followlinks=False):
        retained = []
        for name in names:
            path = Path(directory) / name
            if path.is_symlink() or name.endswith(".noindex") or name.startswith(".env") or name in {"secrets", "swift", "module-cache", "cache", "upstream", "dependencies", "data"} or "home" in name.lower():
                continue
            if name.endswith(".app"):
                apps.append(path)
            else:
                retained.append(name)
        names[:] = retained
    for app in sorted(apps):
        safe(app)
        try:
            info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        except (OSError, plistlib.InvalidFileException):
            entries.append({"source": str(app), "status": "unrecognized-retained"}); continue
        if not str(info.get("CFBundleIdentifier", "")).startswith("org.agentattentionrouter."):
            entries.append({"source": str(app), "status": "foreign-retained"}); continue
        if protected(app, paths):
            entries.append({"source": str(app), "status": "active-retained"}); continue
        if hooks_reference_application(app, hook_commands):
            entries.append({"source": str(app), "status": "configured-hook-retained"}); continue
        destination = build_root / "archive.noindex/apps" / app.relative_to(build_root)
        entries.append({"source": str(app), "destination": str(destination), "fingerprint": fingerprint(app), "status": "planned"})
    return {"schema": 1, "build_root": str(build_root), "recoverable_archive_only": True, "entries": entries}


def apply(reviewed, receipt_file):
    root = Path(reviewed["build_root"]).absolute(); safe(root)
    if reviewed.get("schema") != 1 or root.name != "build" or not reviewed.get("recoverable_archive_only"):
        raise ValueError("Invalid archive plan")
    # Validate every target before making any change.
    for item in reviewed["entries"]:
        if item["status"] not in {"planned", "archived"}:
            continue
        source, destination = Path(item["source"]), Path(item["destination"])
        if not contained(source, root) or not contained(destination, root / "archive.noindex/apps") or source.suffix != ".app":
            raise ValueError("Archive target outside the reviewed build scope")
        if destination != root / "archive.noindex/apps" / source.relative_to(root):
            raise ValueError("Unexpected archive destination")
        safe(source); safe(destination)
    paths = active_paths()
    hook_commands = configured_hook_commands()
    for item in reviewed["entries"]:
        if item["status"] != "planned":
            continue
        source, destination = Path(item["source"]), Path(item["destination"])
        if protected(source, paths):
            item["status"] = "became-active-retained"
        elif hooks_reference_application(source, hook_commands):
            item["status"] = "became-configured-retained"
        elif not source.exists() and destination.exists() and fingerprint(destination) == item["fingerprint"]:
            item["status"] = "archived"
        elif destination.exists() or not source.exists() or fingerprint(source) != item["fingerprint"]:
            item["status"] = "changed-or-conflicting-retained"
        else:
            destination.parent.mkdir(parents=True, exist_ok=True)
            source.rename(destination)
            item["status"] = "archived"
        staged = receipt_file.with_suffix(".pending")
        staged.write_text(json.dumps(reviewed, indent=2, sort_keys=True) + "\n")
        staged.chmod(0o600); staged.replace(receipt_file)
    return reviewed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-root", type=Path)
    parser.add_argument("--plan", type=Path, required=True)
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--expected-plan-sha256")
    options = parser.parse_args()
    try:
        safe(options.plan.absolute())
        if options.apply:
            raw = options.plan.read_bytes()
            if hashlib.sha256(raw).hexdigest() != options.expected_plan_sha256:
                raise ValueError("Archive plan changed; review it again")
            result = apply(json.loads(raw), options.plan)
        else:
            if options.build_root is None:
                raise ValueError("Choose the project build root")
            result = plan(options.build_root)
            options.plan.parent.mkdir(parents=True, exist_ok=True)
            options.plan.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
            options.plan.chmod(0o600)
        counts = {}
        for item in result["entries"]:
            counts[item["status"]] = counts.get(item["status"], 0) + 1
        print(json.dumps({"counts": counts, "manifest": str(options.plan),
                          "manifest_sha256": hashlib.sha256(options.plan.read_bytes()).hexdigest(), "applications_deleted": 0}, indent=2))
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        raise SystemExit(str(error))


if __name__ == "__main__":
    main()
