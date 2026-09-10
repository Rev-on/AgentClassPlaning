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
  /** 富文本内容（HTML 子集；旧纯文本内容会被自动兼容） */
  @Prop html: string = '';
  /** 纸张底色（默认白） */
  @Prop paper: string = '#FFFFFF';
  /** 正文基准字号（fp，与软件正文一致；随字号设置缩放） */
  @Prop bodySize: number = 15;

  /** 正文颜色（墨色，白底下可读） */
  private static readonly INK: string = '#1B1B1F';

  /** 解析为"标题/段落"块序列（按换行切段） */
  private blocks(): PreviewBlock[] {
    const runs: RichRun[] = RichHtml.htmlToRuns(this.html);
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
              .fontColor(RichBox.INK)
              .width('100%')
              .lineHeight(this.headingSize(b.heading) + 8)
          } else {
            Text() {
              ForEach(b.runs, (r: RichRun) => {
                Span(r.text)
                  .fontFamily(AppFonts.family())
                  .fontSize(r.size >= 19 ? this.bodySize + 6 : (r.size >= 17 ? this.bodySize + 2 : this.bodySize))
                  .fontColor(r.color !== '' ? ('#' + r.color) : RichBox.INK)
                  .fontWeight(r.bold ? FontWeight.Bold : FontWeight.Normal)
                  .fontStyle(r.italic ? FontStyle.Italic : FontStyle.Normal)
                  .decoration({
                    type: r.strike ? TextDecorationType.LineThrough
                      : (r.underline ? TextDecorationType.Underline : TextDecorationType.None)
                  })
              }, (r: RichRun, idx: number) => idx.toString() + '_' + r.text)
            }
            .width('100%')
            .lineHeight(this.bodySize + 7)
          }
        }, (b: PreviewBlock, i: number) => i.toString() + '_' + b.heading.toString())
      }
    }
    .width('100%')
    .padding(12)
    .backgroundColor(this.paper)
    .borderRadius(10)
    .alignItems(HorizontalAlign.Start)
  }
}
