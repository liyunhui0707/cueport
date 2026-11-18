"""Build the static product site from explicitly selected published-release facts."""
import argparse
import html
import json
from pathlib import Path
import re
import shutil

ROOT = Path(__file__).resolve().parent.parent


def build(output, release_file=ROOT / "website/release.json"):
    facts = json.loads(release_file.read_text())
    version = facts["version"]
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+-(?:alpha|beta|rc)\.[1-9][0-9]*", version):
        raise ValueError("Choose an explicit experimental release version")
    release = "https://github.com/liyunhui0707/cueport/releases/tag/v" + version
    download = "https://github.com/liyunhui0707/cueport/releases/download/v" + version + ("/AgentAttentionRouter-" if version == "0.1.0-alpha.3" else "/Cueport-") + version + "-macos-arm64.zip"
    if facts["release_url"] != release or facts["download_url"] != download or not re.fullmatch(r"[a-f0-9]{64}", facts["sha256"]):
        raise ValueError("Release facts contain a mismatched target or digest")
    replacements = {"VERSION": version, "RELEASE_URL": release, "DOWNLOAD_URL": download,
        "SHA256": facts["sha256"], "SUPPORTED_CODEX": " / ".join(facts["supported_codex"]),
        "NOTICE": facts["notice"], "ENTRY_DESCRIPTION": facts["entry_description"],
        "RECOVERY_DESCRIPTION": facts["recovery_description"]}
    source = (ROOT / "website/index.html").read_text()
    for key, value in replacements.items():
        source = source.replace("@@" + key + "@@", html.escape(value, quote=True))
    if re.search(r"@@[A-Z_]+@@", source):
        raise ValueError("Unresolved site content")
    output.mkdir(parents=True, exist_ok=True)
    (output / "index.html").write_text(source)
    for name in ["styles.css", "site.js", "cueport.svg", "release.json"]:
        shutil.copyfile(release_file if name == "release.json" else ROOT / "website" / name, output / name)
    (output / ".nojekyll").write_text("")
    return facts


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    options = parser.parse_args()
    facts = build(options.output)
    print(json.dumps({"built": str(options.output), "published_version_selected": facts["version"], "deployment_performed": False}))
