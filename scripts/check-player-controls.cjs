// Run: node scripts/check-player-controls.cjs. No packages or browser profile required.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.join(__dirname, '../src/OAuthProbe/PlayerControls.cs'), 'utf8');
const script = source.match(/private const string JavaScript = """\r?\n([\s\S]*?)\r?\n""";/)[1];

function run({ command = 'play', paused = true, duplicate = false, disabled = false,
    expired = false, origin = 'https://music.youtube.com', stale = false, hidden = false } = {}) {
    let clicks = 0;
    const document = { documentElement: { lang: 'en' }, hidden };
    class Element {
        constructor(label = '') { this.label = label; this.isConnected = true; this.ownerDocument = document; this.parentElement = null; }
        matches() { return false; }
        hasAttribute(name) { return name === 'disabled' && disabled; }
        getAttribute(name) { return name === 'aria-label' ? this.label : null; }
        click() { clicks++; if (this.label === 'Play') media.paused = false; if (this.label === 'Pause') media.paused = true; }
    }
    class Media extends Element {}
    const media = new Media(); media.paused = paused;
    Object.defineProperty(media, 'currentSrc', { get() { throw Error('Stream addresses are outside the control contract'); } });
    const toggle = new Element(paused ? 'Play' : 'Pause');
    const controls = [toggle, new Element('Next'), new Element('Previous')];
    if (duplicate) controls.push(new Element(toggle.label));
    const group = new Element(); group.querySelectorAll = () => controls;
    const bar = new Element(); bar.querySelectorAll = () => [group];
    document.querySelectorAll = selector => selector === 'ytmusic-player-bar' ? [bar]
        : selector === 'audio,video' ? [media] : [];
    const window = {}; window.top = window;
    const href = origin + '/watch';
    const request = { command, href: stale ? href + '?old=1' : href, notAfterUnixMs: expired ? 0 : Date.now() + 60000 };
    const outcome = vm.runInNewContext(`(() => { const request = ${JSON.stringify(request)};\n${script}\n})()`, {
        document, window, location: { origin, href }, HTMLElement: Element, HTMLMediaElement: Media,
        getComputedStyle: () => ({ display: 'block', visibility: 'visible' }),
    }, { timeout: 1000 });
    return { outcome, clicks, paused: media.paused };
}
const played = run();
assert.equal(played.clicks, 1); assert.equal(played.paused, false); assert.equal(played.outcome.code, 'requested');
const noOp = run({ command: 'pause' });
assert.equal(noOp.clicks, 0); assert.equal(noOp.outcome.noOp, true);
const alreadyPlaying = run({ command: 'play', paused: false });
assert.equal(alreadyPlaying.clicks, 0); assert.equal(alreadyPlaying.outcome.noOp, true);
const hidden = run({ command: 'toggle', hidden: true });
assert.equal(hidden.clicks, 1); assert.equal(hidden.paused, false);
for (const [options, expected] of [
    [{ duplicate: true }, 'unavailable'], [{ disabled: true }, 'disabled-control'],
    [{ expired: true }, 'expired'], [{ origin: 'https://music.youtube.com.evil.example' }, 'wrong-origin'],
    [{ stale: true }, 'stale-document'], [{ command: 'arbitrary' }, 'unavailable'],
]) {
    const result = run(options);
    assert.equal(result.clicks, 0); assert.equal(result.outcome.code, expected);
}
console.log('PASS: one-click dispatch, explicit no-op, hidden toggle, duplicate/disabled/expired/origin/stale/unknown refusal');
