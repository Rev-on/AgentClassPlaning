/**
 * Rev TechingMaster 电脑版（Electron 主进程）
 * 布局：左侧工具栏 + 右侧工具页面（在 renderer/index.html 中实现）
 */
const { app, BrowserWindow, ipcMain, dialog } = require('electron');
const path = require('path');
const fs = require('fs');

// renderer 侧保存文档（Word/PPT 导出）与读取 ppt 骨架模板
ipcMain.handle('rtm:saveFile', async (event, name, data) => {
  const ext = path.extname(String(name || ''));
  const filters = ext === '.pptx'
    ? [{ name: 'PowerPoint', extensions: ['pptx'] }]
    : ext === '.docx'
      ? [{ name: 'Word', extensions: ['docx'] }]
      : [{ name: 'All Files', extensions: ['*'] }];
  const { canceled, filePath } = await dialog.showSaveDialog({
    title: '导出文档',
    defaultPath: name,
    filters
  });
  if (canceled || !filePath) return { canceled: true, path: '' };
  fs.writeFileSync(filePath, Buffer.from(data));
  return { canceled: false, path: filePath };
});
ipcMain.handle('rtm:skeleton', () => {
  const p = path.join(__dirname, 'renderer', 'pptskel.pptx');
  const buf = fs.readFileSync(p);
  return new Uint8Array(buf);
});

function createWindow() {
  const win = new BrowserWindow({
    width: 1360,
    height: 860,
    minWidth: 1060,
    minHeight: 680,
    title: 'Rev TechingMaster',
    autoHideMenuBar: true,
    backgroundColor: '#f2f4f8',
    webPreferences: {
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      preload: path.join(__dirname, 'renderer', 'preload.js')
    }
  });
  win.setMenuBarVisibility(false);
  // 外部链接交给系统浏览器打开，不在应用内导航
  const openExternal = (url) => {
    if (/^https?:\/\//i.test(url)) {
      require('electron').shell.openExternal(url);
    }
  };
  win.webContents.setWindowOpenHandler(({ url }) => { openExternal(url); return { action: 'deny' }; });
  win.webContents.on('will-navigate', (event, url) => {
    if (url !== win.webContents.getURL()) {
      event.preventDefault();
      openExternal(url);
    }
  });
  win.loadFile(path.join(__dirname, 'renderer', 'index.html'));
}

app.whenReady().then(() => {
  createWindow();
  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) {
      createWindow();
    }
  });
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') {
    app.quit();
  }
});
