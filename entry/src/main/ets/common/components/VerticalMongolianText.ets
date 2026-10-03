/**
 * 通用横写文本组件
 *
 * 说明：
 *  - 蒙古语界面已改用**西里尔蒙古文**（标准西里尔字符集，横排），
 *    原先的"传统蒙古文竖排"方案不再需要；本组件统一渲染普通横写 Text
 *  - 字体族由 AppFonts.family() 按界面语言决定（藏文/维吾尔文用内置字体，
 *    中文、英文、西里尔蒙古文用系统默认字体）
 *  - 文件名与组件名沿用历史命名（VerticalMongolianText），
 *    以免改动 21 处既有调用点
 */
import { AppFonts } from '../AppFonts';

@Component
export struct VerticalMongolianText {
  /** 文本内容（@Prop：语言切换后随父组件同步刷新） */
  @Prop content: string = '';
  /** 字号 */
  textSize: number = 14;
  /** 字色（@Prop：主题切换后随父组件同步刷新） */
  @Prop textColor: string = '#000000';
  /** 是否加粗 */
  isBold: boolean = false;
  /** 撑满父容器宽度（用于需要换行的段落文本） */
  fillWidth: boolean = false;
  /** 水平居中 */
  centerText: boolean = false;
  /** 行高 */
  lineHeightNum: number = 0;
  /** 字距 */
  letterSpacingNum: number = 0;
  /** 左边距百分比（如启动标语缩进），0 表示无 */
  marginLeftPct: number = 0;

  private weight(): FontWeight {
    return this.isBold ? FontWeight.Bold : FontWeight.Normal;
  }

  private marginLeft(): string {
    return this.marginLeftPct + '%';
  }

  private lineHeight(): number {
    return this.lineHeightNum > 0 ? this.lineHeightNum : this.textSize + 6;
  }

  private spacing(): number {
    return this.letterSpacingNum > 0 ? this.letterSpacingNum : 0;
  }

  private tAlign(): TextAlign {
    return this.centerText ? TextAlign.Center : TextAlign.Start;
  }

  build() {
    if (this.fillWidth) {
      Text(this.content)
        .fontFamily(AppFonts.family())
        .fontSize(this.textSize)
        .fontColor(this.textColor)
        .fontWeight(this.weight())
        .width('100%')
        .textAlign(this.tAlign())
        .lineHeight(this.lineHeight())
        .letterSpacing(this.spacing())
        .margin({ left: this.marginLeft() })
    } else {
      Text(this.content)
        .fontFamily(AppFonts.family())
        .fontSize(this.textSize)
        .fontColor(this.textColor)
        .fontWeight(this.weight())
        .textAlign(this.tAlign())
        .lineHeight(this.lineHeight())
        .letterSpacing(this.spacing())
        .margin({ left: this.marginLeft() })
    }
  }
}
