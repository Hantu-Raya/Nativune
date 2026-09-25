"""Account-free WinUI launcher checks; no build."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
temp = root / '.cache' / 'tmp'
temp.mkdir(parents=True, exist_ok=True)
env = dict(os.environ, TEMP=str(temp), TMP=str(temp))


def run(script, *args):
    return subprocess.run(
        ['pwsh', '-NoProfile', '-File', str(script), *args],
        cwd=root.parent, env=env, capture_output=True, text=True, timeout=30,
    )


launcher = root / 'scripts' / 'probe.ps1'
help_result = run(launcher)
assert help_result.returncode == 0, 'probe.ps1: default help failed'
assert 'native-fixture' in help_result.stdout, 'probe.ps1: WinUI application was not selected'
invalid = run(launcher, 'help', '--invalid-launcher-check')
assert invalid.returncode == 2, 'probe.ps1: application usage exit code was not propagated'
assert 'Unknown option' in invalid.stderr, 'probe.ps1: option did not reach application parser'
with tempfile.TemporaryDirectory(prefix='launcher check ', dir=temp) as directory:
    isolated = Path(directory)
    missing_root = isolated / 'missing root'
    override = run(launcher, 'self-check', '--root', str(missing_root))
    assert override.returncode == 2, 'probe.ps1: spaced root argument or root override was ignored'
    assert 'The specified project root does not exist.' in override.stderr, 'probe.ps1: the explicit root was not selected'
    scripts = isolated / 'scripts'
    scripts.mkdir()
    shutil.copyfile(launcher, scripts / 'probe.ps1')
    missing = run(scripts / 'probe.ps1')
    assert missing.returncode != 0, 'probe.ps1: missing output incorrectly succeeded'
    assert 'WinUI application not found' in missing.stderr, 'probe.ps1: missing-output diagnostic lost'
print('PASS: WinUI identity, help, parser exit 2, spaced root override, missing artifacts; external working directory')
