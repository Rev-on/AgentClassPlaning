/**
 * 实况窗**后台续更**回归测试（Live View background continuation）。
 *
 * 【为什么需要这个测试】
 *   用户核心诉求：7 大 AI 生成功能生成中，把应用退出到后台，桌面实况窗必须
 *   **继续实时显示进度**。
 *   而本仓库曾存在的实现（v1）是纯"进程内回调驱动"的：
 *       页面 onDelta → LiveView.onContent → GenProgress.onLength → updateLiveView
 *   应用退到后台被挂起后回调不再触发 ⇒ 进度**永久冻结**。
 *   本测试锁死修复后的关键不变量，防止任何一次"看起来更简洁"的重构把它改回去。
 *
 * 【覆盖的 4 组不变量】
 *   A. 进度模型是"时间驱动"的（GenProgress）
 *      —— 不靠回调，只靠流逝时间就能推进；跨长时段按时间补齐；封顶 95 不做假完成。
 *   B. 后台接缝存在且语义正确（EntryAbility + LiveView）
 *      —— onBackground 会启用后台续更，且**不会**结束实况窗；
 *         onForeground 会补齐并释放短时任务。
 *   C. 独立进度驱动（看门狗）与页面解耦
 *      —— 定时器 / pump / 时间滑轨存在，且结束后被清理（不泄漏）。
 *   D. 后台短时任务合规
 *      —— 用无需权限的 requestSuspendDelay；不引入 KEEP_BACKGROUND_RUNNING
 *         受限权限、不注册长时任务。
 *
 * 【运行】cd server; node tools/test_liveview_background.js
 */
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const CLIENT_LV = path.join(ROOT, 'entry/src/main/ets/common/LiveView.ets');
const CLIENT_GP = path.join(ROOT, 'entry/src/main/ets/common/GenProgress.ets');
const CLIENT_AB = path.join(ROOT, 'entry/src/main/ets/entryability/EntryAbility.ets');
const MODULE_JSON = path.join(ROOT, 'entry/src/main/module.json5');

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

/** 断言某段源码里"不出现"某个模式（反向断言同样计入用例数） */
function checkNot(name, src, re, detail) {
  check(name, !re.test(src), detail);
}

function read(p) {
  return fs.readFileSync(p, 'utf8');
}

/* =========================================================================
 * 0. 先"真跑一遍"进度模型 —— 不只做文本断言
 * =========================================================================
 * GenProgress.ets 是纯 TypeScript（无 ArkUI / 无系统 API 依赖），
 * 这里把它的类体抽出来直接喂给 new Function，做**行为级**验证：
 * 这比正则断言强得多，能真正证明"时间到了，进度就会涨"。
 */
/**
 * 把 ArkTS 子集源码降级为可直接被 new Function 求值的 JS。
 *
 * 只处理本文件需要的那一小块语法（类型注解、访问修饰符、非空断言），
 * 刻意保持"笨拙但可预期"：任何未覆盖的语法都会在求值时报错，
 * 从而让测试**失败**而不是悄悄跳过。
 */
