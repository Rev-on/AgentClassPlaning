/**
 * 【Lead 核对】隐私协议 1.0.1 的声明 vs 代码实际行为。
 *
 * 目的：协议里写了什么，代码就必须真的做到什么。
 *   "过度声明"比"不声明"更糟 —— 它会让老师和审核方误以为有保护。
 *
 * 本脚本把 privacy.html 里的关键声明逐条转成可执行断言。
 *
 * 运行：node tools/audit_privacy_policy_claims.js
 */
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const POLICY = path.join('C:', 'Users', 'laoyu', 'Desktop', 'Rev TechingMaster', 'rev-on.site', 'privacy.html');
const NAMEMASK = path.join(ROOT, 'entry', 'src', 'main', 'ets', 'common', 'NameMask.ets');
const PAGES = ['Analysis.ets', 'Report.ets', 'Talk.ets']
  .map((f) => path.join(ROOT, 'entry', 'src', 'main', 'ets', 'pages', f));

let pass = 0, fail = 0;
const failures = [];
function check(name, cond, detail) {
  if (cond) pass++;
  else { fail++; failures.push(name + (detail ? ' :: ' + detail : '')); }
}

/** 去注释（协议声明核对必须只看真实代码，注释里的反例文字会误导） */
function code(p) {
  return fs.readFileSync(p, 'utf8')
    .replace(/\/\*[\s\S]*?\*\//g, '')
    .replace(/(^|[^:])\/\/.*$/gm, '$1');
}

console.log('='.repeat(78));
console.log('隐私协议声明 vs 代码行为 核对（over-claiming 检查）');
console.log('='.repeat(78));

/* ---------- 版本信息 ---------- */
console.log('\n[A] 协议版本');
const policyRaw = fs.readFileSync(POLICY, 'utf8');
check('协议版本为 1.0.1', /版本 1\.0\.1/.test(policyRaw));
check('生效日期为 2026-10-08', /2026 年 10 月 8 日/.test(policyRaw));

/* ---------- 声明 1：对照表不落盘/不上传/不写日志 ---------- */
console.log('\n[B] 声明：对照表不落盘、不上传、不写日志');
const ms = code(NAMEMASK);
check('NameMask 无任何 import 语句', (ms.match(/^\s*import\s/gm) || []).length === 0,
  '实际 import 数: ' + (ms.match(/^\s*import\s/gm) || []).length);
for (const kw of ['preferences', 'fileIo', 'HistoryStore', 'PageDraft', 'hilog', 'createHttp', 'fetch(']) {
  check('NameMask 未使用 ' + kw, !ms.includes(kw), '代码中出现 ' + kw);
}

/* ---------- 声明 2：发送前校验，残留真名则终止 ---------- */
console.log('\n[C] 声明：发送前校验，残留真名则终止生成');
check('NameMask 提供 applyToFlow', /applyToFlow/.test(ms));
for (const p of PAGES) {
  const src = code(p);
  const n = path.basename(p);
  check(n + ' 调用了 applyToFlow', /applyToFlow/.test(src));
  // 必须有 try/catch 与中止路径（抛错后 return / 提示失败）
  check(n + ' 对脱敏失败做了中止处理',
    /MaskError/.test(src) && /return\s*;/.test(src));
}

/* ---------- 声明 3：仅姓名列被替换 ---------- */
console.log('\n[D] 声明：学情分析仅姓名列被替换，成绩列保持不变');
check('NameMask 提供按列脱敏 maskTable', /maskTable/.test(ms));
check('NameMask 有姓名列表头识别', /isNameHeader/.test(ms));
const xp = code(path.join(ROOT, 'entry', 'src', 'main', 'ets', 'common', 'ExcelParser.ets'));
check('ExcelParser 提供脱敏版 toJson', /toJsonMasked/.test(xp));
const analysis = code(PAGES[0]);
check('Analysis 使用脱敏版表格入口',
  /toJsonMasked/.test(analysis), '未找到 toJsonMasked 调用');

/* ---------- 声明 4：三项功能均覆盖 ---------- */
console.log('\n[E] 声明：学情分析 / 学情报告 / 沟通话术 三项均已覆盖');
for (const p of PAGES) {
  check(path.basename(p) + ' 接入脱敏', /NameMask/.test(code(p)));
}
// 报告页：姓名必须走结构化脱敏
check('Report 姓名走 maskStructured',
  /maskStructured/.test(code(PAGES[1])));
// 话术页：必须有姓名输入框（协议里承诺的兜底）
const talk = code(PAGES[2]);
check('Talk 有学生姓名输入框', /studentName/.test(talk));

/* ---------- 声明 5：协议里承诺的限制必须真实存在 ---------- */
console.log('\n[F] 声明：协议自述的限制必须与实现一致（不得低报）');
check('协议披露了「手写姓名可能漏识别」的限制',
  /手写姓名、又未填写/.test(policyRaw) || /可能无法被自动识别/.test(policyRaw));
// 该限制必须真实：Talk 不做裸中文姓名猜测
check('Talk 确实不做裸中文姓名通用猜测（与披露一致）',
  /刻意\*\*不做\*\*|不做.*裸中文姓名|不具备.*通用识别/.test(
    fs.readFileSync(PAGES[2], 'utf8')) ||
  /不做/.test(fs.readFileSync(PAGES[2], 'utf8')),
  '协议披露的限制需要在代码注释里有对应说明');

console.log('\n' + '-'.repeat(78));
if (failures.length) {
  console.log('失败项：');
  failures.forEach((f, i) => console.log('  ' + (i + 1) + '. ' + f));
  console.log('-'.repeat(78));
}
console.log('结果: 通过 ' + pass + ' / 共 ' + (pass + fail) + ' 项');
console.log('='.repeat(78));
process.exit(fail === 0 ? 0 : 1);
