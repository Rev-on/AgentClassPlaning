/**
 * 新课标 RAG 检索模块（服务端）
 *
 * 索引由 tools/build_index.py 离线构建，产物放在 server/rag/：
 *   subjects.json  学科索引：学科名/别名/学段/核心素养/课程目标/学段目标/学业质量/章节大纲
 *   chunks.json    内容索引：课标原文条目块（学科 + 章节路径 + 页码 + 原文）
 *
 * 检索策略（零外部依赖，纯内存 BM25 + 结构加权）：
 *   1) 学科路由：显式学科字段 > 正文中的"学科："字段 > 别名命中计分 > 全文检索回退
 *   2) 若学科命中，则在其内容块范围内打分；否则全库打分（多学科教案场景）
 *   3) BM25（中文 bigram + Latin 词）叠加：章节标题命中、学段匹配、关键词组精确命中加权
 *   4) 输出"课标依据块"，含核心素养/学段目标/相关条目原文 + 落实要求，供服务端注入提示词
 *
 * 环境变量：
 *   RAG_ENABLED=0        关闭检索（默认开启）
 *   RAG_DIR              索引目录
 *   RAG_TOP_K            注入条目数（默认 8）
 *   RAG_MAX_CHARS        注入正文总量上限（默认 4200）
 */
const fs = require('fs');
const path = require('path');
const util = require('util');

const RAG_DIR = process.env.RAG_DIR || path.join(__dirname, '..', 'rag');
const TOP_K = Number(process.env.RAG_TOP_K || 8);
const MAX_INJECT = Number(process.env.RAG_MAX_CHARS || 4200);
const ENABLED = process.env.RAG_ENABLED !== '0';

const BM25_K1 = 1.35;
const BM25_B = 0.62;

let subjects = [];
let chunks = [];
let meta = {};
let ready = false;
let sIndex = new Map();     // id -> 学科条目
let aliasTable = [];        // [{alias, id, len}]
let avgdl = 1;

/** 中文停用字/词：参与分词但权重极低的与句式无关字 */
const STOP = new Set(['的', '了', '和', '与', '及', '或', '在', '是', '为', '对', '中', '上', '下',
  '有', '无', '不', '会', '能', '要', '并', '等', '之', '其', '以', '把', '被', '让', '从', '到',
  '个', '这', '那', '请', '我', '你', '他', '它', '们', '一', '二', '三', '四', '五', '六', '七',
  '八', '九', '十', '生', '师', '课', '节', '本', '次', '设', '计', '如', '何', '么', '呢', '吧']);

/** 学段名 → 年级区间（通用兜底；各学科实际划分以 subjects.json 的 stageMap 为准） */
const STAGE_GRADES = {
  '第一学段': [1, 2], '第二学段': [3, 4], '第三学段': [5, 6],
  '第四学段': [7, 9], '第五学段': [10, 12]
};

/** 章节标题里出现的"第X学段" */
const SEC_STAGE_RE = /第\s*([一二三四五])\s*学\s*段/;

const CN_NUM = { '一': 1, '二': 2, '三': 3, '四': 4, '五': 5, '六': 6, '七': 7, '八': 8, '九': 9 };

function log(...a) {
  console.log('[rag] ' + util.format(...a));
}

