/**
 * 生成进度估算（用于实况窗进度百分比）。
 *
 * ============================================================================
 * 【v2 设计论证：为什么要改成"时间驱动"的混合估算】
 * ============================================================================
 * 背景（用户核心诉求）：7 大 AI 生成功能在生成过程中，用户把应用退到后台，
 * 桌面（状态栏/锁屏）的实况窗必须**继续实时显示进度**。
 *
 * v1（原实现）的致命缺陷 —— **进度完全由进程内回调驱动**：
 *   页面 onDelta/onThink → LiveView.onContent/onThinking → GenProgress.onLength
 *   → updateLiveView。
 *   用户按 Home 退到后台后，鸿蒙把应用进程挂起（suspended），JS 回调不再触发，
 *   进度就**永久冻结在最后一次回调的百分比**上 —— 用户看到的是一个"卡死"的
 *   实况窗，这正是要修的问题。
 *
 * v2 的解法：把进度从"回调次数驱动"改为**"阶段锚点 + 单调时间滑轨"**：
 *
 *   进度 = max(阶段锚点值, 时间滑轨值)        —— 两者取大，保证单调不减
 *
 *   · 阶段锚点（回调驱动，保留 v1 的语义）：
 *       思考增量 → 12%；正文增量 → 按 已生成长度/预期长度 推进到 30..95%。
 *       回调只在"有回调"时才抬高锚点，因此后台挂起期间锚点不动。
 *   · 时间滑轨（**时间驱动，后台冻不住**）：
 *       以 startTime 为 0 点，平滑渐近曲线 ramp(t)，
 *       t=0 → 3%，以后持续上升，渐近 88%，硬下限兜底。
 *       它**不依赖任何回调**，只依赖"当前时刻 − 开始时刻"。
 *
 *   ⇒ 进程被挂起期间滑轨不增长；但**一旦该进程被重新调度**（进入后台后
 *     有 requestSuspendDelay 争到的短时窗口、周期任务被拉起、用户回到前台），
 *     下一次读到 Date.now() 时按**真实已流逝时间**一次性补齐百分比，
 *     视觉上立刻跳到"这段时间本该到的位置"，而不是停在旧值。
 *     这就是"后台仍然持续推进"的实现基础（详见 LiveView.ets 顶部的完整论证）。
 *
 * 【为什么是渐近曲线而不是线性】
 *   线性到点会超时后一路冲顶，过早显示 95% 反而误导用户（真实生成可能还需很久）。
 *   渐近曲线前期增长快（用户刚切到后台就能看到百分比在动），后期增长慢，
 *   在 88% 处收敛，给"收尾/校验"留出空间，且永远不会自己走到 100%。
 *
 * 【不变式（回归测试断言的就是这些）】
 *   1. current() 单调不减；
 *   2. 运行期封顶 CAP_RUNNING(95)，永不为 100；
 *   3. onDone() 才置 100；
 *   4. 相同时间点的重复调用不改变进度（幂等）；
 *   5. 时间大幅前进时进度**明显**增长（后台补齐能力）。
 */

/** 各生成类型的内容长度预期（字符）。取自实际产出长度的大致经验值。 */
const EXPECT_CHARS: Record<string, number> = {
  'plan': 4000,        // 教案：较长
  'courseware': 2600,  // 课件大纲
  'quiz': 3000,        // 分层练习
  'research': 2400,    // 教研辅助
  'analysis': 3200,    // 学情分析
  'talk': 2000,        // 沟通话术
  'report': 2800       // 学情报告
};
const DEFAULT_EXPECT: number = 3000;

/** 进度上限：未真正完成前不显示 100% */
const CAP_RUNNING: number = 95;

/**
 * 各类型的"预期总耗时"（毫秒）—— 时间滑轨的时间尺度。
 * 值取自 7 个功能的典型产出长度（与 EXPECT_CHARS 同源：输出越长，耗时越久）。
 * 滑轨是渐近的，所以这个值不需要很精确，只决定"前段涨得多快"。
 */
const EXPECT_MS: Record<string, number> = {
  'plan': 110000,       // 教案：最长
  'courseware': 75000,  // 课件大纲
  'quiz': 85000,        // 分层练习
  'research': 70000,    // 教研辅助
  'analysis': 90000,    // 学情分析
  'talk': 60000,        // 沟通话术
  'report': 80000       // 学情报告
};
const DEFAULT_EXPECT_MS: number = 90000;

/* ---------------- 时间滑轨参数（曲线形状，见顶部论证） ---------------- */
/** 起始百分比：任务一提交就先显示 3%，让用户立刻看到"已受理、在跑" */
const RAMP_START: number = 3;
/** 渐近终值：无论跑多久，时间滑轨自己最高只到 88% */
const RAMP_ASYMPTOTE: number = 88;
/** 时间常数：t = TAU 时滑轨约走完 (1-1/e)≈63% 的剩余量 */
const RAMP_TAU_MS: number = 45000;
/**
 * 硬下限兜底：即使某类型没配 EXPECT_MS、时间又只走了很短一段，
 * 超过 SLA_FLOOR_MS 也至少要显示 SLA_FLOOR_PCT，避免"像卡住了"。
 */
