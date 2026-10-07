"""Sequential FullIdle screening and fixture SendInput latency (no credentials or page text).

python experiments/full-idle-cap/run.py --screens
python experiments/full-idle-cap/run.py --latency
Uses the maintainer's shared solo.py lock. Outputs are retained under artifacts/full-idle-cap.
"""
from __future__ import annotations
import argparse, ctypes, hashlib, json, os, pathlib, struct, subprocess, sys, threading, time
from ctypes import wintypes as W

ROOT = pathlib.Path(__file__).resolve().parents[2]
MAINTAINER = ROOT.parents[1]
OUT = ROOT / 'artifacts/full-idle-cap'
EXE = ROOT / 'artifacts/perf-bench/publish/Nativune.exe'
SOLO = MAINTAINER / 'experiments/memory-attribution/solo.py'
SCHEDULE = 'full@0;compact@245;full@365;hide@545;show@665;quit@725'
u = ctypes.WinDLL('user32', use_last_error=True)
g = ctypes.WinDLL('gdi32', use_last_error=True)
k = ctypes.WinDLL('kernel32', use_last_error=True)
PTR = ctypes.c_size_t
class RECT(ctypes.Structure):
    _fields_ = [('left', W.LONG), ('top', W.LONG), ('right', W.LONG), ('bottom', W.LONG)]
class MOUSE(ctypes.Structure):
    _fields_ = [('dx', W.LONG), ('dy', W.LONG), ('data', W.DWORD), ('flags', W.DWORD), ('time', W.DWORD), ('extra', PTR)]
class KEY(ctypes.Structure):
    _fields_ = [('key', W.WORD), ('scan', W.WORD), ('flags', W.DWORD), ('time', W.DWORD), ('extra', PTR)]
class UNION(ctypes.Union):
    _fields_ = [('mouse', MOUSE), ('key', KEY)]
class INPUT(ctypes.Structure):
    _fields_ = [('type', W.DWORD), ('payload', UNION)]
class BMI(ctypes.Structure):
    _fields_ = [('size', W.DWORD), ('width', W.LONG), ('height', W.LONG), ('planes', W.WORD), ('bits', W.WORD),
                ('compression', W.DWORD), ('imageSize', W.DWORD), ('xp', W.LONG), ('yp', W.LONG), ('colors', W.DWORD), ('important', W.DWORD)]
CALLBACK = ctypes.WINFUNCTYPE(W.BOOL, W.HWND, W.LPARAM)
u.EnumWindows.argtypes = [CALLBACK, W.LPARAM]
u.EnumChildWindows.argtypes = [W.HWND, CALLBACK, W.LPARAM]
u.GetWindowThreadProcessId.argtypes = [W.HWND, ctypes.POINTER(W.DWORD)]
u.GetWindowRect.argtypes = [W.HWND, ctypes.POINTER(RECT)]
u.IsWindowVisible.argtypes = [W.HWND]
u.GetClassNameW.argtypes = [W.HWND, W.LPWSTR, ctypes.c_int]
u.GetDC.restype = W.HDC
u.GetDC.argtypes = [W.HWND]
u.ReleaseDC.argtypes = [W.HWND, W.HDC]
u.SendInput.argtypes = [W.UINT, ctypes.POINTER(INPUT), ctypes.c_int]
u.SetForegroundWindow.argtypes = [W.HWND]
u.GetCursorPos.argtypes = [ctypes.POINTER(W.POINT)]
u.WindowFromPoint.argtypes = [W.POINT]; u.WindowFromPoint.restype = W.HWND
u.GetAncestor.argtypes = [W.HWND, W.UINT]; u.GetAncestor.restype = W.HWND
u.GetForegroundWindow.restype = W.HWND
u.SetCursorPos.argtypes = [ctypes.c_int, ctypes.c_int]
u.SetWindowPos.argtypes = [W.HWND,W.HWND,ctypes.c_int,ctypes.c_int,ctypes.c_int,ctypes.c_int,W.UINT]
g.CreateCompatibleDC.argtypes = [W.HDC]; g.CreateCompatibleDC.restype = W.HDC
g.CreateCompatibleBitmap.argtypes = [W.HDC, ctypes.c_int, ctypes.c_int]; g.CreateCompatibleBitmap.restype = W.HBITMAP
g.SelectObject.argtypes = [W.HDC, W.HGDIOBJ]; g.SelectObject.restype = W.HGDIOBJ
g.BitBlt.argtypes = [W.HDC, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int, W.HDC, ctypes.c_int, ctypes.c_int, W.DWORD]
g.GetDIBits.argtypes = [W.HDC, W.HBITMAP, W.UINT, W.UINT, ctypes.c_void_p, ctypes.POINTER(BMI), W.UINT]
g.DeleteObject.argtypes = [W.HGDIOBJ]; g.DeleteDC.argtypes = [W.HDC]
k.QueryPerformanceCounter.argtypes = [ctypes.POINTER(ctypes.c_longlong)]
k.QueryPerformanceFrequency.argtypes = [ctypes.POINTER(ctypes.c_longlong)]
f = ctypes.c_longlong(); k.QueryPerformanceFrequency(ctypes.byref(f)); FREQUENCY = f.value

