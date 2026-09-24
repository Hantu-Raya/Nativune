using System.Text.Encodings.Web;
using System.Text.Json;

namespace Nativune;

internal static class CompactPlayback
{
    internal const int MaxScriptResultLength = 8192;
    private const int MaxTitleLength = 512;
    private const int MaxArtworkUrlLength = 2048;
    private const double MaxDurationSeconds = 7 * 24 * 60 * 60;

    private static readonly JsonSerializerOptions SignatureOptions = new()
    {
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping
    };

    internal static string BuildScript(string mode, string? command, string href,
        long notAfterUnixMs, double? value = null, string? expectedStateSignature = null)
    {
        var request = JsonSerializer.Serialize(new
        {
            mode,
            command,
            href,
            notAfterUnixMs,
            value,
            expectedStateSignature
        });
        return "(() => { const request = " + request + ";\n" + CompactJavaScript + "\n})()";
    }

    // Item identity only: signed-in media duration can grow while the same item plays.
    internal static string ComputeSignature(CompactPlaybackState state)
        => JsonSerializer.Serialize(new object?[]
            { state.Title, state.ArtworkUrl, state.Duration, state.VideoId }, SignatureOptions);

    internal static bool TryParseState(string? json, out CompactPlaybackState? state)
    {
        state = null;
        if (json is null || json.Length == 0 || json.Length > MaxScriptResultLength)
            return false;

        try
        {
            using var document = JsonDocument.Parse(json, new JsonDocumentOptions { MaxDepth = 8 });
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object
                || !RequiredString(root, "code", "state", out _)
                || !RequiredString(root, "title", null, out var title)
                || title.Length == 0 || title.Length > MaxTitleLength
                || !NullableString(root, "artworkUrl", out var artworkUrl)
                || !NullableString(root, "videoId", out var videoId)
                || videoId is not null && (videoId.Length != 11
                    || videoId.Any(c => c is not (>= 'a' and <= 'z' or >= 'A' and <= 'Z'
                        or >= '0' and <= '9' or '-' or '_')))
                || artworkUrl is { Length: > MaxArtworkUrlLength }
                || artworkUrl is not null && !CompactArtwork.IsAllowedUrl(artworkUrl)
                || !RequiredBool(root, "paused", out var paused)
                || !RequiredFinite(root, "position", out var position)
                || !RequiredFinite(root, "duration", out var duration)
                || !RequiredFinite(root, "mediaDuration", out var mediaDuration)
                || !RequiredFinite(root, "mediaPosition", out var mediaPosition)
                || !RequiredBool(root, "websiteClock", out var websiteClock)
                || !NullableBool(root, "liked", out var liked)
                || !NullableBool(root, "disliked", out var disliked)
                || !NullableRepeat(root, "repeat", out var repeat)
                || !RequiredBool(root, "canSeek", out var canSeek)
                || !RequiredBool(root, "canLike", out var canLike)
                || !RequiredBool(root, "canDislike", out var canDislike)
                || !RequiredBool(root, "canRepeat", out var canRepeat)
                || !RequiredBool(root, "canShuffle", out var canShuffle)
                || !NullableBool(root, "shuffle", out var shuffle)
                || !RequiredBool(root, "clockMismatch", out var clockMismatch)
                || !RequiredBool(root, "clockConfirmed", out var clockConfirmed))
                return false;

            if (duration < 0 || duration > MaxDurationSeconds
                || position < 0 || position > MaxDurationSeconds
                || mediaDuration < 0 || mediaDuration > MaxDurationSeconds
                || mediaPosition < 0 || mediaPosition > MaxDurationSeconds
                || duration > 0 && position > duration && canSeek
                || duration == 0 && canSeek
                || websiteClock && duration <= 0
                || clockMismatch && canSeek
                || canSeek && !clockConfirmed
                || canSeek && !websiteClock && (mediaDuration <= 0 || mediaPosition > mediaDuration)
                || clockConfirmed && (clockMismatch || duration <= 0 || position > duration))
                return false;

            state = new CompactPlaybackState(title, artworkUrl, paused, position, duration,
                liked, disliked, repeat, canSeek, canLike, canDislike, canRepeat, canShuffle,
                shuffle, clockMismatch, videoId, clockConfirmed, mediaDuration, websiteClock,
                mediaPosition);
            return true;
        }
        catch (JsonException)
        {
            return false;
        }
    }

    internal static bool TryParseOutcome(string? json, out CompactPlaybackOutcome outcome)
    {
        outcome = default;
        if (json is null || json.Length == 0 || json.Length > 4096)
            return false;

        try
        {
            using var document = JsonDocument.Parse(json, new JsonDocumentOptions { MaxDepth = 4 });
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object
                || !root.TryGetProperty("code", out var codeElement)
                || codeElement.ValueKind != JsonValueKind.String)
                return false;
            var code = codeElement.GetString();
            if (code is not ("requested" or "unavailable" or "wrong-origin" or "stale-document"
                or "disabled-control" or "ambiguous-control" or "modal-open" or "unsupported-locale"
                or "expired" or "invalid-value" or "unsupported-command"
                or "stale-state" or "script-error"))
                return false;
            var dispatched = root.TryGetProperty("dispatched", out var dispatchedElement)
                && dispatchedElement.ValueKind is JsonValueKind.True or JsonValueKind.False
                && dispatchedElement.GetBoolean();
            outcome = new CompactPlaybackOutcome(code, dispatched);
            return true;
        }
        catch (JsonException)
        {
            return false;
        }
    }
    internal static bool IsTransportReadyResponse(string? json)
    {
        if (json is null || json.Length == 0 || json.Length > MaxScriptResultLength)
            return false;
        try
        {
            using var document = JsonDocument.Parse(json, new JsonDocumentOptions { MaxDepth = 4 });
            return document.RootElement.ValueKind == JsonValueKind.Object
                && RequiredString(document.RootElement, "code", "ready", out _);
        }
        catch (JsonException)
        {
            return false;
        }
    }

    private static bool RequiredString(JsonElement root, string name, string? expected, out string value)
    {
        value = string.Empty;
        if (!root.TryGetProperty(name, out var element) || element.ValueKind != JsonValueKind.String)
            return false;
        value = element.GetString() ?? string.Empty;
        return expected is null || value == expected;
    }

    private static bool NullableString(JsonElement root, string name, out string? value)
    {
        value = null;
        if (!root.TryGetProperty(name, out var element)) return false;
        if (element.ValueKind == JsonValueKind.Null) return true;
        if (element.ValueKind != JsonValueKind.String) return false;
        value = element.GetString();
        return value is not null;
    }

    private static bool RequiredBool(JsonElement root, string name, out bool value)
    {
        value = false;
        if (!root.TryGetProperty(name, out var element)
            || element.ValueKind is not (JsonValueKind.True or JsonValueKind.False)) return false;
        value = element.GetBoolean();
        return true;
    }

    private static bool NullableBool(JsonElement root, string name, out bool? value)
    {
        value = null;
        if (!root.TryGetProperty(name, out var element)) return false;
        if (element.ValueKind == JsonValueKind.Null) return true;
        if (element.ValueKind is not (JsonValueKind.True or JsonValueKind.False)) return false;
        value = element.GetBoolean();
        return true;
    }

    private static bool RequiredFinite(JsonElement root, string name, out double value)
    {
        value = 0;
        return root.TryGetProperty(name, out var element)
            && element.ValueKind == JsonValueKind.Number
            && element.TryGetDouble(out value)
            && double.IsFinite(value);
    }

    private static bool NullableRepeat(JsonElement root, string name, out string? value)
    {
        value = null;
        if (!root.TryGetProperty(name, out var element)) return false;
        if (element.ValueKind == JsonValueKind.Null) return true;
        if (element.ValueKind != JsonValueKind.String) return false;
        value = element.GetString();
        return value is "off" or "all" or "one";
    }

    internal readonly record struct CompactPlaybackOutcome(string Code, bool Dispatched);

    private const string CompactJavaScript = """
let dispatched = false;
try {
  const requestDocument = document;
  const result = (code, fields = {}) => Object.assign({code, dispatched}, fields);
  const finite = value => typeof value === 'number' && Number.isFinite(value);
  const attrNumber = (element, name) => {
    const raw = element?.getAttribute(name);
    if (typeof raw !== 'string' || raw.trim() === '') return null;
    const value = Number(raw);
    return finite(value) ? value : null;
  };
  const isPresent = element => element && element.ownerDocument === requestDocument && element.isConnected !== false;
  const layoutVisible = (element, allowZeroHeight = false, decorativeTrack = false) => {
    if (!isPresent(element)) return false;
    let node = element;
    for (let depth = 0; node && depth < 64; depth++, node = node.parentElement) {
      if (node.hasAttribute?.('hidden') || node.hasAttribute?.('inert')
        || node.getAttribute?.('aria-hidden') === 'true' && !(decorativeTrack && node === element)) return false;
      const style = getComputedStyle(node);
      if (style.display === 'none' || style.visibility === 'hidden' || style.visibility === 'collapse') return false;
    }
    if (node) return false;
    const rect = element.getBoundingClientRect();
    return finite(rect.width) && rect.width > 0 && finite(rect.height)
      && (allowZeroHeight || rect.height > 0);
  };
  const enabled = (element, allowZeroHeight = false) => {
    if (!layoutVisible(element, allowZeroHeight) || !(element instanceof HTMLElement)) return false;
    if (element.matches(':disabled') || element.hasAttribute('disabled')
      || element.getAttribute('aria-disabled') === 'true') return false;
    return true;
  };
  const modalVisible = element => {
    if (!isPresent(element)) return false;
    let node = element;
    for (let depth = 0; node && depth < 64; depth++, node = node.parentElement) {
      if (node.hasAttribute?.('hidden') || node.getAttribute?.('aria-hidden') === 'true') return false;
      const style = getComputedStyle(node);
      if (style.display === 'none' || style.visibility === 'hidden' || style.visibility === 'collapse') return false;
    }
    return !node;
  };
  if (window !== window.top || location.origin !== 'https://music.youtube.com')
    return result('wrong-origin');
  if (location.href !== request.href) return result('stale-document');
  if (!finite(request.notAfterUnixMs) || Date.now() > request.notAfterUnixMs)
    return result('expired');
  const language = requestDocument.documentElement?.lang;
  if (typeof language !== 'string' || !(language.toLowerCase() === 'en' || language.toLowerCase().startsWith('en-')))
    return result('unsupported-locale');
  const modals = requestDocument.querySelectorAll('dialog[open],[aria-modal="true"]');
  if (modals.length > 16 || Array.from(modals).some(modalVisible))
    return result('modal-open');
  const acquire = () => {
    if (document !== requestDocument || window !== window.top
      || location.origin !== 'https://music.youtube.com' || location.href !== request.href) return null;
    const bars = requestDocument.querySelectorAll('ytmusic-player-bar');
    const media = requestDocument.querySelectorAll('audio,video');
    if (bars.length !== 1 || media.length !== 1 || !(media[0] instanceof HTMLMediaElement)) return null;
    const bar = bars[0], element = media[0];
    if (!isPresent(bar) || !isPresent(element)) return null;
    const buttons = Array.from(bar.querySelectorAll('button,[role="button"]'));
    const seekSliders = Array.from(bar.querySelectorAll('tp-yt-paper-slider[id="progress-bar"]'));
    if (buttons.length > 128 || seekSliders.length > 8) return null;
    return {bar, element, buttons, seekSliders};
  };
  const label = element => (element.getAttribute('aria-label') || '').trim().toLowerCase();
  const choose = (candidates, allowZeroHeight = false) => {
    const visible = candidates.filter(element => layoutVisible(element, allowZeroHeight));
    if (visible.length > 1) return {status:'ambiguous-control'};
    if (visible.length === 0) return {status:'unavailable'};
    if (!enabled(visible[0], allowZeroHeight)) return {status:'disabled-control'};
    return {status:'ok', element:visible[0]};
  };
  const buttonsFor = (acquired, command) => acquired.buttons.filter(button => {
    const name = label(button);
    if (command === 'like') return name === 'like' || name === 'remove like';
    if (command === 'dislike') return name === 'dislike' || name === 'remove dislike';
    if (command === 'repeat') return name === 'repeat off' || name === 'repeat all' || name === 'repeat one' || name === 'repeat';
    if (command === 'shuffle') return name === 'shuffle' || name === 'shuffle on' || name === 'shuffle off';
    return false;
  });
  const transportForBar = bar => {
    const groups = Array.from(bar.querySelectorAll('[id="left-controls"].left-controls.ytmusic-player-bar'));
    if (groups.length !== 1 || !isPresent(groups[0])) return null;
    const buttons = Array.from(groups[0].querySelectorAll('button,[role="button"]'));
    if (buttons.length > 16) return null;
    const plays = buttons.filter(button => label(button) === 'play' || label(button) === 'pause');
    const previous = buttons.filter(button => label(button) === 'previous');
    const next = buttons.filter(button => label(button) === 'next');
    if (plays.length !== 1 || previous.length !== 1 || next.length !== 1) return null;
    const playPause = plays[0], previousButton = previous[0], nextButton = next[0];
    if (!layoutVisible(playPause) || !layoutVisible(previousButton) || !layoutVisible(nextButton)) return null;
    return {group:groups[0], playPause, previous:previousButton, next:nextButton};
  };
  const trackFor = slider => {
    const tracks = Array.from(slider.querySelectorAll('[id="sliderBar"]'));
    // The public slider owns accessibility; its visible decorative progress child is aria-hidden.
    if (tracks.length !== 1 || !layoutVisible(slider, true) || !layoutVisible(tracks[0], false, true)) return null;
    const rect = tracks[0].getBoundingClientRect();
    if (!finite(rect.left) || !finite(rect.top) || !finite(rect.width) || !finite(rect.height)
      || rect.width <= 0 || rect.height <= 0) return null;
    return {element:tracks[0], rect};
  };
  const rangeFor = slider => {
    const min = attrNumber(slider, 'aria-valuemin');
    const max = attrNumber(slider, 'aria-valuemax');
    const now = attrNumber(slider, 'aria-valuenow');
    if (!finite(min) || !finite(max) || !finite(now) || min < 0 || max > 604800
      || max <= min || now < min || now > max) return null;
    return {min, max, now};
  };
  const secondsFor = text => {
    if (typeof text !== 'string' || text.length === 0 || text.length > 24) return null;
    const parts = text.split(':');
    let seconds;
    if (parts.length === 2 && /^\d{1,5}$/.test(parts[0]) && /^\d{2}$/.test(parts[1])) {
      const minutes = Number(parts[0]), remainder = Number(parts[1]);
      if (remainder >= 60) return null;
      seconds = minutes * 60 + remainder;
    } else if (parts.length === 3 && /^\d{1,3}$/.test(parts[0])
      && /^\d{2}$/.test(parts[1]) && /^\d{2}$/.test(parts[2])) {
      const hours = Number(parts[0]), minutes = Number(parts[1]), remainder = Number(parts[2]);
      if (minutes >= 60 || remainder >= 60) return null;
      seconds = hours * 3600 + minutes * 60 + remainder;
    } else return null;
    return finite(seconds) && seconds <= 604800 ? seconds : null;
  };
  const timeInfoFor = (acquired, seek) => {
    const candidates = acquired.bar.querySelectorAll('span.time-info');
    if (candidates.length === 0) return {status:'absent'};
    if (candidates.length !== 1 || !layoutVisible(candidates[0])
      || typeof candidates[0].textContent !== 'string' || candidates[0].textContent.length > 64)
      return {status:'invalid'};
    const match = candidates[0].textContent.trim().match(/^([^/]+)\s*\/\s*([^/]+)$/);
    if (!match) return {status:'invalid'};
    const position = secondsFor(match[1].trim()), duration = secondsFor(match[2].trim());
    const range = seek.status === 'ok' ? rangeFor(seek.element) : null;
    if (!finite(position) || !finite(duration) || duration <= 0 || position > duration || !range
      || Math.abs(range.min) > 2 || Math.abs(range.max - duration) > 2
      || Math.abs(range.now - position) > 2) return {status:'invalid'};
    return {status:'ok', element:candidates[0], position, duration, range};
  };
  const seekClockMatches = (media, range) => !!range && media.duration > 0
    && Math.abs(range.min) <= 2 && Math.abs(range.max - media.duration) <= 2
    && Math.abs(range.now - media.position) <= 5;
  // A coherent visible website clock and slider are authoritative. Signed-in playback
  // can place several items on one media timeline, so media time is display-only.
  const clockFor = (acquired, media, seek) => {
    const site = timeInfoFor(acquired, seek);
    if (site.status === 'ok')
      return {position:site.position, duration:site.duration, websiteClock:true,
        mismatch:false, confirmed:true, range:site.range};
    if (site.status === 'invalid')
      return {position:media.position, duration:media.duration, websiteClock:false,
        mismatch:true, confirmed:false, range:null};
    const range = seek.status === 'ok' ? rangeFor(seek.element) : null;
    const coherent = !!range && seekClockMatches(media, range);
    return {position:media.position, duration:media.duration, websiteClock:false,
      mismatch:!media.clockWithinDuration || !!range && !coherent,
      confirmed:media.duration > 0 && media.clockWithinDuration && coherent, range};
  };
  const videoIdFor = () => {
    const watchUrl = new URL(location.href);
    const videoIds = watchUrl.searchParams.getAll('v');
    return watchUrl.pathname === '/watch' && videoIds.length === 1
      && /^[A-Za-z0-9_-]{11}$/.test(videoIds[0]) ? videoIds[0] : null;
  };
  const metadataFor = (acquired, duration) => {
    const titles = Array.from(acquired.bar.querySelectorAll('.title'));
    if (titles.length !== 1 || typeof titles[0].textContent !== 'string') return null;
    const title = titles[0].textContent.trim();
    if (title.length === 0 || title.length > 512) return null;
    const images = Array.from(acquired.bar.querySelectorAll('img'));
    const shown = images.filter(image => {
      if (!layoutVisible(image) || image.complete !== true || !finite(image.naturalWidth)
        || !finite(image.naturalHeight) || image.naturalWidth <= 0 || image.naturalHeight <= 0
        || image.naturalWidth > 4096 || image.naturalHeight > 4096) return false;
      const raw = image.currentSrc;
      if (typeof raw !== 'string' || raw.length === 0 || raw.length > 2048) return false;
      try {
        const uri = new URL(raw);
        return uri.protocol === 'https:' && (uri.port === '' || uri.port === '443')
          && uri.username === '' && uri.password === ''
          && ['lh3.googleusercontent.com','i.ytimg.com','yt3.ggpht.com','yt3.googleusercontent.com'].includes(uri.hostname.toLowerCase());
      } catch { return false; }
    });
    const artworkUrl = shown.length === 1 ? shown[0].currentSrc : null;
    const videoId = videoIdFor();
    return {title, artworkUrl, signature:JSON.stringify([title, artworkUrl, duration, videoId])};
  };
  const stateMediaFor = acquired => {
    const element = acquired.element;
    if (!isPresent(element)) return null;
    const position = element.currentTime, rawDuration = element.duration;
    const duration = rawDuration === Infinity || Number.isNaN(rawDuration) ? 0 : rawDuration;
    if (typeof element.paused !== 'boolean' || typeof element.seeking !== 'boolean'
      || !finite(position) || !finite(duration) || duration < 0 || duration > 604800
      || position < 0 || position > 604800) return null;
    return {position, duration, paused:element.paused, seeking:element.seeking,
      clockWithinDuration:duration <= 0 || position <= duration};
  };
  const signedStateFor = (acquired, media, seek = choose(acquired.seekSliders, true)) => {
    const clock = clockFor(acquired, media, seek);
    const metadata = metadataFor(acquired, clock.duration);
    return {clock, metadata, seek};
  };
  // Validates a seek in the website slider's own seconds; the site maps it to media.
  const seekSnapshot = (acquired, targetElement, target) => {
    if (window !== window.top || location.origin !== 'https://music.youtube.com')
      return {error:'wrong-origin'};
    if (document !== requestDocument || location.href !== request.href)
      return {error:'stale-document'};
    const media = stateMediaFor(acquired);
    if (!media) return {error:'invalid-value'};
    const seek = choose(acquired.seekSliders, true);
    if (seek.status !== 'ok') return {error:seek.status};
    if (seek.element !== targetElement) return {error:'stale-document'};
    const {clock, metadata} = signedStateFor(acquired, media, seek);
    if (!metadata) return {error:'unavailable'};
    if (typeof request.expectedStateSignature !== 'string'
      || request.expectedStateSignature !== metadata.signature)
      return {error:'stale-state'};
    if (!trackFor(targetElement)) return {error:'unavailable'};
    if (media.seeking || !clock.confirmed || clock.mismatch || !clock.range || clock.duration <= 0)
      return {error:'unavailable'};
    if (!finite(target) || target < 0 || target > clock.duration
      || target < clock.range.min || target > clock.range.max)
      return {error:'invalid-value'};
    return {};
  };
  const state = () => {
    const acquired = acquire(), media = acquired && stateMediaFor(acquired);
    if (!acquired || !media) return result('unavailable');
    const transport = transportForBar(acquired.bar);
    if (!transport || !enabled(transport.playPause)) return result('unavailable');
    const like = choose(buttonsFor(acquired, 'like'));
    const dislike = choose(buttonsFor(acquired, 'dislike'));
    const repeat = choose(buttonsFor(acquired, 'repeat'));
    const shuffle = choose(buttonsFor(acquired, 'shuffle'));
    const seek = choose(acquired.seekSliders, true);
    const {clock, metadata} = signedStateFor(acquired, media, seek);
    if (!metadata) return result('unavailable');
    const pressed = choice => {
      if (choice.status !== 'ok') return null;
      const value = choice.element.getAttribute('aria-pressed');
      return value === 'true' ? true : value === 'false' ? false : null;
    };
    const repeatLabel = repeat.status === 'ok' ? label(repeat.element) : '';
    const repeatState = repeatLabel === 'repeat off' ? 'off' : repeatLabel === 'repeat all' ? 'all'
      : repeatLabel === 'repeat one' ? 'one' : null;
    const liked = pressed(like), disliked = pressed(dislike);
    const shuffleActive = (() => {
      if (shuffle.status !== 'ok') return null;
      const explicit = pressed(shuffle);
      if (explicit !== null) return explicit;
      const button = shuffle.element;
      if (label(button) !== 'shuffle' || button.matches(':hover') || button.matches(':focus-visible')
        || repeatState !== 'off' || repeat.status !== 'ok'
        || getComputedStyle(repeat.element).color !== 'rgb(144, 144, 144)')
        return null;
      // Trust the observed dark-site white/on and gray/off colors only while
      // the separate, explicitly labeled Repeat Off button confirms gray is inactive.
      // An unrecognized theme or style leaves Shuffle unconfirmed.
      const color = getComputedStyle(button).color;
      return color === 'rgb(255, 255, 255)' ? true
        : color === 'rgb(144, 144, 144)' ? false : null;
    })();
    const seekRange = clock.range;
    const seekTrack = seek.status === 'ok' ? trackFor(seek.element) : null;
    const canSeek = clock.duration > 0 && seek.status === 'ok' && !!seekRange && !!seekTrack
      && !media.seeking && clock.confirmed && !clock.mismatch;
    const clockMismatch = clock.mismatch;
    const videoId = videoIdFor();
    const clockConfirmed = clock.confirmed;
    return {code:'state', title:metadata.title, artworkUrl:metadata.artworkUrl, paused:media.paused,
      position:clock.position, duration:clock.duration, mediaPosition:media.position,
      mediaDuration:media.duration,
      websiteClock:clock.websiteClock, liked, disliked, repeat:repeatState,
      shuffle:shuffleActive, clockMismatch, clockConfirmed, videoId,
      canSeek, canLike:like.status === 'ok' && liked !== null, canDislike:dislike.status === 'ok' && disliked !== null,
      canRepeat:repeat.status === 'ok' && repeatState !== null, canShuffle:shuffle.status === 'ok',
      signature:metadata.signature};
  };
  const transportReady = () => {
    const bars = requestDocument.querySelectorAll('ytmusic-player-bar');
    if (bars.length !== 1 || !isPresent(bars[0])) return result('unavailable');
    const initialBar = bars[0];
    const initial = transportForBar(initialBar);
    if (!initial || !enabled(initial.playPause)) return result('unavailable');
    const currentBars = requestDocument.querySelectorAll('ytmusic-player-bar');
    if (currentBars.length !== 1 || currentBars[0] !== initialBar) return result('unavailable');
    const current = transportForBar(currentBars[0]);
    if (!current || current.group !== initial.group || current.playPause !== initial.playPause
      || current.previous !== initial.previous || current.next !== initial.next
      || !enabled(current.playPause)) return result('unavailable');
    return result('ready');
  };
  if (request.mode === 'ready') return transportReady();
  if (request.mode === 'state') return state();
  if (request.mode !== 'action' || !['like','dislike','repeat','shuffle','seek'].includes(request.command))
    return result('unsupported-command');
  const initial = acquire();
  if (!initial) return result('unavailable');
  const targetFor = acquired => request.command === 'seek'
    ? choose(acquired.seekSliders, true) : choose(buttonsFor(acquired, request.command));
  const initialTarget = targetFor(initial);
  if (initialTarget.status !== 'ok') return result(initialTarget.status);
  if (request.command === 'seek') {
    const snapshot = seekSnapshot(initial, initialTarget.element, request.value);
    if (snapshot.error) return result(snapshot.error);
  }
  const current = acquire();
  if (!current || current.bar !== initial.bar || current.element !== initial.element) return result('stale-document');
  const currentTarget = targetFor(current);
  if (currentTarget.status !== 'ok') return result(currentTarget.status);
  if (currentTarget.element !== initialTarget.element) return result('stale-document');
  if (request.command === 'like' || request.command === 'dislike') {
    const media = stateMediaFor(current), signed = media && signedStateFor(current, media);
    if (!media || !signed?.metadata || typeof request.expectedStateSignature !== 'string'
      || request.expectedStateSignature !== signed.metadata.signature) return result('stale-state');
  }
  if (request.command === 'seek') {
    const snapshot = seekSnapshot(current, currentTarget.element, request.value);
    if (snapshot.error) return result(snapshot.error);
  }
  if (Date.now() > request.notAfterUnixMs) return result('expired');
  const final = acquire();
  if (!final || final.bar !== current.bar || final.element !== current.element) return result('stale-document');
  const finalTarget = targetFor(final);
  if (finalTarget.status !== 'ok') return result(finalTarget.status);
  if (finalTarget.element !== currentTarget.element) return result('stale-document');
  if (request.command === 'like' || request.command === 'dislike') {
    const media = stateMediaFor(final), signed = media && signedStateFor(final, media);
    if (!media || !signed?.metadata || typeof request.expectedStateSignature !== 'string'
      || request.expectedStateSignature !== signed.metadata.signature) return result('stale-state');
  }
  if (request.command === 'seek') {
    const snapshot = seekSnapshot(final, finalTarget.element, request.value);
    if (snapshot.error) return result(snapshot.error);
    const slider = finalTarget.element;
    // Commit exactly as the site's slider does: its change handler reads value and seeks.
    try { slider.value = request.value; }
    catch { return result('script-error'); }
    if (!finite(slider.value) || Math.abs(slider.value - request.value) > 1)
      return result('invalid-value');
    dispatched = true;
    try { slider.dispatchEvent(new Event('change', {bubbles:true, composed:true})); }
    catch { return result('script-error'); }
    return result('requested');
  }
  const finalButton = finalTarget.element;
  if (!enabled(finalButton)) return result('disabled-control');
  dispatched = true;
  try { HTMLElement.prototype.click.call(finalButton); }
  catch { return result('script-error'); }
  return result('requested');
} catch {
  return {code:'script-error', dispatched, observed:false, noOp:false};
}
""";
}