const SLA_FLOOR_MS: number = 150000;
const SLA_FLOOR_PCT: number = 78;

/* ---------------- 阶段锚点（回调驱动，沿用 v1 语义） ---------------- */
/** 思考阶段锚点：只要收到过思考增量就抬到 12% */
const ANCHOR_THINK: number = 12;
/** 正文阶段锚点区间：30 → CAP_RUNNING */
const ANCHOR_BODY_MIN: number = 30;

export class GenProgress {
  /* ==================== 跨端进度契约（单一事实来源） ====================
   *
   * 【为什么把这三个数字暴露成 public static】
   *   实况窗的进度现在有**两个写入方**：
   *     ① 客户端：本类 + LiveView 看门狗，每 2s 本地 updateLiveView；
   *     ② 服务端：server/src/push.js 的 estimatePercent，任务进行中按节流
   *        （默认 10s/条、最多 30 条）用 Push Kit push-type 7/operation 1 补推，
   *        用于"App 进程被挂起/杀掉后进度条仍能推进"。
   *   两者写的是**同一个实况窗**，因此百分比公式必须逐项对齐，否则交替更新时
   *   进度条会来回跳、甚至回退。
   *
   *   之前对齐靠"两边代码里各写一遍常数"：服务端注释写着"与客户端 EXPECT_CHARS
   *   对齐"，但 push.js 的正文基线实际是 25、思考基线是 10，而这里是 30 / 12。
   *   实测（plan/4000 字符/思考开启）最大偏差 5 个百分点，服务端每次补推都会把
   *   进度条**拉回 5pp**。本应用的思考模式默认开启，因此这是主路径而非边角。
   *
   *   现在把三个基线定义成 public static 常量，服务端侧的防漂移测试可直接解析
   *   本文件，任何单边改动都会让测试失败。
   *
   * ⚠️ 修改这些值等于**修改跨端契约**，必须同步 server/src/push.js，并重跑
   *    server/tools/test_liveview_background.js 与 test_liveview_progress.js。
   */
  /** 思考阶段锚点（%）：收到思考增量即抬升到此值 */
  static readonly ANCHOR_THINK: number = ANCHOR_THINK;
  /** 正文阶段起始锚点（%）：有正文输出时的百分比基线 */
  static readonly ANCHOR_BODY_MIN: number = ANCHOR_BODY_MIN;
  /** 运行期封顶（%）：未真正完成前绝不显示 100 */
  static readonly CAP_RUNNING: number = CAP_RUNNING;

  /**
   * 某生成类型的内容长度预期（字符）——供服务端换算百分比。
   * 这是跨端**唯一**的 EXPECT_CHARS 事实来源，服务端副本必须逐项相等。
   */
  static expectedChars(kind: string): number {
    const e: number | undefined = EXPECT_CHARS[kind];
    return e === undefined ? DEFAULT_EXPECT : e;
  }

  /**
   * 某生成类型的"预期生成时长"（分钟）——上报给服务端用于**记录/诊断**。
   *
   * ⚠️ **不参与任何一端的百分比计算**（服务端已明确去掉时间缩放）。
   *
   * 【为什么必须说清楚这一点】曾经踩到的坑：服务端按这个值缩放流逝时间再喂给
   *   时间滑轨，而客户端滑轨用的是**绝对流逝时间**配固定时间常数
   *   （RAMP_TAU_MS=45s），从不随类型缩放 —— 两端不是同一个钟，最大偏差 26pp
   *   （plan/纯思考/t=150s：服务端 52% vs 客户端 78%），每次补推都把进度条
   *   往回拉。跨端对齐最终以**客户端渐近曲线**为准，服务端不再做时间缩放。
   *
   *   这里如实按 EXPECT_MS 上报真实时间尺度，**不要**为了"让某个线性公式恰好
   *   等于渐近值"而填凑数值 —— 那样只会把一个已废弃的兜底语义伪装成精确值。
   */
  static expectedMinutes(kind: string): number {
    const m: number | undefined = EXPECT_MS[kind];
    const ms: number = m === undefined ? DEFAULT_EXPECT_MS : m;
    return Math.round((ms / 60000) * 100) / 100;
  }

  /** 阶段锚点值（回调驱动，只增不减） */
  private value: number = 0;
  /** 是否处于思考阶段 */
  private thinking: boolean = true;
  /** 是否已开始输出正文 */
  private started: boolean = false;
  /** 预期总字符数 */
  private expect: number = DEFAULT_EXPECT;
  /** 时间滑轨时间尺度（毫秒） */
  private expectMs: number = DEFAULT_EXPECT_MS;
  /** 任务开始时刻（毫秒时间戳）—— 全类的"0 点"，跨后台挂起依然有效 */
  private startTime: number = 0;
  /** 是否已真正完成（onDone 后为 true，此时才允许到 100） */
  private done: boolean = false;
  /** 最近一次计算出的百分比（保证单调不减 / 幂等） */
  private last: number = 0;

