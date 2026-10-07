"""Build both flavors without racing loaded binaries or another memory bench, then run the release probe."""
import hashlib, json, pathlib, subprocess, sys

ROOT=pathlib.Path(__file__).resolve().parents[2]
OUT=ROOT/'artifacts/full-idle-cap';OUT.mkdir(parents=True,exist_ok=True)
if '--locked' not in sys.argv:
    wrapper=ROOT.parents[1]/'experiments/memory-attribution/withlock.py'
    sys.exit(subprocess.run([sys.executable,str(wrapper),sys.executable,__file__,'--locked'],cwd=ROOT).returncode)
commands=[]
for flavor,publish in (('true','artifacts/perf-bench/publish'),('false','artifacts/winui3/publish')):
    args=['pwsh','-NoProfile','-File','scripts/dotnet.ps1','publish','src/Nativune/Nativune.csproj',
          '--runtime','win-x64','--self-contained','false','-o',publish,f'-p:PerfBenchHooks={flavor}']
    commands.append(subprocess.list2cmdline(args));p=subprocess.run(args,cwd=ROOT,capture_output=True,text=True)
    (OUT/('build-bench.log' if flavor=='true' else 'build-release.log')).write_text(p.stdout+p.stderr)
    print('bench' if flavor=='true' else 'release','exit',p.returncode,flush=True)
    if p.returncode:sys.exit(p.returncode)
(OUT/'build-commands.txt').write_text('\n'.join(commands)+'\n')
(OUT/'build-hashes.json').write_text(json.dumps({str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()
    for folder in ('artifacts/perf-bench/publish','artifacts/winui3/publish') for p in (ROOT/folder).glob('Nativune.*') if p.is_file()},indent=2))
sys.exit(subprocess.run([sys.executable,str(ROOT/'experiments/full-idle-cap/verify.py'),'--locked'],cwd=ROOT).returncode)
