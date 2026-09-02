/**
 * 通用页面标题栏：返回按钮 + 标题（支持深浅主题）
 */
import router from '@ohos.router';
import { AppTheme } from '../AppTheme';

@Component
export struct PageHeader {
  title: string = '';
  @StorageProp('appResolvedTheme') resolvedTheme: string = 'light';

  private col(key: string): string {
    void this.resolvedTheme;
    return AppTheme.color(key, this.resolvedTheme);
  }

  build() {
    Row({ space: 10 }) {
      Button('←')
        .fontSize(18)
        .fontColor(this.col('title'))
        .backgroundColor(this.col('card'))
        .width(40)
        .height(40)
        .borderRadius(20)
        .onClick(() => {
          router.back();
        })
      Text(this.title)
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.col('title'))
    }
    .width('100%')
    .padding({ left: 4, right: 4, top: 6, bottom: 6 })
  }
}
