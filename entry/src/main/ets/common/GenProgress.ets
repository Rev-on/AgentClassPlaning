/**
 * 生成进度估算（用于实况窗进度百分比）。
 *
 * 设计依据（方案 C：混合估算）：
 *   纯"按输出长度 / 预期长度"到尾部会长时间卡在 90% 不动，观感差；
 *   纯"按阶段"又不够细腻。因此这里混合：
 *     1. **阶段推进**：思考中 → 正文生成 → 收尾，给出基准区间
 *     2. **长度估算**：在正文阶段按已生成字符数 / 预期字符数线性推进
 *     3. **缓升封顶**：接近预期长度时增速放缓，最高停在 95%
 *     4. **完成跳变**：生成真正结束时才置 100%
 *
 * 这样既不会长时间卡住，也不会在未完成时显示 100%（误导用户）。
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

export class GenProgress {
  /** 当前进度（0-100 整数） */
  private value: number = 0;
  /** 是否处于思考阶段 */
  private thinking: boolean = true;
  /** 是否已开始输出正文 */
  private started: boolean = false;
  /** 预期总字符数 */
  private expect: number = DEFAULT_EXPECT;

  constructor(kind: string) {
    const e: number | undefined = EXPECT_CHARS[kind];
    this.expect = e === undefined ? DEFAULT_EXPECT : e;
  }

  /** 思考阶段有进展（收到思考增量） */
  onThinking(): void {
    // 思考阶段占 0-25%：有思考内容即推进到 10%，避免长时间停在 0
    if (this.value < 10) {
      this.value = 10;
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
    // 正文阶段占 25-95%
    const ratio: number = len <= 0 ? 0 : Math.min(1, len / this.expect);
    // 线性推进，但对接近尾声的部分做压缩（ratio^0.85 让前期推进更快）
    const shaped: number = Math.pow(ratio, 0.85);
    const v: number = 25 + shaped * (CAP_RUNNING - 25);
    if (v > this.value) {
      this.value = v > CAP_RUNNING ? CAP_RUNNING : v;
    }
  }

  /** 生成完成：置 100% */
  onDone(): void {
    this.value = 100;
  }

  /** 当前进度（0-100 整数，单调不减） */
  current(): number {
    const v: number = Math.round(this.value);
    return v < 0 ? 0 : (v > 100 ? 100 : v);
  }

  /** 是否已开始输出正文（用于文案：准备中 / 生成中） */
  hasStarted(): boolean {
    return this.started;
  }
}
