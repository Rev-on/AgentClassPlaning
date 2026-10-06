/* ============================================================
 * Rev TechingMaster Windows 版 · 生成结果通知核心
 *
 * 本文件是鸿蒙主工程通知行为的**逐条移植**，且刻意做成"纯逻辑、零依赖"：
 *   · 不 require('electron')、不访问 document / window / localStorage；
 *   · 唯一外部依赖是注入进来的 `world`（{ rtmNative }）与语言词典 getter。
 * 这样 Node 侧可以直接 require 它做回归测试（tools/test_notify_core.js），
 * 而不必启动 Electron，也不必伪造整个 DOM。
 *
 * 与鸿蒙源码的对应关系（源真值）：
 *   entry/src/main/ets/common/GenTask.ets
 *     · NOTIFY_IDS          plan=7101 courseware=7102 quiz=7103 research=7104
 *                           analysis=7105 talk=7106 report=7107
 *     · NOTIFY_ID_FALLBACK  7199
 *     · notifyIdFor(type)   未知功能取兜底值
 *     · notifyTexts(label)  title = notify.done.title
 *                           body  = notify.done.body.a + name + notify.done.body.b
 *                           fail  = notify.fail.title / body.a + name + body.b
 *     · name 为空时回退 card.history
 *   entry/src/main/ets/common/NotifySlot.ets
 *     · 通知渠道 desc = 'AI 生成完成提醒'（桌面版映射为 Electron 通知的 toast 文案）
 *     · LEVEL_HIGH = 响铃 + 横幅（桌面版映射为 Windows 通知中心横幅，无法逐条指定级别）
 *   entry/src/main/ets/entryability/EntryAbility.ets
 *     · 通知权限 + 渠道是增强项，任何失败都静默，绝不影响应用启动
 *   entry/src/main/ets/common/I18n.ets
 *     · notify.runningTitle / notify.runningText / notify.doneTitle /
 *       notify.doneBody / notify.failTitle / notify.failBody（{type} 占位符）
 * ============================================================ */
