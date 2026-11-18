"""Ten-minute isolated receiver RSS/CPU measurement and read-only live cohort.

Requires a logged-in macOS session and process inspection. Never starts Codex,
reads terminal content, changes the real receiver, or stops an existing worker.
All process identities/results remain in private ignored build evidence.
"""
import datetime
import hashlib
import json
import os
import pathlib
import plistlib
import shutil
import signal
import statistics
import subprocess
import time
import uuid
from manage_install import fingerprint

ROOT = pathlib.Path(__file__).resolve().parent.parent
APP = pathlib.Path(os.environ.get("AAR_REVIEW_APP", str(ROOT / "build/artifacts.noindex/Cueport.app")))
BASE = pathlib.Path(os.environ.get("AAR_RESOURCE_OUTPUT", str(ROOT / "build/poc/resources169")))
DURATION, INTERVAL, WARMUP = 600, 5, 10


def interrupted(signum, frame):
    raise SystemExit("Owned resource measurement interrupted")


signal.signal(signal.SIGTERM, interrupted)


def save(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n")
    path.chmod(0o600)


def run(arguments, **kwargs):
    return subprocess.run(arguments, capture_output=True, text=True, timeout=15,
                          env={**os.environ, "LC_ALL": "C"}, **kwargs)


def cpu_seconds(value):
    days, clock = value.split("-", 1) if "-" in value else ("0", value)
    fields = clock.split(":")
    assert 1 <= len(fields) <= 3
    return int(days) * 86400 + sum(float(v) * 60 ** i for i, v in enumerate(reversed(fields)))


def sample(identities):
    result = run(["/bin/ps", "-ww", "-p", ",".join(str(p) for p in identities),
                  "-o", "pid=,lstart=,rss=,time=,comm="])
    assert result.returncode in (0, 1), "Process resource query failed"
    values = {}
    for line in result.stdout.splitlines():
        fields = line.split(None, 8)
        assert len(fields) == 9, "Unexpected process resource format"
        pid = int(fields[0])
        if pid not in identities or fields[8] != identities[pid]["executable"]:
            continue
        values[pid] = {"start": " ".join(fields[1:6]), "rss_mib": int(fields[6]) / 1024,
                       "cpu_s": cpu_seconds(fields[7])}
    return time.monotonic(), values


def live_cohort():
    # Candidate measurement must not silently redefine the live daily cohort.
    legacy = ROOT / "build/Agent Attention Router.app"
    installed = pathlib.Path.home() / "Applications/Agent Attention Router.app"
    daily = installed if installed.exists() else legacy
    cueport = pathlib.Path.home() / "Applications/Cueport.app"
    receivers = {str(cueport / "Contents/MacOS/CueportApp"), str(daily / "Contents/MacOS/AgentAttentionRouter"),
                 str(legacy / "Contents/MacOS/AgentAttentionRouter")}
    helpers = {str(cueport / "Contents/MacOS/cueport"), str(cueport / "Contents/MacOS/aar"), str(daily / "Contents/MacOS/aar"), str(legacy / "Contents/MacOS/aar")}
    result = run(["/bin/ps", "-ww", "-axo", "pid=,comm="], check=True)
    identities = {}
    for line in result.stdout.splitlines():
        pid_text, executable = line.strip().split(None, 1)
        if executable not in receivers | helpers:
            continue
        pid = int(pid_text)
        role = "live_receiver"
        if executable in helpers:
            # Only inspect argv of an exact packaged helper. Do not retain argv,
            # configuration/ticket paths, environments or any tool arguments.
            args = run(["/bin/ps", "-ww", "-p", str(pid), "-o", "args="])
            if not args.stdout.strip().startswith(executable + " bridge-worker --configuration "):
                continue
            role = "live_bridge_worker"
        identities[pid] = {"role": role, "executable": executable}
    return identities


def summarize(samples, expected_count):
    if not samples:
        return {"samples": 0, "complete": False}
    elapsed = samples[-1]["elapsed_s"] - samples[0]["elapsed_s"]
    cpu = samples[-1]["cpu_s"] - samples[0]["cpu_s"]
    return {"samples": len(samples), "complete": len(samples) == expected_count,
            "duration_s": round(elapsed, 3), "mean_rss_mib": round(statistics.mean(s["rss_mib"] for s in samples), 3),
            "max_rss_mib": round(max(s["rss_mib"] for s in samples), 3),
            "first_rss_mib": round(samples[0]["rss_mib"], 3), "last_rss_mib": round(samples[-1]["rss_mib"], 3),
            "cpu_seconds": round(cpu, 3),
            "interval_cpu_percent": round(100 * cpu / elapsed, 5) if elapsed else None}


def main():
    os.umask(0o077)
    BASE.mkdir(parents=True, exist_ok=True); BASE.chmod(0o700)
    directory = BASE / ("run-" + uuid.uuid4().hex)
    directory.mkdir(mode=0o700)
    clone = directory / "ResourceMeasurement.app"
    source_fingerprint = fingerprint(APP)
    source_executable_sha256 = hashlib.sha256((APP / "Contents/MacOS/CueportApp").read_bytes()).hexdigest()
    shutil.copytree(APP, clone)
    assert fingerprint(clone) == source_fingerprint, "Source bundle changed during measurement staging"
    bundle_id = "org.agentattentionrouter.resource-measurement." + uuid.uuid4().hex
    info = clone / "Contents/Info.plist"
    values = plistlib.loads(info.read_bytes())
    # Keep the selected artifact's presentation. Forcing a daily bundle into
    # review mode adds a permanently drawn TEST title absent from shipping idle
    # behavior, including its font/layout allocations. Isolation comes from the
    # unique bundle ID and explicit private data root, not from that UI label.
    channel = values.get("AARBuildChannel", "daily")
    assert channel in ("daily", "review"), "Unknown artifact channel"
    validation_label = values.get("AARValidationBuild", False)
    values.update(CFBundleIdentifier=bundle_id, CFBundleDisplayName="Cueport Resource Measurement")
    info.write_bytes(plistlib.dumps(values))
    run(["/usr/bin/codesign", "--force", "--sign", "-", "--identifier", bundle_id, str(clone)], check=True)
    executable = clone / "Contents/MacOS/CueportApp"
    data = directory / "data"
    identities = live_cohort()
    started_at = datetime.datetime.now(datetime.timezone.utc).isoformat()
    process = None
    log = (directory / "app.log").open("wb")
    try:
        process = subprocess.Popen([str(executable), "--data-dir", str(data), "--no-notifications"], stdout=log, stderr=log)
        ready, deadline = None, time.monotonic() + 20
        while time.monotonic() < deadline:
            assert process.poll() is None, "Owned receiver exited before ready"
            try:
                health = json.loads((data / "runtime-health.json").read_text())
                if health["pid"] == process.pid and health["monitoring"] == "ready" and health["buildComparison"] == "current":
                    ready = health; break
            except (FileNotFoundError, json.JSONDecodeError):
                pass
            time.sleep(0.05)
        assert ready, "Owned receiver did not report current ready health"
        identities[process.pid] = {"role": "isolated_empty_receiver", "executable": str(executable)}
        time.sleep(WARMUP)
        start, initial = sample(identities)
        assert process.pid in initial
        # Fix the cohort and lifetime at the first sample. Exited/reused PIDs
        # are never replaced or adopted. lstart is only a resource guard.
        identities = {p: {**identity, "start": initial[p]["start"]} for p, identity in identities.items() if p in initial}
        series = {p: [] for p in identities}
        retired, ticks = set(), []
        print(json.dumps({"phase": "measuring", "duration_s": DURATION, "live_receivers": sum(v["role"] == "live_receiver" for v in identities.values()),
                          "live_workers": sum(v["role"] == "live_bridge_worker" for v in identities.values()), "evidence": str(directory)}), flush=True)
        current, resources = start, initial
        for tick in range(DURATION // INTERVAL + 1):
            if tick:
                time.sleep(max(0, start + tick * INTERVAL - time.monotonic()))
                assert process.poll() is None, "Owned receiver exited during measurement"
                current, resources = sample(identities)
            ticks.append(current - start)
            for pid, identity in identities.items():
                value = resources.get(pid)
                if value is None or value["start"] != identity["start"]:
                    retired.add(pid)
                if pid not in retired:
                    series[pid].append({"elapsed_s": current - start, "rss_mib": value["rss_mib"], "cpu_s": value["cpu_s"]})
            assert process.pid not in retired, "Owned receiver identity changed"
            if tick and tick % 12 == 0:
                owned = series[process.pid][-1]
                print(json.dumps({"elapsed_s": round(current - start, 1), "isolated_rss_mib": round(owned["rss_mib"], 2),
                                  "live_cohort_retired": len(retired)}), flush=True)
        results = {str(p): {**identity, **summarize(series[p], len(ticks))} for p, identity in identities.items()}
        empty = results[str(process.pid)]
        max_gap = max(b - a for a, b in zip(ticks, ticks[1:]))
        qualified = empty["complete"] and empty["duration_s"] >= DURATION and max_gap < INTERVAL * 2
        state = json.loads((data / "state.json").read_text()) if (data / "state.json").exists() else {}
        assert not state.get("sessions") and not state.get("processed")
        assert not state.get("pendingNotifications") and not state.get("notificationReceipts")
        report = {"started_at_utc": started_at, "receiver_build": ready["build"].get("running"),
                  "presentation_channel": channel, "validation_label": validation_label,
                  "source_executable_sha256": source_executable_sha256,
                  "source_bundle_fingerprint": source_fingerprint,
                  "duration_target_s": DURATION, "warmup_s": WARMUP, "sample_interval_s": INTERVAL,
                  "max_sample_gap_s": round(max_gap, 3), "qualified_timing": qualified,
                  "isolated_empty": empty, "processes": results,
                  "idle_target": {"cpu_below_one_percent": qualified and empty["interval_cpu_percent"] < 1,
                                  "all_sampled_rss_below_80_mib": qualified and empty["max_rss_mib"] < 80},
                  "notes": ["RSS from ps KiB; CPU-time delta / monotonic elapsed, one core=100%; counter resolution 0.01s.",
                            "Live fixed cohort is observational, uncontrolled workload; exits invalidate full-cohort duration.",
                            "Source presentation retained; historical forced-review TEST-label results remain separate.",
                            "No native Codex/daemon/model resources included; summed RSS can double-count shared pages.",
                            "No input, banners, focus, permissions, real-store writes or changes to live processes."]}
        save(directory / "samples.json", {"ticks_s": ticks, "processes": series})
        save(directory / "results.json", report)
        save(BASE / "latest.json", {"directory": str(directory), "results": report})
        print(json.dumps({"phase": "complete", "qualified_timing": qualified, "isolated_empty": empty,
                          "idle_target": report["idle_target"]}), flush=True)
        # Profiling is strictly after the measured interval, and only the
        # content-free owned clone. Never map memory of a real bridge worker.
        profile = run(["/usr/bin/vmmap", "-summary", str(process.pid)])
        (directory / "isolated-vmmap-summary.txt").write_text(profile.stdout + profile.stderr)
        save(directory / "profile-status.json", {"exit_code": profile.returncode, "after_timed_interval": True})
    finally:
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill(); process.wait(timeout=5)
        log.close()


if __name__ == "__main__":
    main()
