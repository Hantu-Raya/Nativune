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
    this._listeners = new Map();
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
  click() {
    this.ownerDocument.clicks++;
    if (this.getAttribute('aria-label') === 'Mute' || this.getAttribute('aria-label') === 'Unmute') {
      const media = this.ownerDocument.media;
      media.muted = !media.muted;
      this.setAttribute('aria-label', media.muted ? 'Unmute' : 'Mute');
    }
  }
}
class HTMLMediaElement extends HTMLElement {}

function makePage({ duration = 120, position = 10, volume = 0.5, paused = false, seeking = false,
  lang = 'en', origin = 'https://music.youtube.com', href = origin + '/watch',
  seekable = true, seekableReads, likePressed = 'true', dislikePressed = 'false',
  duplicate = false, duplicateTransport = false, disabled = false, modal = false, buttonHeight = 24,
  transport = true, hasMedia = true, sliderHeight = 0, trackHeight = 8, track = true, image = true } = {}) {
  const document = { clicks: 0, documentElement: { lang }, hidden: false };
  const bar = new HTMLElement(document);
  const media = new HTMLMediaElement(document);
  document.media = media;
  Object.assign(media, { currentTime: position, duration, volume, paused, muted: false, seeking });
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
  const transportButtons = transport
    ? [makeButton('Previous'), makeButton(paused ? 'Play' : 'Pause'), makeButton('Next')] : [];
  if (duplicateTransport) transportButtons.push(makeButton(paused ? 'Play' : 'Pause'));
  const buttons = [...transportButtons, makeButton('Like', likePressed), makeButton('Dislike', dislikePressed), makeButton('Mute')];
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
  const transportGroup = new HTMLElement(document);
  transportGroup.setAttribute('id', 'left-controls').setAttribute('class', 'left-controls ytmusic-player-bar');
  transportGroup.append(...transportButtons);
  transportGroup.setQuery('button,[role="button"]', transportButtons);
  bar.append(transportGroup);
  bar.setQuery('[id="left-controls"].left-controls.ytmusic-player-bar', [transportGroup])
    .setQuery('button,[role="button"]', buttons)
    .setQuery('tp-yt-paper-slider[id="progress-bar"]', [seekSlider])
    .setQuery('tp-yt-paper-slider[id="volume-slider"]', [volumeSlider])
    .setQuery('.title', [title]).setQuery('img', image ? [artwork] : []);
  const modals = modal ? [new HTMLElement(document)] : [];
  if (modal) modals[0].setAttribute('aria-modal', 'true');
  document.querySelectorAll = selector => selector === 'ytmusic-player-bar' ? [bar]
    : selector === 'audio,video' ? (hasMedia ? [media] : [])
    : selector === 'dialog[open],[aria-modal="true"]' ? modals : [];
  const location = { origin, href };
  const window = {}; window.top = window;
  return { document, bar, media, buttons, seekSlider, volumeSlider, location, window,
    modal: modals[0], signature: JSON.stringify(['Track title', image ? artwork.currentSrc : null, duration === Infinity || Number.isNaN(duration) ? 0 : duration]) };
}

