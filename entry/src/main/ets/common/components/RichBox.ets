/**
 * 富文本展示组件：以原生文本渲染受限 HTML 子集（AI 生成内容 / 历史记录通用）
 *  - 用原生 Text/Span 渲染，字号使用 fp 单位，**跟随系统/软件内的字号设置缩放**，
 *    与页面正文（fontSize 15fp）保持一致，不再像 RichText 那样固定像素导致预览偏小
 *  - 支持少数民族语言内置字体（AppFonts.family()），RichText 无法做到
 *  - 白底文档纸样式，深浅主题下均可读
 */
import { RichHtml, RichRun } from '../RichHtml';
import { AppFonts } from '../AppFonts';

/** 预览块（一个段落或一个标题） */
interface PreviewBlock {
  /** 0=正文，2/3=标题级数 */
  heading: number;
  runs: RichRun[];
}

@Component
export struct RichBox {
  /** 实际生效主题：'light' | 'dark'（由 EntryAbility 维护） */
  @StorageProp('appResolvedTheme') resolvedTheme: string = 'light';
  /** 富文本内容（HTML 子集；旧纯文本内容会被自动兼容） */
  @Prop html: string = '';
  /** 纸张底色（默认白；深色模式下自动切为深色纸） */
  @Prop paper: string = '#FFFFFF';
  /** 正文基准字号（fp，与软件正文一致；随字号设置缩放） */
  @Prop bodySize: number = 15;

  /** 墨色：浅色＝黑，深色＝白，保证纸面可读 */
  private static readonly INK: string = '#1B1B1F';
  private static readonly INK_DARK: string = '#E7EAF0';
  private static readonly PAPER_DARK: string = '#1C222C';

  /**
   * 解析结果缓存（**仅按源串整串命中**）。
   *
   * 为什么需要：
   *   原实现把 blocks() 直接写在 build() 的 ForEach 里，而 build() 在**每个流式
   *   分片**都会重跑 —— 于是每次都要把"当前已生成的全部 HTML"从头解析一遍。
   *
   * 为什么不做"按段落增量解析"：
   *   曾尝试只解析新增尾部、复用已稳定段落，但**语义不正确**：
   *   段落边界依赖跨行的 HTML 上下文（如 `<b>` 跨行、上一行末尾的样式延续），
   *   从 `\n` 之后单独解析尾部会得到与整串解析不同的分块结果
   *   （实测：`## 一、教材分析\n本` 会被错拆成两块）。
   *   因此这里只做"整串未变则复用"的安全缓存；只要 AppStorage/Prop 触发的是
   *   同值重渲染（排版、主题、滚动等引发的 rebuild），就能省掉重复解析。
   */
  private cachedSrc: string = '';
  private cachedBlocks: PreviewBlock[] = [];

  /** 主题是否为深色 */
  private isDark(): boolean {
    return this.resolvedTheme === 'dark';
  }

  /** 当前墨色：深色模式用浅色白字，浅色保持黑字 */
  private ink(): string {
    return this.isDark() ? RichBox.INK_DARK : RichBox.INK;
  }

  /** 纸面底色：深色模式切为深色纸（调用了可覆盖的 paper，浅色仍可指定纸张） */
  private paperColor(): string {
    return this.isDark() ? RichBox.PAPER_DARK : this.paper;
  }

  /**
   * 解析为"标题/段落"块序列（按换行切段）。
   *
   * 带整串缓存：源串未变时直接复用上次结果，避免同值重渲染重复解析。
   * （不做段落级增量，原因见 cachedSrc 注释 —— 那样会破坏跨行语义。）
   */
  private blocks(): PreviewBlock[] {
    const src: string = this.html;
    if (src === this.cachedSrc) {
      return this.cachedBlocks;
    }
    const out: PreviewBlock[] = RichBox.parseBlocks(src);
    this.cachedSrc = src;
    this.cachedBlocks = out;
    return out;
  }

