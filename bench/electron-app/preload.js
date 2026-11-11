const { contextBridge, ipcRenderer } = require('electron');
contextBridge.exposeInMainWorld('bench', {
  submit: (d) => ipcRenderer.invoke('submit', d),
  exportReport: () => ipcRenderer.invoke('export'),
});
