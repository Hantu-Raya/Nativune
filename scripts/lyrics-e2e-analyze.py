"""Barebones Better Lyrics E2E analyzer. Applies the frozen rules in scripts/lyrics-e2e-protocol.md.

Usage: python scripts/lyrics-e2e-analyze.py <out> <raw-runs-dir>
Reads <out>/config.json, <out>/<arm>.bench.jsonl, <out>/<arm>.lyrics.log and <raw>/<arm>.netlog.json.
Only host names (with first-seen times and request-source counts for lyric hosts) leave the raw netlogs.
Writes <out>/hosts.json, <out>/summary.json and <out>/report.json (pass | fail | blocked per scenario, with evidence).
"""
import json
import os
import re
import statistics
import sys
from collections import Counter

out, raw_dir = sys.argv[1], sys.argv[2]
config = json.load(open(os.path.join(out, "config.json"), encoding="utf-8-sig"))
EXPECTED_ID = config.get("expectedExtensionId", "ogodmldcmpbfeekmejkeppchklblochl")
LYRIC_HOSTS = {"api.betterlyrics.org", "lrclib.net", "a.nel.cloudflare.com"}  # a.nel: Chromium NEL for Cloudflare-hosted api.betterlyrics.org (pre-freeze amendment, 28 Sep 2026)
TRANSLATE_HOST = "translate.googleapis.com"
SYNCED_OFF = (None, "", "none", "unsynced", "plain", "false")
MARK_EVENTS = ("media-pause", "media-play", "lyrics-seekfwd", "lyrics-seekback", "lyrics-next", "lyrics-nav", "lyrics-offset-set")
BAD_EVENTS = ("lyrics-main-download", "lyrics-main-external", "lyrics-options-download", "lyrics-options-external",
              "lyrics-process-failed")


def events(arm):
    p = os.path.join(out, f"{arm}.bench.jsonl")
    if not os.path.exists(p):
        return []
    res = []
    for line in open(p, encoding="utf-8-sig", errors="replace"):
        line = line.strip()
        if line:
            try:
                res.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    return res


def first(ev, name, pred=lambda e: True):
    return next((e for e in ev if e["event"] == name and pred(e)), None)


def samples_of(ev):
    return [(e["t"], e["s"]) for e in ev if e["event"] == "lyrics-sample" and isinstance(e.get("s"), dict)]


def is_synced(s):
    return s.get("sync") not in SYNCED_OFF and s.get("lines", 0) > 0


# Spike rules 3-5, unchanged thresholds.
def timing(ev):
    samples = samples_of(ev)
    marks = [e["t"] for e in ev if e["event"] in MARK_EVENTS]
    changes = [samples[i][0] for i in range(1, len(samples)) if samples[i][1].get("v") != samples[i - 1][1].get("v")]
    quiet = lambda t: all(abs(t - m) > 2000 for m in marks + changes)
    ok_line = lambda s: s.get("activeTime") is not None and s["activeTime"] <= s["t"] + 1 and (s.get("nextTime") is None or s["nextTime"] > s["t"] - 1)
    per = {}
    for t, s in samples:
        v = s.get("v")
        d = per.setdefault(v, {"samples": 0, "withLines": 0, "syncValues": Counter(), "eligible": 0, "pass": 0, "noActive": 0,
                               "firstLinesAtMs": None})
        d["samples"] += 1
        d["syncValues"][str(s.get("sync"))] += 1
        if s.get("lines", 0) > 0:
            d["withLines"] += 1
            if d["firstLinesAtMs"] is None:
                d["firstLinesAtMs"] = t
        # Post-data amendment: during an ad the <video> is the ad and the fork deliberately pauses highlighting; ad samples are ineligible.
        if (is_synced(s) and s.get("paused") is False and s.get("t") is not None and not s.get("ad")
                and s.get("firstTime") is not None and s["t"] >= s["firstTime"] + 1 and quiet(t)):
            d["eligible"] += 1
            if s.get("activeTime") is None:
                d["noActive"] += 1
            elif ok_line(s):
                d["pass"] += 1
    for d in per.values():
        d["syncValues"] = dict(d["syncValues"])
        d["passRate"] = round(d["pass"] / d["eligible"], 4) if d["eligible"] else None
    seeks = []
    for e in ev:
        if e["event"] in ("lyrics-seekfwd", "lyrics-seekback"):
            win = [s for t, s in samples if e["t"] <= t <= e["t"] + 2000 and is_synced(s)]
            seeks.append({"event": e["event"], "applicable": bool(win), "correctWithin2s": any(s.get("t") is not None and ok_line(s) for s in win)})
    pause = None
    p0, p1 = first(ev, "media-pause"), first(ev, "media-play")
    if p0 and p1:
        win = [s for t, s in samples if p0["t"] + 500 <= t <= p1["t"]]
        ts = [s["t"] for s in win if s.get("t") is not None]
        pause = {"samples": len(win), "timeSpread": round(max(ts) - min(ts), 3) if ts else None,
                 "activeStable": len({json.dumps(s.get("active")) for s in win}) <= 1}
        pause["pass"] = bool(win) and pause["timeSpread"] is not None and pause["timeSpread"] <= 0.3 and pause["activeStable"]
    change = None
    nxt = first(ev, "lyrics-next")
    if nxt:
        before = [(t, s) for t, s in samples if t <= nxt["t"]]
        after = [(t, s) for t, s in samples if t > nxt["t"]]
        old_v = before[-1][1].get("v") if before else None
        old_h = before[-1][1].get("hash") if before else None
        new = [(t, s) for t, s in after if s.get("v") != old_v]
        if new:
            t0 = new[0][0]
            stale = [t - t0 for t, s in new if old_h is not None and s.get("hash") == old_h]
            change = {"oldHadLyrics": old_h is not None, "newVideoAfterMs": round(t0 - nxt["t"]),
                      "maxStaleMs": round(max(stale)) if stale else 0, "pass": (max(stale) if stale else 0) <= 2000}
        else:
            change = {"pass": False, "reason": "video id never changed"}
    return per, seeks, pause, change


