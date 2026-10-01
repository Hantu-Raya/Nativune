'use strict';
// Nativune OBS overlay (plan §4.5, design §2.9). Only opacity and transform animate; no rAF loop.
// Looks (OBS designer plan v5 §2.3, §2.4; the pill is the only theme drawn in this phase): a `look` event carries the
// options, default `data` events carry the song. Every look received is applied in arrival order; epoch and seq are
// diagnostics and never a filter (SSE delivers in order, and a restarted server starts a new epoch at seq 1).

const BLUR = 14;
const FADE_MS = 500, RISE_PX = 12, DIM = 0.7;
const CONNECTING_HIDE_MS = 5000, CLOSED_RETRY_MS = 30000;

// The plain pill: 400 x 56 at (20, 20) inside a 440 x 96 source; height and insets scale with k = scale / 100.
const PILL = { width: 400, height: 56, minWidth: 320, maxWidth: 800, text: '#ffffff', accent: '#8a8a95' };
const THEMES = ['pill', 'matte', 'matte-light', 'standard', 'classic', 'simple', 'album-art', 'card'];
const ALIGNS = ['left', 'center', 'right'];
const ANIMATIONS = ['fade', 'slide-up', 'slide-down', 'slide-left', 'slide-right', 'none'];
// Slide directions: the pill travels RISE_PX from that side while it fades (show) or back to it (hide).
const SLIDES = {
  'slide-up': ['translateY', RISE_PX], 'slide-down': ['translateY', -RISE_PX],
  'slide-left': ['translateX', RISE_PX], 'slide-right': ['translateX', -RISE_PX]
};
const FONT_STACK = '"Segoe UI Variable Text", "Segoe UI", Arial, sans-serif';

// Artwork comes only from this server's own /art/<key> route or its generated /art/sample cover; anything else shows no art.
const acceptArtwork = url => typeof url === 'string' && /^\/art\/(?:[0-9a-f]{16}|sample)$/.test(url) ? url : null;

// GET / carries the look in its raw query (plan §2.1). The stream URL is rebuilt from the validated pieces only, in the
// /events order look, pv, sample; preview=1 is a page-only flag. Anything else opens the plain stream.
const boot = (() => {
  const m = /^(?:\?(?:look=([a-z0-9]{8}|draft)(?:&preview=(1)&pv=([a-z0-9]{8}))?(?:&sample=(playing|paused|noart))?|sample=(playing|paused|noart)))?$/
    .exec(location.search);
  if (!m) return { events: '/events', preview: false };
  const parts = [];
  if (m[1]) parts.push('look=' + m[1]);
  if (m[3]) parts.push('pv=' + m[3]);
  if (m[4] || m[5]) parts.push('sample=' + (m[4] || m[5]));
  return { events: '/events' + (parts.length ? '?' + parts.join('&') : ''), preview: m[2] === '1' };
})();

const state = {
  visible: true, connection: 'closed', shown: false, state: 'none',
  id: null, title: null, artist: null,
  artSeq: 0, artLoadedSeq: 0, artFailed: false,
  receivedAt: null, projectedPosition: null, hidePaused: true,
  // The last applied look and what it resolved to (read by the hook build only).
  look: null, lookEpoch: null, lookSeq: null, lookReceivedAt: null,
  theme: null, box: null, source: null, boxMismatch: null, options: null,
  accent: null, fontAvailable: null, reduceMotion: false
};
// Raster and scheduler work counters (hook build only reads them); quantizerRuns is reserved for the themes' accent sampler.
const counters = { blurDraws: 0, quantizerRuns: 0, coverLoads: 0, lookApplies: 0, fillWrites: 0, timeWrites: 0, ticks: 0 };

