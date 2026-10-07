"""Blocked-navigation E2E: python experiments/full-idle-cap/blocked_nav_e2e.py <label> <exe>.
Rescore: python experiments/full-idle-cap/blocked_nav_e2e.py --rescore <label>.
A missing pre-cap or unproven blocked navigation is INVALID, not a passing run.
Uses disposable signed-out muted playback; no new app hooks or Python dependencies.
"""
from __future__ import annotations
import argparse, hashlib, json, math, os, pathlib, re, shutil, socket, subprocess, sys, threading, time
from datetime import datetime
import psutil
import run as h
from gpu_crash_tray_e2e import other_hosts, owned_tree

IDLE = 5
REAPPLY_WINDOW = IDLE + 30
SCHEDULE = 'full@0;quit@90'
# Bun's native WebSocket follows memory-dump/dump.ts; Python websocket packages are not installed.
CDP = r'''
const port = Number(process.env.BLOCKED_NAV_CDP_PORT);
const action = process.env.BLOCKED_NAV_CDP_ACTION;
const targets = await (await fetch(`http://127.0.0.1:${port}/json`)).json();
const pages = targets.filter(t => {
  if(t.type !== 'page') return false;
  const u = new URL(t.url);
  return u.origin === 'https://music.youtube.com' && u.pathname === '/watch' && u.searchParams.has('v');
});
if(pages.length !== 1) throw new Error(`Expected one Music /watch page, got ${pages.length}`);
const url = new URL(pages[0].webSocketDebuggerUrl);
if(url.protocol !== 'ws:' || !['127.0.0.1','localhost'].includes(url.hostname) || Number(url.port) !== port)
  throw new Error('Debugger WebSocket is not the selected loopback endpoint');
const ws = new WebSocket(url.href);
const opened = Promise.withResolvers();
ws.onopen = () => opened.resolve();
ws.onerror = () => opened.reject(new Error('Debugger socket error'));
let nextId = 1;
const pending = new Map();
ws.onmessage = m => {
  const reply = JSON.parse(String(m.data));
  if(pending.has(reply.id)) { pending.get(reply.id)(reply); pending.delete(reply.id); }
};
const send = (method, params) => {
  const reply = Promise.withResolvers();
  const id = nextId++;
  pending.set(id, reply.resolve);
  ws.send(JSON.stringify({id, method, params}));
  return reply.promise;
};
const bounded = p => Promise.race([p, Bun.sleep(7000).then(() => {throw new Error('CDP timeout')})]);
try {
  await bounded(opened.promise);
  const expression = action === 'trigger' ? "location.href='https://example.com/'" :
    "(()=>{const u=new URL(location.href),v=document.querySelector('video');return {origin:u.origin,path:u.pathname,v:u.searchParams.get('v'),paused:v?v.paused:null,ended:v?v.ended:null,currentTime:v&&Number.isFinite(v.currentTime)?v.currentTime:null}})()";
  const reply = await bounded(send('Runtime.evaluate', {expression, returnByValue:true}));
  if(reply.error || reply.result?.exceptionDetails) throw new Error('Runtime.evaluate failed');
  console.log(JSON.stringify(action === 'trigger' ? {navigationIssued:true} : reply.result.result.value));
} finally {ws.close();}
process.exit(0);
'''


def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


def cdp(bun, port, action, pid):
    browsers = {p['pid'] for p in owned_tree(pid) if p['type'] == 'browser'}
    listeners = [c for c in psutil.net_connections(kind='tcp')
                 if c.status == psutil.CONN_LISTEN and c.laddr and c.laddr.port == port]
    if len(listeners) != 1 or listeners[0].pid not in browsers or not listeners[0].laddr or listeners[0].laddr.ip not in ('127.0.0.1', '::1'):
        raise RuntimeError('Loopback debugger listener is not owned by this app browser')
    result = subprocess.run([bun, '-e', CDP], env=dict(os.environ, BLOCKED_NAV_CDP_PORT=str(port),
                            BLOCKED_NAV_CDP_ACTION=action), capture_output=True, text=True, timeout=12)
    if result.returncode:
        raise RuntimeError(f'CDP {action} failed: {result.stderr.strip()}')
    return json.loads(result.stdout)


