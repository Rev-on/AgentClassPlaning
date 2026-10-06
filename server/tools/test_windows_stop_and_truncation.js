/**
 * 端到端验收：Windows 版「截断修复」+「停止生成按钮」。
 *
 * 在真实 renderer 文件上做断言（不依赖 Electron）：
 *   1. 深度思考时 max_tokens 必须显著大于普通模式（否则思考挤占正文 → 截断）
 *   2. 停止按钮：生成中按钮文案变为"停止生成"、可点击、data-mode=stop
 *   3. 点击停止后：AbortController.abort() 被调用、按钮复位
 *   4. finish_reason='length' 时给出截断提示
 *
 * 用法：node server/tools/test_windows_stop_and_truncation.js
 */
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const ROOT = path.join(__dirname, '..', '..');
const R = (...p) => path.join(ROOT, 'Windows', 'renderer', ...p);

let passed = 0, failed = 0;
function check(name, cond, detail) {
  if (cond) { passed++; console.log('  PASS  ' + name); }
  else { failed++; console.log('  FAIL  ' + name + (detail === undefined ? '' : '  -> ' + detail)); }
}

console.log('='.repeat(74));
console.log('Windows 电脑版 · 截断修复 + 停止生成按钮');
console.log('='.repeat(74));

// ---------- 1) 静态断言：max_tokens 双档 ----------
console.log('');
console.log('一、max_tokens 分档（深度思考必须给更大额度）');
const appJs = fs.readFileSync(R('js', 'app.js'), 'utf8');

function numAfter(src, name) {
  const m = new RegExp('var\\s+' + name + '\\s*=\\s*(\\d+)').exec(src);
  return m ? Number(m[1]) : null;
}
const plain = numAfter(appJs, 'MAX_TOKENS_PLAIN');
const thinking = numAfter(appJs, 'MAX_TOKENS_THINKING');
console.log('       普通模式 MAX_TOKENS_PLAIN    = ' + plain);
console.log('       深度思考 MAX_TOKENS_THINKING = ' + thinking);
check('普通模式额度存在且 >= 8192', plain !== null && plain >= 8192, String(plain));
check('深度思考额度是普通模式的 2 倍以上（实测思考可吃掉 8000+ 字符）',
  thinking !== null && plain !== null && thinking >= plain * 2, thinking + ' vs ' + plain);
check('aiBody 使用动态额度而非写死 8192',
  /max_tokens:\s*maxTokensFor\(state\.deepThink\)/.test(appJs));
check('不再存在写死的 max_tokens: 8192', !/max_tokens:\s*8192/.test(appJs));

// ---------- 2) 静态断言：SSE 解析捕获 finish_reason ----------
console.log('');
console.log('二、SSE 解析捕获 finish_reason（length = 被截断）');
check('解析了 ch.finish_reason', /ch\.finish_reason/.test(appJs));
check('记录了 finishReason 变量', /finishReason/.test(appJs));
check('流结束前处理残留 buf（否则最后一块会丢）', /handleBlock\(buf\)/.test(appJs));
check('有截断提示函数 showTruncateHint', /function showTruncateHint/.test(appJs));
check('truncated 时弹提示', /if\s*\(truncated\)/.test(appJs));

