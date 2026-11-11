// gpu-bench.mjs: start Chrome, run bench.html and print one JSON line with the GPU Chrome uses
// and the frame rates. Needs Node 22+ (built-in WebSocket) and a visible desktop session.
//   node gpu-bench.mjs [path/to/chrome] [seconds per test]
// Environment: BENCH_TESTS="fill,draws,upload" picks the tests ("none" only reports the GPU);
// BENCH_CAPPED=1 keeps Chrome's normal frame-rate limit; BENCH_CHROME_FLAGS adds Chrome flags.
import { spawn } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const chrome = process.argv[2] || {
  win32: 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
  darwin: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
}[process.platform] || 'google-chrome';
const seconds = Number(process.env.BENCH_SECONDS || process.argv[3] || 5);
const port = 9333, profile = mkdtempSync(join(tmpdir(), 'gpu-bench-'));
// Uncapped frame rate, and no throttling if the window ends up behind another one.
const uncapped = process.env.BENCH_CAPPED ? [] : ['--disable-gpu-vsync', '--disable-frame-rate-limit'];
const names = (process.env.BENCH_TESTS || 'fill,draws,upload').split(',').filter(n => n && n !== 'none');
const child = spawn(chrome, [`--remote-debugging-port=${port}`, `--user-data-dir=${profile}`, '--no-first-run',
  '--no-default-browser-check', ...uncapped,
  '--disable-backgrounding-occluded-windows', '--disable-renderer-backgrounding',
  '--disable-background-timer-throttling', '--window-size=1320,860', '--window-position=0,0',
  ...(process.env.BENCH_CHROME_FLAGS || '').split(' ').filter(Boolean), 'about:blank'], { stdio: 'ignore' });

const sleep = ms => new Promise(r => setTimeout(r, ms));
let ws, id = 0; const waiting = new Map();
const send = (method, params = {}, sessionId) => new Promise((ok, fail) => {
  waiting.set(++id, { ok, fail }); ws.send(JSON.stringify({ id, method, params, sessionId }));
});
try {
  let url;
  for (let i = 0; i < 60 && !url; i++) {
    try { url = (await (await fetch(`http://127.0.0.1:${port}/json/version`)).json()).webSocketDebuggerUrl; } catch { await sleep(500); }
  }
  if (!url) throw new Error('Chrome did not open its debugging port');
  ws = new WebSocket(url);
  await new Promise((ok, fail) => { ws.onopen = ok; ws.onerror = () => fail(new Error('websocket failed')); });
  ws.onmessage = e => { const m = JSON.parse(e.data), w = waiting.get(m.id); if (!w) return;
    waiting.delete(m.id); m.error ? w.fail(new Error(m.error.message)) : w.ok(m.result); };

  const { targetId } = await send('Target.createTarget', { url: pathToFileURL(join(here, 'bench.html')).href });
  const { sessionId } = await send('Target.attachToTarget', { targetId, flatten: true });
  const evaluate = async expression => {
    const r = await send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true }, sessionId);
    if (r.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description || r.exceptionDetails.text);
    return r.result.value;
  };
  for (let i = 0; i < 40 && !(await evaluate('typeof window.runBench === "function"').catch(() => false)); i++) await sleep(250);
  await send('Page.bringToFront', {}, sessionId);
  const bench = await evaluate(`window.runBench(${seconds * 1000}, ${JSON.stringify(names)})`);
  const info = await send('SystemInfo.getInfo');
  console.log(JSON.stringify({
    platform: process.platform, capped: !uncapped.length, chrome: (await send('Browser.getVersion')).product,
    gpus: info.gpu.devices.map(d => `${d.vendorString} ${d.deviceString} [${d.driverVersion}]`.trim()),
    gl: info.gpu.auxAttributes?.glRenderer, ...bench,
  }));
} catch (e) {
  console.log(JSON.stringify({ error: String(e.message || e) })); process.exitCode = 1;
} finally {
  try { await send('Browser.close'); } catch {}
  await sleep(1500); child.kill(); try { rmSync(profile, { recursive: true, force: true }); } catch {}
}
