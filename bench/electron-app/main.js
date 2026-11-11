// Bench Form: a tiny Electron app used to score computer-use MCPs.
// Every action lands in a JSON file so the harness can verify it over SSH.
const { app, BrowserWindow, ipcMain, dialog } = require('electron');
const fs = require('fs');
const path = require('path');
const os = require('os');

const outDir = process.env.BENCH_DIR || path.join(os.homedir(), 'bench');
fs.mkdirSync(outDir, { recursive: true });

function createWindow() {
  const win = new BrowserWindow({
    width: 720, height: 560, title: 'Bench Form',
    webPreferences: { preload: path.join(__dirname, 'preload.js') },
  });
  win.loadFile('index.html');
}

ipcMain.handle('submit', (_e, data) => {
  fs.writeFileSync(path.join(outDir, 'electron-result.json'), JSON.stringify(data, null, 2));
  return 'Saved';
});

ipcMain.handle('export', async (e) => {
  const win = BrowserWindow.fromWebContents(e.sender);
  const r = await dialog.showSaveDialog(win, {
    title: 'Export report', defaultPath: path.join(outDir, 'report.txt'),
  });
  if (r.canceled || !r.filePath) return 'Cancelled';
  fs.writeFileSync(r.filePath, 'bench export ok\n');
  return 'Exported to ' + r.filePath;
});

app.whenReady().then(createWindow);
app.on('window-all-closed', () => app.quit());
