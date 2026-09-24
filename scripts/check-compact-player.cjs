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
  matches(selector) { return selector === ':disabled' && this.hasAttribute('disabled')
    || selector === ':hover' && this.hovered === true
    || selector === ':focus-visible' && this.focusVisible === true; }
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
  lang = 'en', origin = 'https://music.youtube.com', href = origin + '/watch?v=AbCdEfGhI01',
  likePressed = 'true', dislikePressed = 'false',
  duplicate = false, duplicateTransport = false, disabled = false, progressDisabled = false,
  modal = false, buttonHeight = 24,
  transport = true, hasMedia = true, shuffle = true, shuffleLabel = 'Shuffle', shufflePressed,
  shuffleColor, shuffleHovered = false, shuffleFocused = false,
  repeatLabel = 'Repeat off', repeatColor = 'rgb(144, 144, 144)',
  sliderHeight = 0, trackHeight = 8, track = true, image = true,
  timeInfo = false, websitePosition = position, websiteDuration = duration, timeText,
  duplicateTimeInfo = false, hiddenTimeInfo = false, ariaMin, ariaMax, ariaNow,
  sliderValueWritable = true, allowSeeking = true, siteOffset = 0 } = {}) {
  const document = { clicks: 0, documentElement: { lang }, hidden: false };
  const bar = new HTMLElement(document);
  const media = new HTMLMediaElement(document);
  document.media = media;
  Object.assign(media, { currentTime: position, duration, volume, paused, muted: false, seeking });
  Object.defineProperty(media, 'seekable', { get() { throw Error('seekable must not be read'); } });
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
  if (repeatLabel) {
    const button = makeButton(repeatLabel);
    button.visualColor = repeatColor;
    buttons.push(button);
  }
  if (shuffle) {
    const button = makeButton(shuffleLabel, shufflePressed);
    button.visualColor = shuffleColor;
    button.hovered = shuffleHovered;
    button.focusVisible = shuffleFocused;
    buttons.push(button);
  }
  if (duplicate) buttons.push(makeButton('Like', likePressed));
  const seekToCalls = [];
  const makeSlider = (id) => {
    const slider = new HTMLElement(document, '', { width: 220, height: sliderHeight });
    const isProgress = id === 'progress-bar';
    slider.setAttribute('id', id).setAttribute('aria-valuemin', id === 'volume-slider' ? '0' : String(isProgress ? (ariaMin ?? 0) : 0))
      .setAttribute('aria-valuemax', id === 'volume-slider' ? '100'
        : String(isProgress ? (ariaMax ?? (timeInfo ? websiteDuration : duration || 120)) : (duration || 120)))
      .setAttribute('aria-valuenow', id === 'volume-slider' ? String(volume * 100)
        : String(isProgress ? (ariaNow ?? (timeInfo ? websitePosition : position)) : position));
    if (isProgress) {
      if (progressDisabled) slider.setAttribute('disabled', '');
      let value = Number(slider.getAttribute('aria-valuenow'));
      Object.defineProperty(slider, 'value', { get() { return value; }, set(next) {
        if (!sliderValueWritable) return;
        const min = Number(slider.getAttribute('aria-valuemin'));
        const max = Number(slider.getAttribute('aria-valuemax'));
        value = Math.round(Math.max(min, Math.min(max, next)));
      }});
      slider.dispatchEvent = event => {
        slider.events.push(event);
        if (event.type === 'change' && allowSeeking) {
          seekToCalls.push(slider.value);
          media.currentTime = slider.value + siteOffset;
        }
        return true;
      };
    }
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
  const formatTime = seconds => `${Math.floor(seconds / 60)}:${String(Math.floor(seconds % 60)).padStart(2, '0')}`;
  const makeTimeInfo = () => {
    const element = new HTMLElement(document, '', { width: 96, height: hiddenTimeInfo ? 0 : 18 });
    element.setAttribute('class', 'time-info');
    element.textContent = timeText ?? `${formatTime(websitePosition)} / ${formatTime(websiteDuration)}`;
    if (hiddenTimeInfo) element.setAttribute('hidden', '');
    return element;
  };
  const timeInfos = timeInfo ? [makeTimeInfo()] : [];
  if (duplicateTimeInfo) timeInfos.push(makeTimeInfo());
  bar.append(transportGroup, ...timeInfos);
  bar.setQuery('[id="left-controls"].left-controls.ytmusic-player-bar', [transportGroup])
    .setQuery('button,[role="button"]', buttons)
    .setQuery('tp-yt-paper-slider[id="progress-bar"]', [seekSlider])
    .setQuery('tp-yt-paper-slider[id="volume-slider"]', [volumeSlider])
    .setQuery('.title', [title]).setQuery('img', image ? [artwork] : [])
    .setQuery('span.time-info', timeInfos);
  const modals = modal ? [new HTMLElement(document)] : [];
  if (modal) modals[0].setAttribute('aria-modal', 'true');
  document.querySelectorAll = selector => selector === 'ytmusic-player-bar' ? [bar]
    : selector === 'audio,video' ? (hasMedia ? [media] : [])
    : selector === 'dialog[open],[aria-modal="true"]' ? modals : [];
  const location = { origin, href };
  const window = {}; window.top = window;
  const mediaDuration = duration === Infinity || Number.isNaN(duration) ? 0 : duration;
  const ariaAgrees = Math.abs(ariaMin ?? 0) <= 2
    && Math.abs((ariaMax ?? (timeInfo ? websiteDuration : duration)) - websiteDuration) <= 2
    && Math.abs((ariaNow ?? websitePosition) - websitePosition) <= 2;
  const displayedDuration = timeInfo && !duplicateTimeInfo && !hiddenTimeInfo && ariaAgrees
    ? websiteDuration : mediaDuration;
  const parsedHref = new URL(href);
  const videoIds = parsedHref.searchParams.getAll('v');
  const videoId = parsedHref.pathname === '/watch' && videoIds.length === 1
    && /^[A-Za-z0-9_-]{11}$/.test(videoIds[0]) ? videoIds[0] : null;
  return { document, bar, media, buttons, seekSlider, volumeSlider, timeInfos, location, window,
    modal: modals[0], seekToCalls,
    signature: JSON.stringify(['Track title', image ? artwork.currentSrc : null, displayedDuration, videoId]) };
}

function run(page, request) {
  const context = {
    document: page.document, window: page.window, location: page.location,
    HTMLElement, HTMLMediaElement, URL, Event,
    getComputedStyle: element => ({ display: 'block', visibility: 'visible', color: element.visualColor }),
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
assert.equal(known.videoId, 'AbCdEfGhI01');
assert.equal(known.clockConfirmed, true);
assert.equal(state(makePage({ href: 'https://music.youtube.com/watch?v=AbCdEfGhI01&v=ZbCdEfGhI01' })).videoId, null);
assert.equal(state(makePage({ href: 'https://music.youtube.com/watch?v=invalid' })).videoId, null);
assert.equal(state(makePage({ href: 'https://music.youtube.com/playlist?v=AbCdEfGhI01' })).videoId, null);
assert.equal(known.canLike, true); assert.equal(known.canDislike, true);
assert.equal(known.canShuffle, true);
assert.equal(known.shuffle, null);
assert.equal(state(makePage({ shufflePressed: 'true' })).shuffle, true);
assert.equal(state(makePage({ shufflePressed: 'false' })).shuffle, false);
assert.equal(state(makePage({ shufflePressed: 'yes' })).shuffle, null);
assert.equal(state(makePage({ shuffleLabel: 'Shuffle on', shufflePressed: 'true' })).canShuffle, true);
assert.equal(state(makePage({ shuffleColor: 'rgb(255, 255, 255)' })).shuffle, true);
assert.equal(state(makePage({ shuffleColor: 'rgb(144, 144, 144)' })).shuffle, false);
assert.equal(state(makePage({ shuffleColor: 'rgb(255, 255, 255)', repeatColor: 'rgb(255, 255, 255)' })).shuffle, null);
assert.equal(state(makePage({ shuffleColor: 'rgb(255, 255, 255)', repeatLabel: 'Repeat all' })).shuffle, null);
assert.equal(state(makePage({ shuffleColor: 'rgb(255, 255, 255)', repeatLabel: null })).shuffle, null);
assert.equal(state(makePage({ shuffleColor: 'rgb(244, 244, 244)' })).shuffle, null);
assert.equal(state(makePage({ shuffleColor: 'rgb(255, 255, 255)', shuffleHovered: true })).shuffle, null);
assert.equal(state(makePage({ shuffleColor: 'rgb(255, 255, 255)', shuffleFocused: true })).shuffle, null);
assert.equal(state(makePage({ shuffleColor: 'rgb(255, 255, 255)', shufflePressed: 'false' })).shuffle, false);
assert.equal(state(makePage({ shuffleColor: 'rgb(255, 255, 255)', shuffleLabel: 'Shuffle on' })).shuffle, null);
const shufflePage = makePage();
const shuffled = actionResult(shufflePage, 'shuffle');
assert.equal(shuffled.code, 'requested');
assert.equal(shuffled.dispatched, true);
assert.equal(shufflePage.document.clicks, 1);
const noShuffle = makePage({ shuffle: false });
assert.equal(state(noShuffle).canShuffle, false);
assert.equal(action(noShuffle, 'shuffle'), 'unavailable');
assert.equal(noShuffle.document.clicks, 0);
const duplicateShuffle = makePage();
duplicateShuffle.buttons.push(new HTMLElement(duplicateShuffle.document, 'Shuffle'));
assert.equal(state(duplicateShuffle).canShuffle, false);
assert.equal(action(duplicateShuffle, 'shuffle'), 'ambiguous-control');
assert.equal(duplicateShuffle.document.clicks, 0);
const unknownPage = makePage({ duration: Infinity, position: 10 });
const unknown = state(unknownPage);
assert.equal(unknown.code, 'state'); assert.equal(unknown.duration, 0);
assert.equal(unknown.position, 10); assert.equal(unknown.canSeek, false);
const clockAheadState = state(makePage({ duration: 120, position: 121 }));
assert.equal(clockAheadState.code, 'state');
assert.equal(clockAheadState.position, 121);
assert.equal(clockAheadState.canSeek, false);
assert.equal(clockAheadState.clockMismatch, true);
assert.equal(clockAheadState.clockConfirmed, false);
assert.equal(clockAheadState.canLike, true);
assert.equal(state(makePage({ likePressed: null })).canLike, false);
assert.equal(state(makePage({ likePressed: null })).liked, null);
assert.equal(state(makePage({ track: false })).canSeek, false);
const negativeSeekPage = makePage();
const negativeSeekResult = actionResult(negativeSeekPage, 'seek', -1);
assert.equal(negativeSeekResult.code, 'invalid-value');
assert.equal(negativeSeekResult.dispatched, false);
assert.equal(negativeSeekPage.seekSlider.events.length, 0);
const mixedTime = makePage({ track: false });
mixedTime.seekSlider.setAttribute('aria-valuenow', '100');
const mixedTimeState = state(mixedTime);
assert.equal(mixedTimeState.code, 'state');
assert.equal(mixedTimeState.canSeek, false);
assert.equal(mixedTimeState.clockConfirmed, false);
const inFlightSeek = makePage({ seeking: true });
assert.equal(state(inFlightSeek).code, 'state');
assert.equal(state(inFlightSeek).canSeek, false);
assert.equal(state(inFlightSeek).clockConfirmed, true);
const noAudioControlsPage = makePage();
const noAudioControlsState = state(noAudioControlsPage);
assert.equal(noAudioControlsState.code, 'state');
assert.equal(noAudioControlsState.mediaPosition, noAudioControlsPage.media.currentTime);
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
const staleSeekPage = makePage();
staleSeekPage.bar.querySelectorAll('.title')[0].textContent = 'Different synthetic track';
const staleSeek = actionResult(staleSeekPage, 'seek', 30);
assert.equal(staleSeek.code, 'stale-state');
assert.equal(staleSeekPage.seekToCalls.length, 0);
assert.equal(staleSeekPage.seekSlider.events.length, 0);

const seekPage = makePage({ sliderHeight: 0, trackHeight: 8 });
const seekResult = actionResult(seekPage, 'seek', 30);
assert.equal(seekResult.code, 'requested');
assert.deepEqual(seekPage.seekToCalls, [30]);
assert.equal(seekPage.media.currentTime, 30);
assert.deepEqual(seekPage.seekSlider.children[0].events, []);
const postSeek = makePage();
postSeek.media.currentTime = 30;
const seekingState = state(postSeek);
assert.equal(seekingState.code, 'state');
assert.equal(seekingState.position, 30);
assert.equal(seekingState.canSeek, false);
assert.equal(seekingState.clockMismatch, true);
const blockedInFlightSeek = actionResult(inFlightSeek, 'seek', 40);
assert.equal(blockedInFlightSeek.code, 'unavailable');
assert.equal(blockedInFlightSeek.dispatched, false);
assert.equal(inFlightSeek.media.currentTime, 10);
assert.deepEqual(inFlightSeek.seekToCalls, []);
assert.equal(seekingState.canLike, true);
const refusedDuringSkew = actionResult(postSeek, 'seek', 40);
assert.equal(refusedDuringSkew.code, 'unavailable');
assert.equal(refusedDuringSkew.dispatched, false);
assert.equal(postSeek.media.currentTime, 30);
assert.deepEqual(postSeek.seekToCalls, []);
postSeek.seekSlider.setAttribute('aria-valuenow', '30');
assert.equal(state(postSeek).canSeek, true);
assert.equal(state(postSeek).clockMismatch, false);
assert.equal(action(postSeek, 'seek', 40), 'requested');
const roundedWebsiteClock = makePage({ duration: 245, position: 17.3, timeInfo: true,
  websitePosition: 17, websiteDuration: 246, ariaMax: 246, ariaNow: 17 });
const roundedWebsiteState = state(roundedWebsiteClock);
assert.equal(roundedWebsiteState.websiteClock, true);
assert.equal(roundedWebsiteState.position, 17);
assert.equal(roundedWebsiteState.duration, 246);
assert.equal(roundedWebsiteState.mediaDuration, 245);
assert.equal(roundedWebsiteState.clockConfirmed, true);
assert.equal(roundedWebsiteState.canSeek, true);
assert.equal(action(roundedWebsiteClock, 'seek', 30), 'requested');
assert.deepEqual(roundedWebsiteClock.seekToCalls, [30]);
assert.equal(roundedWebsiteClock.media.currentTime, 30);

const roundedEndClock = makePage({ duration: 245, position: 242, timeInfo: true,
  websitePosition: 243, websiteDuration: 246, ariaMax: 246, ariaNow: 243 });
assert.equal(state(roundedEndClock).canSeek, true);
assert.equal(action(roundedEndClock, 'seek', 246), 'requested');
assert.deepEqual(roundedEndClock.seekToCalls, [246]);

const offsetWebsiteClock = makePage({ duration: 378, position: 354, timeInfo: true,
  websitePosition: 156, websiteDuration: 180, siteOffset: 198 });
const offsetWebsiteState = state(offsetWebsiteClock);
assert.equal(offsetWebsiteState.websiteClock, true);
assert.equal(offsetWebsiteState.position, 156);
assert.equal(offsetWebsiteState.duration, 180);
assert.equal(offsetWebsiteState.mediaDuration, 378);
assert.equal(offsetWebsiteState.clockMismatch, false);
assert.equal(offsetWebsiteState.clockConfirmed, true);
assert.equal(offsetWebsiteState.canSeek, true);
const offsetSeek = actionResult(offsetWebsiteClock, 'seek', 120);
assert.equal(offsetSeek.code, 'requested');
assert.equal(offsetSeek.dispatched, true);
assert.deepEqual(offsetWebsiteClock.seekToCalls, [120]);
assert.equal(offsetWebsiteClock.media.currentTime, 318);

const driftWebsiteClock = makePage({ duration: 378, position: 340, timeInfo: true,
  websitePosition: 156, websiteDuration: 180, siteOffset: 184 });
const driftWebsiteState = state(driftWebsiteClock);
assert.equal(driftWebsiteState.websiteClock, true);
assert.equal(driftWebsiteState.position, 156);
assert.equal(driftWebsiteState.clockMismatch, false);
assert.equal(driftWebsiteState.clockConfirmed, true);
assert.equal(driftWebsiteState.canSeek, true);
const driftSeek = actionResult(driftWebsiteClock, 'seek', 120);
assert.equal(driftSeek.code, 'requested');
assert.equal(driftSeek.dispatched, true);
assert.deepEqual(driftWebsiteClock.seekToCalls, [120]);
assert.equal(driftWebsiteClock.media.currentTime, 304);

const livePair = makePage({ duration: 389.2, position: 364.1, timeInfo: true,
  websitePosition: 94, websiteDuration: 193, ariaMax: 193, ariaNow: 94, siteOffset: 270.1 });
const livePairState = state(livePair);
assert.equal(livePairState.websiteClock, true);
assert.equal(livePairState.position, 94);
assert.equal(livePairState.duration, 193);
assert.equal(livePairState.mediaDuration, 389.2);
assert.equal(livePairState.clockMismatch, false);
assert.equal(livePairState.clockConfirmed, true);
assert.equal(livePairState.canSeek, true);
const livePairSeek = actionResult(livePair, 'seek', 100);
assert.equal(livePairSeek.code, 'requested');
assert.equal(livePairSeek.dispatched, true);
assert.deepEqual(livePair.seekToCalls, [100]);
assert.equal(livePair.media.currentTime, 370.1);
const livePairEnd = makePage({ duration: 389.2, position: 364.1, timeInfo: true,
  websitePosition: 94, websiteDuration: 193, ariaMax: 193, ariaNow: 94, siteOffset: 270.1 });
assert.equal(actionResult(livePairEnd, 'seek', 193).code, 'requested');
assert.deepEqual(livePairEnd.seekToCalls, [193]);

const grewDuringSeek = makePage({ duration: 389.2, position: 364.1, timeInfo: true,
  websitePosition: 94, websiteDuration: 193, ariaMax: 193, ariaNow: 94, siteOffset: 270.1 });
const preGrowthSignature = grewDuringSeek.signature;
grewDuringSeek.media.duration = 402;
const grownSeek = actionResult(grewDuringSeek, 'seek', 100, preGrowthSignature);
assert.equal(grownSeek.code, 'requested');
assert.deepEqual(grewDuringSeek.seekToCalls, [100]);
assert.equal(grewDuringSeek.media.currentTime, 370.1);
const changedItemDuringSeek = makePage({ duration: 389.2, position: 364.1, timeInfo: true,
  websitePosition: 94, websiteDuration: 193, ariaMax: 193, ariaNow: 94, siteOffset: 270.1,
  href: 'https://music.youtube.com/watch?v=abcdefghijk' });
const changedItemSeek = actionResult(changedItemDuringSeek, 'seek', 100, preGrowthSignature);
assert.equal(changedItemSeek.code, 'stale-state');
assert.deepEqual(changedItemDuringSeek.seekToCalls, []);

const appendedDurationClock = makePage({ duration: 249, position: 203, timeInfo: true,
  websitePosition: 170, websiteDuration: 198, ariaMax: 198, ariaNow: 170, siteOffset: 51 });
const appendedDurationState = state(appendedDurationClock);
assert.equal(appendedDurationState.websiteClock, true);
assert.equal(appendedDurationState.position, 170);
assert.equal(appendedDurationState.duration, 198);
assert.equal(appendedDurationState.mediaPosition, 203);
assert.equal(appendedDurationState.mediaDuration, 249);
assert.equal(appendedDurationState.canSeek, true);
assert.equal(actionResult(appendedDurationClock, 'seek', 185).code, 'requested');
assert.deepEqual(appendedDurationClock.seekToCalls, [185]);
assert.equal(appendedDurationClock.media.currentTime, 236);

const scaledOnlyClock = makePage({ duration: 378, position: 354, ariaMax: 180, ariaNow: 168 });
assert.equal(state(scaledOnlyClock).websiteClock, false);
assert.equal(state(scaledOnlyClock).canSeek, false);
const scaledOnlySeek = actionResult(scaledOnlyClock, 'seek', 120);
assert.equal(scaledOnlySeek.dispatched, false);
assert.deepEqual(scaledOnlyClock.seekToCalls, []);
assert.equal(scaledOnlyClock.media.currentTime, 354);

for (const options of [
  { duplicateTimeInfo: true },
  { hiddenTimeInfo: true },
  { ariaMax: 190 },
]) {
  const unusableSiteClock = makePage({ duration: 378, position: 354, timeInfo: true,
    websitePosition: 156, websiteDuration: 180, ...options });
  const unusableState = state(unusableSiteClock);
  assert.equal(unusableState.websiteClock, false);
  assert.equal(unusableState.duration, 378);
  assert.equal(unusableState.canSeek, false);
  assert.equal(unusableState.clockMismatch, true);
  const refused = actionResult(unusableSiteClock, 'seek', 120);
  assert.equal(refused.dispatched, false);
  assert.deepEqual(unusableSiteClock.seekToCalls, []);
}

const absentOffsetClock = makePage({ duration: 378, position: 354, websitePosition: 156,
  websiteDuration: 180, ariaMax: 180, ariaNow: 156 });
assert.equal(state(absentOffsetClock).canSeek, false);
assert.equal(actionResult(absentOffsetClock, 'seek', 120).dispatched, false);
assert.deepEqual(absentOffsetClock.seekToCalls, []);

const overWebsiteDuration = makePage({ duration: 378, position: 354, timeInfo: true,
  websitePosition: 156, websiteDuration: 180, ariaMax: 180, ariaNow: 156 });
const refusedOverDuration = actionResult(overWebsiteDuration, 'seek', 181);
assert.equal(refusedOverDuration.code, 'invalid-value');
assert.equal(refusedOverDuration.dispatched, false);
assert.equal(overWebsiteDuration.seekSlider.events.length, 0);
const belowSliderMinimum = makePage({ duration: 378, position: 156, timeInfo: true,
  websitePosition: 156, websiteDuration: 180, ariaMin: 2, ariaMax: 180, ariaNow: 156 });
const refusedBelowMinimum = actionResult(belowSliderMinimum, 'seek', 1);
assert.equal(refusedBelowMinimum.code, 'invalid-value');
assert.equal(refusedBelowMinimum.dispatched, false);
assert.equal(belowSliderMinimum.seekSlider.events.length, 0);
const unwritableSlider = makePage({ sliderValueWritable: false });
const refusedUnwritable = actionResult(unwritableSlider, 'seek', 30);
assert.equal(refusedUnwritable.code, 'invalid-value');
assert.equal(refusedUnwritable.dispatched, false);
assert.equal(unwritableSlider.seekSlider.events.length, 0);
assert.deepEqual(unwritableSlider.seekToCalls, []);
const disabledSeekSlider = makePage({ progressDisabled: true });
assert.equal(actionResult(disabledSeekSlider, 'seek', 30).code, 'disabled-control');
assert.deepEqual(disabledSeekSlider.seekToCalls, []);
const siteBlockedSeek = makePage({ allowSeeking: false });
const siteBlockedResult = actionResult(siteBlockedSeek, 'seek', 30);
assert.equal(siteBlockedResult.code, 'requested');
assert.equal(siteBlockedResult.dispatched, true);
assert.equal(siteBlockedSeek.media.currentTime, 10);
assert.doesNotMatch(script, /\.volume\b/);
assert.doesNotMatch(script, /\.muted\b/);
assert.deepEqual(script.match(/\b\w+\.value\s*=(?!=)/g), ['slider.value =']);
assert.doesNotMatch(script, /\.currentTime\s*=(?!=)/);
assert.doesNotMatch(script, /seekable/);
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
  assert.equal(skewedTrackState.clockMismatch, true);
  assert.equal(skewedTrackState.canLike, true);
  transitionPage.seekSlider.setAttribute('aria-valuemax', String(duration));
  transitionPage.seekSlider.setAttribute('aria-valuenow', String(position));
  const settledTrackState = state(transitionPage);
  assert.equal(settledTrackState.code, 'state');
  assert.equal(settledTrackState.title, `Synthetic track ${index}`);
  assert.equal(settledTrackState.canSeek, true);
  assert.equal(settledTrackState.clockMismatch, false);
}
const likePage = makePage();
assert.equal(action(likePage, 'like'), 'requested');
assert.equal(likePage.document.clicks, 1);
assert.equal(action(likePage, 'like'), 'requested');
assert.equal(likePage.document.clicks, 2);

console.log('PASS: bounded public transport readiness, website-slider seek route, transient seek-clock recovery, unsupported Compact audio commands, and single-click actions');
