"""Isolated executable tests. Uses synthetic data, never the user's Codex configuration."""
import concurrent.futures
import json
import os
import pathlib
import statistics
import subprocess
import tempfile
import time
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
CLI = ROOT / "build/swift/debug/aar"


class CLITests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="aar-cli-")
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name).resolve()
        self.env = {k: v for k, v in os.environ.items() if k in {"PATH", "TMPDIR", "LANG"}}
        self.env["ITERM_SESSION_ID"] = "w0t0p0:12345678-1234-1234-1234-123456789ABC"

    def command(self, *args, payload=None):
        return subprocess.run([str(CLI), *args], input=payload, env=self.env, capture_output=True, check=True)

    def test_dependency_probe_rejects_wrappers_and_fifos_without_running_them(self):
        for kind in ["script", "fifo"]:
            directory = self.root / kind
            directory.mkdir()
            executable = directory / "codex"
            if kind == "fifo":
                os.mkfifo(executable, 0o700)
            else:
                executable.write_text("#!/bin/sh\nprintf 'codex-cli 0.169.0\\n'\n")
                executable.chmod(0o700)
            result = subprocess.run([str(CLI), "check-bridge-dependencies", "--native-codex", str(executable)],
                                    env=self.env, capture_output=True, timeout=2)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(b"Supported native Codex versions", result.stderr)

    @unittest.skipUnless(pathlib.Path("/Applications/iTerm.app/Contents/Resources/utilities/it2").is_file(), "iTerm utility required")
    def test_native_version_probe_accepts_a_slow_initial_native_launch(self):
        source = self.root / "slow.c"
        source.write_text('extern unsigned sleep(unsigned); extern int puts(const char*); int main(void) { sleep(6); puts("codex-cli 0.169.0"); return 0; }')
        fixture = self.root / "codex"
        subprocess.run(["/usr/bin/clang", str(source), "-o", str(fixture)], check=True, capture_output=True, timeout=20)
        result = subprocess.run([str(CLI), "check-bridge-dependencies", "--native-codex", str(fixture)],
                                env=self.env, capture_output=True, timeout=12)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(b"0.169.0", result.stdout)

    def hook(self, index=0):
        payload = {"hook_event_name": "PostToolUse", "session_id": f"session-{index % 10}", "turn_id": "turn", "tool_name": "request_user_input_async", "tool_use_id": f"call-{index}", "cwd": "/private/SECRET/project", "tool_input": {"questions": [{"title": "SECRET QUESTION"}, {"title": "SECOND SECRET"}]}, "tool_response": {"accepted": True}, "transcript_path": "/SECRET/TRANSCRIPT"}
        return self.command("hook", "--data-dir", str(self.root / "data"), payload=json.dumps(payload).encode())

    def test_hook_silent_redacted_and_deduplicated(self):
        a = self.hook(); b = self.hook()
        self.assertEqual(a.stdout + a.stderr + b.stdout + b.stderr, b"")
        files = list((self.root / "data/inbox").glob("*.json"))
        self.assertEqual(len(files), 1)
        text = files[0].read_text()
        self.assertNotIn("SECRET", text)
        self.assertEqual(len(json.loads(text)["questionIDs"]), 2)
        self.assertEqual(files[0].stat().st_mode & 0o777, 0o600)

    def test_malformed_hook_never_blocks_codex(self):
        result = self.command("hook", "--data-dir", str(self.root / "data"), payload=b"not json")
        self.assertEqual(result.stdout + result.stderr, b"")
        self.assertFalse((self.root / "data").exists())

    def test_complete_json_does_not_wait_for_stdin_close(self):
        process = subprocess.Popen([str(CLI), "hook", "--data-dir", str(self.root / "data")], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=self.env)
        try:
            process.stdin.write(b'{"hook_event_name":"Stop","session_id":"s","turn_id":"t"}')
            process.stdin.flush()
            self.assertEqual(process.wait(timeout=2), 0)
            self.assertEqual(process.stdout.read() + process.stderr.read(), b"")
            self.assertEqual(len(list((self.root / "data/inbox").glob("*.json"))), 1)
        finally:
            if process.poll() is None:
                process.kill(); process.wait(timeout=2)
            process.stdin.close(); process.stdout.close(); process.stderr.close()

    def test_install_preview_merge_backup_idempotent_and_uninstall(self):
        hooks = self.root / "hooks.json"
        original = {"description": "preserve", "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "foreign-tool"}]}]}}
        hooks.write_text(json.dumps(original))
        args = ["--hooks-file", str(hooks), "--executable", str(CLI), "--data-dir", str(self.root / "data")]
        self.command("install-hooks", *args)
        self.assertEqual(json.loads(hooks.read_text()), original)
        self.command("install-hooks", *args, "--apply")
        once = hooks.read_bytes()
        self.command("install-hooks", *args, "--apply")
        self.assertEqual(once, hooks.read_bytes())
        self.assertEqual(len(list(self.root.glob("hooks.json.aar-backup-*"))), 2)
        self.command("uninstall-hooks", *args, "--apply")
        self.assertEqual(json.loads(hooks.read_text()), original)

    def test_concurrent_hook_delivery(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(self.hook, range(100)))
        self.assertTrue(all(not r.stdout and not r.stderr for r in results))
        files = list((self.root / "data/inbox").glob("*.json"))
        self.assertEqual(len(files), 100)
        self.assertEqual(len({json.loads(p.read_text())["id"] for p in files}), 100)

    def test_bridge_cannot_override_endpoint_or_submit_startup_prompt(self):
        for forbidden in [["--remote", "ws://SECRET"], ["SECRET STARTUP PROMPT"], ["--dangerously-bypass-hook-trust"],
                          ["resume", "--last"], ["resume", "--remote", "ws://SECRET"],
                          ["resume", "12345678-1234-1234-1234-123456789abc", "SECRET PROMPT"],
                          ["resume", "--dangerously-bypass-hook-trust"], ["resume", "SECRET NAME"]]:
            result = subprocess.run([str(CLI), "codex", "--data-dir", str(self.root / "bridge"), "--", *forbidden],
                                    env=self.env, capture_output=True)
            self.assertEqual(result.returncode, 1)
            self.assertNotIn(b"SECRET", result.stdout + result.stderr)
            self.assertFalse((self.root / "bridge").exists())

    def test_resume_forms_reach_terminal_guard_without_starting_native_client(self):
        for index, arguments in enumerate([["resume"], ["resume", "12345678-1234-1234-1234-123456789abc"]]):
            data = self.root / f"resume-{index}"
            result = subprocess.run([str(CLI), "codex", "--data-dir", str(data), "--", *arguments],
                                    input=b"", env=self.env, capture_output=True)
            self.assertEqual(result.returncode, 1)
            diagnostic = json.loads((data / "bridge-launch-diagnostic.json").read_text())
            self.assertFalse(diagnostic["stdin_is_terminal"])
            self.assertEqual(diagnostic["failed_stage"], "foreground-terminal")
            self.assertEqual(list(data.glob("bridge-*.json")), [data / "bridge-launch-diagnostic.json"])

    def test_project_trust_preview_and_apply_preserve_other_settings(self):
        config = self.root / "config.toml"
        original = b'api_key = "SYNTHETIC-SECRET"\n[projects."/foreign"]\ntrust_level = "untrusted"\n'
        config.write_bytes(original); config.chmod(0o600)
        arguments = ["python3", str(ROOT / "scripts/project_trust.py"), "--config-file", str(config), "--output-dir", str(self.root / "plans")]
        preview = subprocess.run(arguments, check=True, capture_output=True)
        self.assertEqual(config.read_bytes(), original)
        self.assertNotIn(b"SYNTHETIC-SECRET", preview.stdout + preview.stderr)
        result = subprocess.run([*arguments, "--apply"], check=True, capture_output=True)
        self.assertNotIn(b"SYNTHETIC-SECRET", result.stdout + result.stderr)
        self.assertTrue(config.read_bytes().startswith(original))
        self.assertEqual(len(list(self.root.glob("config.toml.aar-trust-backup-*"))), 1)
        self.assertEqual(next(self.root.glob("config.toml.aar-trust-backup-*")).read_bytes(), original)
        once = config.read_bytes()
        subprocess.run([*arguments, "--apply"], check=True, capture_output=True)
        self.assertEqual(config.read_bytes(), once)

    def test_project_trust_refuses_symlink_and_existing_untrusted_entry(self):
        target = self.root / "target.toml"; target.write_text('value = "SYNTHETIC-SECRET"\n')
        config = self.root / "config.toml"; config.symlink_to(target)
        arguments = ["python3", str(ROOT / "scripts/project_trust.py"), "--config-file", str(config), "--output-dir", str(self.root / "plans")]
        result = subprocess.run([*arguments, "--apply"], capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(b"SYNTHETIC-SECRET", result.stdout + result.stderr)
        config.unlink()
        original = ('[projects.' + json.dumps(str(ROOT)) + ']\ntrust_level = "untrusted"\n').encode()
        config.write_bytes(original)
        result = subprocess.run([*arguments, "--apply"], capture_output=True)
        self.assertNotEqual(result.returncode, 0); self.assertEqual(config.read_bytes(), original)


if __name__ == "__main__":
    unittest.main(verbosity=2)
