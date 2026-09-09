/* ============================================================
 * Rev TechingMaster Windows 版（Electron renderer）
 * 界面与鸿蒙平板版一致：左侧 400px 手机式三 Tab 面板 + 右侧工具页
 * 依赖 js/i18n-data.js（五语言词典，源自鸿蒙工程）
 * ============================================================ */
(function () {
  'use strict';

  var $ = function (s) { return document.querySelector(s); };
  var DICTS = (window.I18N_DATA || {});

  /* ---------- 词典缺失补充（zh/en，少数民族缺键自动回退中文） ---------- */
  var EXTRA = {
    zh: {
      'f.mode': '模式', 'f.researchTopic': '研究选题 / 教学困惑',
      'f.researchMaterial': '补充材料（选填）', 'f.reportStudent': '学生姓名',
      'f.reportClass': '年级班级', 'f.situation': '学生情况描述',
      'web.confirmDel': '确认删除该条记录？',
      'web.exportJson': '已导出 JSON 文件', 'web.seatsCopied': '座位表已复制',
      'web.proxyErr': '无法连接 AI 服务，请检查网络或稍后再试',
      'err.required': '请填写必填项',
      'web.emptyDesc': '点击左侧卡片开始使用'
    },
    en: {
      'f.mode': 'Mode', 'f.researchTopic': 'Research topic / teaching pain point',
      'f.researchMaterial': 'Extra material (optional)', 'f.reportStudent': 'Student name',
      'f.reportClass': 'Class', 'f.situation': 'Describe the situation',
      'web.confirmDel': 'Delete this record?',
      'web.exportJson': 'JSON file exported', 'web.seatsCopied': 'Seat plan copied',
      'web.proxyErr': 'Cannot reach AI service. Check network and retry later.',
      'err.required': 'Please fill in the required fields',
      'web.emptyDesc': 'Pick a tool from the left panel to start'
    }
  };

  /* ---------- 状态 ---------- */
  var STORE_KEY = 'rtm.';
  function load(key, def) {
    try {
      var v = localStorage.getItem(STORE_KEY + key);
      return v === null ? def : JSON.parse(v);
    } catch (e) { return def; }
  }
  function save(key, val) {
    try { localStorage.setItem(STORE_KEY + key, JSON.stringify(val)); } catch (e) { /* ignore */ }
  }

  var state = {
    lang: load('lang', 'zh'),
    theme: load('theme', 'system'),
    resolved: 'light',
    navTab: 'assistant',
    selId: load('lastTool', 'plan'),
    autoSave: load('auto', true),
    formVals: {},          // 工具输入缓存
    toolStates: {},        // 生成中状态
    history: load('history', []),
    classes: load('classes', [])
  };
  var currentDetailClassId = -1;

  /* ---------- 主题 ---------- */
  var mq = window.matchMedia('(prefers-color-scheme: dark)');
  function resolveTheme() {
    state.resolved = state.theme === 'system'
      ? (mq.matches ? 'dark' : 'light')
      : state.theme;
  }
  function applyTheme() {
    resolveTheme();
    var root = document.documentElement;
    root.classList.remove('theme-light', 'theme-dark');
    root.classList.add('theme-' + state.resolved);
    root.lang = state.lang === 'en' ? 'en' : 'zh';
  }
  function setTheme(mode) {
    state.theme = mode; save('theme', mode); applyTheme();
    renderSettings();
  }
  mq.addEventListener('change', function () { if (state.theme === 'system') applyTheme(); });

  /* ---------- 多语言 ---------- */
  function dict(lang) { return DICTS[lang] || {}; }
  function pick(lang, key) {
    var d = dict(lang);
    if (d[key] !== undefined) return d[key];
    var z = dict('zh');
    return z[key] !== undefined ? z[key] : key;
  }
  function t(key) {
    var d = dict(state.lang);
    if (d[key] !== undefined) return d[key];
    var ex = dict('en');
    if (state.lang !== 'zh' && ex[key] !== undefined) return ex[key];
    var z = dict('zh');
    if (z[key] !== undefined) return z[key];
    var e = EXTRA.zh[key];
    return e !== undefined ? e : key;
  }
  function langName() { return t('langName.' + state.lang); }
  function setLang(code) {
    if (state.lang === code) return;
    state.lang = code; save('lang', code); applyTheme(); renderAll();
    toast(t('toast.lang').replace('{lang}', t('langName.' + code)));
  }

  /* ---------- 工具目录（与平板 IndexWide 分组一致） ---------- */
  var GROUPS = {
    assistant: {
      tabKey: 'tab.assistant',
      entries: [
        { id: 'plan', icon: '教', labelKey: 'card.plan', descKey: 'card.plan.desc', iconBg: '#E8F1FB' },
        { id: 'courseware', icon: '课', labelKey: 'card.courseware', descKey: 'card.courseware.desc', iconBg: '#FFF4E5' },
        { id: 'quiz', icon: '题', labelKey: 'card.quiz', descKey: 'card.quiz.desc', iconBg: '#EAF7EF' },
        { id: 'research', icon: '研', labelKey: 'card.research', descKey: 'card.research.desc', iconBg: '#F3EDFB' },
        { id: 'analysis', icon: '析', labelKey: 'card.analysis', descKey: 'card.analysis.desc', iconBg: '#E6F4F2' },
        { id: 'seats', icon: '位', labelKey: 'card.seats', descKey: 'card.seats.desc', iconBg: '#FFF0E6' }
      ]
    },
    family: {
      tabKey: 'tab.family',
      entries: [
        { id: 'talk', icon: '话', labelKey: 'card.talk', descKey: 'card.talk.desc', iconBg: '#FFF0F0' },
        { id: 'report', icon: '报', labelKey: 'card.report', descKey: 'card.report.desc', iconBg: '#E8F1FB' }
      ]
    },
    mine: {
      tabKey: 'tab.mine',
      entries: [
        { id: 'history', icon: '史', labelKey: 'card.history', descKey: 'card.history.desc', iconBg: '#FFF4E5' },
        { id: 'settings', icon: '设', labelKey: 'card.settings', descKey: 'card.settings.desc', iconBg: '#EDF0FA' },
        { id: 'classes', icon: '班', labelKey: 'card.classes', descKey: 'card.classes.desc', iconBg: '#FDEFF0' }
      ]
    }
  };
  var TAB_ORDER = ['assistant', 'family', 'mine'];

  function entryById(id) {
    for (var g = 0; g < TAB_ORDER.length; g++) {
      var list = GROUPS[TAB_ORDER[g]].entries;
      for (var i = 0; i < list.length; i++) {
        if (list[i].id === id) return list[i];
      }
    }
    return null;
  }

  /* ---------- 左侧面板 ---------- */
  function renderLeft() {
    var group = GROUPS[state.navTab];
    $('#paneTitle').textContent = t(group.tabKey);
    var grid = document.createElement('div');
    grid.className = 'pane-grid';
    group.entries.forEach(function (en) {
      var card = document.createElement('div');
      card.className = 'tool-card' + (state.selId === en.id ? ' active' : '');
      card.innerHTML =
        '<div class="tool-icon" style="background:' + en.iconBg + '">' + en.icon + '</div>' +
        '<div class="tool-name">' + esc(t(en.labelKey)) + '</div>' +
        '<div class="tool-desc">' + esc(t(en.descKey)) + '</div>';
      card.onclick = function () { pickTool(en.id); };
      grid.appendChild(card);
    });
    var wrap = $('#gridWrap');
    wrap.innerHTML = '';
    wrap.appendChild(grid);

    // 底部三 Tab 滑动指示
    var idx = TAB_ORDER.indexOf(state.navTab);
    $('#tabIndicator').style.transform = 'translateX(' + (idx * 100) + '%)';
    var btns = $('#tabBtns');
    btns.innerHTML = '';
    TAB_ORDER.forEach(function (tab, i) {
      var b = document.createElement('div');
      b.className = 'tab-btn' + (state.navTab === tab ? ' active' : '');
      b.textContent = t(GROUPS[tab].tabKey);
      b.onclick = function () {
        if (state.navTab === tab) return;
        state.navTab = tab;
        var first = GROUPS[tab].entries[0];
        state.selId = first.id; save('lastTool', first.id);
        animateGridLeave(function () { renderAll(); });
      };
      btns.appendChild(b);
      void i;
    });
  }

  function animateGridLeave(done) {
    var wrap = $('#gridWrap');
    wrap.classList.add('leaving');
    setTimeout(function () {
      wrap.classList.remove('leaving');
      done();
    }, 180);
  }
  function paneLeave(done) {
    var pane = $('#rightPane');
    pane.classList.add('leaving');
    setTimeout(function () {
      pane.classList.remove('leaving');
      done();
    }, 210);
  }

  function pickTool(id) {
    if (state.selId === id) return;
    paneLeave(function () {
      state.selId = id; save('lastTool', id);
      renderAll();
    });
  }

  /* ---------- 右栏：各工具视图 ---------- */
  function renderRight() {
    var en = entryById(state.selId);
    var pane = $('#rightPane');
    var html = '';
    if (en.id === 'seats') { renderSeats(); return; }
    if (en.id === 'history') { renderHistory(); return; }
    if (en.id === 'settings') { renderSettings(); return; }
    if (en.id === 'classes') { renderClasses(); return; }
    html =
      '<div class="right-page">' +
      '  <div class="page-head"><h2>' + esc(t(en.labelKey)) + '</h2>' +
      '    <div class="head-sub">' + esc(t(en.descKey)) + '</div></div>' +
      '  <div class="page-body">' + renderToolForm(en) +
      '    <div class="wcard"><div class="btn-row">' +
      toolActionBar(en) +
      '    </div></div>' +
      '    <div class="wcard"><div id="resultBox" class="result-box">' + esc(t('web.emptyDesc')) + '</div></div>' +
      '  </div></div>';
    pane.innerHTML = html;
    bindToolForm(en);
    // 切回本工具时回显最近一次结果
    var cached = state.formVals[en.id];
    if (cached && cached._result) {
      var box = document.getElementById('resultBox');
      if (box) { box.textContent = cached._result; box.classList.remove('loading'); }
      var jb = document.getElementById('btnJson');
      if (jb) jb.disabled = !(en.id === 'courseware' && cached._json);
    }
  }

  function esc(s) {
    return String(s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }

  /* ---------- 通用 AI 工具字段配置 ----------
   * def: 默认值词典键（与手机/平板一致：I18n def.*，随语言切换）
   */
  var COURSE_FIELDS = [
    { k: 'subject', label: 'label.subject', ph: 'ph.subject', def: 'def.subject' },
    { k: 'version', label: 'label.version', ph: 'ph.version', def: 'def.version' },
    { k: 'grade', label: 'label.grade', ph: 'ph.grade', def: 'def.grade' },
    { k: 'topic', label: 'label.topic', ph: 'ph.topic', required: true, wide: true, def: 'def.topic' },
    { k: 'period', label: 'label.period', ph: 'ph.period', def: 'def.period' },
    { k: 'usage', label: 'label.usage', ph: 'ph.usage', def: 'def.usage' },
    { k: 'requirement', label: 'label.requirement', ph: 'ph.requirement', wide: true, def: 'def.requirement' },
    { k: 'remark', label: 'label.remarkShort', ph: 'ph.remark', wide: true, textarea: true }
  ];

  function toolConfig(id) {
    switch (id) {
      case 'courseware': return { kind: 'courseware', fields: COURSE_FIELDS };
      case 'quiz': return { kind: 'quiz', fields: COURSE_FIELDS };
      case 'analysis': return {
        kind: 'analysis',
        fields: [
          { k: 'excel', label: 'excel.title', ph: 'excel.sub', wide: true, textarea: true, required: true, def: 'def.excel' }
        ]
      };
      case 'talk': return {
        kind: 'talk',
        fields: [
          { k: 'scene', label: 'talk.situationDesc', select: ['talk.s1', 'talk.s2', 'talk.s3', 'talk.s4', 'talk.s5'] },
          { k: 'tone', label: 'label.tone', select: ['talk.t1', 'talk.t2', 'talk.t3'] },
          { k: 'situation', label: 'f.situation', ph: 'ph.situation', wide: true, textarea: true, required: true }
        ]
      };
      case 'report': return {
        kind: 'report',
        fields: [
          { k: 'student', label: 'f.reportStudent', ph: 'ph.reportName', def: 'def.studentName' },
          { k: 'cls', label: 'f.reportClass', ph: 'ph.reportClass', def: 'def.className' },
          { k: 'grades', label: 'label.grades', ph: 'ph.scores', wide: true, textarea: true, def: 'def.grades' },
          { k: 'observation', label: 'label.observation', ph: 'ph.observation', wide: true, textarea: true, def: 'def.observation' }
        ]
      };
      case 'research': return {
        kind: 'research',
        fields: [
          { k: 'mode', label: 'f.mode', select: ['rm.topic', 'rm.outline', 'rm.abstract'], wide: true },
          { k: 'topic', label: 'f.researchTopic', ph: 'rm.ph0', wide: true, textarea: true, required: true },
          { k: 'material', label: 'f.researchMaterial', ph: 'rm.ph2', wide: true, textarea: true }
        ]
      };
      case 'plan':
      default:
        return { kind: 'plan', fields: COURSE_FIELDS };
    }
  }

  /** 字段显示值：用户输入优先，否则词典默认（随语言变化，不写回状态） */
  function displayVal(vals, f) {
    if (f.select) return (vals[f.k] !== undefined ? vals[f.k] : '');
    return (vals[f.k] !== undefined ? vals[f.k] : (f.def ? t(f.def) : ''));
  }

  /** 字段实际使用值（用于校验与生成提示词） */
  function usedVal(vals, f) {
    return String(displayVal(vals, f)).trim();
  }

  function renderToolForm(en) {
    var cfg = toolConfig(en.id);
    var vals = state.formVals[en.id] || {};
    var inner = cfg.fields.map(function (f) {
      var label = f.select ? t(f.label) : t(f.label);
      var req = f.required ? ' required' : '';
      var value = displayVal(vals, f);
      if (f.select) {
        var opts = f.select.map(function (key, i) {
          return '<option value="' + key + '"' + (value === key || (value === '' && i === 0) ? ' selected' : '') + '>' + esc(t(key)) + '</option>';
        }).join('');
        return '<div class="field ' + (f.wide ? 'wide' : '') + '"><label' + req + '>' + esc(label) + '</label>' +
          '<select data-k="' + f.k + '">' + opts + '</select></div>';
      }
      var tag = f.textarea ? 'textarea' : 'input';
      var extra = f.textarea ? '' : ' value="' + esc(value) + '"';
      var innerV = f.textarea ? esc(value) : '';
      return '<div class="field ' + (f.wide ? 'wide' : '') + '"><label' + req + '>' + esc(label) + '</label>' +
        '<' + tag + ' data-k="' + f.k + '"' + extra + ' placeholder="' + esc(t(f.ph || '')) + '">' + innerV + '</' + tag + '></div>';
    }).join('');
    return '<div class="wcard"><div class="form-row">' + inner + '</div></div>';
  }

  function toolActionBar(en) {
    if (en.id === 'courseware') {
      return '<button class="btn btn-primary" id="btnGen">' + esc(t('btn.generate')) + '</button>' +
        '<button class="btn btn-success" id="btnCopy">' + esc(t('btn.copy')) + '</button>' +
        '<button class="btn btn-ghost" id="btnSave">' + esc(t('btn.saveHist')) + '</button>' +
        '<button class="btn btn-ghost" id="btnJson" disabled>' + esc(t('btn.exportJson')) + '</button>' +
        '<button class="btn btn-danger" id="btnClear">' + esc(t('btn.clear')) + '</button>';
    }
    return '<button class="btn btn-primary" id="btnGen">' + esc(t('btn.generate')) + '</button>' +
      '<button class="btn btn-success" id="btnCopy">' + esc(t('btn.copy')) + '</button>' +
      '<button class="btn btn-ghost" id="btnSave">' + esc(t('btn.saveHist')) + '</button>' +
      '<button class="btn btn-danger" id="btnClear">' + esc(t('btn.clear')) + '</button>';
  }

  function bindToolForm(en) {
    var cfg = toolConfig(en.id);
    var vals = state.formVals[en.id] || {};
    // 保存输入
    document.querySelectorAll('.page-body [data-k]').forEach(function (el) {
      var k = el.getAttribute('data-k');
      var ev = el.tagName === 'SELECT' ? 'change' : 'input';
      el.addEventListener(ev, function () { vals[k] = el.value; state.formVals[en.id] = vals; });
    });
    // 行内动作
    var act = function (id, fn) { var b = document.getElementById(id); if (b) b.onclick = fn; };
    act('btnGen', function () { generateTool(en); });
    act('btnCopy', function () { copyResult(); });
    act('btnSave', function () { saveResultToHistory(en, null); });
    act('btnClear', function () { state.formVals[en.id] = {}; renderRight(); });
    act('btnJson', function () { exportCoursewareJson(); });
    void cfg;
  }

  /* ---------- AI 生成 ---------- */
  var PROXY = 'https://rev-on.site:3000/v1/chat/completions';
  var TOKEN = '';
  var MODEL = 'deepseek-v4-flash';
  var aiNote = function () { return t('watermark'); };

  function buildPrompt(en) {
    var vals = state.formVals[en.id] || {};
    var cfg = toolConfig(en.id);
    var langLine = '请全程使用「' + langName() + '」输出。';
    var sysBase = '你是一名经验丰富的中国初中教师与教研员。请根据用户提供的备课信息，输出结构清晰、可直接用于教学的内容。' + langLine;
    var parts = [];
    cfg.fields.forEach(function (f) {
      if (f.select) return;
      var v = usedVal(vals, f);
      if (!v) return;
      if (f.k === 'excel') {
        parts.push('成绩数据：\n' + v);
      } else {
        parts.push(t(f.label) + '：' + v);
      }
    });
    if (en.id === 'research') {
      parts.unshift('任务类型：' + t(vals.mode || 'rm.topic'));
    }
    if (en.id === 'talk') {
      parts.unshift('沟通场景：' + t(vals.scene || 'talk.s1'));
      parts.push('期望语气：' + t(vals.tone || 'talk.t1'));
    }
    var user = parts.join('\n');
    switch (en.id) {
      case 'courseware':
        sysBase += '请只输出一个严格 JSON 对象，不要输出任何额外文字、解释或代码围栏。结构：{"title":"课件标题","pages":[{"title":"页标题","points":["要点1"],"notes":"讲稿提示（选填）","suggestion":"配图建议（选填）"}]}，共 8~12 页。';
        break;
      case 'quiz':
        sysBase += '请按基础/提高/拓展三层命制题目，题型含选择与解答题。';
        break;
      case 'analysis':
        sysBase += '请基于数据做学情诊断，指出优势、薄弱点与改进建议。';
        break;
      case 'talk':
        sysBase += '请站在教师立场、按所选场景与语气，先给一段可直接发送给家长的沟通文案，再给 2 条要点提示。';
        break;
      case 'report':
        sysBase += '请生成一份给家长的个性化学情报告（称呼、进步点、待提升点、给家长的建议）。';
        break;
      case 'research':
        sysBase += '若为选题建议请给 3 个方向并说明理由；若为论文大纲请输出章节结构与每章要点；若为摘要润色请改写并说明改动。';
        break;
      default:
        sysBase += '请输出完整教案：教学目标、重难点、教学准备、教学过程（导入-新授-巩固-小结）、板书设计、作业布置。';
    }
    return { system: sysBase, user: user };
  }

  function fetchAi(system, user) {
    return fetch(PROXY, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-proxy-token': TOKEN
      },
      body: JSON.stringify({
        model: MODEL,
        messages: [{ role: 'system', content: system }, { role: 'user', content: user }],
        stream: false,
        temperature: 0.9,
        max_tokens: 8192
      })
    }).then(function (res) {
      return res.json().then(function (data) {
        if (!res.ok) {
          var msg = (data.error && data.error.message) || t('web.proxyErr');
          throw new Error(msg);
        }
        var text = data && data.choices && data.choices[0] && data.choices[0].message &&
          data.choices[0].message.content;
        if (!text) throw new Error(t('web.proxyErr'));
        return text;
      });
    });
  }

  function setLoading(on) {
    var b = document.getElementById('btnGen');
    if (b) { b.disabled = on; b.textContent = on ? t('gen.loading') : t('btn.generate'); }
    var box = document.getElementById('resultBox');
    if (on && box) box.innerHTML = '<div class="spinner"></div>' + esc(t('gen.loading'));
  }

  function generateTool(en) {
    var cfg = toolConfig(en.id);
    var vals = state.formVals[en.id] || {};
    var missing = cfg.fields.some(function (f) {
      return f.required && usedVal(vals, f) === '';
    });
    if (missing) { toast(t('err.required')); return; }
    if (state.toolStates[en.id]) return;
    state.toolStates[en.id] = true;
    setLoading(true);
    var p = buildPrompt(en);
    fetchAi(p.system, p.user).then(function (text) {
      var content = text.trim();
      var json = null;
      if (en.id === 'courseware') {
        var clean = content.replace(/^```(?:json)?\s*/i, '').replace(/```\s*$/, '').trim();
        try {
          json = JSON.parse(clean);
          content = JSON.stringify(json, null, 2);
          state.formVals[en.id]._json = content;
        } catch (e) {
          json = null;
        }
      } else {
        content = content + '\n\n' + aiNote();
      }
      state.formVals[en.id]._result = content;
      showResult(content, en.id === 'courseware');
      if (state.autoSave && content) {
        addHistory(en, content);
      }
      toast(t('toast.saved'));
    }).catch(function (err) {
      showResult('', false);
      var box = document.getElementById('resultBox');
      if (box) box.innerHTML = '<span class="hint-err">' + esc(t('err.genFail') + ' ' + err.message) + '</span>';
      toast(err.message);
    }).then(function () {
      state.toolStates[en.id] = false;
      setLoading(false);
    });
  }

  function showResult(text, isJson) {
    var box = document.getElementById('resultBox');
    if (!box) return;
    box.textContent = text;
    box.classList.remove('loading');
    var btn = document.getElementById('btnJson');
    if (btn) btn.disabled = !isJson || !text;
  }

  function copyResult() {
    var v = state.formVals[state.selId];
    if (!v || !v._result) { toast(t('err.noContent')); return; }
    copyText(v._result, t('toast.copied'));
  }

  function exportCoursewareJson() {
    var v = state.formVals[state.selId];
    if (!v || !v._json) return;
    var blob = new Blob([v._json], { type: 'application/json' });
    var a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = 'courseware-outline.json';
    a.click();
    URL.revokeObjectURL(a.href);
    toast(t('web.exportJson'));
  }

  /* ---------- 历史记录 ---------- */
  function addHistory(en, content) {
    var item = {
      id: Date.now(),
      type: en.labelKey,
      content: content,
      time: new Date().toLocaleString()
    };
    state.history.unshift(item);
    if (state.history.length > 200) state.history.length = 200;
    save('history', state.history);
  }
  function saveResultToHistory(en, content) {
    var v = state.formVals[en.id];
    var text = content || (v && v._result);
    if (!text) { toast(t('err.noContent')); return; }
    addHistory(en, text);
    toast(t('toast.saved'));
  }
  function renderHistory() {
    var pane = $('#rightPane');
    var rows = state.history.map(function (it) {
      return '<div class="list-item" data-id="' + it.id + '">' +
        '<div class="list-main">' +
        '<div class="list-title">' + esc(t(it.type)) + '</div>' +
        '<div class="list-sub">' + esc(it.time) + '</div></div>' +
        '<button class="btn btn-ghost act-view">' + esc(t('hist.view')) + '</button>' +
        '<button class="btn btn-danger act-del">' + esc(t('cls.del')) + '</button></div>';
    }).join('') || '<div class="empty-tip">' + esc(t('hist.empty')) + '</div>';
    pane.innerHTML =
      '<div class="right-page"><div class="page-head"><h2>' + esc(t('hist.title')) + '</h2>' +
      '<div class="head-sub">' + esc(t('hist.count').replace('{n}', String(state.history.length))) + '</div></div>' +
      '<div class="page-body">' + rows +
      '<div class="btn-row" style="margin-top:12px"><button class="btn btn-danger" id="histClear">' +
      esc(t('btn.clear')) + '</button></div></div></div>';
    pane.querySelectorAll('.list-item').forEach(function (li) {
      var id = Number(li.getAttribute('data-id'));
      li.querySelector('.act-view').onclick = function (e) { e.stopPropagation(); openHistoryModal(id); };
      li.querySelector('.act-del').onclick = function (e) {
        e.stopPropagation();
        if (!confirm(t('web.confirmDel'))) return;
        state.history = state.history.filter(function (h) { return h.id !== id; });
        save('history', state.history); renderHistory();
      };
    });
    var clr = document.getElementById('histClear');
    if (clr) clr.onclick = function () {
      if (state.history.length === 0) return;
      if (!confirm(t('hist.clearMsg'))) return;
      state.history = []; save('history', state.history); renderHistory();
    };
  }
  function openHistoryModal(id) {
    var it = state.history.find(function (h) { return h.id === id; });
    if (!it) return;
    openModal(t(it.type), it.content, [
      { label: t('btn.copy'), cls: 'btn-success', fn: function () { copyText(it.content, t('toast.copied')); } }
    ]);
  }

  /* ---------- 通用弹层 ---------- */
  var modalCb = [];
  function openModal(title, bodyHtml, actions) {
    var mask = document.createElement('div');
    mask.className = 'modal-mask';
    mask.innerHTML =
      '<div class="modal">' +
      '<div class="modal-head"><div class="modal-title">' + esc(title) + '</div>' +
      '<button class="back-btn" data-x>&times;</button></div>' +
      '<div class="modal-body">' + (typeof bodyHtml === 'string' && /<[a-z]/.test(bodyHtml) ? bodyHtml : esc(bodyHtml)) + '</div>' +
      '<div class="modal-foot"></div></div>';
    var foot = mask.querySelector('.modal-foot');
    (actions || []).forEach(function (a) {
      var b = document.createElement('button');
      b.className = 'btn ' + (a.cls || 'btn-ghost');
      b.textContent = a.label;
      b.onclick = function () { a.fn && a.fn(); };
      foot.appendChild(b);
    });
    var closeB = document.createElement('button');
    closeB.className = 'btn btn-ghost';
    closeB.textContent = t('btn.close');
    closeB.onclick = close;
    foot.appendChild(closeB);
    function close() { mask.remove(); }
    mask.querySelector('[data-x]').onclick = close;
    mask.addEventListener('click', function (e) { if (e.target === mask) close(); });
    document.body.appendChild(mask);
  }

  /* ---------- 设置 ---------- */
  function renderSettings() {
    var pane = $('#rightPane');
    var langSel = ['zh', 'en', 'ug', 'bo', 'mn'].map(function (c) {
      return '<option value="' + c + '"' + (state.lang === c ? ' selected' : '') + '>' +
        esc(t('langName.' + c)) + '</option>';
    }).join('');
    pane.innerHTML =
      '<div class="right-page"><div class="page-head"><h2>' + esc(t('set.title')) + '</h2></div>' +
      '<div class="page-body">' +
      '<div class="wcard"><div class="set-row"><div><div class="set-label">' + esc(t('set.language')) + '</div>' +
      '<div class="set-note">' + esc(t('set.themeHint')) + '</div></div>' +
      '<select id="setLang" style="font:inherit;font-size:14px;padding:9px 12px;border-radius:10px;border:1px solid var(--line);background:var(--input-bg);color:var(--text)">' + langSel + '</select></div>' +
      '<div class="set-row"><div><div class="set-label">' + esc(t('set.theme')) + '</div></div>' +
      '<div class="seg" id="themeSeg">' +
      '<button data-t="light"' + (state.theme === 'light' ? ' class="active"' : '') + '>' + esc(t('set.themeLight')) + '</button>' +
      '<button data-t="dark"' + (state.theme === 'dark' ? ' class="active"' : '') + '>' + esc(t('set.themeDark')) + '</button>' +
      '<button data-t="system"' + (state.theme === 'system' ? ' class="active"' : '') + '>' + esc(t('set.themeSystem')) + '</button>' +
      '</div></div>' +
      '<div class="set-row"><div><div class="set-label">' + esc(t('set.autoSaveHistory')) + '</div>' +
      '<div class="set-note">' + esc(t('set.autoSaveHint')) + '</div></div>' +
      '<label class="switch"><input type="checkbox" id="autoSw"' + (state.autoSave ? ' checked' : '') + '><i></i></label></div>' +
      '<div class="set-row"><div><div class="set-label">' + esc(t('set.aboutName')) + '</div>' +
      '<div class="set-note">' + esc(t('set.version')) + '</div></div></div>' +
      '<div class="set-row"><div><div class="set-label">' + esc(t('set.license')) + '</div>' +
      '<div class="set-note">' + esc(t('set.agpl')) + '</div></div></div>' +
      '</div></div></div>';
    document.getElementById('setLang').onchange = function (e) { setLang(e.target.value); };
    document.querySelectorAll('#themeSeg button').forEach(function (b) {
      b.onclick = function () { setTheme(b.getAttribute('data-t')); };
    });
    document.getElementById('autoSw').onchange = function (e) {
      state.autoSave = e.target.checked; save('auto', state.autoSave);
    };
  }

  /* ---------- 班级管理 ---------- */
  function classesNow() { return state.classes; }
  function persistClasses() { save('classes', state.classes); }
  function renderClasses() {
    var pane = $('#rightPane');
    var rows = classesNow().map(function (c) {
      return '<div class="list-item" data-id="' + c.id + '">' +
        '<div class="list-main"><div class="list-title">' + esc(c.name) + '</div>' +
        '<div class="list-sub">' + esc(t('cls.students').replace('{n}', String(c.students.length))) + '</div></div>' +
        '<button class="btn btn-ghost act-open">' + esc(t('hist.view')) + '</button>' +
        '<button class="btn btn-danger act-del">' + esc(t('cls.del')) + '</button></div>';
    }).join('') || '<div class="empty-tip">' + esc(t('cls.empty')) + '</div>';
    pane.innerHTML =
      '<div class="right-page"><div class="page-head"><h2>' + esc(t('page.classes')) + '</h2></div>' +
      '<div class="page-body">' +
      '<div class="wcard"><div class="btn-row">' +
      '<input id="clsName" style="font:inherit;font-size:14px;padding:9px 12px;border-radius:10px;border:1px solid var(--line);background:var(--input-bg);color:var(--text);flex:1;min-width:220px" placeholder="' + esc(t('cls.namePh')) + '"/>' +
      '<button class="btn btn-primary" id="clsNew">' + esc(t('cls.new')) + '</button></div></div>' +
      '<div class="listWrap">' + rows + '</div></div></div>';
    document.getElementById('clsNew').onclick = function () {
      var inp = document.getElementById('clsName');
      var name = (inp.value || '').trim();
      if (!name) { toast(t('cls.nameRequired')); return; }
      state.classes.push({ id: Date.now(), name: name, students: [] });
      persistClasses(); renderClasses(); toast(t('toast.saved'));
    };
    pane.querySelectorAll('.list-item').forEach(function (li) {
      var id = Number(li.getAttribute('data-id'));
      li.querySelector('.act-open').onclick = function () { currentDetailClassId = id; renderClassDetail(); };
      li.querySelector('.act-del').onclick = function () {
        if (!confirm(t('cls.delClassMsg'))) return;
        state.classes = state.classes.filter(function (c) { return c.id !== id; });
        persistClasses(); renderClasses();
      };
    });
  }
  function renderClassDetail() {
    var c = classesNow().find(function (x) { return x.id === currentDetailClassId; });
    var pane = $('#rightPane');
    if (!c) { renderClasses(); return; }
    var stRows = c.students.map(function (s, i) {
      return '<tr><td>' + esc(s.no || '-') + '</td><td>' + esc(s.name) + '</td><td>' + esc(s.height || '-') + '</td>' +
        '<td><button class="btn btn-danger" style="padding:4px 10px;font-size:12px" data-i="' + i + '">' + esc(t('cls.del')) + '</button></td></tr>';
    }).join('');
    pane.innerHTML =
      '<div class="right-page"><div class="back-bar"><button class="back-btn" id="backList">&larr;</button>' +
      '<h2 style="font-size:20px">' + esc(t('cls.detail')) + '</h2></div>' +
      '<div class="page-body">' +
      '<div class="wcard"><div class="btn-row">' +
      '<input id="stuName" style="font:inherit;font-size:14px;padding:9px 12px;border-radius:10px;border:1px solid var(--line);background:var(--input-bg);color:var(--text);flex:1.4" placeholder="' + esc(t('cls.colName')) + '"/>' +
      '<input id="stuHeight" type="number" style="font:inherit;font-size:14px;padding:9px 12px;border-radius:10px;border:1px solid var(--line);background:var(--input-bg);color:var(--text);flex:1" placeholder="' + esc(t('cls.colHeight')) + '"/>' +
      '<button class="btn btn-success" id="stuAdd">' + esc(t('cls.add')) + '</button></div>' +
      '<div class="hint">' + esc(t('mine.local')) + '</div></div>' +
      '<div class="wcard"><table class="seat-table"><thead><tr><th>' + esc(t('cls.colNo')) + '</th><th>' + esc(t('cls.colName')) + '</th><th>' + esc(t('cls.colHeight')) + '</th><th></th></tr></thead>' +
      '<tbody>' + (stRows || '<tr><td colspan="4" style="text-align:center;color:var(--hint);padding:18px">' + esc(t('cls.noStudents')) + '</td></tr>') + '</tbody></table></div>' +
      '</div></div>';
    document.getElementById('backList').onclick = function () { renderClasses(); };
    document.getElementById('stuAdd').onclick = function () {
      var n = document.getElementById('stuName').value.trim();
      var h = document.getElementById('stuHeight').value.trim();
      if (!n) { toast(t('cls.nameNeed')); return; }
      var no = nextFreeNo(c);
      c.students.push({ no: no, name: n, height: h, note: '' });
      persistClasses(); renderClassDetail();
    };
    pane.querySelectorAll('td button').forEach(function (b) {
      b.onclick = function () {
        var i = Number(b.getAttribute('data-i'));
        if (!confirm(t('cls.removeStudent'))) return;
        c.students.splice(i, 1); persistClasses(); renderClassDetail();
      };
    });
  }
  function nextFreeNo(c) {
    var n = 1;
    while (c.students.some(function (s) { return s.no === String(n); })) { n++; }
    return String(n);
  }

  /* ---------- 排座位（本地算法，蛇形排序） ---------- */
  function renderSeats() {
    var pane = $('#rightPane');
    var v = state.formVals.seats || {};
    pane.innerHTML =
      '<div class="right-page"><div class="page-head"><h2>' + esc(t('card.seats')) + '</h2></div>' +
      '<div class="page-body">' +
      '<div class="wcard"><div class="form-row">' +
      '<div class="field"><label>' + esc(t('seats.rows')) + '</label><input id="sRows" type="number" min="1" value="' + esc(v.rows || '') + '"/></div>' +
      '<div class="field"><label>' + esc(t('seats.cols')) + '</label><input id="sCols" type="number" min="1" value="' + esc(v.cols || '') + '"/></div>' +
      '</div>' +
      '<div class="field wide"><label>' + esc(t('seats.students')) + '</label>' +
      '<textarea id="sStu" style="min-height:120px">' + esc(v.students || '') + '</textarea></div>' +
      '<div class="btn-row" style="margin-top:10px"><button class="btn btn-primary" id="sGen">' + esc(t('seats.gen')) + '</button>' +
      '<button class="btn btn-success" id="sCopy" disabled>' + esc(t('btn.copy')) + '</button></div>' +
      '<div class="hint">' + esc(t('hint.common')) + '</div></div>' +
      '<div class="wcard" id="seatOut"><div class="empty-tip">' + esc(t('web.emptyDesc')) + '</div></div>' +
      '</div></div>';
    document.getElementById('sRows').oninput = cacheInput('seats', 'rows');
    document.getElementById('sCols').oninput = cacheInput('seats', 'cols');
    document.getElementById('sStu').oninput = cacheInput('seats', 'students');
    document.getElementById('sGen').onclick = function () {
      var rows = parseInt(document.getElementById('sRows').value, 10);
      var cols = parseInt(document.getElementById('sCols').value, 10);
      if (!(rows > 0) || !(cols > 0)) { toast(t('seats.errLayout')); return; }
      var list = parseStudents(document.getElementById('sStu').value);
      if (!list.length) { toast(t('cls.noStudents')); return; }
      var capacity = rows * cols;
      var seatData = buildSeats(rows, cols, list);
      var cell = function (name) { return '<td>' + esc(name) + '</td>'; };
      var thead = '<tr>' + Array.from({ length: cols }, function () { return '<th>&nbsp;</th>'; }).join('') + '</tr>';
      var body = seatData.map(function (row) {
        var line = '';
        for (var i = 0; i < cols; i++) {
          line += cell(row[i] || '');
        }
        return '<tr>' + line + '</tr>';
      }).join('');
      var out = document.getElementById('seatOut');
      out.innerHTML = '<div class="podium">' + esc(t('seats.podium')) + '</div><table class="seat-table"><tbody>' + body + '</tbody></table>';
      var cap = document.getElementById('sCopy');
      cap.disabled = false;
      cap.onclick = function () {
        var txt = seatData.map(function (row) { return row.join('\t'); }).join('\n');
        copyText(txt, t('web.seatsCopied'));
      };
      if (list.length > capacity) {
        toast(t('seats.errCount').replace('{n}', String(list.length)).replace('{m}', String(capacity)));
      }
    };
    void v;
  }
  function cacheInput(tool, key) {
    return function (e) {
      var map = state.formVals[tool] || {};
      map[key] = e.target.value;
      state.formVals[tool] = map;
    };
  }
  function parseStudents(text) {
    var list = [];
    String(text || '').split('\n').forEach(function (line) {
      line = line.trim();
      if (!line) return;
      var m = line.match(/^(.+?)\s+([\d.]+)\s*(cm)?$/i);
      list.push({ name: m ? m[1].trim() : line, height: m ? parseFloat(m[2]) : 0 });
    });
    return list;
  }
  function buildSeats(rows, cols, list) {
    var sorted = list.slice().sort(function (a, b) { return a.height - b.height; });
    var grid = [];
    for (var r = 0; r < rows; r++) grid.push([]);
    var order = [];
    for (var y = 0; y < rows; y++) {
      var cur = [];
      for (var x = 0; x < cols; x++) cur.push([y, x]);
      if (y % 2 === 1) cur.reverse(); // 蛇形
      order = order.concat(cur);
    }
    for (var i = 0; i < order.length && i < sorted.length; i++) {
      grid[order[i][0]][order[i][1]] = sorted[i].name;
    }
    return grid;
  }

  /* ---------- Toast / 提示 ---------- */
  var toastTimer = -1;
  function copyText(text, okMsg) {
    var done = function () { toast(okMsg); };
    var fallback = function () {
      var ta = document.createElement('textarea');
      ta.value = text;
      ta.style.position = 'fixed';
      ta.style.opacity = '0';
      document.body.appendChild(ta);
      ta.select();
      var ok = false;
      try { ok = document.execCommand('copy'); } catch (e) { ok = false; }
      ta.remove();
      if (ok) { done(); } else { toast(t('err.copyFail')); }
    };
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(done, fallback);
    } else {
      fallback();
    }
  }
  function toast(msg) {
    var el = $('#toast');
    el.textContent = msg;
    el.classList.add('show');
    if (toastTimer !== -1) clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { el.classList.remove('show'); }, 2200);
  }

  /* ---------- 渲染调度 ---------- */
  function renderAll() {
    renderLeft();
    renderRight();
  }

  function boot() {
    applyTheme();
    renderAll();
  }

  document.addEventListener('DOMContentLoaded', boot);
})();
