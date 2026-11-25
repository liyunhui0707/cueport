"""Inspect a trusted native Codex binary's exported schema without opening any user session."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import tempfile


def review(binary):
    binary = binary.resolve(strict=True)
    # Run only an explicitly supplied native arm64 codex, never a shell/npm wrapper.
    if binary.name != "codex" or not binary.is_file():
        raise ValueError("Choose the native binary named codex")
    with binary.open("rb") as stream:
        if stream.read(8) != bytes.fromhex("cffaedfe0c000001"):
            raise ValueError("Choose a native arm64 binary")
    with tempfile.TemporaryDirectory(prefix="cueport-schema-") as directory:
        root = Path(directory)
        output = root / "schema"
        output.mkdir()
        env = {"PATH": "/usr/bin:/bin", "HOME": directory, "CODEX_HOME": directory, "TMPDIR": directory}
        def run(*args):
            return subprocess.run([str(binary), *args], env=env, cwd=root, check=True,
                                  stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=45).stdout
        version = re.fullmatch(rb"codex-cli ([0-9]+\.[0-9]+\.[0-9]+)\s*", run("--version"))
        if not version:
            raise ValueError("Unrecognized version output")
        run("app-server", "generate-json-schema", "--out", str(output))
        def load(name):
            return json.loads((output / name).read_bytes())
        requests = load("ClientRequest.json")
        methods = sorted(m for op in requests["oneOf"] for m in op["properties"]["method"]["enum"])
        thread = load("v2/ThreadReadResponse.json")["definitions"]["Thread"]["properties"]
        names = ("pid", "tty", "iterm", "terminal", "processid", "processbirth", "foreground")
        return {"version": version[1].decode(), "method_count": len(methods),
                "thread_read": "thread/read" in methods, "loaded_list": "thread/loaded/list" in methods,
                "origin_related_thread_fields": sorted(k for k in thread if any(n in k.lower() for n in names)),
                "origin_related_methods_for_review": [m for m in methods if any(n in m.lower() for n in names)],
                "scope": "Schema discovery only. No live terminal binding or version enablement."}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--codex", required=True, type=Path)
    print(json.dumps(review(parser.parse_args().codex), indent=2))
