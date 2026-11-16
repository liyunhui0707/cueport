"""Preview/apply one explicitly owner-approved Codex project trust entry.

Never prints other config values. Default is read-only. No Hook trust, ancestor
trust, approval policy, permissions, endpoint, credential or daemon changes.
"""
import argparse
import datetime
import hashlib
import json
import os
import pathlib
import stat
import tempfile
import tomllib

ROOT = pathlib.Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--apply", action="store_true")
parser.add_argument("--config-file", type=pathlib.Path, default=pathlib.Path.home() / ".codex/config.toml", help="Override only for isolated testing")
parser.add_argument("--output-dir", type=pathlib.Path, default=ROOT / "build/poc", help="Private plan/receipt directory")
args = parser.parse_args()
CONFIG = args.config_file.absolute()
parent_info = CONFIG.parent.lstat()
if not stat.S_ISDIR(parent_info.st_mode) or parent_info.st_uid != os.getuid() or parent_info.st_mode & 0o022:
    raise SystemExit("Config parent ownership/type/mode check failed. Nothing written.")
args.output_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
output_info = args.output_dir.lstat()
if not stat.S_ISDIR(output_info.st_mode) or output_info.st_uid != os.getuid() or output_info.st_mode & 0o077:
    raise SystemExit("Plan/receipt output must be an owned private directory.")
fd = os.open(CONFIG, os.O_RDONLY | os.O_NOFOLLOW)
with os.fdopen(fd, "rb") as handle:
    info = os.fstat(handle.fileno())
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o022 or info.st_size > 1_048_576:
        raise SystemExit("Config ownership/type/size/mode check failed; no values printed or written.")
    original = handle.read()
config = tomllib.loads(original.decode())
project = str(ROOT)
projects = config.get("projects", {})
entry = projects.get(project)
if entry is not None and entry.get("trust_level") == "trusted":
    print(json.dumps({"exact_project_already_trusted": True, "changed": False}))
    raise SystemExit(0)
if entry is not None:
    raise SystemExit("An exact project entry already exists; this append-only plan needs separate review. Nothing written.")
addition = "\n# Explicit project trust approved for the local AAR POC.\n[projects." + json.dumps(project, ensure_ascii=False) + "]\ntrust_level = \"trusted\"\n"
candidate = original + addition.encode()
expected = dict(config)
expected["projects"] = dict(projects)
expected["projects"][project] = {"trust_level": "trusted"}
if tomllib.loads(candidate.decode()) != expected:
    raise SystemExit("Candidate changes more than the exact project entry. Nothing written.")
plan = {"config": "~/.codex/config.toml", "project": project,
        "operation": "append exact project table with trust_level = trusted",
        "original_sha256": hashlib.sha256(original).hexdigest(),
        "other_config_preserved": True, "ancestor_trust_changed": False,
        "hook_trust_changed": False, "approval_policy_changed": False,
        "sensitive_config_values_printed": False, "writes": args.apply}
if not args.apply:
    destination = args.output_dir / "project-trust-plan.json"
    destination.write_text(json.dumps(plan, indent=2) + "\n"); destination.chmod(0o600)
    print(json.dumps(plan, indent=2))
    raise SystemExit(0)
if CONFIG.read_bytes() != original:
    raise SystemExit("Config changed since preview; nothing written.")
backup = CONFIG.with_name("config.toml.aar-trust-backup-" + datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ"))
with backup.open("xb") as handle:
    os.fchmod(handle.fileno(), 0o600); handle.write(original); handle.flush(); os.fsync(handle.fileno())
temp_fd, temporary = tempfile.mkstemp(prefix=".aar-trust-", dir=CONFIG.parent)
try:
    with os.fdopen(temp_fd, "wb") as handle:
        os.fchmod(handle.fileno(), stat.S_IMODE(info.st_mode)); handle.write(candidate); handle.flush(); os.fsync(handle.fileno())
    if CONFIG.read_bytes() != original:
        raise SystemExit("Concurrent config edit detected; backup retained, original config not replaced.")
    os.replace(temporary, CONFIG)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)  # Only this newly created staging file.
plan["backup"] = str(backup)
plan["written_sha256"] = hashlib.sha256(CONFIG.read_bytes()).hexdigest()
receipt = args.output_dir / "project-trust-receipt.json"
receipt.write_text(json.dumps(plan, indent=2) + "\n"); receipt.chmod(0o600)
print(json.dumps(plan, indent=2))
