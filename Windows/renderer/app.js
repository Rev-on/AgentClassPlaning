/* Rev TechingMaster 电脑版 - 渲染层逻辑（纯前端，AI 走自建代理） */
'use strict';

const AI_NOTE_ZH = '（AI生成，仅供参考）';
const LS = { settings: 'rtm:settings', history: 'rtm:history', classes: 'rtm:classes' };

const store = {
  get(key, fb) { try { const v = localStorage.getItem(key); return v ? JSON.parse(v) : fb; } catch (e) { return fb; } },
  set(key, val) { localStorage.setItem(key, JSON.stringify(val)); }
};

const settings = store.get(LS.settings, {
  server: 'http://123.60.130.45:3000/v1/chat/completions',
  token: '',
  theme: 'light'
});

/* ============ 页面 / 鸿蒙主题色 ============ */
const PAGES = {
  plan: { icon: '教', title: '教案生成', head: 'AI 教案生成' },
  courseware: { icon: '课', title: '课件大纲', head: 'AI 课件大纲（JSON）' },
  quiz: { icon: '题', title: '分层练习', head: 'AI 分层练习命题' },
  research: { icon: '研', title: '教研科研', head: '教研科研辅助' },
  analysis: { icon: '析', title: '学情分析', head: '学情分析与报告' },
  talk: { icon: '话', title: '沟通话术', head: '家校沟通话术' },
  report: { icon: '报', title: '学情报告', head: '个性化学情报告' },
  seats: { icon: '位', title: '排座位表', head: '排座位表' },
  mine: { icon: '我', title: '我的', head: '我的' }
};
const ACCENT = {
  plan: '#4A90D9', courseware: '#E8912F', quiz: '#3EA67E', research: '#8E6FC0',
  analysis: '#2FA7A0', talk: '#D96C86', report: '#4A6FCF', seats: '#D98E2B', mine: '#7C6FDF'
};

const TOOLS = {
  plan: {
    fields: [
      { k: 'subject', label: '学科', type: 'text', def: '物理' },
      { k: 'grade', label: '年级', type: 'text', def: '八年级' },
      { k: 'topic', label: '课题', type: 'text', def: '光的反射' },
      { k: 'usage', label: '课型/用途', type: 'text', def: '新授课' }
    ],
    sys: '你是一名资深初中教师。请基于输入生成结构完整、可直接使用的教案，使用 Markdown 排版，正文不要使用 ** 加粗标记。',
    user: (f) => `学科：${f.subject}\n年级：${f.grade}\n课题：${f.topic}\n课型/用途：${f.usage}`
  },
  courseware: {
    fields: [
      { k: 'subject', label: '学科', type: 'text', def: '物理' },
      { k: 'grade', label: '年级', type: 'text', def: '八年级' },
      { k: 'topic', label: '课题', type: 'text', def: '光的反射' },
      { k: 'usage', label: '课型/用途', type: 'text', def: '新授课' }
    ],
    sys: '你是课件设计专家。为课题输出逐页 PPT 大纲，必须是 JSON 数组（不含其它解释文字），每页含 title/要点/配图建议 字段。',
    user: (f) => `学科：${f.subject}\n年级：${f.grade}\n课题：${f.topic}\n课型：${f.usage}`
  },
  quiz: {
    fields: [
      { k: 'subject', label: '学科', type: 'text', def: '物理' },
      { k: 'grade', label: '年级', type: 'text', def: '八年级' },
      { k: 'topic', label: '课题/知识点', type: 'text', def: '光的反射' },
      { k: 'req', label: '附加要求', type: 'text', def: '基础/提高/拓展各 3 题，含选择题与解答题' }
    ],
    sys: '你是一名初中命题老师。请按基础/提高/拓展三层生成分层练习，附参考答案与简要解析，使用 Markdown，正文不要使用 ** 加粗标记。',
    user: (f) => `学科：${f.subject}\n年级：${f.grade}\n知识点：${f.topic}\n要求：${f.req}`
  },
  research: {
    fields: [
      { k: 'mode', label: '教研类型', type: 'select', options: ['选题建议', '论文大纲', '摘要润色'], def: '论文大纲' },
      { k: 'input', label: '内容（主题/摘要等）', type: 'textarea', def: '基于项目式学习的初中物理实验教学研究' }
    ],
    sys: '你是教研专家。根据类型输出：选题建议给出可研究问题清单；论文大纲给出章节结构；摘要润色保留原意改写。使用 Markdown，正文不要使用 ** 加粗标记。',
    user: (f) => `类型：${f.mode}\n内容：${f.input}`
  },
  analysis: {
    fields: [
      { k: 'scores', label: '班级成绩（可粘贴 Excel，Tab 分隔）', type: 'textarea', def: '姓名\t语文\t数学\n张三\t88\t92' },
      { k: 'remark', label: '备注（选填）', type: 'textarea', def: '' }
    ],
    sys: '你是学情分析专家。请解析成绩数据，输出整体情况、分层画像、重点关注学生与教学建议，使用 Markdown，正文不要使用 ** 加粗标记。',
    user: (f) => `班级成绩数据：\n${f.scores}\n备注：${f.remark || '无'}`
  },
  talk: {
    fields: [
      { k: 'scene', label: '沟通场景', type: 'select', options: ['学习退步沟通', '课堂表现反馈', '作业问题沟通', '考试后安抚', '家长会发言'], def: '学习退步沟通' },
      { k: 'tone', label: '期望语气', type: 'select', options: ['温和沟通', '正式规范', '激励引导'], def: '温和沟通' },
      { k: 'situation', label: '学生情况描述', type: 'textarea', def: '小明最近两次数学测验下滑明显，家长比较焦虑。' }
    ],
    sys: '你是家校沟通顾问。给出得体话术与沟通注意点，语气按期望执行，使用 Markdown，正文不要使用 ** 加粗标记。',
    user: (f) => `沟通场景：${f.scene}\n学生情况：${f.situation}\n期望语气：${f.tone}`
  },
  report: {
    fields: [
      { k: 'name', label: '学生姓名', type: 'text', def: '李同学' },
      { k: 'cls', label: '年级班级', type: 'text', def: '八年级2班' },
      { k: 'grades', label: '各科成绩', type: 'textarea', def: '语文 88，数学 92' },
      { k: 'obs', label: '课堂观察记录', type: 'textarea', def: '' }
    ],
    sys: '你是班主任。为家长生成一份语气得体、给建议不揭短的个性化学情报告，使用 Markdown，正文不要使用 ** 加粗标记。',
    user: (f) => `学生：${f.name}（${f.cls}）\n成绩：${f.grades}\n课堂观察：${f.obs || '无'}`
  }
};

