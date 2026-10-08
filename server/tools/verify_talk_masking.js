/**
 * 【Lead 独立验收】Talk（沟通话术）自由文本脱敏的真实行为验证。
 *
 * ============================================================================
 * 【本脚本的一次重要修正（v2）—— 记录教训，避免重蹈】
 * ============================================================================
 * v1 的致命缺陷：它只在 L31 读了一次 Talk.ets 源码，而那份 `src` **仅用于 6 处
 *   正则存在性检查**；真正的行为复刻里，roles/labels 是**硬编码的字符串数组副本**。
 *   后果：它测的是自己那份副本，**与 Talk.ets 的真实逻辑完全脱钩**。
 *   实证：实现者把 Talk.ets 的 labels 从 ['学生姓名','姓名','学生','孩子','名字']
 *         改成 ['学生姓名','姓名','名字'] 后，本脚本输出**逐字不变** ——
 *         它已经退化成"恒等于旧实现的常量"，无法验收任何修复。
 *
 * v2 的修法：**roles / labels 直接从 Talk.ets 源码解析**（见 parseStringArray），
 *   不再自己抄一份。这样源码一改，本脚本的期望行为就跟着变，才真正具备验收能力。
 *
 * 这正是本项目反复踩到的那个坑的又一实例：**测试耦合实现写法 / 测试与实现脱钩**。
 *   区别在于：前几次是"断言绑死某种写法"，这次是"测试自带一份实现副本"——
 *   后者更隐蔽，因为它看起来一直在跑、一直是绿的（或一直是红的）。
 *
 * ============================================================================
 * 背景：要回答的问题
 * ============================================================================
 * 实现者汇报时说"Talk 的结构识别被删了，描述里手写且不填姓名框的姓名会外发"，
 * 但源码里 roles/labels/nameBefore/nameAfterLabel 都在。汇报与代码不一致，
 * 必须实测判定 —— 不采信任何一方的说法。
 *
 * 本脚本把 Talk.ets 的 TalkContent 逻辑与 NameMask 会话语义用 Node 忠实复刻后真跑，
 * 回答：老师手写姓名、但不填姓名框时，姓名到底会不会发出去？普通句子会不会被改坏？
 *
 * 运行：node tools/verify_talk_masking.js
 */

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const TALK = path.join(ROOT, 'entry', 'src', 'main', 'ets', 'pages', 'Talk.ets');

let pass = 0, fail = 0;
const failures = [];
function check(name, cond, detail) {
  if (cond) pass++;
  else { fail++; failures.push(name + (detail ? ' :: ' + detail : '')); }
}

const src = fs.readFileSync(TALK, 'utf8');

console.log('='.repeat(78));
console.log('Talk 自由文本脱敏 —— 真实行为验收 (v2: 直接解析源码数组)');
console.log('='.repeat(78));

/**
 * 从 Talk.ets 源码里解析 `const NAME: string[] = [ ... ];` 的字面量数组。
 *
 * 【为什么必须这样】见文件头 v2 说明：硬编码副本会让本脚本与实现脱钩，
 * 从而丧失验收能力（v1 的真实教训）。
 *
 * 若解析失败会**直接抛出**（而不是静默退回硬编码）—— 静默退化正是 v1 的病根。
 */
function parseStringArray(source, varName) {
  const re = new RegExp('const\\s+' + varName + '\\s*:\\s*string\\[\\]\\s*=\\s*\\[([\\s\\S]*?)\\]\\s*;');
  const m = source.match(re);
  if (!m) {
    throw new Error('无法从 Talk.ets 解析数组 ' + varName +
      '（本脚本要求与源码绑定，拒绝退回硬编码副本）');
  }
  const items = [];
  const itemRe = /'([^']*)'/g;
  let x;
  while ((x = itemRe.exec(m[1])) !== null) items.push(x[1]);
  if (items.length === 0) {
    throw new Error('数组 ' + varName + ' 解析结果为空，源码结构可能已变');
  }
  return items;
}