  /** 把整段 HTML 解析为块序列（纯函数） */
  private static parseBlocks(html: string): PreviewBlock[] {
    const runs: RichRun[] = RichHtml.htmlToRuns(html);
    const out: PreviewBlock[] = [];
    let cur: RichRun[] = [];
    const push = (): void => {
      if (cur.length === 0) {
        return;
      }
      const head: number = cur[0].heading;
      const blk: PreviewBlock = { heading: head, runs: cur };
      out.push(blk);
      cur = [];
    };
    for (let i: number = 0; i < runs.length; i++) {
      const r: RichRun = runs[i];
      const parts: string[] = r.text.split('\n');
      for (let k: number = 0; k < parts.length; k++) {
        if (parts[k] !== '') {
          const cp: RichRun = {
            text: parts[k], bold: r.bold, italic: r.italic, underline: r.underline,
            strike: r.strike, color: r.color, heading: r.heading, size: r.size
          };
          cur.push(cp);
        }
        if (k < parts.length - 1) {
          push();
        }
      }
    }
    push();
    return out;
  }

  /** 标题纯文本 */
  private headingText(runs: RichRun[]): string {
    let s: string = '';
    for (let i: number = 0; i < runs.length; i++) {
      s += runs[i].text;
    }
    return s;
  }

  /** 标题字号（fp）：与正文联动放大 */
  private headingSize(level: number): number {
    if (level >= 3) {
      return this.bodySize + 2;
    }
    return this.bodySize + 6;
  }

  build() {
    Column({ space: 8 }) {
      if (this.html.trim() === '') {
        Text('')
          .width('100%')
          .height(1)
      } else {
        ForEach(this.blocks(), (b: PreviewBlock) => {
          if (b.heading > 0) {
            Text(this.headingText(b.runs))
              .fontFamily(AppFonts.family())
              .fontSize(this.headingSize(b.heading))
              .fontWeight(FontWeight.Bold)
              .fontColor(this.ink())
              .width('100%')
              .lineHeight(this.headingSize(b.heading) + 8)
          } else {
            Text() {
              ForEach(b.runs, (r: RichRun) => {
                Span(r.text)
                  .fontFamily(AppFonts.family())
                  .fontSize(r.size >= 19 ? this.bodySize + 6 : (r.size >= 17 ? this.bodySize + 2 : this.bodySize))
                  .fontColor(r.color !== '' ? ('#' + r.color) : this.ink())
                  .fontWeight(r.bold ? FontWeight.Bold : FontWeight.Normal)
                  .fontStyle(r.italic ? FontStyle.Italic : FontStyle.Normal)
                  .decoration({
                    type: r.strike ? TextDecorationType.LineThrough
                      : (r.underline ? TextDecorationType.Underline : TextDecorationType.None)
                  })
                // key 只用下标 + 样式标记，**不含文本**：
                //   流式追加时最后一段文本每片都在变，若 key 含文本会导致
                //   该 Span 每片都被判定为"新节点"而销毁重建，既闪烁又慢。
                //   下标+样式已能唯一标识该项，文本变化由框架原地更新。
              }, (r: RichRun, idx: number) => idx.toString()
                + (r.bold ? 'b' : '') + (r.italic ? 'i' : '')
                + (r.underline ? 'u' : '') + (r.strike ? 's' : '')
                + (r.color !== '' ? r.color : '') + '_' + r.size.toString())
            }
            .width('100%')
            .lineHeight(this.bodySize + 7)
          }
        // 段落 key 同样去掉易变内容：仅用下标 + 标题级别。
        // 段落的 text 增长由框架更新，不需要重建整个段落节点。
        }, (b: PreviewBlock, i: number) => i.toString() + '_' + b.heading.toString())
      }
    }
    .width('100%')
    .padding(12)
    .backgroundColor(this.paperColor())
    .borderRadius(10)
    .alignItems(HorizontalAlign.Start)
  }
}
