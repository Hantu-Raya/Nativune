(() => {
  'use strict';
  // request is supplied by the host before its owned navigation, in a named isolated world.
  if (window !== window.top || location.origin !== 'https://music.youtube.com') return;
  const saved = request.checkpoint, generation = request.generation;
  if (!request.homeGuard && new URL(location.href).searchParams.get('v') !== saved.videoId) return;
  let state = 'Armed', reason = '', media = null, sought = false, stableAt = 0;
  let baseline = null, timer = null, timeout = null;
  let initialPosition = null, completeAt = null, playingAt = null;
  // The public per-track clock ("1:10 / 3:05"), authoritative when media time is a shared timeline.
  const trackClock = () => {
    const infos = document.querySelectorAll('ytmusic-player-bar span.time-info');
    if (infos.length !== 1) return null;
    const m = (infos[0].textContent || '').trim().match(/^(\d+(?::\d{1,2}){1,2})\s*\/\s*(\d+(?::\d{1,2}){1,2})$/);
    if (!m) return null;
    const secs = s => s.split(':').reduce((a, v) => a * 60 + Number(v), 0);
    const position = secs(m[1]), duration = secs(m[2]);
    return Number.isFinite(position) && duration > 0 && position <= duration ? { position, duration } : null;
  };
  let ignoreSeek = false, recoveryAd = false;
  const waitPaused = request.waitPaused;
  const terminal = () => ['Done','Cancelled','Failed'].includes(state);
  const ad = () => !!document.querySelector('ytmusic-player :is(#movie_player,.html5-video-player):is(.ad-showing,.ad-interrupting)');
  const wakeEvents = ['loadedmetadata','durationchange','canplay','seeked','pause','timeupdate'];
  const clean = () => {
    clearTimeout(timer); clearTimeout(timeout); observer.disconnect();
    for(const event of wakeEvents)document.removeEventListener(event,wake,true);
    document.removeEventListener('play',onPlay,true);
    document.removeEventListener('playing',onPlay,true);
    document.removeEventListener('seeking',onSeek,true);
    document.removeEventListener('visibilitychange',onVisibility,true);
    if(state !== 'Failed') {
      document.removeEventListener('click',onClick,true);
      document.removeEventListener('keydown',onKey,true);
      document.removeEventListener('play',onFailedPlay,true);
      document.removeEventListener('keydown',onInput,true);
      document.removeEventListener('pointerdown',onInput,true);
    }
  };
  const stop = (next, why = '') => { state = next; reason = why; clean(); };
  const cancel = () => {
    stop('Cancelled');
    document.removeEventListener('play', onPlay, true);
    document.removeEventListener('seeking', onSeek, true);
    document.removeEventListener('click', onClick, true);
    document.removeEventListener('keydown',onKey,true);
    document.removeEventListener('play',onFailedPlay,true);
    document.removeEventListener('keydown',onInput,true);
    document.removeEventListener('pointerdown',onInput,true);
    return {cancelled:true,generation};
  };
  const identity = () => {
    if (ad() || !media || media.seeking || !Number.isFinite(media.duration) || media.duration <= 0) { baseline = null; return false; }
    const url = new URL(location.href), bars = document.querySelectorAll('ytmusic-player-bar');
    if (url.searchParams.getAll('v').length !== 1 || url.searchParams.get('v') !== saved.videoId || bars.length !== 1) return false;
    const titles = bars[0].querySelectorAll('.title');
    const title = titles.length === 1 ? titles[0].textContent.trim() : '';
    const artist = bars[0].querySelector('.byline')?.textContent.trim() || '';
    if (!title || title.length > 512) return false;
    const links = document.querySelectorAll('ytmusic-player a.ytp-title-link');
    // A present bad/mismatching link vetoes the fallback, including an outgoing title during a track switch.
    if (links.length) {
      if (links.length !== 1 || links[0].textContent.trim() !== title) return false;
      try {
        const link = new URL(links[0].getAttribute('href'), location.origin);
        return link.origin === location.origin && link.pathname === '/watch'
          && link.searchParams.getAll('v').length === 1 && link.searchParams.get('v') === saved.videoId;
      } catch { return false; }
    }
    if (!artist || artist.length > 512) return false;
    const now = performance.now(), p = media.currentTime;
    if (!baseline || baseline.title !== title || baseline.artist !== artist || baseline.duration !== media.duration
      || Math.abs(p - baseline.position - (media.paused ? 0 : (now-baseline.at)/1000*media.playbackRate)) > 1) {
      baseline = { title, artist, duration:media.duration, position:p, at:now }; return false;
    }
    return now - baseline.at >= 2000;
  };
  const seekable = p => {
    for (let i=0;i<media.seekable.length;i++) if(p>=media.seekable.start(i)&&p<=media.seekable.end(i)) return true;
    return false;
  };
  const wake = () => { if(!terminal()){ clearTimeout(timer); timer=setTimeout(step,50); } };
  const armTimeout = () => {
    clearTimeout(timeout);
    // Chromium defers media loading until a hidden page (tray autostart) is first shown; only visible time counts.
    if(document.visibilityState==='hidden')return;
    timeout=setTimeout(()=>{if(!terminal() && state!=='AdPaused' && !(recoveryAd && ad())) stop('Failed','timeout');},10000);
  };
  function onVisibility() {
    if(!terminal() && state!=='AdPaused' && state!=='AwaitMusic') armTimeout();
    wake();
  }
  function onPlay(event) {
    if (!(event.target instanceof HTMLMediaElement)) return;
    media = event.target;
    if (terminal()) return;
    if (recoveryAd && ad()) { wake(); return; }
    if (ad()) {
      initialPosition=null;playingAt=null;
      if(waitPaused){media.pause();state='AdPaused';}else state='AwaitMusic';
      clearTimeout(timeout);wake();return;
    }
    if(!waitPaused && event.type==='playing' && initialPosition===null){initialPosition=media.currentTime;playingAt=performance.now();}
    // Only an explicit Play control cancels. Site autoplay or metadata retries must not release the safety guard.
    if (waitPaused && !terminal()) media.pause();
    wake();
  }
  function onSeek(event) {
    if(event.target === media && !ignoreSeek && sought && !terminal()) cancel();
    wake();
  }
  function onClick(event) {
    if (!event.isTrusted || terminal() && state !== 'Failed') return;
    const anchor=event.target.closest?.('a[href]');
    if(anchor) {
      try { if(new URL(anchor.href).href.split('#')[0]!==location.href.split('#')[0]){cancel();return;} } catch { }
    }
    const button=event.target.closest?.('button,ytmusic-play-button-renderer,[role="button"],tp-yt-paper-slider');
    const name=button?.getAttribute('aria-label') || '';
    if (/^(Next|Previous|Seek)/i.test(name) || button?.id==='progress-bar') { cancel(); return; }
    if (/^Play(?:$|\b)/i.test(name)) {
      if(state==='AdPaused') recoverAd(); else cancel();
    }
  }
  function onKey(event) {
    const slider=event.target.closest?.('tp-yt-paper-slider,[role="slider"]');
    if(event.isTrusted && slider && (slider.id==='progress-bar' || /^seek\b/i.test(slider.getAttribute('aria-label')||''))
      && ['ArrowLeft','ArrowRight','Home','End','PageUp','PageDown'].includes(event.key)) cancel();
  }
  // After a failed Wait paused restore the view stays muted. A play right after trusted in-page input (a key
  // shortcut or click) is the user's choice: release the guard. Anything else, such as a late site autoplay,
  // stays paused. userActivation is not used: the host's ExecuteScript reads can grant it.
  let lastInputAt = -1e9;
  function onInput(event) { if(event.isTrusted) lastInputAt = performance.now(); }
  function onFailedPlay(event) {
    if(state!=='Failed' || !waitPaused || !(event.target instanceof HTMLMediaElement)) return;
    if(performance.now()-lastInputAt < 1500){ cancel(); return; }
    event.target.pause();
  }
  function recoverAd() {
    recoveryAd=true; state='AwaitMusic'; reason=''; clearTimeout(timeout); wake();
  }
  function step() {
    if(terminal())return;
    const all=document.querySelectorAll('audio,video');
    if(all.length===1 && all[0] instanceof HTMLMediaElement)media=all[0];
    if(request.homeGuard) {
      if(!media || media.readyState<1){
        // Home often has no player at all (fresh profile): 3 s after the document completes, nothing can play.
        if(document.readyState==='complete'){ completeAt ??= performance.now(); if(performance.now()-completeAt>=3000){stop('Done','invalid');return;} }
        state='AwaitMedia';wake();return;
      }
      media.pause();state='Verify';
      if(!stableAt)stableAt=performance.now();
      if(performance.now()-stableAt<500){wake();return;}
      stop('Done','invalid');return;
    }
    const error = Array.from(document.querySelectorAll('yt-playability-error-supported-renderers,ytmusic-player #error-screen'))
      .some(e=>e.getClientRects().length>0 && getComputedStyle(e).visibility!=='hidden'
        && /unavailable|not available|error occurred/i.test(e.textContent || ''));
    if(error) {
      if(waitPaused)media?.pause();stop('Failed','track');return;
    }
    if(!media){state='AwaitMedia';wake();return;}
    if(ad()) {
      if(waitPaused && !recoveryAd){media.pause();state='AdPaused';}
      else state='AwaitMusic';
      clearTimeout(timeout);
      return; // A paused ad waits for media/DOM events, not a perpetual readiness poll.
    }
    if(state==='AdPaused'||state==='AwaitMusic') { state='AwaitMedia';recoveryAd=false;armTimeout(); }
    if(!identity() || media.readyState<1){state='AwaitMedia';wake();return;}
    if(saved.positionSeconds > media.duration + 1){if(waitPaused)media.pause();stop('Failed','track');return;}
    const target=Math.min(saved.positionSeconds,media.duration);
    // Signed-in playback can put several items on one media timeline. Media time equals the saved per-track
    // position only when the element's duration is this track's. Otherwise the site's whole-second t= is the
    // mechanism: the element is never seeked, and the public per-track clock must confirm the position.
    const ownTimeline=Math.abs(media.duration-saved.durationSeconds)<=2;
    if(waitPaused) {
      if(!sought && ownTimeline) {
        if(!seekable(target)){state='AwaitMedia';wake();return;}
        state='Pause/Seek';media.pause();ignoreSeek=true;sought=true;media.currentTime=target;
        media.addEventListener('seeked',()=>{ignoreSeek=false;wake();},{once:true});
      }
      if(!ownTimeline)media.pause();
      state='Verify';
      const clock=ownTimeline?null:trackClock();
      if(media.seeking || !media.paused || (ownTimeline ? Math.abs(media.currentTime-target)>1 : !clock)){stableAt=0;wake();return;}
      if(!stableAt)stableAt=performance.now();
      if(performance.now()-stableAt<500){wake();return;}
      // Paused, so the displayed whole second cannot drift: it must be the saved one (t= floors).
      if(!ownTimeline && Math.abs(clock.position-saved.positionSeconds)>1.5){stop('Failed','position');return;}
    } else {
      // URL t= is the entire StartPlaying mechanism: observe only, never seek or retry play.
      state='Verify';
      if(media.readyState<2){wake();return;}
      if(!media.paused && initialPosition===null){wake();return;}
      if(ownTimeline) {
        if(Math.abs((initialPosition ?? media.currentTime)-saved.positionSeconds)>1){stop('Failed','position');return;}
      } else {
        // Let the displayed clock catch up for 1 s, then it must lie between the saved second and now.
        const clock=trackClock(), since=playingAt===null?0:(performance.now()-playingAt)/1000;
        if(!clock || playingAt!==null && since<1){wake();return;}
        if(clock.position<saved.positionSeconds-1.5 || clock.position>saved.positionSeconds+since+2){stop('Failed','position');return;}
      }
      if(media.paused)reason='paused';
    }
    stop('Done',reason);
  }
  const observer=new MutationObserver(wake);
  observer.observe(document,{childList:true,subtree:true,attributes:true,attributeFilter:['class','href']});
  document.addEventListener('play',onPlay,true);
  document.addEventListener('playing',onPlay,true);
  document.addEventListener('seeking',onSeek,true);
  document.addEventListener('click',onClick,true);
  document.addEventListener('keydown',onKey,true);
  document.addEventListener('play',onFailedPlay,true);
  document.addEventListener('keydown',onInput,true);
  document.addEventListener('pointerdown',onInput,true);
  document.addEventListener('visibilitychange',onVisibility,true);
  for(const event of wakeEvents)document.addEventListener(event,wake,true);
  globalThis.__nativuneResume={
    status:()=>({generation,state,reason,recoveryAd,initialPosition,hidden:document.visibilityState==='hidden'}),
    cancel,
    fail:()=>{if(!terminal()&&state!=='AdPaused'&&state!=='AwaitMusic')stop('Failed','timeout');return {generation,state};},
    recover:()=>{if(state==='AdPaused'){recoverAd();return {adRecovery:true,generation};}return cancel();}
  };
  state='AwaitMedia';armTimeout();wake();
})();