/* ============ 基础工具 ============ */
const $ = (s) => document.querySelector(s);
const el = (tag, cls, txt) => { const n = document.createElement(tag); if (cls) n.className = cls; if (txt !== undefined) n.textContent = txt; return n; };
const esc = (s) => String(s).replace(/</g, '&lt;');

function buildNav() {
  const nav = $('#nav');
  for (const key of Object.keys(PAGES)) {
    const b = el('button', '', PAGES[key].title);
    b.dataset.page = key;
    b.addEventListener('click', () => showPage(key));
    nav.appendChild(b);
  }
}

function showPage(key) {
  document.querySelectorAll('#nav button').forEach((b) => b.classList.toggle('active', b.dataset.page === key));
  document.querySelectorAll('.page').forEach((p) => p.classList.remove('active'));
  const target = document.getElementById('page-' + key);
  if (target) { target.classList.add('active'); }
  $('#page-title').textContent = PAGES[key].head;
  document.body.style.setProperty('--accent', ACCENT[key] || '#f0a93f');
  if (key === 'seats') renderSeats();
  if (key === 'mine') renderMine();
}

function buildAiPages() {
  const wrap = $('#pages');
  for (const key of Object.keys(TOOLS)) {
    const cfg = TOOLS[key];
    const page = el('section', 'page'); page.id = 'page-' + key;
    const card = el('div', 'card');
    for (const f of cfg.fields) {
      const fld = el('div', 'field');
      fld.appendChild(el('label', '', f.label));
      let input;
      if (f.type === 'select') {
        input = document.createElement('select');
        f.options.forEach((o) => { const op = el('option', '', o); op.value = o; input.appendChild(op); });
        input.value = f.def;
      } else if (f.type === 'textarea') {
        input = document.createElement('textarea');
        input.placeholder = f.label;
        input.value = f.def || '';
        if (f.k === 'scores') input.style.minHeight = '120px';
      } else {
        input = document.createElement('input'); input.type = 'text'; input.value = f.def || '';
      }
      input.dataset.key = f.k;
      fld.appendChild(input);
      card.appendChild(fld);
    }
    const row = el('div', 'btn-row');
    const gen = el('button', 'btn', 'AI 生成');
    gen.addEventListener('click', () => runAi(key));
    row.appendChild(gen);
    card.appendChild(row);
    const res = el('div', 'result-area hidden'); res.id = 'res-' + key;
    card.appendChild(res);
    page.appendChild(card);
    wrap.appendChild(page);
  }
}