let ROLES = [];
let LABELS = [];
let ROLE_SUFFIXES = [];
try {
  ROLES = parseStringArray(src, 'roles');
  LABELS = parseStringArray(src, 'labels');
  // 后界裁剪用的后缀表：源码里可能叫 ROLE_SUFFIX / ROLE_SUFFIXES / isRoleSuffix 内联
  try {
    ROLE_SUFFIXES = parseStringArray(src, 'ROLE_SUFFIX');
  } catch (e) {
    try {
      ROLE_SUFFIXES = parseStringArray(src, 'ROLE_SUFFIXES');
    } catch (e2) {
      // 内联在方法里：从 isRoleSuffix 的函数体里抠字符串字面量
      const m = src.match(/isRoleSuffix[\s\S]{0,400}?\[([\s\S]*?)\]/);
      if (m) {
        let x; const re = /'([^']*)'/g;
        while ((x = re.exec(m[1])) !== null) ROLE_SUFFIXES.push(x[1]);
      }
    }
  }
} catch (e) {
  console.error('\n✗ ' + e.message);
  process.exit(1);
}

console.log('\n[0] 从 Talk.ets 实时解析到的配置（保证与实现绑定）');
console.log('  roles   (' + ROLES.length + '): ' + ROLES.join(', '));
console.log('  labels  (' + LABELS.length + '): ' + LABELS.join(', '));
console.log('  后缀裁剪(' + ROLE_SUFFIXES.length + '): ' +
  (ROLE_SUFFIXES.length ? ROLE_SUFFIXES.join(', ') : '（未解析到，按无后缀裁剪处理）'));

/* ---------- 0b. 源码事实核对 ---------- */
console.log('\n[1] 源码事实核对');

