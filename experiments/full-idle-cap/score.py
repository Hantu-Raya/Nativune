"""Score retained FullIdle evidence, including re-entry and actual applied/released boundaries.

python experiments/full-idle-cap/score.py
Same first Full 90-second window as the maintainer score.py; re-entry uses 75 seconds after 90 seconds quiet.
"""
from __future__ import annotations
import json, os, pathlib, statistics
from typing import Any
ROOT=pathlib.Path(__file__).resolve().parents[2]
OUT=ROOT/'artifacts/full-idle-cap'
MIB=1048576

def percentile(values,p=.95):
    if not values:raise ValueError("Percentile needs samples")
    return sorted(values)[max(0,int(len(values)*p+.999999)-1)]

def cap_at(events,t):
    active=None
    for e in events:
        if e['t']>t:break
        if e['event']=='fullidle-cap':
            if e.get('outcome')=='applied':active=e
            elif e.get('outcome','').startswith('released'):active=None
    return active

def settled_interval(events,start,end):
    """Longest continuously applied interval after 30 seconds settling; no cherry-picking by memory."""
    intervals=[]; applied=None
    for e in events+[{'event':'fullidle-cap','outcome':'released','t':end}]:
        if e['event']!='fullidle-cap':continue
        if e.get('outcome')=='applied':applied=e['t']
        elif e.get('outcome','').startswith('released') and applied is not None:
            a,b=max(start,applied+30000),min(end,e['t'])
            if b-a>=30000:intervals.append((a,b))
            applied=None
    return max(intervals,key=lambda w:w[1]-w[0]) if intervals else None

def phase(samples,events,start,end,enabled,settled=True):
    if start is None or end is None:return None
    rows=[s for s in samples if start<=s['t']<end]
    if len(rows)<30:return {'complete':False,'samples':len(rows)}
    tot=[sum(v[0] for v in s['roles'].values())/MIB for s in rows]
    role_names=sorted({r for s in rows for r in s['roles']})
    role_ws={r:round(statistics.median(s['roles'].get(r,[0])[0]/MIB for s in rows),2) for r in role_names}
    dt=(rows[-1]['t']-rows[0]['t'])/1000
    cpus=[s.get('cpu') for s in rows if s.get('cpu') is not None]
    faults=[]
    for a,b in zip(rows,rows[1:]):
        x,y=a['roles'].get('renderer'),b['roles'].get('renderer')
        # Aggregate PageFaultCount is meaningful only when the one renderer persists (recorded process events below).
        if x and y and x[2]==y[2]==1 and y[3]>=x[3]:faults.append((y[3]-x[3])/((b['t']-a['t'])/1000))
    active=[cap_at(events,s['t']) for s in rows]
    not_settled=[s['t'] for s,c in zip(rows,active) if c and s['t']-c['t']<30000]
    first_cap=cap_at(events,start)
    return {'complete':True,'samples':len(rows),'start':start,'end':end,
            'treeWsMedianMiB':round(statistics.median(tot),2),'treeWsP95MiB':round(percentile(tot),2),'roleWsMedianMiB':role_ws,
            'treeCpuPct':round(100*(cpus[-1]-cpus[0])/dt/os.cpu_count(),4) if len(cpus)>1 else None,
            'rendererTotalFaultsPerS':round(statistics.median(faults),1) if faults else None,
            'rendererTotalFaultsP95PerS':round(percentile(faults),1) if faults else None,
            'capDutyPct':round(100*sum(c is not None for c in active)/len(active),1) if enabled else 0,
            'allAppliedSamplesSettled30S':not not_settled if settled else None,
            'capAgeAtWindowStartS':round((start-first_cap['t'])/1000,3) if first_cap else None}