const root = document.documentElement;
const pill = document.getElementById('pill');
const clip = document.getElementById('clip');
const colour = document.getElementById('colour');
const grey = document.getElementById('grey');
const titleEl = document.getElementById('title');
const artistEl = document.getElementById('artist');
const elapsedEl = document.getElementById('elapsed');   // null until a theme with a times slot exists
const durationEl = document.getElementById('duration');

let msg = null;          // last applied metadata-bearing message
let opts = null;         // options of the applied look (the defaults until the first look, assigned below)
let geo = null;          // box and source size of the applied look
let artUrl = null;       // accepted artwork URL currently loaded or loading
let artImg = null;       // bitmap currently drawn on the band canvases, kept so a size change can redraw it
let rasterKey = 'pill|400|56';   // layout part of the raster-cache key the band canvases were last sized/drawn for
let source = null;       // the one EventSource
let connGen = 0;         // connection generation; timers check it
let lossTimer = 0, retryTimer = 0;
let awaitingData = true; // set when the view was dropped for a lost connection: a look alone never shows the pill again
let viewAnim = null;     // the running show/hide/dim transition, if any
let viewKind = '';       // its kind: show, hide, dim or undim
let fillTimer = 0;       // the one stepped-fill setTimeout chain (no rAF, no fill animation)
let fillPx = -1;         // last written fill boundary in whole pixels of the pill width
let tickEpoch = 0;       // performance.now() when the wall-clock tick chain (times shown) started
let elapsedText = '';
let viewOpacity = 0;     // target opacity of the pill

// ---- look validation (plan §4.3, §4.4): every field is re-checked; anything invalid falls back to its default ----

const isObject = v => v !== null && typeof v === 'object' && !Array.isArray(v);
const oneOf = (v, list, dflt) => typeof v === 'string' && list.includes(v) ? v : dflt;
const flag = (v, dflt) => typeof v === 'boolean' ? v : dflt;
const hexColour = (v, dflt) => typeof v === 'string' && /^#[0-9a-fA-F]{6}$/.test(v) ? v.toLowerCase() : dflt;
const fontName = v => typeof v === 'string' && v.trim().length > 0 && v.length <= 64 && !/[\u0000-\u001f\u007f-\u009f]/.test(v) ? v : null;
// A finite number inside [min, max] snapped to the nearest step from min; anything else is the default.
const snapped = (v, min, max, step, dflt) => typeof v === 'number' && Number.isFinite(v) && v >= min && v <= max
  ? Math.min(max, min + Math.round((v - min) / step) * step) : dflt;

function normalizeOptions(raw) {
  const r = isObject(raw) ? raw : {};
  // Order matters (plan §3.2): scale, then the width range that depends on it, then the width.
  const scale = snapped(r.scale, 50, 200, 5, 100);
  const minWidth = Math.ceil(PILL.minWidth * Math.max(scale, 100) / 1000) * 10;
  const width = snapped(r.width, minWidth, PILL.maxWidth, 10, Math.min(PILL.maxWidth, Math.max(minWidth, PILL.width)));
  return {
    theme: oneOf(r.theme, THEMES, 'pill'), font: fontName(r.font), scale, width,
    align: oneOf(r.align, ALIGNS, 'center'), colours: oneOf(r.colours, ['auto', 'custom'], 'auto'),
    text: hexColour(r.text, PILL.text), background: hexColour(r.background, '#202020'),
    backgroundOpacity: snapped(r.backgroundOpacity, 0, 100, 1, 100), accent: hexColour(r.accent, PILL.accent),
    textShadow: flag(r.textShadow, true), showArt: flag(r.showArt, true), showArtist: flag(r.showArtist, true),
    showProgress: flag(r.showProgress, true), showTimes: flag(r.showTimes, true),
    paused: oneOf(r.paused, ['hide', 'dim'], 'hide'),
    showAnimation: oneOf(r.showAnimation, ANIMATIONS, 'slide-up'), hideAnimation: oneOf(r.hideAnimation, ANIMATIONS, 'fade')
  };
}

