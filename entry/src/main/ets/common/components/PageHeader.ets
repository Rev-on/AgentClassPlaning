/**
 * 通用页面标题栏：返回按钮 + 标题（支持深浅主题）
 */
import router from '@ohos.router';
import { AppTheme } from '../AppTheme';
import { AppFonts } from '../AppFonts';
import { VerticalMongolianText } from './VerticalMongolianText';

@Component
export struct PageHeader {
  @Prop title: string = '';
  @StorageProp('appResolvedTheme') resolvedTheme: string = 'light';
  /** 平板/横屏两栏布局：右栏内嵌页面时自动隐藏返回按钮（由 AppStorage('appWideLayout') 驱动） */
  @StorageProp('appWideLayout') wideLayout: boolean = false;

  private col(key: string): string {
    void this.resolvedTheme;
    return AppTheme.color(key, this.resolvedTheme);
  }

  build() {
    Row({ space: 10 }) {
      if (!this.wideLayout) {
        Button('←')
          .fontFamily(AppFonts.family())
          .fontSize(18)
          .fontColor(this.col('title'))
          .backgroundColor(this.col('card'))
          .width(40)
          .height(40)
          .borderRadius(20)
          .onClick(() => {
            router.back();
          })
      }
      VerticalMongolianText({
        content: this.title,
        textSize: 20,
        textColor: this.col('title'),
        isBold: true
      })
    }
    .width('100%')
    .padding({ left: 4, right: 4, top: 6, bottom: 6 })
  }
}
