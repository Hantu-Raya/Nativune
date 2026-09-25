"""Run: python scripts/check-native-icons.py. Requires the approved local resvg and pwsh."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
scratch = root / '.cache' / 'tmp'
scratch.mkdir(parents=True, exist_ok=True)
pwsh = shutil.which('pwsh')
assert pwsh, 'PowerShell 7 is required for the raster wrapper'
active_names = {
    'app-mark', 'back', 'cancel-timer', 'close', 'compact', 'dislike',
    'error', 'exit-fullscreen', 'forward', 'fullscreen', 'hide', 'home',
    'like', 'minimize', 'next', 'overflow', 'pause', 'pin', 'play-pause',
    'play', 'previous', 'quit-timer', 'quit', 'repeat-one', 'repeat',
    'restore-section', 'restore-window', 'retry', 'settings', 'show',
    'shuffle', 'status', 'tray', 'update', 'update-available',
    'volume-muted', 'volume', 'zoom-in', 'zoom-out', 'zoom-reset',
}
mask_root = root / 'assets' / 'native-icons' / 'states' / 'mask'
assert {path.stem for path in mask_root.glob('*.svg')} == active_names, (
    'active mask registry must contain exactly the 40 canonical SVG names'
)
historical_root = root / 'assets' / 'native-icons' / 'states' / 'historical' / 'mask'
assert {path.name for path in historical_root.glob('*.svg')} == {
    'notifications.svg', 'notifications-off.svg'
}, 'historical notification masks must remain outside active renderer input'
with tempfile.TemporaryDirectory(prefix='native-icon-check-', dir=scratch) as temporary:
    work = Path(temporary)
    inputs = work / 'masks'
    shutil.copytree(mask_root, inputs)
    source = (inputs / 'back.svg').read_text(encoding='utf-8')
    cases = [
        source,
        source.replace('fill="none"', 'fill="url(https://example.invalid/paint)"'),
        source.replace('<svg ', '<!DOCTYPE svg [<!ENTITY remote SYSTEM "https://example.invalid/entity">]><svg ', 1),
        source.replace('<svg ', '<svg onload="alert(1)" ', 1),
    ]
    for index, content in enumerate(cases):
        output = work / str(index)
        (inputs / 'back.svg').write_text(content, encoding='utf-8')
        result = subprocess.run([pwsh, '-NoProfile', '-File', str(root / 'scripts' / 'render-native-icons.ps1'),
            '-InputRoot', str(inputs), '-OutputRoot', str(output)], cwd=root,
            env={**os.environ, 'TEMP': str(scratch), 'TMP': str(scratch)}, capture_output=True, text=True, timeout=30)
        if index == 0:
            assert result.returncode == 0, result.stdout + result.stderr
            png = (output / '20' / 'back.png').read_bytes()
            assert png[:8] == b'\x89PNG\r\n\x1a\n' and int.from_bytes(png[16:20], 'big') == 20
        else:
            assert result.returncode != 0, 'Unsafe SVG was accepted'
            assert not output.exists(), 'Rejected SVG published raster output'
    (inputs / 'back.svg').write_text(source, encoding='utf-8')
    protected = work / 'unrelated'
    protected.mkdir()
    marker = protected / 'keep.txt'
    marker.write_bytes(b'not generated')
    result = subprocess.run([pwsh, '-NoProfile', '-File', str(root / 'scripts' / 'render-native-icons.ps1'),
        '-InputRoot', str(inputs), '-OutputRoot', str(protected)], cwd=root,
        env={**os.environ, 'TEMP': str(scratch), 'TMP': str(scratch)}, capture_output=True, text=True, timeout=30)
    assert result.returncode != 0 and marker.read_bytes() == b'not generated', 'Unrelated output directory was replaced'
print('PASS: safe rendering, external paint/DTD/event refusal, unrelated directory preserved')
