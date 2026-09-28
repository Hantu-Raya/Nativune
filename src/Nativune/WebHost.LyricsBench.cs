#if NATIVUNE_PERF_BENCH_HOOKS
using Microsoft.Web.WebView2.Core;
using System.Text.Json;
using UiDispatcherQueueTimer = Microsoft.UI.Dispatching.DispatcherQueueTimer;

namespace Nativune;

// Lyrics E2E (scripts/lyrics-e2e.ps1, protocol scripts/lyrics-e2e-protocol.md), bench builds only.
// Observes Barebones Better Lyrics as loaded by production (settings.json BetterLyricsEnabled) and drives the
// production lyric settings window through OpenLyricsSettingsAsync / LyricsSettingsCore.
// Public signed-out test tracks only; lyric text and page titles are hashed, never logged.
public sealed partial class WebHostWindow
{
    private const string LyricsBenchSampleScript =
        "(()=>{const v=document.querySelector('video');const u=new URL(location.href);" +
        "const c=document.querySelector('.blyrics-container');const L=[...document.querySelectorAll('.blyrics--line')];" +
        "const tm=e=>{const x=parseFloat(e.dataset.time);return Number.isFinite(x)?x:null;};" +
        "const act=[];L.forEach((e,i)=>{if(e.classList.contains('blyrics--active'))act.push(i);});" +
        "const last=act.length?act[act.length-1]:-1;" +
        "let h=0;const s=L.map(e=>e.dataset.content||e.textContent||'').join('\\n');for(let i=0;i<s.length;i++)h=(h*31+s.charCodeAt(i))|0;" +
        "const tab=[...document.querySelectorAll('tp-yt-paper-tab')].find(t=>/lyrics|liedtext|songtext/i.test(t.textContent));" +
        "const tr=c?c.querySelectorAll('[class*=\"translat\"]').length:0;" +
        // Word-state frontier for the Core timing metric (protocol amendment 28 Sep 2026): [start,end,state] per sung
        // word, no text. Highlight duplicates, translations and romanizations are excluded. A line without word spans
        // yields [] when it is instrumental or has no letter or digit of its own (a blank or symbol-only spacer line,
        // amendment 28 Sep 2026); otherwise [null,null,null], so the analyzer fails it instead of dropping it.
        "const blank=l=>{const o=l.cloneNode(true);o.querySelectorAll('.blyrics--romanized,.blyrics--translated').forEach(x=>x.remove());return !/[\\p{L}\\p{N}]/u.test(o.textContent||'');};" +
        "let wordlessBlank=0;" +
        "const timingWords=[...(c?c.querySelectorAll('.blyrics--line'):[])].flatMap(l=>{" +
        "const w=[...l.querySelectorAll('.blyrics--word:not(.blyrics-word-highlight)')].filter(e=>!e.closest('.blyrics--romanized,.blyrics--translated'));" +
        "if(!w.length){if(l.dataset.instrumental==='true')return [];if(blank(l)){wordlessBlank++;return [];}return [[null,null,null]];}" +
        "return w.map((e,i)=>{const a=Number(e.dataset.time),d=Number(e.dataset.duration);" +
        "return [a,d>0?a+d:(i+1<w.length?Number(w[i+1].dataset.time):Number(l.dataset.time)+Number(l.dataset.duration)),e.dataset.wordState??null];});});" +
        "return {v:u.searchParams.get('v'),path:u.pathname,t:v&&Number.isFinite(v.currentTime)?v.currentTime:null,paused:v?v.paused:null," +
        "lines:L.length,active:act.slice(-4),activeTime:last>=0?tm(L[last]):null,nextTime:last>=0&&last+1<L.length?tm(L[last+1]):null," +
        "firstTime:L.length?tm(L[0]):null,sync:c?(c.dataset.sync||null):null,noLyrics:c?(c.dataset.noLyrics||null):null," +
        "container:!!c,blyrics:document.querySelectorAll('[class*=\"blyrics\"]').length,timed:L.filter(e=>tm(e)!==null).length,translated:tr>0,translatedCount:tr," +
        "hash:L.length?h:null,tab:tab?tab.getAttribute('aria-selected'):null,lang:document.documentElement.lang||null,doc:performance.timeOrigin," +
        "ad:!!document.querySelector('ytmusic-player-bar[is-advertisement]'),timingWords,wordlessBlank};})()";