function arktsToJs(src) {
  let s = src;
  // 去掉块注释与行注释（避免注释里的类型写法干扰）
  s = s.replace(/\/\*[\s\S]*?\*\//g, '');
  s = s.replace(/(^|[^:])\/\/.*$/gm, '$1');
  // 函数返回值类型：  ): number {   ->   ) {
  s = s.replace(/\)\s*:\s*[A-Za-z_$][\w$.<>\[\]|,\s]*(?==>|\{)/g, ') ');
  // 局部/字段联合类型注解：  const e: number | undefined =   ->   const e =
  s = s.replace(/([\w$]+)\s*:\s*[A-Za-z_$][\w$.<>\[\]]*(?:\s*\|\s*(?:[A-Za-z_$][\w$.<>\[\]]*|undefined|null))*\s*(?==)/g, '$1 ');
  // 变量/字段类型注解：  x: number =   ->   x =
  s = s.replace(/([\w$]+)\s*:\s*(?:number|string|boolean|void|Object)\s*(?=[=;,)\]])/g, '$1 ');
  // 形参类型注解（含可选标记）：  (a: number, b?: string)  ->  (a, b)
  s = s.replace(/([,(]\s*[\w$]+)\s*\??\s*:\s*[A-Za-z_$][\w$.<>\[\]|\s]*/g, '$1');
  // 剩余的可选参数标记：  (a?)  ->  (a)
  s = s.replace(/([,(]\s*[\w$]+)\s*\?/g, '$1');
  // 访问修饰符 / readonly
  s = s.replace(/\b(private|public|protected|readonly)\s+/g, '');
  // 非空断言
  s = s.replace(/!\./g, '.');
  // export 关键字（类/常量在求值环境里不需要）
  s = s.replace(/\bexport\s+/g, '');
  return s;
}

/**
 * 从 GenProgress.ets 载入 GenProgress 类。
 * 先抽出模块级常量，再把类体（去掉 export）连同常量一起求值。
 */
function loadGenProgressClass() {
  const src = read(CLIENT_GP);
  const start = src.indexOf('export class GenProgress');
  if (start < 0) {
    return null;
  }
  const body = arktsToJs(src.slice(start)).replace('class GenProgress', 'class GenProgress');
  const consts = {};
  const constRe = /^const\s+([A-Z_0-9]+)\s*(?::[^=]+)?=\s*([\s\S]*?);\s*$/gm;
  let m;
  while ((m = constRe.exec(src)) !== null) {
    try {
      consts[m[1]] = new Function('return (' + m[2] + ')')();
    } catch (e) {
      /* 非字面量常量：忽略，由下面的缺失检测兜住 */
    }
  }
  const names = Object.keys(consts);
  const values = names.map((n) => consts[n]);
  const factory = new Function(...names, body + '\nreturn GenProgress;');
  return factory(...values);
}

const GenProgress = loadGenProgressClass();
check('能从 GenProgress.ets 中实例化 GenProgress（纯 TS，可行为验证）',
  typeof GenProgress === 'function');
if (typeof GenProgress === 'function') {
  /* ---- A1. 零回调也会随时间推进（这就是"后台不再冻结"的模型基础） ---- */
  const t0 = Date.now();
  const p = new GenProgress('plan', t0);
  const v0 = p.current();
  // 模拟"已流逝 40 秒"：把内部起始时间前移，等价于进程被挂起 40s 后重新调度
  const p40 = new GenProgress('plan', t0 - 40000);
  const v40 = p40.current();
  const p120 = new GenProgress('plan', t0 - 120000);
  const v120 = p120.current();

  check('未收到任何回调时，进度起始值 > 0（提交即显示"在跑"）', v0 > 0, 'v0=' + v0);
  check('零回调 + 40s 流逝 → 进度明显推进（后台补齐的关键）',
    v40 >= v0 + 20, 'v0=' + v0 + ' v40=' + v40);
  check('零回调 + 120s 流逝 → 进度继续推进且单调',
    v120 > v40, 'v40=' + v40 + ' v120=' + v120);
  check('时间滑轨单调不减', v0 <= v40 && v40 <= v120, [v0, v40, v120].join(' < '));

  /* ---- A2. 运行期永不到 100（不做假完成） ---- */
  const pInf = new GenProgress('plan', t0 - 24 * 3600 * 1000);
  check('运行 24h（极端）仍 < 100%，绝不假完成', pInf.current() < 100, 'v=' + pInf.current());
  check('运行期封顶为 95%', pInf.current() <= 95, 'v=' + pInf.current());

  /* ---- A3. 只有 onDone 才能到 100 ---- */
  pInf.onDone();
  check('onDone() 后置 100%', pInf.current() === 100, 'v=' + pInf.current());

  /* ---- A4. 回调锚点仍然有效（前台路径不退化） ---- */
  const pCb = new GenProgress('quiz', t0);
  const before = pCb.current();
  pCb.onLength(1500); // quiz 预期 3000 字符 → 正文过半
  const after = pCb.current();
  check('收到正文增量后进度被抬高（前台回调路径保留）', after > before,
    before + ' -> ' + after);
  const afterThink = (() => {
    const q = new GenProgress('quiz', t0);
    q.onThinking();
    return q.current();
  })();
  check('思考增量能抬高基准进度', afterThink >= 12, 'v=' + afterThink);

  /* ---- A5. 幂等：同一时刻重复读取不改变结果 ---- */
  const pIdem = new GenProgress('talk', t0 - 30000);
  const a1 = pIdem.current();
  const a2 = pIdem.current();
  check('同一时刻重复调用 current() 结果稳定（幂等）', a1 === a2, a1 + ' vs ' + a2);

  /* ---- A6. 回调锚点高时不会被时间滑轨拉低 ---- */
  const pMix = new GenProgress('plan', t0);
  pMix.onLength(4000); // 预期 4000 → 锚点接近 95
  const high = pMix.current();
  const stillHigh = (() => {
    const q = new GenProgress('plan', t0 - 1000);
    q.onLength(4000);
    return q.current();
  })();
  check('回调锚点 > 时间滑轨时取 max（进度不回退）',
    stillHigh === high, high + ' vs ' + stillHigh);
}

/* =========================================================================
 * 1. 源码契约：GenProgress 必须是"时间驱动"的
 * ========================================================================= */
const gp = read(CLIENT_GP);
check('GenProgress 构造函数接受 startTime（与实况窗创建同源）',
  /constructor\s*\(\s*kind\s*:\s*string\s*,\s*startTime\s*\?\s*:\s*number\s*\)/.test(gp));
check('GenProgress 记录 startTime 字段', /private\s+startTime\s*:\s*number/.test(gp));
check('GenProgress 存在时间滑轨函数 ramp()', /private\s+ramp\s*\(\s*elapsedMs\s*:\s*number\s*\)/.test(gp));
check('ramp 使用 Date.now() 计算已流逝时间（跨挂起仍准确）',
  /Date\.now\(\)\s*-\s*this\.startTime/.test(gp));
check('current() = max(阶段锚点, 时间滑轨) 的取大语义',
  /anchor\s*>\s*rampV\s*\?\s*anchor\s*:\s*rampV/.test(gp));
check('current() 保证单调不减', /if\s*\(v\s*>\s*this\.last\)\s*\{\s*this\.last\s*=\s*v/.test(gp));
check('有每小时级别的硬下限兜底（SLA floor）', /SLA_FLOOR_MS/.test(gp) && /SLA_FLOOR_PCT/.test(gp));
check('渐近上限 <95，避免时间外推冲到运行期封顶',
  /RAMP_ASYMPTOTE\s*:\s*number\s*=\s*8\d/.test(gp));

/* =========================================================================
 * 2. LiveView：独立进度驱动（看门狗）+ 时间补齐
 * ========================================================================= */
const lv = read(CLIENT_LV);

check('LiveView 启动与页面解耦的进度看门狗', /private\s+static\s+startWatchdog\s*\(/.test(lv));
check('看门狗定时器在 start 成功路径上被拉起', /LiveView\.startWatchdog\('start'\)/.test(lv));
check('看门狗按固定节拍运行', /setInterval\(/.test(lv) && /TICK_MS\s*:\s*number\s*=\s*\d+/.test(lv));
check('看门狗每拍推进进度（pump → push）', /LiveView\.pump\(\)/.test(lv));
check('结束时清理定时器（不泄漏）', /clearInterval\(LiveView\.tick\)/.test(lv));
check('有运行上限保护，异常路径下定时器不会永生', /MAX_TICK_MS/.test(lv));

check('后台无回调时按时间外推（isTimeDriven → push(estimated)）',
  /LiveView\.isTimeDriven\(\)/.test(lv) && /push\s*\(fromTime\)/.test(lv));
check('时间外推用"约 N%"文案，不把估算值说成真实值',
  /'约 '/.test(lv));

check('后台会用服务端权威任务态校准进度', /fetchAuthoritative/.test(lv));
check('服务端权威校准走 GenTask.apiUrl（与其它接口同源）',
  /GenTask\.apiUrl\('\/task\/' \+ id\)/.test(lv));
check('权威校准有独立短超时（不吃掉短时任务额度）',
  /FETCH_TIMEOUT_MS\s*:\s*number\s*=\s*\d+/.test(lv));
check('服务端已 done 时后台主动收尾实况窗',
  /t\.status\s*===\s*'done'[\s\S]{0,200}LiveView\.done\(\)/.test(lv));
check('服务端已 failed 时后台主动收尾实况窗',
  /t\.status\s*===\s*'failed'[\s\S]{0,200}LiveView\.stop\(\)/.test(lv));

check('LiveView 提供 attach(ctx) 注入 UIAbilityContext',
  /static\s+attach\s*\(\s*ctx\s*:\s*common\.UIAbilityContext\s*\)\s*:\s*void/.test(lv));
check('LiveView 提供 onBackground/onForeground 接缝',
  /static\s+onBackground\s*\(\s*\)\s*:\s*void/.test(lv)
  && /static\s+onForeground\s*\(\s*\)\s*:\s*void/.test(lv));
check('onForeground 立刻补齐一次进度（不等下一个节拍）',
  /onForeground[\s\S]{0,600}LiveView\.push\(false\)/.test(lv));

/* ---- 关键否定断言：后台动作绝不结束实况窗 ---- */
const bgBody = lv.match(/static\s+onBackground\s*\(\s*\)\s*:\s*void\s*\{([\s\S]*?)\n  \}/);
check('能定位 onBackground 函数体', bgBody !== null);
if (bgBody) {
  checkNot('onBackground 内不得调用 stop()/done()（退出后台 ≠ 生成结束）',
    bgBody[1], /LiveView\.(stop|done)\s*\(|stopLiveView|stopLiveViewByTrigger/);
  check('onBackground 内会争取后台短时任务',
    /ensureSuspend\s*\(/.test(bgBody[1]));
  check('onBackground 内会兜底启动看门狗',
    /startWatchdog\s*\(/.test(bgBody[1]));
}

/* =========================================================================
 * 3. 后台短时任务（transient task）合规性
 * ========================================================================= */
check('使用 requestSuspendDelay 申请短时任务',
  /backgroundTaskManager\.requestSuspendDelay\s*\(/.test(lv));
check('从 @kit.BackgroundTasksKit 引入 backgroundTaskManager（非直接 @ohos 路径）',
  /import\s*\{\s*backgroundTaskManager\s*\}\s*from\s*'@kit\.BackgroundTasksKit'/.test(lv));
check('到期回调里重置持有状态（避免用失效 requestId 续期）',
  /requestSuspendDelay\(reason,\s*\(\)\s*:\s*void\s*=>\s*\{[\s\S]{0,400}suspendId\s*=\s*-1/.test(lv));
check('短时任务额度将尽时续期', /RENEW_BELOW_MS/.test(lv));
check('续期申请有节流（防回调风暴打爆配额）', /lastExpireLog/.test(lv));
check('结束时取消短时任务（归还每日配额）',
  /backgroundTaskManager\.cancelSuspendDelay\s*\(/.test(lv));
check('短时任务申请失败静默降级（9900001/9900002）',
  /catch\s*\(e\)[\s\S]{0,300}申请后台短时任务失败[\s\S]{0,200}静默降级/.test(lv));

/* ---- 合规红线：不得引入受限权限 / 长时任务 ---- */
checkNot('未调用 startBackgroundRunning（长时任务需受限权限）',
  lv, /backgroundTaskManager\.startBackgroundRunning/);
checkNot('未调用 stopBackgroundRunning', lv, /backgroundTaskManager\.stopBackgroundRunning/);

/* =========================================================================
 * 4. 生命周期接缝真的被接上了（EntryAbility）
 * ========================================================================= */
const ab = read(CLIENT_AB);
check('EntryAbility 引入 LiveView', /import\s*\{\s*LiveView\s*\}\s*from\s*'\.\.\/common\/LiveView'/.test(ab));
check('EntryAbility.onCreate 注入 context（LiveView.attach）',
  /LiveView\.attach\(\s*this\.context\s*\)/.test(ab));

const abBg = ab.match(/onBackground\s*\(\s*\)\s*:\s*void\s*\{([\s\S]*?)\n  \}/);
check('能定位 EntryAbility.onBackground', abBg !== null);
if (abBg) {
  check('onBackground 调用 LiveView.onBackground()（启用后台续更）',
    /LiveView\.onBackground\s*\(/.test(abBg[1]));
  checkNot('onBackground 不得结束实况窗', abBg[1], /LiveView\.(stop|done)\s*\(/);
}

const abFg = ab.match(/onForeground\s*\(\s*\)\s*:\s*void\s*\{([\s\S]*?)\n  \}/);
check('能定位 EntryAbility.onForeground', abFg !== null);
if (abFg) {
  check('onForeground 调用 LiveView.onForeground()（补齐 + 恢复页面同步）',
    /LiveView\.onForeground\s*\(/.test(abFg[1]));
}

/* =========================================================================
 * 5. module.json5 合规：不得新增 KEEP_BACKGROUND_RUNNING
 * ========================================================================= */
const mj = read(MODULE_JSON);
checkNot('module.json5 未声明 KEEP_BACKGROUND_RUNNING（受限权限，本方案不需要）',
  mj, /KEEP_BACKGROUND_RUNNING/);
checkNot('module.json5 未声明 backgroundModes（长时任务专用）',
  mj, /"backgroundModes"/);

/* =========================================================================
 * 6. 独立进度驱动必须与页面解耦（不受 7 个页面调用契约影响）
 * ========================================================================= */
check('LiveView 不 import 任何页面（驱动层与 UI 解耦）',
  !/from\s*'\.\.\/pages\//.test(lv));
check('LiveView 顶层注释写明后台续更设计论证',
  /后台续更|后台短时任务/.test(lv.slice(0, 6000)));
check('LiveView 顶层注释写明为何不采用长时任务',
  /startBackgroundRunning[\s\S]{0,400}受限/.test(lv) || /受限权限[\s\S]{0,400}startBackgroundRunning/.test(lv));

/* =========================================================================
 * 7. 跨端进度契约：客户端 ↔ 服务端数值必须逐项一致（本次缺陷的根因防护）
 * =========================================================================
 * 实况窗进度现在有**两个写入方**，写的是同一个实况窗：
 *   ① 客户端 LiveView 看门狗，每 2s 本地 updateLiveView；
 *   ② 服务端 push.js，任务进行中按 LIVEVIEW_MIN_UPDATE_MS（默认 10s）补推
 *      （push-type 7 / operation 1），用于"App 被挂起/杀掉后仍能推进"。
 * 两端百分比公式只要有任何一个基线不同，服务端每次补推都会把进度条**拉回去**。
 *
 * 这不是假想：push.js 曾经把正文基线写成 25、思考基线写成 10，而客户端是
 * 30 / 12 —— 实测（plan/4000 字符，思考模式默认开启）最大偏差 5 个百分点，
 * 且从正文第 1 个字符起就全程 ≥3pp。本组断言就是防它再次发生。
 * ========================================================================= */
const PUSH_JS = path.join(ROOT, 'server/src/push.js');
const hasPushJs = fs.existsSync(PUSH_JS);

check('存在 server/src/push.js（跨端契约另一方）', hasPushJs);

if (hasPushJs) {
  const pj = read(PUSH_JS);

  /** 从 push.js 里按名字取一个 `const NAME = <number>;` 的字面量值 */
  function pushConst(name) {
    const m = pj.match(new RegExp('^const\\s+' + name + '\\s*=\\s*(-?[\\d.]+)\\s*;', 'm'));
    return m === null ? null : Number(m[1]);
  }

  /**
   * 从 GenProgress.ets 里取 `static readonly NAME: number = <值>;` 的公开契约值。
   *
   * 初值既可能是数字字面量，也可能是模块级常量的**符号引用**
   * （如 `= ANCHOR_THINK`，指向 `const ANCHOR_THINK: number = 12;`）。
   * 后者更可读、也更能保证"公开值与内部实现同源"，因此两种都要支持：
   * 否则这条最重要的跨端断言会因为写法而静默失效（写成 null 就等于没测）。
   */
  function gpStatic(name) {
    const m = gp.match(new RegExp('static\\s+readonly\\s+' + name +
      '\\s*:\\s*number\\s*=\\s*([\\w.]+)\\s*;'));
    if (m === null) {
      return null;
    }
    const raw = m[1];
    if (/^-?[\d.]+$/.test(raw)) {
      return Number(raw);
    }
    // 符号引用：回查同文件里的模块级常量定义
    const ref = gp.match(new RegExp('^const\\s+' + raw + '\\s*:\\s*number\\s*=\\s*(-?[\\d.]+)\\s*;', 'm'));
    return ref === null ? null : Number(ref[1]);
  }
  /* ---- 7.1 客户端确实把契约值公开出来了 ---- */
  const cThink = gpStatic('ANCHOR_THINK');
  const cBody = gpStatic('ANCHOR_BODY_MIN');
  const cCap = gpStatic('CAP_RUNNING');
  check('客户端公开 ANCHOR_THINK（跨端契约）', cThink !== null, 'value=' + cThink);
  check('客户端公开 ANCHOR_BODY_MIN（跨端契约）', cBody !== null, 'value=' + cBody);
  check('客户端公开 CAP_RUNNING（跨端契约）', cCap !== null, 'value=' + cCap);

  /* ---- 7.2 三个基线逐项相等（漂移的直接防护） ---- */
  const sThink = pushConst('ANCHOR_THINK');
  const sBody = pushConst('ANCHOR_BODY_MIN');
  const sCap = pushConst('CAP_RUNNING');
  check('ANCHOR_THINK 跨端一致', sThink !== null && sThink === cThink,
    'client=' + cThink + ' server=' + sThink);
  check('ANCHOR_BODY_MIN 跨端一致', sBody !== null && sBody === cBody,
    'client=' + cBody + ' server=' + sBody);
  check('CAP_RUNNING 跨端一致', sCap !== null && sCap === cCap,
    'client=' + cCap + ' server=' + sCap);

  /* ---- 7.2b 时间滑轨参数也必须跨端一致（第二次漂移的根因，26pp） ----
   * 客户端滑轨用的是**绝对流逝时间**配固定时间常数；服务端一度按
   * expectedMinutes 缩放流逝时间再喂给滑轨，于是两端不是同一个钟，
   * 最大偏差 26pp（plan/纯思考/t=150s：服务端 52% vs 客户端 78%）。
   * 只锁"锚点"不锁"滑轨"就会漏掉这一类漂移，故这里一并锁死。
   */
  function gpLocalNum(name) {
    const m = gp.match(new RegExp('^const\\s+' + name + '\\s*:\\s*number\\s*=\\s*(-?[\\d.]+)\\s*;', 'm'));
    return m === null ? null : Number(m[1]);
  }
  for (const n of ['RAMP_START', 'RAMP_ASYMPTOTE', 'RAMP_TAU_MS', 'SLA_FLOOR_MS', 'SLA_FLOOR_PCT']) {
    const cv = gpLocalNum(n);
    const sv = pushConst(n);
    check('滑轨参数 ' + n + ' 跨端一致', cv !== null && sv !== null && cv === sv,
      'client=' + cv + ' server=' + sv);
  }
  /* 根因判据：渐近上限必须小于运行期封顶，否则时间项可能把已抬高的锚点拉回去 */
  const cAsym = gpLocalNum('RAMP_ASYMPTOTE');
  check('RAMP_ASYMPTOTE < CAP_RUNNING（时间项不得拉回回调锚点）',
    cAsym !== null && cAsym < cCap, 'asym=' + cAsym + ' cap=' + cCap);

  /* ---- 7.3 EXPECT_CHARS 逐项相等（7 个功能一个都不能少/错） ---- */  const KINDS = ['plan', 'courseware', 'quiz', 'research', 'analysis', 'talk', 'report'];
  const sExpectMatch = pj.match(/const\s+EXPECT_CHARS\s*=\s*\{([\s\S]*?)\};/);
  check('能解析 push.js 的 EXPECT_CHARS 表', sExpectMatch !== null);
  const sExpect = {};
  if (sExpectMatch) {
    const re = /(\w+)\s*:\s*(\d+)/g;
    let mm;
    while ((mm = re.exec(sExpectMatch[1])) !== null) {
      sExpect[mm[1]] = Number(mm[2]);
    }
  }
  for (const k of KINDS) {
    check('EXPECT_CHARS[' + k + '] 跨端一致',
      sExpect[k] !== undefined && sExpect[k] === GenProgress.expectedChars(k),
      'client=' + GenProgress.expectedChars(k) + ' server=' + sExpect[k]);
  }

  /* ---- 7.4 行为级对齐：服务端 estimatePercent 必须与客户端公式逐点一致 ----
   * 上面前三条只锁"常数"，这一条直接跑服务端函数做逐点比对，
   * 能抓到"常数对但公式形状被改坏"的情况（比如正文分支又去覆盖思考基线）。
   */
  let pushMod = null;
  try {
    pushMod = require(path.join(ROOT, 'server/src/push.js'));
  } catch (e) {
    pushMod = null;
  }
  check('能加载 server/src/push.js 的 estimatePercent（行为级比对）',
    pushMod !== null && typeof pushMod.estimatePercent === 'function');

  if (pushMod !== null && typeof pushMod.estimatePercent === 'function') {
    /**
     * 客户端侧基线的**独立**取数：直接从 GenProgress.ets 的模块级常量解析，
     * 而不是复用上面的 gpStatic（那是"公开契约值"，两者若不一致本身就是缺陷）。
     * 这样这条行为断言才能真正独立于客户端公开出来的那几个数。
     */
    function gpLocalConst(name) {
      const m = gp.match(new RegExp('^const\\s+' + name + '\\s*:\\s*number\\s*=\\s*(-?[\\d.]+)\\s*;', 'm'));
      return m === null ? NaN : Number(m[1]);
    }
    const ANCHOR_THINK_LOCAL = gpLocalConst('ANCHOR_THINK');
    const ANCHOR_BODY_MIN_LOCAL = gpLocalConst('ANCHOR_BODY_MIN');
    const CAP_RUNNING_LOCAL = gpLocalConst('CAP_RUNNING');

    check('能从 GenProgress.ets 解析出三个基线常量（行为比对的前提）',
      !Number.isNaN(ANCHOR_THINK_LOCAL) && !Number.isNaN(ANCHOR_BODY_MIN_LOCAL)
      && !Number.isNaN(CAP_RUNNING_LOCAL),
      [ANCHOR_THINK_LOCAL, ANCHOR_BODY_MIN_LOCAL, CAP_RUNNING_LOCAL].join('/'));

    /**
     * 客户端侧的独立复算（按 GenProgress 的语义，不依赖其内部实现）：
     *   先 onThinking() → ANCHOR_THINK，再 onLength(L) → ANCHOR_BODY_MIN + (L/exp)^0.85·(CAP-基线)
     *   取 max，封顶 CAP_RUNNING。
     */
    function clientPercent(kind, len, hasThink) {
      const exp = GenProgress.expectedChars(kind);
      const ratio = Math.min(1, len / exp);
      const anchor = ANCHOR_BODY_MIN_LOCAL + Math.pow(ratio, 0.85) *
        (CAP_RUNNING_LOCAL - ANCHOR_BODY_MIN_LOCAL);
      const thinkAnchor = hasThink ? ANCHOR_THINK_LOCAL : 0;
      const v = Math.min(CAP_RUNNING_LOCAL, Math.max(anchor, thinkAnchor));
      return Math.round(v);
    }

    let worst = 0;
    let worstDesc = '';
    for (const k of KINDS) {
      const exp = GenProgress.expectedChars(k);
      const task = { type: k, liveView: { totalChars: exp, expectedMinutes: 2 } };
      // 采样整条长度曲线（含 1 字符这个最易暴露基线差异的点）
      const samples = new Set([1, 2, 5, 10, 50, 100, 200, 500, 1000,
        Math.floor(exp / 2), exp - 1, exp]);
      for (const L of samples) {
        if (L <= 0) {
          continue;
        }
        const s = pushMod.estimatePercent(task,
          { content: 'x'.repeat(L), reasoning: 'think'.repeat(10) });
        const c = clientPercent(k, L, true);
        const d = Math.abs(s - c);
        if (d > worst) {
          worst = d;
          worstDesc = k + '/len=' + L + ' server=' + s + ' client=' + c;
        }
      }
    }
    check('服务端 estimatePercent 与客户端公式逐点一致（思考态，7 个功能全采样）',
      worst === 0, '最大偏差=' + worst + 'pp @ ' + worstDesc);

    /* 无思考时也要一致（思考基线不得泄漏进无思考路径） */
    let worstNoThink = 0;
    let worstNoThinkDesc = '';
    for (const k of KINDS) {
      const exp = GenProgress.expectedChars(k);
      const task = { type: k, liveView: { totalChars: exp, expectedMinutes: 2 } };
      for (const L of [1, 100, 500, 1000, exp]) {
        const s = pushMod.estimatePercent(task, { content: 'x'.repeat(L), reasoning: '' });
        const c = clientPercent(k, L, false);
        const d = Math.abs(s - c);
        if (d > worstNoThink) {
          worstNoThink = d;
          worstNoThinkDesc = k + '/len=' + L + ' server=' + s + ' client=' + c;
        }
      }
    }
    check('服务端 estimatePercent 与客户端公式逐点一致（无思考态）',
      worstNoThink === 0, '最大偏差=' + worstNoThink + 'pp @ ' + worstNoThinkDesc);
  }

  /* ---- 7.5 服务端不得再出现被修正过的旧基线字面量 ---- */
  checkNot('push.js 不再含旧的 25 正文基线公式（曾导致 5pp 回退）',
    pj, /25\s*\+\s*Math\.pow\(ratio,\s*0\.85\)\s*\*\s*\(\s*CAP_RUNNING\s*-\s*25\s*\)/);
}

/* =========================================================================
 * 8. 上报体必须携带跨端对齐所需的 totalChars
 * ========================================================================= */
const rep = read(path.join(ROOT, 'entry/src/main/ets/common/LiveViewReport.ets'));
check('LiveViewReport.bind 接受 totalChars / expectedMinutes（可选，向后兼容）',
  /static\s+async\s+bind\s*\(\s*taskId\s*:\s*string\s*,\s*activityId\s*:\s*number\s*,\s*event\s*:\s*string\s*,\s*totalChars\s*\?:\s*number\s*,\s*expectedMinutes\s*\?:\s*number\s*\)/.test(rep));
check('上报体带上 totalChars 字段', /b\.totalChars\s*=\s*totalChars/.test(rep));
check('上报体带上 expectedMinutes 字段', /b\.expectedMinutes\s*=\s*expectedMinutes/.test(rep));
check('上报体用显式声明的接口（ArkTS 禁止无类型对象字面量）',
  /interface\s+LiveViewBindBody/.test(rep) && /:\s*LiveViewBindBody\s*\{/.test(rep));
check('非正数不携带（避免把 0 当有效预期长度发出去）',
  /totalChars\s*!==\s*undefined\s*&&\s*totalChars\s*>\s*0/.test(rep));
check('LiveView.bindTask 从 GenProgress 取契约值（不在别处再写一份字面量）',
  /GenProgress\.expectedChars\(kind\)/.test(lv) && /GenProgress\.expectedMinutes\(kind\)/.test(lv));

/* ---- 采样间隔：避开服务端 10s 推送节奏与自身 2s tick 的锁步 ---- */
const pollMs = (lv.match(/const\s+POLL_MS\s*:\s*number\s*=\s*(\d+)/) || [])[1];
check('权威进度拉取间隔为 8s（与 10s 推送的最小公倍数最大，冲突最少）',
  pollMs === '8000', 'POLL_MS=' + pollMs);
check('采样间隔大于 tick，避免每拍都打网络',
  Number(pollMs) > Number((lv.match(/const\s+TICK_MS\s*:\s*number\s*=\s*(\d+)/) || [])[1]),
  'POLL_MS=' + pollMs);

/* ---------------- 汇总 ---------------- */
console.log('='.repeat(72));
console.log('实况窗后台续更测试（LiveView background continuation）');
console.log('='.repeat(72));
if (failures.length > 0) {
  console.log('失败项：');
  failures.forEach((f, i) => console.log('  ' + (i + 1) + '. ' + f));
  console.log('-'.repeat(72));
}
console.log('结果: 通过 ' + pass + ' / 共 ' + (pass + fail) + ' 项');
console.log('='.repeat(72));
process.exit(fail === 0 ? 0 : 1);
