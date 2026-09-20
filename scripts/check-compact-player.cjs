// Run: node scripts/check-compact-player.cjs. No packages or browser profile required.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.join(__dirname, '../src/Nativune/CompactPlayback.cs'), 'utf8');
const script = source.match(/private const string CompactJavaScript = """\r?\n([\s\S]*?)\r?\n""";/)[1];

class Element {
  constructor(document, label = '', { width = 120, height = 24 } = {}) {
    this.ownerDocument = document; this.label = label; this.parentElement = null;
    this.isConnected = true; this.children = []; this.attrs = new Map();
    this.rect = { left: 10, top: 20, width, height }; this.textContent = '';
    this.complete = true; this.naturalWidth = 64; this.naturalHeight = 64;
    this._queries = new Map(); this.events = [];
  }
  append(...children) { for (const child of children) { child.parentElement = this; this.children.push(child); } return this; }
  querySelectorAll(selector) { return this._queries.get(selector) || []; }
  setQuery(selector, values) { this._queries.set(selector, values); return this; }
  getBoundingClientRect() { return this.rect; }
  hasAttribute(name) { return this.attrs.has(name); }
  getAttribute(name) { return name === 'aria-label' ? this.attrs.get(name) ?? this.label : this.attrs.get(name) ?? null; }
  setAttribute(name, value = '') { this.attrs.set(name, String(value)); return this; }
  matches(selector) { return selector === ':disabled' && this.hasAttribute('disabled'); }
  dispatchEvent(event) { this.events.push(event); return true; }
}
class HTMLElement extends Element {
  click() { this.ownerDocument.clicks++; }
}
class HTMLMediaElement extends HTMLElement {}

function makePage({ duration = 120, position = 10, volume = 0.5, paused = false,
  lang = 'en', origin = 'https://music.youtube.com', href = origin + '/watch',
  seekable = true, seekableReads, likePressed = 'true', dislikePressed = 'false',
  duplicate = false, disabled = false, modal = false, buttonHeight = 24,
  sliderHeight = 0, trackHeight = 8, track = true, image = true } = {}) {
  const document = { clicks: 0, documentElement: { lang }, hidden: false };
  const bar = new HTMLElement(document);
  const media = new HTMLMediaElement(document);
  Object.assign(media, { currentTime: position, duration, volume, paused, muted: false });
  let seekableRead = 0;
  Object.defineProperty(media, 'seekable', { get() {
    seekableRead++;
    const value = seekableReads ? seekableReads[Math.min(seekableRead - 1, seekableReads.length - 1)] : seekable;
    return { length: value ? 1 : 0 };
  }});
  Object.defineProperty(media, 'currentSrc', { get() { throw Error('stream addresses are outside the control contract'); } });

  const makeButton = (label, pressed) => {
    const button = new HTMLElement(document, label, { width: 80, height: buttonHeight });
    if (pressed !== undefined) button.setAttribute('aria-pressed', pressed);
    if (disabled) button.setAttribute('disabled', '');
    return button;
  };
  const buttons = [makeButton('Like', likePressed), makeButton('Dislike', dislikePressed), makeButton('Mute')];
  if (duplicate) buttons.push(makeButton('Like', likePressed));
  const makeSlider = (id) => {
    const slider = new HTMLElement(document, '', { width: 220, height: sliderHeight });
    slider.setAttribute('id', id).setAttribute('aria-valuemin', id === 'volume-slider' ? '0' : '0')
      .setAttribute('aria-valuemax', id === 'volume-slider' ? '100' : String(duration || 120))
      .setAttribute('aria-valuenow', id === 'volume-slider' ? String(volume * 100) : String(position));
    if (track) {
      const inner = new HTMLElement(document, '', { width: 200, height: trackHeight });
      inner.setAttribute('id', 'sliderBar').setAttribute('aria-hidden', 'true'); slider.append(inner); slider.setQuery('[id="sliderBar"]', [inner]);
    }
    return slider;
  };
  const seekSlider = makeSlider('progress-bar');
  const volumeSlider = makeSlider('volume-slider');
  const title = new HTMLElement(document, '', { width: 160, height: 24 }); title.textContent = 'Track title';
  const artwork = new HTMLElement(document, '', { width: 48, height: 48 }); artwork.currentSrc = 'https://i.ytimg.com/vi/example/hqdefault.jpg';
  bar.setQuery('button,[role="button"]', buttons)
    .setQuery('tp-yt-paper-slider[id="progress-bar"]', [seekSlider])
    .setQuery('tp-yt-paper-slider[id="volume-slider"]', [volumeSlider])
    .setQuery('.title', [title]).setQuery('img', image ? [artwork] : []);
  const modals = modal ? [new HTMLElement(document)] : [];
  if (modal) modals[0].setAttribute('aria-modal', 'true');
  document.querySelectorAll = selector => selector === 'ytmusic-player-bar' ? [bar]
    : selector === 'audio,video' ? [media]
    : selector === 'dialog[open],[aria-modal="true"]' ? modals : [];
  const location = { origin, href };
  const window = {}; window.top = window;
  return { document, bar, media, buttons, seekSlider, volumeSlider, location, window,
    modal: modals[0], signature: JSON.stringify(['Track title', image ? artwork.currentSrc : null, duration === Infinity || Number.isNaN(duration) ? 0 : duration]) };
}