    // The Lyrics tab is the third tab of the player page; the text match covers English and German UI.
    private const string LyricsBenchTabScript =
        "(()=>{const ts=[...document.querySelectorAll('tp-yt-paper-tab')];" +
        "const t=ts.find(t=>/lyrics|liedtext|songtext/i.test(t.textContent))||ts[1]||null;" +
        "if(!t)return 'no-tab';const b=t.getBoundingClientRect(),x=Math.max(1,b.left+b.width/2),y=Math.max(1,b.top+b.height/2);" +
        "const o={bubbles:true,composed:true,view:window,button:0,clientX:x,clientY:y};" +
        "t.dispatchEvent(new MouseEvent('mousemove',o));t.dispatchEvent(new PointerEvent('pointerdown',o));t.dispatchEvent(new MouseEvent('mousedown',o));" +
        "t.dispatchEvent(new PointerEvent('pointerup',o));t.dispatchEvent(new MouseEvent('mouseup',o));t.dispatchEvent(new MouseEvent('click',o));return 'ok';})()";

    private const string LyricsBenchTitleScript =
        "(()=>{const s=document.title||'';let h=0;for(let i=0;i<s.length;i++)h=(h*31+s.charCodeAt(i))|0;" +
        "return {titleHash:s.length?h:null,titleLength:s.length,isDefault:/^YouTube Music$/.test(s),v:new URL(location.href).searchParams.get('v')};})()";

    // StyleIsolation: computed styles of YouTube Music's own chrome. Missing elements are recorded as null.
    private const string LyricsBenchStyleProbeScript = """
        (()=>{
        const props=['background-color','background-image','color','opacity','filter','backdrop-filter','border-color','font-family','display','visibility'];
        const read=e=>{if(!e)return null;const cs=getComputedStyle(e);const r={};for(const p of props)r[p]=cs.getPropertyValue(p);return r;};
        const sels=['html','body','ytmusic-app','#layout','ytmusic-nav-bar','#nav-bar-background','#guide-wrapper','#mini-guide-background',
          'ytmusic-player-bar','#player-bar-background','ytmusic-player-page','#main-panel','#side-panel','tp-yt-paper-tabs',
          'ytmusic-player','#player','ytmusic-player-queue'];
        const el={};for(const s of sels)el[s]=read(document.querySelector(s));
        const tabs=[...document.querySelectorAll('tp-yt-paper-tab')];for(let i=0;i<3;i++)el['tp-yt-paper-tab['+i+']']=read(tabs[i]||null);
        const tr=document.querySelector('#tab-renderer');const pt=tr?(tr.getAttribute('page-type')||''):null;
        el['#tab-renderer']=tr&&pt!=='MUSIC_PAGE_TYPE_TRACK_LYRICS'?read(tr):null;
        const node=e=>e?{classes:[...e.classList].sort(),attributes:Object.fromEntries([...e.attributes].map(a=>[a.name,a.value]).sort())}:null;
        const rcs=getComputedStyle(document.documentElement);const vars={};
        for(let i=0;i<rcs.length;i++){const n=rcs[i];if(n.startsWith('--yt'))vars[n]=rcs.getPropertyValue(n).trim();}
        const sheets=[...document.styleSheets].map(s=>s.href).filter(h=>h&&h.startsWith('chrome-extension://'));
        return {path:location.pathname,tabRendererPageType:pt,elements:el,html:node(document.documentElement),body:node(document.body),rootVars:vars,extensionSheets:sheets};
        })()
        """;

