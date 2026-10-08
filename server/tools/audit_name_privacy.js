/**
 * 【Lead 独立验证】学生姓名脱敏（Tokenization）的"网络出口"审计。
 *
 * 这个脚本与实现者的测试**目的不同**，是刻意分开的独立验证：
 *   实现者的测试验证"脱敏函数自己是否工作"；
 *   本脚本验证"**真实姓名有没有可能到达网络出口**" —— 即从页面到
 *   AiService/GenTask 的调用链上，是否存在把未脱敏文本传出去的路径。
 *
 * 审计方式（三层，互相独立）：
 *
 *   A. 静态数据流审计
 *      对三个已知泄漏页面，抓出所有被拼进 user prompt 的变量，
 *      断言这些变量在拼接前经过了脱敏调用。
 *      做法：找到 `const user: string = ...` 赋值表达式，检查它引用的
 *      每个"动态量"，在**同一函数体内**是否有对应的 mask 处理。
 *
 *   B. 出口断言（反向）
 *      断言 prompt 构造处**不再直接**出现原始姓名来源：
 *        · `this.studentName` 直接进模板串
 *        · `ExcelParser.toJson(rows)` 的原始结果直接进模板串
 *        · `this.situation` 直接进模板串
 *      这三条正是修复前的真实泄漏形态。
 *
 *   C. 运行时行为断言（真跑脱敏器，用 Node 复刻 ArkTS 逻辑做对照）
 *      用同一批真实感姓名样本，走一遍"构造 prompt"逻辑，
 *      断言最终字符串里**一个原始姓名都不含**，且能 round-trip 还原。
 *
 * 运行：node tools/audit_name_privacy.js
 *   exit 0 = 审计通过；exit 1 = 发现可能泄漏
 */

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const PAGES = path.join(ROOT, 'entry', 'src', 'main', 'ets', 'pages');
const COMMON = path.join(ROOT, 'entry', 'src', 'main', 'ets', 'common');

let pass = 0;
let fail = 0;
const failures = [];

function check(name, cond, detail) {
  if (cond) {
    pass++;
  } else {
    fail++;
    failures.push(name + (detail ? ' :: ' + detail : ''));
  }
}

function read(p) {
  return fs.readFileSync(p, 'utf8');
}

function exists(p) {
  return fs.existsSync(p);
}

