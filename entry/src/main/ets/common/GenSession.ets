/**
 * 生成会话总线：让"AI 生成"的生命周期与页面解耦
 * - 进入生成 → begin(key)：即使离开页面/退到桌面，生成照常进行
 * - 完成 → end(key, text)：记录最终内容并广播
 * - 失败/放弃 → clear(key)：复位广播
 * 页面在 aboutToAppear 订阅、aboutToDisappear 退订，重进页面即可恢复"生成中/结果"
 */
export interface GenSessionState {
  /** busy=生成中 done=已完成 idle=无会话 */
  phase: string;
  /** 页面/工具标识（与 AiService opts.type 一致） */
  key: string;
  /** 已完成内容（富文本 HTML） */
  text: string;
  /** 开始时间戳 */
  ts: number;
}

interface GenEntry {
  state: GenSessionState;
  subs: Map<number, (s: GenSessionState) => void>;
  nextId: number;
}

export class GenSession {
  private static entries: Map<string, GenEntry> = new Map<string, GenEntry>();

  private static entry(key: string): GenEntry {
    let e: GenEntry | undefined = GenSession.entries.get(key);
    if (e === undefined) {
      e = { state: { phase: 'idle', key: key, text: '', ts: 0 }, subs: new Map<number, (s: GenSessionState) => void>(), nextId: 1 };
      GenSession.entries.set(key, e);
    }
    return e;
  }

  private static notify(e: GenEntry): void {
    e.subs.forEach((cb: (s: GenSessionState) => void) => {
      try {
        cb(e.state);
      } catch (err) {
        // 订阅方异常不影响其它订阅者与生成流程
      }
    });
  }

  /** 生成开始（幂等覆盖同 key 的旧会话） */
  static begin(key: string): void {
    const e: GenEntry = GenSession.entry(key);
    e.state = { phase: 'busy', key: key, text: '', ts: Date.now() };
    GenSession.notify(e);
  }

  /** 生成成功：写入结果并广播 */
  static end(key: string, text: string): void {
    const e: GenEntry = GenSession.entry(key);
    e.state = { phase: 'done', key: key, text: text, ts: Date.now() };
    GenSession.notify(e);
  }

  /** 生成失败/取消：复位并广播（有内容的页面保留旧结果显示，空白页停止转圈） */
  static clear(key: string): void {
    const e: GenEntry = GenSession.entry(key);
    e.state = { phase: 'idle', key: key, text: '', ts: Date.now() };
    GenSession.notify(e);
  }

  /** 查询当前会话（无会话返回 undefined） */
  static stateOf(key: string): GenSessionState | undefined {
    const e: GenEntry | undefined = GenSession.entries.get(key);
    if (e === undefined) {
      return undefined;
    }
    return e.state;
  }

  /** 订阅变更，返回订阅号（用于退订） */
  static subscribe(key: string, cb: (s: GenSessionState) => void): number {
    const e: GenEntry = GenSession.entry(key);
    const token: number = e.nextId;
    e.nextId++;
    e.subs.set(token, cb);
    return token;
  }

  /** 退订 */
  static unsubscribe(key: string, token: number): void {
    const e: GenEntry | undefined = GenSession.entries.get(key);
    if (e === undefined) {
      return;
    }
    e.subs.delete(token);
  }
}
