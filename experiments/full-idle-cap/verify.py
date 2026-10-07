"""Run the release native-fixture de-elevated and alone, using the shared benchmark lock."""
import json, os, pathlib, shutil, subprocess, sys, time
from datetime import datetime, timezone
import psutil

ROOT=pathlib.Path(__file__).resolve().parents[2]
MAINTAINER=ROOT.parents[1]
OUT=ROOT/'artifacts/full-idle-cap/native-fixture'/datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')
OUT.mkdir(parents=True,exist_ok=True)
if '--locked' not in sys.argv:
    wrapper=MAINTAINER/'experiments/memory-attribution/withlock.py'
    sys.exit(subprocess.run([sys.executable,str(wrapper),sys.executable,__file__,'--locked'],cwd=ROOT).returncode)
if any((p.info['name'] or '').lower()=='nativune.exe' for p in psutil.process_iter(['name'])):
    raise RuntimeError('Refusing: another Nativune.exe is running')
q=lambda s: "'"+str(s).replace("'","''")+"'"
launcher=OUT/'native-fixture.ps1'
exitp=OUT/'native-fixture-exit.json'
launcher.write_text("$ErrorActionPreference = 'Stop'\n"
    +f"Set-Location {q(ROOT)}\n"
    +"if (Get-Process Nativune -ErrorAction SilentlyContinue) { throw 'Refusing: another Nativune.exe is running' }\n"
    +f"& {q(ROOT/'scripts/probe.ps1')} native-fixture *> {q(OUT/'native-fixture.log')}\n"
    +f"[IO.File]::WriteAllText({q(exitp)}, (ConvertTo-Json -Compress @{{exitCode=$LASTEXITCODE}}))\n")
if exitp.exists():raise RuntimeError('Existing result: choose a fresh evidence directory before rerunning')
command=[os.path.join(os.environ['SystemRoot'],'System32/runas.exe'),'/trustlevel:0x20000',
    f'"{shutil.which("pwsh")}" -NoProfile -File "{launcher}"']
(OUT/'native-fixture-command.txt').write_text('python experiments/full-idle-cap/verify.py\n'
    +'Direct probe: pwsh -NoProfile -File scripts/probe.ps1 native-fixture\n')
subprocess.run(command,cwd=ROOT,check=True,capture_output=True)
deadline=time.time()+120
while not exitp.exists() and time.time()<deadline:time.sleep(.2)
if not exitp.exists():raise RuntimeError('Native-fixture did not write its exit report within 120 s')
result=json.loads(exitp.read_text(encoding='utf-8-sig'));print(result)
if result['exitCode']!=0:raise RuntimeError('Release native-fixture failed')
