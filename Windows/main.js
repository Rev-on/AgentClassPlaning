/**
 * Agent备课（Rev TechingMaster 电脑版）Electron 主进程
 * 布局：左侧工具栏 + 右侧工具页面（在 renderer/index.html 中实现）
 *
 * 本文件同时承担"Windows 通知中心"的职责，对应鸿蒙侧的
 * entry/src/main/ets/common/NotifySlot.ets（通知渠道）+ GenTask.ets（固定通知 ID）：
 *   · renderer 沙箱化（contextIsolation:true / sandbox:true），因此通知统一经
 *     preload 的 contextBridge 走 IPC（rtm:notify）到主进程，由 Electron 的
 *     Notification 弹出系统通知；
 *   · Windows toast 不能按数字 id 寻址，改用"功能 key → 存活 Notification 实例"
 *     表实现鸿蒙 notifyId 的**覆盖**语义：同一功能发新通知前先 close() 旧的，
 *     重复生成绝不堆叠。
 */

const electron = require('electron');
const path = require('path');
const fs = require('fs');

const { app, BrowserWindow, ipcMain, dialog, Notification, nativeImage, shell } = electron;

/** 应用标识：与 package.json 的 build.appId / 安装器保持一致 */
const APP_ID = 'com.rev.techingmaster';
/** 窗口标题与 Windows 通知归属名 */
const APP_TITLE = 'Agent备课';

/**
 * Windows toast 与其它平台不同：必须先在系统中注册一个 AppUserModelID，
 * 系统才知道这条通知该挂在哪个应用名下（否则会显示成 "electron.app.xxx"，
 * 通知中心里也找不到归属）。必须在 app ready **之前**调用才生效。
 *
 * ⚠️ 实测坑（Electron 20 上必现）：在 main.js 的模块顶层直接解构/调用
 * `require('electron').app` 会拿到 undefined，触发
 *   TypeError: Cannot read properties of undefined (reading 'setAppUserModelId')
 * 并让主进程在启动瞬间崩溃（窗口完全打不开）。
 * 因此这里把 AppUserModelID 的设置推迟到 whenReady 里执行，
 * 并对 app 缺失做防御，保证任何情况下都只是"少设置一个 id"而不是崩溃。
 */
function ensureAppUserModelId() {
  try {
    if (app && typeof app.setAppUserModelId === 'function') {
      app.setAppUserModelId(APP_ID);
    }
  } catch (e) {
    console.warn('[app] setAppUserModelId 失败（已忽略）:', e && e.message ? e.message : e);
  }
}

/* ============================================================
 * 生成结果通知（Windows 版通知中心）
 * ============================================================ */

/**
 * 逐功能固定通知 ID —— 与鸿蒙 entry/src/main/ets/common/GenTask.ets 的
 * NOTIFY_IDS 完全一致（plan=7101 … report=7107，兜底 7199）。
 *
 * 桌面侧并不向系统传这个数字（toast 无 id 概念），它的作用是：
 *   1. 作为主进程与 renderer 共同遵守的**槽位契约**，语义与鸿蒙一致；
 *   2. 记入日志，便于把 Windows 通知与鸿蒙侧推送对账；
 *   3. 让回归测试可以直接断言 id 映射没有漂移。
 */
const NOTIFY_IDS = Object.freeze({
  plan: 7101,
  courseware: 7102,
  quiz: 7103,
  research: 7104,
  analysis: 7105,
  talk: 7106,
  report: 7107
});
const NOTIFY_ID_FALLBACK = 7199;
/** 与鸿蒙 NotifySlot.ets 渠道 desc 对齐（Windows 通知无法自定义渠道名，记日志用） */
const NOTIFY_CHANNEL_DESC = 'AI 生成完成提醒';

/** 未知功能统一落到兜底槽位，保证"同一功能只占一条通知" */
const NOTIFY_KEY_FALLBACK = 'id:' + NOTIFY_ID_FALLBACK;

function notifyIdFor(featureKey) {
  const k = String(featureKey == null ? '' : featureKey);
  return Object.prototype.hasOwnProperty.call(NOTIFY_IDS, k) ? NOTIFY_IDS[k] : NOTIFY_ID_FALLBACK;
}
function notifyKeyFor(featureKey) {
  const k = String(featureKey == null ? '' : featureKey);
  return Object.prototype.hasOwnProperty.call(NOTIFY_IDS, k) ? 'id:' + NOTIFY_IDS[k] : NOTIFY_KEY_FALLBACK;
}