def screen(path):
    summary=json.loads((path/'summary.json').read_text());events=json.loads((path/'events.json').read_text())
    # Retain only playback clocks/paused/readiness; segment identity is compared locally, never exported.
    raw=ROOT.parents[1]/'.cache/memory-attribution/runs'/f"{summary['utc']}-{path.name}"/'bench.jsonl'
    if raw.exists() and not any(e['event']=='playback-state' for e in events):
        identity=None; segment=0; previous=None
        for line in raw.read_text(encoding='utf-8').splitlines():
            e=json.loads(line)
            if e['event']!='page-stats':continue
            page=e.get('page',{});current=page.get('t')
            if current is None:continue
            if page.get('v')!=identity or previous is not None and current<previous:segment+=1
            identity=page.get('v');previous=current
            events.append({'event':'playback-state','t':e['t'],'currentTime':current,
                           'paused':page.get('paused'),'ready':page.get('ready'),'segment':segment})
        events.sort(key=lambda e:e['t'])
        (path/'events.json').write_text(json.dumps(events,indent=2))
    samples=[json.loads(l) for l in (path/'samples.jsonl').read_text().splitlines() if l]
    first={}
    for e in events:first.setdefault(e['event'],e['t'])
    cap=int(path.name.split('-')[1]); enabled=cap>0
    compact=first.get('compact-requested'); full2=first.get('full-shown'); hide=first.get('hide-requested')
    second_start=full2+90000 if full2 is not None else None
    if second_start:
        applies=[e['t'] for e in events if e['event']=='fullidle-cap' and e.get('outcome')=='applied' and full2<=e['t']<(hide or float('inf'))]
        if applies:second_start=max(second_start,applies[0]+30000)
    phases={
        'full':phase(samples,events,compact-90000 if compact else None,compact,enabled),
        'full2':phase(samples,events,second_start,min(second_start+75000,hide) if second_start and hide else None,enabled),
        'compact':phase(samples,events,first.get('compact-shown',0)+30000,first.get('compact-shown',0)+120000,enabled),
        'tray':phase(samples,events,first.get('hide-done',0)+30000,min(first.get('hide-done',0)+120000,first.get('show-requested',float('inf'))),enabled),
    }
    if enabled and compact:
        interval=settled_interval(events,compact-90000,compact)
        phases['full_settled']=phase(samples,events,*interval,True) if interval else {
            'complete':False,'reason':'No continuous first Full cap interval with >=30 s samples after >=30 s applied settling.'}
    else:phases['full_settled']=phases['full']
    if enabled and full2 and hide:
        interval=settled_interval(events,full2,hide)
        phases['full2_settled']=phase(samples,events,interval[0],min(interval[1],interval[0]+90000),True) if interval else {
            'complete':False,'reason':'No continuous Full2 cap interval with >=30 s samples after >=30 s applied settling.'}
    else:phases['full2_settled']=phases['full2']
    cap_events=[e for e in events if e['event'] in ('fullidle-cap','tray-cap')]
    ownership=[e for e in events if e['event']=='webview-input-windows']
    processes={p['pid']:p['kind'] for e in events if e['event']=='process-infos' for p in e['processes']}
    input_windows=[dict(w,role=processes.get(w['pid'])) for e in ownership for w in e['windows']]
    media=[e for e in events if e['event']=='playback-state' and e.get('currentTime') is not None]
    pairs=[(a,b) for a,b in zip(media,media[1:]) if a['segment']==b['segment'] and b['currentTime']>=a['currentTime'] and not a.get('paused') and not b.get('paused')]
    drift=sum((b['currentTime']-a['currentTime'])-(b['t']-a['t'])/1000 for a,b in pairs)
    restored=[e for e in events if e['event']=='renderer-cap-restored']
    score=json.loads((path/'score.json').read_text())
    return {'capMiB':cap,'exit':summary.get('exit'),'playing':summary.get('mediaPlaying'),
        'contaminated':score.get('contaminated'),'phases':phases,'capEvents':cap_events,
        'inputWindows':input_windows,'restoresExact':all(e['exact'] for e in restored),'restoresChecked':len(restored),
        'playbackWithinSegmentDriftS':round(drift,3) if pairs else None,'playbackCheckedWallS':round(sum((b['t']-a['t'])/1000 for a,b in pairs),1),
        'playbackPausedSamples':sum(e.get('paused') is True for e in media),'playbackSegmentCount':len({e['segment'] for e in media}),
        'conventionalScore':score}