function run(page, request) {
  const context = {
    document: page.document, window: page.window, location: page.location,
    HTMLElement, HTMLMediaElement, URL, MouseEvent: class MouseEvent {
      constructor(type, options) { this.type = type; Object.assign(this, options); }
    },
    getComputedStyle: () => ({ display: 'block', visibility: 'visible' }),
    Date,
  };
  return vm.runInNewContext(`(() => { const request = ${JSON.stringify(request)};\n${script}\n})()`, context, { timeout: 1000 });
}
function request(page, mode, command = null, value = null, expectedStateSignature = null, overrides = {}) {
  return { mode, command, href: page.location.href, notAfterUnixMs: Date.now() + 60000,
    value, expectedStateSignature, ...overrides };
}
function state(page, overrides = {}) { return run(page, request(page, 'state', null, null, null, overrides)); }
function action(page, command, value = null, signature = page.signature, overrides = {}) {
  return run(page, request(page, 'action', command, value, signature, overrides)).code;
}

const knownPage = makePage();
const known = state(knownPage);
assert.equal(known.code, 'state');
assert.equal(known.duration, 120); assert.equal(known.canSeek, true); assert.equal(known.canVolume, true);
assert.equal(known.canLike, true); assert.equal(known.canDislike, true);
const unknownPage = makePage({ duration: Infinity, position: 10 });
const unknown = state(unknownPage);
assert.equal(unknown.code, 'state'); assert.equal(unknown.duration, 0);
assert.equal(unknown.position, 10); assert.equal(unknown.canSeek, false);
assert.equal(state(makePage({ duration: 120, position: 121 })).code, 'unavailable');
assert.equal(state(makePage({ volume: 1.1 })).code, 'unavailable');
assert.equal(state(makePage({ likePressed: null })).canLike, false);
assert.equal(state(makePage({ likePressed: null })).liked, null);
assert.equal(state(makePage({ track: false })).canSeek, false);
assert.equal(state(makePage({ track: false })).canVolume, false);
assert.equal(action(makePage(), 'seek', -1), 'invalid-value');
assert.equal(action(makePage(), 'volume', 1.01), 'invalid-value');

for (const [options, expected] of [
  [{ origin: 'https://music.youtube.com.evil.example' }, 'wrong-origin'],
  [{ lang: 'fr' }, 'unsupported-locale'],
  [{ modal: true }, 'modal-open'],
  [{ duplicate: true }, 'ambiguous-control'],
  [{ disabled: true }, 'disabled-control'],
]) assert.equal(action(makePage(options), 'like'), expected);
const stale = makePage();
const staleRequest = request(stale, 'action', 'like', null, stale.signature, { href: 'https://music.youtube.com/watch?old=1' });
assert.equal(run(stale, staleRequest).code, 'stale-document');
const lostSeekability = makePage({ seekableReads: [true, false] });
assert.equal(action(lostSeekability, 'seek', 30), 'invalid-value');

const seekPage = makePage({ sliderHeight: 0, trackHeight: 8 });
assert.equal(action(seekPage, 'seek', 30), 'requested');
assert.deepEqual(seekPage.seekSlider.children[0].events.map(event => event.type), ['mousedown', 'mouseup']);
const volumePage = makePage({ sliderHeight: 0, trackHeight: 8 });
assert.equal(action(volumePage, 'volume', 0.75), 'requested');
assert.deepEqual(volumePage.volumeSlider.children[0].events.map(event => event.type), ['mousedown', 'mouseup']);
const likePage = makePage();
assert.equal(action(likePage, 'like'), 'requested');
assert.equal(likePage.document.clicks, 1);
assert.equal(action(likePage, 'like'), 'requested');
assert.equal(likePage.document.clicks, 2);

console.log('PASS: compact state bounds/unknown duration, guarded DOM actions, metadata signatures, seekability, pointer dispatch, and single button clicks');