(function (root, factory) {
  'use strict';
  var api = factory();
  if (typeof module === 'object' && module && module.exports) {
    module.exports = api;          // Node（测试）
  } else {
    root.RTMNotify = api;          // renderer（<script>）
  }
})(typeof globalThis !== 'undefined' ? globalThis : this, function () {
  'use strict';

  /* ------------------------------------------------------------
   * 1) 逐功能固定通知 ID —— 与 GenTask.ets 的 NOTIFY_IDS 完全一致
   *
   * 为什么要固定 ID：
   *   鸿蒙侧按 notifyId 归并通知；若每次生成都用新 id，用户连生成 3 次教案
   *   就会在通知栏堆 3 条"教案已生成完成"。
   * Windows 的 toast 本身**不能**按数字 id 寻址，因此 Electron 侧用
   *   "功能 key → 当前存活的 Notification 实例"
   * 表来实现同一语义：同一功能发新通知前先 close() 掉旧的那条，
   * 效果等价于鸿蒙的"新通知覆盖旧通知，永远只占一条"。
   * ------------------------------------------------------------ */
  var NOTIFY_IDS = {
    plan: 7101,
    courseware: 7102,
    quiz: 7103,
    research: 7104,
    analysis: 7105,
    talk: 7106,
    report: 7107
  };
  /** 未知功能的兜底通知 ID（不与 7 个已知功能冲突） */
  var NOTIFY_ID_FALLBACK = 7199;
  /** 与鸿蒙 NotifySlot.ets 的渠道 desc 对齐的桌面提示语 */
  var CHANNEL_DESC = 'AI 生成完成提醒';

  /** 取某功能的通知 ID；未知功能返回兜底值（等价 GenTask.notifyIdFor） */
  function notifyIdFor(type) {
    var id = Object.prototype.hasOwnProperty.call(NOTIFY_IDS, type) ? NOTIFY_IDS[type] : undefined;
    return id === undefined ? NOTIFY_ID_FALLBACK : id;
  }
  /** 稳定的"归并槽位"key：已知功能用功能 id，未知功能共用 fallback 槽位 */
  function notifyKeyFor(type) {
    return 'id:' + notifyIdFor(type);
  }

  /* ------------------------------------------------------------
   * 2) 生成任务类型推断 —— 与鸿蒙"每个生成功能一个 type"对齐
   * ------------------------------------------------------------ */
  var TYPE_ALIASES = {
    plan: 'plan', jiaoan: 'plan', lesson: 'plan', lessonplan: 'plan',
    courseware: 'courseware', ppt: 'courseware', kejian: 'courseware',
    quiz: 'quiz', exercise: 'quiz', lianxi: 'quiz',
    research: 'research', yanjiu: 'research',
    analysis: 'analysis', xueqing: 'analysis',
    talk: 'talk', huashu: 'talk', speech: 'talk',
    report: 'report', baogao: 'report'
  };
  /** 兜底 type：让无法识别的功能仍共享同一个通知槽位（不堆叠） */
  var TYPE_FALLBACK = 'other';

  /** 从 page key / 卡片 id / 标签推断通知用的功能 type */
  function typeFor(key, label) {
    var k = String(key == null ? '' : key).toLowerCase().replace(/[^a-z]/g, '');
    if (k && TYPE_ALIASES[k]) return TYPE_ALIASES[k];
    var lb = String(label == null ? '' : label).toLowerCase();
    if (/\u6559\u6848|lesson\s*plan/.test(lb)) return 'plan';
    if (/\u8bfe\u4ef6|slide|courseware|ppt/.test(lb)) return 'courseware';
    if (/\u7ec3\u4e60|quiz|exercise/.test(lb)) return 'quiz';
    if (/\u6559\u7814|\u79d1\s*\u7814|research/.test(lb)) return 'research';
    if (/\u5b66\u60c5|analysis/.test(lb)) return 'analysis';
    if (/\u8bdd\u672f|\u6c9f\u901a|talk/.test(lb)) return 'talk';
    if (/\u62a5\u544a|report/.test(lb)) return 'report';
    return TYPE_FALLBACK;
  }

  /* ------------------------------------------------------------
   * 3) 通知文案拼装
   *
   * 语言查表的两条路径（本功能最容易出错的地方，务必理解）：
   *
   *  A. 词典提供**点号键**（zh / en）：走鸿蒙 GenTask.notifyTexts 的三段式
   *       title = notify.done.title
   *       body  = notify.done.body.a + 功能名 + notify.done.body.b
   *     中文即 '「' + 教案生成 + '」已生成完成，点击查看'，与鸿蒙端逐字一致。
   *
   *  B. 词典只有 **camelCase 家族**（ug / bo / mn 三种语言就是这种情况）：
   *     这些语言没有点号键，但有自己的 notify.doneTitle / notify.doneBody
   *     （自带 {type} 占位符，是一句语序完整的本族语句子）。
   *     此时若硬走 A 路径，会退化成"中文括号前缀 + 本族语功能名 + 中文后缀"的
   *     缝合怪（如 '「دەرس پىلانى قۇرۇش」已生成完成'），既不是中文也不是本族语。
   *     因此 B 路径优先使用本族语的完整句式，把 {type} 换成功能名。
   *
   * ⚠️ 关键实现约束：查表必须**先看本语言**。renderer 的 t() 在缺键时会回退
   * 英文/中文，若直接拿 t() 的结果判断"本语言有没有 camelCase 键"，就会得到
   * 英文值，于是 ug/bo/mn 永远走不到自己的 B 路径（这正是回归测试抓到的缺陷）。
   * 因此这里用 makeLookup()：传入"本语言字典的精确查询"，命中即用本族语，
   * 未命中才回退到 renderer 的 t()。
   * ------------------------------------------------------------ */

  /** 缺失键的原样返回：t() 的实现约定 */
  function rawLookup(dict, key) {
    return (dict && Object.prototype.hasOwnProperty.call(dict, key)) ? dict[key] : undefined;
  }

  /**
   * 构造"本语言优先"的查表函数。
   * @param {object} langDict 当前语言的精确词典（可缺省）
   * @param {function(string):string} t renderer 的 t()（跨语言回退链）
   */
  function makeLookup(langDict, t) {
    return function lookup(key) {
      var own = rawLookup(langDict, key);
      if (typeof own === 'string' && own !== '') return own;
      var v;
      try { v = t(key); } catch (e) { v = undefined; }
      if (typeof v === 'string' && v !== '' && v !== key) return v;
      if (Object.prototype.hasOwnProperty.call(BUILTIN_FALLBACK, key)) return BUILTIN_FALLBACK[key];
      return key;
    };
  }

  /**
   * 组装「完成 / 失败 / 生成中」三组通知文案。
   *
   * 优先级：本语言点号键 → 本语言 camelCase 完整句式 → 跨语言点号键 →
   *         跨语言 camelCase → 内置中文常量。
   * 任何路径都不会把裸 key 名（如 'notify.done.title'）显示给用户。
   *
   * @param {function(string):string} lookup makeLookup() 产出的查表函数
   * @param {string} label 功能名（已是当前语言的标题，如“教案生成”）
   * @param {function(string):boolean} [hasOwn] 判断某键是否属于**本语言**词典
   */
  function buildTexts(lookup, label, hasOwn) {
    var name = String(label == null ? '' : label).trim();
    if (name === '') name = lookup('card.history');

    // 无 hasOwn（Node 测试/直接调用）时退化为"值不同于 key 即视为存在"。
    var own = typeof hasOwn === 'function' ? hasOwn : function (key) {
      var v = lookup(key);
      return typeof v === 'string' && v !== '' && v !== key;
    };

    var dottedDone = own('notify.done.title') && own('notify.done.body.b');
    var dottedFail = own('notify.fail.title') && own('notify.fail.body.b');

    var doneTitle, doneBody, failTitle, failBody;

    if (dottedDone) {
      // A 路径：点号键三段式（zh / en）——与鸿蒙 GenTask.notifyTexts 逐字一致
      doneTitle = lookup('notify.done.title');
      doneBody = lookup('notify.done.body.a') + name + lookup('notify.done.body.b');
    } else if (own('notify.doneTitle') && own('notify.doneBody')) {
      // B 路径：本族语完整句式 + {type} 填充（ug / bo / mn）
      doneTitle = fillType(lookup('notify.doneTitle'), name);
      doneBody = fillType(lookup('notify.doneBody'), name);
    } else if (lookup('notify.doneTitle') !== 'notify.doneTitle') {
      // 跨语言回退：本语言两套键都缺，但回退链能给出一句完整句式
      doneTitle = fillType(lookup('notify.doneTitle'), name);
      doneBody = fillType(lookup('notify.doneBody'), name);
    } else {
      // 全缺：内置中文常量（仍不显示裸 key）
      doneTitle = BUILTIN_FALLBACK['notify.done.title'];
      doneBody = BUILTIN_FALLBACK['notify.done.body.a'] + name + BUILTIN_FALLBACK['notify.done.body.b'];
    }

    if (dottedFail) {
      failTitle = lookup('notify.fail.title');
      failBody = lookup('notify.fail.body.a') + name + lookup('notify.fail.body.b');
    } else if (own('notify.failTitle') && own('notify.failBody')) {
      failTitle = fillType(lookup('notify.failTitle'), name);
      failBody = fillType(lookup('notify.failBody'), name);
    } else if (lookup('notify.failTitle') !== 'notify.failTitle') {
      failTitle = fillType(lookup('notify.failTitle'), name);
      failBody = fillType(lookup('notify.failBody'), name);
    } else {
      failTitle = BUILTIN_FALLBACK['notify.fail.title'];
      failBody = BUILTIN_FALLBACK['notify.fail.body.a'] + name + BUILTIN_FALLBACK['notify.fail.body.b'];
    }

    // 生成中：五种语言都提供 camelCase 家族，缺则用内置中文常量
    var runningTitle = lookup('notify.runningTitle') !== 'notify.runningTitle'
      ? fillType(lookup('notify.runningTitle'), name)
      : fillType(BUILTIN_FALLBACK['notify.runningTitle'], name);
    var runningText = lookup('notify.runningText') !== 'notify.runningText'
      ? lookup('notify.runningText')
      : BUILTIN_FALLBACK['notify.runningText'];

    return {
      doneTitle: doneTitle,
      doneBody: doneBody,
      failTitle: failTitle,
      failBody: failBody,
      runningTitle: runningTitle,
      runningText: runningText
    };
  }

  // 词典查表兜底链：当前语言 → 英文 → 中文 → 内置最小词典 → key 本身。
  // 与 renderer 的 t() 行为一致，但即使某个键在所有词典里都缺失，
  // 通知也仍然能显示可读文本（绝不显示裸 key，也绝不抛错）。
  var BUILTIN_FALLBACK = {
    'notify.done.title': '\u751f\u6210\u5b8c\u6210',
    'notify.done.body.a': '\u300c',
    'notify.done.body.b': '\u300d\u5df2\u751f\u6210\u5b8c\u6210\uff0c\u70b9\u51fb\u67e5\u770b',
    'notify.fail.title': '\u751f\u6210\u5931\u8d25',
    'notify.fail.body.a': '\u300c',
    'notify.fail.body.b': '\u300d\u751f\u6210\u5931\u8d25\uff0c\u70b9\u51fb\u91cd\u8bd5',
    'notify.runningTitle': '{type}\u751f\u6210\u4e2d',
    'notify.runningText': '\u6b63\u5728\u540e\u53f0\u4e3a\u60a8\u751f\u6210\uff0c\u5b8c\u6210\u540e\u5c06\u6536\u5230\u901a\u77e5',
    'card.history': '\u5386\u53f2\u8bb0\u5f55'
  };

  /** 把词典里的 {type} 占位符替换为当前语言的显示名 */
  function fillType(tpl, label) {
    return String(tpl == null ? '' : tpl).replace(/\{type\}/g, label);
  }

  /**
   * 兼容旧签名：构造一个"永不返回裸 key"的查表函数。
   *
   * 注意：它只包住 renderer 的 t()，**无法**感知"本语言是否拥有某个键"，
   * 因此当 t() 带有跨语言回退链时，ug/bo/mn 会被误判为拥有英文点号键。
   * 新代码请使用 makeLookup(langDict, t)，它保证本语言优先。
   *
   * @param {function(string):string} t renderer 的 t(key)
   * @param {string} lang 当前语言代码（仅用于日志/自检）
   */
  function makeSafeT(t, lang) {
    void lang;
    return makeLookup(null, t);
  }

  /* ------------------------------------------------------------
   * 4) 发送器：把 payload 交给 main 进程（preload 暴露的 rtmNative.notify）
   *
   * 容错策略完全对齐鸿蒙 EntryAbility / NotifySlot：
   *   通知是**增强项**，任何失败只记录日志，绝不抛出、绝不打断生成流程。
   *   · 不在 Electron 里（直接在浏览器打开 index.html）→ 静默跳过；
   *   · 用户不允许通知 → 不弹（返回 {skipped:'disabled'}）；
   *   · main 侧抛错 → 捕获后返回 {ok:false}。
   * ------------------------------------------------------------ */
  function createNotifier(world, log) {
    var w = world || {};
    var warn = typeof log === 'function' ? log : function () {};
    var state = { lastAt: 0, lastKey: '', lastId: 0, sent: 0, failures: 0, lastResult: null };

    function bridge() {
      return w.rtmNative && typeof w.rtmNative.notify === 'function' ? w.rtmNative : null;
    }

    /**
     * @param {{kind:string, featureKey:string, featureId?:number, title:string,
     *          body:string, tag?:string}} payload
     */
    function send(payload) {
      var p = payload || {};
      var b = bridge();
      if (!b) {
        state.lastResult = { ok: false, skipped: 'no-bridge' };
        return Promise.resolve(state.lastResult);
      }
      var featureKey = String(p.featureKey || 'unknown');
      var msg = {
        kind: String(p.kind || 'done'),
        featureKey: featureKey,
        featureId: typeof p.featureId === 'number' ? p.featureId : notifyIdFor(featureKey),
        title: String(p.title == null ? '' : p.title),
        body: String(p.body == null ? '' : p.body),
        tag: String(p.tag == null ? '' : p.tag),
        channelDesc: CHANNEL_DESC
      };
      state.lastAt = Date.now();
      state.lastKey = featureKey;
      state.lastId = msg.featureId;
      return Promise.resolve()
        .then(function () { return b.notify(msg); })
        .then(function (res) {
          if (res && res.ok === false && res.skipped === 'disabled') {
            state.lastResult = res;
            return res;
          }
          state.sent++;
          state.lastResult = res && typeof res === 'object' ? res : { ok: true };
          return state.lastResult;
        })
        .catch(function (e) {
          state.failures++;
          state.lastResult = { ok: false, error: e && e.message ? e.message : String(e) };
          warn('[notify] \u53d1\u9001\u5931\u8d25\uff08\u5df2\u5ffd\u7565\uff0c\u4e0d\u5f71\u54cd\u751f\u6210\uff09: ' + state.lastResult.error);
          return state.lastResult;
        });
    }

    return { send: send, state: state, bridge: bridge };
  }

  /* ------------------------------------------------------------
   * 5) 通知中心：把"何时发、发什么"收在一处，供 app.js 直接调用
   *
   * 关键语义 —— 固定槽位替换：
   *   同一 featureKey/ID 的新通知，main 进程会先 close() 上一条同槽位的
   *   通知再 show()，因此重复生成同一功能**不会堆叠**。
   * ------------------------------------------------------------ */
  function createCenter(opts) {
    var o = opts || {};
    var t = o.t || function (k) { return k; };
    var notifier = createNotifier(o.world, o.log);

    /**
     * ⚠️ 未传 dict 时的显式告警（只提醒一次）。
     *
     * 为什么必须提醒：dict 在签名上是可选的，但**漏传会导致静默的文案降级** ——
     * hasOwn 失去"本语言精确词典"后，ug/bo/mn 会误判为"本语言有点号键"，
     * 于是走跨语言回退分支，渲染出"中文括号 + 本族语功能名 + 中文后缀"的缝合怪，
     * 而不是本族语的完整句式。这个缺陷不会抛异常、不会显示裸 key，
     * 肉眼审查时极难发现（本项目就真的踩过一次）。
     * 因此这里不改成必填（避免破坏既有调用），但把静默降级变成**可见告警**。
     */
    if (!o.dict && !createCenter._warned) {
      createCenter._warned = true;
      try {
        var w = (o.log && typeof o.log.warn === 'function') ? o.log.warn
          : (typeof console !== 'undefined' && console.warn ? function (m) { console.warn(m); } : null);
        if (w) {
          w('[notify] createCenter 未传 dict：ug/bo/mn 将退化为跨语言回退文案（可能中英混排）。'
            + '请传入当前语言的精确词典，例如 createCenter({t: t, dict: I18N_DATA[lang]})');
        }
      } catch (e) { /* 告警本身绝不能影响通知 */ }
    }

    /**
     * 当前语言的**精确**词典（可为 getter，语言切换后自动取到新值）。
     * 有了它，buildTexts 才能区分"本语言真的没有点号键"与"只是回退到了英文"。
     */
    function langDict() {
      try {
        return typeof o.dict === 'function' ? o.dict() : (o.dict || null);
      } catch (e) {
        return null;
      }
    }

    /** 组装文案时统一走此入口：本语言优先 + 跨语言回退 + 内置常量 */
    function textsFor(label) {
      var d = langDict();
      var lookup = makeLookup(d, t);
      var hasOwn = function (key) {
        return typeof rawLookup(d, key) === 'string' && rawLookup(d, key) !== '';
      };
      return buildTexts(lookup, label, hasOwn);
    }

    /**
     * 完成/失败通知。
     * @param {string} key 功能 id（'plan' | 'courseware' | ... 或任意页 key）
     * @param {string} label 当前语言的显示名（= t(labelKey)）
     * @param {'done'|'fail'} kind
     * @param {string} tag 附加信息（失败原因等），拼在正文末尾
     */
    function feature(key, label, kind, tag) {
      var type = typeFor(key, label);
      var tx = textsFor(label);
      var done = kind !== 'fail';
      var body = done ? tx.doneBody : tx.failBody;
      var extra = String(tag == null ? '' : tag).trim();
      if (extra) body = body + ' ' + extra;
      return notifier.send({
        kind: done ? 'done' : 'fail',
        featureKey: type,
        featureId: notifyIdFor(type),
        title: done ? tx.doneTitle : tx.failTitle,
        body: body,
        tag: type + ':' + (done ? 'done' : 'fail')
      });
    }

    /**
     * "生成中"通知：仅在窗口不可见（最小化 / 隐藏）时发送，
     * 避免打扰正在看界面的用户 —— 对应鸿蒙 notify.runningTitle/runningText。
     * 该通知**不**进历史、也**不**做完成态归并（完成时会被同槽位替换）。
     */
    function running(key, label) {
      var type = typeFor(key, label);
      var tx = textsFor(label);
      return notifier.send({
        kind: 'running',
        featureKey: type,
        featureId: notifyIdFor(type),
        title: tx.runningTitle,
        body: tx.runningText,
        tag: type + ':running'
      });
    }

    return {
      feature: feature,
      running: running,
      notifyIdFor: notifyIdFor,
      notifyKeyFor: notifyKeyFor,
      typeFor: typeFor,
      buildTexts: textsFor,
      state: notifier.state,
      hasBridge: function () { return !!notifier.bridge(); }
    };
  }

  return {
    NOTIFY_IDS: NOTIFY_IDS,
    NOTIFY_ID_FALLBACK: NOTIFY_ID_FALLBACK,
    CHANNEL_DESC: CHANNEL_DESC,
    TYPE_FALLBACK: TYPE_FALLBACK,
    notifyIdFor: notifyIdFor,
    notifyKeyFor: notifyKeyFor,
    typeFor: typeFor,
    buildTexts: buildTexts,
    makeLookup: makeLookup,
    makeSafeT: makeSafeT,
    createNotifier: createNotifier,
    createCenter: createCenter
  };
});
