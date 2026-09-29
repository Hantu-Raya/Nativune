
// ---- test hooks (hook builds only; appended to ObsOverlayPage.js, same scope) ----

Object.defineProperty(window, '__state', {
  get: () => ({
    visible: state.visible, connection: state.connection, shown: state.shown, state: state.state,
    id: state.id, title: state.title, artist: state.artist,
    artSeq: state.artSeq, artLoadedSeq: state.artLoadedSeq, artFailed: state.artFailed,
    receivedAt: state.receivedAt, projectedPosition: state.receivedAt == null ? null : projected(), hidePaused: state.hidePaused
  })
});