    // Clicks the Home guide entry (href FEmusic_home or "/", else the first guide entry).
    private const string LyricsBenchHomeScript = """
        (()=>{
        const a=[...document.querySelectorAll('ytmusic-guide-entry-renderer a, ytmusic-pivot-bar-item-renderer, a')]
          .find(x=>{const h=x.getAttribute&&x.getAttribute('href');return h==='/'||(h&&h.includes('FEmusic_home'))||/FEmusic_home/.test(x.getAttribute&&x.getAttribute('tab-id')||'');})
          ||document.querySelector('ytmusic-guide-entry-renderer tp-yt-paper-item')||null;
        if(!a)return 'no-home';a.click();return 'ok';
        })()
        """;

    private UiDispatcherQueueTimer? _lyricsBenchTimer;
    private bool _lyricsBenchPending;
    private CoreWebView2? _lyricsBenchObservedOptions;
    private JsonElement? _lyricsBenchLastSample;
    private long _lyricsBenchLastSampleAt;

    // Extra observers on the Music view; production handlers still run and decide.
    private void LyricsBenchObserveMainView(CoreWebView2 core)
    {
        core.NavigationStarting += (_, a) => BenchHooks.Event("lyrics-main-nav", ("host", LyricsBenchHost(a.Uri)), ("scheme", LyricsBenchScheme(a.Uri)));
        core.NewWindowRequested += (_, a) => BenchHooks.Event("lyrics-main-newwindow", ("host", LyricsBenchHost(a.Uri)), ("user", a.IsUserInitiated));
        core.DownloadStarting += (_, a) => BenchHooks.Event("lyrics-main-download", ("host", LyricsBenchHost(a.DownloadOperation.Uri)));
        core.LaunchingExternalUriScheme += (_, a) => BenchHooks.Event("lyrics-main-external", ("scheme", LyricsBenchScheme(a.Uri)));
        core.ProcessFailed += (_, a) => BenchHooks.Event("lyrics-process-failed", ("kind", a.ProcessFailedKind.ToString()), ("view", "main"));
        core.ContentLoading += (_, a) => BenchHooks.Event("lyrics-main-content", ("errorPage", a.IsErrorPage));
        // The harness's full `nav` while playing raises YouTube Music's leave-page prompt, which blocks the page. Runs before the first
        // navigation (settings apply from the next one): the bench logs every dialog and accepts only the leave-page prompt.
        core.Settings.AreDefaultScriptDialogsEnabled = false;
        core.ScriptDialogOpening += (_, a) =>
        {
            BenchHooks.Event("lyrics-dialog", ("kind", a.Kind.ToString()));
            if (a.Kind == CoreWebView2ScriptDialogKind.Beforeunload) a.Accept();
        };
    }

    // Observers on the production options view; they only log, production handlers enforce containment.
    private void LyricsBenchObserveOptions(CoreWebView2 core)
    {
        if (ReferenceEquals(_lyricsBenchObservedOptions, core)) return;
        _lyricsBenchObservedOptions = core;
        core.NavigationStarting += (_, a) => BenchHooks.Event("lyrics-options-nav", ("host", LyricsBenchHost(a.Uri)), ("scheme", LyricsBenchScheme(a.Uri)));
        core.NewWindowRequested += (_, a) => BenchHooks.Event("lyrics-options-newwindow", ("host", LyricsBenchHost(a.Uri)), ("scheme", LyricsBenchScheme(a.Uri)));
        core.DownloadStarting += (_, _) => BenchHooks.Event("lyrics-options-download");
        core.LaunchingExternalUriScheme += (_, a) => BenchHooks.Event("lyrics-options-external", ("scheme", LyricsBenchScheme(a.Uri)));
        core.ProcessFailed += (_, a) => BenchHooks.Event("lyrics-process-failed", ("kind", a.ProcessFailedKind.ToString()), ("view", "options"));
    }

    private static string? LyricsBenchHost(string? uri) => Uri.TryCreate(uri, UriKind.Absolute, out var u) ? u.Host : null;
    private static string? LyricsBenchScheme(string? uri) => Uri.TryCreate(uri, UriKind.Absolute, out var u) ? u.Scheme : null;