def blocked_events(run):
    events = []
    for path in (run/'data/nativune.old.log', run/'data/nativune.log'):
        if not path.exists():
            continue
        for line in path.read_text(encoding='utf-8-sig').splitlines():
            match = re.match(r'^(.*?) \[status\] Navigation blocked to example\.com\. Only Music and Google account pages are allowed\.$', line)
            if match:
                stamp = datetime.strptime(match[1], '%Y-%m-%d %H:%M:%S.%f %z').timestamp()*1000
                events.append({'t': stamp, 'host': 'example.com', 'source': path.name})
    return events


def drive(label, bun, port, marks, errors, stop):
    try:
        started = time.time()
        run = None
        while not stop.is_set() and time.time()-started < 90:
            runs = sorted(r for r in (h.MAINTAINER/'.cache/memory-attribution/runs').glob('*-'+label)
                          if r.stat().st_mtime >= started-5)
            if runs and (runs[-1]/'app-process.json').exists():
                run = runs[-1]
                break
            stop.wait(.2)
        if run is None:
            raise RuntimeError('No app identity from solo launcher')
        marks['run'] = str(run)
        pid = json.loads((run/'app-process.json').read_text(encoding='utf-8-sig'))['pid']
        marks['hostPid'] = pid
        log = run/'bench.jsonl'

        def safe_wait():
            others = other_hosts(pid)
            if others:
                marks['otherHostPids'] = others
                raise RuntimeError('Another Nativune.exe appeared; aborting scenario')
            if stop.is_set() or not psutil.Process(pid).is_running():
                raise RuntimeError('App/launcher exited before evidence capture')
            stop.wait(.2)

        deadline = time.monotonic()+130
        pre = None
        while time.monotonic() < deadline:
            safe_wait()
            events = h.events(log)
            if any(e['event'] == 'media-timeout' for e in events):
                raise RuntimeError('Media did not start')
            playing = [e for e in events if e['event'] == 'media-playing']
            if playing:
                if time.time()*1000 > playing[0]['t']+35000:
                    raise RuntimeError('No idle cap within 35 seconds of media-playing')
                for event in events:
                    if event['event'] != 'fullidle-cap' or event['t'] < playing[0]['t']:
                        continue
                    if event.get('outcome') == 'applied':
                        pre = event
                    elif event.get('outcome', '').startswith('released'):
                        pre = None
                if pre:
                    break
        if pre is None:
            raise RuntimeError('Full-idle cap precondition missing')
        marks['preCap'] = pre
        marks['before'] = cdp(bun, port, 'snapshot', pid)
        before = marks['before']
        if before.get('path') != '/watch' or not before.get('v') or before.get('paused') is not False or before.get('ended') is not False:
            raise RuntimeError('Music /watch playback precondition missing')
        safe_wait()
        marks['triggerAt'] = time.time()*1000
        trigger_clock = time.monotonic()
        marks['triggerReply'] = cdp(bun, port, 'trigger', pid)
        # example.com is not in WebHostPolicy's exact HTTPS main-frame allowlist.
        deadline = trigger_clock+REAPPLY_WINDOW
        checked = False
        while time.monotonic() < deadline:
            safe_wait()
            blocked = [e for e in blocked_events(run) if e['t'] >= marks['triggerAt']]
            if blocked and not checked:
                marks['afterBlocked'] = cdp(bun, port, 'snapshot', pid)
                checked = True
        marks['checkedAt'] = time.time()*1000
        marks['elapsedSeconds'] = time.monotonic()-trigger_clock
        marks['after'] = cdp(bun, port, 'snapshot', pid)
        marks['snapshotAt'] = time.time()*1000
        if not checked:
            marks['afterBlocked'] = marks['after']
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
    trigger = marks.get('triggerAt', 0)
    end = marks.get('checkedAt', 0)
    pre = marks.get('preCap', {})
    before, blocked, after = (marks.get(key, {}) for key in ('before', 'afterBlocked', 'after'))
    blocked_log = [e for e in report.get('blockedEvents', []) if trigger <= e['t'] <= end]
    def same_playing(page):
        return bool(before.get('v') and page.get('origin') == 'https://music.youtube.com'
                    and page.get('path') == '/watch' and page.get('v') == before['v']
                    and page.get('paused') is False and page.get('ended') is False)
    deadline = trigger+(report['idleSeconds']+30)*1000
    reapplied = [e for e in report.get('capEvents', []) if trigger <= e['t'] <= deadline and e.get('outcome') == 'applied']
    active = None
    for event in report.get('capEvents', []):
        if trigger <= event['t'] <= end:
            if event.get('outcome') == 'applied':
                active = event
            elif event.get('outcome', '').startswith('released'):
                active = None
    progress = bool(isinstance(after.get('currentTime'), (int, float))
                    and isinstance(blocked.get('currentTime'), (int, float))
                    and after['currentTime'] > blocked['currentTime']+5)
    report['checks'] = {
        'A_fullIdleCapAppliedBeforeTrigger': bool(trigger and pre.get('outcome') == 'applied' and pre.get('t', math.inf) < trigger),
        'B_disallowedNavigationCancelledPageIntact': bool(trigger and marks.get('triggerReply', {}).get('navigationIssued')
            and blocked_log and same_playing(blocked)),
        'C_fullIdleCapReappliesWithinIdlePlus30Seconds': bool(trigger and reapplied and active
            and marks.get('elapsedSeconds', 0) >= report['idleSeconds']+30),
        'D_playbackContinuesCleanExitNoOtherHosts': bool(same_playing(after) and progress and report.get('appExit') == 0
            and report.get('launcherExit') == 0 and report.get('initialSolo') and not marks.get('otherHostPids')),
    }
    report['reappliedAt'] = reapplied[0]['t'] if reapplied else None
    report['passed'] = all(report['checks'].values()) and not report['errors']
    valid = report['checks']['A_fullIdleCapAppliedBeforeTrigger'] and report['checks']['B_disallowedNavigationCancelledPageIntact'] and not report['errors']
    report['status'] = 'PASS' if report['passed'] else 'FAIL' if valid else 'INVALID'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rescore', action='store_true')
    parser.add_argument('label')
    parser.add_argument('exe', nargs='?')
    args = parser.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9_-]+', args.label):
        parser.error('label must contain only letters, digits, underscores or hyphens')
    out = h.OUT/('blocked-nav-'+args.label)
    path = out/'report.json'
    if args.rescore:
        report = json.loads(path.read_text(encoding='utf-8'))
    else:
        if not args.exe:
            parser.error('exe is required unless --rescore is used')
        exe = pathlib.Path(args.exe).resolve()
        bun = shutil.which('bun')
        if not exe.is_file() or not bun:
            parser.error('Executable must exist and the already-installed Bun must be on PATH')
        out.mkdir(parents=True, exist_ok=True)
        marks, errors, stop = {}, [], threading.Event()
        report = {'label': args.label, 'exe': str(exe), 'errors': errors, 'marks': marks, 'idleSeconds': IDLE,
                  'schedule': SCHEDULE, 'initialSolo': not other_hosts(), 'binarySha256': hashlib.sha256(exe.read_bytes()).hexdigest()}
        if exe.with_suffix('.dll').exists():
            report['dllSha256'] = hashlib.sha256(exe.with_suffix('.dll').read_bytes()).hexdigest()
        if not report['initialSolo']:
            errors.append('Another Nativune.exe is present; launch aborted')
        else:
            port = free_port()
            report['debugPort'] = port
            label = 'blocked-nav-'+args.label
            command = [sys.executable, str(h.SOLO), label, str(exe), '--schedule', SCHEDULE, '--signed-out',
                       f'--extra-args=--no-delay-for-dx12-vulkan-info-collection --remote-debugging-port={port}',
                       '--env', f'NATIVUNE_BENCH_FULLIDLE_SECONDS={IDLE}', '--env', f'NATIVUNE_BENCH_FULLIDLE_REARM_SECONDS={IDLE}',
                       '--env', 'NATIVUNE_BENCH_FULLIDLE_CAP_MIB=60', '--env', 'NATIVUNE_BENCH_STATS_SECONDS=1']
            (out/'command.txt').write_text(subprocess.list2cmdline(command)+'\n', encoding='utf-8')
            monitor = threading.Thread(target=drive, args=(label, bun, port, marks, errors, stop))
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
                report['capEvents'] = [e for e in h.events(run/'bench.jsonl') if e['event'] == 'fullidle-cap']
                report['blockedEvents'] = blocked_events(run)
                exit_path = run/'app-exit.json'
                if exit_path.exists():
                    report['appExit'] = json.loads(exit_path.read_text(encoding='utf-8-sig')).get('exitCode')
    score(report)
    path.write_text(json.dumps(report, indent=2)+'\n', encoding='utf-8')
    print(json.dumps({key: report[key] for key in ('label', 'status', 'passed', 'checks', 'errors')}))
    return 0 if report['passed'] else 2 if report['status'] == 'INVALID' else 1


if __name__ == '__main__':
    sys.exit(main())
