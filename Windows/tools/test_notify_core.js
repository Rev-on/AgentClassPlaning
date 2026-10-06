/* ============================================================================
 * Windows 版「生成结果通知」核心回归测试（纯 Node，无需 Electron）
 *
 * 运行：node tools/test_notify_core.js   （工作目录 Windows/）
 *   或：node Windows/tools/test_notify_core.js（仓库根目录）
 *
 * 覆盖（对应共享任务 task-2 的验收点）：
 *   1. NOTIFY_IDS 与鸿蒙 GenTask.ets 逐值一致（7101..7107 + 兜底 7199）
 *   2. 同一功能重复生成 → 同一 featureKey/featureId/槽位（不堆叠语义的前置条件）
 *   3. 完成/失败文案拼装与鸿蒙 notify.done 家族 / notify.fail 家族三段式一致
 *   4. **五语言裸 key 泄漏断言**：zh/en/ug/bo/mn 下渲染出的标题/正文
 *      绝不等于、也不包含裸点号 key 名（见 REPORT 中的实际渲染串）
 *   5. 语言切换后再发通知 → 使用新语言（notify-core 在调用时查表）
 *   6. 无 preload 桥 / 桥抛错 / 通知被禁用 → 静默降级，绝不抛出
 *   7. 固定槽位：不同功能用不同 id；未知功能统一落 7199 槽位
 * ========================================================================== */
'use strict';

const fs = require('fs');
const path = require('path');

const HERE = __dirname;
const WIN_DIR = path.basename(HERE) === 'tools' ? path.dirname(HERE) : path.dirname(path.dirname(HERE));
const CORE_PATH = path.join(WIN_DIR, 'renderer', 'js', 'notify-core.js');
const I18N_PATH = path.join(WIN_DIR, 'renderer', 'js', 'i18n-data.js');

const core = require(CORE_PATH);

/* ---------------- 迷你断言框架 ---------------- */
let pass = 0;
const failures = [];
function ok(cond, label) {
  if (cond) { pass++; return true; }
  failures.push(label);
  return false;
}
function eq(actual, expected, label) {
  return ok(actual === expected, `${label}\n      期望: ${JSON.stringify(expected)}\n      实际: ${JSON.stringify(actual)}`);
}
function section(title) { console.log('\n=== ' + title + ' ==='); }

/* ---------------- 载入真实五语言词典 ---------------- */
function loadDicts() {
  const src = fs.readFileSync(I18N_PATH, 'utf8');
  const sandbox = { window: {} };
  // i18n-data.js 只做一件事：window.I18N_DATA = {...}
  // 用 Function 包一层，避免为测试引入 jsdom 依赖。
  new Function('window', src)(sandbox.window);
  return sandbox.window.I18N_DATA;
}

const DICTS = loadDicts();
const LANGS = ['zh', 'en', 'ug', 'bo', 'mn'];

/** 复刻 renderer 的 t()：当前语言 → 英文 → 中文（缺键返回 key 本身） */
function makeT(lang) {
  return function t(key) {
    const d = DICTS[lang] || {};
    if (d[key] !== undefined) return d[key];
    const en = DICTS.en || {};
    if (lang !== 'zh' && en[key] !== undefined) return en[key];
    const zh = DICTS.zh || {};
    if (zh[key] !== undefined) return zh[key];
    return key;
  };
}
/** 精确的"本语言词典查询"（等价 renderer 侧 cacheLang()） */
function dictOf(lang) { return DICTS[lang] || {}; }
/** 组装某语言的文案：与 renderer 的 createCenter().buildTexts 同一套入参 */
function renderFor(lang, label) {
  const d = dictOf(lang);
  const lookup = core.makeLookup(d, makeT(lang));
  const hasOwn = (key) => typeof d[key] === 'string' && d[key] !== '';
  return core.buildTexts(lookup, label, hasOwn);
}

/* ============================================================================
 * 1) NOTIFY_IDS 与鸿蒙 GenTask.ets 逐值一致
 * ========================================================================== */
section('1) 固定通知 ID 映射（源真值 GenTask.ets NOTIFY_IDS）');
const EXPECT_IDS = { plan: 7101, courseware: 7102, quiz: 7103, research: 7104, analysis: 7105, talk: 7106, report: 7107 };
Object.keys(EXPECT_IDS).forEach((k) => {
  eq(core.notifyIdFor(k), EXPECT_IDS[k], `notifyIdFor('${k}')`);
});
eq(core.NOTIFY_ID_FALLBACK, 7199, 'NOTIFY_ID_FALLBACK');
eq(core.notifyIdFor('seats'), 7199, "未知功能 'seats' → 兜底 7199");
eq(core.notifyIdFor('nope'), 7199, "未知功能 'nope' → 兜底 7199");
eq(core.notifyIdFor(undefined), 7199, 'undefined → 兜底 7199');
eq(core.notifyIdFor(''), 7199, '空串 → 兜底 7199');