    private async Task LyricsBenchRunActionAsync(string action)
    {
        if (_browserHost is null) return;
        var core = _browserHost.Core;
        var colon = action.IndexOf(':');
        var verb = colon < 0 ? action : action[..colon];
        var argument = colon < 0 ? null : action[(colon + 1)..];
        switch (verb)
        {
            case "pause":
            case "play":
                BenchHooks.Event("media-" + verb, ("result", await core.ExecuteScriptAsync(verb == "pause"
                    ? "(()=>{const v=document.querySelector('video');if(!v)return 'no-video';v.pause();return 'ok';})()"
                    : "(()=>{const v=document.querySelector('video');if(!v)return 'no-video';v.play();return 'ok';})()")));
                break;
            case "lyrics":
                await LyricsBenchLogExtensionsAsync(core);
                BenchHooks.Event("lyrics-tab", ("result", await core.ExecuteScriptAsync(LyricsBenchTabScript)));
                StartLyricsBenchSampler();
                break;
            case "seekfwd":
            case "seekback":
                BenchHooks.Event("lyrics-" + verb, ("result", await core.ExecuteScriptAsync(verb == "seekfwd"
                    ? "(()=>{const v=document.querySelector('video');if(!v)return null;v.currentTime=v.currentTime+40;return v.currentTime;})()"
                    : "(()=>{const v=document.querySelector('video');if(!v)return null;v.currentTime=Math.max(0,v.currentTime-25);return v.currentTime;})()")));
                break;
            case "next":
                BenchHooks.Event("lyrics-next", ("result", await core.ExecuteScriptAsync(
                    "(()=>{const b=document.querySelector('ytmusic-player-bar .next-button');if(!b)return 'no-button';b.click();return 'ok';})()")));
                break;
            case "nav" when argument is { Length: 11 }:
                await LyricsBenchNavAsync(core, argument);
                break;
            case "coverage":
                await LyricsBenchCoverageAsync(core);
                break;
            case "lyrics-off-now":
                // The production runtime-off path (Settings > Lyrics off); RuntimeOff scenario.
                BenchHooks.Event("lyrics-off-now-start");
                var off = await TurnLyricsOffAsync();
                BenchHooks.Event("lyrics-off-now", ("ok", off), ("status", LyricsStatusText));
                if (off && _browserHost is { } afterOff)
                    await LyricsBenchLogExtensionsAsync(afterOff.Core, "lyrics-extensions-after-off");
                break;
            case "capture" when argument is not null:
                await LyricsBenchCaptureAsync(core, argument, "main");
                break;
            case "style-probe" when argument is not null:
                BenchHooks.Event("style-probe", ("name", argument), ("r", await LyricsBenchEvaluateAsync(core, LyricsBenchStyleProbeScript)));
                break;
            case "home":
                BenchHooks.Event("lyrics-home", ("result", await core.ExecuteScriptAsync(LyricsBenchHomeScript)));
                break;
            case "options":
                await LyricsBenchOptionsAsync();
                break;
            case "capture-options" when argument is not null:
                if (LyricsSettingsCore is { } optionsCore) await LyricsBenchCaptureAsync(optionsCore, argument, "options");
                else BenchHooks.Event("lyrics-capture-skipped", ("name", argument), ("reason", "no-options-view"));
                break;
            case "translate-on":
            case "translate-off":
                await LyricsBenchOptionsScriptAsync(verb,
                    "(async()=>{const r={};const fire=e=>{e.dispatchEvent(new Event('input',{bubbles:true}));e.dispatchEvent(new Event('change',{bubbles:true}));};" +
                    "const t=document.getElementById('translate');const l=document.getElementById('translationLanguage');" +
                    "if(!t||!l)return {error:'missing-control',translate:!!t,translationLanguage:!!l};" +
                    "t.checked=" + (verb == "translate-on" ? "true" : "false") + ";fire(t);l.value='de';fire(l);" +
                    "await new Promise(z=>setTimeout(z,1500));r.checked=t.checked;r.language=l.value;return r;})()");
                break;
            case "offset-set":
                await LyricsBenchOptionsScriptAsync(verb,
                    "(async()=>{const e=document.getElementById('globalLyricOffset');if(!e)return {error:'missing-control'};" +
                    "e.value='1.5';e.dispatchEvent(new Event('input',{bubbles:true}));e.dispatchEvent(new Event('change',{bubbles:true}));" +
                    "await new Promise(z=>setTimeout(z,1500));return {value:e.value};})()");
                break;
            default:
                BenchHooks.Event("lyrics-action-unknown", ("action", verb));
                break;
        }
    }

