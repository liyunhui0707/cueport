"""Verify the exact local archive by extraction and helper execution, without installing."""
import hashlib
import argparse
import json
import pathlib
import subprocess
import tempfile
import zipfile

root = pathlib.Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--archive", type=pathlib.Path, default=root / "build/artifacts.noindex/Cueport-local-arm64.zip")
parser.add_argument("--receipt", type=pathlib.Path, default=root / "build/artifact-receipt.json")
options = parser.parse_args()
archive = options.archive.absolute()
with zipfile.ZipFile(archive) as package:
    for name in package.namelist():
        path = pathlib.PurePosixPath(name)
        assert not path.is_absolute() and ".." not in path.parts and "\\" not in name
        assert name == "__MACOSX/" or name.startswith((
            "Cueport.app/", "__MACOSX/Cueport.app/"
        )), "Unexpected content outside the application bundle"
with tempfile.TemporaryDirectory(prefix="aar-archive-") as temporary:
    destination = pathlib.Path(temporary).resolve()
    subprocess.run(["/usr/bin/ditto", "-x", "-k", str(archive), str(destination)], check=True)
    app = destination / "Cueport.app"
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    helper = app / "Contents/MacOS/aar"
    for image in [helper, helper.with_name("CueportApp"), helper.with_name("cueport")]:
        assert subprocess.check_output(["/usr/bin/lipo", "-archs", str(image)]).strip() == b"arm64"
    result = subprocess.run([str(helper), "doctor", "--data-dir", str(destination / "data")], check=True, capture_output=True)
    assert b"Cueport" in result.stdout
    hooks = destination / "hooks.json"
    original = {"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "foreign-tool"}]}]}}
    hooks.write_text(json.dumps(original))
    arguments = ["--hooks-file", str(hooks), "--executable", str(helper), "--data-dir", str(destination / "data")]
    for operation in ["install-hooks", "uninstall-hooks"]:
        subprocess.run([str(helper), operation, *arguments, "--apply"], check=True, capture_output=True)
    assert json.loads(hooks.read_text()) == original
    assert (app / "Contents/Resources/AppIcon.icns").stat().st_size > 0
    receipt = {
        "archive": archive.name,
        "sha256": hashlib.sha256(archive.read_bytes()).hexdigest(),
        "architecture": "arm64",
        "signing": "ad-hoc, no Developer ID",
        "notarization": "not performed",
        "extraction": "pass",
        "application_bundle_only": "pass",
        "codesign_integrity": "pass",
        "packaged_helper_execution": "pass",
        "isolated_packaged_install_uninstall": "pass",
        "real_codex_and_spaces_acceptance": "not tested",
    }
    options.receipt.write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt, indent=2))
