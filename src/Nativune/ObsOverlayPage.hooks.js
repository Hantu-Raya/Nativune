
// ---- test hooks (hook builds only; appended to ObsOverlayPage.js, same scope) ----

// Everything here is read-only diagnostics of the page's own state: the last applied look and what it resolved to
// (theme, box and source sizes, the box-mismatch flag against the server's numbers, normalised options, accent,
// font availability), the stepped-fill timer id (0 = no timer) and the raster/scheduler work counters.
Object.defineProperty(window, '__state', {
  get: () => ({
    visible: state.visible, connection: state.connection, shown: state.shown, state: state.state,
    id: state.id, title: state.title, artist: state.artist,
    artSeq: state.artSeq, artLoadedSeq: state.artLoadedSeq, artFailed: state.artFailed,
    receivedAt: state.receivedAt, projectedPosition: state.receivedAt == null ? null : projected(), hidePaused: state.hidePaused,
    look: state.look, lookEpoch: state.lookEpoch, lookSeq: state.lookSeq, lookReceivedAt: state.lookReceivedAt,
    theme: state.theme, box: state.box, source: state.source, boxMismatch: state.boxMismatch, options: state.options,
    accent: state.accent, fontAvailable: state.fontAvailable, fillTimer, fillPx, barWidth: fillWidth(), rasterKey,
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