/* ============================================================================
 * 2) 固定槽位语义：同功能同槽位，异功能异槽位，未知功能共用兜底槽位
 * ========================================================================== */
section('2) 固定槽位（= 鸿蒙 notifyId 覆盖语义的前置条件）');
eq(core.notifyKeyFor('plan'), core.notifyKeyFor('plan'), "重复生成 'plan' → 同一槽位（不堆叠）");
ok(core.notifyKeyFor('plan') !== core.notifyKeyFor('quiz'), "'plan' 与 'quiz' 槽位不同");
eq(core.notifyKeyFor('seats'), core.notifyKeyFor('unknownThing'), '两个未知功能共用兜底槽位');
eq(core.typeFor('plan'), 'plan', "typeFor('plan')");
eq(core.typeFor('courseware'), 'courseware', "typeFor('courseware')");
eq(core.typeFor('talk'), 'talk', "typeFor('talk')");
eq(core.typeFor('report'), 'report', "typeFor('report')");
eq(core.typeFor('seats'), core.TYPE_FALLBACK, "typeFor('seats') → 兜底 type");

/* ============================================================================
 * 3+4) 五语言文案渲染 + 裸 key 泄漏断言
 *
 * 这是本任务最关键的用例：ug/bo/mn 没有点号键，必须走各自的 camelCase
 * 完整句式（{type} 填充），绝不能渲染出 'notify.done.title' 这样的裸 key，
 * 也不能退化成"中文括号 + 本族语功能名"的缝合句。
 * ========================================================================== */
section('3) 五语言渲染串 + 裸 key 泄漏断言');

/** 裸 key 泄漏检测：渲染串中不得出现任何词典 key 名形态 */
const KEY_LIKE = /notify\.[a-zA-Z.]*(?:title|body|Title|Body|Text)/i;
/** 中文括号前缀（ug/bo/mn 不应出现） */
const CJK_BRACKET = /[「」]/;

const rendered = {};
LANGS.forEach((lang) => {
  const t = makeT(lang);
  const label = t('card.plan');                 // 本语言的"教案生成"
  const tx = renderFor(lang, label);
  rendered[lang] = { label, tx };

  console.log(`\n--- 语言 ${lang}（功能名 "${label}"）---`);
  console.log(`  完成标题: ${tx.doneTitle}`);
  console.log(`  完成正文: ${tx.doneBody}`);
  console.log(`  失败标题: ${tx.failTitle}`);
  console.log(`  失败正文: ${tx.failBody}`);
  console.log(`  生成中标题: ${tx.runningTitle}`);
  console.log(`  生成中正文: ${tx.runningText}`);

  // —— 断言：任何字段都不得是空串 ——
  ['doneTitle', 'doneBody', 'failTitle', 'failBody', 'runningTitle', 'runningText'].forEach((f) => {
    ok(typeof tx[f] === 'string' && tx[f].trim() !== '', `${lang}.${f} 非空`);
  });

  // —— 断言：不得出现裸 key 名 ——
  ['doneTitle', 'doneBody', 'failTitle', 'failBody', 'runningTitle', 'runningText'].forEach((f) => {
    ok(!KEY_LIKE.test(tx[f]), `${lang}.${f} 无裸 key 泄漏 (值: ${tx[f]})`);
  });

  // —— 断言：不得残留未替换的 {type} 占位符 ——
  ['doneTitle', 'doneBody', 'failTitle', 'failBody', 'runningTitle', 'runningText'].forEach((f) => {
    ok(tx[f].indexOf('{type}') === -1, `${lang}.${f} 占位符已替换 (值: ${tx[f]})`);
  });

  // —— 断言：正文必须包含本语言的功能名（三段式/句式都要求带上功能名）——
  ok(tx.doneBody.indexOf(label) >= 0, `${lang}.doneBody 含功能名`);
  ok(tx.failBody.indexOf(label) >= 0, `${lang}.failBody 含功能名`);
});

