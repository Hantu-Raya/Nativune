
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
    accent: state.accent, fontAvailable: state.fontAvailable, fillTimer, counters: Object.assign({}, counters)
  })
});
