(() => {
    'use strict';
    if (globalThis.__nativuneEq) return;
    if (globalThis.top !== globalThis || location.origin !== 'https://music.youtube.com') return;
    const installedDocument = document;
    const centres = [31.5, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000];
    const sources = new WeakMap();
    let epoch = null, rev = 0, desired = null;
    let ctx = null, source = null, element = null, filters = [], preamp = null;
    let state = 'off', reason = '', encrypted = false, mediaKeys = false;
    let working = false, pending = false, gestureListening = false, resumeInFlight = false;
    let reloadNeeded = false;
    let activationAttempted = false, parameterRevision = -1, attachmentAttempted = false;

    function status() {
        return { state, reason, sampleRate: ctx ? ctx.sampleRate : 0,
            baseLatency: ctx && Number.isFinite(ctx.baseLatency) ? ctx.baseLatency : 0,
            attached: source !== null, rev, encrypted, mediaKeys };
    }
    function setState(value, why = '') { state = value; reason = why; }
    function ramp(parameter, value) {
        const now = ctx.currentTime;
        parameter.cancelScheduledValues(now);
        parameter.setTargetAtTime(value, now, 0.008);
    }
    function updateParameters() {
        if (parameterRevision === rev) return;
        parameterRevision = rev;
        const dry = !desired.enabled || desired.bypass;
        filters.forEach((filter, index) => ramp(filter.gain, dry ? 0 : desired.gains[index]));
        ramp(preamp.gain, dry ? 1 : Math.pow(10, desired.preampDb / 20));
    }
    async function resume() {
        if (resumeInFlight || ctx.state === 'running') return;
        resumeInFlight = true;
        try {
            // A browser may leave resume pending until a genuine gesture. Bound our wait.
            await Promise.race([ctx.resume().catch(() => {}), new Promise(resolve => setTimeout(resolve, 750))]);
        } catch (_) { }
        finally { resumeInFlight = false; }
    }
    function listenForGesture() {
        if (gestureListening) return;
        gestureListening = true;
        document.addEventListener('pointerdown', onGesture, true);
        document.addEventListener('keydown', onGesture, true);
    }
    function removeGestureListeners() {
        gestureListening = false;
        document.removeEventListener('pointerdown', onGesture, true);
        document.removeEventListener('keydown', onGesture, true);
    }
    async function onGesture(event) {
        if (!event.isTrusted) return;
        removeGestureListeners();
        if (ctx) await resume();
        await reconcile();
    }
    async function reconcile() {
        if (working) { pending = true; return; }
        working = true;
        try {
            if (document !== installedDocument || !desired) return;
            if (source) {
                if (!element.isConnected || !Array.from(document.querySelectorAll('video,audio')).includes(element)) reloadNeeded = true;
                mediaKeys = element.mediaKeys !== null;
                updateParameters();
                if (encrypted || mediaKeys) { setState('protectedMedia', 'protected'); return; }
                if (reloadNeeded) { setState('reloadNeeded', 'elementChanged'); return; }
                if (ctx.state !== 'running') { setState('interrupted', 'context'); listenForGesture(); return; }
                setState(!desired.enabled ? 'off' : desired.bypass ? 'bypassed' : 'active');
                return;
            }
            if (!desired.enabled) { setState('off'); return; }
            const elements = document.querySelectorAll('video,audio');
            if (elements.length === 0) { setState('waiting', 'media'); return; }
            if (elements.length !== 1) { setState('notApplied', 'ambiguous'); return; }
            const candidate = elements[0];
            mediaKeys = candidate.mediaKeys !== null;
            if (mediaKeys) { setState('unsupported', 'protected'); return; }
            if (!candidate.currentSrc) { setState('waiting', 'loading'); return; }
            if (!candidate.currentSrc.startsWith('blob:https://music.youtube.com/')) { setState('notApplied', 'source'); return; }
            if (!ctx) {
                if (typeof AudioContext !== 'function') { setState('unsupported', 'audioContext'); return; }
                ctx = new AudioContext({ latencyHint: 'playback' });
                ctx.onstatechange = async () => {
                    if (!source || ctx.state === 'running') { await reconcile(); return; }
                    await resume();
                    await reconcile();
                };
            }
            if (ctx.state !== 'running' && !activationAttempted) {
                activationAttempted = true;
                await resume();
            }
            if (ctx.state !== 'running') { setState('waiting', 'gesture'); listenForGesture(); return; }
            // Recheck after the asynchronous activation: never attach an obsolete or unsafe element.
            if (!desired.enabled || !candidate.isConnected || document.querySelectorAll('video,audio').length !== 1 ||
                candidate.mediaKeys !== null || !candidate.currentSrc.startsWith('blob:https://music.youtube.com/')) {
                pending = true; return;
            }
            if (attachmentAttempted) { setState('reloadNeeded', 'audioGraph'); return; }
            attachmentAttempted = true;
            filters = centres.map(frequency => {
                const filter = ctx.createBiquadFilter();
                filter.type = 'peaking'; filter.frequency.value = frequency;
                filter.Q.value = Math.SQRT2; filter.gain.value = 0;
                return filter;
            });
            preamp = ctx.createGain(); preamp.gain.value = 1;
            filters.forEach((filter, index) => filter.connect(filters[index + 1] || preamp));
            preamp.connect(ctx.destination);
            source = sources.get(candidate);
            if (!source) { source = ctx.createMediaElementSource(candidate); sources.set(candidate, source); }
            element = candidate;
            source.connect(filters[0]);
            element.addEventListener('encrypted', () => { encrypted = true; void reconcile(); });
            updateParameters();
            setState(desired.bypass ? 'bypassed' : 'active');
            removeGestureListeners();
        } catch (_) {
            reloadNeeded = attachmentAttempted;
            setState(attachmentAttempted ? 'reloadNeeded' : 'unavailable', 'audioGraph');
        }
        finally {
            working = false;
            if (pending) { pending = false; void reconcile(); }
        }
    }
    function validApply(value) {
        return value && Number.isSafeInteger(value.rev) && value.rev > 0 && Number.isSafeInteger(value.epoch) &&
            typeof value.enabled === 'boolean' && typeof value.bypass === 'boolean' &&
            Array.isArray(value.gains) && value.gains.length === 10 &&
            value.gains.every(gain => Number.isFinite(gain) && gain >= -12 && gain <= 12) &&
            Number.isFinite(value.preampDb) && value.preampDb >= -24 && value.preampDb <= 6;
    }
    const controller = {
        async apply(value) {
            if (!validApply(value) || document !== installedDocument || value.rev <= rev || (epoch !== null && epoch !== value.epoch)) return status();
            epoch = value.epoch; rev = value.rev;
            desired = { enabled: value.enabled, bypass: value.bypass, gains: value.gains.slice(), preampDb: value.preampDb };
            await reconcile();
            return status();
        },
        status() { if (desired) void reconcile(); return status(); }
    };
    if (globalThis.__nativuneEqTestHooks) controller.__graph = () => ({ source, filters, preamp, ctx });
    globalThis.__nativuneEq = controller;
    // Music's DOM changes constantly (progress text, lyrics). Only watch for the media element while
    // it is still needed (enabled and not yet attached), and coalesce bursts; after attachment the
    // host's bounded status reads detect element replacement.
    let observeTimer = 0;
    new MutationObserver(() => {
        if (!desired || !desired.enabled || source || observeTimer) return;
        observeTimer = setTimeout(() => { observeTimer = 0; void reconcile(); }, 250);
    }).observe(document, { childList: true, subtree: true });
    document.addEventListener('loadedmetadata', () => { if (desired) void reconcile(); }, true);
    document.addEventListener('emptied', () => { if (desired) void reconcile(); }, true);
})();
