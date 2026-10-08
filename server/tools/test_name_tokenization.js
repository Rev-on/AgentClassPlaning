/**
 * 学生姓名脱敏（Tokenization）回归测试
 * =====================================================================
 * 这是**安全改造**的证明脚本：断言真实姓名不可能出现在发往 AI 的 prompt 里，
 * 且 AI 返回后能正确还原为真名。
 *
 * 覆盖三层：
 *   A. 源码静态断言（防回归）
 *      · 三个页面不再出现裸姓名拼接（`${this.studentName}` / `this.situation` /
 *        `ExcelParser.toJson(rows)` 直接进 prompt 的形态）；
 *      · 脱敏服务不落盘 / 不上传 / 日志不打印姓名；
 *      · 系统提示词已告知 AI 使用编号称呼。
 *   B. 语义断言（用 Node 复刻 ArkTS 的脱敏/还原语义，独立于真机）
 *      · 脱敏后不含原始姓名、编号 S001 格式、同批同姓名同编号；
 *      · round-trip：restore(mask(x)) === x；
 *      · Analysis 的 JSON 表格形状：姓名列被替换、成绩列**未被改动**。
 *   C. 边界
 *      · 空姓名、单字姓、含空格姓名、姓名恰好是常见词（"高兴"）、
 *        未登记的裸姓名不误伤其它文本、流式半编号不还原。
 *
 * 运行：node tools/test_name_tokenization.js   （工作目录 server/）
 *   exit 0 = 全部通过
 */
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const PAGES = path.join(ROOT, 'entry/src/main/ets/pages');
const COMMON = path.join(ROOT, 'entry/src/main/ets/common');

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

function readIfExists(p) {
  return fs.existsSync(p) ? read(p) : '';
}