/**
 * 存活通知表：slotKey → Notification。
 * 这就是鸿蒙 notifyId 覆盖语义在桌面端的等价实现。
 */
const liveNotifications = new Map();
/** 环形日志：便于"通知到底发了没有"的现场排查（不落盘，纯内存） */
const notifyLog = [];
const NOTIFY_LOG_MAX = 50;
function logNotify(entry) {
  notifyLog.push(Object.assign({ at: new Date().toISOString() }, entry));
  if (notifyLog.length > NOTIFY_LOG_MAX) notifyLog.shift();
  // 主进程控制台，便于 `npm start` 时肉眼确认
  console.log('[notify]', JSON.stringify(entry));
}

/** 应用图标：通知左侧显示的小图 + 任务栏图标（构建时由 build/icon.ico 生成） */
function resolveAppIcon() {
  const candidates = [
    path.join(__dirname, 'renderer', 'icon.png'),
    path.join(__dirname, 'build', 'icon.ico')
  ];
  for (const p of candidates) {
    try {
      if (!fs.existsSync(p)) continue;
      const img = nativeImage.createFromPath(p);
      if (img && !img.isEmpty()) return img;
    } catch (e) {
      // 图标只是装饰：任何失败都忽略，绝不阻塞启动/发通知
    }
  }
  return null;
}

/**
 * 关闭某个槽位上仍在显示的通知（鸿蒙"新通知覆盖旧通知"的桌面等价物）。
 * 幂等 + 容错：实例可能已被系统关闭或已过期，close() 抛错也不影响新通知。
 */
function closeSlot(slotKey) {
  const prev = liveNotifications.get(slotKey);
  if (!prev) return false;
  liveNotifications.delete(slotKey);
  try {
    if (!prev.isDestroyed || !prev.isDestroyed()) prev.close();
  } catch (e) {
    // 已被系统回收：忽略
  }
  return true;
}

/** 把窗口带到前台：恢复最小化 + show + focus（点击通知的期望行为） */
function focusMainWindow(targetFeatureKey) {
  const wins = BrowserWindow.getAllWindows();
  if (wins.length === 0) {
    createWindow();
    return;
  }
  const win = wins[0];
  try {
    if (win.isMinimized()) win.restore();
    if (!win.isVisible()) win.show();
    win.focus();
    // 让界面直接跳到对应工具页（renderer 侧监听 rtm:focus-feature）
    if (targetFeatureKey) win.webContents.send('rtm:focus-feature', String(targetFeatureKey));
  } catch (e) {
    console.warn('[notify] 聚焦窗口失败:', e && e.message ? e.message : e);
  }
}

/**
 * 显示一条系统通知。
 * 与鸿蒙 NotifySlot/EntryAbility 的容错策略一致：通知是增强项，
 * 任何失败只记日志，绝不抛出、绝不影响生成流程。
 */
function showNotification(payload) {
  const p = payload && typeof payload === 'object' ? payload : {};
  const featureKey = String(p.featureKey || 'unknown');
  const slotKey = notifyKeyFor(featureKey);
  const id = typeof p.featureId === 'number' ? p.featureId : notifyIdFor(featureKey);
  const title = String(p.title == null ? '' : p.title);
  const body = String(p.body == null ? '' : p.body);

  if (!title && !body) {
    logNotify({ kind: p.kind, featureKey, featureId: id, shown: false, reason: 'empty-payload' });
    return { ok: false, skipped: 'empty-payload' };
  }

  // 系统层面是否支持通知（Windows 上恒为 true；某些精简系统可能为 false）
  let supported = true;
  try {
    supported = Notification.isSupported();
  } catch (e) {
    supported = true;
  }
  if (!supported) {
    logNotify({ kind: p.kind, featureKey, featureId: id, shown: false, reason: 'unsupported' });
    return { ok: false, skipped: 'unsupported' };
  }

  // 先覆盖同槽位的旧通知，保证同一功能永远只占一条
  const replaced = closeSlot(slotKey);

  try {
    const opts = { title, body, silent: false };
    const icon = resolveAppIcon();
    if (icon) opts.icon = icon;
    const n = new Notification(opts);

    n.on('click', () => {
      logNotify({ kind: p.kind, featureKey, featureId: id, clicked: true });
      focusMainWindow(featureKey);
    });
    n.on('close', () => {
      // 只有仍是"当前槽位持有者"时才清表，避免误删后来居上的新通知
      if (liveNotifications.get(slotKey) === n) liveNotifications.delete(slotKey);
    });
    n.on('failed', (event, error) => {
      console.warn('[notify] 通知投递失败:', error || event);
    });

    n.show();
    liveNotifications.set(slotKey, n);
    logNotify({
      kind: p.kind, featureKey, featureId: id, slotKey, replaced,
      shown: true, channelDesc: p.channelDesc || NOTIFY_CHANNEL_DESC
    });
    return { ok: true, slotKey, featureId: id, replaced };
  } catch (e) {
    const msg = e && e.message ? e.message : String(e);
    console.warn('[notify] 显示通知失败（已忽略，不影响生成）:', msg);
    logNotify({ kind: p.kind, featureKey, featureId: id, shown: false, reason: 'error', error: msg });
    return { ok: false, error: msg };
  }
}