    private void StartLyricsBenchSampler()
    {
        if (_lyricsBenchTimer is not null) return;
        _lyricsBenchTimer = _dispatcherQueue.CreateTimer();
        _lyricsBenchTimer.Interval = TimeSpan.FromMilliseconds(500);
        _lyricsBenchTimer.IsRepeating = true;
        _lyricsBenchTimer.Tick += OnLyricsBenchTick;
        _lyricsBenchTimer.Start();
    }

    private async void OnLyricsBenchTick(object? sender, object args)
    {
        if (_closing || _disposed) { _lyricsBenchTimer?.Stop(); return; }
        if (_lyricsBenchPending || _browserHost is null) return;
        _lyricsBenchPending = true;
        try
        {
            var raw = await BenchWithTimeout(_browserHost.Core.ExecuteScriptAsync(LyricsBenchSampleScript).AsTask(), 3);
            var sample = JsonDocument.Parse(raw).RootElement.Clone();
            _lyricsBenchLastSample = sample;
            _lyricsBenchLastSampleAt = System.Diagnostics.Stopwatch.GetTimestamp();
            BenchHooks.Event("lyrics-sample", ("s", sample));
        }
        catch (Exception ex) { BenchHooks.Event("lyrics-sample-error", ("error", ex.GetType().Name)); }
        finally { _lyricsBenchPending = false; }
    }

    // Enumerates installed profile extensions (ids and enabled state only) for the Off and load rules.
    private static async Task LyricsBenchLogExtensionsAsync(CoreWebView2 core, string eventName = "lyrics-extensions")
    {
        try
        {
            var list = await core.Profile.GetBrowserExtensionsAsync();
            var items = list.Select(e => new Dictionary<string, object?> { ["id"] = e.Id, ["enabled"] = e.IsEnabled }).ToList();
            BenchHooks.Event(eventName, ("items", items));
        }
        catch (Exception ex) { BenchHooks.Event(eventName + "-error", ("error", ex.GetType().Name)); }
    }

    private async Task<bool> LyricsBenchNavAsync(CoreWebView2 core, string videoId)
    {
        BenchHooks.Event("lyrics-nav", ("v", videoId));
        core.Navigate("https://music.youtube.com/watch?v=" + Uri.EscapeDataString(videoId));
        await Task.Delay(TimeSpan.FromSeconds(8));
        if (_closing || _disposed) return false;
        // Titles name the song: only a hash and whether it is still the generic title are logged.
        BenchHooks.Event("lyrics-nav-title", ("v", videoId), ("r", await LyricsBenchEvaluateAsync(core, LyricsBenchTitleScript)));
        BenchHooks.Event("lyrics-tab", ("result", await core.ExecuteScriptAsync(LyricsBenchTabScript)), ("v", videoId));
        StartLyricsBenchSampler();
        return true;
    }

    // Adaptive Coverage (protocol amendment 28 Sep 2026): navigates the frozen tracks in order and moves on as soon as a
    // synced sample for the NEW track carries fresh evidence (same video id, and a lyric hash different from the previous
    // track's or a new document); otherwise it waits the full 20 s window after the nav.
    private async Task LyricsBenchCoverageAsync(CoreWebView2 core)
    {
        foreach (var videoId in BenchHooks.CoverageTracks)
        {
            if (_closing || _disposed) return;
            var previous = _lyricsBenchLastSample;
            var previousHash = previous is { } p && p.TryGetProperty("hash", out var ph) ? ph.ToString() : null;
            var previousDoc = previous is { } q && q.TryGetProperty("doc", out var pd) ? pd.ToString() : null;
            var navAt = System.Diagnostics.Stopwatch.GetTimestamp();
            if (!await LyricsBenchNavAsync(core, videoId)) return;
            var reason = "cap";
            while (System.Diagnostics.Stopwatch.GetElapsedTime(navAt) < TimeSpan.FromSeconds(20.5))
            {
                if (_closing || _disposed) return;
                if (_lyricsBenchLastSampleAt > navAt && _lyricsBenchLastSample is { } s && LyricsBenchFreshSynced(s, videoId, previousHash, previousDoc))
                {
                    reason = "fresh";
                    break;
                }
                await Task.Delay(250);
            }
            BenchHooks.Event("lyrics-coverage-advance", ("v", videoId), ("reason", reason),
                ("afterMs", Math.Round(System.Diagnostics.Stopwatch.GetElapsedTime(navAt).TotalMilliseconds)));
        }
    }

