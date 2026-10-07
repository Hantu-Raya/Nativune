"""E2E: the app log's memory trail survives a page renderer crash.

python experiments/memory-trail/trail_e2e.py <label> <bench exe>
Report: artifacts/memory-trail/<label>/report.json

Ways it can fail (checked below):
 A no [memory-trail] rows, a wrong heap limit (flag not applied), non-numeric fields or status != ok
 B the cached row is missing before recovery, or it is stale (older than one interval)
 C the renderer kill did not register as RenderProcessExited (run is INVALID, not PASS)
 D no fresh row after the reload, or the sample counter restarts or goes backwards
 E not exactly one [start] and one [stop] for the session, or the app exit code is not 0
 F a memory line contains anything except allowlisted keys with numeric/null/enum values
"""
import json, re, subprocess, sys, time
from pathlib import Path
import psutil

WT = Path(__file__).resolve().parents[2]
args = [a for a in sys.argv[1:] if not a.startswith('--harness-root=')]
override = [a.split('=', 1)[1] for a in sys.argv[1:] if a.startswith('--harness-root=')]
# The bench harness (experiments/memory-attribution) lives in the maintainer checkout; worktrees sit at <root>/.cache/<wt>.
ROOT = Path(override[0]) if override else next(
    (p for p in [WT, *WT.parents] if (p / 'experiments/memory-attribution/run.py').exists()), None)
if ROOT is None:
    sys.exit('experiments/memory-attribution/run.py not found; pass --harness-root=<maintainer checkout>')
label, exe = args[0], args[1]
out = WT / 'artifacts/memory-trail' / label
out.mkdir(parents=True, exist_ok=True)
started = time.time()
launcher = subprocess.Popen([sys.executable, str(ROOT / 'experiments/memory-attribution/run.py'), '--label', label,
                             '--exe', exe, '--signed-out', '--schedule=full@0;quit@75', '--max-seconds', '200',
                             '--env', 'NATIVUNE_BENCH_MEMORY_TRAIL_SECONDS=5', '--env', 'NATIVUNE_BENCH_STATS_SECONDS=0',
                             '--extra-args=--no-delay-for-dx12-vulkan-info-collection'], cwd=ROOT)
marks = {}
run = None
while launcher.poll() is None and time.time() - started < 120:
    runs = sorted(p for p in (ROOT / '.cache/memory-attribution/runs').glob(f'*-{label}') if p.stat().st_mtime >= started - 5)
    if runs and (runs[-1] / 'bench.jsonl').exists() and '"media-playing"' in (runs[-1] / 'bench.jsonl').read_text(encoding='utf-8', errors='replace'):
        run = runs[-1]
        break
    time.sleep(0.5)
if run:
    time.sleep(30)
    host = json.loads((run / 'app-process.json').read_text(encoding='utf-8-sig'))['pid']
    renderers = []
    for child in psutil.Process(host).children(recursive=True):
        try:
            cmd = ' '.join(child.cmdline())
        except psutil.Error:
            continue
        if '--type=renderer' in cmd and '--extension-process' not in cmd:
            renderers.append(child)
    marks['pageRenderers'] = [r.pid for r in renderers]
    if len(renderers) == 1:
        marks['killAt'] = time.time()
        renderers[0].kill()
launcher_rc = launcher.wait()
log = (run / 'data/nativune.log').read_text(encoding='utf-8', errors='replace') if run else ''
lines = log.splitlines()

def ts(line):
    m = re.match(r'^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+ [+-]\d\d:\d\d)', line)
    return time.mktime(time.strptime(m.group(1)[:19], '%Y-%m-%d %H:%M:%S')) if m else None

def fields(line):
    """Parse key=value tokens; None if any token is not key=value (counted as a violation, never raised)."""
    body = line.split('] ', 1)[1] if '] ' in line else ''
    tokens = body.split()
    if not tokens or any('=' not in t for t in tokens):
        return None
    return dict(t.split('=', 1) for t in tokens)

