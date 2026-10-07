"""GPU-exit regression: python experiments/full-idle-cap/gpu_crash_tray_e2e.py <label> <exe>.
Rescore retained evidence: python experiments/full-idle-cap/gpu_crash_tray_e2e.py --rescore <label>.
Uses the existing solo launcher, a disposable signed-out profile and muted real media.
Only the verified GPU child is killed; the app exits through its bench schedule.
"""
from __future__ import annotations
import argparse, ctypes, hashlib, json, math, os, pathlib, re, subprocess, sys, threading, time
from datetime import datetime
import psutil
import run as h

MIB = 1024 * 1024
MARGIN = 5 * MIB
WAIT = 20
SCHEDULE = 'full@0;minimize@5;hide@10;quit@65'


def other_hosts(own=None):
    return [p.pid for p in psutil.process_iter(['name'])
            if (p.info['name'] or '').lower() == 'nativune.exe' and p.pid != own]


def owned_tree(pid):
    rows = []
    for p in psutil.Process(pid).children(recursive=True):
        try:
            if p.name().lower() != 'msedgewebview2.exe':
                continue
            cmd = p.cmdline()
            types = [a.split('=', 1)[1] for a in cmd if a.startswith('--type=')]
            rows.append({'pid': p.pid, 'parentPid': p.ppid(), 'type': types[0] if types else 'browser',
                         'createdAt': p.create_time()})
        except psutil.NoSuchProcess:
            continue
    return rows


def renderer_memory(pid):
    kernel = h.k
    kernel.OpenProcess.argtypes = [h.W.DWORD, h.W.BOOL, h.W.DWORD]
    kernel.OpenProcess.restype = h.W.HANDLE
    kernel.CloseHandle.argtypes = [h.W.HANDLE]
    kernel.GetProcessWorkingSetSizeEx.argtypes = [h.W.HANDLE, ctypes.POINTER(ctypes.c_size_t),
                                                ctypes.POINTER(ctypes.c_size_t), ctypes.POINTER(h.W.DWORD)]
    handle = kernel.OpenProcess(0x1000, False, pid)
    if not handle:
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        minimum, maximum, flags = ctypes.c_size_t(), ctypes.c_size_t(), h.W.DWORD()
        if not kernel.GetProcessWorkingSetSizeEx(handle, ctypes.byref(minimum), ctypes.byref(maximum), ctypes.byref(flags)):
            raise ctypes.WinError(ctypes.get_last_error())
        return {'pid': pid, 'workingSetBytes': psutil.Process(pid).memory_info().rss,
                'maximumBytes': maximum.value, 'flags': flags.value}
    finally:
        kernel.CloseHandle(handle)


def gpu_failures(run):
    # OnProcessFailed logs to AppLog, not bench.jsonl. Retain only time/kind, never arbitrary log messages.
    result = []
    for path in (run/'data/nativune.old.log', run/'data/nativune.log'):
        if not path.exists():
            continue
        for line in path.read_text(encoding='utf-8-sig').splitlines():
            match = re.match(r'^(.*?) \[process-failed\] (GpuProcessExited)(?:,|$)', line, re.IGNORECASE)
            if match:
                stamp = datetime.strptime(match[1], '%Y-%m-%d %H:%M:%S.%f %z').timestamp() * 1000
                result.append({'t': stamp, 'kind': 'GpuProcessExited', 'source': path.name})
    return result


