// Local diagnostic: DOM node growth + mutation churn by custom-element owner. Tags only, never text.
// bun sampler.ts <port> <minutes> <out.jsonl> [--gc-at-end]
const [port, minutesArg, outPath] = Bun.argv.slice(2);
const minutes = Number(minutesArg), gcAtEnd = Bun.argv.includes("--gc-at-end");
const targets: any[] = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const page = targets.find(t => t.type === "page" && String(t.url).startsWith("https://music.youtube.com/"));
if (!page) throw new Error("no music page target");
const ws = new WebSocket(page.webSocketDebuggerUrl);
await new Promise((ok, bad) => { ws.onopen = ok; ws.onerror = bad; });
let next = 1; const pending = new Map<number, (v: any) => void>();
ws.onmessage = e => { const m = JSON.parse(String(e.data)); if (m.id && pending.has(m.id)) { pending.get(m.id)!(m); pending.delete(m.id); } };
const send = (method: string, params: object = {}) => new Promise<any>(ok => { const id = next++; pending.set(id, ok); ws.send(JSON.stringify({ id, method, params })); });
const evaluate = async (expression: string) => (await send("Runtime.evaluate", { expression, returnByValue: true, timeout: 5000 })).result?.result?.value;

const install = `(() => {
  if (window.__ntTally) return 'already';
  const tally = window.__ntTally = { added: {}, removed: {}, text: {}, records: 0 };
  const owner = n => { let e = n && n.nodeType === 1 ? n : n && n.parentElement;
    const self = e ? e.localName : '?';
    while (e && !e.localName.includes('-')) e = e.parentElement || (e.getRootNode && e.getRootNode().host) || null;
    return (e ? e.localName : 'doc') + '>' + self; };
  const size = n => n.nodeType === 1 ? 1 + n.getElementsByTagName('*').length : 1;
  const bump = (bag, k, v) => { bag[k] = (bag[k] || 0) + v; };
  new MutationObserver(list => { for (const r of list) { tally.records++;
    if (r.type === 'characterData') { bump(tally.text, owner(r.target), 1); continue; }
    const k = owner(r.target);
    for (const n of r.addedNodes) bump(tally.added, k + (n.nodeType === 1 ? '+' + n.localName : '+#' + n.nodeType), size(n));
    for (const n of r.removedNodes) bump(tally.removed, k + (n.nodeType === 1 ? '+' + n.localName : '+#' + n.nodeType), size(n));
  } }).observe(document, { childList: true, subtree: true, characterData: true });
  return 'installed';
})()`;
const take = `(() => { const t = window.__ntTally; if (!t) return null;
  const top = bag => Object.entries(bag).sort((a, b) => b[1] - a[1]).slice(0, 12);
  const v = document.querySelector('video'), ti = document.querySelector('ytmusic-player-bar span.time-info'),
    sl = document.querySelector('ytmusic-player-bar tp-yt-paper-slider#progress-bar');
  const r = { visibility: document.visibilityState, paused: v ? v.paused : null, t: v ? Math.round(v.currentTime) : null,
    site: ti ? ti.textContent.trim() : null, slider: sl ? sl.getAttribute('aria-valuenow') : null,
    path: location.pathname, records: t.records, added: top(t.added), removed: top(t.removed), text: top(t.text),
    addedTotal: Object.values(t.added).reduce((a, b) => a + b, 0), removedTotal: Object.values(t.removed).reduce((a, b) => a + b, 0) };
  t.added = {}; t.removed = {}; t.text = {}; t.records = 0; return r; })()`;

console.log("install:", await evaluate(install));
const out = Bun.file(outPath).writer();
const t0 = Date.now();
for (let i = 0; Date.now() - t0 < minutes * 60000; i++) {
  await Bun.sleep(30000);
  if (Bun.argv.includes("--gc-each")) await send("HeapProfiler.collectGarbage");
  const dom = (await send("Memory.getDOMCounters")).result;
  const heap = (await send("Runtime.getHeapUsage")).result;
  const churn = await evaluate(take);
  const row = { ts: Date.now(), min: +((Date.now() - t0) / 60000).toFixed(2), nodes: dom?.nodes, listeners: dom?.jsEventListeners, docs: dom?.documents,
    jsMiB: heap ? +(heap.usedSize / 1048576).toFixed(1) : null, churn };
  out.write(JSON.stringify(row) + "\n"); out.flush();
  console.log(row.min, "nodes", row.nodes, "listeners", row.listeners, "js", row.jsMiB, churn?.visibility, "paused", churn?.paused,
    "media", churn?.t, "site", churn?.site, "slider", churn?.slider,
    "added", churn?.addedTotal, "removed", churn?.removedTotal, JSON.stringify(churn?.added?.slice(0, 4)));
}
if (gcAtEnd) {
  await send("HeapProfiler.collectGarbage");
  const dom = (await send("Memory.getDOMCounters")).result, heap = (await send("Runtime.getHeapUsage")).result;
  const row = { afterGc: true, nodes: dom?.nodes, listeners: dom?.jsEventListeners, jsMiB: +(heap.usedSize / 1048576).toFixed(1) };
  out.write(JSON.stringify(row) + "\n"); console.log(JSON.stringify(row));
}
out.end(); ws.close();
