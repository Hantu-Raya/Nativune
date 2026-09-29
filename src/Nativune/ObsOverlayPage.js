'use strict';
// Nativune OBS overlay (plan §4.5, design §2.9). Only opacity and transform animate; no rAF loop.

const W = 400, H = 56, BLUR = 14;
const FADE_MS = 500, RISE_PX = 12, DIM = 0.7;
const CONNECTING_HIDE_MS = 5000, CLOSED_RETRY_MS = 30000;

// Artwork comes only from this server's own /art/<key> route; anything else shows no art.
const acceptArtwork = url => typeof url === 'string' && /^\/art\/[0-9a-f]{16}$/.test(url) ? url : null;

const state = {
  visible: true, connection: 'closed', shown: false, state: 'none',
  id: null, title: null, artist: null,
  artSeq: 0, artLoadedSeq: 0, artFailed: false,
  receivedAt: null, projectedPosition: null, hidePaused: true
};

const pill = document.getElementById('pill');
const clip = document.getElementById('clip');
const colour = document.getElementById('colour');
const grey = document.getElementById('grey');
const titleEl = document.getElementById('title');
const artistEl = document.getElementById('artist');

let msg = null;          // last applied metadata-bearing message
let artUrl = null;       // accepted artwork URL currently loaded or loading
let source = null;       // the one EventSource
let connGen = 0;         // connection generation; timers check it
let lossTimer = 0, retryTimer = 0;
let viewAnim = null;
let fillTimer = 0;       // the one stepped-fill setTimeout chain (no rAF, no fill animation)
let fillPx = -1;         // last written fill boundary in whole pixels of the 400 px pill
let viewOpacity = 0;     // target opacity of the pill

// ---- view (opacity/transform only) ----

function setView(opacity) {
  if (opacity === viewOpacity) return;
  const from = viewAnim ? getComputedStyle(pill).opacity : String(viewOpacity);
  const rising = viewOpacity === 0;
  if (viewAnim) viewAnim.cancel();
  viewOpacity = opacity;
  // Show: fade plus 12 px rise. Hide or dim: fade only, position unchanged.
  const keyframes = rising
    ? [{ opacity: from, transform: `translateY(${RISE_PX}px)` }, { opacity: String(opacity), transform: 'translateY(0px)' }]
    : [{ opacity: from }, { opacity: String(opacity) }];
  pill.style.opacity = String(opacity);
  if (rising) pill.style.transform = 'translateY(0px)';
  const anim = pill.animate(keyframes, { duration: FADE_MS, easing: 'ease-out' });
  viewAnim = anim;
  anim.onfinish = () => {
    if (viewAnim !== anim) return;
    viewAnim = null;
    if (viewOpacity === 0) pill.style.transform = `translateY(${RISE_PX}px)`;
  };
  state.shown = opacity > 0;
}

function hide() {
  setView(0);
  // Freeze the fill where it is so the fading pill does not jump; no motion while hidden.
  stopFill();
}

// ---- fill (clip box at translateX(p%), grey canvas counter-translated) ----

// The fill moves in discrete whole-pixel steps, at most one write per second, so CEF only
// composites a new frame when the visible boundary actually moves (G3 CPU budget).
// will-change is deliberately not added: the clip sits inside the rounded, overflow-hidden,
// shadowed pill, so each step re-rasters the same small area either way; per-second steps
// are what removes the per-frame cost.
function stopFill() {
  clearTimeout(fillTimer); fillTimer = 0;
}

function writeFill(px) {
  if (px === fillPx) return;
  fillPx = px;
  clip.style.transform = `translateX(${px}px)`;
  grey.style.transform = `translateX(${-px}px)`;
}

function toPx(p) { return Math.min(W, Math.max(0, Math.round(p / 100 * W))); }

function setFill(p) {
  stopFill();
  writeFill(toPx(p));
}