def extensions(ev):
    e = first(ev, "lyrics-extensions")
    return e.get("items") if e else None


def load(ev):
    items = extensions(ev) or []
    mine = [i for i in items if i.get("id") == EXPECTED_ID]
    return {"enumerated": extensions(ev) is not None, "loaded": bool(mine and mine[0].get("enabled")),
            "present": bool(mine), "otherIds": [i.get("id") for i in items if i.get("id") != EXPECTED_ID]}


def lyrics_ok(ev):
    tab = (first(ev, "lyrics-tab") or {}).get("t")
    for t, s in samples_of(ev):
        if tab and is_synced(s) and t - tab <= 20000:
            return True
    return False


def probes(ev):
    return [e.get("r") for e in ev if e["event"] == "lyrics-options-probe" and isinstance(e.get("r"), dict)]


def stored(probe, key):
    st = (probe or {}).get("stored")
    if not isinstance(st, dict):
        return None
    for area in ("sync", "local"):
        v = (st.get(area) or {}).get(key)
        if v is not None:
            return v
    return None


def containment(ev):
    bad = [e["event"] for e in ev if e["event"] in BAD_EVENTS or e["event"] == "harness-killed"]
    navs = Counter(f"{e.get('scheme')}://{e.get('host')}" for e in ev if e["event"] == "lyrics-main-nav")
    offsite = {k: v for k, v in navs.items() if not (k.startswith("https://music.youtube.com") or k.startswith("chrome-extension://") or k.startswith("about://"))}
    return {"badEvents": bad, "mainNavs": dict(navs), "mainNavOffsite": offsite,
            "optionsNavs": dict(Counter(f"{e.get('scheme')}://{e.get('host')}" for e in ev if e["event"] == "lyrics-options-nav")),
            "newWindows": [e.get("host") for e in ev if e["event"] in ("lyrics-main-newwindow", "lyrics-options-newwindow")]}


# Real host names only: dotted names (not bare schemes like "http"/"https", not single-label names like "wpad") or localhost.
def valid_host(h):
    return h == "localhost" or ("." in h and not h.startswith("-") and all(part for part in h.split(".")))


# NetLog (Default capture). Hosts come only from structured fields of named event types, never from free text
# (request headers such as Lrclib-Client carry URLs that are not requests). Tolerant of a truncated tail.
HOST_EVENT_MARKERS = ("URL_REQUEST_START_JOB", "REQUEST_ALIVE", "HOST_RESOLVER", "DNS", "CONNECT_JOB", "SOCKET_POOL",
                      "HTTP_STREAM_JOB", "SSL_CONNECT", "TCP_CONNECT")
HOST_FIELDS = ("url", "original_url", "host", "group_id", "group_name", "destination", "server")
LYRIC_PATHS = ("/getLyrics", "/api/get", "/translate_a/")


def host_of(value):
    if not isinstance(value, str) or not value:
        return None
    v = value.strip()
    if "://" in v:
        v = v.split("://", 1)[1]
    else:
        v = v.split("/")[-1] if v.count("/") and not v.startswith("[") else v  # e.g. "ssl/host:443", "pm/ssl/host:443"
    v = v.split("/", 1)[0].split("?", 1)[0].split("@")[-1]
    if v.startswith("["):
        return None  # IPv6 literal
    v = v.rsplit(":", 1)[0] if v.count(":") == 1 else v
    v = v.lower().strip(".")
    if not re.fullmatch(r"[a-z0-9.\-]+", v) or re.fullmatch(r"[0-9.]+", v):
        return None
    return v if valid_host(v) else None