def qpc():
    q = ctypes.c_longlong(); k.QueryPerformanceCounter(ctypes.byref(q)); return q.value

def events(path):
    result = []
    if path.exists():
        for line in path.read_text(encoding='utf-8').splitlines():
            try: result.append(json.loads(line))
            except json.JSONDecodeError: pass  # a writer may be appending the last line
    return result

def window_for(pid):
    found = []
    @CALLBACK
    def top(h, _):
        p = W.DWORD(); u.GetWindowThreadProcessId(h, ctypes.byref(p))
        if p.value == pid and u.IsWindowVisible(h): found.append(h)
        return True
    u.EnumWindows(top, 0)
    if len(found) != 1: raise RuntimeError(f'Expected one visible host window, got {len(found)}')
    children = []
    @CALLBACK
    def child(h, _):
        name = ctypes.create_unicode_buffer(128); u.GetClassNameW(h, name, len(name))
        if name.value in ('Chrome_RenderWidgetHostHWND', 'Intermediate D3D Window') and u.IsWindowVisible(h):
            r = RECT(); u.GetWindowRect(h, ctypes.byref(r))
            if r.right-r.left > 200 and r.bottom-r.top > 200: children.append((h, r))
        return True
    u.EnumChildWindows(found[0], child, 0)
    if not children: raise RuntimeError('No visible WebView input surface')
    h, rect = max(children, key=lambda x: (x[1].right-x[1].left)*(x[1].bottom-x[1].top))
    return found[0], h, rect

def target_snapshot(top,rect):
    point=W.POINT()
    if not u.GetCursorPos(ctypes.byref(point)):raise ctypes.WinError()
    under=u.WindowFromPoint(point); root=u.GetAncestor(under,2)
    def info(h):
        p=W.DWORD();u.GetWindowThreadProcessId(h,ctypes.byref(p))
        name=ctypes.create_unicode_buffer(128);u.GetClassNameW(h,name,len(name))
        return {'hwnd':int(h or 0),'pid':p.value,'class':name.value}
    return {'host':info(top),'underCursor':info(under),'cursorRoot':info(root),
            'foreground':info(u.GetForegroundWindow()),'cursor':[point.x,point.y],
            'rect':[rect.left,rect.top,rect.right,rect.bottom],
            'inside':rect.left<=point.x<rect.right and rect.top<=point.y<rect.bottom,
            'rootMatches':root==top}

class Capture:
    def __init__(self, x, y, width=128, height=64):
        self.x,self.y,self.width,self.height=x,y,width,height
        self.screen=u.GetDC(None); self.dc=g.CreateCompatibleDC(self.screen)
        self.bitmap=g.CreateCompatibleBitmap(self.screen,width,height)
        self.old=g.SelectObject(self.dc,self.bitmap)
        self.info=BMI(40,width,-height,1,32,0,width*height*4,0,0,0,0)
        self.data=ctypes.create_string_buffer(width*height*4)
    def frame(self):
        started=qpc()
        if not g.BitBlt(self.dc,0,0,self.width,self.height,self.screen,self.x,self.y,0x00CC0020): raise ctypes.WinError()
        complete=qpc()
        g.SelectObject(self.dc,self.old)
        try:
            if not g.GetDIBits(self.dc,self.bitmap,0,self.height,self.data,ctypes.byref(self.info),0): raise ctypes.WinError()
        finally:g.SelectObject(self.dc,self.bitmap)
        return started,complete,self.data.raw
    def save(self, path, data):
        path.write_bytes(struct.pack('<2sIHHI',b'BM',54+len(data),0,0,54)+bytes(self.info)+data)
    def close(self):
        g.SelectObject(self.dc,self.old); g.DeleteObject(self.bitmap); g.DeleteDC(self.dc); u.ReleaseDC(None,self.screen)