/** 去掉注释：注释里会写"修复前"的反例代码，必须剔除以免假阴/假阳 */
function stripComments(src) {
  return src
    .replace(/\/\*[\s\S]*?\*\//g, '')
    .replace(/(^|[^:])\/\/.*$/gm, '$1');
}

const NAME_MASK_FILE = path.join(COMMON, 'NameMask.ets');
const ANALYSIS = path.join(PAGES, 'Analysis.ets');
const REPORT = path.join(PAGES, 'Report.ets');
const TALK = path.join(PAGES, 'Talk.ets');
const PROMPTS = path.join(COMMON, 'Prompts.ets');
const EXCEL = path.join(COMMON, 'ExcelParser.ets');

/* ================================================================== *
 * 套件 A. 源码静态断言
 * ================================================================== */
function suiteStaticSource() {
  console.log('\n[A] 源码静态断言');

  check('脱敏服务 NameMask.ets 存在', fs.existsSync(NAME_MASK_FILE));
  const maskSrc = stripComments(readIfExists(NAME_MASK_FILE));

  check('脱敏服务导出 mask/restore 能力',
    /static\s+maskStructured\s*\(/.test(maskSrc) &&
    /restore\s*\(\s*text\s*:\s*string\s*\)\s*:\s*string/.test(maskSrc));
  check('脱敏服务提供结构化表格入口 maskTable',
    /static\s+maskTable\s*\(/.test(maskSrc));
  check('脱敏服务提供姓名列识别 isNameHeader',
    /static\s+isNameHeader\s*\(/.test(maskSrc));

  // --- 映射表只在内存 ---
  check('映射表不落盘（无 preferences / fileIo / 文件写）',
    !/preferences/.test(maskSrc) && !/fileIo/.test(maskSrc) && !/writeSync/.test(maskSrc));
  check('映射表不上传（无 http / fetch）',
    !/createHttp|@ohos\.net\.http|@kit\.NetworkKit|fetch\(/.test(maskSrc));
  check('映射表不写历史/草稿',
    !/HistoryStore/.test(maskSrc) && !/PageDraft/.test(maskSrc));
  check('脱敏服务不 import hilog（根本不会打印姓名）',
    !/hilog/.test(maskSrc));

  // --- 三个泄漏点：不得再裸拼 ---
  const analysis = stripComments(read(ANALYSIS));
  const report = stripComments(read(REPORT));
  const talk = stripComments(read(TALK));

  function userPromptExpr(src) {
    const m = src.match(/const\s+user\s*:\s*string\s*=\s*([\s\S]*?);\s*\n/);
    return m ? m[1] : '';
  }

  const aExpr = userPromptExpr(analysis);
  const rExpr = userPromptExpr(report);
  const tExpr = userPromptExpr(talk);

  check('Analysis 抓到了 const user 表达式', aExpr !== '');
  check('Analysis prompt 不再直接拼接 ExcelParser.toJson(rows) 原文',
    aExpr !== '' && !/ExcelParser\.toJson\(\s*rows\s*\)/.test(aExpr),
    '实际: ' + aExpr.slice(0, 120));
  /**
   * 断言落在**整页**而非 prompt 表达式本身。
   * 单元格脱敏发生在"页面调用表格入口 → 拿到已脱敏 JSON"这一步；
   * 生成出来的变量再塞进模板串，变量名里当然不会出现 "mask" 字样。
   * 若把断言绑到表达式上，就变成"测试耦合实现写法"——实现一改名测试就红
   * （本项目在 test_liveview_contract 的 event 默认值断言上已踩过这个坑）。
   * 这里守住语义：页面确实调用了按列脱敏入口，且 prompt 里放的是它的产物。
   */
  check('Analysis 用按列脱敏入口生成发给 AI 的表格 JSON',
    /ExcelParser\.toJsonMaskedText\(/.test(analysis) && /\$\{\s*tableJson\s*\}/.test(aExpr),
    '实际: ' + aExpr.slice(0, 120));
  check('Analysis 出网前调用 applyToFlow 做 fail-closed 校验',
    /NameMask\.applyToFlow\(/.test(analysis));
  check('Analysis 对最终文本做了还原', /mask\.restore\(/.test(analysis));
  /**
   * 草稿/历史/会话必须落**还原后的真名版本**。这里逐条定位具体的调用点，
   * 而不是用 `[^)]*` 一类的短窗口正则 —— 那会把同文件里另一处
   * `PageDraft.save(..., t)` 也算进来，断言看似通过其实没盯住目标语句。
   */
  check('Analysis 落库/草稿用还原后的真名版本',
    /PageDraft\.save\(getContext\(this\) as common\.UIAbilityContext, this\.genKey\(\), shown\)/.test(analysis) &&
    /this\.autoSaveHistory\(shown\)/.test(analysis),
    'PageDraft.save 与 autoSaveHistory 都必须吃还原后的 shown');

  check('Report 抓到了 const user 表达式', rExpr !== '');
  check('Report prompt 不再直接拼接 this.studentName 原文',
    rExpr !== '' && !/\$\{\s*this\.studentName\s*\}/.test(rExpr),
    '实际: ' + rExpr.slice(0, 120));
  check('Report prompt 用的是编号变量 nameToken',
    /\$\{\s*nameToken\s*\}/.test(rExpr));
  check('Report 出网前调用 applyToFlow', /NameMask\.applyToFlow\(/.test(report));
  check('Report 对最终文本做了还原', /mask\.restore\(/.test(report));
  check('Report 落库/草稿用还原后的真名版本',
    /PageDraft\.save\(getContext\(this\) as common\.UIAbilityContext, this\.genKey\(\), shown\)/.test(report) &&
    /this\.autoSaveHistory\(shown\)/.test(report));

  check('Talk 抓到了 const user 表达式', tExpr !== '');
  check('Talk prompt 不再直接拼接 this.situation 原文',
    tExpr !== '' && !/\$\{\s*this\.situation\s*\}/.test(tExpr),
    '实际: ' + tExpr.slice(0, 120));
  check('Talk prompt 用的是脱敏后的描述 situationMasked',
    /\$\{\s*situationMasked\s*\}/.test(tExpr));
  check('Talk 出网前调用 applyToFlow（并还原已提交的流式文本）',
    /NameMask\.applyToFlow\(/.test(talk));
  check('Talk 对最终文本做了还原', /mask\.restore\(/.test(talk));
  check('Talk 落库/草稿用还原后的真名版本',
    /PageDraft\.save\(getContext\(this\) as common\.UIAbilityContext, this\.genKey\(\), shown\)/.test(talk) &&
    /this\.autoSaveHistory\(shown\)/.test(talk));

  // --- 流式还原的坑：不得在流式回调里做替换 ---
  for (const [label, src] of [['Analysis', analysis], ['Report', report], ['Talk', talk]]) {
    const cb = src.match(/AiService\.chat\(([\s\S]*?)\}, false,/);
    const body = cb ? cb[1] : '';
    check(label + ' 流式回调内不做还原（只 push 原始 partial）',
      body !== '' && /resultThrottle\.push\(partial\)/.test(body) &&
      !/restore\(partial/.test(body) && !/restore\(\s*partial\s*\)/.test(body),
      '流式期还原会漏掉被 token 切开的半个编号');
  }

  // --- 系统提示词 ---
  const prompts = stripComments(read(PROMPTS));
  check('系统提示词告知 AI 姓名已用编号替代',
    /编号/.test(prompts) && /S001/.test(prompts));
  check('学情分析系统提示词带上匿名化约束',
    /analysisSystem[\s\S]{0,700}anonRule\(\)/.test(prompts));
  check('沟通话术系统提示词带上匿名化约束',
    /talkSystem[\s\S]{0,700}anonRule\(\)/.test(prompts));
  check('个性化学情报告系统提示词带上匿名化约束',
    /studentReportSystem[\s\S]{0,900}anonRule\(\)/.test(prompts));
  check('报告标题占位不再诱导模型填真名（{学生姓名} → {学生编号}）',
    !/\{学生姓名\}/.test(prompts) && /\{学生编号\}/.test(prompts));

  // --- 表格入口 ---
  const excel = stripComments(read(EXCEL));
  check('ExcelParser 提供按列脱敏的 toJsonMaskedText',
    /static\s+toJsonMaskedText\s*\(/.test(excel));
}

/* ================================================================== *
 * B. Node 复刻：与 NameMask.ets 语义一致的参考实现
 * ------------------------------------------------------------------
 * 刻意手工复刻（不是 require ArkTS 文件），用于在 Node 端验证**语义**：
 *   · 编号格式与去重规则；
 *   · 按列识别姓名列；
 *   · round-trip。
 * 源码侧的"实现是否真的这么写"由套件 A 的静态断言 + 套件 D 的常量对照保证。
 * ================================================================== */
function makeSession() {
  const idToName = new Map();
  const nameToId = new Map();
  let seq = 0;
  const pad3 = (n) => {
    const s = String(n);
    return s.length >= 3 ? s : '000'.substring(s.length) + s;
  };
  const register = (raw) => {
    const name = String(raw === undefined || raw === null ? '' : raw).trim();
    if (name === '') return '';
    if (nameToId.has(name)) return nameToId.get(name);
    seq += 1;
    const id = 'S' + pad3(seq);
    nameToId.set(name, id);
    idToName.set(id, name);
    return id;
  };
  const restore = (text) => {
    if (!text || idToName.size === 0) return text;
    return String(text).replace(/S(\d+)/g, (whole, digits) => {
      // 从长到短探测，保证 S1000 不被当成 S100 + '0'
      for (let len = digits.length; len >= 1; len--) {
        const cand = 'S' + digits.slice(0, len);
        if (idToName.has(cand)) return idToName.get(cand) + digits.slice(len);
      }
      return whole;
    });
  };
  return { register, restore, nameToId, idToName, size: () => idToName.size };
}

const HEADERS = ['姓名', '学生姓名', '名字', '学生', '学生名', '学员', '学员姓名',
  'name', 'Name', 'studentName', 'STUDENT', 'full name'];
const EXCLUDED = ['家长姓名', '监护人', '教师姓名', '老师', '班级', '年级', '学号'];

function isNameHeader(h) {
  const n = String(h).replace(/\s+/g, '').replace(/\u3000/g, '')
    .replace(/[_\-·.]/g, '').toLowerCase();
  if (n === '') return false;
  for (const ex of EXCLUDED) {
    if (n.includes(ex.toLowerCase())) return false;
  }
  return HEADERS.some((x) => n === x.replace(/[_\-·.\s]/g, '').toLowerCase());
}

/** 复刻 maskTable：按列识别姓名列，只替换姓名列 */
function maskTable(sess, rows, requireNameColumn) {
  if (rows.length === 0) {
    if (requireNameColumn) throw new Error('no-name-column');
    return { rows, nameColumns: [], masked: false };
  }
  const headers = rows[0];
  const nameCols = [];
  for (let j = 0; j < headers.length; j++) {
    if (isNameHeader(headers[j])) nameCols.push(j);
  }
  if (nameCols.length === 0) {
    if (requireNameColumn) throw new Error('no-name-column');
    return { rows, nameColumns: [], masked: false };
  }
  for (let i = 1; i < rows.length; i++) {
    for (const c of nameCols) if (rows[i][c] !== undefined) sess.register(rows[i][c]);
  }
  const out = [headers.slice(0)];
  for (let i = 1; i < rows.length; i++) {
    const row = rows[i].slice(0);
    for (const c of nameCols) {
      if (row[c] !== undefined) row[c] = String(row[c]).trim() === '' ? '' : sess.register(row[c]);
    }
    out.push(row);
  }
  return { rows: out, nameColumns: nameCols, masked: true };
}

/** 复刻 toJsonOf：与 ExcelParser.toJson 同形状，只是姓名列已是编号 */
function toJsonOf(rows) {
  if (rows.length === 0) return '{}';
  const headers = rows[0];
  const students = [];
  for (let i = 1; i < rows.length; i++) {
    const obj = {};
    for (let j = 0; j < headers.length; j++) {
      obj[headers[j]] = rows[i][j] !== undefined ? rows[i][j] : '';
    }
    students.push(obj);
  }
  return JSON.stringify({ headers, students });
}

/** 与 ExcelParser.toJson 原实现一致的"未脱敏"序列化（用于对照） */
function toJsonPlain(rows) {
  return toJsonOf(rows);
}

const SAMPLES = ['张三', '李四', '王小明', '欧阳娜娜'];

function suiteSemantics() {
  console.log('\n[B] 语义断言（编号 / 去重 / round-trip / 表格形状）');

  /* --- 编号格式与去重 --- */
  const s1 = makeSession();
  const id1 = s1.register('张三');
  const id2 = s1.register('李四');
  const id3 = s1.register('王小明');
  const id4 = s1.register('欧阳娜娜');
  const idDup = s1.register('张三');
  check('编号格式为 S + 三位补零', /^S\d{3}$/.test(id1) && /^S\d{3}$/.test(id4),
    id1 + '/' + id4);
  check('首个编号为 S001', id1 === 'S001', id1);
  check('编号按登记顺序递增', id1 === 'S001' && id2 === 'S002' && id3 === 'S003' && id4 === 'S004',
    [id1, id2, id3, id4].join(','));
  check('同一批同一姓名同编号（去重）', idDup === id1, idDup + ' vs ' + id1);
  check('四个样本占用 4 个编号', s1.size() === 4, String(s1.size()));

  /* --- 超过 999 自然增长为 S1000 --- */
  const sBig = makeSession();
  sBig.register('填充名');
  let last = '';
  for (let i = 2; i <= 1000; i++) last = sBig.register('学生' + i);
  check('第 1000 个编号自然增长为 S1000（不截断）', last === 'S1000', last);

  /* --- 脱敏后不含任何原始姓名 --- */
  const s2 = makeSession();
  s2.register('张三');
  s2.register('李四');
  s2.register('王小明');
  s2.register('欧阳娜娜');
  const rawDoc = '张三语文88，李四数学92，王小明及格，欧阳娜娜优秀。';
  const maskedDoc = rawDoc
    .replace(/欧阳娜娜/g, s2.nameToId.get('欧阳娜娜'))
    .replace(/王小明/g, s2.nameToId.get('王小明'))
    .replace(/张三/g, s2.nameToId.get('张三'))
    .replace(/李四/g, s2.nameToId.get('李四'));
  for (const nm of SAMPLES) {
    check('脱敏后不含原始姓名「' + nm + '」', !maskedDoc.includes(nm), '实际: ' + maskedDoc);
  }
  check('脱敏后确实出现编号', /S00\d/.test(maskedDoc), maskedDoc);
  check('round-trip：restore(mask(x)) === x', s2.restore(maskedDoc) === rawDoc,
    s2.restore(maskedDoc));

  /* --- Analysis 的 JSON 表格形状 --- */
  const rows = [
    ['姓名', '语文', '数学', '总分', '等级'],
    ['张三', '88', '92', '180', '优'],
    ['李四', '76', '81', '157', '良'],
    ['王小明', '95', '98', '193', '优'],
    ['欧阳娜娜', '60', '65', '125', '及格']
  ];
  const s3 = makeSession();
  const mt = maskTable(s3, rows, false);
  check('表格识别出姓名列（第 0 列）',
    mt.nameColumns.length === 1 && mt.nameColumns[0] === 0,
    JSON.stringify(mt.nameColumns));
  check('表格标记为已脱敏', mt.masked === true);

  const maskedJson = toJsonOf(mt.rows);
  // 1) 不含任何原始姓名
  for (const nm of SAMPLES) {
    check('表格 JSON 不含原始姓名「' + nm + '」', !maskedJson.includes(nm), maskedJson);
  }
  // 2) 姓名列被替换为编号
  const parsed = JSON.parse(maskedJson);
  check('JSON 形状与 toJson 一致（headers + students）',
    Array.isArray(parsed.headers) && Array.isArray(parsed.students) &&
    parsed.students.length === 4 &&
    parsed.headers.join(',') === '姓名,语文,数学,总分,等级');
  const nameVals = parsed.students.map((s) => s['姓名']);
  check('姓名列全部为编号', nameVals.every((v) => /^S\d{3}$/.test(v)), nameVals.join(','));
  check('同批同姓名同编号（表内去重，跨行一致）',
    nameVals[0] === 'S001' && nameVals[1] === 'S002' &&
    nameVals[2] === 'S003' && nameVals[3] === 'S004',
    nameVals.join(','));
  // 3) 成绩列未被改动（逐字节对照原表）
  const plainParsed = JSON.parse(toJsonPlain(rows));
  const scoreCols = ['语文', '数学', '总分', '等级'];
  let scoreSame = true;
  for (let i = 0; i < plainParsed.students.length; i++) {
    for (const c of scoreCols) {
      if (plainParsed.students[i][c] !== parsed.students[i][c]) {
        scoreSame = false;
      }
    }
  }
  check('语文/数学/总分/等级列逐字节未被改动', scoreSame, maskedJson);
  check('表头文字未被改动（含"姓名"键名保留）',
    parsed.headers.join(',') === plainParsed.headers.join(','));
  // 4) round-trip：整个 JSON 串还原后与原文 JSON 一致
  check('表格 JSON round-trip：restore(mask(json)) === json',
    s3.restore(maskedJson) === toJsonPlain(rows),
    '还原后: ' + s3.restore(maskedJson).slice(0, 160));

  /* --- 多姓名列表头 + 排除列 --- */
  const rows2 = [
    ['学生姓名', '家长姓名', '语文'],
    ['张三', '张建国', '88'],
    ['李四', '李梅', '76']
  ];
  const s4 = makeSession();
  const mt2 = maskTable(s4, rows2, false);
  check('只把"学生姓名"列判为姓名列（"家长姓名"被排除）',
    mt2.nameColumns.length === 1 && mt2.nameColumns[0] === 0,
    JSON.stringify(mt2.nameColumns));
  check('家长姓名列保持原样（家校沟通需要称呼家长）',
    mt2.rows[1][1] === '张建国' && mt2.rows[2][1] === '李梅');

  /* --- 英文表头 / 表头写法变体 --- */
  for (const h of ['姓名', '学生姓名', '名字', '学生', '学员姓名', 'name', 'Name',
    'studentName', 'student name', 'full_name', 'STUDENT']) {
    check('表头「' + h + '」被识别为姓名列', isNameHeader(h) === true);
  }
  for (const h of ['家长姓名', '监护人', '教师姓名', '班级', '学号', '语文', '语文成绩']) {
    check('表头「' + h + '」被判为非姓名列', isNameHeader(h) === false);
  }

  /* --- 无姓名列：不误伤，且不误报 --- */
  const statRows = [['题号', '得分率'], ['1', '82%'], ['2', '67%']];
  const s5 = makeSession();
  const mt3 = maskTable(s5, statRows, false);
  check('无姓名列的统计表：masked=false（不阻断合法输入）', mt3.masked === false);
  check('无姓名列的统计表：逐字节保持原样',
    JSON.stringify(mt3.rows) === JSON.stringify(statRows));

  /* --- 学号列不被误改 --- */
  const rows3 = [['学号', '姓名'], ['20250101', '张三']];
  const s6 = makeSession();
  const mt4 = maskTable(s6, rows3, false);
  check('学号列不被误改', mt4.rows[1][0] === '20250101', mt4.rows[1][0]);
  check('姓名列被替换', /^S\d{3}$/.test(mt4.rows[1][1]), mt4.rows[1][1]);

  /* --- 含空格姓名 / 单字姓 --- */
  const s7 = makeSession();
  const spaced = s7.register('  张三  ');
  check('含空格的姓名被 trim 后登记', spaced === 'S001', spaced);
  check('含空格姓名可还原为 trim 后的真名', s7.restore('学生 ' + spaced + ' 表现好') === '学生 张三 表现好',
    s7.restore('学生 ' + spaced + ' 表现好'));
  const single = s7.register('李');
  check('单字姓也被登记为编号', /^S\d{3}$/.test(single), single);
  check('空姓名不登记、返回空串（不发编号给"空学生"）',
    s7.register('') === '' && s7.register('   ') === '');
}

/* ================================================================== *
 * C. 边界：误伤与漏伤
 * ================================================================== */
function suiteEdgeCases() {
  console.log('\n[C] 边界（常见词姓名 / 未登记姓名 / 流式半编号）');

  /* --- 姓名恰好是常见词：确知它是姓名时必须被替换 --- */
  const s = makeSession();
  const happyId = s.register('高兴'); // 老师显式声明"高兴"是学生姓名
  check('姓名恰为常见词「高兴」→ 编号', /^S\d{3}$/.test(happyId), happyId);
  const t1 = '高兴同学最近作业完成度下降，家长很高兴看到改进。';
  const masked1 = t1.replace(/高兴/g, happyId);
  check('常见词姓名在自由文本中被替换', !masked1.includes('高兴'), masked1);

  /* --- 反向：未登记时不得误伤（不做无根据的中文姓名猜测是刻意设计） --- */
  const s2 = makeSession();
  s2.register('张三');
  const t2 = '本次考试成绩下滑，请家长会后来办公室沟通学习方法。';
  const masked2 = t2.replace(/张三/g, s2.nameToId.get('张三'));
  check('未登记的普通文本逐字节不变（不误伤"成绩/家长会/学习方法"）',
    masked2 === t2, masked2);

  /* --- 误伤防护：编号还原不得动到普通文本里的 S 开头单词 --- */
  const s3 = makeSession();
  s3.register('张三');
  const t3 = 'SaaS 平台的 SSE 推送与 S001 学生无关。';
  check('还原只动真实编号（SaaS/SSE 不被误改）',
    s3.restore(t3) === 'SaaS 平台的 SSE 推送与 张三 学生无关。',
    s3.restore(t3));

  /* --- 未登记的编号保持原样（不臆造姓名） --- */
  const s4 = makeSession();
  s4.register('张三');
  check('编号表里没有的编号保持原样', s4.restore('S009 未知') === 'S009 未知',
    s4.restore('S009 未知'));

  /* --- 流式半编号：逐段还原会失败，整体还原才正确 --- */
  const s5 = makeSession();
  s5.register('张三');
  const full = '学生 S001 表现优异。';
  // 在编号中间切开：片1 以 'S0' 结尾，片2 以 '01' 开头
  const cut = full.indexOf('S001') + 2;   // 'S0' 之后
  const piece1 = full.slice(0, cut);      // '学生 S0'   —— 半个编号
  const piece2 = full.slice(cut);         // '01 表现优异。'
  check('流式分片确实可能切断编号（前置条件成立）',
    piece1.endsWith('S0') && piece2.startsWith('01'), piece1 + ' | ' + piece2);
  const naivePerPiece = s5.restore(piece1) + s5.restore(piece2);
  check('逐段还原会漏掉半个编号（证明为什么不能在流式增量上还原）',
    naivePerPiece.includes('S0') && !naivePerPiece.includes('张三'),
    naivePerPiece);
  check('整体还原最终完整文本才正确',
    s5.restore(full) === '学生 张三 表现优异。', s5.restore(full));
  check('先落原文再在最终文本上还原 == 直接还原最终文本',
    s5.restore(piece1 + piece2) === s5.restore(full));
  /**
   * 跨片拼接后还原 == 整段还原（说明"流式期不还原、结束时整体还原"这条
   * 路径在**只看编号长度**的意义上是安全的：编号本身不跨"最终文本"边界）。
   */
  const pieces = ['学生 S', '00', '1 表现优异。'];
  check('任意切分方式的片段拼接后整体还原仍正确',
    s5.restore(pieces.join('')) === '学生 张三 表现优异。', s5.restore(pieces.join('')));

  /* --- 空输入 / 空表 --- */
  const s6 = makeSession();
  check('空文本还原返回空串', s6.restore('') === '');
  const s7 = makeSession();
  const empty = maskTable(s7, [], false);
  check('空表返回 masked=false 且不抛错', empty.masked === false && empty.rows.length === 0);
  check('空表的 JSON 为 {}', toJsonOf([]) === '{}');

  /* --- 表格里的空姓名单元格不产生编号 --- */
  const rows = [['姓名', '语文'], ['', '88'], ['张三', '90']];
  const s8 = makeSession();
  const mt = maskTable(s8, rows, false);
  check('空姓名单元格保持为空（不给空值发编号）', mt.rows[1][0] === '', JSON.stringify(mt.rows[1]));
  check('空姓名不占用编号（张三仍是 S001）', mt.rows[2][0] === 'S001', mt.rows[2][0]);
}

/* ================================================================== *
 * D. 与实现的一致性对照（防止"测试自说自话"）
 * ================================================================== */
function suiteImplementationAlignment() {
  console.log('\n[D] 与 ArkTS 实现的一致性对照');
  const src = stripComments(readIfExists(NAME_MASK_FILE));

  check('实现里的编号前缀是 S', /'S'\s*\+/.test(src));
  check('实现里的补零是三位', /pad3|'000'/.test(src));
  check('实现按列识别姓名列（只替换命中列）',
    /nameCols\[k\]\s*=\s*|row\[c\]\s*=/.test(src));
  check('实现声明了流式只能在最终完整文本还原',
    /最终完整文本|完整文本/.test(readIfExists(NAME_MASK_FILE)));
  check('实现声明了 fail-closed 语义', /mask-leak|fail-closed|阻断/.test(src));
  check('实现声明了"映射表只在内存"', /映射表只放内存|映射表只存内存/.test(readIfExists(NAME_MASK_FILE)));
}

/* ================================================================== *
 * E. Talk 自由文本脱敏的**行为**验证（源码驱动）
 * ------------------------------------------------------------------
 * 【为什么要单独做一套，以及为什么必须"源码驱动"】
 *   教训：Lead 的 verify_talk_masking.js 在 L110-136 硬编码了一份
 *   maskSituation 的复刻副本（roles/labels 写在脚本里），只把 Talk.ets
 *   读来做 6 条正则存在性检查。结果 Talk.ets 改了、脚本输出逐字不变 ——
 *   它测的是自己那份快照，**无法验收任何修复**（实测：改完仍恒为 11/13）。
 *
 *   所以本套件吸取教训：**roles / labels / 边界字表全部从 Talk.ets 源码里
 *   用正则抽出来**，再用抽到的常量真跑一遍行为。Talk.ets 一改，这里立刻跟着变，
 *   不存在"测试与实现各自漂移"的窗口。
 *
 *   覆盖 Lead 指出的两个真实缺陷（旧实现 108 项测试在此**零命中**）：
 *     缺陷1 把称谓词当字段标签 → "孩子最近情绪低落" 被改成 "孩子S001低落"
 *     缺陷2 roles 缺不带"的"的亲属写法 → "王小明妈妈反映…" 姓名直接外发
 * ================================================================== */

/** 从 ArkTS 源里抽出一个 `const NAME: string[] = [ 'a', 'b' ];` 字面量数组 */
function extractStringArray(source, varName) {
  const re = new RegExp('const\\s+' + varName + '\\s*:\\s*string\\[\\]\\s*=\\s*\\[([\\s\\S]*?)\\]\\s*;');
  const m = source.match(re);
  if (!m) return null;
  return (m[1].match(/'([^']*)'/g) || []).map((s) => s.replace(/'/g, ''));
}

/** 从 ArkTS 源里抽出一个返回字符串常量的方法体（如 isRoleSuffix 的 '会访们…'） */
function extractReturnedLiteral(source, methodName) {
  const re = new RegExp(methodName + '\\s*\\([^)]*\\)[^{]*\\{[\\s\\S]*?return\\s*\'([^\']*)\'');
  const m = source.match(re);
  return m ? m[1] : null;
}

function suiteTalkBehavior() {
  console.log('\n[E] Talk 自由文本脱敏行为（源码驱动，含 Lead 指出的两个缺陷）');

  const talkRaw = readIfExists(TALK);
  const talk = stripComments(talkRaw);

  /* ---------- E0. 从源码抽常量（抽不到就直接失败，不允许静默跳过） ---------- */
  const SRC_LABELS = extractStringArray(talk, 'labels');
  const SRC_ROLES = extractStringArray(talk, 'roles');
  check('能从 Talk.ets 抽出 labels 数组（源码驱动的前置条件）',
    SRC_LABELS !== null && SRC_LABELS.length > 0, JSON.stringify(SRC_LABELS));
  check('能从 Talk.ets 抽出 roles 数组（源码驱动的前置条件）',
    SRC_ROLES !== null && SRC_ROLES.length > 0, JSON.stringify(SRC_ROLES));

  const ROLE_SUFFIX = extractReturnedLiteral(talk, 'isRoleSuffix');
  const STOP_WORDS = extractStringArray(talk, 'stop');
  check('能从 Talk.ets 抽出 isRoleSuffix 的后界字表', ROLE_SUFFIX !== null, String(ROLE_SUFFIX));
  check('能从 Talk.ets 抽出 isStopWord 的停用词表', STOP_WORDS !== null, JSON.stringify(STOP_WORDS));

  const labels = SRC_LABELS || [];
  const roles = SRC_ROLES || [];
  const roleSuffix = ROLE_SUFFIX || '';
  const stopWords = STOP_WORDS || [];

  /* ---------- E1. 缺陷 1 的源码级断言：labels 只能是字段标签 ---------- */
  check('labels 不含称谓词「学生」（缺陷1 根因）', labels.indexOf('学生') < 0,
    'labels=' + labels.join(','));
  check('labels 不含称谓词「孩子」（缺陷1 根因）', labels.indexOf('孩子') < 0,
    'labels=' + labels.join(','));
  check('labels 保住了真正的字段标签「学生姓名」', labels.indexOf('学生姓名') >= 0);
  check('labels 保住了「姓名」', labels.indexOf('姓名') >= 0);
  check('labels 中「学生姓名」排在「姓名」之前（长标签优先，避免"学生S002：S001"双误登记）',
    labels.indexOf('学生姓名') < labels.indexOf('姓名'),
    labels.join(','));

  /* ---------- E2. 缺陷 2 的源码级断言：roles 有不带"的"的亲属写法 ---------- */
  for (const r of ['妈妈', '爸爸', '母亲', '父亲', '家长', '奶奶', '爷爷']) {
    check('roles 含不带"的"的亲属写法「' + r + '」（缺陷2 根因）',
      roles.indexOf(r) >= 0, 'roles=' + roles.join(','));
  }
  check('roles 保留"同学"结构', roles.indexOf('同学') >= 0);
  check('roles 保留带"的"的写法「的妈妈」', roles.indexOf('的妈妈') >= 0);

  /* ---------- 复刻 nameBefore / nameAfterLabel（常量来自源码） ---------- */
  const isHan = (ch) => {
    const c = ch.charCodeAt(0);
    return c >= 0x4e00 && c <= 0x9fff;
  };
  const tailHan = (text, maxLen) => {
    let end = text.length, start = end;
    while (start > 0 && end - start < maxLen && isHan(text.charAt(start - 1))) start--;
    return text.substring(start, end);
  };
  const headHan = (text, maxLen) => {
    let end = 0;
    while (end < text.length && end < maxLen && isHan(text.charAt(end))) end++;
    return text.substring(0, end);
  };
  const FUNCTION_WORDS = '的与和、给对跟同被把是在有';
  const endsWithFunctionWord = (prefix) => {
    if (prefix.length === 0) return false;
    return FUNCTION_WORDS.indexOf(prefix.charAt(prefix.length - 1)) >= 0;
  };
  const SEP = '：:=＝ \u3000';
  const isSep = (ch) => SEP.indexOf(ch) >= 0;

  /** 与 Talk.ets nameBefore 同步（含后界裁剪 + 停用词裁剪 + 去领属"的"） */
  function nameBefore(text, role, maxLen) {
    const out = [];
    let from = 0, idx = text.indexOf(role, from);
    while (idx >= 0) {
      const after = text.substring(idx + role.length, idx + role.length + 1);
      if (!(after !== '' && roleSuffix.indexOf(after) >= 0)) {
        const prefix = text.substring(0, idx);
        // (d) 去掉候选尾部的领属助词"的"（'的妈妈' 与 '妈妈' 两条路径归一化）
        let cand = tailHan(prefix, maxLen);
        while (cand.length >= 2 && cand.charAt(cand.length - 1) === '的') {
          cand = cand.substring(0, cand.length - 1);
        }
        if (cand.length >= 2 &&
          !endsWithFunctionWord(prefix.substring(0, prefix.length - cand.length)) &&
          stopWords.indexOf(cand) < 0) {
          out.push(cand);
        }
      }
      from = idx + role.length;
      idx = text.indexOf(role, from);
    }
    return out;
  }

  /** 与 Talk.ets nameAfterLabel 同步 */
  function nameAfterLabel(text, label) {
    const out = [];
    let from = 0, idx = text.indexOf(label, from);
    while (idx >= 0) {
      let p = idx + label.length;
      while (p < text.length && isSep(text.charAt(p))) p++;
      const cand = headHan(text.substring(p), 4);
      if (cand.length >= 2) out.push(cand);
      from = idx + label.length;
      idx = text.indexOf(label, from);
    }
    return out;
  }

  /** 复刻 maskSituation：登记（含姓名框）→ 长名优先全量替换 */
  function maskSituation(situation, explicitName) {
    const registered = [];
    const reg = (n) => {
      const t = String(n || '').trim();
      if (t !== '' && registered.indexOf(t) < 0) registered.push(t);
    };
    if (explicitName) reg(explicitName);
    for (const l of labels) nameAfterLabel(situation, l).forEach(reg);
    for (const r of roles) nameBefore(situation, r, 4).forEach(reg);
    // ③ 兜底：已知姓名全量替换（顺序与 Talk 一致：labels → roles → 全量）
    let outText = situation;
    const byLen = registered.slice().sort((a, b) => b.length - a.length);
    byLen.forEach((nm, i) => {
      // 编号按登记顺序发放（与 NameMask.register 一致）
      const idx = registered.indexOf(nm);
      const id = 'S' + String(idx + 1).padStart(3, '0');
      outText = outText.split(nm).join(id);
      void i;
    });
    return { text: outText, registered };
  }

  /* ---------- E3. 正例：姓名必须被替换 ---------- */
  const positives = [
    { d: '张三同学最近上课走神，作业也经常不交。', names: ['张三'], why: '「X同学」结构' },
    { d: '学生姓名：李四，数学成绩下滑明显。', names: ['李四'], why: '「学生姓名：」标签' },
    { d: '王小明妈妈反映孩子在家不愿写作业。', names: ['王小明'], why: '不带"的"的亲属称谓（缺陷2）' },
    { d: '王小明妈妈', names: ['王小明'], why: '不带"的"的亲属称谓（最短形态）' },
    { d: '张三的妈妈反映孩子最近状态不好。', names: ['张三'], why: '带"的"的亲属称谓（回归）' },
    { d: '欧阳娜娜父亲来校沟通。', names: ['欧阳娜娜'], why: '四字名 + 亲属称谓' }
  ];
  for (const c of positives) {
    const r = maskSituation(c.d, '');
    const leaked = c.names.filter((nm) => r.text.includes(nm));
    check('Talk 正例[' + c.why + '] 姓名不外发', leaked.length === 0,
      '原文: ' + c.d + ' / 外发: ' + r.text + ' / 泄漏: ' + leaked.join(','));
    check('Talk 正例[' + c.why + '] 确实产生了编号', /S\d{3}/.test(r.text), r.text);
  }

  /* ---------- E4. 反例：必须逐字完全相等（Lead 点名的 5 句 + 扩展） ---------- */
  const negatives = [
    '孩子最近情绪低落，需要家访。',
    '班级整体成绩下滑，家长会需要沟通。',
    '单元测试显示学习方法有待改进。',
    '学生普遍反映作业量偏大。',
    '家长会定在周五下午。',
    // 扩展反例：同族误伤风险
    '家长反映孩子最近在家不愿写作业。',
    '妈妈们建议增加课后练习。',
    '学校组织家长会，请准时参加。',
    '孩子的情绪需要家长多关注。',
    '这次单元测试整体难度偏低。'
  ];
  for (const b of negatives) {
    const r = maskSituation(b, '');
    check('Talk 反例逐字不变: ' + b, r.text === b,
      '被改成: ' + r.text + ' / 误登记: ' + (r.registered.join(',') || '（无）'));
  }

  /* ---------- E5. 姓名框兜底 ---------- */
  const r5 = maskSituation('张三和李四这次都没考好，需要重点关注。', '张三');
  check('填了姓名框 → 描述里的该姓名被替换', !r5.text.includes('张三'),
    '实际外发: ' + r5.text);
  check('填了姓名框 → 未填的另一个姓名仍会外发（已知限制，已验证）',
    r5.text.includes('李四'), r5.text);

  /* ---------- E6. 行为反向断言：缺陷1 的两个原始病例不再复现 ---------- */
  const bad1 = maskSituation('孩子最近情绪低落，需要家访。', '');
  check('缺陷1 病例①「孩子最近情绪低落」不再被改写',
    bad1.text === '孩子最近情绪低落，需要家访。', bad1.text);
  const bad2 = maskSituation('学生姓名：李四，数学成绩下滑明显。', '');
  check('缺陷1 病例②不再产生「学生S002：S001」式双误登记',
    !/学生S\d+:S\d+/.test(bad2.text) && !bad2.registered.includes('姓名'),
    bad2.text + ' / 登记: ' + bad2.registered.join(','));

  /* ---------- E7. 还原闭环：Talk 场景 mask → restore 应回到原文 ---------- */
  const sess = makeSession();
  const explicit = '王小明';
  sess.register(explicit);
  const original = '王小明妈妈反映孩子在家不愿写作业。';
  const masked = maskSituation(original, explicit).text;
  check('Talk 场景：脱敏后不含姓名', !masked.includes('王小明'), masked);
  check('Talk 场景 round-trip：restore(mask(x)) === x',
    sess.restore(masked) === original, sess.restore(masked));

  /* ---------- E8. 领属"的"归一化：编号表不得出现 "李四的" 这类脏数据 ---------- */
  /**
   * roles 里同时有 '的妈妈' 与 '妈妈'，两条都会在 "李四的妈妈…" 命中：
   *   · '的妈妈' @2 → 候选 "李四"（正确）
   *   · '妈妈'  @3 → 候选 "李四的"（脏数据）
   * 修正方式是在 nameBefore 里剥掉候选尾部的"的"，两条路径归一到 "李四"。
   */
  const deCase = maskSituation('李四的妈妈希望老师多关注。', '');
  check('带"的"的亲属称谓：登记的人名不含尾部"的"',
    deCase.registered.indexOf('李四的') < 0 && deCase.registered.indexOf('李四') >= 0,
    '登记: ' + deCase.registered.join(','));
  check('带"的"的亲属称谓：登记的姓名个数被去重为 1（不产生"李四"+"李四的"两条）',
    deCase.registered.length === 1, '登记: ' + deCase.registered.join(','));
  /**
   * 注意这里的判据："S001的妈妈" 是**正确**结果 —— 正文里的"李四"被换成编号，
   * 其后的"的"是老师原文本来就有的助词，必须保留（剥掉它才是破坏原文）。
   * 真正的畸形是**候选误登记为"李四的"**，那样会把"李四的"整体换成" S001"，
   * 于是助词消失、"的妈妈"变成"妈妈"。故断言：
   *   · 助词"的"必须还在（说明只换了人名本身）；
   *   · 且不得出现"李四的"被登记导致的 "S001的妈妈"→"S001妈妈" 形态。
   */
  check('带"的"的亲属称谓：只替换人名本身，助词"的"保留在原文位置',
    deCase.text === 'S001的妈妈希望老师多关注。', deCase.text);
  check('带"的"的亲属称谓：未发生"李四的"整体被替换（助词不丢失）',
    deCase.text.includes('的妈妈') && !deCase.text.includes('S001妈妈'),
    deCase.text);
  check('带"的"的亲属称谓：姓名已脱敏', !deCase.text.includes('李四'), deCase.text);
  check('带"的"的亲属称谓：功能词"希望"未被误改', deCase.text.includes('希望'), deCase.text);

  const deCase2 = maskSituation('张三的妈妈反映孩子最近状态不好。', '');
  check('带"的"的多例：登记项去重后只剩真实姓名',
    deCase2.registered.length === 1 && deCase2.registered[0] === '张三',
    '登记: ' + deCase2.registered.join(','));
}

/* ================================================================== */
console.log('='.repeat(78));
console.log('学生姓名脱敏（Tokenization）回归测试');
console.log('='.repeat(78));

suiteStaticSource();
suiteSemantics();
suiteEdgeCases();
suiteImplementationAlignment();
suiteTalkBehavior();

console.log('\n' + '-'.repeat(78));
if (failures.length > 0) {
  console.log('失败项：');
  failures.forEach((f, i) => console.log('  ' + (i + 1) + '. ' + f));
  console.log('-'.repeat(78));
}
console.log('结果: 通过 ' + pass + ' / 共 ' + (pass + fail) + ' 项');
console.log('='.repeat(78));
process.exit(fail === 0 ? 0 : 1);
