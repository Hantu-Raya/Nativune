// Leaves the player page for Home while music keeps playing, so later song changes do not change the URL
// (the owner's 0.1.40 tray case). bun home.ts <port> <out.json>. Tags and paths only, never page text.
const [port, outPath] = Bun.argv.slice(2);
const sleep = (ms: number) => new Promise(r => setTimeout(r, ms));
const result: Record<string, unknown> = { ok: false };
try {
  let page: any;
  for (let i = 0; i < 120 && !page; i++) {
    try {
      const targets: any[] = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
      page = targets.find(t => t.type === "page" && String(t.url).startsWith("https://music.youtube.com/"));
    } catch { }
    if (!page) await sleep(500);
  }
  if (!page) throw new Error("no music page target");
  const ws = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise((ok, bad) => { ws.onopen = ok; ws.onerror = bad; });
  let next = 1; const pending = new Map<number, (v: any) => void>();
  ws.onmessage = e => { const m = JSON.parse(String(e.data)); if (m.id && pending.has(m.id)) { pending.get(m.id)!(m); pending.delete(m.id); } };
  const send = (method: string, params: object = {}) => new Promise<any>(ok => { const id = next++; pending.set(id, ok); ws.send(JSON.stringify({ id, method, params })); });
  const evaluate = async (expression: string) => (await send("Runtime.evaluate", { expression, returnByValue: true, timeout: 5000 })).result?.result?.value;
  const state = `(() => { const v = document.querySelector('video'); return { path: location.pathname,
    paused: v ? v.paused : null, t: v ? v.currentTime : null }; })()`;
  let s: any;
  for (let i = 0; i < 90; i++) {
    s = await evaluate(state);
    if (s?.path === "/watch" && s.paused === false && s.t > 3) break;
    await sleep(1000);
  }
  result.before = s;
  if (!(s?.path === "/watch" && s.paused === false)) throw new Error("not playing on /watch");
  // Primary guide entries have no href; click the rendered "Home" item (English profile), as a user would.
  result.click = await evaluate(`(() => {
    const items = [...document.querySelectorAll('ytmusic-guide-entry-renderer tp-yt-paper-item[role=link]')];
    const home = items.find(i => (i.querySelector('.title')?.textContent || '').trim() === 'Home');
    if (!home) return 'no-home:' + items.length;
    home.click(); return 'clicked'; })()`);
  for (let i = 0; i < 20; i++) {
    await sleep(500);
    s = await evaluate(state);
    if (s?.path !== "/watch") break;
  }
  await sleep(3000);
  const after = await evaluate(state);
  result.after = after;
  result.ok = after?.path === "/" && after.paused === false && after.t > (result.before as any).t;
  ws.close();
} catch (e) { result.error = String(e); }
await Bun.write(outPath, JSON.stringify(result));
console.log(JSON.stringify(result));
process.exit(result.ok ? 0 : 1);