def drive(label, marks, errors, stop):
    try:
        started = time.time()
        run = None
        while not stop.is_set() and time.time() - started < 90:
            runs = sorted(r for r in (h.MAINTAINER/'.cache/memory-attribution/runs').glob('*-'+label)
                          if r.stat().st_mtime >= started-5)
            if runs and (runs[-1]/'app-process.json').exists():
                run = runs[-1]
                break
            stop.wait(.2)
        if run is None:
            raise RuntimeError('No app-process identity from the solo launcher')
        marks['run'] = str(run)
        pid = json.loads((run/'app-process.json').read_text(encoding='utf-8-sig'))['pid']
        marks['hostPid'] = pid
        log = run/'bench.jsonl'

        def safe_wait():
            others = other_hosts(pid)
            if others:
                marks['otherHostPids'] = others
                raise RuntimeError('Another Nativune.exe is present; aborting GPU scenario')
            if stop.is_set() or not psutil.Process(pid).is_running():
                raise RuntimeError('App/launcher stopped before evidence capture')
            stop.wait(.2)

        deadline = time.monotonic() + 130
        applied = None
        while time.monotonic() < deadline:
            safe_wait()
            events = h.events(log)
            playing = [e for e in events if e['event'] == 'media-playing']
            if any(e['event'] == 'media-timeout' for e in events):
                raise RuntimeError('Media did not start; GPU scenario is invalid')
            if playing:
                # Do not inject late enough that the scheduled quit can race the 20-second check.
                if time.time()*1000 > playing[0]['t'] + 35000:
                    raise RuntimeError('Tray cap did not apply within 35 seconds of media-playing')
                caps = [e for e in events if e['event'] == 'tray-cap' and e.get('outcome') == 'applied'
                        and e['t'] > playing[0]['t']]
                if caps:
                    applied = caps[-1]
                    break
        if applied is None:
            raise RuntimeError('No tray-cap applied precondition')
        marks['preCap'] = applied
        safe_wait()
        tree = owned_tree(pid)
        marks['treeBefore'] = tree
        gpu = [p for p in tree if p['type'] == 'gpu-process']
        if len(gpu) != 1:
            raise RuntimeError(f'Expected exactly one owned GPU process, got {len(gpu)}')
        target = gpu[0]
        browser = [p for p in tree if p['pid'] == target['parentPid'] and p['type'] == 'browser']
        renderers = [p for p in tree if p['type'] == 'renderer' and p['pid'] == applied['pid']]
        if len(browser) != 1 or len(renderers) != 1:
            raise RuntimeError('GPU browser parent or capped renderer ownership is unverified')
        marks['gpu'] = target
        marks['browser'] = browser[0]
        marks['rendererBefore'] = renderers[0]
        # psutil rechecks process identity before kill, protecting against PID reuse.
        process = psutil.Process(target['pid'])
        if process.create_time() != target['createdAt'] or process.ppid() != browser[0]['pid']:
            raise RuntimeError('GPU identity changed before injection')
        safe_wait()
        marks['killAt'] = time.time()*1000
        killed_at = time.monotonic()
        process.kill()
        marks['killCount'] = 1
        process.wait(timeout=5)
        while time.monotonic() - killed_at < WAIT:
            safe_wait()
        marks['treeAfter'] = owned_tree(pid)
        marks['rendererMemory'] = renderer_memory(applied['pid'])
        marks['checkedAt'] = time.time()*1000
        marks['elapsedSeconds'] = time.monotonic() - killed_at
        # Let one fresh 1-second page sample confirm continued progress at the check boundary.
        until = time.monotonic() + 3
        while time.monotonic() < until:
            safe_wait()
        marks['evidenceEndAt'] = time.time()*1000
        marks['otherHostPids'] = other_hosts(pid)
        while not stop.is_set():
            others = other_hosts(pid)
            if others:
                marks['otherHostPids'] = others
                raise RuntimeError('Another Nativune.exe appeared before launcher completion')
            stop.wait(.2)
    except Exception as exc:
        errors.append(str(exc))