  constructor(kind: string, startTime?: number) {
    const e: number | undefined = EXPECT_CHARS[kind];
    this.expect = e === undefined ? DEFAULT_EXPECT : e;
    const m: number | undefined = EXPECT_MS[kind];
    this.expectMs = m === undefined ? DEFAULT_EXPECT_MS : m;
    // startTime 由调用方（LiveView.start）传入，保证与"实况窗创建时刻"同源。
    // 不传时退回当前时刻，便于独立测试。
    this.startTime = startTime === undefined ? Date.now() : startTime;
    this.last = RAMP_START;
    this.value = RAMP_START;
  }

  /* ==================== 回调驱动：阶段锚点 ==================== */

  /** 思考阶段有进展（收到思考增量） */
  onThinking(): void {
    this.thinking = true;
    // 思考阶段锚点 12%：有思考内容即抬升，避免长时间停在起始值
    if (this.value < ANCHOR_THINK) {
      this.value = ANCHOR_THINK;
    }
  }

  /**
   * 正文有进展（收到正文增量）。
   * @param content 当前已生成的正文全文
   */
  onContent(content: string): void {
    this.onLength(content.length);
  }

  /**
   * 正文有进展（只知道已生成长度时使用，例如课件页不保留半成品正文）。
   * @param len 已生成的字符数
   */
  onLength(len: number): void {
    this.thinking = false;
    this.started = true;
    // 正文阶段锚点区间 30 → 95
    const ratio: number = len <= 0 ? 0 : Math.min(1, len / this.expect);
    // 线性推进，但对接近尾声的部分做压缩（ratio^0.85 让前期推进更快）
    const shaped: number = Math.pow(ratio, 0.85);
    const v: number = ANCHOR_BODY_MIN + shaped * (CAP_RUNNING - ANCHOR_BODY_MIN);
    if (v > this.value) {
      this.value = v > CAP_RUNNING ? CAP_RUNNING : v;
    }
  }

  /* ==================== 时间驱动：平滑滑轨 ==================== */

  /**
   * 计算"仅按已流逝时间"应达到的百分比（与任何回调无关）。
   *
   * 曲线：ramp(t) = RAMP_START + (ASYMPTOTE - START) · t/(t + TAU)
   *   t→0    : → RAMP_START(3)
   *   t=TAU  : 3 + 85·0.5      = 45.5
   *   t=3TAU : 3 + 85·0.75     = 66.8
   *   t→∞    : → ASYMPTOTE(88)
   *
   * @param elapsedMs 已流逝毫秒数（跨后台挂起照样累加，因为用的是墙钟时间差）
   */
  private ramp(elapsedMs: number): number {
    if (elapsedMs <= 0) {
      return RAMP_START;
    }
    const r: number = elapsedMs / (elapsedMs + RAMP_TAU_MS);
    let v: number = RAMP_START + (RAMP_ASYMPTOTE - RAMP_START) * r;
    // 硬下限兜底（SLA）：跑过 SLA_FLOOR_MS 还没结束，至少显示 78%
    if (elapsedMs >= SLA_FLOOR_MS && v < SLA_FLOOR_PCT) {
      v = SLA_FLOOR_PCT;
    }
    return v;
  }

  /** 仅按时间计算的滑轨值（对外暴露，供测试与诊断） */
  rampNow(): number {
    return this.ramp(Date.now() - this.startTime);
  }

  /* ==================== 汇总 ==================== */

  /**
   * 当前进度（0-100 整数，单调不减）。
   *
   * 取值 = max(阶段锚点, 时间滑轨)。**每次调用都会重新读时间**，
   * 因此"后台挂起 → 重新被调度"时，这里会自动把这段时间补上。
   */
  current(): number {
    if (this.done) {
      return 100;
    }
    const anchor: number = this.value > CAP_RUNNING ? CAP_RUNNING : this.value;
    const rampV: number = this.ramp(Date.now() - this.startTime);
    let v: number = anchor > rampV ? anchor : rampV;
    if (v > CAP_RUNNING) {
      v = CAP_RUNNING;
    }
    // 单调不减：一旦抬高就不再回落（避免回调锚点与滑轨交叉时百分比回跳）
    if (v > this.last) {
      this.last = v;
    }
    return Math.round(this.last);
  }

  /** 生成完成：置 100%（只有这里能让进度到 100） */
  onDone(): void {
    this.done = true;
    this.value = 100;
    this.last = 100;
  }

  /** 是否已开始输出正文（用于文案：准备中 / 生成中） */
  hasStarted(): boolean {
    return this.started;
  }

  /** 已运行的毫秒数（供 LiveView 判断是否需要续期后台短时任务） */
  elapsedMs(): number {
    return Date.now() - this.startTime;
  }
}