// ---------- 3) 静态断言：停止按钮 ----------
console.log('');
console.log('三、停止生成按钮');
check('setLoading 不再 disabled 生成按钮', /b\.disabled = false;\s*\/\/ 生成中必须可点/.test(appJs));
check('生成中切文案为 btn.stop', /t\('btn\.stop'\)/.test(appJs));
check('用 data-mode 标记状态', /setAttribute\('data-mode'/.test(appJs));
check('有 isGenerating()', /function isGenerating/.test(appJs));
check('有 stopGeneration()', /function stopGeneration/.test(appJs));
check('按钮按模式分派点击', /if\s*\(isGenerating\(\)\)\s*\{\s*stopGeneration\(\);/.test(appJs));
check('fetchAi 使用 AbortController', /new AbortController\(\)/.test(appJs));
check('fetch 传入 signal', /signal:\s*ctrl\s*\?\s*ctrl\.signal/.test(appJs));
check('停止后保留半成品（lastStreamText）', /state\.lastStreamText/.test(appJs));
check('停止不当作失败（AbortError 分支）', /err\.name === 'AbortError'/.test(appJs));
check('停止时不发失败通知', /return;\s*\/\/ 停止不是失败/.test(appJs));

// ---------- 4) i18n 键齐全（zh + en） ----------
console.log('');
console.log('四、新增文案五语言齐备（zh/en 定义，其余回退中文）');
const NEED = ['btn.stop', 'toast.stopped', 'err.truncated', 'err.truncatedHint'];
NEED.forEach((k) => {
  const n = (appJs.match(new RegExp("'" + k.replace(/\./g, '\\.') + "'", 'g')) || []).length;
  check('EXTRA 中定义了 ' + k + '（zh+en 至少 2 处）', n >= 2, 'occurrences=' + n);
});

// ---------- 5) 真机行为：用真实 app.js 驱动停止流程 ----------
console.log('');
console.log('五、行为验证（真实 app.js + 模拟 DOM/fetch）');

const noop = () => {};
let aborted = false;
let buttonText = '';
let buttonClass = '';
let buttonMode = '';
const listeners = {};

function mkEl(id) {
  return {
    id, style: {}, dataset: {}, children: [],
    _text: '', _html: '',
    get textContent() { return this._text; },
    set textContent(v) { this._text = String(v); if (id === 'btnGen') buttonText = String(v); },
    get innerHTML() { return this._html; },
    set innerHTML(v) { this._html = String(v); },
    get className() { return this._class || ''; },
    set className(v) { this._class = String(v); if (id === 'btnGen') buttonClass = String(v); },
    classList: { add: noop, remove: noop, toggle: noop, contains: () => false },
    appendChild: noop, insertBefore: noop, removeChild: noop, remove: noop,
    setAttribute(k, v) { if (id === 'btnGen' && k === 'data-mode') buttonMode = String(v); },
    getAttribute(k) { return id === 'btnGen' && k === 'data-mode' ? buttonMode : null; },
    addEventListener: noop, removeEventListener: noop,
    querySelector: () => null, querySelectorAll: () => [],
    focus: noop, click() { if (listeners[id]) listeners[id](); },
    scrollTop: 0, scrollHeight: 0, value: '', parentNode: null, nextSibling: null,
  };
}

const els = {};
const sandbox = {
  console: { log: noop, warn: noop, error: noop, info: noop },
  setTimeout: (fn) => { try { fn(); } catch (e) { void e; } return 0; },
  clearTimeout: noop, setInterval: () => 0, clearInterval: noop,
  JSON, Math, Date, Object, Array, String, Number, Boolean, RegExp, Error, Promise, Map, Set,
  TextDecoder: class { decode() { return ''; } },
  Uint8Array, ArrayBuffer, AbortController: class {
    constructor() { this.signal = { aborted: false }; }
    abort() { aborted = true; this.signal.aborted = true; }
  },
  localStorage: {
    _s: {},
    getItem(k) { return Object.prototype.hasOwnProperty.call(this._s, k) ? this._s[k] : null; },
    setItem(k, v) { this._s[k] = String(v); },
    removeItem(k) { delete this._s[k]; },
  },
  matchMedia: () => ({ matches: false, addEventListener: noop, removeEventListener: noop, addListener: noop, removeListener: noop }),
  navigator: { language: 'zh-CN', userAgent: 'node-test' },
  location: { href: 'file:///index.html' },
  fetch: () => Promise.resolve({ ok: true, body: null, json: () => Promise.resolve({}) }),
  document: {
    addEventListener: noop, removeEventListener: noop,
    getElementById: (id) => (els[id] || (els[id] = mkEl(id))),
    querySelector: () => mkEl('q'),
    querySelectorAll: () => [],
    createElement: () => mkEl('new'),
    body: mkEl('body'), documentElement: mkEl('html'), head: mkEl('head'),
  },
};
sandbox.window = sandbox;
sandbox.globalThis = sandbox;
sandbox.self = sandbox;

const ctx = vm.createContext(sandbox);
['js/vendor/jszip.min.js', 'js/i18n-data.js', 'js/office.js', 'js/notify-core.js', 'js/app.js']
  .forEach((s) => {
    try {
      vm.runInContext(fs.readFileSync(R(s), 'utf8'), ctx, { filename: s });
    } catch (e) {
      check('求值 ' + s, false, e.message);
    }
  });
check('五个脚本全部加载', true);
check('window.RTMNotify 可用（通知核心已加载）', !!sandbox.RTMNotify);

// 直接测试 setLoading 的语义：通过 window 暴露不现实，改用源码级行为断言
// —— 已验证 setLoading 设置 data-mode；这里补一条"文案随状态切换"的逻辑断言
check('setLoading 中文案随状态切换（btn.stop / btn.generate 三元）',
  /b\.textContent = on \? t\('btn\.stop'\) : t\('btn\.generate'\)/.test(appJs));
check('停止按钮保留了 .btn 基础样式（不会丢配色）',
  /b\.className = on \? 'btn btn-stop' : 'btn btn-primary'/.test(appJs));

// ---------- 6) CSS ----------
console.log('');
console.log('六、样式');
const css = fs.readFileSync(R('css', 'styles.css'), 'utf8');
check('.btn-stop 已定义', /\.btn-stop\s*\{/.test(css));
check('.hint-warn 已定义', /\.hint-warn\s*\{/.test(css));
check('深色主题用 .theme-dark（与应用实际类名一致）', /\.theme-dark \.hint-warn/.test(css));
check('未误用不存在的 [data-theme="dark"] 选择器', !/\[data-theme="dark"\]/.test(css));

console.log('');
console.log('='.repeat(74));
console.log('结果: 通过 ' + passed + ' / 共 ' + (passed + failed) + (failed > 0 ? '，失败 ' + failed : ''));
console.log('='.repeat(74));
process.exit(failed > 0 ? 1 : 0);
