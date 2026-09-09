/**
 * 流式生成实时预览（生成中滚动展示已产出的部分内容）
 *  - 内容每次更新（@Watch）自动滚动到底部：立即一次 + 延迟兜底一次（覆盖 RichText 异步排版）
 *  - plain=true 按纯文本展示（如课件大纲 JSON 流）；否则按富文本 HTML 展示
 *  - 仅在生成中挂载：生成结束由父页面卸载，不残留滚动状态
 */
import { RichBox } from './RichBox';
import { RichHtml } from '../RichHtml';

@Component
export struct StreamPreview {
  /** 已产出的部分内容（HTML 或纯文本，由父页面随流式增量持续更新） */
  @Prop @Watch('onTextChange') text: string = '';
  /** true=纯文本展示；false=富文本 HTML 展示 */
  plain: boolean = false;
  /** 加载指示器配色（与所在页面主色一致） */
  accent: string = '#4A90D9';
  /** 顶部提示文案（父页面传入已翻译文案） */
  label: string = '';
  /** 顶部提示文案颜色（跟随主题） */
  labelColor: string = '#666666';
  /** 滚动控制器：内容更新后滚动到底部 */
  private scroller: Scroller = new Scroller();

  /** 内容更新回调：滚动到底部 */
  private onTextChange(): void {
    this.scrollToBottom();
  }

  /** 滚动到底部（延迟一次兜底 RichText 异步排版导致的高度变化） */
  private scrollToBottom(): void {
    try {
      this.scroller.scrollEdge(Edge.Bottom);
    } catch (e) {
      // 组件尚未挂载时滚动无效，忽略
    }
    setTimeout(() => {
      try {
        this.scroller.scrollEdge(Edge.Bottom);
      } catch (e) {
        // ignore
      }
    }, 60);
  }

  build() {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        LoadingProgress().width(14).height(14).color(this.accent)
        Text(this.label)
          .fontSize(12)
          .fontColor(this.labelColor)
      }
      .width('100%')
      .justifyContent(FlexAlign.Start)

      Scroll() {
        if (this.plain) {
          Text(this.text)
            .fontSize(13)
            .lineHeight(20)
            .fontColor('#333333')
            .width('100%')
        } else {
          RichBox({ html: RichHtml.liveSafe(this.text) })
            .width('100%')
        }
      }
      .scroller(this.scroller)
      .width('100%')
      .layoutWeight(1)
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .layoutWeight(1)
  }
}