function stepFill() {
  fillTimer = 0;
  const s = projected();
  if (s == null || !msg || msg.duration == null) { writeFill(W); return; }
  state.projectedPosition = s;
  const px = toPx(s / msg.duration * 100);
  writeFill(px);
  if (px >= W) return;
  // Next rounded-pixel boundary, or 1 s, whichever is later.
  const nextS = (px + 0.5) / W * msg.duration;
  const delay = Math.max(1000, (nextS - s) / msg.rate * 1000);
  fillTimer = setTimeout(stepFill, Math.ceil(delay));
}

function runFill() {
  stopFill();
  stepFill();
}

// ---- projection (plan §4.2), seconds ----

function projected(now = performance.now()) {
  if (!msg || state.state === 'none' || state.state === 'ad') return null;
  if (msg.state !== 'playing' || !msg.clock || msg.duration == null) return msg.position;
  const s = msg.position + (msg.ageMs / 1000 + (now - state.receivedAt) / 1000) * msg.rate;
  return Math.min(Math.max(s, 0), msg.duration);
}

// ---- artwork: blur once per track into two canvases ----

function drawArt(img) {
  const scale = Math.max((W + 4 * BLUR) / img.naturalWidth, (H + 4 * BLUR) / img.naturalHeight);
  const dw = img.naturalWidth * scale, dh = img.naturalHeight * scale;
  const dx = (W - dw) / 2, dy = (H - dh) / 2;
  const c = colour.getContext('2d');
  c.clearRect(0, 0, W, H);
  c.filter = `blur(${BLUR}px) saturate(1.3)`;
  c.drawImage(img, dx, dy, dw, dh);
  const g = grey.getContext('2d');
  g.clearRect(0, 0, W, H);
  g.filter = `blur(${BLUR}px) grayscale(.75)`;
  g.globalAlpha = 0.5;
  g.drawImage(img, dx, dy, dw, dh);
}

function clearArt() {
  colour.getContext('2d').clearRect(0, 0, W, H);
  grey.getContext('2d').clearRect(0, 0, W, H);
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
  const img = new Image();
  img.referrerPolicy = 'no-referrer';
  img.decoding = 'async';
  img.onload = () => {
    if (seq !== state.artSeq) return;
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

// ---- messages ----

function apply(m) {
  stopFill();
  state.receivedAt = performance.now();
  state.state = m.state;
  if (m.state === 'none' || m.state === 'ad') {
    state.projectedPosition = null;
    hide();
    return;
  }
  const hidePaused = m.hidePaused !== false;
  state.hidePaused = hidePaused;
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
  state.projectedPosition = projected(state.receivedAt);

  if (m.state === 'ended' || (m.state === 'paused' && hidePaused)) { hide(); return; }
  if (m.state === 'paused') {
    setFill(duration == null ? 100 : msg.position / duration * 100);
    setView(DIM);
    return;
  }
  if (m.state !== 'playing') { hide(); return; }
  if (msg.clock && duration != null) {
    runFill();
  } else {
    setFill(100);
  }
  setView(1);
}

function onMessage(e) {
  let m;
  try { m = JSON.parse(e.data); } catch { return; }
  if (!m || m.v !== 1 || typeof m.state !== 'string') return;
  apply(m);
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
  const es = new EventSource('/events');
  source = es;
  state.connection = 'connecting';
  es.onopen = () => {
    if (gen !== connGen) return;
    clearTimeout(lossTimer); lossTimer = 0;
    state.connection = 'open';
  };
  es.onmessage = e => { if (gen === connGen) onMessage(e); };
  es.onerror = () => {
    if (gen !== connGen) return;
    if (es.readyState === EventSource.CLOSED) {
      clearTimers();
      state.connection = 'closed';
      source = null;
      hide();
      retryTimer = setTimeout(() => { if (gen === connGen && state.visible) connect(); }, CLOSED_RETRY_MS);
    } else {
      state.connection = 'connecting';
      if (!lossTimer) {
        lossTimer = setTimeout(() => {
          lossTimer = 0;
          if (gen === connGen && es.readyState !== EventSource.OPEN) hide();
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
  else { disconnect(); hide(); }
}

if (window.obsstudio) window.obsstudio.onVisibilityChange = v => setVisible(v);
window.addEventListener('obsSourceVisibleChanged', e => setVisible(e.detail ? e.detail.visible : true));

setFill(100);
connect();
