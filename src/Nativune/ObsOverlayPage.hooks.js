
// ---- test hooks (hook builds only; appended to ObsOverlayPage.js, same scope) ----

// Wrap the existing mutable function bindings in this appended hook scope only. The originals still own
// all validation, state updates, timer deadlines and callback scheduling; production loads none of this.
const cadenceLog = [];
let cadenceLogSequence = 0;
let cadenceWakeReason = 'timer';
let cadenceHasRun = false;
let cadenceHasData = false, cadenceHasLook = false;
function recordCadence(kind, reason, details = {}) {
  const pageNow = performance.now();
  cadenceLog.push(Object.assign({
    sequence: ++cadenceLogSequence, kind, pageNow, tickEpoch, projection: projected(pageNow), reason
  }, details));
  if (cadenceLog.length > 256) cadenceLog.shift();
}
const cadenceApply = apply;
apply = m => {
  recordCadence('data', cadenceHasData ? 'reanchor' : 'initial', {
    dataState: m.state, dataPosition: m.position ?? null, dataRate: m.rate ?? null, dataAgeMs: m.ageMs ?? null
  });
  cadenceHasData = true;
  return cadenceApply(m);
};
const cadenceApplyLook = applyLook;
applyLook = (look, at) => {
  recordCadence('look', cadenceHasLook ? 'reanchor' : 'initial', { lookEpoch: look.epoch, lookSeq: look.seq });
  cadenceHasLook = true;
  return cadenceApplyLook(look, at);
};
const cadenceStepFill = stepFill;
stepFill = () => {
  recordCadence('stepFill', cadenceWakeReason);
  return cadenceStepFill();
};
const cadenceRunFill = runFill;
runFill = () => {
  const previousReason = cadenceWakeReason;
  cadenceWakeReason = cadenceHasRun ? 'reanchor' : 'initial';
  cadenceHasRun = true;
  try { return cadenceRunFill(); }
  finally { cadenceWakeReason = previousReason; }
};

// Owned-preview calibration only: no timer or retained allocation exists until the bench explicitly starts it.
let designerCalibrationTimer = 0;
let designerCalibrationBuffers = [];
let designerCalibrationState = { active: false, cpuPp: 0, memMiB: 0, startedAtUtc: null, retainedBytes: 0 };
function stopDesignerCalibrationLoad() {
  clearTimeout(designerCalibrationTimer);
  designerCalibrationTimer = 0;
  designerCalibrationBuffers = [];
  designerCalibrationState = { active: false, cpuPp: 0, memMiB: 0, startedAtUtc: null, retainedBytes: 0 };
  return Object.assign({}, designerCalibrationState);
}
window.__designerCalibrationLoad = request => {
  if (!boot.preview) throw new Error('Calibration requires the designer preview');
  if (!request || typeof request !== 'object' || Array.isArray(request)) throw new Error('Invalid calibration request');
  if (request.off === true) return stopDesignerCalibrationLoad();
  const { cpuPp, memMiB } = request;
  if (!Number.isFinite(cpuPp) || cpuPp < 0 || cpuPp > 100 ||
      !Number.isFinite(memMiB) || memMiB < 0 || memMiB > 1024) throw new Error('Invalid calibration load');
  stopDesignerCalibrationLoad();
  const retainedBytes = Math.ceil(memMiB * 1024 * 1024);
  try {
    for (let remaining = retainedBytes; remaining > 0;) {
      const buffer = new ArrayBuffer(Math.min(remaining, 16 * 1024 * 1024));
      const pages = new Uint8Array(buffer);
      for (let offset = 0; offset < pages.length; offset += 4096) pages[offset] = 1;
      designerCalibrationBuffers.push(buffer);
      remaining -= buffer.byteLength;
    }
    designerCalibrationState = { active: true, cpuPp, memMiB, startedAtUtc: new Date().toISOString(), retainedBytes };
    if (cpuPp > 0) {
      const epoch = performance.now();
      let next = epoch;
      const step = () => {
        const end = performance.now() + cpuPp; // cpuPp / 100 × the fixed 100 ms period.
        while (performance.now() < end) { /* Deliberate hook-only CPU load. */ }
        next += 100;
        const now = performance.now();
        if (next <= now) next = epoch + (Math.floor((now - epoch) / 100) + 1) * 100;
        designerCalibrationTimer = setTimeout(step, Math.max(1, Math.ceil(next - now)));
      };
      designerCalibrationTimer = setTimeout(step, 0);
    }
    return Object.assign({}, designerCalibrationState);
  } catch (error) {
    stopDesignerCalibrationLoad();
    throw error;
  }
};
window.addEventListener('pagehide', stopDesignerCalibrationLoad);
window.addEventListener('unload', stopDesignerCalibrationLoad);