function run(page, request) {
  const context = {
    document: page.document, window: page.window, location: page.location,
    HTMLElement, HTMLMediaElement, URL,
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
function transportReady(page) { return run(page, request(page, 'ready')).code === 'ready'; }
function action(page, command, value = null, signature = page.signature, overrides = {}) {
  return run(page, request(page, 'action', command, value, signature, overrides)).code;
}
function actionResult(page, command, value = null, signature = page.signature, overrides = {}) {
  return run(page, request(page, 'action', command, value, signature, overrides));
}

const knownPage = makePage();
assert.equal(transportReady(knownPage), true);
assert.equal(knownPage.document.clicks, 0);
assert.equal(transportReady(makePage({ paused: true })), true);
assert.equal(transportReady(makePage({ disabled: true })), false);
assert.equal(transportReady(makePage({ transport: false })), false);
assert.equal(transportReady(makePage({ duplicateTransport: true })), false);
assert.equal(state(makePage({ duplicateTransport: true })).code, 'unavailable');
assert.equal(transportReady(makePage({ hasMedia: false })), true);
assert.equal(state(makePage({ transport: false })).code, 'unavailable');
assert.equal(state(makePage({ hasMedia: false })).code, 'unavailable');
const known = state(knownPage);
assert.equal(known.code, 'state');
assert.equal(known.duration, 120); assert.equal(known.canSeek, true);
assert.equal(known.canLike, true); assert.equal(known.canDislike, true);
const unknownPage = makePage({ duration: Infinity, position: 10 });
const unknown = state(unknownPage);
assert.equal(unknown.code, 'state'); assert.equal(unknown.duration, 0);
assert.equal(unknown.position, 10); assert.equal(unknown.canSeek, false);
const clockAheadState = state(makePage({ duration: 120, position: 121 }));
assert.equal(clockAheadState.code, 'state');
assert.equal(clockAheadState.position, 121);
assert.equal(clockAheadState.canSeek, false);
assert.equal(clockAheadState.canLike, true);
assert.equal(state(makePage({ likePressed: null })).canLike, false);
assert.equal(state(makePage({ likePressed: null })).liked, null);
assert.equal(state(makePage({ track: false })).canSeek, false);
assert.equal(action(makePage(), 'seek', -1), 'invalid-value');
const mixedTime = makePage({ track: false });
mixedTime.seekSlider.setAttribute('aria-valuenow', '100');
const mixedTimeState = state(mixedTime);
assert.equal(mixedTimeState.code, 'state');
assert.equal(mixedTimeState.canSeek, false);
const inFlightSeek = makePage({ seeking: true });
assert.equal(state(inFlightSeek).code, 'state');
assert.equal(state(inFlightSeek).canSeek, false);
const noAudioControlsPage = makePage();
const noAudioControlsState = state(noAudioControlsPage);
assert.equal(noAudioControlsState.code, 'state');
for (const field of ['volume', 'muted', 'canVolume'])
  assert.equal(Object.hasOwn(noAudioControlsState, field), false);
for (const [command, value] of [['volume', 0.75], ['mute', null]]) {
  const before = { volume: noAudioControlsPage.media.volume, muted: noAudioControlsPage.media.muted };
  const result = actionResult(noAudioControlsPage, command, value);
  assert.equal(result.code, 'unsupported-command');
  assert.equal(result.dispatched, false);
  assert.equal(noAudioControlsPage.media.volume, before.volume);
  assert.equal(noAudioControlsPage.media.muted, before.muted);
  assert.equal(noAudioControlsPage.document.clicks, 0);
}

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
assert.equal(lostSeekability.media.currentTime, 10);
const staleSeekPage = makePage();
staleSeekPage.bar.querySelectorAll('.title')[0].textContent = 'Different synthetic track';
assert.equal(action(staleSeekPage, 'seek', 30), 'stale-state');
assert.equal(staleSeekPage.media.currentTime, 10);

const seekPage = makePage({ sliderHeight: 0, trackHeight: 8 });
assert.equal(action(seekPage, 'seek', 30), 'requested');
assert.equal(seekPage.media.currentTime, 30);
assert.deepEqual(seekPage.seekSlider.children[0].events, []);
const postSeek = makePage();
postSeek.media.currentTime = 30;
const seekingState = state(postSeek);
assert.equal(seekingState.code, 'state');
assert.equal(seekingState.position, 30);
assert.equal(seekingState.canSeek, false);
const blockedInFlightSeek = actionResult(inFlightSeek, 'seek', 40);
assert.equal(blockedInFlightSeek.code, 'unavailable');
assert.equal(blockedInFlightSeek.dispatched, false);
assert.equal(inFlightSeek.media.currentTime, 10);
assert.equal(seekingState.canLike, true);
const refusedDuringSkew = actionResult(postSeek, 'seek', 40);
assert.equal(refusedDuringSkew.code, 'unavailable');
assert.equal(refusedDuringSkew.dispatched, false);
assert.equal(postSeek.media.currentTime, 30);
postSeek.seekSlider.setAttribute('aria-valuenow', '30');
assert.equal(state(postSeek).canSeek, true);
assert.equal(action(postSeek, 'seek', 40), 'requested');
assert.doesNotMatch(script, /\.volume\b/);
assert.doesNotMatch(script, /\.muted\b/);
assert.doesNotMatch(script, /\.value\s*=(?!=)/);
const transitionPage = makePage({ duration: 120, position: 60 });
for (const [index, duration, position] of [
  [1, 180, 2], [2, 210, 180], [3, 90, 10], [4, 240, 180]
]) {
  transitionPage.bar.querySelectorAll('.title')[0].textContent = `Synthetic track ${index}`;
  transitionPage.media.duration = duration;
  transitionPage.media.currentTime = position;
  const skewedTrackState = state(transitionPage);
  assert.equal(skewedTrackState.code, 'state');
  assert.equal(skewedTrackState.title, `Synthetic track ${index}`);
  assert.equal(skewedTrackState.duration, duration);
  assert.equal(skewedTrackState.position, position);
  assert.equal(skewedTrackState.canSeek, false);
  assert.equal(skewedTrackState.canLike, true);
  transitionPage.seekSlider.setAttribute('aria-valuemax', String(duration));
  transitionPage.seekSlider.setAttribute('aria-valuenow', String(position));
  const settledTrackState = state(transitionPage);
  assert.equal(settledTrackState.code, 'state');
  assert.equal(settledTrackState.title, `Synthetic track ${index}`);
  assert.equal(settledTrackState.canSeek, true);
}
const likePage = makePage();
assert.equal(action(likePage, 'like'), 'requested');
assert.equal(likePage.document.clicks, 1);
assert.equal(action(likePage, 'like'), 'requested');
assert.equal(likePage.document.clicks, 2);

console.log('PASS: bounded public transport readiness, transient seek-clock recovery, unsupported Compact audio commands, and single-click actions');