memory = [l for l in lines if '[memory-trail] ' in l]
before = [l for l in lines if '[memory-trail-before-failure] ' in l]
failed = [l for l in lines if '[process-failed] RenderProcessExited' in l]
stop = [l for l in lines if '[stop] ' in l]
allowed = {'sample', 'session_min', 'renderer_min', 'mode', 'js_used_mib', 'js_total_mib', 'js_limit_mib', 'documents', 'nodes',
           'listeners', 'renderer_private_mib', 'renderer_ws_mib', 'host_private_mib', 'host_ws_mib', 'tree_private_mib', 'commit_used_mib', 'commit_limit_mib',
           'phys_available_mib', 'collection_ms', 'status', 'age_min'}
value_ok = re.compile(r'^(null|-?\d+(\.\d+)?|full|compact|tray|ok|partial|timeout|failed)$')
privacy_bad = [l for l in memory + before if fields(l) is None
               or any(k not in allowed or not value_ok.match(v) for k, v in fields(l).items())]
memory = [l for l in memory if fields(l) is not None and 'sample' in fields(l)]
before = [l for l in before if fields(l) is not None]
kill_at = marks.get('killAt')
fail_idx = lines.index(failed[0]) if failed else None
pre = [l for i, l in enumerate(lines) if '[memory-trail] ' in l and fail_idx is not None and i < fail_idx]
post = [l for i, l in enumerate(lines) if '[memory-trail] ' in l and fail_idx is not None and i > fail_idx]
bf = [l for i, l in enumerate(lines) if '[memory-trail-before-failure] ' in l and fail_idx is not None and i > fail_idx]
pre = [l for l in pre if l in memory]
post = [l for l in post if l in memory]
bf = [l for l in bf if l in before]
limit_ok = bool(pre) and all(fields(l)['status'] == 'ok' and 500 <= float(fields(l)['js_limit_mib']) <= 530
                             and fields(l)['renderer_private_mib'] != 'null' and fields(l).get('host_private_mib', 'null') != 'null'
                             and float(fields(l)['tree_private_mib']) >= float(fields(l)['host_private_mib']) + float(fields(l)['renderer_private_mib'])
                             for l in pre)
checks = {
    'A_rowsBeforeKillOkWithLimit515': len(pre) >= 3 and limit_ok,
    'B_cachedRowBeforeRecoveryFresh': bool(bf) and fields(bf[0]).get('age_min') not in (None, 'null') and float(fields(bf[0])['age_min']) <= 0.2
                                      and fields(bf[0]).get('sample') == fields(pre[-1]).get('sample') if pre and bf else False,
    'C_rendererExitRegistered': bool(kill_at and failed),
    'D_freshRowAfterReload': bool(post) and bool(pre) and int(fields(post[0])['sample']) > int(fields(pre[-1])['sample'])
                             and fields(post[0])['status'] == 'ok' and float(fields(post[0])['renderer_min']) < 1.0,
    'E_stopLineAndCleanExit': len(stop) == 1 and sum('[start] ' in l for l in lines) == 1 and launcher_rc == 0,
    'F_numericOnly': bool(memory) and not privacy_bad,
}
status = 'INVALID' if not checks['C_rendererExitRegistered'] else 'PASS' if all(checks.values()) else 'FAIL'
report = {'label': label, 'exe': exe, 'status': status, 'checks': checks, 'marks': marks, 'launcherExit': launcher_rc,
          'run': str(run), 'counts': {'memory': len(memory), 'beforeFailure': len(before), 'stop': len(stop)},
          'firstRows': memory[:2], 'beforeFailureRows': before, 'postRows': post[:2], 'stopRows': stop,
          'privacyViolations': len(privacy_bad),
          'command': f'python experiments/memory-trail/trail_e2e.py {label} {exe}'}
(out / 'report.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
print(json.dumps({'label': label, 'status': status, 'checks': checks}))
sys.exit(0 if status == 'PASS' else 2 if status == 'INVALID' else 1)
