// page-shot.mjs URL OUT.png [seconds] [chrome flags...]: open URL in Chrome, wait, save a screenshot of the
// page as the GPU drew it, and print one JSON line: the WebGL renderer, console errors, requests that failed,
// the page's fps text and window.__result where the page sets one (gl-features.html does).
import { spawn } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
const chrome = { win32: 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
  darwin: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' }[process.platform] || 'google-chrome';
const [url, out, secs = '8', ...flags] = process.argv.slice(2);
const port = 9335, profile = mkdtempSync(join(tmpdir(), 'shot-'));
const child = spawn(chrome, [`--remote-debugging-port=${port}`, `--user-data-dir=${profile}`, '--no-first-run',
  '--no-default-browser-check', '--window-size=1320,860', '--window-position=0,0', ...flags, 'about:blank'], { stdio: 'ignore' });
const sleep = ms => new Promise(r => setTimeout(r, ms));
let ws, id = 0; const waiting = new Map(), errors = [];
const send = (method, params = {}, sessionId) => new Promise((ok, fail) => { waiting.set(++id, { ok, fail }); ws.send(JSON.stringify({ id, method, params, sessionId })); });
try {
  let dbg;
  for (let i = 0; i < 60 && !dbg; i++) { try { dbg = (await (await fetch(`http://127.0.0.1:${port}/json/version`)).json()).webSocketDebuggerUrl; } catch { await sleep(500); } }
  ws = new WebSocket(dbg); await new Promise((ok, fail) => { ws.onopen = ok; ws.onerror = () => fail(new Error('websocket failed')); });
  ws.onmessage = e => { const m = JSON.parse(e.data);
    if (m.method === 'Runtime.consoleAPICalled' && ['error', 'warning'].includes(m.params.type)) errors.push(m.params.args.map(a => a.value ?? a.description).join(' ').slice(0, 300));
    if (m.method === 'Runtime.exceptionThrown') errors.push(String(m.params.exceptionDetails.exception?.description ?? m.params.exceptionDetails.text).slice(0, 300));
    if (m.method === 'Network.responseReceived' && m.params.response.status >= 400) errors.push(`${m.params.response.status} ${m.params.response.url}`);
    if (m.method === 'Log.entryAdded' && m.params.entry.level !== 'info') errors.push(m.params.entry.text.slice(0, 300));
    const w = waiting.get(m.id); if (!w) return; waiting.delete(m.id); m.error ? w.fail(new Error(m.error.message)) : w.ok(m.result); };
  const { targetId } = await send('Target.createTarget', { url: 'about:blank' });
  const { sessionId } = await send('Target.attachToTarget', { targetId, flatten: true });
  await send('Runtime.enable', {}, sessionId); await send('Log.enable', {}, sessionId); await send('Page.enable', {}, sessionId); await send('Network.enable', {}, sessionId);
  await send('Page.navigate', { url }, sessionId); await send('Page.bringToFront', {}, sessionId); await sleep(Number(secs) * 1000);
  const info = await send('Runtime.evaluate', { returnByValue: true, expression: `(() => { const c = document.createElement('canvas'), g = c.getContext('webgl2') || c.getContext('webgl');
    const e = g && g.getExtension('WEBGL_debug_renderer_info'); return { renderer: g ? g.getParameter(e ? e.UNMASKED_RENDERER_WEBGL : g.RENDERER) : 'no webgl',
    fps: (document.getElementById('fps') || {}).textContent || null, result: window.__result }; })()` }, sessionId);
  const shot = await send('Page.captureScreenshot', { format: 'png' }, sessionId);
  writeFileSync(out, Buffer.from(shot.data, 'base64'));
  console.log(JSON.stringify({ ...info.result.value, errors: [...new Set(errors)].slice(0, 20) }));
} finally { try { await send('Browser.close'); } catch {} child.kill(); await sleep(800); try { rmSync(profile, { recursive: true, force: true }); } catch {} }
process.exit(0);