/** 载入索引（进程启动时调用一次） */
function load() {
  try {
    const sp = path.join(RAG_DIR, 'subjects.json');
    const cp = path.join(RAG_DIR, 'chunks.json');
    const mp = path.join(RAG_DIR, 'meta.json');
    if (!fs.existsSync(sp) || !fs.existsSync(cp)) {
      log('未找到索引文件，RAG 关闭。目录=', RAG_DIR);
      ready = false;
      return false;
    }
    subjects = JSON.parse(fs.readFileSync(sp, 'utf-8')).subjects || [];
    chunks = JSON.parse(fs.readFileSync(cp, 'utf-8')).chunks || [];
    meta = fs.existsSync(mp) ? JSON.parse(fs.readFileSync(mp, 'utf-8')) : {};
    let total = 0;
    for (const c of chunks) {
      c.len = c.t.length;
      total += c.len;
    }
    avgdl = chunks.length > 0 ? total / chunks.length : 1;
    sIndex = new Map();
    aliasTable = [];
    for (const s of subjects) {
      sIndex.set(s.id, s);
      const names = [s.name].concat(s.aliases || []);
      for (const a of names) {
        if (typeof a === 'string' && a.length > 0) {
          aliasTable.push({ alias: a, id: s.id, len: a.length });
        }
      }
    }
    // 长别名优先，避免"科学"抢走"信息科技"之类
    aliasTable.sort((x, y) => y.len - x.len);
    ready = true;
    log('索引载入完成：学科 %d 个，内容块 %d 个，平均块长 %d 字，构建于 %s',
      subjects.length, chunks.length, Math.round(avgdl), meta.builtAt || '未知');
    return true;
  } catch (e) {
    log('索引载入失败：', e && e.message ? e.message : e);
    ready = false;
    return false;
  }
}

function isReady() {
  return ready && ENABLED;
}

function stats() {
  return {
    enabled: ENABLED,
    ready: ready,
    dir: RAG_DIR,
    subjects: subjects.map((s) => ({
      id: s.id, name: s.name, doc: s.doc, chunks: s.chunkCount,
      stages: s.stages, core: !!s.core, stageGoals: (s.stageGoals || []).length,
      quality: !!s.quality, outline: (s.outline || []).length
    })),
    totalChunks: chunks.length,
    avgChunkLen: Math.round(avgdl),
    meta: meta
  };
}

/* ===================== 分词 ===================== */

const isCJK = (ch) => {
  const c = ch.codePointAt(0);
  return (c >= 0x3400 && c <= 0x4dbf) || (c >= 0x4e00 && c <= 0x9fff) || (c >= 0xf900 && c <= 0xfaff);
};

/** 中文按 bigram（外加单字兜底），拉丁/数字按词 */
function tokens(text) {
  const out = [];
  const t = String(text || '');
  let buf = '';
  const segs = [];
  for (const ch of t) {
    if (isCJK(ch)) {
      if (buf !== '') { segs.push(buf); buf = ''; }
      segs.push(ch);
    } else if (/[A-Za-z0-9]/.test(ch)) {
      buf += ch;
    } else {
      if (buf !== '') { segs.push(buf); buf = ''; }
    }
  }
  if (buf !== '') { segs.push(buf); }
  // 连续 CJK 单字合成 bigram
  let run = [];
  const flushRun = () => {
    if (run.length === 0) { return; }
    if (run.length === 1) {
      out.push(run[0]);
    } else {
      for (let i = 0; i < run.length - 1; i++) {
        out.push(run[i] + run[i + 1]);
      }
      // 单字兜底（低频权重由停用表控制）
      for (const c of run) {
        if (!STOP.has(c)) { out.push(c); }
      }
    }
    run = [];
  };
  for (const s of segs) {
    if (s.length === 1 && isCJK(s)) {
      run.push(s);
    } else {
      flushRun();
      if (s.length >= 2) { out.push(s.toLowerCase()); }
    }
  }
  flushRun();
  // 过滤停用 bigram（首尾字均为停用字的组合意义弱）
  return out.filter((x) => !(x.length === 2 && STOP.has(x[0]) && STOP.has(x[1])));
}

/* ===================== 请求解析 ===================== */