def iter_netlog(text):
    """Yields (constants, event) tolerant of a missing final ']}' or a cut-off last event."""
    dec = json.JSONDecoder()
    constants = {}
    m = re.search(r'"constants"\s*:\s*', text)
    if m:
        try:
            constants, _ = dec.raw_decode(text, m.end())
        except json.JSONDecodeError:
            constants = {}
    m = re.search(r'"events"\s*:\s*\[', text)
    if not m:
        return constants, []
    pos, evs, n = m.end(), [], len(text)
    while pos < n:
        while pos < n and text[pos] in " \t\r\n,":
            pos += 1
        if pos >= n or text[pos] == "]":
            break
        try:
            ev, pos = dec.raw_decode(text, pos)
        except json.JSONDecodeError:
            break  # truncated final event
        if isinstance(ev, dict):
            evs.append(ev)
    return constants, evs


def netlog(arm):
    p = os.path.join(raw_dir, f"{arm}.netlog.json")
    if not os.path.exists(p):
        return None
    constants, evs = iter_netlog(open(p, encoding="utf-8", errors="replace").read())
    names = {v: k for k, v in (constants.get("logEventTypes") or {}).items()} if isinstance(constants, dict) else {}
    try:
        offset = int((constants or {}).get("timeTickOffset"))
    except (TypeError, ValueError):
        offset = None
    hosts, first_seen, sources = Counter(), {}, {h: {} for h in LYRIC_HOSTS | {TRANSLATE_HOST}}
    for ev in evs:
        etype = ev.get("type")
        name = names.get(etype, etype if isinstance(etype, str) else "")
        if not any(mk in name for mk in HOST_EVENT_MARKERS):
            continue
        params = ev.get("params") or {}
        if not isinstance(params, dict):
            continue
        try:
            when = int(ev.get("time")) + offset if offset is not None else None
        except (TypeError, ValueError):
            when = None
        sid = str((ev.get("source") or {}).get("id"))
        found = {h for h in (host_of(params.get(k)) for k in HOST_FIELDS) if h}
        for h in found:
            hosts[h] += 1
            if when is not None and (h not in first_seen or when < first_seen[h]):
                first_seen[h] = when
        url = params.get("url")
        if name == "URL_REQUEST_START_JOB" and isinstance(url, str) and any(x in url for x in LYRIC_PATHS):
            h = host_of(url)
            if h in sources and (sid not in sources[h] or (when is not None and (sources[h][sid] is None or when < sources[h][sid]))):
                sources[h][sid] = when
    return {"hosts": hosts, "firstSeen": first_seen, "requestSources": {h: len(v) for h, v in sources.items()},
            "requestTimes": {h: sorted(t for t in v.values() if t is not None) for h, v in sources.items()}}


# Post-data amendment (run 20260927T221658Z): YouTube's own ads appear at random in any arm. Ad hosts count as page traffic only
# when the staged lyrics bundle contains none of these names, which the analyzer checks itself.
AD_SUFFIXES = ("doubleclick.net", "googlesyndication.com", "googleadservices.com")


def _bundle_mentions_ads():
    root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
    ver = json.load(open(os.path.join(root, "release-inputs.json"), encoding="utf-8-sig"))["betterLyrics"]["version"]
    tree = os.path.join(root, ".tools", "better-lyrics", ver)
    if not os.path.isdir(tree):
        return None
    for dp, _, fs in os.walk(tree):
        for f in fs:
            data = open(os.path.join(dp, f), "rb").read()
            if any(s.encode() in data for s in AD_SUFFIXES):
                return True
    return False


BUNDLE_MENTIONS_ADS = _bundle_mentions_ads()


def ignorable(h):
    if h.endswith(".googlevideo.com") or h == "googlevideo.com":
        return True
    return BUNDLE_MENTIONS_ADS is False and any(h == s or h.endswith("." + s) for s in AD_SUFFIXES)


arms = [a["arm"] for a in config["arms"]]
ev_by = {a: events(a) for a in arms}
nl = {a: netlog(a) for a in arms}
# Post-data amendment: the page baseline is every lyrics-off control arm (C, C2, C3), not C alone; C must still exist.
control = set().union(*(set(nl[a]["hosts"]) for a in ("C", "C2", "C3") if nl.get(a))) if nl.get("C") else None
hosts_out = {"note": "host names only, from structured NetLog fields (URL request, resolver, connect events); counts are event hits, not request counts; googlevideo shards ignored in rules; ad hosts ignored only when the lyrics bundle has no ad-host names",
             "bundleMentionsAds": BUNDLE_MENTIONS_ADS,
             "arms": {a: dict(n["hosts"].most_common()) for a, n in nl.items() if n}, "onlyWithExtension": {},
             "lyricRequestSources": {a: n["requestSources"] for a, n in nl.items() if n}}


