"""E2E: a pointer resting on the unfocused Full window must not block the idle cap.

python experiments/full-idle-cap/pointer_e2e.py <label> [exe]

Launches the bench fixture (signed out, local fixture page) with a 15 s idle wait, puts a small
helper window in front, parks the real pointer over Nativune and then:
  A  taps Shift into the helper every 2 s for 40 s     -> expect the cap to apply (idle)
  B  moves the pointer 15 px over Nativune               -> expect release (app-input)
  C  taps Shift into the helper again for 30 s           -> expect the cap to apply again
Writes artifacts/full-idle-cap/<label>/pointer-report.json (pass/fail plus cap events, no page data).
"""
from __future__ import annotations
import json, os, subprocess, sys, threading, time
import ctypes
from ctypes import wintypes as W
sys.path.insert(0, os.path.dirname(__file__))
import run as h

IDLE = 15
HELPER = r'''
import tkinter as tk, ctypes
r = tk.Tk(); r.title("pointer-e2e-helper"); r.geometry("320x160+1450+200"); r.attributes("-topmost", True)
tk.Label(r, text="Nativune pointer E2E helper").pack(expand=True)
def front():
    r.lift(); r.focus_force()
    ctypes.windll.user32.SetForegroundWindow(ctypes.windll.user32.GetParent(r.winfo_id()))
r.after(300, front); r.after(1500, front)
r.mainloop()
'''

def key_tap():
    items = (h.INPUT * 2)()
    for i, flags in enumerate((0, 2)):
        items[i].type = 1
        items[i].payload.key = h.KEY(0x10, 0, flags, 0, 0)
    if h.u.SendInput(2, items, ctypes.sizeof(h.INPUT)) != 2: raise ctypes.WinError()

def mouse_nudge(dx):
    item = (h.INPUT * 1)()
    item[0].type = 0
    item[0].payload.mouse = h.MOUSE(dx, 0, 0, 0x0001, 0, 0)
    if h.u.SendInput(1, item, ctypes.sizeof(h.INPUT)) != 1: raise ctypes.WinError()

def cap_events(log, since):
    return [e for e in h.events(log) if e['event'] == 'fullidle-cap' and e['t'] >= since]

def drive(label, marks, errors, stop):
    helper = None
    try:
        started = time.time(); run = None
        while not stop.is_set() and run is None:
            runs = sorted(r for r in (h.MAINTAINER/'.cache/memory-attribution/runs').glob('*-'+label) if r.stat().st_mtime >= started-5)
            if runs and (runs[-1]/'app-process.json').exists(): run = runs[-1]
            else: time.sleep(.2)
        if run is None: return
        pid = json.loads((run/'app-process.json').read_text(encoding='utf-8-sig'))['pid']; log = run/'bench.jsonl'
        ready = time.time()
        while not any(e['event'] == 'webview-input-windows' for e in h.events(log)):
            if stop.is_set() or time.time()-ready > 60: raise RuntimeError('Fixture did not become ready')
            time.sleep(.1)
        top, _, rect = h.window_for(pid)
        if not h.u.SetWindowPos(top, None, 100, 100, 0, 0, 0x0015): raise ctypes.WinError()
        time.sleep(.5); top, _, rect = h.window_for(pid)
        helper = subprocess.Popen([sys.executable, '-c', HELPER])
        time.sleep(2.5)
        if not h.u.SetCursorPos((rect.left+rect.right)//2, (rect.top+rect.bottom)//2): raise ctypes.WinError()
        time.sleep(.3)
        snap = h.target_snapshot(top, rect); marks['parked'] = snap
        if not snap['inside'] or not snap['rootMatches']: raise RuntimeError('Pointer is not over Nativune')
        if snap['foreground']['pid'] in (pid, 0): raise RuntimeError('Helper did not take the foreground')
        def now(): return int(time.time()*1000)
        marks['phaseA'] = now()
        for _ in range(20):
            key_tap(); time.sleep(2)
            if stop.is_set(): return
        marks['phaseB'] = now()
        mouse_nudge(15); time.sleep(1.5)
        marks['afterNudge'] = h.target_snapshot(top, rect)
        marks['phaseC'] = now()
        for _ in range(15):
            key_tap(); time.sleep(2)
            if stop.is_set(): return
        marks['end'] = now()
        marks['log'] = str(log)
    except Exception as e:
        errors.append(str(e))
    finally:
        if helper: helper.kill()

def main():
    label = sys.argv[1]
    exe = sys.argv[2] if len(sys.argv) > 2 else str(h.EXE)
    out = h.OUT/label; out.mkdir(parents=True, exist_ok=True)
    args = [sys.executable, str(h.SOLO), label, exe, '--schedule', 'show@0;quit@110',
            '--signed-out', '--start-uri', 'https://music.youtube.com/fullidle-fixture',
            '--env', 'NATIVUNE_BENCH_FULLIDLE_FIXTURE=1', '--env', 'NATIVUNE_BENCH_FULLIDLE_CAP_MIB=60',
            '--env', f'NATIVUNE_BENCH_FULLIDLE_SECONDS={IDLE}']
    (out/'command.txt').write_text(subprocess.list2cmdline(args)+'\n')
    marks, errors, stop = {}, [], threading.Event()
    t = threading.Thread(target=drive, args=(label, marks, errors, stop)); t.start()
    p = subprocess.run(args, cwd=h.ROOT, env=dict(os.environ, SOLO_ATTEMPTS='1', SOLO_QUIET_SECONDS='10'),
                       capture_output=True, text=True)
    stop.set(); t.join()
    report = {'label': label, 'exe': exe, 'idleSeconds': IDLE, 'exit': p.returncode, 'errors': errors, 'marks': {}}
    if 'log' in marks:
        from pathlib import Path
        ev = cap_events(Path(marks['log']), marks['phaseA'] - 30000)
        report['capEvents'] = [{k: e.get(k) for k in ('t', 'outcome', 'reason')} for e in ev]
        A = [e for e in ev if marks['phaseA'] <= e['t'] < marks['phaseB'] and e.get('outcome') == 'applied']
        B = [e for e in ev if marks['phaseB'] <= e['t'] < marks['phaseB']+1500 and e.get('outcome') == 'released' and e.get('reason') == 'app-input']
        C = [e for e in ev if marks['phaseC'] <= e['t'] <= marks['end'] and e.get('outcome') == 'applied']
        report['checks'] = {'A_capWhileTypingElsewhere': bool(A), 'B_releaseOnPointerMove': bool(B), 'C_capAgain': bool(C)}
        report['passed'] = all(report['checks'].values()) and not errors
        report['marks'] = {k: v for k, v in marks.items() if k != 'log'}
    else:
        report['passed'] = False
    (out/'pointer-report.json').write_text(json.dumps(report, indent=2))
    print(json.dumps({k: report.get(k) for k in ('label', 'passed', 'checks', 'errors')}))
    return 0 if report['passed'] else 1

if __name__ == '__main__': sys.exit(main())