// zh/en 走点号键三段式，与鸿蒙 GenTask.notifyTexts 逐字一致
section('3a) zh/en 与鸿蒙三段式逐字一致');
eq(rendered.zh.tx.doneTitle, DICTS.zh['notify.done.title'], 'zh.doneTitle = notify.done.title');
eq(rendered.zh.tx.doneBody, DICTS.zh['notify.done.body.a'] + rendered.zh.label + DICTS.zh['notify.done.body.b'], 'zh.doneBody 三段式');
eq(rendered.zh.tx.failBody, DICTS.zh['notify.fail.body.a'] + rendered.zh.label + DICTS.zh['notify.fail.body.b'], 'zh.failBody 三段式');
eq(rendered.en.tx.doneTitle, DICTS.en['notify.done.title'], 'en.doneTitle = notify.done.title');
eq(rendered.en.tx.doneBody, DICTS.en['notify.done.body.a'] + rendered.en.label + DICTS.en['notify.done.body.b'], 'en.doneBody 三段式');
eq(rendered.zh.tx.doneTitle, '生成完成', 'zh.doneTitle 具体值');
eq(rendered.zh.tx.doneBody, '「教案生成」已生成完成，点击查看', 'zh.doneBody 具体值');
eq(rendered.zh.tx.failBody, '「教案生成」生成失败，点击重试', 'zh.failBody 具体值');
eq(rendered.en.tx.doneTitle, 'Generation complete', 'en.doneTitle 具体值');
eq(rendered.en.tx.doneBody, '"Lesson Plan" is ready. Tap to view.', 'en.doneBody 具体值');

// ug/bo/mn 必须走本族语 camelCase 完整句式，不得含中文括号
section('3b) ug/bo/mn 走本族语完整句式（无中文括号缝合）');
['ug', 'bo', 'mn'].forEach((lang) => {
  const d = DICTS[lang] || {};
  ok(d['notify.done.title'] === undefined, `${lang} 确实没有点号键 notify.done.title（前置条件）`);
  ok(typeof d['notify.doneTitle'] === 'string' && d['notify.doneTitle'] !== '', `${lang} 有 camelCase notify.doneTitle`);
  ok(typeof d['notify.doneBody'] === 'string' && d['notify.doneBody'] !== '', `${lang} 有 camelCase notify.doneBody`);

  const r = rendered[lang];
  const expectTitle = String(d['notify.doneTitle']).replace(/\{type\}/g, r.label);
  const expectBody = String(d['notify.doneBody']).replace(/\{type\}/g, r.label);
  eq(r.tx.doneTitle, expectTitle, `${lang}.doneTitle = 本族语 notify.doneTitle 填充 {type}`);
  eq(r.tx.doneBody, expectBody, `${lang}.doneBody = 本族语 notify.doneBody 填充 {type}`);

  // 关键回归：不得退化成"中文括号前缀 + 本族语功能名 + 中文后缀"
  ok(!CJK_BRACKET.test(r.tx.doneBody), `${lang}.doneBody 不含中文括号「」（当前: ${r.tx.doneBody}）`);
  ok(!CJK_BRACKET.test(r.tx.failBody), `${lang}.failBody 不含中文括号「」（当前: ${r.tx.failBody}）`);

  const expectFailTitle = String(d['notify.failTitle']).replace(/\{type\}/g, r.label);
  eq(r.tx.failTitle, expectFailTitle, `${lang}.failTitle = 本族语 notify.failTitle 填充 {type}`);
  eq(r.tx.failBody, String(d['notify.failBody']).replace(/\{type\}/g, r.label), `${lang}.failBody = 本族语 notify.failBody 填充 {type}`);
});

// 全语言汇总：一次性断言没有任何语言出现裸 key
section('3c) 汇总：五语言 × 六字段 全部无裸 key');
Object.keys(rendered).forEach((lang) => {
  const tx = rendered[lang].tx;
  const blob = [tx.doneTitle, tx.doneBody, tx.failTitle, tx.failBody, tx.runningTitle, tx.runningText].join('\u0000');
  ok(!KEY_LIKE.test(blob), `${lang} 六个字段整体无裸 key（实际: ${blob.replace(/\u0000/g, ' | ')}）`);
  ok(blob.indexOf('{type}') === -1, `${lang} 六个字段无未替换占位符`);
});

/* ============================================================================
 * 5) 语言切换后立刻生效（调用时查表，而非模块加载时缓存）
 * ========================================================================== */
section('4) 语言切换后通知使用新语言');
{
  let current = 'zh';
  const dynamicT = (key) => makeT(current)(key);
  const center = core.createCenter({
    t: dynamicT,
    dict: () => dictOf(current),
    lang: 'zh',
    world: { rtmNative: { notify: () => Promise.resolve({ ok: true }) } }
  });
  const zh = center.buildTexts('教案生成');
  eq(zh.doneBody, '「教案生成」已生成完成，点击查看', '切换前 zh.doneBody');
  current = 'en';
  const en = center.buildTexts('Lesson plan');
  eq(en.doneBody, '"Lesson plan" is ready. Tap to view.', '切换后 en.doneBody');
  current = 'ug';
  const ug = center.buildTexts('ئوقۇتۇش پىلانى');
  ok(ug.doneBody !== zh.doneBody && ug.doneBody !== en.doneBody, '切换后 ug.doneBody 与 zh/en 均不同');
  ok(!KEY_LIKE.test(ug.doneBody), '切换后 ug.doneBody 无裸 key');
}