def extra_hosts(arm):
    n = nl.get(arm)
    if n is None or control is None:
        return None
    extra = sorted(h for h in n["hosts"] if h not in control and not ignorable(h))
    hosts_out["onlyWithExtension"][arm] = extra
    return extra


summary = {}
for a in arms:
    per, seeks, pause, change = timing(ev_by[a])
    summary[a] = {"events": len(ev_by[a]), "load": load(ev_by[a]), "lyricsOk": lyrics_ok(ev_by[a]), "tracks": per, "seeks": seeks,
                  "pause": pause, "trackChange": change, "probes": probes(ev_by[a]), "containment": containment(ev_by[a]),
                  "captures": [{k: e.get(k) for k in ("name", "view", "bytes")} for e in ev_by[a] if e["event"] == "lyrics-capture"],
                  "optionsLoaded": [e.get("ok") for e in ev_by[a] if e["event"] == "lyrics-options-loaded"],
                  "sampleErrors": sum(e["event"] == "lyrics-sample-error" for e in ev_by[a])}

scenarios = {}


def verdict(name, expected, checks, evidence, needed_arms=(), needs_control=False):
    missing = [a for a in needed_arms if not ev_by.get(a)]
    if missing:
        scenarios[name] = {"status": "blocked", "expected": expected, "reason": f"no bench log for arm(s) {missing}", "evidence": evidence}
        return
    if needs_control and control is None:
        scenarios[name] = {"status": "blocked", "expected": expected, "reason": "control arm C netlog missing", "evidence": evidence}
        return
    if any(v is None for v in checks.values()):
        scenarios[name] = {"status": "blocked", "expected": expected, "reason": "unmeasurable: " + ", ".join(k for k, v in checks.items() if v is None),
                           "checks": checks, "evidence": evidence}
        return
    scenarios[name] = {"status": "pass" if all(checks.values()) else "fail", "expected": expected, "checks": checks, "evidence": evidence}


def cap_bytes(arm, name):
    return next((c["bytes"] for c in summary.get(arm, {}).get("captures", []) if c["name"] == name), None)


selected = config["scenarios"]

if "Core" in selected:
    r1, r2 = summary.get("R1", {}), summary.get("R2", {})
    p1 = next(iter(r1.get("probes") or []), {})
    p2 = next(iter(r2.get("probes") or []), {})
    synced = [d for d in (r1.get("tracks") or {}).values() if d["eligible"] > 0]
    controls = (p1.get("controls") or {})
    checks = {
        "1_load": bool(r1.get("load", {}).get("loaded") and r2.get("load", {}).get("loaded")),
        "2_lyrics": bool(r1.get("lyricsOk")),
        "3_timing": bool(synced) and all(d["passRate"] is not None and d["passRate"] >= 0.95 for d in synced)
                    and all(s["correctWithin2s"] for s in r1.get("seeks", []) if s["applicable"]),
        "4_pause": bool(r1.get("pause") and r1["pause"]["pass"]),
        "5_trackChange": bool(r1.get("trackChange") and r1["trackChange"]["pass"]),
        "6_options": True in r1.get("optionsLoaded", []) and (cap_bytes("R1", "options") or 0) > 10000
                     and p1.get("syncWrite") == "ok" and p1.get("localWrite") == "ok"
                     and p2.get("nonceSyncBefore") == config["nonce"] and p2.get("nonceLocalBefore") == config["nonce"]
                     and all((controls.get(k) or {}).get("present") for k in ("translate", "translationLanguage", "uiLanguage", "globalLyricOffset", "clearCache")),
        "7_noWorker": bool(p1) and p1.get("sw") is None,
        "8_containment": not r1.get("containment", {}).get("badEvents") and not r2.get("containment", {}).get("badEvents"),
        "9_blockAdsOn": bool(r2.get("load", {}).get("loaded") and r2.get("lyricsOk")),
    }
    verdict("Core", "spike rules 1-6, 8-9 unchanged; rule 7 inverted to no service-worker registration", checks,
            {"R1": {k: r1.get(k) for k in ("load", "seeks", "pause", "trackChange", "containment")},
             "R2": {k: r2.get(k) for k in ("load", "containment")}, "probeR1": p1, "probeR2": p2,
             "syncedTracks": {v: {"passRate": d["passRate"], "eligible": d["eligible"]} for v, d in (r1.get("tracks") or {}).items() if d["eligible"]}},
            ("R1", "R2"))

if "HostAllowlist" in selected:
    per_arm = {}
    for a in ("R1", "R2", "I", "T1", "T2"):
        extra = extra_hosts(a)
        allowed = LYRIC_HOSTS | ({TRANSLATE_HOST} if a == "T1" else set())
        per_arm[a] = None if extra is None else {"extra": extra, "notAllowed": sorted(set(extra) - allowed)}
    checks = {a: (None if v is None else not v["notAllowed"]) for a, v in per_arm.items()}
    verdict("HostAllowlist", "extension-arm hosts minus control hosts (googlevideo ignored) within {api.betterlyrics.org, lrclib.net, a.nel.cloudflare.com}, plus translate.googleapis.com only in TranslateOn (T1)",
            checks, per_arm, ("R1", "R2", "I", "T1", "T2"), needs_control=True)

