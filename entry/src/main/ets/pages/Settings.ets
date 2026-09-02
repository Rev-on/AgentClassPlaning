/**
 * 设置页：语言（下拉）、主题（下拉：浅色/深色/跟随系统）、关于、AGPL 与水印
 */
import common from '@ohos.app.ability.common';
import promptAction from '@ohos.promptAction';
import { I18n } from '../common/I18n';
import { AppTheme } from '../common/AppTheme';
import { AppSettings } from '../common/AppSettings';
import { PageHeader } from '../common/components/PageHeader';

@Entry
@Component
struct Settings {
  @StorageLink('appLang') appLang: string = 'zh';
  @StorageLink('appTheme') appTheme: string = 'light';
  @StorageProp('appResolvedTheme') resolvedTheme: string = 'light';

  private t(key: string): string {
    void this.appLang;
    return I18n.t(key);
  }

  private col(key: string): string {
    void this.resolvedTheme;
    return AppTheme.color(key, this.resolvedTheme);
  }

  /** 语言下拉选项 */
  private langOptions(): SelectOption[] {
    return [
      { value: '简体中文' },
      { value: 'English' }
    ];
  }

  /** 主题下拉选项 */
  private themeOptions(): SelectOption[] {
    return [
      { value: this.t('set.themeLight') },
      { value: this.t('set.themeDark') },
      { value: this.t('set.themeSystem') }
    ];
  }

  private langIndex(): number {
    return this.appLang === 'en' ? 1 : 0;
  }

  private themeIndex(): number {
    if (this.appTheme === 'dark') {
      return 1;
    }
    if (this.appTheme === 'system') {
      return 2;
    }
    return 0;
  }

  /** 切换语言 */
  private switchLang(lang: string): void {
    if (this.appLang === lang) {
      return;
    }
    const ctx = getContext(this) as common.UIAbilityContext;
    AppSettings.saveLang(ctx, lang).then(() => {
      promptAction.showToast({ message: lang === 'zh' ? '已切换为简体中文' : 'Switched to English' });
    });
  }

  /** 切换主题 */
  private switchTheme(theme: string): void {
    if (this.appTheme === theme) {
      return;
    }
    const ctx = getContext(this) as common.UIAbilityContext;
    AppSettings.saveTheme(ctx, theme).then(() => {
      promptAction.showToast({ message: I18n.t('set.themeHint') });
    });
  }

  build() {
    Column({ space: 12 }) {
      PageHeader({ title: this.t('set.title') })

      Scroll() {
        Column({ space: 12 }) {
          // 语言
          Column({ space: 10 }) {
            Text(this.t('set.language'))
              .fontSize(13)
              .fontColor(this.col('sub'))
              .width('100%')
            Select(this.langOptions())
              .selected(this.langIndex())
              .value(this.langIndex() === 0 ? '简体中文' : 'English')
              .fontColor(this.col('text'))
              .selectedOptionFontColor('#4A90D9')
              .width('100%')
              .onSelect((index: number) => {
                this.switchLang(index === 0 ? 'zh' : 'en');
              })
          }
          .width('100%')
          .padding(16)
          .backgroundColor(this.col('card'))
          .borderRadius(14)
          .alignItems(HorizontalAlign.Start)

          // 主题
          Column({ space: 10 }) {
            Text(this.t('set.theme'))
              .fontSize(13)
              .fontColor(this.col('sub'))
              .width('100%')
            Select(this.themeOptions())
              .selected(this.themeIndex())
              .value(this.themeOptions()[this.themeIndex()].value as string)
              .fontColor(this.col('text'))
              .selectedOptionFontColor('#4A90D9')
              .width('100%')
              .onSelect((index: number) => {
                const themes: string[] = ['light', 'dark', 'system'];
                this.switchTheme(themes[index]);
              })
          }
          .width('100%')
          .padding(16)
          .backgroundColor(this.col('card'))
          .borderRadius(14)
          .alignItems(HorizontalAlign.Start)

          // 关于
          Column({ space: 8 }) {
            Text(this.t('set.about'))
              .fontSize(13)
              .fontColor(this.col('sub'))
              .width('100%')
            Text(this.t('set.aboutName'))
              .fontSize(17)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.col('title'))
              .width('100%')
            Text(this.t('set.version'))
              .fontSize(13)
              .fontColor(this.col('hint'))
              .width('100%')
            Text(this.t('set.aboutDesc'))
              .fontSize(14)
              .fontColor(this.col('text'))
              .lineHeight(22)
              .width('100%')
          }
          .width('100%')
          .padding(16)
          .backgroundColor(this.col('card'))
          .borderRadius(14)
          .alignItems(HorizontalAlign.Start)

          // 开源协议
          Column({ space: 8 }) {
            Text(this.t('set.license'))
              .fontSize(13)
              .fontColor(this.col('sub'))
              .width('100%')
            Text('AGPL-3.0')
              .fontSize(15)
              .fontWeight(FontWeight.Bold)
              .fontColor('#D9534F')
              .width('100%')
            Text(this.t('set.agpl'))
              .fontSize(13)
              .fontColor(this.col('text'))
              .lineHeight(20)
              .width('100%')
            Text('https://www.gnu.org/licenses/agpl-3.0.html')
              .fontSize(12)
              .fontColor('#4A90D9')
              .width('100%')
          }
          .width('100%')
          .padding(16)
          .backgroundColor(this.col('card'))
          .borderRadius(14)
          .alignItems(HorizontalAlign.Start)

          Text(this.t('set.themeHint'))
            .fontSize(12)
            .fontColor(this.col('hint'))
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding({ top: 4 })

          // 底部水印
          Text(this.t('watermark'))
            .fontSize(11)
            .fontColor(this.col('faint'))
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding({ top: 8, bottom: 16 })
        }
        .width('100%')
        .padding(16)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
    }
    .width('100%')
    .height('100%')
    .padding(12)
    .backgroundColor(this.col('bg'))
  }
}