/** 从请求文本中抽取学科、年级、学段、课题等 */
function parseRequest(text, explicit) {
  const t = String(text || '');
  const info = { subjectId: '', subjectName: '', grade: 0, stage: '', declared: '', declaredMiss: false, source: '' };

  // 年级
  let m = t.match(/([一二三四五六七八九1-9])\s*年级/);
  if (m) {
    info.grade = CN_NUM[m[1]] || Number(m[1]) || 0;
  } else {
    m = t.match(/初\s*([一二三])/);
    if (m) {
      info.grade = 6 + (CN_NUM[m[1]] || 0);
    } else {
      m = t.match(/高\s*([一二三])/);
      if (m) { info.grade = 9 + (CN_NUM[m[1]] || 0); }
    }
  }
  m = t.match(/第\s*([一二三四五])\s*学段/);
  if (m) {
    info.stage = '第' + m[1] + '学段';
    if (info.grade === 0) {
      const rg = STAGE_GRADES[info.stage];
      if (rg) { info.grade = rg[0]; }
    }
  }
  if (info.grade > 0 && info.stage === '') {
    info.stage = stageOfGrade(info.grade);
  }

  // 学科：显式字段优先
  const cand = [];
  if (explicit) { cand.push(String(explicit)); }
  m = t.match(/学\s*科\s*[：:]\s*([^\s、，,。;；\n]{1,12})/);
  if (m) {
    cand.push(m[1]);
    info.declared = m[1];      // 客户端声明的学科（用于判断"课标库中没有该学科"）
  }
  m = t.match(/课\s*程\s*[：:]\s*([^\s、，,。;；\n]{1,12})/);
  if (m) { cand.push(m[1]); }

  for (const c of cand) {
    const hit = matchSubject(c);
    if (hit) {
      info.subjectId = hit;
      info.subjectName = sIndex.get(hit).name;
      info.source = (explicit === c) ? 'field' : 'text';
      return info;
    }
  }
  if (info.declared === '' && explicit) {
    info.declared = String(explicit);
  }
  if (info.declared !== '') {
    info.declaredMiss = true;   // 声明的学科不在课标库中（如数学、历史、生物）
  }
  // 别名全文计分（长别名优先）
  const hit = matchSubject(t);
  if (hit) {
    info.subjectId = hit;
    info.subjectName = sIndex.get(hit).name;
    info.source = 'alias';
  }
  return info;
}

/** 在给定文本中匹配学科（长别名优先；同长冲突时优先"别名即学科本名"的学科，避免跨学科抢词） */
function matchSubject(text) {
  const t = String(text || '');
  if (t === '') { return ''; }
  let best = '';
  let bestLen = 0;
  let bestExact = false;
  for (const a of aliasTable) {
    if (a.alias.length < 2) { continue; }
    if (a.id === 'general') { continue; }        // 通用文档不作为学科命中
    if (a.alias.length < bestLen) { continue; }
    if (t.indexOf(a.alias) < 0) { continue; }
    const s = sIndex.get(a.id);
    const exact = !!(s && s.name === a.alias);
    if (a.alias.length > bestLen || (exact && !bestExact)) {
      best = a.id;
      bestLen = a.alias.length;
      bestExact = exact;
    }
  }
  return best;
}

/** 年级 → 学段名（通用表兜底） */
function stageOfGrade(g) {
  for (const name in STAGE_GRADES) {
    const r = STAGE_GRADES[name];
    if (g >= r[0] && g <= r[1]) { return name; }
  }
  return '';
}

/** 年级 → 学段名：优先用该学科课标实测的划分（艺术等学科与通用表不同） */
function stageOfGradeIn(sub, g) {
  if (sub && sub.stageMap) {
    for (const name in sub.stageMap) {
      const r = sub.stageMap[name];
      if (g >= r[0] && g <= r[1]) { return name; }
    }
  }
  return stageOfGrade(g);
}

/** 正文里是否写了覆盖该年级的年级区间（如"（5～6年级）"）——部分学科的学段标记在正文而不在标题 */
function gradeRangeHit(text, grade) {
  const re = /([1-9])\s*[~～\-—–一至到]\s*([1-9])\s*年\s*级/g;
  let m;
  while ((m = re.exec(text)) !== null) {
    let lo = Number(m[1]);
    let hi = Number(m[2]);
    if (lo > hi) { const t = lo; lo = hi; hi = t; }
    if (grade >= lo && grade <= hi) { return true; }
  }
  return false;
}

