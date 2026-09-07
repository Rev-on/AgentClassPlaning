/**
 * 生成结果全局总线（2in1 全屏"下半屏大面板"用）
 *  - 7 个 AI 生成工具在生成过程中将阶段/内容发布到 AppStorage('liveGenResult')
 *  - IndexWideDuo 下半屏大面板订阅并展示（busy=生成中 / done=完成 / idle=占位）
 *  - 手机/平板/键盘模式不消费该数据，发布无副作用
 */
export class ResultBus {
  static readonly KEY: string = 'liveGenResult';

  /** 面板初始态（确保 @StorageLink 绑定前键已存在） */
  static init(): void {
    if (AppStorage.get<string>(ResultBus.KEY) === undefined) {
      AppStorage.setOrCreate<string>(ResultBus.KEY, '{"phase":"idle","kind":"","type":"","title":"","text":""}');
    }
  }

  /** 生成中（含流式中间文本，partial 可为空串） */
  static live(kind: string, type: string, title: string, text: string): void {
    AppStorage.setOrCreate<string>(ResultBus.KEY, ResultBus.pack('busy', kind, type, title, text));
  }

  /** 生成完成 */
  static done(kind: string, type: string, title: string, text: string): void {
    AppStorage.setOrCreate<string>(ResultBus.KEY, ResultBus.pack('done', kind, type, title, text));
  }

  /** 清空 / 失败复位 */
  static clear(): void {
    AppStorage.setOrCreate<string>(ResultBus.KEY, '{"phase":"idle","kind":"","type":"","title":"","text":""}');
  }

  /** 编码负载 JSON（底部面板编辑回写时也复用） */
  static pack(phase: string, kind: string, type: string, title: string, text: string): string {
    return JSON.stringify({ phase: phase, kind: kind, type: type, title: title, text: text });
  }
}
