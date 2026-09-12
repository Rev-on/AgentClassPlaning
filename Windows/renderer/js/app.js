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
      'web.emptyDesc': '点击左侧卡片开始使用',
      'think.title': '深度思考', 'think.hint': '先推理再作答，更严谨但耗时更长',
      'think.running': '深度思考中...', 'think.done': '深度思考过程',
      'think.expand': '展开', 'think.collapse': '收起',
      'btn.export': '导出', 'btn.exportWord': '导出 Word', 'btn.exportPpt': '导出 PPT',
      'btn.saveBack': '保存回班级', 'btn.import': '导入名单', 'btn.rename': '重命名',
      'toast.exported': '已导出成功', 'toast.imported': '已导入 {n} 条',
      'toast.classSaved': '已保存到班级', 'toast.swapped': '已互换座位',
      'hist.export': '导出', 'hist.exportTitle': '导出为 Word',
      'seats.sideOn': '左右护法位', 'seats.leftGuard': '讲台左', 'seats.rightGuard': '讲台右',
      'seats.import': '导入班级名单', 'seats.guardHint': '护法位不占座，显示在讲台两侧；点击两个座位可互换',
      'seats.saveBack': '保存回班级', 'seats.noClass': '暂无可导入的班级',
      'cls.import': '导入名单（Excel/Word）', 'cls.export': '导出名单',
      'cls.importSelected': '选择班级导入', 'cls.importInto': '导入学生名单',
      'analysis.file': '选择 Excel 文件导入', 'analysis.fileTip': '支持 .xlsx 一行一条学情数据',
      'err.badJson': '课件 JSON 解析失败', 'err.noJson': '暂无课件数据可导出 PPT',
      'err.importFail': '导入文件解析失败，请检查文件', 'err.noResult': '暂无内容可导出',
      'err.guardInput': '请填写护法位姓名', 'disclaimer.title': '使用须知',
      'disclaimer.text': '本应用面向初中教师备课场景。由 AI 生成的教学内容仅供参考，请依据课标与班级实际把关。所有生成内容版权归你所有。',
      'disclaimer.accept': '同意并继续', 'disclaimer.decline': '不同意',
      'disclaimer.countdown': '{n} 秒后可继续',
      'md.bold': '加粗', 'md.italic': '斜体', 'md.underline': '下划线',
      'md.strike': '删除线', 'md.color': '文字颜色', 'md.editHint': '生成后可在此直接编辑，点击/框选文字后用工具栏设置格式'
    },
    en: {
      'f.mode': 'Mode', 'f.researchTopic': 'Research topic / teaching pain point',
      'f.researchMaterial': 'Extra material (optional)', 'f.reportStudent': 'Student name',
      'f.reportClass': 'Class', 'f.situation': 'Describe the situation',
      'web.confirmDel': 'Delete this record?',
      'web.exportJson': 'JSON file exported', 'web.seatsCopied': 'Seat plan copied',
      'web.proxyErr': 'Cannot reach AI service. Check network and retry later.',
      'err.required': 'Please fill in the required fields',
      'web.emptyDesc': 'Pick a tool from the left panel to start',
      'think.title': 'Deep Thinking', 'think.hint': 'Reason first: better quality, slower',
      'think.running': 'Thinking deeply...', 'think.done': 'Deep thinking process',
      'think.expand': 'Expand', 'think.collapse': 'Collapse',
      'btn.export': 'Export', 'btn.exportWord': 'Export Word', 'btn.exportPpt': 'Export PPT',
      'btn.saveBack': 'Save to class', 'btn.import': 'Import roster', 'btn.rename': 'Rename',
      'toast.exported': 'Exported', 'toast.imported': 'Imported {n} items',
      'toast.classSaved': 'Saved to class', 'toast.swapped': 'Seats swapped',
      'hist.export': 'Export', 'hist.exportTitle': 'Export as Word',
      'seats.sideOn': 'Side guard seats', 'seats.leftGuard': 'Left', 'seats.rightGuard': 'Right',
      'seats.import': 'Import from class', 'seats.guardHint': 'Guards do not take a seat; click two cells to swap',
      'seats.saveBack': 'Save to class', 'seats.noClass': 'No class available to import',
      'cls.import': 'Import roster (Excel/Word)', 'cls.export': 'Export roster',
      'cls.importSelected': 'Pick class to import into', 'cls.importInto': 'Import student roster',
      'analysis.file': 'Import from Excel', 'analysis.fileTip': '.xlsx, one survey record per row',
      'err.badJson': 'Failed to parse courseware JSON', 'err.noJson': 'No courseware data to export PPT',
      'err.importFail': 'Failed to parse the file', 'err.noResult': 'Nothing to export',
      'err.guardInput': 'Please enter a guard-seat name', 'disclaimer.title': 'Notice',
      'disclaimer.text': 'This app assists middle-school teachers. AI-generated content is for reference only; please review against the curriculum. All generated content is yours.',
      'disclaimer.accept': 'Agree & continue', 'disclaimer.decline': 'Decline',
      'disclaimer.countdown': 'Continue in {n}s',
      'md.bold': 'Bold', 'md.italic': 'Italic', 'md.underline': 'Underline',
      'md.strike': 'Strikethrough', 'md.color': 'Text color', 'md.editHint': 'Editable after generation: select text then use the toolbar'
    }
  };

  /* 把新增键合并进词典：zh/en 直接命中，少数民族语言缺失时仍由 t() 回退中文 */
  (function () {
    var m = window.I18N_DATA;
    if (!m) return;
    m.zh = Object.assign({}, m.zh || {}, EXTRA.zh);
    m.en = Object.assign({}, m.en || {}, EXTRA.en);
  })();

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
    deepThink: load('deepThink', false),   // 深度思考开关（与鸿蒙端一致，localStorage 持久化）
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
      '      <div class="wcard"><div id="resultBox" class="result-box" contenteditable="false" title="">' + esc(t('web.emptyDesc')) + '</div>' +
      '        <div class="md-toolbar" id="mdToolbar" style="display:none" title="' + esc(t('md.editHint')) + '">' +
      '          <button type="button" class="md-btn" data-cmd="bold" title="' + esc(t('md.bold')) + '"><b>B</b></button>' +
      '          <button type="button" class="md-btn" data-cmd="italic" title="' + esc(t('md.italic')) + '"><i>I</i></button>' +
      '          <button type="button" class="md-btn" data-cmd="underline" title="' + esc(t('md.underline')) + '"><u>U</u></button>' +
      '          <button type="button" class="md-btn" data-cmd="strikeThrough" title="' + esc(t('md.strike')) + '"><s>S</s></button>' +
      '          <input type="color" class="md-color" id="mdColor" value="#d92d20" title="' + esc(t('md.color')) + '"/>' +
      '          <span class="md-hint">' + esc(t('md.editHint')) + '</span>' +
      '        </div></div>' +
      '  </div></div>';
    pane.innerHTML = html;
    bindToolForm(en);
    bindMdToolbar();
    // 切回本工具时回显最近一次结果（富文本）；有编辑过的 HTML 优先还原编辑态
    var cached = state.formVals[en.id];
    if (cached && cached._result) {
      if (cached._resultHtml) {
        var rb0 = document.getElementById('resultBox');
        if (rb0) { rb0.innerHTML = cached._resultHtml; rb0.classList.remove('loading'); }
      } else {
        renderResultInto(document.getElementById('resultBox'), cached._result, en.id === 'courseware');
      }
      setEditing(true);
      var jb = document.getElementById('btnJson');
      if (jb) jb.disabled = !(en.id === 'courseware' && cached._json);
      var pb = document.getElementById('btnPpt');
      if (pb) pb.disabled = !(en.id === 'courseware' && cached._json);
      var wb = document.getElementById('btnWord');
      if (wb) wb.disabled = !cached._result;
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
    // 深度思考开关：与鸿蒙端一致，开启后本次生成走 thinking.type=enabled（更严谨、更慢）
    var thinkSwitch = '<div class="set-row" style="border-top:1px solid var(--line);margin-top:14px;padding-top:14px">' +
      '<div><div class="set-label">' + esc(t('think.title')) + '</div>' +
      '<div class="set-note">' + esc(t('think.hint')) + '</div></div>' +
      '<label class="switch"><input type="checkbox" id="deepThinkSw"' + (state.deepThink ? ' checked' : '') + '><i></i></label></div>';
    return '<div class="wcard"><div class="form-row">' + inner + '</div>' + thinkSwitch +
      (en.id === 'analysis'
        ? '<div class="btn-row" style="margin-top:12px"><button class="btn btn-ghost" id="analysisFileBtn">' + esc(t('analysis.file')) + '</button>' +
          '<div class="set-note" style="min-height:0">' + esc(t('analysis.fileTip')) + '</div></div>'
        : '') +
      '</div>';
  }

  function toolActionBar(en) {
    if (en.id === 'courseware') {
      return '<button class="btn btn-primary" id="btnGen">' + esc(t('btn.generate')) + '</button>' +
        '<button class="btn btn-success" id="btnCopy">' + esc(t('btn.copy')) + '</button>' +
        '<button class="btn btn-ghost" id="btnSave">' + esc(t('btn.saveHist')) + '</button>' +
        '<button class="btn btn-ghost" id="btnJson" disabled>' + esc(t('btn.exportJson')) + '</button>' +
        '<button class="btn btn-ghost" id="btnPpt" disabled>' + esc(t('btn.exportPpt')) + '</button>' +
        '<button class="btn btn-danger" id="btnClear">' + esc(t('btn.clear')) + '</button>';
    }
    return '<button class="btn btn-primary" id="btnGen">' + esc(t('btn.generate')) + '</button>' +
      '<button class="btn btn-success" id="btnCopy">' + esc(t('btn.copy')) + '</button>' +
      '<button class="btn btn-ghost" id="btnSave">' + esc(t('btn.saveHist')) + '</button>' +
      '<button class="btn btn-ghost" id="btnWord" disabled>' + esc(t('btn.exportWord')) + '</button>' +
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
    // 深度思考开关状态绑定（全局持久化，与鸿蒙端一致）
    var dts = document.getElementById('deepThinkSw');
    if (dts) {
      dts.onchange = function () {
        state.deepThink = dts.checked; save('deepThink', state.deepThink);
      };
    }
    // 行内动作
    var act = function (id, fn) { var b = document.getElementById(id); if (b) b.onclick = fn; };
    act('btnGen', function () { generateTool(en); });
    act('btnCopy', function () { copyResult(); });
    act('btnSave', function () { saveResultToHistory(en, null); });
    act('btnClear', function () { state.formVals[en.id] = {}; renderRight(); });
    act('btnJson', function () { exportCoursewareJson(); });
    act('btnPpt', function () { exportCoursewarePpt(); });
    act('btnWord', function () { exportResultWord(); });
    act('analysisFileBtn', function () { analysisImportFile(); });
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

  /* 请求体：与鸿蒙端一致，stream=true 走 SSE 流式（服务端逐块透传 DeepSeek 原生 delta） */
  function aiBody(system, user) {
    return {
      model: MODEL,
      messages: [{ role: 'system', content: system }, { role: 'user', content: user }],
      stream: true,
      temperature: 0.9,
      max_tokens: 8192,
      thinking: { type: state.deepThink ? 'enabled' : 'disabled' }
    };
  }

  /**
   * SSE 流式请求：逐块解析，onThink(onReasoning) / onDelta(onContentPartial) 实时回调；
   * resolve 为完整正文文本（含思考时仅正文）。网络/服务错误统一 reject。
   */
  function fetchAi(system, user, onThink, onDelta) {
    return fetch(PROXY, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'x-proxy-token': TOKEN },
      body: JSON.stringify(aiBody(system, user))
    }).then(function (res) {
      if (!res.ok) {
        return res.json().then(function (d) {
          var msg = (d && d.error && d.error.message) || t('web.proxyErr');
          throw new Error(msg);
        });
      }
      if (!res.body || typeof res.body.getReader !== 'function') {
        // 兜底：非流式 JSON（兼容旧代理/降级）
        return res.json().then(function (data) {
          var ch = data && data.choices && data.choices[0];
          if (!ch || !ch.message) throw new Error(t('web.proxyErr'));
          var rc = ch.message.reasoning_content;
          if (rc && onThink) onThink(rc);
          var text = ch.message.content;
          if (!text) throw new Error(t('web.proxyErr'));
          return text;
        });
      }
      var reader = res.body.getReader();
      var dec = new TextDecoder('utf-8');
      var buf = '', full = '', reason = '';
      function pump() {
        return reader.read().then(function (r) {
          if (r.done) return full;
          buf = buf + dec.decode(r.value, { stream: true });
          var idx;
          while ((idx = buf.indexOf('\n\n')) >= 0) {
            var block = buf.slice(0, idx);
            buf = buf.slice(idx + 2);
            block.split('\n').forEach(function (line) {
              if (line.indexOf('data:') !== 0) return;
              var ev = line.slice(5).trim();
              if (ev === '[DONE]') return;
              var ch2;
              try { ch2 = JSON.parse(ev); } catch (e) { return; }
              var ch = ch2.choices && ch2.choices[0];
              if (!ch || !ch.delta) return;
              if (typeof ch.delta.reasoning_content === 'string' && ch.delta.reasoning_content) {
                reason += ch.delta.reasoning_content;
                if (onThink) onThink(reason);
              }
              if (typeof ch.delta.content === 'string' && ch.delta.content) {
                full += ch.delta.content;
                if (onDelta) onDelta(full);
              }
            });
          }
          return pump();
        });
      }
      return pump();
    });
  }

  function setLoading(on) {
    var b = document.getElementById('btnGen');
    if (b) { b.disabled = on; b.textContent = on ? t('gen.loading') : t('btn.generate'); }
    var box = document.getElementById('resultBox');
    if (on && box) box.innerHTML = '<div class="spinner"></div>' + esc(t('gen.loading'));
    if (on) setEditing(false);   // 生成中禁止编辑；结束后的编辑态由 showResult 等控制
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
    // 保证本工具的输入缓存存在，避免流式完成回写 _result/_json 时崩溃
    if (!state.formVals[en.id]) state.formVals[en.id] = {};
    var store = state.formVals[en.id];
    setLoading(true);
    var p = buildPrompt(en);
    var thinkBox = null, thinkBody = null;
    if (state.deepThink) {
      thinkBox = createThinkPanel();
      thinkBody = thinkBox.querySelector('.think-body');
    }
    fetchAi(p.system, p.user,
      (state.deepThink ? function (think) {
        if (!thinkBox || !thinkBody) return;
        thinkBody.textContent = think;
        var running = thinkBox.classList.contains('running');
        if (running) thinkBody.scrollTop = thinkBody.scrollHeight;   // 生成中保持最新行
      } : undefined),
      function (partial) { streamResult(partial); }   // 流式：正文逐块上屏
    ).then(function (text) {
      if (thinkBox && thinkBody) collapseThinkPanel(thinkBox, thinkBody);  // 完成自动折叠
      var content = String(text || '').trim();
      var json = null;
      if (en.id === 'courseware') {
        var clean = content.replace(/^```(?:json)?\s*/i, '').replace(/```\s*$/, '').trim();
        try {
          json = JSON.parse(clean);
          content = JSON.stringify(json, null, 2);
          store._json = content;
        } catch (e) {
          json = null;
        }
      } else {
        content = content + '\n\n' + aiNote();
      }
      store._result = content;
      showResult(content, en.id === 'courseware');
      if (state.autoSave && content) {
        addHistory(en, content);
      }
      toast(t('toast.saved'));
    }).catch(function (err) {
      if (thinkBox && thinkBody) collapseThinkPanel(thinkBox, thinkBody);  // 失败也收回正文
      showResult('', false);
      var box = document.getElementById('resultBox');
      if (box) box.innerHTML = '<span class="hint-err">' + esc(t('err.genFail') + ' ' + err.message) + '</span>';
      toast(err.message);
    }).then(function () {
      state.toolStates[en.id] = false;
      setLoading(false);
    });
  }

  /** 流式分块上屏：Markdown 实时渲染 + 自动滚到最底部 */
  function streamResult(partial) {
    var box = document.getElementById('resultBox');
    if (!box) return;
    box.innerHTML = mdToHtml(partial || '');
    box.classList.remove('loading');
    scrollResultBottom(box);
  }

  /** 富文本渲染进预览框；JSON 以 <pre> 原文显示（流式完成后排版） */
  function renderResultInto(box, text, isJson) {
    if (!box) return;
    box.innerHTML = isJson
      ? '<pre class="md-pre">' + escHtml(text == null ? '' : text) + '</pre>'
      : (mdToHtml(text || '') || '<p></p>');
    box.classList.remove('loading');
    scrollResultBottom(box);
  }
  function scrollResultBottom(box) {
    if (!box) return;
    box.scrollTop = box.scrollHeight;
  }

  function escHtml(s) {
    return String(s == null ? '' : s)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  }
  /** 行内：先转义，再识别 **加粗** 与 `代码`（保安全） */
  function inlineMd(text) {
    return escHtml(text)
      .replace(/`([^`]*?)`/g, '<code>$1</code>')
      .replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');
  }
  function tableHtml(rows) {
    var h = rows.map(function (r) {
      return '<tr>' + r.map(function (c) { return '<td>' + inlineMd(c) + '</td>'; }).join('') + '</tr>';
    }).join('');
    return '<table class="md-table"><tbody>' + h + '</tbody></table>';
  }
  /** 安全 Markdown → HTML（标题/列表/表格/代码块/段落；与鸿蒙 RichHtml 对齐） */
  function mdToHtml(md) {
    var lines = String(md == null ? '' : md).split(/\r?\n/);
    var out = [], i = 0, inCode = false, codeBuf = [];
    while (i < lines.length) {
      var ln = lines[i], t = ln.trim();
      if (inCode) {
        if (/^```/.test(t)) { inCode = false; out.push('<pre class="md-code">' + escHtml(codeBuf.join('\n')) + '</pre>'); codeBuf = []; }
        else { codeBuf.push(ln); }
        i++; continue;
      }
      if (/^```/.test(t)) { inCode = true; codeBuf = []; i++; continue; }
      if (/^\|/.test(t)) {
        var tbl = [];
        while (i < lines.length && /^\|/.test(lines[i].trim())) {
          var raw = lines[i].trim().replace(/^\|/, '').replace(/\|$/, '').split('|').map(function (s) { return s.trim(); });
          if (!(raw.length > 0 && raw.every(function (c) { return /^:?-+:?$/.test(c); }))) tbl.push(raw);
          i++;
        }
        if (tbl.length) out.push(tableHtml(tbl));
        continue;
      }
      var h = t.match(/^(#{1,6})\s+(.*)$/);
      if (h) { out.push('<h' + h[1].length + '>' + inlineMd(h[2]) + '</h' + h[1].length + '>'); i++; continue; }
      if (/^[-*+]\s+/.test(t)) { out.push('<ul><li>' + inlineMd(t.replace(/^[-*+]\s+/, '')) + '</li></ul>'); i++; continue; }
      if (/^\d+[.、]\s+/.test(t)) { out.push('<ul><li>' + inlineMd(t.replace(/^\d+[.、]\s+/, '')) + '</li></ul>'); i++; continue; }
      if (t === '') { i++; continue; }
      out.push('<p>' + inlineMd(ln) + '</p>');
      i++;
    }
    if (inCode) out.push('<pre class="md-code">' + escHtml(codeBuf.join('\n')) + '</pre>');
    return out.join('');
  }

  /**
   * 创建深度思考面板：标题行（点击展开/收起）+ 正文区（灰色小字，生成中滚动）
   * 折叠状态由 CSS 高度过渡实现（与鸿蒙端平滑折叠一致）
   */
  function createThinkPanel() {
    var box = document.getElementById('resultBox');
    if (!box) return null;
    var holder = document.createElement('div');
    holder.className = 'think-panel running';
    holder.innerHTML =
      '<div class="think-head" role="button" tabindex="0">' +
      '<div class="think-head-title">' + esc(t('think.running')) + '</div>' +
      '<div class="think-toggle">' + esc(t('think.collapse')) + '</div></div>' +
      '<div class="think-body-wrap"><div class="think-body"></div></div>';
    box.parentElement.insertBefore(holder, box);
    var head = holder.querySelector('.think-head');
    var bodyWrap = holder.querySelector('.think-body-wrap');
    head.addEventListener('click', function () {
      if (!holder.classList.contains('done')) return;   // 生成中不允许收起
      var expanded = holder.classList.toggle('collapsed');
      head.querySelector('.think-toggle').textContent = t(expanded ? 'think.expand' : 'think.collapse');
      void bodyWrap;
    });
    return holder;
  }

  /** 生成完成：标题切为"深度思考过程"，移除 running，并自动折叠正文 */
  function collapseThinkPanel(panel, bodyEl) {
    if (!panel) return;
    panel.classList.remove('running');
    panel.classList.add('done');
    var title = panel.querySelector('.think-head-title');
    if (title) title.textContent = t('think.done');
    panel.querySelector('.think-toggle').textContent = t('think.expand');
    panel.classList.add('collapsed');   // 触发 CSS 高度过渡，自动折叠
    if (bodyEl) bodyEl.scrollTop = 0;
  }

  /* ---------- 富文本编辑（生成完成后的预览框） ---------- */
  function setEditing(on) {
    var tb = document.getElementById('mdToolbar');
    if (tb) tb.style.display = on ? '' : 'none';
    var box = document.getElementById('resultBox');
    if (box) box.contentEditable = on ? 'true' : 'false';
  }
  function bindMdToolbar() {
    var box = document.getElementById('resultBox');
    if (!box) return;
    if (box._mdBound) return;
    box._mdBound = true;
    // 用户编辑后记录编辑态 HTML，供切回工具时还原与导出
    box.addEventListener('input', function () {
      var m = state.formVals[state.selId];
      if (m && box.isContentEditable) m._resultHtml = box.innerHTML;
    });
    document.querySelectorAll('#mdToolbar .md-btn').forEach(function (btn) {
      btn.addEventListener('mousedown', function (e) { e.preventDefault(); }); // 保持选区
      btn.addEventListener('click', function () {
        focusEditor(box);
        document.execCommand(btn.getAttribute('data-cmd'), false, null);
        syncEditState(box);
      });
    });
    var color = document.getElementById('mdColor');
    if (color) color.addEventListener('input', function () {
      focusEditor(box);
      document.execCommand('foreColor', false, color.value);
      syncEditState(box);
    });
  }
  function focusEditor(box) { if (box) box.focus({ preventScroll: true }); }
  function syncEditState(box) {
    var m = state.formVals[state.selId];
    if (m && box) m._resultHtml = box.innerHTML;
  }
  /** 预览框当前编辑后的 HTML（供导出 Word 富文本） */
  function editorHtml() {
    var box = document.getElementById('resultBox');
    return box ? box.innerHTML : null;
  }

  function showResult(text, isJson) {
    var box = document.getElementById('resultBox');
    if (!box) return;
    renderResultInto(box, text, isJson);
    setEditing(!!text);
    var btn = document.getElementById('btnJson');
    if (btn) btn.disabled = !isJson || !text;
    var pb = document.getElementById('btnPpt');
    if (pb) pb.disabled = !isJson || !text;
    var wb = document.getElementById('btnWord');
    if (wb) wb.disabled = !text;
  }

  function copyResult() {
    var box = document.getElementById('resultBox');
    var txt = (box && box.isContentEditable) ? box.innerText : null;
    if (!txt) {
      var v = state.formVals[state.selId];
      if (!v || !v._result) { toast(t('err.noContent')); return; }
      txt = v._result;
    }
    copyText(txt, t('toast.copied'));
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

  /* ---------- 文档能力（Word/PPT 导出、Excel/Word 导入） ---------- */
  function saveDoc(filename, content, markdown) {
    if (!window.RTM_OFFICE || !window.rtmNative) { toast(t('err.importFail')); return Promise.resolve(); }
    return RTM_OFFICE.docxFromMarkdown(markdown ? content : (content || ''), filename)
      .then(function (d) { return window.rtmNative.saveFile(d.name, d.data); })
      .then(function (r) { if (!r.canceled) toast(t('toast.exported')); })
      .catch(function (e) { toast(t('err.importFail') + ' ' + e.message); });
  }
  function exportResultWord() {
    var v = state.formVals[state.selId];
    if (!v || !v._result) { toast(t('err.noResult')); return; }
    var en = entryById(state.selId);
    var name = t(en.labelKey) + '-' + Date.now();
    // 有编辑富文本（HTML）时导出保留 粗/斜/下/删/颜色；否则退回 Markdown 导出
    var html = editorHtml();
    if (html && window.RTM_OFFICE && window.rtmNative && window.RTM_OFFICE.docxFromHtml) {
      RTM_OFFICE.docxFromHtml(html, name)
        .then(function (d) { return window.rtmNative.saveFile(d.name, d.data); })
        .then(function (r) { if (!r.canceled) toast(t('toast.exported')); })
        .catch(function (e) { toast(t('err.importFail') + ' ' + e.message); });
    } else {
      saveDoc(name, v._result, false);
    }
  }
  function exportCoursewarePpt() {
    var v = state.formVals.courseware;
    if (!v || !v._json) { toast(t('err.noJson')); return; }
    if (!window.RTM_OFFICE || !window.rtmNative) { toast(t('err.importFail')); return; }
    RTM_OFFICE.pptxFromCourseware(v._json, t('card.courseware') + '-' + Date.now())
      .then(function (d) { return window.rtmNative.saveFile(d.name, d.data); })
      .then(function (r) { if (!r.canceled) toast(t('toast.exported')); })
      .catch(function (e) { toast(t('err.badJson') + ' ' + e.message); });
  }

  function pickFile(accept) {
    return new Promise(function (resolve) {
      var input = document.createElement('input');
      input.type = 'file';
      input.accept = accept || '.xlsx,.xls,.docx';
      input.onchange = function () {
        var f = input.files && input.files[0];
        if (!f) { resolve(null); return; }
        var ext = (f.name.split('.').pop() || '').toLowerCase();
        var rd = new FileReader();
        rd.onload = function () { resolve({ name: f.name, ext: ext, buffer: rd.result }); };
        rd.onerror = function () { resolve(null); };
        rd.readAsArrayBuffer(f);
      };
      input.click();
    });
  }

  /* Excel/Docx → 名单学生数组 [{no,name,height,note}]，与鸿蒙 parseCells 同规则 */
  function parseRosterCells(rows) {
    var students = [];
    rows.forEach(function (cells) {
      var nonEmptyIdx = [];
      cells.forEach(function (v, i) { if (String(v).trim() !== '') nonEmptyIdx.push(i); });
      if (!nonEmptyIdx.length) return;
      var first = nonEmptyIdx[0];
      var joined = cells.join('');
      // 表头行跳过
      if (/学号|姓名|编号|班级|name|no\.?|id|序号/i.test(joined) && nonEmptyIdx.length <= 4) return;
      var isNoLike = /^\d/.test(String(cells[first]).trim());
      var name, rest = [], no = '';
      if (isNoLike) {
        no = String(cells[first]).trim();
        for (var i = first + 1; i < cells.length; i++) rest.push(String(cells[i]).trim());
      } else {
        rest = cells.slice(first).map(String);
      }
      if (!rest.length || rest[0] === '') return;
      name = rest[0];
      if (/^\d/.test(name) && rest.length === 1) return; // 只有学号无姓名
      var height = '', note = [];
      for (var k = 1; k < rest.length; k++) {
        var v = rest[k];
        if (!v) continue;
        var h = parseHeight(v);
        if (h && !height) height = String(h);
        else if (v && v !== name) note.push(v);
      }
      students.push({ no: no, name: name, height: height, note: note.join(' ') });
    });
    return students;
  }
  function parseHeight(v) {
    var s = String(v).trim();
    if (!s) return null;
    var m = s.match(/^(\d{2,3})(?:\.\d+)?(?:cm|CM|厘米)?$/);
    if (m) {
      var n = parseInt(m[1], 10);
      if (n >= 80 && n <= 230) return n;
      return null;
    }
    var mm = s.match(/^(\d{3,4})\s*mm$/i);
    if (mm) { var f = Math.round(parseInt(mm[1], 10) / 10); if (f >= 80 && f <= 230) return f; }
    var dm = s.match(/^(\d+(?:\.\d+)?)\s*m$/i);
    if (dm) { var g = Math.round(parseFloat(dm[1]) * 100); if (g >= 80 && g <= 230) return g; }
    return null;
  }

  /* 生成中/结果里导入：toTabText（学情分析粘贴到文本框） */
  function toTabText(rows) {
    return rows.map(function (r) { return r.join('\t'); }).join('\n');
  }
  function analysisImportFile() {
    pickFile('.xlsx,.xls').then(function (f) {
      if (!f) return;
      RTM_OFFICE.xlsxToRows(f.buffer).then(function (res) {
        var ta = document.getElementById('excelTa');
        if (!ta) return;
        var tab = toTabText(res.rows);
        ta.value = tab;
        var vals = state.formVals.analysis || {};
        vals.excel = tab;
        state.formVals.analysis = vals;
        toast(t('toast.imported').replace('{n}', String(res.rows.length)));
      }).catch(function () { toast(t('err.importFail')); });
    });
  }

  /* 导入 .xlsx/.docx 到指定班级 */
  function importRosterIntoClass(cls, fill) {
    pickFile('.xlsx,.xls,.docx').then(function (f) {
      if (!f) return;
      var p;
      if (f.ext === 'docx') p = RTM_OFFICE.docxToPlain(f.buffer).then(function (txt) {
        return txt.split(/\r?\n/).filter(function (l) { return l.trim() !== ''; })
          .map(function (l) { return l.split(/[\t ]+/).filter(Boolean); });
      });
      else p = RTM_OFFICE.xlsxToRows(f.buffer).then(function (res) { return res.rows; });
      p.then(function (rows) {
        var students = parseRosterCells(rows);
        if (!students.length) { toast(t('err.importFail')); return; }
        var before = cls.students.length;
        var existing = {};
        cls.students.forEach(function (s) { if (s.no) existing['n' + s.no] = true; });
        students.forEach(function (st) {
          if (st.no && existing['n' + st.no]) return; // 学号去重
          cls.students.push(Object.assign({}, st, st.no ? {} : { no: nextFreeNo(cls) }));
        });
        persistClasses();
        toast(t('toast.imported').replace('{n}', String(cls.students.length - before)));
        if (fill) fill(students);
        else renderClasses();
      }).catch(function () { toast(t('err.importFail')); });
    });
  }

  /* ---------- 免责声明：首次启动弹窗，同意后本地记忆 ---------- */
  function maybeShowDisclaimer() {
    if (load('accept', '0') === '1') return;
    var mask = document.createElement('div');
    mask.className = 'modal-mask';
    mask.innerHTML =
      '<div class="modal modal-narrow">' +
      '<div class="modal-head"><div class="modal-title">' + esc(t('disclaimer.title')) + '</div></div>' +
      '<div class="modal-body">' + esc(t('disclaimer.text')) + '</div>' +
      '<div class="modal-foot">' +
      '<button class="btn btn-ghost" data-decline>' + esc(t('disclaimer.decline')) + '</button>' +
      '<button class="btn btn-primary" data-accept disabled>' + esc(t('disclaimer.accept')) + '</button>' +
      '</div></div>';
    document.body.appendChild(mask);
    var acceptBtn = mask.querySelector('[data-accept]');
    var declineBtn = mask.querySelector('[data-decline]');
    var n = 5;
    acceptBtn.textContent = t('disclaimer.countdown').replace('{n}', n);
    var timer = setInterval(function () {
      n--;
      if (n <= 0) {
        clearInterval(timer);
        acceptBtn.disabled = false;
        acceptBtn.textContent = t('disclaimer.accept');
      } else {
        acceptBtn.textContent = t('disclaimer.countdown').replace('{n}', n);
      }
    }, 1000);
    acceptBtn.onclick = function () { save('accept', '1'); mask.remove(); };
    declineBtn.onclick = function () { mask.remove(); };
    mask.querySelector('.modal').addEventListener('click', function (e) { e.stopPropagation(); });
    void declineBtn;
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
      { label: t('hist.export'), cls: 'btn-ghost', fn: function () { saveHistoryWord(it); } },
      { label: t('btn.copy'), cls: 'btn-success', fn: function () { copyText(it.content, t('toast.copied')); } }
    ]);
  }
  function saveHistoryWord(it) {
    if (!it || !it.content) { toast(t('err.noResult')); return; }
    saveDoc(t(it.type) + '-' + it.id, it.content, true);
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
        '<button class="btn btn-ghost act-rename">' + esc(t('btn.rename')) + '</button>' +
        '<button class="btn btn-ghost act-import">' + esc(t('btn.import')) + '</button>' +
        '<button class="btn btn-ghost act-export">' + esc(t('cls.export')) + '</button>' +
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
      var cls = classesNow().find(function (c) { return c.id === id; });
      li.querySelector('.act-open').onclick = function () { currentDetailClassId = id; renderClassDetail(); };
      li.querySelector('.act-rename').onclick = function () {
        inputModal(t('btn.rename'), cls.name, t('toast.saved'), function (v) {
          cls.name = v; persistClasses(); renderClasses();
        });
      };
      li.querySelector('.act-import').onclick = function () { importRosterIntoClass(cls, null); };
      li.querySelector('.act-export').onclick = function () { exportClassList(cls); };
      li.querySelector('.act-del').onclick = function () {
        if (!confirm(t('cls.delClassMsg'))) return;
        state.classes = state.classes.filter(function (c) { return c.id !== id; });
        persistClasses(); renderClasses();
      };
    });
  }
  function exportClassList(c) {
    if (!c.students.length) { toast(t('err.noResult')); return; }
    var md = '# ' + esc2(c.name) + '\n\n' +
      '| ' + esc2(t('cls.colNo')) + ' | ' + esc2(t('cls.colName')) + ' | ' + esc2(t('cls.colHeight')) + ' |\n' +
      '| --- | --- | --- |\n' +
      c.students.map(function (s) { return '| ' + esc2(s.no || '') + ' | ' + esc2(s.name) + ' | ' + esc2(s.height || '') + ' |'; }).join('\n');
    saveDoc(c.name + '-' + Date.now(), md, true);
  }
  function esc2(s) { return String(s).replace(/\|/g, '\\|'); }
  function inputModal(title, initial, okLabel, cb) {
    var mask = document.createElement('div');
    mask.className = 'modal-mask';
    mask.innerHTML =
      '<div class="modal modal-narrow"><div class="modal-head"><div class="modal-title">' + esc(title) + '</div></div>' +
      '<div class="modal-body"><input id="inputModalVal" style="width:100%;padding:9px 12px;border-radius:10px;border:1px solid var(--line);background:var(--input-bg);color:var(--text);font:inherit" value="' + esc(initial == null ? '' : initial) + '"/></div>' +
      '<div class="modal-foot"><button class="btn btn-ghost" data-x>' + esc(t('btn.close')) + '</button>' +
      '<button class="btn btn-primary" data-ok>' + esc(okLabel) + '</button></div></div>';
    document.body.appendChild(mask);
    var inp = mask.querySelector('#inputModalVal');
    inp.focus(); inp.select();
    var ok = function () {
      var v = (inp.value || '').trim();
      if (!v) { toast(t('err.required')); return; }
      cb(v); mask.remove();
    };
    mask.querySelector('[data-x]').onclick = function () { mask.remove(); };
    mask.querySelector('[data-ok]').onclick = ok;
    inp.onkeydown = function (e) { if (e.key === 'Enter') ok(); };
    mask.addEventListener('click', function (e) { if (e.target === mask) mask.remove(); });
    mask.querySelector('.modal').addEventListener('click', function (e) { e.stopPropagation(); });
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
      '<div class="btn-row" style="margin-top:8px">' +
      '<button class="btn btn-ghost" id="clsImportBtn">' + esc(t('cls.importInto')) + '</button>' +
      '<button class="btn btn-ghost" id="clsExportBtn">' + esc(t('cls.export')) + '</button></div>' +
      '<div class="hint">' + esc(t('mine.local')) + '</div></div>' +
      '<div class="wcard"><table class="seat-table"><thead><tr><th>' + esc(t('cls.colNo')) + '</th><th>' + esc(t('cls.colName')) + '</th><th>' + esc(t('cls.colHeight')) + '</th><th></th></tr></thead>' +
      '<tbody>' + (stRows || '<tr><td colspan="4" style="text-align:center;color:var(--hint);padding:18px">' + esc(t('cls.noStudents')) + '</td></tr>') + '</tbody></table></div>' +
      '</div></div>';
    document.getElementById('backList').onclick = function () { renderClasses(); };
    document.getElementById('clsImportBtn').onclick = function () { importRosterIntoClass(c, function () { renderClassDetail(); }); };
    document.getElementById('clsExportBtn').onclick = function () { exportClassList(c); };
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

  /* ---------- 排座位（身高蛇形 + 护法位 + 点击互换 + 班级双向联动） ---------- */
  var seatModel = null;  // { grid:[[object|null]], guards:{l,r}, rows, cols }

  function renderSeats() {
    var pane = $('#rightPane');
    var v = state.formVals.seats || {};
    seatModel = null;
    pane.innerHTML =
      '<div class="right-page"><div class="page-head"><h2>' + esc(t('card.seats')) + '</h2></div>' +
      '<div class="page-body">' +
      '<div class="wcard"><div class="form-row">' +
      '<div class="field"><label>' + esc(t('seats.rows')) + '</label><input id="sRows" type="number" min="1" value="' + esc(v.rows || '') + '"/></div>' +
      '<div class="field"><label>' + esc(t('seats.cols')) + '</label><input id="sCols" type="number" min="1" value="' + esc(v.cols || '') + '"/></div>' +
      '</div>' +
      '<div class="field wide"><label>' + esc(t('seats.students')) + '</label>' +
      '<textarea id="sStu" style="min-height:96px">' + esc(v.students || '') + '</textarea></div>' +
      '<div class="set-row" style="border-top:1px solid var(--line);padding-top:10px">' +
      '<div><div class="set-label">' + esc(t('seats.sideOn')) + '</div>' +
      '<div class="set-note">' + esc(t('seats.guardHint')) + '</div></div>' +
      '<label class="switch"><input type="checkbox" id="sSide"' + (v.sideOn ? ' checked' : '') + '><i></i></label></div>' +
      '<div class="btn-row" id="sGuardRow" style="margin-top:10px">' +
      '<input id="sGuardL" style="font:inherit;font-size:14px;padding:9px 12px;border-radius:10px;border:1px solid var(--line);background:var(--input-bg);color:var(--text);flex:1" placeholder="' + esc(t('seats.leftGuard')) + '"/>' +
      '<input id="sGuardR" style="font:inherit;font-size:14px;padding:9px 12px;border-radius:10px;border:1px solid var(--line);background:var(--input-bg);color:var(--text);flex:1" placeholder="' + esc(t('seats.rightGuard')) + '"/>' +
      '</div>' +
      '<div class="btn-row" style="margin-top:12px">' +
      '<button class="btn btn-primary" id="sGen">' + esc(t('seats.gen')) + '</button>' +
      '<button class="btn btn-ghost" id="sImportClass">' + esc(t('seats.import')) + '</button>' +
      '<button class="btn btn-ghost" id="sSaveBack" disabled>' + esc(t('seats.saveBack')) + '</button>' +
      '<button class="btn btn-success" id="sCopy" disabled>' + esc(t('btn.copy')) + '</button></div>' +
      '<div class="hint">' + esc(t('hint.common')) + '</div></div>' +
      '<div class="wcard" id="seatOut"><div class="empty-tip">' + esc(t('web.emptyDesc')) + '</div></div>' +
      '</div></div>';
    document.getElementById('sRows').oninput = cacheInput('seats', 'rows');
    document.getElementById('sCols').oninput = cacheInput('seats', 'cols');
    document.getElementById('sStu').oninput = cacheInput('seats', 'students');
    var slideRow = document.getElementById('sGuardRow');
    var syncGuard = function () {
      var on = document.getElementById('sSide').checked;
      slideRow.style.display = on ? '' : 'none';
      var mv = state.formVals.seats || {};
      mv.sideOn = on; state.formVals.seats = mv;
    };
    document.getElementById('sSide').onchange = syncGuard;
    syncGuard();
    document.getElementById('sImportClass').onclick = importClassToSeats;
    document.getElementById('sGen').onclick = genSeats;
    document.getElementById('sCopy').onclick = copySeats;
    document.getElementById('sSaveBack').onclick = saveSeatsToClass;
    void v;
  }

  function classPicker(title, cb) {
    if (!classesNow().length) { toast(t('seats.noClass')); return; }
    var items = classesNow().map(function (c) {
      return '<div class="list-item" data-id="' + c.id + '">' +
        '<div class="list-main"><div class="list-title">' + esc(c.name) + '</div>' +
        '<div class="list-sub">' + esc(t('cls.students').replace('{n}', String(c.students.length))) + '</div></div></div>';
    }).join('');
    var mask = document.createElement('div');
    mask.className = 'modal-mask';
    mask.innerHTML =
      '<div class="modal modal-narrow"><div class="modal-head"><div class="modal-title">' + esc(title) + '</div>' +
      '<button class="back-btn" data-x>&times;</button></div>' +
      '<div class="modal-body" style="max-height:380px;overflow:auto">' + items + '</div></div>';
    document.body.appendChild(mask);
    mask.querySelector('[data-x]').onclick = function () { mask.remove(); };
    mask.querySelectorAll('.list-item').forEach(function (li) {
      li.style.cursor = 'pointer';
      li.onclick = function () {
        var id = Number(li.getAttribute('data-id'));
        mask.remove();
        cb(classesNow().find(function (c) { return c.id === id; }));
      };
    });
    mask.addEventListener('click', function (e) { if (e.target === mask) mask.remove(); });
    mask.querySelector('.modal').addEventListener('click', function (e) { e.stopPropagation(); });
  }

  function importClassToSeats() {
    classPicker(t('cls.importSelected'), function (cls) {
      var lines = [];
      var noHeight = 0;
      cls.students.forEach(function (s) {
        if (s.height) { lines.push(s.name + ' ' + s.height); }
        else { noHeight++; }
      });
      var ta = document.getElementById('sStu');
      ta.value = lines.join('\n');
      var mv = state.formVals.seats || {};
      mv.students = ta.value; state.formVals.seats = mv;
      toast(noHeight ? t('toast.imported').replace('{n}', String(lines.length)) + '（' + noHeight + ' ' + t('seats.guardHint') + '）' : t('toast.imported').replace('{n}', String(lines.length)));
    });
  }

  function genSeats() {
    var rows = parseInt(document.getElementById('sRows').value, 10);
    var cols = parseInt(document.getElementById('sCols').value, 10);
    if (!(rows > 0) || !(cols > 0)) { toast(t('seats.errLayout')); return; }
    var list = parseStudents(document.getElementById('sStu').value);
    if (!list.length) { toast(t('cls.noStudents')); return; }
    var guards = { l: '', r: '' };
    if (document.getElementById('sSide').checked) {
      guards.l = document.getElementById('sGuardL').value.trim();
      guards.r = document.getElementById('sGuardR').value.trim();
    }
    seatModel = { rows: rows, cols: cols, guards: guards, grid: buildSeatGrid(rows, cols, list) };
    if (list.length > rows * cols) toast(t('seats.errCount').replace('{n}', String(list.length)).replace('{m}', String(rows * cols)));
    renderSeatVisual(true);
    document.getElementById('sSaveBack').disabled = false;
    document.getElementById('sCopy').disabled = false;
  }

  function renderSeatVisual(resetSelection) {
    var m = seatModel;
    if (!m) return;
    if (resetSelection) m.selected = null;
    var body = '';
    for (var r = 0; r < m.rows; r++) {
      body += '<tr>';
      for (var c = 0; c < m.cols; c++) {
        var cell = m.grid[r][c];
        var sel = m.selected && m.selected.r === r && m.selected.c === c;
        var text = cell ? cell.name : '';
        body += '<td class="seat-cell' + (cell ? ' occupied' : '') + (sel ? ' selected' : '') + '" data-r="' + r + '" data-c="' + c + '" title="' + (cell && cell.height ? (t('cls.colHeight') + ' ' + (cell.height || '')) : '') + '">' + esc(text) + '</td>';
      }
      body += '</tr>';
    }
    var podium = '<div class="podium">' + esc(t('seats.podium')) + '</div>';
    if (m.guards.l || m.guards.r) {
      podium = '<div class="guards-row"><span class="guard-cell">' + esc(t('seats.leftGuard')) + '：' + esc(m.guards.l || '') + '</span>' +
        '<span class="podium">' + esc(t('seats.podium')) + '</span>' +
        '<span class="guard-cell">' + esc(t('seats.rightGuard')) + '：' + esc(m.guards.r || '') + '</span></div>';
    }
    var out = document.getElementById('seatOut');
    out.innerHTML = podium + '<table class="seat-table"><tbody>' + body + '</tbody></table>';
    out.querySelectorAll('.seat-cell').forEach(function (td) {
      td.addEventListener('click', function () {
        var r = Number(td.getAttribute('data-r')), c = Number(td.getAttribute('data-c'));
        if (!m.selected) {
          if (!m.grid[r][c]) return;
          m.selected = { r: r, c: c };
          renderSeatVisual(false);
        } else if (m.selected.r === r && m.selected.c === c) {
          m.selected = null;
          renderSeatVisual(false);
        } else {
          var a = m.selected, b = { r: r, c: c };
          var tmp = m.grid[a.r][a.c];
          m.grid[a.r][a.c] = m.grid[b.r][b.c];
          m.grid[b.r][b.c] = tmp;
          m.selected = null;
          renderSeatVisual(false);
          toast(t('toast.swapped'));
        }
      });
    });
  }

  function seatsToText() {
    var m = seatModel;
    if (!m) return '';
    var lines = [];
    if (m.guards.l) lines.push(t('seats.leftGuard') + '：' + m.guards.l + ' | ' + t('seats.rightGuard') + '：' + (m.guards.r || ''));
    m.grid.forEach(function (row) {
      lines.push(row.map(function (cell) { return cell ? cell.name : '-'; }).join('\t'));
    });
    return lines.join('\n');
  }
  function copySeats() {
    if (!seatModel) return;
    copyText(seatsToText(), t('web.seatsCopied'));
  }

  function saveSeatsToClass() {
    if (!seatModel) return;
    classPicker(t('seats.saveBack'), function (cls) {
      // 汇总当前座位名单（含护法位）
      var roster = [];
      seatModel.grid.forEach(function (row) {
        row.forEach(function (cell) { if (cell) roster.push(cell); });
      });
      if (seatModel.guards.l) roster.push({ name: seatModel.guards.l, height: '' });
      if (seatModel.guards.r) roster.push({ name: seatModel.guards.r, height: '' });
      // 按姓名合并：更新身高、补新、不删除旧、空学号补号
      var byName = {};
      cls.students.forEach(function (s) { byName[s.name] = s; });
      var maxNo = 0;
      cls.students.forEach(function (s) { var n = parseInt(s.no, 10) || 0; if (n > maxNo) maxNo = n; });
      roster.forEach(function (rc) {
        if (byName[rc.name]) {
          if (rc.height && !byName[rc.name].height) byName[rc.name].height = rc.height;
        } else {
          maxNo++;
          cls.students.push({ no: String(maxNo), name: rc.name, height: rc.height || '', note: '' });
          byName[rc.name] = cls.students[cls.students.length - 1];
        }
      });
      persistClasses();
      toast(t('toast.classSaved'));
    });
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
  /* 身高贪心蛇形 + 前排名次修正：矮生靠前（显示顶部），同排内按身高后位沉降；
   * 单元格为对象 {name, height}，以支持点击互换与身高 tooltip（与鸿蒙端一致） */
  function buildSeatGrid(rows, cols, list) {
    var sorted = list.slice().sort(function (a, b) {
      return (a.height || 0) - (b.height || 0);
    });
    var grid = [];
    for (var r = 0; r < rows; r++) {
      var emptyRow = [];
      for (var c = 0; c < cols; c++) emptyRow.push(null);
      grid.push(emptyRow);
    }
    var order = [];
    for (var y = 0; y < rows; y++) {
      var cur = [];
      for (var x = 0; x < cols; x++) cur.push([y, x]);
      if (y % 2 === 1) cur.reverse();   // 蛇形折返，保证 S 型走位
      order = order.concat(cur);
    }
    var n = sorted.length;
    for (var i = 0; i < order.length && i < n; i++) {
      var p = order[i];
      grid[p[0]][p[1]] = { name: sorted[i].name, height: sorted[i].height || '' };
    }
    // 前排修正：若某排两端坐的是异常高个，与后排同列矮生互换，避免遮黑板
    // （仅多行时执行，保持贪心骨架基本不动）
    if (rows > 1) frontRowCorrect(grid, rows, cols);
    return grid;
  }
  function frontRowCorrect(grid, rows, cols) {
    var frontRow = grid[0];
    var backRow = grid[rows - 1];
    for (var c = 0; c < cols; c++) {
      var f = frontRow[c], b = backRow[c];
      if (f && b && (f.height || 0) > 0 && (b.height || 0) > 0 && f.height > b.height) {
        // 前排个子高于最后一排同列：互换，保证前低后高
        frontRow[c] = b;
        backRow[c] = f;
      }
    }
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
    maybeShowDisclaimer();   // 首次启动免责声明（同意后本地记忆）
  }

  document.addEventListener('DOMContentLoaded', boot);
})();