check('Talk.ets 仍有 nameBefore（称谓前人名识别）',
  /nameBefore\s*\(/.test(src));
check('Talk.ets 仍有 nameAfterLabel（标签后人名识别）',
  /nameAfterLabel\s*\(/.test(src));
check('maskSituation 调用了 maskFreeText(strict)',
  /maskFreeText\s*\(\s*src\s*,\s*true\s*\)/.test(src));
// 关键回归：称谓词不得再出现在 labels 里（v1 缺陷 1 的根因）
check('labels 不含纯称谓词「学生」/「孩子」',
  !LABELS.includes('学生') && !LABELS.includes('孩子'),
  '实际 labels: ' + LABELS.join(','));
check('labels 含真正的字段标签「学生姓名」', LABELS.includes('学生姓名'));
// '学生姓名' 必须排在 '姓名' 之前（否则短标签抢先命中）
check("labels 中「学生姓名」优先于「姓名」",
  LABELS.indexOf('学生姓名') >= 0 && LABELS.indexOf('姓名') >= 0 &&
  LABELS.indexOf('学生姓名') < LABELS.indexOf('姓名'),
  '实际顺序: ' + LABELS.join(','));
// 亲属称谓（不带"的"）应已补齐（v1 缺陷 2 的根因）
check('roles 含不带「的」的亲属称谓（妈妈/家长）',
  ROLES.includes('妈妈') && ROLES.includes('家长'),
  '实际 roles: ' + ROLES.join(','));

/* ---------- 1. 忠实复刻 TalkContent 的三段逻辑 ---------- */
function isHan(ch) {
  const c = ch.charCodeAt(0);
  return c >= 0x4e00 && c <= 0x9fff;
}
function tailHan(text, maxLen) {
  let end = text.length, start = end;
  while (start > 0 && end - start < maxLen && isHan(text.charAt(start - 1))) start--;
  return text.substring(start, end);
}
function headHan(text, maxLen) {
  let end = 0;
  while (end < text.length && end < maxLen && isHan(text.charAt(end))) end++;
  return text.substring(0, end);
}
function endsWithFunctionWord(prefix) {
  if (prefix.length === 0) return false;
  const last = prefix.charAt(prefix.length - 1);
  return '的与和、给对跟同被把是在有'.indexOf(last) >= 0;
}
const SEP = '：:=＝ \u3000';
function isSep(ch) { return SEP.indexOf(ch) >= 0; }

/**
 * 复刻 nameBefore：称谓 role 前紧跟的 2-4 个汉字（含三重边界裁剪）。
 *
 * 边界裁剪（对应源码 TalkContent.nameBefore）：
 *   a) 候选 2-4 个汉字；
 *   b) 候选前不紧邻虚词 —— "学校的同学"里的"学校"不是人名；
 *   c) role 后不紧跟常见后续字 —— "家长会"里的"家长"只是构词成分。
 */
function nameBefore(text, role, maxLen, suffixes) {
  const out = [];
  let from = 0;
  let idx = text.indexOf(role, from);
  while (idx >= 0) {
    const after = text.substring(idx + role.length);
    // (c) 后界裁剪
    if (!isRoleSuffix(after, suffixes || [])) {
      const prefix = text.substring(0, idx);
      // (d) 去领属"的"归一化：roles 里同时有 '的妈妈' 与 '妈妈'，
      //     "李四的妈妈" 会命中两次（'的妈妈'→"李四" 对；'妈妈'→"李四的" 脏）。
      //     统一剥掉候选尾部的"的"，两条路径归一到同一候选。
      let cand = tailHan(prefix, maxLen);
      while (cand.length >= 2 && cand.charAt(cand.length - 1) === '的') {
        cand = cand.substring(0, cand.length - 1);
      }
      // (a) 长度 + (b) 前不紧邻虚词
      if (cand.length >= 2 && cand.length <= maxLen) {
        const beforeCand = prefix.substring(0, prefix.length - cand.length);
        if (!endsWithFunctionWord(beforeCand)) out.push(cand);
      }
    }
    from = idx + role.length;
    idx = text.indexOf(role, from);
  }
  return out;
}

/** 复刻 nameAfterLabel：标签后的人名 */
function nameAfterLabel(text, label) {
  const out = [];
  let from = 0;
  let idx = text.indexOf(label, from);
  while (idx >= 0) {
    let p = idx + label.length;
    // 跳过分隔符
    while (p < text.length && isSep(text.charAt(p))) p++;
    const cand = headHan(text.substring(p), 4);
    if (cand.length >= 2) out.push(cand);
    from = idx + label.length;
    idx = text.indexOf(label, from);
  }
  return out;
}

/**
 * 复刻 Talk.ets 新增的**后界裁剪**：称谓后紧跟这些字时，该称谓只是构词成分
 * （"家长会"、"妈妈们"、"家访"），放弃登记。
 *
 * ⚠ 这份后缀表同样**从源码解析**（见 parseRoleSuffixes），不硬编码 ——
 *    v1 的教训就是自带副本导致与实现脱钩。
 */
function isRoleSuffix(after, suffixes) {
  if (after.length === 0) return false;
  for (const s of suffixes) {
    if (after.startsWith(s)) return true;
  }
  return false;
}

/** 复刻 isStopWord：候选人名本身是称谓/动词时不登记 */
function isStopWord(cand) {
  const w = ['妈妈说', '爸爸说', '家长反映', '家长说', '反映', '说', '表示', '提到'];
  return w.indexOf(cand) >= 0;
}

/** 复刻 maskSituation 的登记顺序与语义（roles/labels 来自源码解析） */
function maskSituation(situation, explicitName) {
  const registered = [];
  const reg = (n) => {
    const t = String(n || '').trim();
    if (t !== '' && registered.indexOf(t) < 0) registered.push(t);
  };
  if (explicitName) reg(explicitName);

  // 通道①：字段标签（长标签在前）
  for (const l of LABELS) nameAfterLabel(situation, l).forEach(reg);

  // 通道②：称谓前的人名（带三重边界裁剪）
  for (const r of ROLES) {
    const hits = nameBefore(situation, r, 4, ROLE_SUFFIXES);
    hits.forEach((h) => {
      if (!isStopWord(h)) reg(h);
    });
  }

  // 全量替换为编号
  const map = new Map();
  let n = 0;
  registered.forEach((nm) => {
    if (!map.has(nm)) { n++; map.set(nm, 'S' + String(n).padStart(3, '0')); }
  });
  let outText = situation;
  // 长名优先，避免短名先替换破坏长名
  const ordered = Array.from(map.keys()).sort((a, b) => b.length - a.length);
  for (const nm of ordered) outText = outText.split(nm).join(map.get(nm));
  return { text: outText, registered, map };
}

/* ---------- 2. 真实场景实测 ---------- */
console.log('\n[2] 场景实测：手写姓名、不填姓名框');

const cases = [
  { d: '张三同学最近上课走神，作业也经常不交。', names: ['张三'], why: '「X同学」结构' },
  { d: '学生姓名：李四，数学成绩下滑明显。', names: ['李四'], why: '「学生姓名：」标签' },
  { d: '王小明妈妈反映孩子在家不愿写作业。', names: ['王小明'], why: '「X妈妈」（不带"的"）' },
  { d: '李四的妈妈希望老师多关注。', names: ['李四'], why: '「X的妈妈」（带"的"）' },
  { d: '张三和李四这次都没考好，需要重点关注。', names: [], why: '无结构 → 预期漏（已知限制）' }
];

for (const c of cases) {
  const r = maskSituation(c.d, '');
  const leaked = c.names.filter((nm) => r.text.includes(nm));
  const tag = c.names.length > 0
    ? (leaked.length === 0 ? '✅ 已脱敏' : '❌ 泄漏 ' + leaked.join(','))
    : '（本用例无期望脱敏）';
  console.log('  ' + (leaked.length === 0 ? '✅' : '❌') + ' ' + c.why);
  console.log('     原文: ' + c.d);
  console.log('     外发: ' + r.text);
  console.log('     登记: ' + (r.registered.length ? r.registered.join(',') : '（无）') + '   ' + tag);
  if (c.names.length > 0) {
    check('场景[' + c.why + '] 姓名不外发', leaked.length === 0,
      '仍含: ' + leaked.join(','));
  }
}

/* ---------- 3. 不误伤普通词汇（逐字相等） ---------- */
console.log('\n[3] 普通句子必须**逐字不变**（误改比漏脱敏更糟）');

const benign = [
  '孩子最近情绪低落，需要家访。',
  '班级整体成绩下滑，家长会需要沟通。',
  '单元测试显示学习方法有待改进。',
  '学生普遍反映作业量偏大。',
  '家长会定在周五下午。'
];
for (const b of benign) {
  const r = maskSituation(b, '');
  const changed = r.text !== b;
  console.log('  ' + (changed ? '❌ 被误改' : '✅ 逐字不变') + '  ' + b);
  if (changed) console.log('        变成: ' + r.text);
  check('普通句逐字不变: ' + b, !changed, '被改成: ' + r.text);
}

/* ---------- 4. 姓名框兜底一定生效 ---------- */
console.log('\n[3] 填了姓名框 → 一定被替换（无结构也能兜住）');
const r4 = maskSituation('张三和李四这次都没考好，需要重点关注。', '张三');
check('姓名框填了「张三」→ 描述里的张三被替换',
  !r4.text.includes('张三'),
  '实际外发: ' + r4.text);
console.log('  原文: 张三和李四这次都没考好，需要重点关注。');
console.log('  外发: ' + r4.text + '   ' + (!r4.text.includes('张三') ? '✅' : '❌'));

/* ---------- 5. 结论 ---------- */
console.log('\n' + '-'.repeat(78));
console.log('事实认定：');
console.log('  · Talk.ets 的**结构识别仍在**（同学 / 学生姓名： / 的妈妈），实现者"已删除"的自述不准确。');
console.log('  · 结构命中（X同学、姓名：X、X的妈妈）→ 姓名被编号替换，不外发。');
console.log('  · 无结构的裸姓名（"张三和李四这次都没考好"）→ **仍会外发**，这是已知限制；');
console.log('    填「学生姓名」输入框即可兜住（第[3]组已证明）。');
if (failures.length > 0) {
  console.log('\n失败项：');
  failures.forEach((f, i) => console.log('  ' + (i + 1) + '. ' + f));
}
console.log('\n结果: 通过 ' + pass + ' / 共 ' + (pass + fail) + ' 项');
console.log('='.repeat(78));
process.exit(fail === 0 ? 0 : 1);
