"""Hidden-page DOM retention E2E (real music.youtube.com, bench-hook build, maintainer's solo launcher).

python experiments/hidden-render/e2e.py --exe artifacts/perf-bench/publish/Nativune.exe [--arms candidate-tray,control-tray,...]

Failure modes this run is built to catch (written before the driver):
  1. maintenance never pulses (dirty flag/timer not wired)          -> no pulse-start events, retained nodes grow per track
  2. pulse fires but releases nothing (hidden HWND blocks rendering) -> retained nodes grow like the control arm
  3. pulse shows the window/container (visible flash)               -> a visible top-level window of the app while hidden
  4. pulse leaves the page rendering (controller stuck visible)      -> document.visibilityState 'visible' while hidden
  5. pulse interrupts playback                                       -> media paused or site clock not advancing
  6. CPU cost / cap fuse                                             -> hidden-phase tree CPU vs control, fuse lines in log
The control arm (NATIVUNE_BENCH_NO_HIDDEN_RENDER=1) must show the leak, or the run proves nothing.
'-home' arms leave the player page for Home (home.ts) before hiding, so song changes no longer change the URL
(the owner's 0.1.40 tray report): 7. maintenance keyed only to route changes stops pulsing there -> nodes grow.
DOM counts come from Memory.getDOMCounters after HeapProfiler.collectGarbage (retained nodes). Tags only; no page text.
"""
from __future__ import annotations

import argparse, ctypes, json, subprocess, sys, threading, time
from ctypes import wintypes as W
from datetime import datetime, timezone
from pathlib import Path

import psutil

WT = Path(__file__).resolve().parents[2]
MAINTAINER = Path("D:/youtube")
RUN = MAINTAINER / "experiments/memory-attribution/run.py"
SAMPLER = WT / "experiments/hidden-render/sampler.ts"
BUN = "C:/Users/Administrator/.bun/bin/bun.exe"
OUT = WT / "artifacts/hidden-render"
SETTINGS = '{"BetterLyricsEnabled":true,"BlockAds":true,"TrayEnabled":true}'
ARMS = {  # name: (env, mode action, seconds until quit)
    "candidate-tray": ([], "hide", 1080),
    "control-tray": (["NATIVUNE_BENCH_NO_HIDDEN_RENDER=1"], "hide", 1080),
    "candidate-compact": ([], "compact", 960),
    "candidate-minimized": ([], "minimize", 960),
    "candidate-tray-home": ([], "hide", 1080),
}
HOME = WT / "experiments/hidden-render/home.ts"
HIDE_AT = 30
HOME_HIDE_AT = 60  # Home arms: playback must start on /watch and the click land before the window hides
u = ctypes.WinDLL("user32", use_last_error=True)
ENUM = ctypes.WINFUNCTYPE(W.BOOL, W.HWND, W.LPARAM)
u.EnumWindows.argtypes = [ENUM, W.LPARAM]
u.GetWindowThreadProcessId.argtypes = [W.HWND, ctypes.POINTER(W.DWORD)]
u.IsWindowVisible.argtypes = [W.HWND]
u.IsIconic.argtypes = [W.HWND]
u.EnumChildWindows.argtypes = [W.HWND, ENUM, W.LPARAM]
u.GetClassNameW.argtypes = [W.HWND, W.LPWSTR, ctypes.c_int]
u.GetParent.argtypes = [W.HWND]
u.GetParent.restype = W.HWND


def class_name(hwnd) -> str:
    buffer = ctypes.create_unicode_buffer(64)
    u.GetClassNameW(hwnd, buffer, 64)
    return buffer.value


def visible_surfaces(pid: int, tray: bool) -> int:
    """Visible app surfaces that must stay hidden: any top-level window in the tray arm, and in every arm the
    browser slot (the 'Static' container child that hosts Chrome_WidgetWin_*), e.g. over Compact."""
    count = 0
    def child(hwnd, _):
        nonlocal count
        if class_name(hwnd).startswith("Chrome_WidgetWin") and class_name(u.GetParent(hwnd)) == "Static" \
                and u.IsWindowVisible(u.GetParent(hwnd)):
            count += 1
        return True
    def top(hwnd, _):
        nonlocal count
        owner = W.DWORD()
        u.GetWindowThreadProcessId(hwnd, ctypes.byref(owner))
        if owner.value == pid and u.IsWindowVisible(hwnd):
            if tray and not u.IsIconic(hwnd):
                count += 1
            u.EnumChildWindows(hwnd, ENUM(child), 0)
        return True
    u.EnumWindows(ENUM(top), 0)
    return count