def latency(path):
    rows=json.loads((path/'trials.json').read_text()) if (path/'trials.json').exists() else []
    errors=json.loads((path/'latency-errors.json').read_text()) if (path/'latency-errors.json').exists() else []
    result={'trials':len(rows),'gate':'COMPLETE' if len(rows)>=10 and not errors else 'BLOCKED','errors':errors}
    for kind in ('all','wheel','click'):
        selected=[r for r in rows if kind=='all' or r['kind']==kind]
        result[kind]={'trials':len(selected)}
        for column in ('injectionToReleaseMs','injectionToFirstChangedFrameMs'):
            values=[r[column] for r in selected if r[column] is not None]
            result[kind][column]={'n':len(values),'median':round(statistics.median(values),3),'p95':round(percentile(values),3)} if values else None
        gaps=[1000*(b['endQpc']-a['endQpc'])/r['frequency'] for r in selected for a,b in zip(r['frames'],r['frames'][1:])]
        result[kind]['frameIntervalMedianMs']=round(statistics.median(gaps),3) if gaps else None
        result[kind]['frameIntervalP95Ms']=round(percentile(gaps),3) if gaps else None
    result['fixture']='Offline synthetic response band, blank click area and striped scrollable content; no real-site first-input or audible claim.'
    result['controlRelease']='Not applicable: cap=0 has no limit to release.'
    return result

def main():
    results={'screens':{},'latency':{},'limits':['One screen per cap, not paired confidence or long-session qualification.',
        'Muted real-site workload: clocks/paused state do not establish audible continuity.',
        'PageFaultCount includes all faults; this does not distinguish hard vs soft faults.',
        'Frame timestamps bound desktop capture sampling, not a hardware presentation timestamp.']}
    results['limits'] += ['Input heuristic cannot distinguish keyboard from mouse: typing elsewhere with the cursor over Nativune counts as activity.',
        'Fixture latency exercises detection/presentation, not the real Music SPA memory pressure.',
        '80-a orchestration was stopped before input trials to add fresh-target injection guards; its in-flight app was not terminated, but that arm is not used.']
    results['limits'] += ['Memory screens use the frozen pre-b3ac76b prototype build; lifecycle/build/input evidence uses the rebased build.',
        'Broad Full windows include uncapped work after source/input activity; incomplete settled windows are not memory passes.',
        'A few guarded native injections are partial evidence, never the required >=10 trials per arm.']
    for cap in (0,60,80,100):
        candidates=[p for p in OUT.glob(f'fullidle-{cap}-*') if (p/'summary.json').exists() and (p/'score.json').exists()]
        if candidates:
            path=max(candidates,key=lambda p:json.loads((p/'summary.json').read_text())['utc'])
            results['screens'][str(cap)]=dict(screen(path),label=path.name)
    for cap in (0,60):
        candidates=[p for p in OUT.glob(f'fullidle-input-{cap}-*') if (p/'summary.json').exists()
                    and ((p/'trials.json').exists() or (p/'latency-errors.json').exists())]
        if candidates:
            path=max(candidates,key=lambda p:json.loads((p/'summary.json').read_text())['utc'])
            results['latency'][str(cap)]=dict(latency(path),label=path.name)
    (OUT/'results.json').write_text(json.dumps(results,indent=2))
    print(json.dumps({group:{cap:({k:v for k,v in item.items() if k in ('phases','exit','playing','contaminated')} if group=='screens' else item)
        for cap,item in results[group].items()} for group in ('screens','latency')},indent=2))
if __name__=='__main__':main()
