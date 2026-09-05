/**
 * Rev TechingMaster 电脑版（Electron 主进程）
 * 布局：左侧工具栏 + 右侧工具页面（在 renderer/index.html 中实现）
 */
const { app, BrowserWindow } = require('electron');
const path = require('path');

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
      sandbox: true
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