def fixture_pixels(pixels):
    color=pixels[:3]
    return color in (b'\x6e\x50\x24',b'\x40\x40\x82') and all(pixels[i:i+3]==color for i in range(0,len(pixels),4))

def inject(kind):
    items=(INPUT*2)()
    if kind=='wheel':
        items[0].payload.mouse=MOUSE(0,0,120,0x0800,0,0); count=1
    else:
        items[0].payload.mouse=MOUSE(0,0,0,0x0002,0,0)
        items[1].payload.mouse=MOUSE(0,0,0,0x0004,0,0); count=2
    stamp=qpc()
    if u.SendInput(count,items,ctypes.sizeof(INPUT)) != count: raise ctypes.WinError()
    return stamp

def latency_watch(label, cap, result, errors, stop, probe=False, position=None):
    try:
        started=time.time(); run=None
        while not stop.is_set() and run is None:
            runs=sorted(r for r in (MAINTAINER/'.cache/memory-attribution/runs').glob('*-'+label) if r.stat().st_mtime>=started-5)
            if runs and (runs[-1]/'app-process.json').exists(): run=runs[-1]
            else: time.sleep(.2)
        if run is None: return
        pid=json.loads((run/'app-process.json').read_text(encoding='utf-8-sig'))['pid']; log=run/'bench.jsonl'
        ready=time.time()
        while not any(e['event']=='webview-input-windows' for e in events(log)):
            if stop.is_set() or time.time()-ready > 60: raise RuntimeError('Fixture did not become ready')
            time.sleep(.1)
        top,_,rect=window_for(pid)
        arm=OUT/label; arm.mkdir(parents=True,exist_ok=True)
        if position is not None:
            if not u.SetWindowPos(top,None,*position,0,0,0x0015):raise ctypes.WinError()
            time.sleep(.25)
            top,_,rect=window_for(pid)
        ready=time.time()
        while not any(e['event']=='show-requested' for e in events(log)):
            if stop.is_set() or time.time()-ready>15:raise RuntimeError('Owned activation path did not run')
            time.sleep(.025)
        time.sleep(.25)
        u.SetForegroundWindow(top)
        placed=bool(u.SetCursorPos((rect.left+rect.right)//2, rect.top+300))
        initial=target_snapshot(top,rect);initial['setCursorSucceeded']=placed
        (arm/'initial-target.json').write_text(json.dumps(initial,indent=2))
        if probe:return
        if not placed or not initial['inside'] or not initial['rootMatches']:
            raise RuntimeError('Initial cursor placement does not target the owned WebView; refusing input')
        capture=Capture(rect.left+20,rect.top+20)
        previous=0
        try:
            for trial in range(10):
                deadline=time.time()+100
                parked=False
                while True:
                    log_events=events(log)
                    shown=[e for e in log_events if e['event']=='show-requested']
                    activation=shown[trial]['t'] if len(shown)>trial else None
                    if activation is not None and not parked:
                        if not u.SetCursorPos((rect.left+rect.right)//2,rect.top+300):raise ctypes.WinError()
                        parked=True
                    applied=[e for e in log_events if e['event']=='fullidle-cap' and e.get('outcome')=='applied'
                             and activation is not None and e['t']>max(previous,activation)]
                    if cap and applied:previous=applied[-1]['t'];break
                    if not cap and activation is not None and time.time()*1000-activation>=62000:break
                    if stop.is_set() or time.time()>deadline: raise RuntimeError(f'No idle cap before trial {trial}')
                    time.sleep(.025)
                kind='wheel' if trial%2==0 else 'click'
                frames=arm/f'trial-{trial:02}-{kind}';frames.mkdir(exist_ok=True)
                live_top,_,live_rect=window_for(pid)
                target=target_snapshot(top,rect)
                (frames/'input-target.json').write_text(json.dumps(target,indent=2))
                if bytes(live_rect)!=bytes(rect) or live_top!=top:
                    raise RuntimeError('Owned fixture geometry changed; refusing input')
                if not target['inside'] or not target['rootMatches']:
                    raise RuntimeError('Cursor is no longer over the owned WebView; refusing input')
                _,_,baseline=capture.frame()
                if not fixture_pixels(baseline):
                    raise RuntimeError('Fixture response band is not visible and unobscured; refusing input')
                capture.save(frames/'baseline.bmp',baseline)
                stamp=inject(kind); first=None; frame_records=[]; target=time.perf_counter()
                for number in range(32):
                    a,b,pixels=capture.frame()
                    if not fixture_pixels(pixels):
                        raise RuntimeError('Response band obscured; refusing to retain non-fixture pixels')
                    capture.save(frames/f'{number:02}.bmp',pixels)
                    changed=pixels!=baseline
                    frame_records.append({'startQpc':a,'endQpc':b,'changed':changed})
                    if changed and first is None: first=(a,b)
                    target+=.016;time.sleep(max(0,target-time.perf_counter()))
                release_deadline=time.time()+2
                released=[]
                while time.time()<release_deadline:
                    released=[e for e in events(log) if e['event']=='fullidle-cap' and e.get('outcome')=='released'
                              and e.get('completedQpc',0)>=stamp]
                    if released or not cap: break
                    time.sleep(.01)
                release=released[0] if released else None
                row={'trial':trial,'kind':kind,'injectionQpc':stamp,'frequency':FREQUENCY,
                     'applied':applied[-1] if cap else None,'release':release,'frames':frame_records,
                     'injectionToReleaseMs':1000*(release['completedQpc']-stamp)/FREQUENCY if release else None,
                     'injectionToFirstChangedFrameMs':1000*(first[1]-stamp)/FREQUENCY if first else None,
                     'frameStartMs':1000*(first[0]-stamp)/FREQUENCY if first else None}
                result.append(row);(arm/'trials.json').write_text(json.dumps(result,indent=2))
                if cap and release is None: raise RuntimeError('No FullIdle release after real input')
                if first is None: raise RuntimeError('No changed fixture frame after real input')
        finally: capture.close()
    except Exception as e: errors.append(str(e))

def launch(label, cap, latency=False, schedule=None, probe=False, position=None):
    input_schedule=';'.join(f'show@{70*i}' for i in range(10))+';compact@720;quit@725'
    selected_schedule=schedule or ('show@0;quit@12' if probe else input_schedule if latency else SCHEDULE)
    args=[sys.executable,str(SOLO),label,str(EXE),'--schedule',selected_schedule,
          '--extra-args=--no-delay-for-dx12-vulkan-info-collection','--env',f'NATIVUNE_BENCH_FULLIDLE_CAP_MIB={cap}']
    if latency:
        args+=['--signed-out','--start-uri','https://music.youtube.com/fullidle-fixture','--env','NATIVUNE_BENCH_FULLIDLE_FIXTURE=1']
    command=subprocess.list2cmdline(args)
    (OUT/(label+'-command.txt')).write_text(command+'\n')
    (OUT/(label+'-binary.json')).write_text(json.dumps({'sha256':hashlib.sha256((EXE.parent/'Nativune.dll').read_bytes()).hexdigest()}))
    rows,errors,stop=[],[],threading.Event()
    monitor=None
    if latency:
        monitor=threading.Thread(target=latency_watch,args=(label,cap,rows,errors,stop,probe,position));monitor.start()
    env=dict(os.environ,SOLO_ATTEMPTS='1',SOLO_QUIET_SECONDS='60')
    p=subprocess.run(args,cwd=ROOT,env=env,capture_output=True,text=True)
    stop.set()
    if monitor: monitor.join()
    (OUT/(label+'-launcher.log')).write_text(p.stdout+p.stderr)
    dirs=sorted((MAINTAINER/'artifacts/memory-attribution').glob('*-'+label))
    if not dirs: raise RuntimeError(f'{label}: runner failed without artifacts, exit {p.returncode}')
    out=dirs[-1]; dst=OUT/label;dst.mkdir(exist_ok=True)
    for name in ('samples.jsonl','summary.json','score.json','command.txt'):
        if (out/name).exists(): (dst/name).write_bytes((out/name).read_bytes())
    run=sorted((MAINTAINER/'.cache/memory-attribution/runs').glob('*-'+label))[-1]
    safe={'fullidle-cap','tray-cap','renderer-cap-restored','webview-input-windows','anchor','media-playing','media-timeout','media-sample',
          'compact-requested','compact-shown','full-requested','full-shown','hide-requested','hide-done',
          'show-requested','show-done','quit-requested','process-infos','presentation-state'}
    retained=[e for e in events(run/'bench.jsonl') if e['event'] in safe]
    (dst/'events.json').write_text(json.dumps(retained,indent=2))
    if errors: (dst/'latency-errors.json').write_text(json.dumps(errors))
    print(json.dumps({'label':label,'exit':p.returncode,'latencyTrials':len(rows),'errors':errors}),flush=True)
    if errors or p.returncode: raise RuntimeError(f'{label}: incomplete evidence')
    if label.startswith('fullidle-lifecycle-'):
        release=[e for e in retained if e['event']=='tray-cap' and e.get('outcome')=='released'
                 and e.get('reason')=='compact-entry']
        if not release:raise RuntimeError('Hidden Tray -> Compact did not synchronously release its cap')
        full_entry=next(e['t'] for e in retained if e['event']=='full-requested' and e['t']>release[0]['t'])
        sticky=[e for e in retained if e['event'] in ('tray-cap','fullidle-cap') and e.get('outcome')=='applied'
                and release[0]['t']<e['t']<full_entry]
        exact=[e for e in retained if e['event']=='renderer-cap-restored' and e.get('exact')]
        tray_applied=[e for e in retained if e['event']=='tray-cap' and e.get('outcome')=='applied']
        if not tray_applied:raise RuntimeError('Minimize -> hide did not apply the shared Tray cap')
        full_state=next(e for e in retained if e['event']=='presentation-state' and not e['compact'] and e['t']>full_entry)
        if full_state['inTray'] and not any(e['t']>full_entry for e in tray_applied):
            raise RuntimeError('Hidden Compact -> Full did not re-arm the shared Tray cap')
        if sticky or not exact:raise RuntimeError('A cap survived Compact or original limits were not restored')
        (dst/'lifecycle-check.json').write_text(json.dumps({'passed':True,'compactRelease':release[0],
            'exactRestoreChecks':len(exact),'trayApplied':tray_applied,'fullState':full_state},indent=2))
    return dst

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--screens',action='store_true');ap.add_argument('--latency',action='store_true')
    ap.add_argument('--lifecycle',action='store_true')
    ap.add_argument('--target-probe',action='store_true')
    ap.add_argument('--screen-caps',default='0,60,80,100')
    ap.add_argument('--screen-suffix',default='a')
    ap.add_argument('--input-suffix',default='a')
    ap.add_argument('--fixture-x',type=int);ap.add_argument('--fixture-y',type=int)
    a=ap.parse_args();OUT.mkdir(parents=True,exist_ok=True)
    position=(a.fixture_x,a.fixture_y) if a.fixture_x is not None and a.fixture_y is not None else None
    if a.screens:
        for cap in map(int,a.screen_caps.split(',')): launch(f'fullidle-{cap}-{a.screen_suffix}',cap)
    if a.latency:
        failures=[]
        for cap in (0,60):
            try:launch(f'fullidle-input-{cap}-{a.input_suffix}',cap,True,position=position)
            except RuntimeError as e:failures.append(str(e))
        if failures:raise RuntimeError('; '.join(failures))
    if a.target_probe:launch(f'fullidle-target-probe-{a.input_suffix}',0,True,probe=True,position=position)
    if a.lifecycle:
        launch('fullidle-lifecycle-60-c',60,schedule='full@0;minimize@100;hide@105;compact@135;full@165;show@195;quit@205')
    return 0
if __name__=='__main__': sys.exit(main())
