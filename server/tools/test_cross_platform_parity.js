/**
 * 跨端一致性校验：鸿蒙端 与 安卓端（ArkUI-X）的通知功能必须保持同构。
 *
 * 为什么需要：
 *   两个工程是**手工同步**的（安卓端在 Desktop\RevTechingX_Android），
 *   没有共享源码机制。一旦只改一端，就会出现"鸿蒙能收到通知、安卓收不到"
 *   或"两端通知文案/ID 不一致"的问题，而且很难发现。
 *   本脚本把"两端通知契约必须一致"固化为断言。
 *
 * 用法：node server/tools/test_cross_platform_parity.js
 */
const fs = require('fs');
const path = require('path');

const HARMONY = path.join(__dirname, '..', '..');                               // 鸿蒙主工程
const ANDROID = path.join(__dirname, '..', '..', '..', 'RevTechingX_Android');   // 安卓工程

let passed = 0;
let failed = 0;
function check(name, cond, detail) {
  if (cond) {
    passed++;
    console.log('  PASS  ' + name);
  } else {
    failed++;
    console.log('  FAIL  ' + name + (detail === undefined ? '' : '  -> ' + detail));
  }
}

function read(p) {
  try {
    return fs.readFileSync(p, 'utf8');
  } catch (e) {
    return '';
  }
}

console.log('='.repeat(72));
console.log('跨端一致性校验：鸿蒙端 ↔ 安卓端（ArkUI-X）通知功能');
console.log('='.repeat(72));
console.log('鸿蒙端: ' + HARMONY);
console.log('安卓端: ' + ANDROID);
console.log('');

if (!fs.existsSync(ANDROID)) {
  console.log('  FAIL  安卓工程不存在: ' + ANDROID);
  console.log('  （若不需要跨端校验，可忽略本脚本）');
  process.exit(1);
}

const FEATURES = ['plan', 'courseware', 'quiz', 'research', 'analysis', 'talk', 'report'];

/* ------------------------------------------------------------------ *
 * 一、GenTask.ets：两端 notify 契约必须一致
 * ------------------------------------------------------------------ */
console.log('一、GenTask.ets 通知上报契约');
const gA = read(path.join(HARMONY, 'entry', 'src', 'main', 'ets', 'common', 'GenTask.ets'));
const gB = read(path.join(ANDROID, 'entry', 'src', 'main', 'ets', 'common', 'GenTask.ets'));
check('两端 GenTask.ets 都存在', gA !== '' && gB !== '');

// 1.1 5 个 notify 字段两端都要有
['notifySeed', 'notifyTitle', 'notifyBody', 'notifyFailTitle', 'notifyFailBody'].forEach((f) => {
  const re = new RegExp(f + '\\??:\\s*(number|string)');
  check('鸿蒙端声明 ' + f, re.test(gA));
  check('安卓端声明 ' + f, re.test(gB));
});

// 1.2 两端 notifyId 映射数值必须完全相同（否则跨端通知无法互相覆盖）
function parseIds(src) {
  const out = {};
  const block = src.match(/NOTIFY_IDS[^=]*=\s*\{([\s\S]*?)\}/);
  if (!block) {
    return out;
  }
  const re = /'([a-z]+)':\s*(\d+)/g;
  let m;
  while ((m = re.exec(block[1])) !== null) {
    out[m[1]] = Number(m[2]);
  }
  return out;
}
const idsA = parseIds(gA);
const idsB = parseIds(gB);
FEATURES.forEach((f) => {
  check('notifySeed[' + f + '] 两端一致（' + idsA[f] + ' / ' + idsB[f] + '）',
    idsA[f] !== undefined && idsA[f] === idsB[f],
    '鸿蒙=' + idsA[f] + ' 安卓=' + idsB[f]);
});