/* ===================== 检索 ===================== */

function termFreq(text, terms) {
  const tf = new Map();
  for (const t of terms) {
    let n = 0;
    let from = 0;
    while (true) {
      const i = text.indexOf(t, from);
      if (i < 0) { break; }
      n++;
      from = i + t.length;
      if (n > 40) { break; }
    }
    if (n > 0) { tf.set(t, n); }
  }
  return tf;
}

/**
 * 检索课标条目
 * @param {string} query 查询文本（课题 + 备注 + 教材等）
 * @param {object} opt   {subjectId, stage, grade, topK}
 */
function search(query, opt) {
  const o = opt || {};
  const terms = tokens(query);
  if (terms.length === 0) { return []; }
  const uniq = Array.from(new Set(terms)).slice(0, 120);
  const topK = o.topK || TOP_K;

  // 候选范围：命中学科则只看该学科的块；否则全库
  let pool = chunks;
  if (o.subjectId) {
    pool = chunks.filter((c) => c.s === o.subjectId);
    if (pool.length === 0) { pool = chunks; }
  }

  const total = pool.length || 1;
  const df = new Map();
  const tfs = new Array(pool.length);
  for (let i = 0; i < pool.length; i++) {
    const tf = termFreq(pool[i].t, uniq);
    tfs[i] = tf;
    for (const k of tf.keys()) {
      df.set(k, (df.get(k) || 0) + 1);
    }
  }

  const stageName = o.stage || (o.grade ? stageOfGrade(o.grade) : '');
  const gradeRe = o.grade ? new RegExp(o.grade + '\\s*年级') : null;

  const scored = [];
  for (let i = 0; i < pool.length; i++) {
    const c = pool[i];
    const tf = tfs[i];
    if (tf.size === 0) { continue; }
    let score = 0;
    for (const [term, f] of tf) {
      const n = df.get(term) || 1;
      const idf = Math.log(1 + (total - n + 0.5) / (n + 0.5));
      const w = f * (BM25_K1 + 1) / (f + BM25_K1 * (1 - BM25_B + BM25_B * c.len / avgdl));
      score += idf * w;
    }
    // 章节标题命中（标题是课标"内容要求"的组织方式，权重较高）
    if (c.sec) {
      for (const t of uniq) {
        if (t.length >= 2 && c.sec.indexOf(t) >= 0) { score += 1.6; }
      }
    }
    // 学段匹配
    if (stageName && c.t.indexOf(stageName) >= 0) { score += 1.2; }
    if (gradeRe && gradeRe.test(c.t)) { score += 1.0; }
    if (o.grade && gradeRangeHit(c.t, o.grade)) { score += 1.2; }
    // 课题命中：标题命中 > 正文命中（课题才是检索意图所在）
    if (o.topic && o.topic.length >= 2) {
      if (c.sec && c.sec.indexOf(o.topic) >= 0) { score += 7.0; }
      if (c.t.indexOf(o.topic) >= 0) { score += 3.0; }
    }
    // 前言/修订原则/主要变化等各科通用块与教学设计无关，降权避免占位
    if (c.aux) { score *= 0.3; }
    /* 学段对齐（关键）：课标按学段分列内容要求，跨学段取条目会直接写错教学深度。
       小节标题里写明了"第X学段"的：与目标学段一致则加权，不一致则大幅降权。
       单学段学科（物理/化学/地理）标题里不出现学段，此处不产生影响。 */
    if (stageName && c.sec) {
      const sm = SEC_STAGE_RE.exec(c.sec);
      if (sm) {
        const secStage = '第' + sm[1] + '学段';
        score *= (secStage === stageName) ? 1.8 : 0.2;
      }
    }
    // 附录（背诵篇目、教学案例、知识说明等参考资料）优先级低于正文内容要求
    if (c.app || (c.sec && c.sec.indexOf('附录') >= 0)) { score *= 0.5; }
    // 可落地的小节类型（内容要求/学业要求/教学提示/学段目标/学业质量）加权：
    // 教学设计必须对齐这些条款，而"课程性质/理念"等描述性章节参考价值较低
    if (c.sec && /内容要求|学业要求|教学提示|学段目标|学段要求|学业质量/.test(c.sec)) { score *= 1.2; }
    // 记录本块命中的强词（词长>=2、按 tf 排序），用于后面截取"命中窗口"而非块首
    const strong = [];
    for (const [term, f] of tf) {
      if (term.length >= 2) { strong.push({ t: term, f: f }); }
    }
    strong.sort((x, y) => y.f - x.f);
    scored.push({ c: c, score: score, terms: strong.slice(0, 8).map((x) => x.t) });
  }
  scored.sort((a, b) => b.score - a.score);

  // 同一章节最多取 2 块，保证覆盖面
  const perSec = new Map();
  const picked = [];
  for (const s of scored) {
    const key = (s.c.s || '') + '|' + (s.c.sec || '');
    const n = perSec.get(key) || 0;
    if (n >= 2) { continue; }
    perSec.set(key, n + 1);
    picked.push(s);
    if (picked.length >= topK) { break; }
  }
  return picked;
}

