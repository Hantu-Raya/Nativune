"""Actual-app cap fuse E2E, using the signed-out owned fixture and solo standard-token launcher.

python experiments/cap-guard/guard_e2e.py <label> <exe> [--harness-root=<checkout>]
Use --arm=<name> to rerun one arm; --rescore reuses its retained numeric evidence.
No account, audio, real-site control latency or long-session claims are made by this fixture.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import statistics
import subprocess
import sys
import time
from pathlib import Path

WT = Path(__file__).resolve().parents[2]
MIB = 1048576
POLICY = {"full": 2, "tray": 1, "compact": 3}
ARMS = {
    "heavy-full": ("full", True, "full@0;compact@125;full@145;quit@185"),
    "light-full": ("full", False, "full@0;quit@100"),
    "heavy-tray": ("tray", True, "full@0;hide@10;show@80;hide@85;quit@125"),
    "heavy-compact": ("compact", True, "full@0;compact@10;full@95;compact@100;quit@145"),
    "light-compact": ("compact", False, "full@0;compact@10;hide@100;show@115;full@145;quit@160"),
    "control-nofuse": ("full", True, "full@0;quit@60"),
    "light-tray": ("tray", False, "full@0;hide@10;show@90;quit@100"),
    "restore-retry": ("full", True, "full@0;quit@65"),
    "policy-isolation": ("full", True, "full@0;compact@55;hide@105;show@145;full@150;quit@185"),
}


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def read_lines(path):
    return [json.loads(line) for line in path.read_text(encoding="utf-8-sig").splitlines() if line.strip()]


def median(rows, key):
    values = [r[key] for r in rows if r.get(key) is not None]
    return statistics.median(values) if values else None


def rates(samples):
    result = []
    for previous, current in zip(samples, samples[1:]):
        elapsed = (current["t"] - previous["t"]) / 1000
        before, after = previous["roles"].get("renderer"), current["roles"].get("renderer")
        if elapsed <= 0 or not before or not after or before[2] != 1 or after[2] != 1:
            continue  # Aggregated fault deltas cannot identify multiple renderers reliably.
        old_cpu = previous.get("roleCpu", {}).get("renderer")
        new_cpu = current.get("roleCpu", {}).get("renderer")
        if old_cpu is None or new_cpu is None or new_cpu < old_cpu:
            continue
        tree_delta = current.get("cpu", 0) - previous.get("cpu", 0)
        result.append({"t": current["t"], "cpu_cores": (new_cpu - old_cpu) / elapsed,
                       "faults_s": ((after[3] - before[3]) & 0xffffffff) / elapsed,
                       "ws_mib": after[0] / MIB, "private_mib": after[1] / MIB,
                       "tree_ws_mib": sum(role[0] for role in current["roles"].values()) / MIB,
                       "tree_cpu_cores": tree_delta / elapsed if tree_delta >= 0 else None})
    return result


def window(rows, start, end):
    return [row for row in rows if start <= row["t"] < end]


def first(events, name):
    return next((event for event in events if event["event"] == name), None)


def cap_events(events, mode, outcome):
    name = {"full": "fullidle-cap", "tray": "tray-cap", "compact": "compact-cap"}[mode]
    return [e for e in events if e["event"] == name and e.get("outcome") == outcome]


def trip_evidence(events, cap, trip, hidden):
    reason = trip.get("reason")
    count, cpu_floor, counter = (3, .15, "fast_strikes") if reason == 1 else (10, .05, "slow_strikes")
    accepted_reason = reason in (1, 4) if hidden else reason == 1
    prior = [e for e in events if e["event"] == "cap-guard-sample"
             and e.get("policy") == trip.get("policy") and cap["t"] <= e["t"] <= trip["t"]]
    tail = prior[-count:]
    consecutive = accepted_reason and len(tail) == count and all(
        e["faults_s"] >= 10_000 and e["cpu_cores"] >= cpu_floor for e in tail)
    counter_ok = trip.get(counter) == count
    bad_start = tail[0]["t"] - tail[0]["sample_ms"] if consecutive else None
    release = next((e for e in events if e.get("outcome") == "released" and e.get("reason") == "fuse"
                    and e["event"] == cap["event"] and e.get("pid") == cap["pid"]
                    and bad_start is not None and bad_start <= e["t"] <= trip["t"]), None)
    exact = next((e for e in events if e["event"] == "renderer-cap-restored" and e.get("pid") == cap["pid"]
                  and bad_start is not None and bad_start <= e["t"] <= trip["t"] and e.get("exact") is True), None)
    released_at = release["t"] if release is not None else trip["t"]
    deadline = 24_000 if hidden else 8000
    return {"consecutive_windows_trip": consecutive and counter_ok,
            "exact_restore_within_deadline": (exact is not None and bad_start is not None and release is not None
                and exact["t"] - bad_start <= deadline and trip.get("restored") == 1),
            "released_at": released_at, "deadline_ms": deadline,
            "release_from_first_bad_window_ms": released_at - bad_start if bad_start is not None else None}


def collect(root, label, since):
    runs = sorted(p for p in (root / ".cache/memory-attribution/runs").glob("*-" + label)
                  if p.stat().st_mtime >= since - 5)
    outputs = sorted(p for p in (root / "artifacts/memory-attribution").glob("*-" + label)
                     if p.stat().st_mtime >= since - 5)
    if not runs or not outputs:
        raise RuntimeError("Solo launcher did not retain a completed uncontaminated run")
    run, out = runs[-1], outputs[-1]
    score = read_json(out / "score.json")
    return {"run": str(run), "output": str(out), "summary": read_json(out / "summary.json"),
            "score": score, "events": read_lines(run / "bench.jsonl"),
            "samples": rates(read_lines(out / "samples.jsonl"))}


def launch(root, label, exe, mode, heavy, schedule, baseline=False, nofuse=False, restore_retry=False, cooldown=None):
    env = {"NATIVUNE_BENCH_FULLIDLE_FIXTURE": "1", "NATIVUNE_BENCH_FULLIDLE_SECONDS": "25"}
    if mode != "full":
        env["NATIVUNE_BENCH_FULLIDLE_CAP_MIB"] = "0"
    if heavy:
        env["NATIVUNE_BENCH_CAP_HEAVY"] = "1"
    if mode != "full" and heavy:
        # Long enough that the hidden cap's return (cooldown + 5 s settle) falls after the 5-15 s recovery window.
        env["NATIVUNE_BENCH_CAP_COOLDOWN_SECONDS"] = "30"
    if cooldown is not None:
        env["NATIVUNE_BENCH_CAP_COOLDOWN_SECONDS"] = str(cooldown)
    if baseline:
        env["NATIVUNE_BENCH_CAP_DISABLED"] = "1"
    if nofuse:
        env["NATIVUNE_BENCH_CAP_NO_FUSE"] = "1"
    if restore_retry:
        env["NATIVUNE_BENCH_CAP_RESTORE_FAIL_ONCE"] = "1"
    command = [sys.executable, str(root / "experiments/memory-attribution/solo.py"), label, str(exe),
               "--signed-out", "--schedule", schedule, "--max-seconds", "240",
               "--start-uri", "https://music.youtube.com/fullidle-fixture",
               "--settings-override", json.dumps({"Version": 7, "X": 100, "Y": 100, "Width": 1280,
                   "Height": 800, "Dpi": 96, "Zoom": 1, "TrayEnabled": True, "AutoCheckUpdates": False,
                   "BetterLyricsEnabled": False, "StartupDestination": 2}),
               "--extra-args=--no-delay-for-dx12-vulkan-info-collection"]
    for key, value in env.items():
        command += ["--env", key + "=" + value]
    since = time.time()
    completed = subprocess.run(command, cwd=root)
    data = collect(root, label, since)
    data.update({"launcher_exit": completed.returncode, "command": subprocess.list2cmdline(command), "env": env})
    return data


def score_arm(arm, data, baseline):
    mode, heavy, _ = ARMS[arm]
    events, samples = data["events"], data["samples"]
    applied = cap_events(events, mode, "applied")
    released = cap_events(events, mode, "released")
    fixture = first(events, "cap-guard-fixture") or {}
    anchor = first(events, "anchor") or {"t": 0}
    checks = {"solo_uncontaminated": not data["score"].get("contaminated"),
              "launcher_and_app_exit_zero": data["launcher_exit"] == 0 and data["score"].get("exit") == 0,
              "owned_fixture": fixture.get("heavy") is heavy and bool(anchor["t"]),
              "build_sha_recorded": bool(re.search(r"\+[0-9a-fA-F]{7,40}", fixture.get("build") or "")),
              "runtime_recorded": bool(fixture.get("runtime")), "cap_applied": bool(applied),
              "cap_60mib_hard_max": bool(applied) and all(e["max"] == 60 * MIB and e["flags"] & 4 for e in applied)}
    metrics = {}
    if baseline:
        checks["baseline_uncontaminated"] = not baseline["score"].get("contaminated")
        checks["baseline_successful_uncapped"] = (baseline["launcher_exit"] == 0
            and baseline["score"].get("exit") == 0
            and not any(e.get("outcome") == "applied" for e in baseline["events"]))
        baseline_fixture = first(baseline["events"], "cap-guard-fixture") or {}
        checks["baseline_same_build_runtime_and_workload"] = all(
            fixture.get(key) == baseline_fixture.get(key) for key in ("build", "runtime", "heavy"))
    if not applied:
        return checks, metrics
    cap = applied[0]
    guard = [e for e in events if e["event"] == "cap-guard-sample" and e.get("policy") == POLICY[mode]]
    trips = [e for e in events if e["event"] == "cap-guard-trip" and e.get("policy") == POLICY[mode]]
    restores = [e for e in events if e["event"] == "renderer-cap-restored"]
    checks["guard_samples_present"] = bool(guard)
    checks["both_guard_counters_reported"] = bool(guard) and all(
        "fast_strikes" in sample and "slow_strikes" in sample for sample in guard)
    checks["all_restorations_exact"] = bool(restores) and all(e.get("exact") is True for e in restores)
    metrics.update({"first_cap_t": cap["t"], "caps": applied, "releases": released,
                    "trips": trips, "restores": restores, "guard_samples": guard})
    uncapped = window(samples, anchor["t"] + 10_000, anchor["t"] + 20_000)
    if baseline:
        entered = first(baseline["events"], "hide-done" if mode == "tray" else "compact-shown")
        uncapped = window(baseline["samples"], entered["t"] + 10_000, entered["t"] + 25_000) if entered else []
    metrics["baseline"] = {key: median(uncapped, key) for key in ("cpu_cores", "faults_s", "tree_ws_mib", "tree_cpu_cores")}
    checks["baseline_numeric_window"] = len(uncapped) >= 8
    if arm == "control-nofuse":
        checks["control_no_trip"] = not trips
        pathological = [e for e in guard if e["faults_s"] >= 10_000 and e["cpu_cores"] >= .15]
        checks["control_exceeds_fuse_thresholds"] = bool(pathological)
        end = released[0]["t"] if released else None
        metrics["control_capped_ms"] = end - cap["t"] if end is not None else None
        checks["control_exposure_at_most_6s"] = end is not None and 0 < end - cap["t"] <= 6000
        return checks, metrics
    if arm == "restore-retry":
        failures = [e for e in events if e["event"] == "renderer-cap-restore-failed"]
        recovered = next((e for e in restores if failures and e["pid"] == cap["pid"] and e["t"] > failures[0]["t"]), None)
        checks["injected_restore_failure_observed"] = bool(failures) and failures[0]["error"] == 5
        checks["timer_retry_exact_within_3s"] = bool(recovered) and recovered["exact"] and recovered["t"] - failures[0]["t"] <= 3000
        checks["restore_came_from_guard_timer"] = bool(released) and released[0].get("reason") == "restore-retry"
        checks["trip_retained_failed_snapshot"] = bool(trips) and trips[0].get("restored") == 0 and trips[0].get("error") == 5
        checks["original_snapshot_preserved"] = bool(recovered) and all(recovered[k] == cap["original" + k[0].upper() + k[1:]] for k in ("min", "max", "flags"))
        checks["no_apply_before_restore_retry"] = bool(recovered) and not any(
            e.get("outcome") == "applied" and failures[0]["t"] < e["t"] < recovered["t"] for e in events)
        metrics["restore_failures"] = failures
        return checks, metrics
    if not heavy:
        end = next((e["t"] for e in released if e["t"] > cap["t"]), 0)
        checks["cap_held_60s"] = end - cap["t"] >= 60_000
        checks["light_no_trip"] = not trips
        checks["continuous_guard_for_60s"] = len(window(guard, cap["t"], cap["t"] + 60_000)) >= 28
        held = window(samples, cap["t"] + 10_000, cap["t"] + 60_000)
        before_ws, held_ws = median(uncapped, "tree_ws_mib"), median(held, "tree_ws_mib")
        saving = before_ws - held_ws if before_ws is not None and held_ws is not None else None
        metrics["whole_tree_private_ws_saving_mib"] = saving
        if mode == "compact":
            baseline_renderer_ws = median(uncapped, "ws_mib")
            saving_threshold = cap["max"] / MIB + 10
            metrics["baseline_renderer_ws_mib"] = baseline_renderer_ws
            metrics["baseline_renderer_ws_kind"] = "private"  # The solo harness samples private WS.
            metrics["saving_gate_minimum_renderer_ws_mib"] = saving_threshold
            if baseline_renderer_ws is None:
                checks["compact_measurable_resident_saving"] = False
            elif baseline_renderer_ws > saving_threshold:
                checks["compact_measurable_resident_saving"] = saving is not None and saving > 0
            else:
                checks["compact_measurable_resident_saving"] = "not_applicable"
            old, new = median(uncapped, "tree_cpu_cores"), median(held, "tree_cpu_cores")
            cpus = os.cpu_count() or 1
            metrics["tree_cpu_added_percentage_points"] = None if old is None or new is None else 100 * (new - old) / cpus
            checks["light_compact_cpu_gate"] = metrics["tree_cpu_added_percentage_points"] is not None and metrics["tree_cpu_added_percentage_points"] <= .2
            hide, show = first(events, "hide-done"), first(events, "show-requested")
            full = first(events, "full-requested")
            tray_caps = cap_events(events, "tray", "applied")
            checks["compact_hidden_handoff_to_tray"] = hide is not None and show is not None and any(
                hide["t"] <= e["t"] < show["t"] for e in tray_caps)
            checks["compact_restore_before_handoff"] = bool(tray_caps) and any(cap["t"] < e["t"] <= tray_caps[0]["t"] for e in released)
            checks["tray_restore_on_show"] = bool(show) and any(e["t"] >= show["t"] and e.get("reason") in ("show", "mode-change") for e in cap_events(events, "tray", "released"))
            checks["return_full_restores_compact"] = bool(full) and any(e["t"] >= full["t"] and e.get("reason") == "full-entry" for e in released)
        return checks, metrics
    checks["fuse_tripped"] = bool(trips)
    if not trips:
        return checks, metrics
    trip = trips[0]
    trip_proof = trip_evidence(events, cap, trip, hidden=mode != "full")
    released_at = trip_proof["released_at"]
    metrics["release_from_first_bad_window_ms"] = trip_proof["release_from_first_bad_window_ms"]
    metrics["fuse_deadline_ms"] = trip_proof["deadline_ms"]
    checks["tier_consecutive_windows_trip"] = trip_proof["consecutive_windows_trip"]
    checks["exact_restore_within_fuse_deadline"] = trip_proof["exact_restore_within_deadline"]
    recovered = window(samples, released_at + 5000, released_at + 15_000)
    metrics["recovery"] = {key: median(recovered, key) for key in ("cpu_cores", "faults_s")}
    checks["recovery_10s_window_within_15s"] = len(recovered) >= 8
    for key, floor, ratio in (("cpu_cores", .05, 1.25), ("faults_s", 2000, 2)):
        before, after = median(uncapped, key), median(recovered, key)
        # CPU gate is baseline + max(.05 core, 25%); faults gate is max(2000, twice baseline).
        ceiling = None if before is None else before + max(floor, before * .25) if key == "cpu_cores" else max(floor, ratio * before)
        checks["recovered_" + key] = after is not None and ceiling is not None and after <= ceiling
        metrics[key + "_recovery_ceiling"] = ceiling
    if mode == "full":
        checks["no_recap_90s"] = samples[-1]["t"] >= released_at + 90_000 and not any(released_at < e["t"] <= released_at + 90_000 for e in applied)
        if arm == "heavy-full":
            departure = first(events, "compact-requested")
            returned = first(events, "full-requested")
            cooldown_end = trip["t"] + trip["cooldown_s"] * 1000
            checks["continuous_full_past_cooldown_without_input"] = (
                departure is not None and departure["t"] >= cooldown_end + 30_000
                and not any(trip["t"] < e["t"] < departure["t"] for e in applied))
            checks["full_mode_roundtrip_does_not_clear_fuse"] = (
                returned is not None and samples[-1]["t"] >= returned["t"] + 30_000
                and not any(e["t"] >= returned["t"] for e in applied))
        if arm == "policy-isolation":
            cooldown_end = trip["t"] + trip["cooldown_s"] * 1000
            for isolated_mode in ("compact", "tray"):
                other_caps = cap_events(events, isolated_mode, "applied")
                other_trips = [e for e in events if e["event"] == "cap-guard-trip"
                               and e.get("policy") == POLICY[isolated_mode]]
                checks[isolated_mode + "_applies_during_full_cooldown"] = any(
                    trip["t"] < e["t"] < cooldown_end for e in other_caps)
                other_proofs = [trip_evidence(events, other_caps[0], other_trip, hidden=True)
                                for other_trip in other_trips] if other_caps else []
                checks[isolated_mode + "_trips_own_fuse"] = any(
                    proof["consecutive_windows_trip"] for proof in other_proofs)
                checks[isolated_mode + "_restores_within_24s"] = any(
                    proof["consecutive_windows_trip"] and proof["exact_restore_within_deadline"]
                    for proof in other_proofs)
                metrics[isolated_mode + "_trip_evidence"] = other_proofs
                metrics[isolated_mode + "_caps"] = other_caps
                metrics[isolated_mode + "_trips"] = other_trips
    else:
        departure = first(events, "show-requested" if mode == "tray" else "full-requested")
        cooldown_end = trip["t"] + trip["cooldown_s"] * 1000
        checks["cooldown_expired_during_same_episode"] = bool(departure) and departure["t"] > cooldown_end + 10_000
        checks["no_recap_during_cooldown"] = not any(trip["t"] < e["t"] < cooldown_end for e in applied)
        # Hidden caps return in the same episode once the cooldown ends (an episode-long latch cost ~140 MB for hours).
        checks["recaps_after_cooldown_same_episode"] = bool(departure) and any(
            cooldown_end <= e["t"] < departure["t"] for e in applied)
        checks["genuine_reentry_rearms"] = bool(departure) and any(e["t"] > departure["t"] for e in applied)
        sweeps = [e for e in events if e["event"] == "cap-heavy-sweep" and e.get("completed")]
        checks["hidden_workload_continues_after_release"] = len(window(sweeps, released_at, released_at + 15_000)) >= 15
        metrics["hidden_sweep_completion_samples"] = sweeps
    return checks, metrics


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("label")
    parser.add_argument("exe", type=Path)
    parser.add_argument("--harness-root", type=Path)
    parser.add_argument("--arm", choices=ARMS)
    parser.add_argument("--rescore", action="store_true")
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", args.label) or args.label in (".", ".."):
        parser.error("label must be a single safe directory name")
    root = args.harness_root or next((p for p in (WT, *WT.parents) if (p / "experiments/memory-attribution/solo.py").exists()), None)
    if root is None:
        parser.error("solo.py not found; pass --harness-root=<maintainer checkout>")
    root, exe = root.resolve(), args.exe.resolve()
    out = WT / "artifacts/cap-guard" / args.label
    out.mkdir(parents=True, exist_ok=True)
    results = {}
    for arm in ([args.arm] if args.arm else ARMS):
        raw = out / (arm + "-evidence.json")
        rerun = subprocess.list2cmdline([sys.executable, str(Path(__file__).resolve()), args.label, str(exe),
                                        "--harness-root=" + str(root), "--arm=" + arm])
        try:
            if args.rescore:
                evidence = read_json(raw)
            else:
                mode, heavy, schedule = ARMS[arm]
                baseline = None
                if mode == "compact" or mode == "tray" and heavy:
                    baseline_schedule = "full@0;compact@10;quit@65" if mode == "compact" else "full@0;hide@10;quit@45"
                    baseline = launch(root, args.label + "-" + arm + "-baseline", exe, mode, heavy, baseline_schedule, baseline=True)
                data = launch(root, args.label + "-" + arm, exe, mode, heavy, schedule,
                              nofuse=arm == "control-nofuse", restore_retry=arm == "restore-retry",
                              cooldown=5 if arm == "heavy-full" else None)
                evidence = {"run": data, "baseline": baseline,
                            "exe_sha256": hashlib.sha256(exe.read_bytes()).hexdigest(),
                            "payload_sha256": {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                                               for p in (exe, exe.with_suffix(".dll")) if p.exists()}}
                raw.write_text(json.dumps(evidence, indent=2), encoding="utf-8")
            checks, metrics = score_arm(arm, evidence["run"], evidence["baseline"])
            fixture = first(evidence["run"]["events"], "cap-guard-fixture") or {}
            match = re.search(r"\+([0-9a-fA-F]{7,40})", fixture.get("build") or "")
            applicable_pass = all(value is True or value == "not_applicable" for value in checks.values())
            report = {"arm": arm, "status": "PASS" if applicable_pass else "FAIL", "checks": checks,
                      "not_applicable_checks": [name for name, value in checks.items() if value == "not_applicable"],
                      "metrics": metrics, "numeric_samples": evidence["run"]["samples"],
                      "build_sha": match.group(1) if match else None, "build": fixture.get("build"),
                      "runtime": fixture.get("runtime"), "exe_sha256": evidence["exe_sha256"],
                      "payload_sha256": evidence["payload_sha256"],
                      "rerun": rerun, "launch_command": evidence["run"]["command"], "evidence": str(raw)}
        except (OSError, ValueError, KeyError, IndexError, RuntimeError) as error:
            report = {"arm": arm, "status": "INVALID", "checks": {"complete_native_evidence": False},
                      "error": str(error), "rerun": rerun}
        (out / (arm + ".json")).write_text(json.dumps(report, indent=2), encoding="utf-8")
        results[arm] = {key: report[key] for key in ("status", "checks", "rerun")}
        print(json.dumps({"arm": arm, "status": report["status"], "checks": report["checks"]}), flush=True)
    overall = {"status": "PASS" if all(r["status"] == "PASS" for r in results.values()) else "FAIL",
               "label": args.label, "arms": results, "suite_complete": len(results) == len(ARMS),
               "scope": "signed-out owned fixture; no signed-in playback/control-latency or two-hour coverage",
               "rerun": subprocess.list2cmdline([sys.executable, str(Path(__file__).resolve()), args.label, str(exe),
                                                 "--harness-root=" + str(root)] + (["--arm=" + args.arm] if args.arm else []))}
    (out / "report.json").write_text(json.dumps(overall, indent=2), encoding="utf-8")
    return 0 if overall["status"] == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