def run_arm(name: str, exe: Path, out: Path) -> dict:
    env, mode, quit_s = ARMS[name]
    home = name.endswith("-home")
    hide_at = HOME_HIDE_AT if home else HIDE_AT
    started = time.time()
    cmd = [sys.executable, str(RUN), "--label", f"hidden-render-{name}", "--exe", str(exe),
           "--schedule", f"full@0;{mode}@{hide_at};quit@{quit_s}", "--max-seconds", str(quit_s + 200),
           "--extra-args=--remote-debugging-port=9333", "--settings-override", SETTINGS]
    for e in env:
        cmd += ["--env", e]
    launcher = subprocess.Popen(cmd, cwd=MAINTAINER, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    home_proc = subprocess.Popen([BUN, str(HOME), "9333", str(out / f"{name}.home.json")], cwd=WT,
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) if home else None
    run_dir = None
    deadline = time.time() + 180
    while launcher.poll() is None and time.time() < deadline:
        runs = sorted(p for p in (MAINTAINER / ".cache/memory-attribution/runs").glob(f"*-hidden-render-{name}")
                      if p.stat().st_mtime >= started - 5)
        bench = runs[-1] / "bench.jsonl" if runs else None
        if bench and bench.exists() and any(f'"{e}"' in bench.read_text("utf-8") for e in ("hide-done", "compact-shown")):
            run_dir = runs[-1]
            break
        time.sleep(0.5)
    if run_dir is None:
        launcher.kill()
        return {"arm": name, "error": "app did not reach the hidden state"}
    if home_proc is not None:
        home_proc.wait(timeout=120)
    host_pid = json.loads((run_dir / "app-process.json").read_text("utf-8-sig"))["pid"]
    flashes, stop = [], threading.Event()
    def watch():
        time.sleep(2)  # the hidden state was already reached
        while not stop.is_set():
            if psutil.pid_exists(host_pid) and visible_surfaces(host_pid, tray=mode == "hide"):
                flashes.append(time.time())
            time.sleep(0.1)
    watcher = threading.Thread(target=watch, daemon=True); watcher.start()
    samples = out / f"{name}.jsonl"
    sampler = subprocess.run([BUN, str(SAMPLER), "9333", str((quit_s - hide_at - 60) / 60), str(samples), "--gc-each"],
                             cwd=WT, capture_output=True, text=True)
    launch_out = launcher.communicate(timeout=quit_s + 400)[0]
    stop.set()
    artifacts = launch_out.strip().rsplit("->", 1)[-1].strip() if "->" in launch_out else None
    meta = {"arm": name, "runDir": str(run_dir), "artifacts": artifacts, "flashes": flashes, "samplerExit": sampler.returncode,
            "home": json.loads((out / f"{name}.home.json").read_text("utf-8")) if home and (out / f"{name}.home.json").exists() else None}
    (out / f"{name}.meta.json").write_text(json.dumps(meta), encoding="utf-8")
    return score(out, name)


def score(out: Path, name: str) -> dict:
    env, mode, _ = ARMS[name]
    meta = json.loads((out / f"{name}.meta.json").read_text("utf-8"))
    run_dir, samples = Path(meta["runDir"]), out / f"{name}.jsonl"
    rows = [json.loads(l) for l in samples.read_text("utf-8").splitlines() if l.strip()] if samples.exists() else []
    hidden = [r for r in rows if r.get("churn")]
    nodes = [r["nodes"] for r in hidden]
    base = min(nodes) if nodes else None
    events = [json.loads(l) for l in (run_dir / "bench.jsonl").read_text("utf-8").splitlines() if l.strip()]
    log = (run_dir / "data/nativune.log").read_text("utf-8", errors="replace") if (run_dir / "data/nativune.log").exists() else ""
    # A sample taken during a legitimate 1 s pulse may read 'visible'; only visibility outside pulses is a failure.
    starts = [e["t"] for e in events if e["event"] == "pulse-start"]
    ends = [e["t"] for e in events if e["event"] == "pulse-end"]
    windows = [(s - 500, (next((e for e in ends if e >= s), s + 5000)) + 1500) for s in starts]
    in_pulse = lambda t: t is not None and any(a <= t <= b for a, b in windows)
    stuck = [r for r in hidden if r["churn"].get("visibility") != "hidden" and not in_pulse(r.get("ts"))]
    flashes = [f for f in meta["flashes"]]
    cpu = None
    artifacts = meta["artifacts"]
    if artifacts and (MAINTAINER / artifacts / "samples.jsonl").exists():
        s = [json.loads(l) for l in (MAINTAINER / artifacts / "samples.jsonl").read_text("utf-8").splitlines() if l.strip()]
        hid = next(e["t"] for e in events if e["event"] in ("hide-done", "compact-shown"))
        w = [x for x in s if hid + 60_000 <= x["t"] and x.get("cpu") is not None]
        if len(w) > 1:
            cpu = round(100 * (w[-1]["cpu"] - w[0]["cpu"]) / ((w[-1]["t"] - w[0]["t"]) / 1000), 2)  # % of one core
    clock = [r["churn"].get("site") for r in hidden]
    return {
        "arm": name, "env": env, "mode": mode, "runDir": str(run_dir), "artifacts": artifacts,
        "samples": len(hidden), "baselineNodes": base, "maxExcess": (max(nodes) - base) if nodes else None,
        "finalExcess": (nodes[-1] - base) if nodes else None,
        "trackChanges": sum(1 for r in hidden if r["churn"].get("addedTotal", 0) > 5000),
        "pulses": len(starts),
        "visibleOutsidePulse": len(stuck),
        "pausedSamples": sum(1 for r in hidden if r["churn"].get("paused") is not False),
        "clockStalls": sum(1 for a, b in zip(clock, clock[1:]) if a == b),
        "surfaceFlashes": len(flashes), "fuseTrips": log.count("renderer cap fuse"),
        # The cap fuse also trips without pulses (the control arm trips on its first hidden queue re-render);
        # a pulse-caused trip is one logged from pulse start until 10 s after the pulse ends.
        "pulseFuseTrips": sum(1 for line in log.splitlines() if "renderer cap fuse" in line
                              and any(a <= datetime.fromisoformat(line[:23] + line[24:30]).timestamp() * 1000 <= b + 10_000 - 1500
                                      for a, b in windows)),
        "treeCpuPctOneCore": cpu, "samplerExit": meta["samplerExit"],
        "home": meta.get("home"), "offWatchSamples": sum(1 for r in hidden if r["churn"].get("path") != "/watch"),
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--exe", type=Path)
    ap.add_argument("--arms", default=",".join(ARMS))
    ap.add_argument("--rescore", type=Path, help="recompute report.json from a retained output folder")
    a = ap.parse_args()
    names = a.arms.split(",")
    results = []
    if a.rescore:
        out = a.rescore
        for name in names:
            results.append(score(out, name) if (out / f"{name}.meta.json").exists() else {"arm": name, "error": "no retained data"})
    else:
        if a.exe is None:
            ap.error("--exe is required unless --rescore is given")
        exe = (WT / a.exe).resolve() if not a.exe.is_absolute() else a.exe
        out = OUT / datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        out.mkdir(parents=True)
        for name in names:
            result = run_arm(name, exe, out)
            print(json.dumps(result), flush=True)
            results.append(result)
    by = {r["arm"]: r for r in results}
    checks = {f"{r['arm']}: ran ({r['error']})" if "error" in r else f"{r['arm']}: ran": "error" not in r for r in results}
    control = by.get("control-tray")
    if control and "error" not in control:
        checks["control shows the leak (finalExcess >= 25k)"] = control["finalExcess"] >= 25_000
    for r in results:
        if not r["arm"].startswith("candidate") or "error" in r:
            continue
        n = r["arm"]
        checks[f"{n}: >=3 track changes observed"] = r["trackChanges"] >= 3
        checks[f"{n}: pulsed"] = r["pulses"] >= 1
        checks[f"{n}: max retained excess <= 16k (at most one track pending)"] = r["maxExcess"] <= 16_000
        checks[f"{n}: page hidden outside pulses"] = r["visibleOutsidePulse"] == 0
        checks[f"{n}: playing, clock advancing"] = r["pausedSamples"] == 0 and r["clockStalls"] == 0
        checks[f"{n}: no visible window/browser slot"] = r["surfaceFlashes"] == 0
        checks[f"{n}: no pulse-caused cap fuse trip"] = r["pulseFuseTrips"] == 0
        if n.endswith("-home"):
            checks[f"{n}: left /watch for Home while playing"] = bool(r.get("home") and r["home"].get("ok"))
            checks[f"{n}: every hidden sample off /watch"] = r["samples"] > 0 and r["offWatchSamples"] == r["samples"]
    cand = by.get("candidate-tray")
    if cand and control and "error" not in cand and "error" not in control:
        checks["candidate-tray fuse trips <= control"] = cand["fuseTrips"] <= control["fuseTrips"]
    if cand and control and cand.get("treeCpuPctOneCore") is not None and control.get("treeCpuPctOneCore") is not None:
        checks["candidate-tray CPU within +0.5 pp of one core vs control"] = \
            cand["treeCpuPctOneCore"] - control["treeCpuPctOneCore"] <= 0.5
    command = "python experiments/hidden-render/e2e.py " + (f"--rescore {out}" if a.rescore else f"--exe {a.exe}") + " --arms " + a.arms
    report = {"command": command, "results": results, "checks": checks, "passed": bool(checks) and all(checks.values())}
    (out / "report.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps({"checks": checks, "passed": report["passed"], "report": str(out / "report.json")}, indent=2))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