/* ===================== 依据块拼装 ===================== */

function clip(s, n) {
  const t = String(s || '').replace(/\s+/g, ' ').trim();
  return t.length > n ? t.slice(0, n) + '……' : t;
}

/** 截取"命中窗口"：以课题/命中词为锚点居中取一段，避免块首的跨节残留占满额度 */
function excerptFor(text, anchors, n) {
  const t = String(text || '').replace(/\s+/g, ' ').trim();
  if (t.length <= n) { return t; }
  let pos = -1;
  for (const a of anchors) {
    if (!a || a.length < 2) { continue; }
    const i = t.indexOf(a);
    if (i >= 0 && (pos < 0 || i < pos)) { pos = i; }
  }
  if (pos < 0) { return t.slice(0, n) + '……'; }
  const start = Math.max(0, pos - Math.round(n * 0.2));
  const seg = t.slice(start, start + n);
  return (start > 0 ? '……' : '') + seg + (start + n < t.length ? '……' : '');
}

function pickStageGoals(sub, grade, stage) {
  const all = sub.stageGoals || [];
  if (all.length === 0) { return []; }
  if (grade === 0 && stage === '') { return all.slice(0, 1); }
  const hit = all.filter((g) => {
    const label = g.label || '';
    if (stage && label.indexOf(stage) >= 0) { return true; }
    const rg = label.match(/(\d)\s*[～~\-—到]\s*(\d)\s*年级/);
    if (rg && grade >= Number(rg[1]) && grade <= Number(rg[2])) { return true; }
    const one = label.match(/([1-9])\s*年级/);
    if (one && grade === Number(one[1])) { return true; }
    return false;
  });
  if (hit.length > 0) { return hit; }
  // 标签无法解析时退回第一条（不编造，仅可能不够精确）
  return all.slice(0, 1);
}

/**
 * 生成"课标依据"提示块
 * @param {object} p {user, subject, grade, remark, extraText}
 * @returns {{block:string, info:object}|null}
 */
