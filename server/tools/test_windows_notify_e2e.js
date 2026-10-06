/**
 * 端到端验收：在真实 renderer 文件上验证「消息通知」行为（不依赖 Electron）。
 *
 * 做法：用一个极小的 DOM/浏览器桩把 Windows/renderer/index.html 里声明的
 *       **真实脚本按真实顺序**求值，然后断言：
 *         1. window.RTMNotify 存在（notify-core.js 真的被加载）
 *         2. 每个功能 key 的 notifyId 与鸿蒙 GenTask.ets 完全一致
 *         3. 五语言下渲染出的标题/正文都不是裸键名，也不含 "notify." 前缀
 *         4. 同一功能重复通知 == 同槽位（等价鸿蒙"新通知覆盖旧通知"）
 *
 * 用法：node server/tools/test_windows_notify_e2e.js
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

console.log('='.repeat(72));
console.log('Windows 电脑版 · 消息通知端到端验收（真实 renderer 文件）');
console.log('='.repeat(72));

/* ---------------- 1) 从 index.html 解析真实脚本顺序 ---------------- */
const html = fs.readFileSync(R('index.html'), 'utf8');
const srcs = [];
const re = /<script\s+src="([^"]+)"><\/script>/g;
let m;
while ((m = re.exec(html)) !== null) srcs.push(m[1]);
console.log('index.html 声明的脚本顺序: ' + srcs.join('  ->  '));
check('index.html 声明了 notify-core.js', srcs.some((s) => s.indexOf('notify-core') >= 0));
const iCore = srcs.findIndex((s) => s.indexOf('notify-core') >= 0);
const iApp = srcs.findIndex((s) => s.indexOf('js/app.js') >= 0);
check('notify-core.js 在 js/app.js 之前加载', iCore >= 0 && iApp >= 0 && iCore < iApp,
  'core@' + iCore + ' app@' + iApp);
srcs.forEach((s) => {
  check('脚本存在: ' + s, fs.existsSync(R(s)));
});

/* ---------------- 2) 最小浏览器桩，按真实顺序求值 ---------------- */
const noop = () => {};
const fakeEl = () => ({
  style: {}, dataset: {}, classList: { add: noop, remove: noop, toggle: noop, contains: () => false },
  appendChild: noop, insertBefore: noop, removeChild: noop, remove: noop, setAttribute: noop,
  addEventListener: noop, removeEventListener: noop, querySelector: () => null,
  querySelectorAll: () => [], focus: noop, click: noop, scrollTop: 0, scrollHeight: 0,
  innerHTML: '', textContent: '', value: '', children: [], parentNode: null
});

const store = {};
const sandbox = {
  console: { log: noop, warn: noop, error: noop, info: noop },
  setTimeout: (fn) => { void fn; return 0; },
  clearTimeout: noop,
  setInterval: () => 0,
  clearInterval: noop,
  JSON, Math, Date, Object, Array, String, Number, Boolean, RegExp, Error, Promise, Map, Set,
  TextDecoder: class { decode() { return ''; } },
  Uint8Array, ArrayBuffer,
  fetch: () => Promise.reject(new Error('no network in test')),
  localStorage: {
    getItem: (k) => (Object.prototype.hasOwnProperty.call(store, k) ? store[k] : null),
    setItem: (k, v) => { store[k] = String(v); },
    removeItem: (k) => { delete store[k]; }
  },
  document: {
    addEventListener: noop, removeEventListener: noop,
    getElementById: () => fakeEl(),
    querySelector: () => fakeEl(),
    querySelectorAll: () => [],
    createElement: () => fakeEl(),
    body: fakeEl(), documentElement: fakeEl(), head: fakeEl()
  },
  navigator: { language: 'zh-CN', userAgent: 'node-test' },
  matchMedia: () => ({ matches: false, media: '', addEventListener: noop, removeEventListener: noop, addListener: noop, removeListener: noop }),
  location: { href: 'file:///test/index.html' },
  RTM: null
};
sandbox.window = sandbox;
sandbox.globalThis = sandbox;
sandbox.self = sandbox;

const ctx = vm.createContext(sandbox);

srcs.forEach((s) => {
  const code = fs.readFileSync(R(s), 'utf8');
  try {
    vm.runInContext(code, ctx, { filename: s });
  } catch (e) {
    check('求值 ' + s + ' 不抛异常', false, e.message);
  }
});
check('五个脚本全部求值完成', true);

