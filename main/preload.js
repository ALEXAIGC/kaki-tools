const { contextBridge, ipcRenderer } = require('electron')

contextBridge.exposeInMainWorld('kaki', {
  getHistory: () => ipcRenderer.invoke('history:get'),
  activate: (id, opts) => ipcRenderer.send('item:activate', id, opts || {}),
  remove: id => ipcRenderer.send('item:delete', id),
  togglePin: id => ipcRenderer.send('item:pin', id),
  hide: () => ipcRenderer.send('panel:hide'),
  itemContext: (id, currentBoard) => ipcRenderer.send('item:context', id, currentBoard || null),
  boardContext: name => ipcRenderer.send('board:context', name),
  createBoard: payload => ipcRenderer.send('board:create', payload),
  renameBoard: payload => ipcRenderer.send('board:rename', payload),
  onUpdate: cb => ipcRenderer.on('history:updated', (_e, data) => cb(data)),
  onShown: cb => ipcRenderer.on('panel-shown', () => cb()),
  onBoardPrompt: cb => ipcRenderer.on('board:prompt', (_e, payload) => cb(payload)),
})
