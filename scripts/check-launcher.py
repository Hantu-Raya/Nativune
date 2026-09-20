"""Account-free default WinUI and explicit legacy launcher checks; no build."""
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


for name, missing_message, is_winui in (
    ('probe.ps1', 'WinUI application not found', True),
    ('probe-legacy.ps1', 'Legacy WinForms application not found', False),
):
    launcher = root / 'scripts' / name
    help_result = run(launcher)
    assert help_result.returncode == 0, f'{name}: default help failed'
    assert ('native-fixture' in help_result.stdout) == is_winui, f'{name}: wrong application selected'
    invalid = run(launcher, 'help', '--invalid-launcher-check')
    assert invalid.returncode == 2, f'{name}: application usage exit code was not propagated'
    assert 'Unknown option' in invalid.stderr, f'{name}: option did not reach application parser'
    with tempfile.TemporaryDirectory(prefix='launcher check ', dir=temp) as directory:
        isolated = Path(directory)
        # The final explicit root must override the real root, without reading credentials.
        override = run(launcher, 'library', '--root', str(isolated))
        assert override.returncode == 3, f'{name}: spaced root argument or root precedence changed'
        assert 'no installed OAuth credentials' in override.stderr, f'{name}: wrong root was selected'
        scripts = isolated / 'scripts'
        scripts.mkdir()
        shutil.copyfile(launcher, scripts / name)
        missing = run(scripts / name)
        assert missing.returncode != 0, f'{name}: missing output incorrectly succeeded'
        assert missing_message in missing.stderr, f'{name}: missing-output diagnostic lost'
print('PASS: WinUI default and legacy identity, help, parser exit 2, spaced root override, missing artifacts; external working directory')
