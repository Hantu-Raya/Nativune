
// ---- test hooks (hook builds only; appended to ObsOverlayPage.js, same scope) ----

const acceptFixtureArt = url => {
  try {
    const u = new URL(url);
    if (u.protocol !== 'http:' || u.host !== 'localhost:47813' || u.username || u.password || u.hash) return null;
    if (!/^\/fixture-art\/[abc]\.png$/.test(u.pathname)) return null;
    if (u.search !== '' && !/^\?delayMs=[0-9]{1,4}$/.test(u.search)) return null;
    return u.href;
  } catch { return null; }
};
{
  const base = acceptArtwork;
  acceptArtwork = url => base(url) ?? acceptFixtureArt(url);
}

Object.defineProperty(window, '__state', {
  get: () => ({
    visible: state.visible, connection: state.connection, shown: state.shown, state: state.state,
    id: state.id, title: state.title, artist: state.artist,
    artSeq: state.artSeq, artLoadedSeq: state.artLoadedSeq, artFailed: state.artFailed,
    receivedAt: state.receivedAt, projectedPosition: state.receivedAt == null ? null : projected(), hidePaused: state.hidePaused
  })
});
