/* Rev TechingMaster Windows 版 · preload
 * 经 contextBridge 暴露给沙箱化 renderer（contextIsolation:true / sandbox:true）：
 *  - saveFile(name, Uint8Array) → {canceled, path}  系统"另存为"对话框 + 写盘
 *  - skeleton() → Uint8Array       读取 ppt 骨架模板（renderer 侧 JSZip 注入页用）
 *
 * 消息通知（对应鸿蒙 NotifySlot.ets + GenTask.ets）：
 *  - notify(payload) → {ok, slotKey, featureId, replaced}
 *      弹出"生成完成/失败"系统通知。payload:
 *        { kind:'done'|'fail'|'running', featureKey:'plan'|…, featureId:7101,
 *          title, body, tag }
 *      featureKey/featureId 决定"归并槽位"：同一功能重复生成时，主进程会先
 *      close() 掉上一条同槽位通知再显示新的（= 鸿蒙固定 notifyId 的覆盖语义），
 *      因此不会堆叠。
 *  - notifyEnabled() → {enabled}    系统通知是否可用（不可用时界面可降级提示）
 *  - notifyState() → {appId, notifyIds, live, log}  诊断用
 *  - clearNotify(featureKey?)       关闭指定（或全部）通知
 *  - onFocusFeature(fn)             点击通知后主进程下发"跳到某功能页"事件；
 *                                   返回取消订阅函数（组件卸载时可调用）
 *
 * 所有通道都用 ipcRenderer.invoke（Promise 语义），renderer 侧可用 .catch 兜底，
 * 不会因为通知失败而打断生成流程。
 */
const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('rtmNative', {
  saveFile: (name, data) => ipcRenderer.invoke('rtm:saveFile', name, data),
  skeleton: () => ipcRenderer.invoke('rtm:skeleton'),

  /* ---------- 系统通知（Windows toast） ---------- */
  notify: (payload) => ipcRenderer.invoke('rtm:notify', payload),
  notifyEnabled: () => ipcRenderer.invoke('rtm:notify-enabled'),
  notifyState: () => ipcRenderer.invoke('rtm:notify-state'),
  clearNotify: (featureKey) => ipcRenderer.invoke('rtm:notify-clear', featureKey),

  /**
   * 订阅"点击通知 → 跳到对应功能页"。
   * 只把 featureKey 字符串交给 renderer，不透传任何 Electron 对象，
   * 保持 contextIsolation 的安全边界。
   */
  onFocusFeature: (fn) => {
    if (typeof fn !== 'function') return () => {};
    const handler = (_event, featureKey) => {
      try { fn(String(featureKey == null ? '' : featureKey)); } catch (e) { /* 忽略订阅方异常 */ }
    };
    ipcRenderer.on('rtm:focus-feature', handler);
    return () => { ipcRenderer.removeListener('rtm:focus-feature', handler); };
  }
});