    private static bool LyricsBenchFreshSynced(JsonElement s, string videoId, string? previousHash, string? previousDoc)
    {
        string? Text(string name) => s.TryGetProperty(name, out var value) && value.ValueKind != JsonValueKind.Null ? value.ToString() : null;
        var sync = Text("sync");
        var lines = s.TryGetProperty("lines", out var l) && l.ValueKind == JsonValueKind.Number ? l.GetInt32() : 0;
        if (Text("v") != videoId || lines <= 0 || sync is null or "" or "none" or "unsynced" or "plain" or "false") return false;
        return previousHash is null || Text("hash") != previousHash || (Text("doc") is { } doc && doc != previousDoc);
    }

    private static async Task LyricsBenchCaptureAsync(CoreWebView2 core, string name, string view)
    {
        if (BenchHooks.LogDirectory is not { } directory) return;
        try
        {
            var png = Path.Combine(directory, name + ".png");
            using (var stream = File.Create(png))
                await core.CapturePreviewAsync(CoreWebView2CapturePreviewImageFormat.Png, stream.AsRandomAccessStream());
            BenchHooks.Event("lyrics-capture", ("name", name), ("view", view), ("bytes", new FileInfo(png).Length));
        }
        catch (Exception ex) { BenchHooks.Event("lyrics-capture-failed", ("name", name), ("view", view), ("error", ex.GetType().Name)); }
    }

    // Opens (or reuses) the production lyric settings window and waits for the options document.
    private async Task<CoreWebView2?> LyricsBenchEnsureOptionsAsync()
    {
        try
        {
            await OpenLyricsSettingsAsync();
        }
        catch (Exception ex)
        {
            BenchHooks.Event("lyrics-options-failed", ("error", ex.GetType().Name + ": " + ex.Message), ("status", LyricsStatusText));
            return null;
        }
        for (var attempt = 0; attempt < 80 && !_closing && !_disposed; attempt++)
        {
            if (LyricsSettingsCore is { } core)
            {
                LyricsBenchObserveOptions(core);
                string? source = null;
                try { source = core.Source; } catch (Exception) { }
                if (source is not null && source.StartsWith("chrome-extension://", StringComparison.Ordinal))
                {
                    try
                    {
                        var state = await BenchWithTimeout(core.ExecuteScriptAsync("document.readyState").AsTask(), 3);
                        if (state == "\"complete\"")
                        {
                            BenchHooks.Event("lyrics-options-loaded", ("ok", true), ("host", LyricsBenchHost(source)),
                                ("path", Uri.TryCreate(source, UriKind.Absolute, out var u) ? u.AbsolutePath : null));
                            return core;
                        }
                    }
                    catch (Exception) { }
                }
            }
            await Task.Delay(250);
        }
        BenchHooks.Event("lyrics-options-loaded", ("ok", false), ("open", LyricsSettingsCore is not null), ("status", LyricsStatusText));
        return null;
    }

    private async Task LyricsBenchOptionsAsync()
    {
        var core = await LyricsBenchEnsureOptionsAsync();
        if (core is null) return;
        await Task.Delay(TimeSpan.FromSeconds(2));
        var nonce = Environment.GetEnvironmentVariable("NATIVUNE_BENCH_LYRICS_NONCE");
        BenchHooks.Event("lyrics-options-probe", ("r", await LyricsBenchEvaluateAsync(core, LyricsBenchProbeExpression(nonce))));
        await LyricsBenchCaptureAsync(core, "options", "options");
    }

