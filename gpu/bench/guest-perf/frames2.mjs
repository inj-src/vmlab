// frames.mjs [seconds]: frame pacing in Chrome at its normal frame-rate limit. Opens a page with
// a moving, blurred layer, records the time between frames and prints one JSON line.
import { spawn } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
const chrome = { win32: 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
  darwin: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' }[process.platform] || 'google-chrome';
const seconds = Number(process.argv[2] || 10), port = 9334, profile = mkdtempSync(join(tmpdir(), 'frames-'));
const child = spawn(chrome, [`--remote-debugging-port=${port}`, `--user-data-dir=${profile}`, '--no-first-run',
  '--no-default-browser-check', '--disable-backgrounding-occluded-windows', '--disable-renderer-backgrounding',
  '--window-size=1320,860', '--window-position=0,0', 'about:blank'], { stdio: 'ignore' });
const sleep = ms => new Promise(r => setTimeout(r, ms));
let ws, id = 0; const waiting = new Map();
const send = (method, params = {}, sessionId) => new Promise((ok, fail) => { waiting.set(++id, { ok, fail }); ws.send(JSON.stringify({ id, method, params, sessionId })); });
const page = `<body style="margin:0;background:#123"><div id=b style="position:absolute;width:300px;height:300px;border-radius:40px;background:linear-gradient(45deg,#f06,#48f);filter:blur(6px);box-shadow:0 0 60px #000"></div>
<p style="color:#fff;font:20px sans-serif;columns:3;padding:20px">${'The quick brown fox jumps over the lazy dog. '.repeat(120)}</p>`;
try {
  let url;
  for (let i = 0; i < 60 && !url; i++) { try { url = (await (await fetch(`http://127.0.0.1:${port}/json/version`)).json()).webSocketDebuggerUrl; } catch { await sleep(500); } }
  ws = new WebSocket(url); await new Promise((ok, fail) => { ws.onopen = ok; ws.onerror = () => fail(new Error('websocket failed')); });
  ws.onmessage = e => { const m = JSON.parse(e.data), w = waiting.get(m.id); if (!w) return; waiting.delete(m.id); m.error ? w.fail(new Error(m.error.message)) : w.ok(m.result); };
  const { targetId } = await send('Target.createTarget', { url: 'data:text/html,' + encodeURIComponent(page) });
  const { sessionId } = await send('Target.attachToTarget', { targetId, flatten: true });
  await send('Page.bringToFront', {}, sessionId); await sleep(1500);
  const r = await send('Runtime.evaluate', { awaitPromise: true, returnByValue: true, expression: `new Promise(done => {
    const b = document.getElementById('b'), d = []; let last = performance.now(), t0 = last;
    (function tick(t) { b.style.transform = 'translate(' + (500 + 400 * Math.sin(t / 300)) + 'px,' + (250 + 200 * Math.cos(t / 370)) + 'px)';
      window.scrollTo(0, 200 + 200 * Math.sin(t / 500)); d.push([Math.round(performance.timeOrigin + t), +(t - last).toFixed(1)]); last = t;
      t - t0 < ${seconds * 1000} ? requestAnimationFrame(tick) : done(d.slice(2)); })(last); })` }, sessionId);
  const d = r.result.value; console.log(JSON.stringify({frames: d.length, late: d.filter(x => x[1] > 25)}));
} catch (e) { console.log(JSON.stringify({ error: String(e.message || e) })); }
finally { try { await send('Browser.close'); } catch {} await sleep(1000); child.kill(); try { rmSync(profile, { recursive: true, force: true }); } catch {} }