function buildBlock(p) {
  if (!isReady()) { return null; }
  const user = String((p && p.user) || '');
  const extra = String((p && p.extraText) || '');
  const info = parseRequest(user, (p && p.subject) || '');
  if (info.grade === 0 && p && p.grade) {
    info.grade = Number(p.grade) || 0;
  }
  const sub = info.subjectId ? sIndex.get(info.subjectId) : null;
  const general = sIndex.get('general');
  // 学段按"该学科课标实测的划分"重算（艺术为 1-2/3-5/6-7/8-9，与通用表不同）
  if (info.grade > 0) {
    const st = stageOfGradeIn(sub, info.grade);
    if (st !== '') { info.stage = st; }
  }

  // 检索词只取教学相关字段：整段请求里的"请生成教案/课时/教材版本"等样板词会稀释检索
  const field = (re) => {
    const m = user.match(re);
    return m ? m[1].trim() : '';
  };
  const topic = field(/(?:课\s*题|主\s*题|篇\s*目|知识点)\s*[：:]\s*([^\n]{1,40})/);
  const unit = field(/(?:单\s*元|章\s*节)\s*[：:]\s*([^\n]{1,40})/);
  const book = field(/(?:教材版本|教\s*材|版\s*本)\s*[：:]\s*([^\n]{1,30})/);
  const remark = field(/(?:【\s*备\s*注\s*】|备\s*注|要\s*求)\s*[：:]?\s*([^\n]{1,200})/);
  const queryText = [topic, topic, topic, unit, book, remark, extra].filter((x) => x !== '').join(' ');
  const finalQuery = queryText.trim() !== '' ? queryText : user.slice(0, 500);

  const hits = search(finalQuery, {
    subjectId: info.subjectId || 'general',
    stage: info.stage, grade: info.grade, topic: topic
  });

  /* 注入闸门：只有"教学设计类任务"或"明确要求依据课标"时才注入，避免污染无关结果
     - 客户端明确写了"学科："字段（教案/练习页）-> 注入
     - 学科只是被顺带提到（如学情报告里的各科成绩、沟通话术）-> 不注入
     - 完全没识别到学科，但请求提到课标/课程标准/课程方案 -> 用《课程方案》作为依据 */
  const TEACHING_TASK = /教案|教学设计|课件|分层练习|练习设计|作业设计|命题|课时|教学过程/;
  const wantsStandard = /课程标准|课\s*标|课程方案/.test(user);
  if (info.declaredMiss && !wantsStandard) {
    /* 库中没有该学科课标（数学、历史、生物学、体育等）：绝不能用别的学科条文顶替，
       但也不能什么都不说——模型可能凭记忆编造课标条文，因此明确告知并给出唯一可引用的通用依据 */
    const g = sIndex.get('general');
    const ls = [];
    ls.push('【课程标准依据说明】');
    ls.push('说明：本学科（' + info.declared + '）的义务教育课程标准尚未纳入本系统的课标库，'
      + '因此本次不提供该学科的课标条文。');
    if (g && g.core && g.core.text) {
      ls.push('本次唯一可作为课标依据的是《' + g.doc + '》：' + clip(g.core.text, 700));
    }
    ls.push('硬性要求：');
    ls.push('1. 严禁编造、或凭记忆引用该学科课标的条文编号与原文；');
    ls.push('2. 教学设计按学科通用规范撰写（教学目标、重难点、教学过程、作业、板书），'
      + '课标意识只能体现在上述《课程方案》层面；');
    ls.push('3. 如需说明课标依据，请写明"该学科课标未收录于系统课标库，具体以现行课标与教材为准"。');
    const nb = ls.join('\n');
    log('未收录学科「' + info.declared + '」，仅注入"禁止编造课标条文"说明（' + nb.length + '字）');
    return {
      block: nb,
      info: {
        subjectId: '', subjectName: info.declared, doc: g ? g.doc : '',
        stage: info.stage, grade: info.grade, topic: '', source: 'not-indexed',
        notIndexed: true, hits: [], blockChars: nb.length
      }
    };
  }
  if (sub === null) {
    if (!wantsStandard) {
      log('未识别学科且未提及课标，跳过课标注入');
      return null;
    }
  } else if (info.declared === '' && !wantsStandard && !TEACHING_TASK.test(user)) {
    log('学科「' + info.subjectName + '」疑似顺带提及（非教学设计任务），跳过课标注入');
    return null;
  }
  if (sub && hits.length === 0 && !sub.core && (sub.stageGoals || []).length === 0) { return null; }

  const lines = [];
  const head = sub
    ? '【义务教育课程标准（2022年版）依据 · 必须落实】'
    : '【义务教育课程方案（2022年版）依据 · 必须落实】';
  lines.push(head);
  lines.push('依据文件：' + (sub ? ('《' + sub.doc + '》') : ('《' + (general ? general.doc : '') + '》')) +
    '（教育部 2022 年版，现行最新课标）');
  const metaBits = [];
  if (info.subjectName) { metaBits.push('学科：' + info.subjectName); }
  if (info.stage) { metaBits.push('学段：' + info.stage); }
  if (info.grade > 0) { metaBits.push('年级：' + info.grade + '年级'); }
  if (metaBits.length > 0) { lines.push(metaBits.join('　|　')); }

  let body = 0;
  const budget = (s) => {
    body += s.length;
    return body <= MAX_INJECT;
  };

  if (sub) {
    if (sub.core && sub.core.text) {
      const t = '一、本学科核心素养（课标原文要点）：' + clip(sub.core.text, 620);
      if (budget(t)) { lines.push(t); }
    }
    const goals = pickStageGoals(sub, info.grade, info.stage);
    if (goals.length > 0) {
      for (const g of goals) {
        const t = '二、学段目标·' + g.label + '：' + clip(g.text, 700);
        if (budget(t)) { lines.push(t); }
      }
    } else if (sub.goals && sub.goals.text) {
      const t = '二、课程目标：' + clip(sub.goals.text, 620);
      if (budget(t)) { lines.push(t); }
    }
    if (sub.quality && sub.quality.text) {
      const t = '三、学业质量（水平描述，用于对标作业与评价）：' + clip(sub.quality.text, 420);
      if (budget(t)) { lines.push(t); }
    }
  }
  if (general && general.core && !sub) {
    const t = '一、课程方案·培养目标要点：' + clip(general.core.text, 620);
    if (budget(t)) { lines.push(t); }
  }

  if (hits.length > 0) {
    lines.push((sub ? '四' : '二') + '、与本课直接相关的课标条目（原文摘录，写作时必须逐条对照）：');
    let n = 0;
    for (const h of hits) {
      const c = h.c;
      const src = '（' + c.d + ' · ' + (c.sec || '正文') + ' · 第' + c.p + '页）';
      const anchors = [topic, unit].concat(h.terms || []);
      const seg = '[' + (++n) + '] ' + src + '\n『' + excerptFor(c.t, anchors, 620) + '』';
      if (!budget(seg)) { break; }
      lines.push(seg);
    }
  }

  const no = hits.length > 0 ? (sub ? '五' : '三') : (sub ? '四' : '二');
  lines.push(no + '、落实要求：');
  lines.push('1. 教学目标必须按上述核心素养的维度表述，并与学段目标逐条呼应；开头注明依据的课标名称与版本（如《义务教育XX课程标准（2022年版）》）；');
  lines.push('2. 内容要求的用词须与课标一致（如"通过实验，了解…""探究并了解…"），不得拔高或降低水平；');
  lines.push('3. 教学活动、作业与评价设计需对标课标"学业质量"的水平描述；');
  lines.push('4. 教案中凡依据课标的内容，在对应位置标注依据：条目有编号时用【课标 X.X.X】；' +
    '没有编号的学科（如艺术、劳动）用【课标 摘录N】或【课标 章节名·第P页】（N、P 见上面摘录）；');
  lines.push('5. 只能使用上面摘录的条目作为课标依据，严禁编造条文编号或原文；若本课主题在摘录中没有' +
    '直接对应条目，请注明"课标未直接列出，按核心素养要求延伸"，不得虚构。');

  const block = lines.join('\n');
  const used = hits.map((h) => ({ i: h.c.i, sec: h.c.sec, p: h.c.p, d: h.c.d, score: Math.round(h.score * 100) / 100 }));
  return {
    block: block,
    info: {
      subjectId: info.subjectId, subjectName: info.subjectName,
      doc: sub ? sub.doc : (general ? general.doc : ''),
      stage: info.stage, grade: info.grade, topic: topic,
      source: info.source, hits: used, blockChars: block.length
    }
  };
}

module.exports = { load, isReady, stats, search, buildBlock, parseRequest, tokens, matchSubject };