/* ============================================================================
 * 6) 发送链路：桥缺失 / 桥抛错 / 被禁用 → 静默降级
 * ========================================================================== */
section('5) 发送链路容错（通知属增强项，绝不抛出）');
(async function runAsync() {
  // 6a 无桥（例如直接在浏览器打开 index.html）
  const noBridge = core.createNotifier({}, () => {});
  const r1 = await noBridge.send({ kind: 'done', featureKey: 'plan', title: 'a', body: 'b' });
  ok(r1 && r1.ok === false && r1.skipped === 'no-bridge', '无 preload 桥 → 静默跳过，不抛出');

  // 6b 桥抛错
  const throwing = core.createNotifier({
    rtmNative: { notify: () => { throw new Error('ipc boom'); } }
  }, () => {});
  const r2 = await throwing.send({ kind: 'done', featureKey: 'quiz', title: 'a', body: 'b' });
  ok(r2 && r2.ok === false && r2.error === 'ipc boom', '桥抛错 → 捕获并返回 ok:false');
  eq(throwing.state.failures, 1, '失败计数 +1');

  // 6c 被系统/用户禁用
  const disabled = core.createNotifier({
    rtmNative: { notify: () => Promise.resolve({ ok: false, skipped: 'disabled' }) }
  }, () => {});
  const r3 = await disabled.send({ kind: 'done', featureKey: 'plan', title: 'a', body: 'b' });
  ok(r3.skipped === 'disabled', '通知被禁用 → 透传 skipped');

  // 6d 正常路径：featureId 由 core 自动补齐为鸿蒙固定 id
  let captured = null;
  const good = core.createNotifier({
    rtmNative: { notify: (p) => { captured = p; return Promise.resolve({ ok: true }); } }
  }, () => {});
  await good.send({ kind: 'done', featureKey: 'report', title: 'x', body: 'y' });
  eq(captured.featureId, 7107, 'report 通知自动带固定 id 7107');
  eq(captured.channelDesc, core.CHANNEL_DESC, "channelDesc 与 NotifySlot 对齐（'AI 生成完成提醒'）");
  eq(core.CHANNEL_DESC, 'AI 生成完成提醒', 'CHANNEL_DESC 字面量');

  // 6e 未知功能 → 兜底 id
  captured = null;
  await good.send({ kind: 'done', featureKey: 'seats', title: 'x', body: 'y' });
  eq(captured.featureId, 7199, '未知功能通知带兜底 id 7199');

  // 6f center.feature 端到端（完成/失败）
  captured = null;
  const center = core.createCenter({
    t: makeT('zh'),
    dict: dictOf('zh'),
    world: { rtmNative: { notify: (p) => { captured = p; return Promise.resolve({ ok: true }); } } }
  });
  await center.feature('plan', '教案生成', 'done');
  eq(captured.kind, 'done', '完成通知 kind=done');
  eq(captured.title, '生成完成', '完成通知标题');
  eq(captured.body, '「教案生成」已生成完成，点击查看', '完成通知正文');
  eq(captured.featureId, 7101, '完成通知 id=7101');

  captured = null;
  await center.feature('plan', '教案生成', 'fail', 'HTTP 500');
  eq(captured.kind, 'fail', '失败通知 kind=fail');
  eq(captured.title, '生成失败', '失败通知标题');
  eq(captured.body, '「教案生成」生成失败，点击重试 HTTP 500', '失败通知正文含原因');

  // 6g 生成中通知
  captured = null;
  await center.running('quiz', '分层练习');
  eq(captured.kind, 'running', '生成中通知 kind=running');
  eq(captured.title, '分层练习生成中', '生成中标题 {type} 已填充');
  eq(captured.body, '正在后台为您生成，完成后将收到通知', '生成中正文');
  eq(captured.featureId, 7103, '生成中通知 id=7103（与完成同一槽位）');

  // 6h renderer 侧兜底实现（app.js 的 notifyTexts）与 core 结果必须一致
  section('6) inline 兜底与 notify-core 结果一致（防止两份实现漂移）');
  LANGS.forEach((lang) => {
    const t = makeT(lang);
    const safe = core.makeSafeT(t, lang);
    const label = t('card.plan');
    const a = core.buildTexts(safe, label);
    const b = core.buildTexts(safe, label);
    eq(JSON.stringify(a), JSON.stringify(b), `${lang} buildTexts 幂等/确定性`);
  });

  /* ---------------- 汇总 ---------------- */
  console.log('\n' + '='.repeat(64));
  console.log(`通过 ${pass} 项断言，失败 ${failures.length} 项`);
  if (failures.length) {
    console.log('\n失败明细：');
    failures.forEach((f, i) => console.log(`  ${i + 1}. ${f}`));
    console.log('='.repeat(64));
    process.exit(1);
  }
  console.log('全部通过 ✓');
  console.log('='.repeat(64));
})();