const sizeOf = v => isObject(v) && Number.isFinite(v.w) && Number.isFinite(v.h) ? { w: v.w, h: v.h } : null;
const sameSize = (a, b) => a !== null && Math.abs(a.w - b.w) < 1e-6 && Math.abs(a.h - b.h) < 1e-6;

function backdropOf(v) {
  if (isObject(v)) {
    const b = v.backdrop;
    if (b === 'checker' || b === 'dark' || b === 'light') return { backdrop: b };
    if (typeof b === 'string' && /^#[0-9a-fA-F]{6}$/.test(b)) return { backdrop: b.toLowerCase() };
    return { backdrop: 'checker' };
  }
  return null;
}

function normalizeLook(m) {
  if (!isObject(m) || m.v !== 1) return null;
  const options = normalizeOptions(m.options);
  return {
    v: 1,
    epoch: typeof m.epoch === 'string' && /^[0-9A-Za-z_-]{1,32}$/.test(m.epoch) ? m.epoch : null,
    seq: Number.isSafeInteger(m.seq) && m.seq >= 0 ? m.seq : null,
    id: typeof m.id === 'string' && /^(?:[a-z0-9]{8}|draft)$/.test(m.id) ? m.id : null,
    missing: m.missing === true,
    kind: m.kind === 'sample' ? 'sample' : 'real',
    theme: options.theme,
    box: sizeOf(m.box), source: sizeOf(m.source),
    reduceMotion: m.reduceMotion === true,
    fontAvailable: m.fontAvailable === true,
    hidePaused: typeof m.hidePaused === 'boolean' ? m.hidePaused : null,
    options,
    preview: backdropOf(m.preview)
  };
}

// ---- geometry (plan §3.2): logical px at k = 1, scaled by k; the source is the box plus 20 px each side, rounded up to even ----

function geometry(o) {
  const k = o.scale / 100;
  const box = { w: o.width, h: PILL.height * k };
  // Only the pill is drawn in this phase, so every theme id resolves to it.
  return { theme: 'pill', k, box, source: { w: 2 * Math.ceil((box.w + 40) / 2), h: 2 * Math.ceil((box.h + 40) / 2) } };
}

opts = normalizeOptions(null);
geo = geometry(opts);

// ---- style writes: fixed names only, values built from the validated primitives above ----

const VARS = ['--k', '--w', '--sw', '--sh', '--font', '--align', '--fg', '--bg', '--bg-a', '--accent', '--shadow', '--backdrop'];
const ATTRS = ['data-theme', 'data-colours', 'data-show-art', 'data-show-artist', 'data-show-progress', 'data-show-times',
  'data-paused', 'data-anim-show', 'data-anim-hide', 'data-preview', 'data-backdrop'];
const written = new Map();

function setVar(name, value) {
  if (!VARS.includes(name) || written.get(name) === value) return;
  written.set(name, value);
  root.style.setProperty(name, value);
}

function setAttr(name, value) {
  if (!ATTRS.includes(name) || written.get(name) === value) return;
  written.set(name, value);
  root.setAttribute(name, value);
}

// Quoted family (escaping backslash and quote, so it stays one string token) ahead of the fixed stack, only when the
// server confirmed the family is installed.
const fontValue = (family, available) => available && family !== null
  ? '"' + family.replace(/[\\"]/g, '\\$&') + '", ' + FONT_STACK : FONT_STACK;

// Text shadow (plan §3.3): a dark halo under light text, a light one under dark text (higher contrast against the text colour).
function luminance(hex) {
  const c = [1, 3, 5].map(i => {
    const v = parseInt(hex.slice(i, i + 2), 16) / 255;
    return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4;
  });
  return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
}
const shadowFor = (on, fg) => !on ? 'none'
  : luminance(fg) > 0.179 ? '0 1px 3px rgba(0, 0, 0, .8)' : '0 1px 2px rgba(255, 255, 255, .6)';

// ---- view (opacity/transform only) ----

// Effective motion (plan §2.4.2): instant when ReduceMotion is on or the chosen animation is none, show and hide
// judged separately. Dim (paused dim) is governed by the hide choice, the return from dim by the show choice.
const choiceFor = kind => kind === 'show' || kind === 'undim' ? opts.showAnimation : opts.hideAnimation;
const instantFor = kind => state.reduceMotion || choiceFor(kind) === 'none';

function endTransition() {
  viewAnim.cancel();
  viewAnim = null;
  viewKind = '';
}

function setView(opacity) {
  if (opacity === viewOpacity) return;
  const kind = opacity === 0 ? 'hide' : viewOpacity === 0 ? 'show' : opacity < viewOpacity ? 'dim' : 'undim';
  const from = viewAnim ? getComputedStyle(pill).opacity : String(viewOpacity);
  if (viewAnim) endTransition();
  viewOpacity = opacity;
  state.shown = opacity > 0;
  // The final state is applied at once; the animation only paints the way there, so cancelling it lands on the end.
  pill.style.opacity = String(opacity);
  if (kind === 'show') pill.style.transform = 'translateY(0px)';
  if (instantFor(kind)) return;
  const slide = kind === 'show' || kind === 'hide' ? SLIDES[choiceFor(kind)] : undefined;
  let keyframes;
  if (slide) {
    const away = `${slide[0]}(${slide[1]}px)`, rest = `${slide[0]}(0px)`;
    keyframes = kind === 'show'
      ? [{ opacity: from, transform: away }, { opacity: String(opacity), transform: rest }]
      : [{ opacity: from, transform: rest }, { opacity: String(opacity), transform: away }];
  } else {
    keyframes = [{ opacity: from }, { opacity: String(opacity) }];
  }
  const anim = pill.animate(keyframes, { duration: FADE_MS, easing: 'ease-out' });
  viewAnim = anim;
  viewKind = kind;
  anim.onfinish = () => {
    if (viewAnim !== anim) return;
    viewAnim = null;
    viewKind = '';
  };
}

function hide() {
  setView(0);
  // Freeze the fill where it is so the fading pill does not jump; no motion while hidden.
  stopFill();
}

// The view was dropped because the connection is gone or the source is hidden; only a song message shows it again.
function lose() {
  awaitingData = true;
  hide();
}

// ---- fill (clip box at translateX(p%), grey canvas counter-translated) ----

// The fill moves in discrete whole-pixel steps so CEF only composites a new frame when the visible boundary actually
// moves (G3 CPU budget). will-change is deliberately not added: the clip sits inside the rounded, overflow-hidden,
// shadowed pill, so each step re-rasters the same small area either way.
// Scheduler (plan §2.4.1), per wake, never queued, never caught up:
//  - times hidden: today's rule made rate-aware, delay = max(1000, time to the next whole pixel / rate); the wake
//    writes the fill, and a wake that finds the pixel unchanged is not a tick;
//  - times shown: one wall-clock tick per second at any rate; the same task writes the label and the fill;
//  - paused, hidden, ended, no clock or duration, progress hidden: no timer at all.
function stopFill() {
  clearTimeout(fillTimer); fillTimer = 0;
}

function writeFill(px) {
  if (px === fillPx) return;
  fillPx = px;
  counters.fillWrites++;
  clip.style.transform = `translateX(${px}px)`;
  grey.style.transform = `translateX(${-px}px)`;
}

function toPx(p) { return Math.min(geo.box.w, Math.max(0, Math.round(p / 100 * geo.box.w))); }

function setFill(p) {
  stopFill();
  writeFill(toPx(p));
}

const clockText = s => {
  const whole = Math.floor(s);
  return Math.floor(whole / 60) + ':' + String(whole % 60).padStart(2, '0');
};

function timesShown() {
  return elapsedEl !== null && durationEl !== null && opts.showTimes && opts.showProgress
    && msg !== null && msg.clock && msg.duration != null;
}

function writeTimes(s) {
  const text = clockText(s);
  if (text === elapsedText) return;
  elapsedText = text;
  elapsedEl.textContent = text;
  counters.timeWrites++;
}

function stepFill() {
  fillTimer = 0;
  const s = projected();
  if (s == null || !msg || msg.duration == null || !opts.showProgress) { writeFill(geo.box.w); return; }
  state.projectedPosition = s;
  const px = toPx(s / msg.duration * 100);
  if (timesShown()) {
    counters.ticks++;
    writeTimes(s);
    writeFill(px);
    if (s >= msg.duration) return;
    fillTimer = setTimeout(stepFill, Math.max(1, 1000 - ((performance.now() - tickEpoch) % 1000)));
    return;
  }
  if (px !== fillPx) {
    counters.ticks++;
    writeFill(px);
  }
  if (px >= geo.box.w) return;
  // Next rounded-pixel boundary, or 1 s, whichever is later.
  const nextS = (px + 0.5) / geo.box.w * msg.duration;
  const delay = Math.max(1000, (nextS - s) / msg.rate * 1000);
  fillTimer = setTimeout(stepFill, Math.ceil(delay));
}

function runFill() {
  stopFill();
  tickEpoch = performance.now();
  stepFill();
}

// ---- projection (plan §4.2), seconds ----

function projected(now = performance.now()) {
  if (!msg || state.state === 'none' || state.state === 'ad') return null;
  if (msg.state !== 'playing' || !msg.clock || msg.duration == null) return msg.position;
  const s = msg.position + (msg.ageMs / 1000 + (now - state.receivedAt) / 1000) * msg.rate;
  return Math.min(Math.max(s, 0), msg.duration);
}

// ---- artwork: blur once per raster key into two canvases ----

function drawArt(img) {
  const w = colour.width, h = colour.height;
  const blur = Math.round(BLUR * geo.k * 10) / 10;
  const scale = Math.max((w + 4 * blur) / img.naturalWidth, (h + 4 * blur) / img.naturalHeight);
  const dw = img.naturalWidth * scale, dh = img.naturalHeight * scale;
  const dx = (w - dw) / 2, dy = (h - dh) / 2;
  const c = colour.getContext('2d');
  c.clearRect(0, 0, w, h);
  c.filter = `blur(${blur}px) saturate(1.3)`;
  c.drawImage(img, dx, dy, dw, dh);
  const g = grey.getContext('2d');
  g.clearRect(0, 0, w, h);
  g.filter = `blur(${blur}px) grayscale(.75)`;
  g.globalAlpha = 0.5;
  g.drawImage(img, dx, dy, dw, dh);
}

function clearArt() {
  artImg = null;
  colour.getContext('2d').clearRect(0, 0, colour.width, colour.height);
  grey.getContext('2d').clearRect(0, 0, grey.width, grey.height);
}

// A look that keeps the raster key unchanged causes no raster work; a new size resizes the canvases and redraws the
// bitmap that is on them. blurDraws counts a pass when it is scheduled (an art load or a redraw), one per key change.
function syncRaster(g) {
  const w = Math.ceil(g.box.w), h = Math.ceil(g.box.h);
  const key = g.theme + '|' + w + '|' + h;
  if (key === rasterKey) return;
  rasterKey = key;
  if (colour.width !== w || colour.height !== h) {
    colour.width = grey.width = w;   // resizing clears the canvases
    colour.height = grey.height = h;
  }
  if (artImg !== null) {
    counters.blurDraws++;
    drawArt(artImg);
  }
}

function loadArt(raw) {
  const url = raw == null ? null : acceptArtwork(raw);
  if (url !== null && url === artUrl && !state.artFailed) return;
  artUrl = url;
  const seq = ++state.artSeq;
  if (url === null) {
    clearArt();
    state.artFailed = true;
    state.artLoadedSeq = seq;
    return;
  }
  counters.coverLoads++;
  counters.blurDraws++;
  const img = new Image();
  img.referrerPolicy = 'no-referrer';
  img.decoding = 'async';
  img.onload = () => {
    if (seq !== state.artSeq) return;
    artImg = img;
    drawArt(img);
    state.artFailed = false;
    state.artLoadedSeq = seq;
  };
  img.onerror = () => {
    if (seq !== state.artSeq) return;
    clearArt();
    state.artFailed = true;
    state.artLoadedSeq = seq;
  };
  img.src = url;
}

// ---- looks ----

function writePreview(look) {
  if (!boot.preview) return;
  document.title = 'Overlay preview \u2014 ' + (look.kind === 'sample' ? 'sample song' : 'current song');
  const backdrop = look.preview ? look.preview.backdrop : 'checker';
  const custom = backdrop.startsWith('#');
  setAttr('data-backdrop', custom ? 'custom' : backdrop);
  if (custom) setVar('--backdrop', backdrop);
}

function applyLook(look, at) {
  const o = look.options;
  const g = geometry(o);
  counters.lookApplies++;
  opts = o;
  geo = g;
  state.look = look; state.lookEpoch = look.epoch; state.lookSeq = look.seq; state.lookReceivedAt = at;
  state.options = o; state.theme = g.theme; state.box = g.box; state.source = g.source;
  state.boxMismatch = !sameSize(look.box, g.box) || !sameSize(look.source, g.source);
  state.fontAvailable = look.fontAvailable;
  state.reduceMotion = look.reduceMotion;
  if (look.hidePaused !== null) state.hidePaused = look.hidePaused;
  const custom = o.colours === 'custom';
  const fg = custom ? o.text : PILL.text;
  state.accent = custom ? o.accent : PILL.accent;

  setAttr('data-theme', g.theme);
  setAttr('data-colours', o.colours);
  setAttr('data-show-art', String(o.showArt));
  setAttr('data-show-artist', String(o.showArtist));
  setAttr('data-show-progress', String(o.showProgress));
  setAttr('data-show-times', String(o.showTimes));
  setAttr('data-paused', o.paused);
  setAttr('data-anim-show', o.showAnimation);
  setAttr('data-anim-hide', o.hideAnimation);
  setVar('--k', String(g.k));
  setVar('--w', g.box.w + 'px');
  setVar('--sw', g.source.w + 'px');
  setVar('--sh', g.source.h + 'px');
  setVar('--font', fontValue(o.font, look.fontAvailable));
  setVar('--align', o.align);
  setVar('--fg', fg);
  setVar('--bg', o.background);
  setVar('--bg-a', String(o.backgroundOpacity / 100));
  setVar('--accent', state.accent);
  setVar('--shadow', shadowFor(o.textShadow, fg));
  syncRaster(g);
  writePreview(look);

  // A push that makes the running transition instant (ReduceMotion on, or its own choice now none) ends it at its
  // final state at once; a push that only changes the other transition's choice leaves it alone (plan §2.4.2).
  if (viewAnim !== null && instantFor(viewKind)) endTransition();
  if (!awaitingData && msg !== null && state.state !== 'none' && state.state !== 'ad') present();
}

// ---- messages ----

// Paused, ended, hidden and playing views of the current message under the current look.
function present() {
  if (state.state === 'ended') { hide(); return; }
  if (state.state === 'paused') {
    // A paused song hides only when its look says hide and the global hide-when-paused switch is on; otherwise it dims.
    if (opts.paused === 'hide' && state.hidePaused) { hide(); return; }
    setFill(!opts.showProgress || msg.duration == null ? 100 : msg.position / msg.duration * 100);
    setView(DIM);
    return;
  }
  if (state.state !== 'playing') { hide(); return; }
  if (opts.showProgress && msg.clock && msg.duration != null) runFill();
  else setFill(100);
  setView(1);
}

function apply(m) {
  stopFill();
  awaitingData = false;
  state.receivedAt = performance.now();
  state.state = m.state;
  if (m.state === 'none' || m.state === 'ad') {
    state.projectedPosition = null;
    hide();
    return;
  }
  state.hidePaused = m.hidePaused !== false;
  const duration = typeof m.duration === 'number' && m.duration > 0 ? m.duration : null;
  const position = Math.max(0, Number(m.position) || 0);
  msg = {
    state: m.state, duration, position: duration == null ? position : Math.min(position, duration),
    rate: typeof m.rate === 'number' && m.rate > 0 ? m.rate : 1,
    clock: m.clock === true, ageMs: Math.max(0, Number(m.ageMs) || 0)
  };
  if (m.id !== state.id || m.title !== state.title || m.artist !== state.artist) {
    state.id = m.id ?? null;
    state.title = typeof m.title === 'string' ? m.title : '';
    state.artist = typeof m.artist === 'string' ? m.artist : null;
    titleEl.textContent = state.title;
    artistEl.textContent = state.artist ?? '';
  }
  loadArt(m.artwork);
  if (durationEl !== null) durationEl.textContent = duration == null ? '' : clockText(duration);
  state.projectedPosition = projected(state.receivedAt);
  present();
}

function onMessage(e) {
  let m;
  try { m = JSON.parse(e.data); } catch { return; }
  if (!m || m.v !== 1 || typeof m.state !== 'string') return;
  apply(m);
}

function onLook(e) {
  const at = performance.now();
  let m;
  try { m = JSON.parse(e.data); } catch { return; }
  const look = normalizeLook(m);
  if (look !== null) applyLook(look, at);
}

// ---- connection state machine (design §2.9) ----

function clearTimers() {
  clearTimeout(lossTimer); lossTimer = 0;
  clearTimeout(retryTimer); retryTimer = 0;
}

function disconnect() {
  connGen++;
  clearTimers();
  if (source) { source.close(); source = null; }
  state.connection = 'closed';
}

function connect() {
  disconnect();
  if (!state.visible) return;
  const gen = connGen;
  const es = new EventSource(boot.events);
  source = es;
  state.connection = 'connecting';
  es.onopen = () => {
    if (gen !== connGen) return;
    clearTimeout(lossTimer); lossTimer = 0;
    state.connection = 'open';
  };
  es.onmessage = e => { if (gen === connGen) onMessage(e); };
  es.addEventListener('look', e => { if (gen === connGen) onLook(e); });
  es.onerror = () => {
    if (gen !== connGen) return;
    if (es.readyState === EventSource.CLOSED) {
      clearTimers();
      state.connection = 'closed';
      source = null;
      lose();
      retryTimer = setTimeout(() => { if (gen === connGen && state.visible) connect(); }, CLOSED_RETRY_MS);
    } else {
      state.connection = 'connecting';
      if (!lossTimer) {
        lossTimer = setTimeout(() => {
          lossTimer = 0;
          if (gen === connGen && es.readyState !== EventSource.OPEN) lose();
        }, CONNECTING_HIDE_MS);
      }
    }
  };
}

function setVisible(v) {
  v = v !== false;
  if (v === state.visible) return;
  state.visible = v;
  if (v) connect();
  else { disconnect(); lose(); }
}

if (window.obsstudio) window.obsstudio.onVisibilityChange = v => setVisible(v);
window.addEventListener('obsSourceVisibleChanged', e => setVisible(e.detail ? e.detail.visible : true));

if (boot.preview) {
  setAttr('data-preview', '1');
  setAttr('data-backdrop', 'checker');
  pill.setAttribute('role', 'region');
  pill.setAttribute('aria-label', 'Overlay preview');
}
setFill(100);
connect();