if "Idle" in selected:
    i = summary.get("I", {})
    probe = (i.get("probes") or [{}])[-1] if i.get("probes") else {}
    anchor = (first(ev_by.get("I", []), "anchor") or {}).get("t")
    late = None
    if nl.get("I") and anchor:
        seen = nl["I"]["firstSeen"]
        # Post-data amendment: Chromium delivers NEL reports (a.nel.cloudflare.com) late, for earlier requests; not new activity.
        late = sorted(h for h, t in seen.items() if t > anchor + 60000 and not ignorable(h) and h != "a.nel.cloudflare.com"
                      and (control is None or h not in control))
    checks = {"noWorker": (None if not probe else probe.get("sw") is None),
              "alarmsUndefined": (None if not probe else (probe.get("types") or {}).get("alarms") == "undefined"),
              "noNewHostAfterMinute1": None if late is None else not late}
    verdict("Idle", "10 min idle: no worker registration, chrome.alarms undefined, no new non-control host after the first minute",
            checks, {"probe": probe, "lateHosts": late, "controlUsed": control is not None}, ("I",))

if "TranslateOn" in selected:
    ev = ev_by.get("T1", [])
    on = first(ev, "lyrics-translate-on")
    translated_at = None
    if on:
        translated_at = next((t - on["t"] for t, s in samples_of(ev) if t >= on["t"] and s.get("translated") and s.get("lines", 0) > 0), None)
    extra = extra_hosts("T1")
    t_hosts = set(nl["T1"]["hosts"]) if nl.get("T1") else None
    checks = {"toggled": bool(on and isinstance(on.get("r"), dict) and on["r"].get("checked") is True and on["r"].get("language") == "de"),
              "translatedWithin10s": translated_at is not None and translated_at <= 10000,
              "translateHostSeen": None if t_hosts is None else TRANSLATE_HOST in t_hosts,
              "noOtherHost": None if extra is None else not (set(extra) - LYRIC_HOSTS - {TRANSLATE_HOST})}
    verdict("TranslateOn", "translation enabled through #translate/#translationLanguage=de; translated line element within 10 s; translate.googleapis.com seen; no other extra host",
            checks, {"toggle": on.get("r") if on else None, "translatedAfterMs": translated_at, "extraHosts": extra}, ("T1",), needs_control=True)

if "TranslateOff" in selected:
    ev = ev_by.get("T2", [])
    probe = (summary.get("T2", {}).get("probes") or [{}])[0] if summary.get("T2", {}).get("probes") else {}
    t_hosts = set(nl["T2"]["hosts"]) if nl.get("T2") else None
    checks = {"storedOff": None if not probe else stored(probe, "isTranslateEnabled") in (False, None),
              "noTranslateHost": None if t_hosts is None else TRANSLATE_HOST not in t_hosts,
              "noTranslatedLines": not any(s.get("translated") for _, s in samples_of(ev)),
              "lyricsStillShown": lyrics_ok(ev)}
    verdict("TranslateOff", "restart after turning translation off in the UI: no translate.googleapis.com, original lines only",
            checks, {"storedIsTranslateEnabled": stored(probe, "isTranslateEnabled") if probe else None}, ("T2",), needs_control=False)