/* ============================================================
 * IPC：renderer → 主进程
 *
 * ⚠️ 这些 handler 必须在 app ready 之后注册（见 registerIpcHandlers）。
 * 与 ensureAppUserModelId 同一个坑：Electron 20 下模块顶层拿到的
 * `ipcMain` 可能是 undefined，顶层注册会直接崩主进程。
 * ============================================================ */

function registerIpcHandlers() {
  /**
   * rtm:notify —— 弹出"生成完成/失败/生成中"系统通知。
   * 复用鸿蒙行为：固定 id 覆盖、点击回到对应功能页。
   */
  ipcMain.handle('rtm:notify', (event, payload) => {
    // 系统层面通知不可用：静默跳过（不报错、不打扰）
    try {
      if (typeof Notification.isSupported === 'function' && !Notification.isSupported()) {
        return { ok: false, skipped: 'disabled' };
      }
    } catch (e) {
      // 判定失败也继续尝试投递，避免误伤
    }
    return showNotification(payload);
  });

  /** rtm:notify-enabled —— renderer 可据此决定是否展示"通知不可用"提示 */
  ipcMain.handle('rtm:notify-enabled', () => {
    try {
      return { enabled: Notification.isSupported() };
    } catch (e) {
      return { enabled: false };
    }
  });

  /** rtm:notify-state —— 诊断：最近的通知日志 + 当前存活槽位 */
  ipcMain.handle('rtm:notify-state', () => ({
    appId: APP_ID,
    title: APP_TITLE,
    channelDesc: NOTIFY_CHANNEL_DESC,
    notifyIds: NOTIFY_IDS,
    fallbackId: NOTIFY_ID_FALLBACK,
    live: Array.from(liveNotifications.keys()),
    log: notifyLog.slice(-20)
  }));

  /** rtm:notify-clear —— 关闭指定槽位（或全部）通知 */
  ipcMain.handle('rtm:notify-clear', (event, featureKey) => {
    if (featureKey === undefined || featureKey === null || featureKey === '') {
      const keys = Array.from(liveNotifications.keys());
      keys.forEach((k) => closeSlot(k));
      return { ok: true, closed: keys };
    }
    const slotKey = notifyKeyFor(featureKey);
    return { ok: true, closed: closeSlot(slotKey) ? [slotKey] : [] };
  });

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
}

function createWindow() {
  const appIcon = resolveAppIcon();
  const win = new BrowserWindow({
    width: 1360,
    height: 860,
    minWidth: 1060,
    minHeight: 680,
    title: APP_TITLE,
    autoHideMenuBar: true,
    backgroundColor: '#f2f4f8',
    ...(appIcon ? { icon: appIcon } : {}),
    webPreferences: {
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      preload: path.join(__dirname, 'renderer', 'preload.js')
    }
  });
  // 立即显示：某些显卡/远程桌面环境下不显式 show() 会呈现"进程在跑但看不到窗口"。
  win.show();
  win.setMenuBarVisibility(false);
  // 渲染页 <title> 不允许覆盖窗口标题（index.html 由另一位队友维护，
  // 这里在主进程侧兜底，保证任务栏/窗口标题恒为 App 名）
  win.on('page-title-updated', (event) => {
    event.preventDefault();
    if (win.getTitle() !== APP_TITLE) win.setTitle(APP_TITLE);
  });
  // 关闭窗口即释放该窗口的所有存活通知，避免退出后残留"幽灵 toast"
  win.on('closed', () => {
    Array.from(liveNotifications.keys()).forEach((k) => closeSlot(k));
  });
  // 外部链接交给系统浏览器打开，不在应用内导航
  const openExternal = (url) => {
    if (/^https?:\/\//i.test(url)) {
      shell.openExternal(url);
    }
  };
  try {
    win.webContents.setWindowOpenHandler(({ url }) => { openExternal(url); return { action: 'deny' }; });
    win.webContents.on('will-navigate', (event, url) => {
      if (url !== win.webContents.getURL()) {
        event.preventDefault();
        openExternal(url);
      }
    });
  } catch (e) {
    console.error('[app] 绑定导航守卫失败（不影响使用）:', e && e.message ? e.message : e);
  }
  // 加载失败必须让人看得见：否则表现为"双击没反应"。
  win.loadFile(path.join(__dirname, 'renderer', 'index.html')).catch((e) => {
    const msg = e && e.message ? e.message : String(e);
    console.error('[app] 页面加载失败: ' + msg);
    try {
      dialog.showErrorBox('Agent备课 启动失败',
        '无法加载界面文件：\n' + msg + '\n\n请重新安装，或把本提示反馈给开发者。');
    } catch (e2) { /* 对话框失败也不能再抛 */ }
  });
}

