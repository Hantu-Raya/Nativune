"""Account-free launcher checks against the existing Release output; no build."""
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
assert run(launcher).returncode == 0, 'Default help failed'
invalid = run(launcher, 'help', '--invalid-launcher-check')
assert invalid.returncode == 2, 'Application usage exit code was not propagated'
assert 'Unknown option' in invalid.stderr, 'Option did not reach application parser'
with tempfile.TemporaryDirectory(prefix='launcher check ', dir=temp) as directory:
    isolated = Path(directory)
    # The final explicit root must override the real root, without reading credentials.
    override = run(launcher, 'library', '--root', str(isolated))
    assert override.returncode == 3, 'Spaced root argument or root precedence changed'
    assert 'no installed OAuth credentials' in override.stderr, 'Wrong root was selected'
    scripts = isolated / 'scripts'
    scripts.mkdir()
    shutil.copyfile(launcher, scripts / 'probe.ps1')
    missing = run(scripts / 'probe.ps1')
    assert missing.returncode != 0, 'Missing output incorrectly succeeded'
    assert 'Release application not found' in missing.stderr, 'Missing-output diagnostic lost'
print('PASS: default help, parser exit 2, spaced root override, missing artifact; external working directory')
