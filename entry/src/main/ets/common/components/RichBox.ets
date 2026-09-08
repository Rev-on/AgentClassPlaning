/**
 * 富文本展示组件：以 RichText 渲染受限 HTML 子集（AI 生成内容 / 历史记录通用）
 * RichText 文字颜色默认黑色且不支持主题色注入，故采用"白底文档纸"样式保证深浅主题均可读；
 * 内容来源为经模型约束 + RichHtml 白名单的 HTML。
 */
import { RichHtml } from '../RichHtml';

@Component
export struct RichBox {
  /** 富文本内容（HTML 子集；旧纯文本内容会被自动兼容为带换行的文本） */
  @Prop html: string = '';
  /** 纸张底色（默认白；可传 null 字符串保持白底） */
  @Prop paper: string = '#FFFFFF';

  build() {
    Column() {
      if (this.html.trim() === '') {
        Text('')
          .width('100%')
          .height(1)
      } else {
        RichText(RichHtml.toDisplay(this.html))
          .width('100%')
      }
    }
    .width('100%')
    .padding(12)
    .backgroundColor(this.paper)
    .borderRadius(10)
    .alignItems(HorizontalAlign.Start)
  }
}