/**
 * 主进程启动。
 *
 * 顺序很重要：先注册 IPC，再建窗口（renderer 一加载就可能发 rtm:notify）。
 * 所有 Electron 对象的访问都放在 ready 之后 —— 见 ensureAppUserModelId 的注释。
 */
if (app && typeof app.whenReady === 'function') {
  /**
   * 单实例锁。
   *
   * 为什么需要：电脑版常被"桌面快捷方式连点两下"。没有锁时第二个实例会尝试
   * 打开第二个窗口并争抢同一个 userData 目录，在部分机器上表现为启动异常。
   * 有锁时第二个实例直接退出，并唤起已有窗口 —— 符合桌面软件的习惯。
   *
   * 注意：若上一个进程变成僵尸（用户看到"双击没反应"），锁会挡住新实例。
   * 因此这里在拿不到锁时仍然把已存在窗口拉到前台，用户不会"点了没动静"。
   */
  let gotLock = true;
  try {
    if (typeof app.requestSingleInstanceLock === 'function') {
      gotLock = app.requestSingleInstanceLock();
    }
  } catch (e) {
    console.warn('[app] 单实例锁不可用，继续启动:', e && e.message ? e.message : e);
  }

  if (!gotLock) {
    console.warn('[app] 已有实例在运行，本实例退出并唤起已有窗口');
    app.quit();
    return;
  }

  app.on('second-instance', () => {
    try {
      const wins = BrowserWindow.getAllWindows();
      if (wins.length) {
        const w = wins[0];
        if (w.isMinimized && w.isMinimized()) w.restore();
        w.show();
        w.focus();
      }
    } catch (e) {
      console.warn('[app] 唤起已有窗口失败:', e && e.message ? e.message : e);
    }
  });

  app.whenReady().then(() => {
    try {
      registerIpcHandlers();
    } catch (e) {
      console.error('[app] IPC 注册失败:', e && e.message ? e.message : e);
    }
    ensureAppUserModelId();
    // 建窗口单独兜底：若这里抛错而无人接管，结果是"进程活着但没有任何窗口"，
    // 用户看到的就是"双击没反应"。因此必须把失败弹出来，而不是只写日志。
    try {
      createWindow();
    } catch (e) {
      const msg = e && e.message ? e.message : String(e);
      console.error('[app] 创建窗口失败:', msg);
      try {
        dialog.showErrorBox('Agent备课 启动失败',
          '窗口创建失败：\n' + msg + '\n\n请重新安装，或把本提示反馈给开发者。');
      } catch (e2) { /* 忽略 */ }
      app.quit();
      return;
    }
    app.on('activate', () => {
      if (BrowserWindow.getAllWindows().length === 0) {
        createWindow();
      }
    });
  }).catch((e) => {
    const msg = e && e.message ? e.message : String(e);
    console.error('[app] whenReady 失败:', msg);
    // ready 都失败了就绝无可能出窗口，直接提示并退出，避免"无窗口僵尸进程"
    try {
      dialog.showErrorBox('Agent备课 启动失败', '应用初始化失败：\n' + msg);
    } catch (e2) { /* 忽略 */ }
    app.quit();
  });

  app.on('window-all-closed', () => {
    if (process.platform !== 'darwin') {
      app.quit();
    }
  });
} else {
  // 非 Electron 环境（例如被 Node 直接 require 做静态检查）：不启动 GUI
  console.warn('[app] 未检测到 Electron app 对象，跳过硬初始化');
}