// 1.3 提交时必须真的填充（不能只声明）
FEATURES.length; // 占位：保持结构清晰
['notifySeed', 'notifyTitle', 'notifyBody', 'notifyFailTitle', 'notifyFailBody'].forEach((f) => {
  check('安卓端 submit() 填充 ' + f, new RegExp(f + ':\\s*[A-Za-z]').test(gB));
});

// 1.4 两端组装文案的 i18n 键必须一致
const textsKeysA = (gA.match(/I18n\.t\('(notify\.[a-z.]+)'\)/g) || []).sort().join(',');
const textsKeysB = (gB.match(/I18n\.t\('(notify\.[a-z.]+)'\)/g) || []).sort().join(',');
check('两端通知文案使用的 i18n 键集合一致', textsKeysA === textsKeysB,
  '鸿蒙=[' + textsKeysA + '] 安卓=[' + textsKeysB + ']');

/* ------------------------------------------------------------------ *
 * 二、I18n.ets：两端通知文案键与文案必须一致
 * ------------------------------------------------------------------ */
console.log('');
console.log('二、I18n.ets 通知文案');

function dictEntries(src, dictName) {
  const re = new RegExp('private static readonly ' + dictName + '([\\s\\S]*?)\\]\\);');
  const m = re.exec(src);
  if (!m) {
    return {};
  }
  const out = {};
  const e = /\[\s*'([^']+)'\s*,\s*'((?:[^'\\]|\\.)*)'\s*\]/g;
  let x;
  while ((x = e.exec(m[1])) !== null) {
    out[x[1]] = x[2];
  }
  return out;
}
// 词典可能是 Map 或其它形式，做两种尝试
function dictEntriesLoose(src, marker) {
  const idx = src.indexOf(marker);
  if (idx < 0) {
    return {};
  }
  const seg = src.slice(idx, idx + 60000);
  const out = {};
  const e = /\[\s*'([^']+)'\s*,\s*'((?:[^'\\]|\\.)*)'\s*\]/g;
  let x;
  let count = 0;
  while ((x = e.exec(seg)) !== null) {
    out[x[1]] = x[2];
    count++;
    if (count > 3000) {
      break;
    }
  }
  return out;
}

const iA = read(path.join(HARMONY, 'entry', 'src', 'main', 'ets', 'common', 'I18n.ets'));
const iB = read(path.join(ANDROID, 'entry', 'src', 'main', 'ets', 'common', 'I18n.ets'));
check('两端 I18n.ets 都存在', iA !== '' && iB !== '');

// 用宽松方式取各自的 zh / en 段
const zhA = dictEntriesLoose(iA.slice(0, iA.indexOf('private static readonly en')), "'notify.");
const enAIdx = iA.indexOf('private static readonly en');
const enA = dictEntriesLoose(iA.slice(enAIdx), "'notify.");
const zhB = dictEntriesLoose(iB.slice(0, iB.indexOf('private static readonly en')), "'notify.");
const enBIdx = iB.indexOf('private static readonly en');
const enB = dictEntriesLoose(iB.slice(enBIdx), "'notify.");

const NEED = ['notify.done.title', 'notify.done.body.a', 'notify.done.body.b',
  'notify.fail.title', 'notify.fail.body.a', 'notify.fail.body.b'];

NEED.forEach((k) => {
  check('鸿蒙 zh 有 ' + k, typeof zhA[k] === 'string' && zhA[k] !== '');
  check('安卓 zh 有 ' + k, typeof zhB[k] === 'string' && zhB[k] !== '');
  check('鸿蒙 en 有 ' + k, typeof enA[k] === 'string' && enA[k] !== '');
  check('安卓 en 有 ' + k, typeof enB[k] === 'string' && enB[k] !== '');
  check('zh ' + k + ' 两端文案一致', zhA[k] === zhB[k],
    '鸿蒙=' + JSON.stringify(zhA[k]) + ' 安卓=' + JSON.stringify(zhB[k]));
  check('en ' + k + ' 两端文案一致', enA[k] === enB[k],
    '鸿蒙=' + JSON.stringify(enA[k]) + ' 安卓=' + JSON.stringify(enB[k]));
});

/* ------------------------------------------------------------------ *
 * 三、平台隔离：安卓端不得引入 HarmonyOS 专有 API
 * ------------------------------------------------------------------ */
console.log('');
console.log('三、平台隔离（安卓端不得引入鸿蒙专有 API）');

// 这些 API 在 ArkUI-X 安卓端不可用，必须不出现在安卓工程
const FORBIDDEN = [
  { name: 'NotifySlot', why: '通知渠道（HarmonyOS Notification Kit 专有）' },
  { name: 'LiveView', why: '实况窗（LiveView Kit 专有，已明确不同步）' },
  { name: 'PushToken', why: 'Push Kit token 申请（专有）' },
  { name: 'ContinuationService', why: '分布式流转（专有）' },
  { name: '@kit.NotificationKit', why: '通知模块（专有）' },
  { name: '@kit.PushKit', why: '推送模块（专有）' },
  { name: '@kit.LiveViewKit', why: '实况窗模块（专有）' }
];

// 只检查 ets 源码（排除注释与文档）
function stripComments(src) {
  return src.replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/[^\n]*/g, '');
}

const etsFiles = [];
(function walk(dir) {
  if (!fs.existsSync(dir)) {
    return;
  }
  fs.readdirSync(dir, { withFileTypes: true }).forEach((d) => {
    const p = path.join(dir, d.name);
    if (d.isDirectory()) {
      walk(p);
    } else if (d.name.endsWith('.ets')) {
      etsFiles.push(p);
    }
  });
})(path.join(ANDROID, 'entry', 'src', 'main', 'ets'));

check('安卓工程存在 ets 源码', etsFiles.length > 0, 'count=' + etsFiles.length);

FORBIDDEN.forEach((f) => {
  const hits = etsFiles.filter((p) => stripComments(read(p)).indexOf(f.name) >= 0);
  check('安卓端未使用 ' + f.name + '（' + f.why + '）',
    hits.length === 0,
    hits.length > 0 ? hits.map((h) => path.basename(h)).join(', ') : '');
});

// 3.2 安卓端必须也没有 NotifySlot.ets 文件
check('安卓端不存在 NotifySlot.ets',
  !fs.existsSync(path.join(ANDROID, 'entry', 'src', 'main', 'ets', 'common', 'NotifySlot.ets')));
check('安卓端不存在 LiveView.ets',
  !fs.existsSync(path.join(ANDROID, 'entry', 'src', 'main', 'ets', 'common', 'LiveView.ets')));

/* ------------------------------------------------------------------ *
 * 四、7 个页面在两端都传入 type / label
 * ------------------------------------------------------------------ */
console.log('');
console.log('四、7 个生成页面（两端均需传 type + label）');
FEATURES.forEach((f) => {
  const page = f.charAt(0).toUpperCase() + f.slice(1);
  const pa = path.join(HARMONY, 'entry', 'src', 'main', 'ets', 'pages', page + '.ets');
  const pb = path.join(ANDROID, 'entry', 'src', 'main', 'ets', 'pages', page + '.ets');
  const sa = read(pa);
  const sb = read(pb);
  check(page + ' 鸿蒙端传 type', new RegExp("type:\\s*'" + f + "'").test(sa));
  check(page + ' 安卓端传 type', new RegExp("type:\\s*'" + f + "'").test(sb));
  check(page + ' 安卓端传本地化 label', /label:\s*I18n\.t\('page\./.test(sb));
});

console.log('');
console.log('='.repeat(72));
console.log('结果: 通过 ' + passed + ' / 共 ' + (passed + failed) + ' 项'
  + (failed > 0 ? '，失败 ' + failed : ''));
console.log('='.repeat(72));
process.exit(failed > 0 ? 1 : 0);