    private async Task LyricsBenchOptionsScriptAsync(string verb, string expression)
    {
        var core = await LyricsBenchEnsureOptionsAsync();
        if (core is null)
        {
            BenchHooks.Event("lyrics-" + verb, ("r", "no-options-view"));
            return;
        }
        BenchHooks.Event("lyrics-" + verb, ("r", await LyricsBenchEvaluateAsync(core, expression)));
        BenchHooks.Event("lyrics-options-probe", ("r", await LyricsBenchEvaluateAsync(core, LyricsBenchProbeExpression(null))), ("after", verb));
    }

    private static string LyricsBenchProbeExpression(string? nonce)
    {
        var writes = nonce is null ? "" :
            "try{await c.storage.sync.set({e2eSync:N});r.syncWrite='ok'}catch(e){r.syncWrite='error: '+e.message}" +
            "try{await c.storage.local.set({e2eLocal:N});r.localWrite='ok'}catch(e){r.localWrite='error: '+e.message}";
        return "(async()=>{const r={};const c=globalThis.chrome||{};const N=" + JsonSerializer.Serialize(nonce) + ";" +
            "r.types={sync:typeof c.storage?.sync?.set,local:typeof c.storage?.local?.set,alarms:typeof c.alarms,alarmsGetAll:typeof c.alarms?.getAll," +
            "tabs:typeof c.tabs?.create,windows:typeof c.windows?.create,downloads:typeof c.downloads?.download,permissions:typeof c.permissions?.request};" +
            "try{const g=await navigator.serviceWorker.getRegistration();r.sw=g?{active:g.active?g.active.state:null}:null}catch(e){r.sw='error: '+e.message}" +
            "const id=x=>{const e=document.getElementById(x);return e?{present:true,type:e.type||e.tagName.toLowerCase(),checked:e.type==='checkbox'?e.checked:null," +
            "value:e.type==='checkbox'||e.tagName==='BUTTON'?null:(e.value??null)}:{present:false};};" +
            "r.controls={translate:id('translate'),translationLanguage:id('translationLanguage'),uiLanguage:id('uiLanguage')," +
            "globalLyricOffset:id('globalLyricOffset'),clearCache:id('clear-cache')};" +
            "const K=['isTranslateEnabled','translationLanguage','globalLyricOffset','uiLanguage'];" +
            "try{r.stored={sync:await c.storage.sync.get(K),local:await c.storage.local.get(K)}}catch(e){r.stored='error: '+e.message}" +
            "try{r.syncKeys=Object.keys(await c.storage.sync.get(null)).sort()}catch(e){r.syncKeys='error: '+e.message}" +
            "try{r.localKeyCount=Object.keys(await c.storage.local.get(null)).length}catch(e){r.localKeyCount='error: '+e.message}" +
            "try{r.nonceSyncBefore=(await c.storage.sync.get('e2eSync')).e2eSync??null}catch(e){r.nonceSyncBefore='error: '+e.message}" +
            "try{r.nonceLocalBefore=(await c.storage.local.get('e2eLocal')).e2eLocal??null}catch(e){r.nonceLocalBefore='error: '+e.message}" +
            writes +
            "r.textLength=(document.body&&document.body.innerText||'').length;r.lang=document.documentElement.lang||null;return r;})()";
    }

    private static async Task<object> LyricsBenchEvaluateAsync(CoreWebView2 core, string expression)
    {
        try
        {
            var parameters = JsonSerializer.Serialize(new { expression, awaitPromise = true, returnByValue = true });
            var raw = await BenchWithTimeout(core.CallDevToolsProtocolMethodAsync("Runtime.evaluate", parameters).AsTask(), 20);
            var root = JsonDocument.Parse(raw).RootElement;
            if (root.TryGetProperty("exceptionDetails", out var ex)) return "exception: " + ex.GetProperty("text").GetString();
            return root.GetProperty("result").TryGetProperty("value", out var value) ? value.Clone() : "no-value";
        }
        catch (Exception ex) { return "error: " + ex.GetType().Name + ": " + ex.Message; }
    }
}
#endif