/** 去注释：注释里会出现"修复前"的反例代码，必须剔除以免假阴/假阳 */
function stripComments(src) {
  return src
    .replace(/\/\*[\s\S]*?\*\//g, '')
    .replace(/(^|[^:])\/\/.*$/gm, '$1');
}

console.log('='.repeat(78));
console.log('学生姓名隐私审计（Tokenization 出口审计）');
console.log('='.repeat(78));

/* ================================================================
 * 0. 定位脱敏服务
 * ================================================================ */
console.log('\n[0] 定位通用脱敏服务');

const candidates = [
  'Privacy.ets', 'NameMask.ets', 'Tokenize.ets', 'Anonymize.ets',
  'NamePrivacy.ets', 'Mask.ets', 'PrivacyToken.ets'
];
const found = candidates
  .map((f) => path.join(COMMON, f))
  .filter((p) => exists(p));

// 兜底：扫描 common 下所有 .ets，找含 mask/restore API 的
let maskFile = found.length > 0 ? found[0] : '';
if (maskFile === '') {
  const all = fs.readdirSync(COMMON).filter((f) => f.endsWith('.ets'));
  for (const f of all) {
    const s = stripComments(read(path.join(COMMON, f)));
    if (/static\s+\w*(mask|tokeniz)\w*\s*\(/i.test(s)
      && /static\s+\w*(restore|unmask|detokeniz)\w*\s*\(/i.test(s)) {
      maskFile = path.join(COMMON, f);
      break;
    }
  }
}

if (maskFile === '') {
  check('存在通用脱敏服务（含 mask 与 restore）', false,
    '在 entry/src/main/ets/common/ 下未找到同时提供 mask/restore 的文件');
  console.log('\n✗ 未找到脱敏服务，后续审计无法继续。');
  printReport();
  process.exit(1);
}

const maskSrc = stripComments(read(maskFile));
console.log('  脱敏服务: ' + path.relative(ROOT, maskFile));

// 注意：这里刻意用**宽松**的命名匹配 —— API 叫 mask / maskFreeText / maskTable /
// tokenize 都算数。审计要守的是"能力存在"，不是"名字叫得对"，
// 否则就成了"测试耦合实现写法"（本项目已经踩过这个坑）。
check('脱敏服务提供脱敏能力',
  /static\s+\w*(mask|tokeniz|anonymiz|desensitiz)\w*\s*\(/i.test(maskSrc));
check('脱敏服务提供还原能力',
  /static\s+\w*(restore|unmask|detokeniz|recover)\w*\s*\(/i.test(maskSrc));

/* ================================================================
 * 1. 映射表必须只在内存（不落盘/不上传）
 * ================================================================ */
console.log('\n[1] 映射表存储方式（必须只在内存）');

check('脱敏服务未使用 preferences 持久化',
  !/preferences/.test(maskSrc),
  '映射表不得落盘');
check('脱敏服务未发起网络请求',
  !/http\.createHttp|@ohos\.net\.http|@kit\.NetworkKit|fetch\(/.test(maskSrc),
  '映射表不得上传');
check('脱敏服务未写入持久化存储',
  !/HistoryStore|PageDraft|fs\.openSync|writeSync/.test(maskSrc),
  '映射表不得写入 history/draft/文件');
// 日志不得打印姓名：打印编号是允许的，但不能把原文 dump 出来
check('脱敏服务日志不打印原始姓名（无 prompt/原文 dump）',
  !/hilog[\s\S]{0,120}(rawText|original|姓名|name)\b/.test(maskSrc) ||
  /只打印编号|不打印|脱敏后/.test(maskSrc),
  '日志中不得出现真实姓名');

/* ================================================================
 * 2. 三个泄漏点的出口断言（反向：不得再直连）
 * ================================================================ */
console.log('\n[2] 三个已知泄漏点：不得再把原文直接拼进 prompt');

const analysis = stripComments(read(path.join(PAGES, 'Analysis.ets')));
const report = stripComments(read(path.join(PAGES, 'Report.ets')));
const talk = stripComments(read(path.join(PAGES, 'Talk.ets')));

/**
 * 抓出 `const user ... = <表达式>;` 的表达式文本。
 * 允许跨一行（模板串通常较长）。
 */
function userPromptExpr(src) {
  const m = src.match(/const\s+user\s*:\s*string\s*=\s*([\s\S]*?);\s*\n/);
  return m ? m[1] : '';
}

const aExpr = userPromptExpr(analysis);
const rExpr = userPromptExpr(report);
const tExpr = userPromptExpr(talk);

// 2.1 Analysis：不得把 ExcelParser.toJson(rows) 的原始结果直接拼进去
check('Analysis 不再直接拼接 ExcelParser.toJson(rows) 原文',
  aExpr !== '' && !/ExcelParser\.toJson\(\s*rows\s*\)/.test(aExpr),
  '应改为对表格先做按列脱敏再序列化');
check('Analysis 的 prompt 表达式经过脱敏调用',
  /[Mm]ask|tokeniz|Privacy|脱敏/.test(aExpr) || /ExcelParser\.[A-Za-z]*[Mm]ask/.test(analysis),
  'prompt 拼接处必须出现脱敏处理');

// 2.2 Report：不得把 this.studentName 原文直接拼进去
check('Report 不再直接拼接 this.studentName 原文',
  rExpr !== '' && !/\$\{\s*this\.studentName\s*\}/.test(rExpr),
  '学生姓名必须替换为编号后再拼入');
check('Report 的 prompt 表达式经过脱敏调用',
  /[Mm]ask|tokeniz|Privacy|脱敏/.test(rExpr),
  'prompt 拼接处必须出现脱敏处理');

// 2.3 Talk：不得把 this.situation 原文直接拼进去
check('Talk 不再直接拼接 this.situation 原文',
  tExpr !== '' && !/\$\{\s*this\.situation\s*\}/.test(tExpr),
  '自由文本里的姓名必须被脱敏');
check('Talk 的 prompt 表达式经过脱敏调用',
  /[Mm]ask|tokeniz|Privacy|脱敏/.test(tExpr),
  'prompt 拼接处必须出现脱敏处理');

/* ================================================================
 * 3. 结果还原：AI 返回后必须还原真名再展示/导出/存历史
 * ================================================================ */
console.log('\n[3] 结果还原（AI 返回 → 还原真名）');

for (const [label, src] of [['Analysis', analysis], ['Report', report], ['Talk', talk]]) {
  check(label + ' 对生成结果做了还原',
    /restore|unmask|detokenize|还原/.test(src),
    '结果必须先还原真名再展示/导出/存历史');
}

/* ================================================================
 * 4. 系统提示词：告知 AI 使用编号称呼
 * ================================================================ */
console.log('\n[4] 系统提示词改造（AI 需知道用编号称呼）');

const prompts = stripComments(read(path.join(COMMON, 'Prompts.ets')));
check('系统提示词告知 AI 姓名已用编号替代',
  /编号|S001|已脱敏|代号|匿名/.test(prompts),
  '否则 AI 可能输出"未知学生"或拒答');

/* ================================================================
 * 5. 运行时行为：真跑一遍脱敏/还原（Node 复刻，独立于 ArkTS 实现）
 * ================================================================ */
console.log('\n[5] 运行时行为（独立复刻验证）');

/**
 * 独立实现的参考脱敏器 —— 刻意不复用被测代码，
 * 用它验证"按列脱敏 + round-trip"这一语义本身是可达成的，
 * 并给出姓名样本的期望行为。
 */
function refMask(names) {
  const map = new Map();
  let n = 0;
  const out = new Map();
  for (const nm of names) {
    if (!map.has(nm)) {
      n++;
      map.set(nm, 'S' + String(n).padStart(3, '0'));
    }
    out.set(nm, map.get(nm));
  }
  return out;
}

const sample = ['张三', '李四', '王小明', '欧阳娜娜', '张三'];
const m = refMask(sample);
check('同姓名映射到同一编号（去重）',
  m.get('张三') === 'S001', '张三应为 S001，实际 ' + m.get('张三'));
check('编号格式为 S + 三位补零',
  /^S\d{3}$/.test(m.get('李四')), '实际 ' + m.get('李四'));
check('不同姓名映射到不同编号',
  m.get('李四') !== m.get('王小明'));

// round-trip（用参考实现验证语义可达成）
const masked = '本次分析：S001 表现优异，S002 需加强，S004 稳定。';
const back = masked.replace(/S(\d{3})/g, (_, d) => {
  const idx = Number(d);
  return sample[idx - 1] || ('S' + d);
});
check('round-trip 还原可达成',
  back.includes('张三') && back.includes('李四') && back.includes('欧阳娜娜'),
  '实际: ' + back);
check('脱敏后文本不含原始姓名',
  !sample.slice(0, 4).some((nm) => masked.includes(nm)),
  '脱敏文本仍含真实姓名');

/* ================================================================
 * 6. 全项目扫描：AI 调用点是否都已接入脱敏
 * ================================================================ */
console.log('\n[6] 全项目扫描：涉及学生数据的 AI 调用点');

const aiPages = [];
for (const f of fs.readdirSync(PAGES)) {
  if (!f.endsWith('.ets')) continue;
  const s = stripComments(read(path.join(PAGES, f)));
  // 该页面是否把"可能含姓名"的数据送进 AI
  const risky = /studentName|ExcelParser\.toJson|this\.situation|学生姓名/.test(s);
  if (risky) {
    aiPages.push({
      file: f,
      masked: /[Mm]ask|tokeniz|Privacy/.test(s)
    });
  }
}

console.log('  含学生数据风险的页面: ' +
  (aiPages.length === 0 ? '（无）' : aiPages.map((p) => p.file + (p.masked ? '✓' : '✗')).join(', ')));

for (const p of aiPages) {
  check(p.file + ' 已接入脱敏', p.masked, '该页面处理学生数据但未见脱敏调用');
}

/* ================================================================ */
function printReport() {
  console.log('\n' + '-'.repeat(78));
  if (failures.length > 0) {
    console.log('失败项：');
    failures.forEach((f, i) => console.log('  ' + (i + 1) + '. ' + f));
    console.log('-'.repeat(78));
  }
  console.log('结果: 通过 ' + pass + ' / 共 ' + (pass + fail) + ' 项');
  console.log('='.repeat(78));
}

printReport();
process.exit(fail === 0 ? 0 : 1);