if "SettingsPersist" in selected:
    ev1 = ev_by.get("S1", [])
    probe2 = (summary.get("S2", {}).get("probes") or [{}])[0] if summary.get("S2", {}).get("probes") else {}
    off_ev = first(ev1, "lyrics-offset-set")
    shift_range, lag_n = None, None
    if off_ev:
        # Post-data amendment: the fork applies the offset to the playback clock (engine.js subtracts it), never to data-time.
        # Exact bounds: a forward active-line change between consecutive samples p, s happened at media time x in (p.t, s.t], so the
        # engine's lead (line data-time minus activation time) lies in [activeTime - s.t, activeTime - p.t). Intersecting these per side
        # bounds lead (before) and lead - offset (after); the shift range is [loB - hiA, hiB - loA].
        smp = samples_of(ev1)
        v_at = next((s.get("v") for t, s in reversed(smp) if t <= off_ev["t"]), None)
        marks = [e["t"] for e in ev1 if e["event"] in MARK_EVENTS + ("lyrics-translate-off", "lyrics-translate-on", "lyrics-options-nav",
                                                                     "lyrics-options-loaded", "lyrics-options-probe", "lyrics-capture") and e is not off_ev]

        def bounds(lo, hi):
            low, high, n, prev = float("-inf"), float("inf"), 0, None
            for t, s in smp:
                ok = (lo <= t <= hi and s.get("v") == v_at and not s.get("ad") and s.get("paused") is False and s.get("t") is not None
                      and is_synced(s) and s.get("activeTime") is not None and all(abs(t - m) > 3000 for m in marks))
                if not ok:
                    prev = None
                    continue
                if prev is not None and s["activeTime"] > prev["activeTime"] and 0 < s["t"] - prev["t"] <= 1.5:
                    low, high, n = max(low, s["activeTime"] - s["t"]), min(high, s["activeTime"] - prev["t"]), n + 1
                prev = s
            return low, high, n
        b, a = bounds(off_ev["t"] - 40000, off_ev["t"] - 500), bounds(off_ev["t"] + 2000, off_ev["t"] + 50000)
        lag_n = {"before": b[2], "after": a[2], "leadBefore": [round(b[0], 3), round(b[1], 3)], "leadMinusOffsetAfter": [round(a[0], 3), round(a[1], 3)]}
        if b[2] >= 3 and a[2] >= 3:
            # An empty intersection (inconsistent timing) yields an inverted range, which fails below.
            shift_range = [round(b[0] - a[1], 3), round(b[1] - a[0], 3)]
    try:
        offset_val = float(stored(probe2, "globalLyricOffset"))
    except (TypeError, ValueError):
        offset_val = None
    checks = {"languagePersisted": None if not probe2 else stored(probe2, "translationLanguage") == "de",
              "offsetPersisted": None if not probe2 else offset_val is not None and abs(offset_val - 1.5) < 1e-6,
              "offsetAppliedLive": None if shift_range is None else (shift_range[0] <= shift_range[1] and 1.25 <= shift_range[0] and shift_range[1] <= 1.75)}
    verdict("SettingsPersist", "translationLanguage=de and globalLyricOffset=1.5 set in the UI persist across restart; without restart, the whole feasible "
            "shift range of the active-line lead (exact bounds from >= 3 line changes each side) lies within 1.5 s ± 0.25",
            checks, {"storedAfterRestart": (probe2 or {}).get("stored"), "shiftRange": shift_range, "lineChanges": lag_n}, ("S1", "S2"))

if "Off" in selected:
    res = {}
    for a in ("O1", "P2", "P3"):
        ev = ev_by.get(a, [])
        items = extensions(ev)
        mine = [i for i in (items or []) if i.get("id") == EXPECTED_ID]
        n = nl.get(a)
        res[a] = {"extensionsEnumerated": items is not None,
                  "notEnabled": items is not None and not any(i.get("enabled") for i in mine),
                  "absent": items is not None and not mine,
                  # Post-data amendment: Nativune opens uBOL's own page at every start; only the lyrics extension's id counts.
                  "noExtensionNav": not any(e["event"] == "lyrics-options-nav" or (e["event"] == "lyrics-main-nav" and e.get("scheme") == "chrome-extension"
                                                                                  and e.get("host") == EXPECTED_ID) for e in ev),
                  "noLyricHost": None if n is None else not (set(n["hosts"]) & (LYRIC_HOSTS - {"a.nel.cloudflare.com"})),
                  "noBlyrics": bool(samples_of(ev)) and all(s.get("blyrics", 0) == 0 and not s.get("container") for _, s in samples_of(ev))}
    checks = {"P1_loaded": bool(summary.get("P1", {}).get("load", {}).get("loaded")),
              "O1_neverInstalled": res["O1"]["absent"]}
    for a in ("O1", "P2", "P3"):
        for k in ("notEnabled", "noExtensionNav", "noLyricHost", "noBlyrics"):
            checks[f"{a}_{k}"] = res[a][k]
    logs = {}
    for a in ("O1", "P1", "P2", "P3"):
        p = os.path.join(out, f"{a}.lyrics.log")
        if os.path.exists(p):
            logs[a] = [re.sub(r"^\S+\s+", "", l.strip())[:120] for l in open(p, encoding="utf-8-sig", errors="replace") if l.strip()][:20]
    verdict("Off", "lyrics off: no enabled extension, no chrome-extension navigation, no lyric host, no blyrics elements; a previously enabled instance stays disabled over two restarts",
            checks, {"arms": res, "appLogLyricsLines": logs}, ("O1", "P1", "P2", "P3"))