// Everything here is read-only diagnostics of the page's own state: the last applied look and what it resolved to
// (theme, box and source sizes, the box-mismatch flag against the server's numbers, normalised options, accent,
// font availability), the stepped-fill timer id (0 = no timer) and the raster/scheduler work counters.
Object.defineProperty(window, '__state', {
  get: () => ({
    pageNow: performance.now(), tickEpoch, cadenceLogSequence, cadenceLog: cadenceLog.map(entry => Object.assign({}, entry)),
    visible: state.visible, connection: state.connection, shown: state.shown, state: state.state,
    id: state.id, title: state.title, artist: state.artist,
    artSeq: state.artSeq, artLoadedSeq: state.artLoadedSeq, artFailed: state.artFailed,
    receivedAt: state.receivedAt, projectedPosition: state.receivedAt == null ? null : projected(), hidePaused: state.hidePaused,
    look: state.look, lookEpoch: state.lookEpoch, lookSeq: state.lookSeq, lookReceivedAt: state.lookReceivedAt,
    theme: state.theme, box: state.box, source: state.source, boxMismatch: state.boxMismatch, options: state.options, fx: state.fx,
    accent: state.accent, fontAvailable: state.fontAvailable, fillTimer, fillPx, barWidth: fillWidth(), rasterKey,
    runningAnimations: document.getAnimations().filter(animation => animation.playState === 'running').length,
    raster: { colour: { w: colour.width, h: colour.height }, grey: { w: grey.width, h: grey.height },
      cover: artImg ? { w: artImg.naturalWidth, h: artImg.naturalHeight } : null },
    counters: Object.assign({}, counters)
  })
});

// Calibration renderers and their selector are present only in hook builds.
counters.mutantMutations = 0;
if (obsMutant === 'bar-transition') barfill.style.transition = 'transform 1s linear';
if (obsMutant === 'pill-raf') {
  let mutantX = 0;
  const mutantFrame = () => {
    grey.style.transform = `translateX(${++mutantX % 40}px)`;
    counters.mutantMutations++;
    requestAnimationFrame(mutantFrame);
  };
  requestAnimationFrame(mutantFrame);
}
if (obsMutant === 'ceiling-low' || obsMutant === 'ceiling-high') {
  // Isolate the boundary oracle from production progress/label work, including later SSE re-anchors.
  stopFill();
  runFill = stopFill;
  writeFill = () => {};
  pill.style.willChange = 'opacity';
  const period = 1000 / (obsMutant === 'ceiling-low' ? 1.2 : 1.4);
  const epoch = performance.now();
  let next = epoch + period;
  const mutantStep = () => {
    const now = performance.now();
    if (now >= next) {
      if (state.shown) {
        pill.style.opacity = ++counters.mutantMutations % 2 ? '0.8' : '1';
      }
      // Re-anchor to absolute deadlines; skip missed slots rather than batching invisible catch-up writes.
      next = epoch + (Math.floor((now - epoch) / period) + 1) * period;
    }
    setTimeout(mutantStep, Math.max(1, Math.ceil(next - performance.now())));
  };
  setTimeout(mutantStep, Math.ceil(period));
}
