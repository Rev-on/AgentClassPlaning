/**
 * 流式渲染节流器。
 *
 * 问题背景：
 *   服务端每收到一个模型分片就 SSE 推一次；客户端 onDelta 里直接
 *   `this.result = partial`，于是**每个分片都触发一次整页 rebuild**，
 *   RichBox 还要把已生成的全部 HTML 重新解析一遍。
 *   DeepSeek 流式输出常有 20~80 片/秒，远高于屏幕刷新率（60Hz），
 *   大量分片落在**同一帧内** —— 渲染纯属白做，表现为卡顿、掉帧。
 *
 * 策略：
 *   保留"最新值"而不是排队 —— UI 只需要展示最新进度，中间态可丢弃。
 *   固定间隔（默认 60ms ≈ 16fps）提交一次，兼顾流畅与开销：
 *     · 比屏幕刷新略慢，避免无谓渲染；
 *     · 又足够快，肉眼看仍是"连续输出"。
 *
 * 用法：
 *   private throttle: StreamThrottle = new StreamThrottle((v: string) => { this.result = v; });
 *   // 流式回调里
 *   this.throttle.push(partial);
 *   // 结束/停止时务必 flush，保证最终内容不丢
 *   this.throttle.flush();
 *   this.throttle.cancel();
 */
export class StreamThrottle {
  /** 最小提交间隔（毫秒） */
  private static readonly INTERVAL: number = 60;

  private latest: string = '';
  private timer: number = -1;
  private lastAt: number = 0;
  private readonly apply: (v: string) => void;

  constructor(apply: (v: string) => void) {
    this.apply = apply;
  }

  /** 推入最新值（不立即渲染，按间隔合并提交） */
  push(value: string): void {
    this.latest = value;
    const now: number = Date.now();
    const elapsed: number = now - this.lastAt;
    if (elapsed >= StreamThrottle.INTERVAL) {
      // 距上次提交已足够久：立即渲染，保证首屏响应
      this.commit();
      return;
    }
    if (this.timer !== -1) {
      return; // 已有待执行的提交
    }
    this.timer = setTimeout((): void => {
      this.timer = -1;
      this.commit();
    }, StreamThrottle.INTERVAL - elapsed);
  }

  /** 立即提交最新值（生成结束/停止时调用，确保最终内容落地） */
  flush(): void {
    if (this.timer !== -1) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
    this.commit();
  }

  /** 丢弃待提交并清空，防止旧任务回魂 */
  cancel(): void {
    if (this.timer !== -1) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
    this.latest = '';
    this.lastAt = 0;
  }

  private commit(): void {
    this.lastAt = Date.now();
    this.apply(this.latest);
  }
}