if "NonEnglish" in selected:
    ev = ev_by.get("G", [])
    smp = samples_of(ev)
    langs = Counter(str(s.get("lang")) for _, s in smp)
    german = any(str(s.get("lang") or "").lower().startswith("de") for _, s in smp)
    per = {}
    for t, s in smp:
        if is_synced(s):
            per.setdefault(s.get("v"), t)
    tab = (first(ev, "lyrics-tab") or {}).get("t")
    nxt = first(ev, "lyrics-next")
    seed = "dQw4w9WgXcQ"
    track2 = next((s.get("v") for t, s in smp if nxt and t > nxt["t"] and s.get("v") and s.get("v") != seed), None)
    evidence = {"htmlLang": dict(langs), "trackA": seed in per, "track2": track2 is not None and track2 in per,
                "trackAWithin20s": bool(tab and seed in per and per[seed] - tab <= 20000)}
    if ev and smp and not german:
        scenarios["NonEnglish"] = {"status": "blocked", "expected": "lyrics found for track A and track 2 on a German (hl=de) page",
                                   "reason": "page <html lang> was not 'de' (hl=de not honoured)", "evidence": evidence}
    else:
        verdict("NonEnglish", "on a German (hl=de, <html lang=de>) page: synced lyrics found for track A (within 20 s of the tab click) and for track 2",
                {"trackA": evidence["trackAWithin20s"], "track2": evidence["track2"]}, evidence, ("G",))

if "NoLyrics" in selected:
    track = config.get("noLyricsTrack") or ""
    if not track:
        scenarios["NoLyrics"] = {"status": "blocked", "expected": "no synced lines and an honest empty state within 20 s; <= 3 requests per lyric host in 60 s",
                                 "reason": "no -NoLyricsTrack given"}
    else:
        ev = ev_by.get("N", [])
        nav = first(ev, "lyrics-nav", lambda e: e.get("v") == track)
        win = [s for t, s in samples_of(ev) if nav and nav["t"] <= t <= nav["t"] + 20000 and s.get("v") == track]
        times = (nl.get("N") or {}).get("requestTimes")
        in60 = None if times is None or not nav else {h: sum(1 for x in ts if nav["t"] <= x <= nav["t"] + 60000) for h, ts in times.items()}
        synced = any(is_synced(s) for s in win)
        checks = {"noSyncedLinesWithin20s": not synced,
                  # Post-data amendment: upstream and the fork render "not found" as one message line with data-time 0
                  # (lyrics.ts), marking the container data-no-lyrics=true, sync none. Honest = that marker appears, and no
                  # sample shows more than the one message line or any timed line without the marker.
                  "honestEmptyState": bool(win) and any(s.get("noLyrics") == "true" for s in win)
                                      and all((s.get("lines", 0) <= 1) if s.get("noLyrics") == "true" else s.get("timed", 0) == 0 for s in win),
                  "noRetryStorm": None if in60 is None else all(n <= 3 for n in in60.values())}
        evidence = {"requestsIn60s": in60, "samplesInWindow": len(win),
                    "states": dict(Counter(f"container={s.get('container')} noLyrics={s.get('noLyrics')} sync={s.get('sync')}" for s in win))}
        verdict("NoLyrics", "no synced lines within 20 s of nav; the container shows data-no-lyrics=true with at most the one not-found message line, and no timed line otherwise; <= 3 requests per lyric host within 60 s of nav",
                checks, evidence, ("N",))
        if synced and scenarios["NoLyrics"]["status"] == "fail":
            scenarios["NoLyrics"]["reason"] = "track unexpectedly has synced lyrics"

if "Coverage" in selected:
    ev = ev_by.get("V", [])
    smp = samples_of(ev)
    tracks = []
    for v in config["coverageTracks"]:
        nav = first(ev, "lyrics-nav", lambda e, v=v: e.get("v") == v)
        win = [s for t, s in smp if nav and nav["t"] <= t <= nav["t"] + 20000 and s.get("v") == v]
        state = "synced" if any(is_synced(s) for s in win) else "plain" if any(s.get("lines", 0) > 0 for s in win) else "none"
        tracks.append({"v": v, "navigated": nav is not None, "result": state})
    n = sum(t["result"] == "synced" for t in tracks)
    verdict("Coverage", "synced lines within 20 s of navigation on at least 16 of the 20 frozen tracks",
            {"atLeast16of20": n >= 16}, {"synced": n, "tracks": tracks}, ("V",))

STYLE_PROBES = ("player", "player2", "home")


def style_probe(arm, name):
    e = first(ev_by.get(arm, []), "style-probe", lambda e: e.get("name") == name)
    r = e.get("r") if e else None
    return r if isinstance(r, dict) and isinstance(r.get("elements"), dict) else None


def style_flat(r, attributes=True):
    """Flattens a probe to {key: value}. Keys: el|<selector>|<property>, var|<name>, <html|body>|class, <html|body>|attr|<name>."""
    flat = {}
    for sel, props in r["elements"].items():
        if props is None:
            flat[f"el|{sel}"] = None
        else:
            for p, v in props.items():
                flat[f"el|{sel}|{p}"] = v
    for n, v in (r.get("rootVars") or {}).items():
        flat[f"var|{n}"] = v
    for node in ("html", "body"):
        d = r.get(node)
        flat[f"{node}|class"] = None if d is None else " ".join(d.get("classes") or [])
        if attributes and d is not None:
            for n, v in (d.get("attributes") or {}).items():
                if n == "style" and isinstance(v, str):
                    # Frozen exclusion: @braccato/core writes --blyrics-padding-top/bottom inline on <html>; fork-only variables.
                    v = ";".join(x.strip() for x in v.split(";") if x.strip() and not x.strip().startswith("--blyrics-")) or None
                if n != "class" and v is not None:
                    flat[f"{node}|attr|{n}"] = v
    return flat


