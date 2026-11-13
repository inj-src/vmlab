// An Electron app for the d3d12 test: loads venc.html (asks for a hardware video encoder and a
// WebGPU adapter, which make the GPU process load d3d12.dll, then tries WebGL for 20 s) and
// writes what the page logged, and every child process that went away, to --out=FILE.
const { app, BrowserWindow } = require('electron');
const fs = require('fs');
const path = require('path');
const arg = process.argv.find(a => a.startsWith('--out='));
const out = arg ? arg.slice(6) : path.join(app.getPath('temp'), 'etest.txt');
const lines = [];
const log = s => { lines.push(s); fs.writeFileSync(out, lines.join('\n') + '\n'); };
app.on('child-process-gone', (e, d) => log(`child-process-gone type=${d.type} reason=${d.reason} exitCode=${d.exitCode}`));
app.whenReady().then(async () => {
  log(`electron ${process.versions.electron} chrome ${process.versions.chrome} arch ${process.arch}`);
  const w = new BrowserWindow({ width: 1100, height: 600 });
  await w.loadFile(path.join(__dirname, 'venc.html'));
  setTimeout(async () => {
    try { log(await w.webContents.executeJavaScript('document.getElementById("o").textContent')); } catch (e) { log('page read failed: ' + e); }
    log(app.getAppMetrics().filter(p => p.type === 'GPU').map(p => `gpu process pid ${p.pid}`).join(', ') || 'no GPU process');
    log('end');
    app.quit();
  }, 26000);
});