function buildStaticPages() {
  const wrap = $('#pages');
  const seats = el('section', 'page'); seats.id = 'page-seats'; wrap.appendChild(seats);
  const mine = el('section', 'page'); mine.id = 'page-mine'; wrap.appendChild(mine);
}

function readFields(key) {
  const out = {};
  document.getElementById('page-' + key).querySelectorAll('[data-key]').forEach((n) => { out[n.dataset.key] = n.value; });
  return out;
}

function resultHtml(content) {
  const wrap = document.createElement('div');
  const lines = content.split('\n');
  let inCode = false;
  for (const line of lines) {
    if (/^```/.test(line.trim())) { inCode = !inCode; continue; }
    const t = line.trim();
    if (!inCode && /^#{1,6}\s/.test(t)) {
      const lv = Math.min(6, (t.match(/^#+/) || ['#'])[0].length);
      wrap.appendChild(el('h' + Math.max(1, lv), '', t.replace(/^#+\s*/, '')));
    } else if (!inCode && /^\s*[-*]\s+/.test(t)) {
      wrap.appendChild(el('p', '', '• ' + t.replace(/^\s*[-*]\s+/, '')));
    } else if (!inCode && /^\s*\d+[.、)]/.test(t)) {
      wrap.appendChild(el('p', '', t));
    } else if (t === '') {
      wrap.appendChild(document.createElement('br'));
    } else {
      const p = el('p', '', t); p.style.whiteSpace = 'pre-wrap'; wrap.appendChild(p);
    }
  }
  return wrap;
}

async function runAi(key) {
  const f = readFields(key);
  const tool = TOOLS[key];
  const topic = f.topic || f.name || f.input || f.scores || f.situation || '';
  const res = $('#res-' + key);
  res.classList.remove('hidden');
  res.innerHTML = '';
  res.appendChild(el('div', 'loading', 'AI 生成中…（约 10-60 秒）'));
  try {
    const remark = f.remark ? '\n【备注】' + f.remark : '';
    const content = await callAi(tool.sys, tool.user(f) + remark);
    let out = content;
    if (key === 'courseware') {
      try { JSON.parse(out); } catch (e) { /* 保留原文便于查看 */ }
    } else if (!out.endsWith(AI_NOTE_ZH)) {
      out += '\n\n' + AI_NOTE_ZH;
    }
    res.innerHTML = '';
    const head = el('div', 'result-head');
    head.appendChild(el('span', 'label', '生成结果'));
    const ops = el('div', 'btn-row');
    const copyBtn = el('button', 'btn small primary', '复制');
    copyBtn.addEventListener('click', () => { navigator.clipboard.writeText(out); copyBtn.textContent = '已复制'; setTimeout(() => (copyBtn.textContent = '复制'), 1200); });
    const saveBtn = el('button', 'btn small green', '保存到历史');
    saveBtn.addEventListener('click', () => saveHistory(PAGES[key].title, topic, out));
    ops.appendChild(copyBtn); ops.appendChild(saveBtn);
    head.appendChild(ops);
    res.appendChild(head);
    res.appendChild(resultHtml(out));
  } catch (e) {
    res.innerHTML = '';
    res.appendChild(el('div', 'hint', '生成失败：' + e.message));
  }
}

async function callAi(system, user) {
  const url = settings.server;
  const headers = { 'Content-Type': 'application/json' };
  if (settings.token) { headers['x-proxy-token'] = settings.token; }
  const resp = await fetch(url, { method: 'POST', headers, body: JSON.stringify({ messages: [{ role: 'system', content: system }, { role: 'user', content: user }], stream: false }) });
  if (!resp.ok) {
    let msg = 'HTTP ' + resp.status;
    try { const j = await resp.json(); if (j && j.error && j.error.message) { msg = j.error.message; } } catch (e) { /* noop */ }
    throw new Error(msg);
  }
  const j = await resp.json();
  const c = j && j.choices && j.choices[0] && j.choices[0].message ? j.choices[0].message.content : '';
  if (!c) { throw new Error(j && j.error && j.error.message ? j.error.message : 'AI 未返回内容'); }
  return c;
}

/* ============ 我的页（整合班级名单 / 历史记录 / 设置） ============ */
let mineTab = 'classes';
function renderMine() {
  const page = document.getElementById('page-mine');
  page.innerHTML = '';
  const tabs = el('div', 'mine-head');
  [['classes', '班级名单'], ['history', '历史记录'], ['settings', '设置']].forEach(([k, label]) => {
    const t = el('button', 'mine-tab', label);
    t.addEventListener('click', () => { mineTab = k; renderMine(); });
    if (mineTab === k) { t.classList.add('active'); }
    tabs.appendChild(t);
  });
  page.appendChild(tabs);
  page.appendChild(el('div', 'mine-intro', '数据仅保存在本机，不上云。'));
  const body = el('div', 'card'); body.id = 'mine-body';
  page.appendChild(body);
  if (mineTab === 'classes') renderClasses(body);
  else if (mineTab === 'history') renderHistory(body);
  else renderSettings(body);
}

/* ---- 班级名单 ---- */
function getClasses() { return store.get(LS.classes, []); }
function renderClasses(host) {
  const classes = getClasses();
  host.innerHTML = '';
  const row = el('div', 'btn-row');
  const add = el('button', 'btn', '新建班级');
  add.addEventListener('click', () => {
    const name = prompt('班级名称：');
    if (!name) { return; }
    const now = getClasses(); now.push({ name, students: [] }); store.set(LS.classes, now); renderClasses(host);
  });
  row.appendChild(add);
  host.appendChild(row);
  if (!classes.length) { host.appendChild(el('div', 'hint', '还没有班级，点上方按钮新建')); return; }
  classes.forEach((cls, ci) => {
    const cr = el('div', 'class-row');
    const info = el('div', '');
    info.appendChild(el('div', 't', cls.name + '（' + cls.students.length + ' 人）'));
    const txt = cls.students.map((s) => s.name + (s.h ? ' ' + s.h : '')).join('\n');
    info.appendChild(el('div', 'm', txt || '（空名单）'));
    cr.appendChild(info);
    const ops = el('div', 'btn-row');
    const imp = el('button', 'btn small primary', '导入到排座');
    imp.addEventListener('click', () => { $('#seat-ta').value = txt; showPage('seats'); });
    const del = el('button', 'btn small ghost', '删除');
    del.addEventListener('click', () => { if (confirm('删除班级：' + cls.name + '？')) { const now = getClasses(); now.splice(ci, 1); store.set(LS.classes, now); renderClasses(host); } });
    ops.appendChild(imp); ops.appendChild(del);
    cr.appendChild(ops);
    host.appendChild(cr);
  });
}

/* ---- 历史记录 ---- */
function getHistory() { return store.get(LS.history, []); }
function saveHistory(tool, topic, content) {
  const h = getHistory();
  h.unshift({ tool, topic, content, time: new Date().toLocaleString('zh-CN') });
  store.set(LS.history, h.slice(0, 100));
}
function renderHistory(host) {
  const h = getHistory();
  host.innerHTML = '';
  const row = el('div', 'btn-row');
  const clear = el('button', 'btn small ghost', '清空历史');
  clear.addEventListener('click', () => { if (confirm('清空后不可恢复')) { store.set(LS.history, []); renderHistory(host); } });
  row.appendChild(clear);
  host.appendChild(row);
  if (!h.length) { host.appendChild(el('div', 'hint', '暂无历史记录（在各工具页点击“保存到历史”后显示）')); return; }
  h.forEach((it, i) => {
    const item = el('div', 'history-item');
    const left = el('div', '');
    left.appendChild(el('div', 't', esc(it.tool) + ' · ' + esc(it.topic) + '<span class="tag">' + esc(it.time) + '</span>'));
    left.appendChild(el('div', 'm', it.content.length > 200 ? esc(it.content.slice(0, 200)) + '…' : esc(it.content)));
    item.appendChild(left);
    const ops = el('div', 'ops');
    const view = el('button', 'btn small primary', '查看');
    view.addEventListener('click', () => { const w = window.open('', '_blank', 'width=760,height=640'); if (w) { w.document.write('<pre style="white-space:pre-wrap;font-family:inherit">' + esc(it.content) + '</pre>'); } });
    const copy = el('button', 'btn small', '复制');
    copy.addEventListener('click', () => navigator.clipboard.writeText(it.content));
    const del = el('button', 'btn small ghost', '删');
    del.addEventListener('click', () => { const now = getHistory(); now.splice(i, 1); store.set(LS.history, now); renderHistory(host); });
    ops.appendChild(view); ops.appendChild(copy); ops.appendChild(del);
    item.appendChild(ops);
    host.appendChild(item);
  });
}

/* ---- 设置（隐藏 AI 代理与令牌，连点版本号 5 次展开高级项） ---- */
function renderSettings(host) {
  host.innerHTML = '';
  const about = el('div', 'card');
  about.appendChild(el('h3', '', '关于'));
  const card = el('div', 'hint', 'Rev TechingMaster 电脑版 v1.0.0 · 基于 Electron，核心代码遵循 AGPL-3.0。');
  about.appendChild(card);
  const repo = el('div', 'hint', '开源仓库：');
  const link = el('a', 'link', 'https://gitcode.com/RTX6090/Techingmaster');
  link.href = 'https://gitcode.com/RTX6090/Techingmaster';
  link.target = '_blank';
  link.appendChild(el('span', '', '（欢迎点亮 Star 支持持续更新）'));
  repo.appendChild(link);
  about.appendChild(repo);
  const local = el('div', 'hint', '所有班级名单、历史记录等数据仅保存在本机，不上云。');
  about.appendChild(local);
  const themeRow = el('div', 'btn-row');
  const themeBtn = el('button', 'btn', settings.theme === 'dark' ? '切换为浅色主题' : '切换为深色主题');
  themeBtn.addEventListener('click', () => { settings.theme = settings.theme === 'dark' ? 'light' : 'dark'; store.set(LS.settings, settings); applyTheme(); renderSettings(host); });
  themeRow.appendChild(themeBtn);
  about.appendChild(themeRow);
  const ver = el('div', 'version-line', '版本号：1.0.0');
  about.appendChild(ver);
  host.appendChild(about);

  const adv = el('div', 'adv-block hidden');
  const f1 = el('div', 'field'); f1.appendChild(el('label', '', '高级：AI 服务地址'));
  const s1 = document.createElement('input'); s1.type = 'text'; s1.value = settings.server; s1.id = 'adv-server';
  f1.appendChild(s1); adv.appendChild(f1);
  const f2 = el('div', 'field'); f2.appendChild(el('label', '', '高级：共享令牌'));
  const s2 = document.createElement('input'); s2.type = 'text'; s2.value = settings.token; s2.id = 'adv-token';
  f2.appendChild(s2); adv.appendChild(f2);
  const rowA = el('div', 'btn-row');
  const saveA = el('button', 'btn small green', '保存高级设置');
  saveA.addEventListener('click', () => { settings.server = $('#adv-server').value.trim(); settings.token = $('#adv-token').value.trim(); store.set(LS.settings, settings); alert('已保存'); checkProxy(); });
  rowA.appendChild(saveA);
  adv.appendChild(rowA);
  host.appendChild(adv);

  let clicks = 0;
  ver.addEventListener('click', () => { clicks++; if (clicks >= 5) { adv.classList.remove('hidden'); ver.textContent = '版本号：1.0.0（高级设置已展开）'; } });
}

/* ============ 排座位表 ============ */
const seatState = { text: '' };
let seatGrid = [];
let seatSel = null;
function renderSeats() {
  const page = document.getElementById('page-seats');
  page.innerHTML = '';
  const card = el('div', 'card');
  const r1 = el('div', 'field-row');
  r1.appendChild(fieldEl('rows', '排数（前后）', 'number', '8'));
  r1.appendChild(fieldEl('cols', '每排人数', 'number', '6'));
  card.appendChild(r1);
  const side = el('div', 'field-row');
  side.appendChild(fieldEl('sideL', '左护法（留空自动安排）', 'text', ''));
  side.appendChild(fieldEl('sideR', '右护法（留空自动安排）', 'text', ''));
  card.appendChild(side);
  const fs = el('div', 'field');
  fs.appendChild(el('label', '', '学生身高数据（每行：姓名 空格 身高cm）'));
  const ta = document.createElement('textarea'); ta.id = 'seat-ta'; ta.value = seatState.text; ta.placeholder = '示例：\n张三 158\n李四 163\n王五 170';
  ta.addEventListener('input', () => { seatState.text = ta.value; });
  fs.appendChild(ta); card.appendChild(fs);
  const row = el('div', 'btn-row');
  const gen = el('button', 'btn', '生成座位表');
  gen.addEventListener('click', genSeats);
  const imp = el('button', 'btn primary', '导入班级名单');
  imp.addEventListener('click', importClassToSeats);
  const save = el('button', 'btn green', '保存当前名单到班级');
  save.addEventListener('click', saveSeatsToClass);
  row.appendChild(gen); row.appendChild(imp); row.appendChild(save);
  card.appendChild(row);
  const wrap = el('div', 'result-area hidden'); wrap.id = 'seat-grid-wrap';
  card.appendChild(wrap);
  page.appendChild(card);
}
function fieldEl(key, label, type, def) {
  const fld = el('div', 'field');
  fld.appendChild(el('label', '', label));
  const input = document.createElement('input');
  input.type = type === 'number' ? 'number' : 'text';
  input.value = def; input.dataset.key = key;
  fld.appendChild(input);
  return fld;
}
function parseSeatText(text) {
  const list = [];
  text.split('\n').forEach((line) => {
    const parts = line.trim().split(/[\s，,、]+/);
    if (parts.length < 2) { return; }
    const h = parseInt(parts[parts.length - 1], 10);
    if (!isNaN(h) && h > 0) { list.push({ name: parts.slice(0, -1).join(' '), h }); }
  });
  return list;
}
function genSeats() {
  const page = document.getElementById('page-seats');
  const rows = parseInt(page.querySelector('[data-key="rows"]').value, 10);
  const cols = parseInt(page.querySelector('[data-key="cols"]').value, 10);
  const wrap = $('#seat-grid-wrap');
  if (isNaN(rows) || isNaN(cols) || rows < 1 || cols < 1 || rows > 20 || cols > 15) { alert('请正确填写排数与每排人数'); return; }
  const list = parseSeatText($('#seat-ta').value);
  if (list.length > rows * cols) { alert('学生人数超过座位数，请核对'); return; }
  const sorted = list.slice().sort((a, b) => a.h - b.h || (a.name < b.name ? -1 : 1));
  const heightOf = {};
  list.forEach((s) => { if (!(s.name in heightOf)) { heightOf[s.name] = s.h; } });
  seatGrid = [];
  for (let r = 0; r < rows; r++) { seatGrid.push(new Array(cols).fill('')); }
  let idx = 0;
  for (let r = 0; r < rows; r++) {
    if (r % 2 === 0) { for (let c = 0; c < cols && idx < sorted.length; c++, idx++) { seatGrid[r][c] = sorted[idx].name + '|' + heightOf[sorted[idx].name]; } }
    else { for (let c = cols - 1; c >= 0 && idx < sorted.length; c--, idx++) { seatGrid[r][c] = sorted[idx].name + '|' + heightOf[sorted[idx].name]; } }
  }
  for (let round = 0; round < rows; round++) {
    let changed = false;
    for (let r = 0; r < rows - 1; r++) { for (let c = 0; c < cols; c++) { const a = seatGrid[r][c], b = seatGrid[r + 1][c]; if (a && b && ha(a) > ha(b)) { seatGrid[r][c] = b; seatGrid[r + 1][c] = a; changed = true; } } }
    if (!changed) { break; }
  }
  seatSel = null;
  wrap.innerHTML = '';
  wrap.appendChild(el('div', 'stats', '共 ' + rows * cols + ' 座，已排 ' + sorted.length + ' 人（点击两个座位可互换）'));
  wrap.classList.remove('hidden');
  paintGrid();
}
const ha = (cell) => parseInt(cell.split('|')[1], 10);
function paintGrid() {
  const holder = $('#seat-grid-wrap');
  if (!holder || !seatGrid.length) { return; }
  const old = holder.querySelector('table.grid'); if (old) { old.remove(); }
  const tbl = el('table', 'grid');
  const thead = el('tr'); thead.appendChild(el('th', '', '座'));
  for (let c = 1; c <= seatGrid[0].length; c++) { thead.appendChild(el('th', '', '第' + c + '列')); }
  tbl.appendChild(thead);
  seatGrid.forEach((rrow, r) => {
    const tr = el('tr'); tr.appendChild(el('td', '', '第' + (r + 1) + '排'));
    rrow.forEach((cell, c) => {
      const td = el('td', 'cursor', cell ? cell.split('|')[0] : '');
      td.addEventListener('click', () => tapCell(r, c, td));
      tr.appendChild(td);
    });
    tbl.appendChild(tr);
  });
  holder.insertBefore(tbl, holder.querySelector('div.stats'));
}
function tapCell(r, c, td) {
  document.querySelectorAll('table.grid td.sel').forEach((x) => x.classList.remove('sel'));
  if (seatSel) {
    if (seatSel[0] === r && seatSel[1] === c) { seatSel = null; return; }
    const a = seatGrid[seatSel[0]][seatSel[1]];
    seatGrid[seatSel[0]][seatSel[1]] = seatGrid[r][c];
    seatGrid[r][c] = a;
    seatSel = null;
    paintGrid();
  } else { seatSel = [r, c]; td.classList.add('sel'); }
}
function importClassToSeats() {
  const classes = getClasses();
  if (!classes.length) { alert('暂无班级，请到“我的-班级名单”创建'); return; }
  const pick = prompt('选择要导入的班级：\n' + classes.map((c, i) => (i + 1) + '. ' + c.name).join('\n') + '\n（输入序号）');
  const idx = parseInt(pick, 10) - 1;
  if (isNaN(idx) || idx < 0 || idx >= classes.length) { return; }
  const lines = [];
  classes[idx].students.forEach((s) => { if (s.h) { lines.push(s.name + ' ' + s.h); } });
  if (lines.length) { seatState.text = lines.join('\n'); $('#seat-ta').value = seatState.text; } else { alert('该班没有身高数据'); }
}
function saveSeatsToClass() {
  const list = parseSeatText($('#seat-ta').value);
  if (!list.length) { alert('当前身高名单为空'); return; }
  const classes = getClasses();
  let cls;
  if (!classes.length) {
    const name = prompt('输入班级名称（如：扬帆18班）：');
    if (!name) { return; }
    cls = { name, students: [] };
    classes.push(cls);
  } else {
    const pick = prompt('保存到班级：\n' + classes.map((c, i) => (i + 1) + '. ' + c.name).join('\n') + '\n输入序号；留空则新建：');
    if (pick && pick.trim() !== '') {
      const idx = parseInt(pick, 10) - 1;
      if (isNaN(idx) || idx < 0 || idx >= classes.length) { return; }
      cls = classes[idx];
    } else {
      const name = prompt('输入新班级名称：');
      if (!name) { return; }
      cls = { name, students: [] };
      classes.push(cls);
    }
  }
  list.forEach((s) => {
    const ex = cls.students.find((x) => x.name === s.name);
    if (ex) { ex.h = s.h; } else { cls.students.push({ name: s.name, h: s.h }); }
  });
  store.set(LS.classes, classes);
  alert('已保存 ' + list.length + ' 人到班级：' + cls.name);
}

/* ============ 状态与初始化 ============ */
function applyTheme() { document.body.classList.toggle('dark', settings.theme === 'dark'); }

async function checkProxy() {
  const st = $('#proxy-state');
  try {
    const root = settings.server.replace(/\/v1\/chat\/completions.*$/, '').replace(/\/$/, '');
    const resp = await fetch(root + '/health', { signal: AbortSignal.timeout(5000) });
    if (resp.ok) { st.textContent = 'AI 服务已连接'; st.classList.add('ok'); }
    else { st.textContent = 'AI 服务响应异常'; st.classList.remove('ok'); }
  } catch (e) {
    st.textContent = 'AI 服务未连接'; st.classList.remove('ok');
  }
}

document.addEventListener('DOMContentLoaded', () => {
  applyTheme();
  $('#btn-theme').addEventListener('click', () => {
    settings.theme = settings.theme === 'dark' ? 'light' : 'dark';
    store.set(LS.settings, settings);
    applyTheme();
  });
  buildNav();
  buildAiPages();
  buildStaticPages();
  showPage('plan');
  checkProxy();
});
