/* Rev TechingMaster Windows 版 · preload
 * 经 contextBridge 暴露给沙箱化 renderer：
 *  - saveFile(name, Uint8Array) → {canceled, path}  系统"另存为"对话框 + 写盘
 *  - skeleton() → Uint8Array       读取 ppt 骨架模板（renderer 侧 JSZip 注入页用）
 */
const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('rtmNative', {
  saveFile: (name, data) => ipcRenderer.invoke('rtm:saveFile', name, data),
  skeleton: () => ipcRenderer.invoke('rtm:skeleton')
});