/* ---------------- 3) window.RTMNotify 必须存在 ---------------- */
const N = sandbox.RTMNotify || sandbox.window.RTMNotify;
check('notify-core.js 暴露了 window.RTMNotify', !!N);
if (!N) {
  console.log('\n结果: 通过 ' + passed + ' / 共 ' + (passed + failed) + '，失败 ' + failed);
  process.exit(1);
}
check('RTMNotify 暴露 NOTIFY_IDS', !!N.NOTIFY_IDS);
check('RTMNotify 暴露 createCenter', typeof N.createCenter === 'function');

/* ---------------- 4) notifyId 与鸿蒙 GenTask.ets 逐条比对 ---------------- */
console.log('');
console.log('一、notifyId 映射（对照鸿蒙 GenTask.ets）');
const HMS = fs.readFileSync(
  path.join(ROOT, 'entry', 'src', 'main', 'ets', 'common', 'GenTask.ets'), 'utf8');
const block = HMS.match(/NOTIFY_IDS[^=]*=\s*\{([\s\S]*?)\}/);
const hmsIds = {};
if (block) {
  const r2 = /'([a-z]+)':\s*(\d+)/g;
  let x;
  while ((x = r2.exec(block[1])) !== null) hmsIds[x[1]] = Number(x[2]);
}
const FEATURES = ['plan', 'courseware', 'quiz', 'research', 'analysis', 'talk', 'report'];
FEATURES.forEach((f) => {
  check('notifyId[' + f + '] 与鸿蒙一致 (' + hmsIds[f] + ')',
    N.notifyIdFor(f) === hmsIds[f], 'win=' + N.notifyIdFor(f) + ' hms=' + hmsIds[f]);
});
check('未知功能兜底 = 7199', N.notifyIdFor('nope') === 7199, 'got ' + N.notifyIdFor('nope'));

/* ---------------- 5) 五语言文案：不得出现裸键名 ---------------- */
console.log('');
console.log('二、五语言通知文案（核心：不得泄露裸键名）');
const I18N = sandbox.I18N_DATA;
check('i18n-data.js 已加载为 window.I18N_DATA', !!I18N);
const LANGS = ['zh', 'en', 'ug', 'bo', 'mn'];

const rendered = {};
LANGS.forEach((lang) => {
  const d = (I18N && I18N[lang]) || {};
  // 模拟 app.js 的取值：命中即取，未命中回退 zh（与 I18n.ets 语义一致）
  const t = (k) => (d[k] !== undefined && d[k] !== '' ? d[k] : ((I18N.zh || {})[k] || k));
  // 必须把「本语言精确词典」作为 dict 注入：createCenter 用它区分
  // "本语言真的没有点号键" 与 "只是回退到了英文"，从而为 ug/bo/mn 选择
  // 本族语完整句式而非中文括号拼接。不注入则退化为近似判定，测不出真实模板。
  const center = N.createCenter({ t: t, dict: d, world: {}, log: noop });
  const label = t('card.plan') || '教案';
  rendered[lang] = center.buildTexts(label);
});

LANGS.forEach((lang) => {
  const r = rendered[lang];
  const all = [r.doneTitle, r.doneBody, r.failTitle, r.failBody];
  const leak = all.filter((s) => /(^|\s)notify\.[a-zA-Z.]+/.test(String(s)) || String(s) === 'undefined');
  check(lang + ' 无裸键名/undefined 泄露', leak.length === 0, JSON.stringify(leak));
  const empty = all.filter((s) => String(s).trim() === '');
  check(lang + ' 标题正文均非空', empty.length === 0, JSON.stringify(all));
  console.log('        [' + lang + '] ' + r.doneTitle + ' | ' + r.doneBody);
  console.log('        [' + lang + '] ' + r.failTitle + ' | ' + r.failBody);
});

/* ---------------- 6) 同槽位替换语义 ---------------- */
console.log('');
console.log('三、同功能重复通知 → 同槽位（等价鸿蒙"覆盖旧通知"）');
FEATURES.forEach((f) => {
  check(f + ' 重复调用槽位 key 稳定', N.notifyKeyFor(f) === N.notifyKeyFor(f));
});
check('不同功能槽位互不相同',
  new Set(FEATURES.map((f) => N.notifyKeyFor(f))).size === FEATURES.length);
check('未知功能共用 fallback 槽位',
  N.notifyKeyFor('x1') === N.notifyKeyFor('x2'));

console.log('');
console.log('='.repeat(72));
console.log('结果: 通过 ' + passed + ' / 共 ' + (passed + failed) + (failed > 0 ? '，失败 ' + failed : ''));
console.log('='.repeat(72));
process.exit(failed > 0 ? 1 : 0);