def style_diff(a, b):
    return sorted(k for k in set(a) | set(b) if a.get(k, "<absent>") != b.get(k, "<absent>"))


if "StyleIsolation" in selected:
    checks, diffs, ignored, sheets = {}, {}, {}, {}
    for name in STYLE_PROBES:
        s, c2, c3 = style_probe("S", name), style_probe("C2", name), style_probe("C3", name)
        if s is None or c2 is None:
            checks[f"identical_{name}"] = None
            continue
        fs, f2 = style_flat(s), style_flat(c2)
        # Only html/body attributes may be ignored, and only those that also differ between the two lyrics-off runs.
        vol = [k for k in style_diff(f2, style_flat(c3)) if "|attr|" in k] if c3 is not None else []
        ignored[name] = vol
        d = [k for k in style_diff(fs, f2) if k not in vol]
        # Post-red-run amendments (protocol): with the Lyrics tab selected in only one arm, #tab-renderer (the fork's host) and the
        # tab headers' selected/unselected colours are not comparable; data-extjs-extension-base is the bundler runtime's base-URL marker.
        if "MUSIC_PAGE_TYPE_TRACK_LYRICS" in (s.get("tabRendererPageType"), c2.get("tabRendererPageType")):
            d = [k for k in d if not k.startswith(("el|#tab-renderer", "el|tp-yt-paper-tab["))]
        d = [k for k in d if k != "html|attr|data-extjs-extension-base"]
        diffs[name] = [{"key": k, "lyricsOn": fs.get(k, "<absent>"), "lyricsOff": f2.get(k, "<absent>")} for k in d]
        sheets[name] = {"S": s.get("extensionSheets"), "C2": c2.get("extensionSheets"), "pathS": s.get("path"), "pathC2": c2.get("path"),
                        "tabRendererPageTypeS": s.get("tabRendererPageType"), "tabRendererPageTypeC2": c2.get("tabRendererPageType")}
        checks[f"identical_{name}"] = not d
    captures = sorted(f for f in os.listdir(out) if f.startswith("style-lyrics-") and f.endswith(".png"))
    verdict("StyleIsolation", "for probes player, player2 and home: every probed computed property, every --yt* :root custom property, "
            "and html/body classes and attributes identical between S (lyrics on) and C2 (lyrics off); only html/body attributes that also "
            "differ between C2 and C3 (both lyrics off) are ignored, and --blyrics-* declarations are removed from html/body inline style",
            checks, {"differences": diffs, "ignoredVolatileKeys": ignored, "context": sheets, "captures": captures,
                     "c3Present": {n: style_probe("C3", n) is not None for n in STYLE_PROBES}}, ("S", "C2"))

if "Smoke" in selected:
    m = summary.get("M", {})
    extra = extra_hosts("M")
    checks = {"1_load": bool(m.get("load", {}).get("loaded")), "2_lyrics": bool(m.get("lyricsOk")),
              "noProcessFailed": "lyrics-process-failed" not in (m.get("containment") or {}).get("badEvents", []),
              "hostsInAllowlist": None if extra is None else not (set(extra) - LYRIC_HOSTS)}
    verdict("Smoke", "rules 1-2, no ProcessFailed; Smoke-arm hosts minus control hosts (googlevideo ignored) within {api.betterlyrics.org, lrclib.net, a.nel.cloudflare.com}",
            checks, {"load": m.get("load"), "extraHosts": extra}, ("M",), needs_control=True)

json.dump(hosts_out, open(os.path.join(out, "hosts.json"), "w", encoding="utf-8"), indent=1)
json.dump(summary, open(os.path.join(out, "summary.json"), "w", encoding="utf-8"), indent=1,
          default=lambda o: dict(o) if isinstance(o, Counter) else str(o))
report = {"stamp": config["stamp"], "command": config.get("command"), "protocol": "scripts/lyrics-e2e-protocol.md",
          "extensionId": EXPECTED_ID, "fingerprint": config.get("fingerprint"), "scenarios": scenarios,
          "pass": bool(scenarios) and all(s["status"] == "pass" for s in scenarios.values())}
json.dump(report, open(os.path.join(out, "report.json"), "w", encoding="utf-8"), indent=1, default=str)
print(json.dumps({k: v["status"] for k, v in scenarios.items()}, indent=1))