def score(report):
    marks = report.get('marks', {})
    kill, end = marks.get('killAt', 0), marks.get('checkedAt', 0)
    pre = marks.get('preCap', {})
    events = report.get('capEvents', [])
    through_end = [e for e in events if pre.get('t', math.inf) <= e['t'] <= end]
    active = None
    for event in through_end:
        if event.get('outcome') == 'applied':
            active = event
        elif event.get('outcome', '').startswith('released'):
            active = None
    failure_releases = [e for e in through_end if e['t'] >= kill and e.get('reason') == 'process-failed'
                        and e.get('outcome', '').startswith('released')]
    reapplied = bool(failure_releases and active and active['t'] > failure_releases[-1]['t'])
    report['capDisposition'] = 're-applied' if reapplied else 'released-not-reapplied' if failure_releases else 'retained'
    memory = marks.get('rendererMemory', {})
    cap = pre.get('max', 0)
    gpu, browser = marks.get('gpu', {}), marks.get('browser', {})
    before = marks.get('rendererBefore', {})
    after = marks.get('treeAfter', [])
    renderer_unchanged = bool(before and any(p == before for p in after))
    # Secondary renderers (e.g. the extension renderer) may exit with the GPU process; only the capped page renderer must survive.
    report['otherRenderersChanged'] = sorted(p['pid'] for p in marks.get('treeBefore', []) if p['type'] == 'renderer') != sorted(
        p['pid'] for p in after if p['type'] == 'renderer')
    failures = [e for e in report.get('gpuFailureEvents', []) if kill <= e['t'] <= marks.get('evidenceEndAt', end)]
    samples = [e for e in report.get('mediaSamples', []) if kill <= e['t'] <= marks.get('evidenceEndAt', end)]
    near_end = [e for e in samples if end-1500 <= e['t'] <= end+3500]
    playing = bool(near_end and len(samples) >= 2 and near_end[-1].get('paused') is False
                   and isinstance(near_end[-1].get('currentTime'), (int, float))
                   and isinstance(samples[0].get('currentTime'), (int, float))
                   and near_end[-1]['currentTime'] > samples[0]['currentTime'] + 5)
    report['checks'] = {
        'A_trayCapAppliedBeforeKill': bool(kill and pre.get('outcome') == 'applied' and pre.get('t', math.inf) < kill),
        'B_onlyOwnedGpuKilledRendererUnchanged': bool(marks.get('killCount') == 1 and gpu and browser
            and len([p for p in marks.get('treeBefore', []) if p['type'] == 'gpu-process']) == 1
            and gpu['parentPid'] == browser['pid'] and renderer_unchanged
            and any(p == browser for p in after)),
        'C_gpuProcessFailureReported': bool(kill and failures),
        'D_trayCapActiveAfter20Seconds': bool(marks.get('elapsedSeconds', 0) >= WAIT and active
            and active.get('pid') == pre.get('pid') and cap > 0 and memory
            and memory.get('maximumBytes') == cap and memory.get('flags', 0) & 4
            and memory.get('workingSetBytes', math.inf) <= cap + MARGIN),
        'E_playbackContinuesCleanExitNoOtherHosts': bool(playing and report.get('appExit') == 0
            and report.get('launcherExit') == 0 and not marks.get('otherHostPids') and report.get('initialSolo')),
    }
    report['passed'] = all(report['checks'].values()) and not report['errors']
    valid = all(report['checks'][key] for key in ('A_trayCapAppliedBeforeKill',
                 'B_onlyOwnedGpuKilledRendererUnchanged', 'C_gpuProcessFailureReported')) and not report['errors']
    report['status'] = 'PASS' if report['passed'] else 'FAIL' if valid else 'INVALID'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rescore', action='store_true')
    parser.add_argument('label')
    parser.add_argument('exe', nargs='?')
    args = parser.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9_-]+', args.label):
        parser.error('label must contain only letters, digits, underscores or hyphens')
    out = h.OUT/('gpu-crash-'+args.label)
    path = out/'report.json'
    if args.rescore:
        report = json.loads(path.read_text(encoding='utf-8'))
    else:
        if not args.exe:
            parser.error('exe is required unless --rescore is used')
        exe = pathlib.Path(args.exe).resolve()
        if not exe.is_file():
            parser.error(f'Executable not found: {exe}')
        out.mkdir(parents=True, exist_ok=True)
        marks, errors, stop = {}, [], threading.Event()
        report = {'label': args.label, 'exe': str(exe), 'errors': errors, 'marks': marks,
                  'schedule': SCHEDULE, 'waitSeconds': WAIT, 'workingSetMarginBytes': MARGIN,
                  'initialSolo': not other_hosts(), 'binarySha256': hashlib.sha256(exe.read_bytes()).hexdigest()}
        if exe.with_suffix('.dll').exists():
            report['dllSha256'] = hashlib.sha256(exe.with_suffix('.dll').read_bytes()).hexdigest()
        if not report['initialSolo']:
            errors.append('Another Nativune.exe is present; launch aborted')
        else:
            label = 'gpu-crash-'+args.label
            command = [sys.executable, str(h.SOLO), label, str(exe), '--schedule', SCHEDULE, '--signed-out',
                       '--extra-args=--no-delay-for-dx12-vulkan-info-collection',
                       '--env', 'NATIVUNE_BENCH_STATS_SECONDS=1', '--env', 'NATIVUNE_BENCH_FULLIDLE_CAP_MIB=60']
            (out/'command.txt').write_text(subprocess.list2cmdline(command)+'\n', encoding='utf-8')
            monitor = threading.Thread(target=drive, args=(label, marks, errors, stop))
            monitor.start()
            try:
                result = subprocess.run(command, cwd=h.ROOT, env=dict(os.environ, SOLO_ATTEMPTS='1', SOLO_QUIET_SECONDS='10'),
                                        capture_output=True, text=True)
                report['launcherExit'] = result.returncode
                (out/'launcher.log').write_text(result.stdout+result.stderr, encoding='utf-8')
            except Exception as exc:
                errors.append(str(exc))
            finally:
                stop.set()
                monitor.join()
            if 'run' in marks:
                run = pathlib.Path(marks['run'])
                events = h.events(run/'bench.jsonl')
                report['capEvents'] = [e for e in events if e['event'] == 'tray-cap']
                report['gpuFailureEvents'] = gpu_failures(run)
                report['mediaSamples'] = [e for e in events if e['event'] == 'media-sample']
                report['mediaSamples'] += [{'t': e['t'], 'paused': e['page'].get('paused'), 'currentTime': e['page'].get('t')}
                                          for e in events if e['event'] == 'page-stats']
                report['mediaSamples'].sort(key=lambda e: e['t'])
                exit_path = run/'app-exit.json'
                if exit_path.exists():
                    report['appExit'] = json.loads(exit_path.read_text(encoding='utf-8-sig')).get('exitCode')
    score(report)
    path.write_text(json.dumps(report, indent=2)+'\n', encoding='utf-8')
    print(json.dumps({key: report[key] for key in ('label', 'status', 'passed', 'checks', 'errors')}))
    return 0 if report['passed'] else 2 if report['status'] == 'INVALID' else 1


if __name__ == '__main__':
    sys.exit(main())
