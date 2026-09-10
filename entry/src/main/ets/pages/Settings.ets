/**
 * 设置页：语言（下拉）、主题（下拉：浅色/深色/跟随系统）、关于、AGPL 与水印
 */
import common from '@ohos.app.ability.common';
import Want from '@ohos.app.ability.Want';
import promptAction from '@ohos.promptAction';
import { I18n } from '../common/I18n';
import { AppTheme } from '../common/AppTheme';
import { AppFonts } from '../common/AppFonts';
import { AppSettings } from '../common/AppSettings';
import { PageHeader } from '../common/components/PageHeader';

/** 开源仓库地址（GitCode），点击后经系统浏览器打开 */
const REPO_URL: string = 'https://gitcode.com/RTX6090/Techingmaster';

@Component
export struct SettingsContent {
  @StorageLink('appLang') appLang: string = 'zh';
  @StorageLink('appTheme') appTheme: string = 'system';
  @StorageProp('appResolvedTheme') resolvedTheme: string = 'light';
  /** 生成结果自动保存到历史（默认开） */
  @StorageLink('autoSaveHist') autoSave: boolean = true;
  /** 应用内字号倍率（作用于全部 fp 文字） */
  @StorageLink('fontScale') fontScale: number = 1.0;
  /** 字号档位选中下标（0..3，对应 AppSettings.FONT_PRESETS） */
  @State selFontIdx: number = 1;

  private t(key: string): string {
    void this.appLang;
    return I18n.t(key);
  }

  private col(key: string): string {
    void this.resolvedTheme;
    return AppTheme.color(key, this.resolvedTheme);
  }

  /** 进入设置页即确保内置字体已注册（进程内仅一次），避免切换语言后文字空白 */
  aboutToAppear(): void {
    this.ensureFonts();
    this.selFontIdx = this.fontPresetIndex();
  }

  private ensureFonts(): void {
    if (AppStorage.get<boolean>('revFontsReg') === true) {
      return;
    }
    try {
      this.getUIContext().getFont().registerFont({
        familyName: AppFonts.TIBETAN,
        familySrc: $rawfile('fonts/ctrc-uchen.ttf')
      });
      this.getUIContext().getFont().registerFont({
        familyName: AppFonts.UYGHUR,
        familySrc: $rawfile('fonts/UKIJMejT.ttf')
      });
      this.getUIContext().getFont().registerFont({
        familyName: AppFonts.MONGOLIAN,
        familySrc: $rawfile('fonts/c8abb3845e34a252fcf04f0cd4e74a00.ttf')
      });
    } catch (e) {
      // 注册失败时回退系统字体
    }
    AppStorage.setOrCreate('revFontsReg', true);
  }

  /** 支持的语言代码（顺序与下拉选项一致） */
  private langCodes(): string[] {
    return ['zh', 'en', 'ug', 'bo', 'mn'];
  }

  /** 语言下拉选项（按当前界面语言显示各语言的名称） */
  private langOptions(): SelectOption[] {
    const codes: string[] = this.langCodes();
    const opts: SelectOption[] = [];
    for (let i = 0; i < codes.length; i++) {
      const opt: SelectOption = { value: this.t('langName.' + codes[i]) };
      opts.push(opt);
    }
    return opts;
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
    const idx: number = this.langCodes().indexOf(this.appLang);
    return idx >= 0 ? idx : 0;
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
      const langName: string = I18n.t('langName.' + lang);
      promptAction.showToast({ message: I18n.t('toast.lang').replace('{lang}', langName) });
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

  /** 切换“自动保存到历史” */
  private switchAutoSave(on: boolean): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    AppSettings.saveAutoSave(ctx, on).then(() => {
      // 开关即时生效，无需额外提示
    });
  }

  /** 当前已应用字号在档位中的下标（未命中默认"标准"档） */
  private fontPresetIndex(): number {
    const presets: number[] = AppSettings.FONT_PRESETS;
    for (let i = 0; i < presets.length; i++) {
      if (Math.abs(presets[i] - this.fontScale) < 0.001) {
        return i;
      }
    }
    return 1;
  }

  /** 字号档位标签（与 AppSettings.FONT_PRESETS 顺序一致） */
  private fontLabel(idx: number): string {
    if (idx === 0) {
      return this.t('set.fontSmall');
    }
    if (idx === 2) {
      return this.t('set.fontLarge');
    }
    if (idx === 3) {
      return this.t('set.fontXl');
    }
    return this.t('set.fontStandard');
  }

  /** 点击"应用"：持久化并全局应用所选字号倍率 */
  private applyFontSize(): void {
    const presets: number[] = AppSettings.FONT_PRESETS;
    const ctx = getContext(this) as common.UIAbilityContext;
    AppSettings.saveFontScale(ctx, presets[this.selFontIdx]).then((ok: boolean) => {
      promptAction.showToast({
        message: ok ? I18n.t('toast.fontApplied') : I18n.t('err.fontUnsupported')
      });
    });
  }

  /**
   * 预览字号换算：在当前"已应用倍率"下渲染出"目标档位"的绝对视觉效果
   * （页面文字本身也随已应用倍率缩放，故需按 cur/target 反向折算字号值）
   */
  private previewSize(base: number): number {
    const cur: number = this.fontScale > 0 ? this.fontScale : 1.0;
    const target: number = AppSettings.FONT_PRESETS[this.selFontIdx];
    return Math.round(base * (target / cur) * 100) / 100;
  }

  /** 打开系统浏览器访问开源仓库，鼓励用户点亮 Star */
  private openRepo(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    const want: Want = {
      action: 'ohos.want.action.viewData',
      entities: ['entity.system.browsable'],
      uri: REPO_URL
    };
    ctx.startAbility(want).then(() => {
      promptAction.showToast({ message: I18n.t('set.repoToast') });
    }).catch(() => {
      promptAction.showToast({ message: I18n.t('err.openBrowser') });
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
              .fontFamily(AppFonts.family())
              .fontSize(13)
              .fontColor(this.col('sub'))
              .width('100%')
            Select(this.langOptions())
              .selected(this.langIndex())
              .value(this.langOptions()[this.langIndex()].value as string)
              .fontColor(this.col('text'))
              .selectedOptionFontColor('#4A90D9')
              .width('100%')
              .onSelect((index: number) => {
                const codes: string[] = this.langCodes();
                this.switchLang(codes[index]);
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
              .fontFamily(AppFonts.family())
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

          // 字号大小（选择档位 + 预览，点"应用"全局生效）
          Column({ space: 12 }) {
            Column({ space: 4 }) {
              Text(this.t('set.fontScale'))
                .fontFamily(AppFonts.family())
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.col('title'))
                .width('100%')
              Text(this.t('set.fontDesc'))
                .fontFamily(AppFonts.family())
                .fontSize(12)
                .fontColor(this.col('hint'))
                .lineHeight(18)
                .width('100%')
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            // 档位选择（小 / 标准 / 大 / 特大）
            Row({ space: 8 }) {
              ForEach([0, 1, 2, 3], (idx: number) => {
                Button(this.fontLabel(idx))
                  .fontFamily(AppFonts.family())
                  .fontSize(13)
                  .height(38)
                  .layoutWeight(1)
                  .backgroundColor(this.selFontIdx === idx ? '#4A90D9' : this.col('inputBg'))
                  .fontColor(this.selFontIdx === idx ? '#FFFFFF' : this.col('text'))
                  .onClick(() => {
                    this.selFontIdx = idx;
                  })
              }, (idx: number) => idx.toString())
            }
            .width('100%')
            // 预览（随所选档位即时变化）
            Column({ space: 6 }) {
              Text('Aa')
                .fontFamily(AppFonts.family())
                .fontSize(this.previewSize(26))
                .fontWeight(FontWeight.Bold)
                .fontColor(this.col('title'))
                .width('100%')
              Text(this.t('set.fontPreview'))
                .fontFamily(AppFonts.family())
                .fontSize(this.previewSize(15))
                .fontColor(this.col('text'))
                .lineHeight(this.previewSize(22))
                .width('100%')
            }
            .width('100%')
            .padding(14)
            .backgroundColor(this.col('inputBg'))
            .borderRadius(12)
            .alignItems(HorizontalAlign.Start)
            // 应用
            Row() {
              Blank()
              Button(this.t('set.fontApply'))
                .fontFamily(AppFonts.family())
                .fontSize(14)
                .height(38)
                .width(104)
                .backgroundColor('#4A90D9')
                .onClick(() => {
                  this.applyFontSize();
                })
            }
            .width('100%')
          }
          .width('100%')
          .padding(16)
          .backgroundColor(this.col('card'))
          .borderRadius(14)
          .alignItems(HorizontalAlign.Start)

          // 自动保存到历史
          Column({ space: 10 }) {
            Row({ space: 8 }) {
              Column({ space: 4 }) {
                Text(this.t('set.autoSaveHistory'))
                  .fontFamily(AppFonts.family())
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.col('title'))
                  .width('100%')
                Text(this.t('set.autoSaveHint'))
                  .fontFamily(AppFonts.family())
                  .fontSize(12)
                  .fontColor(this.col('hint'))
                  .lineHeight(18)
                  .width('100%')
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.autoSave })
                .selectedColor('#4A90D9')
                .onChange((isOn: boolean) => {
                  this.switchAutoSave(isOn);
                })
            }
            .width('100%')
          }
          .width('100%')
          .padding(16)
          .backgroundColor(this.col('card'))
          .borderRadius(14)
          .alignItems(HorizontalAlign.Start)

          // 关于
          Column({ space: 8 }) {
            Text(this.t('set.about'))
              .fontFamily(AppFonts.family())
              .fontSize(13)
              .fontColor(this.col('sub'))
              .width('100%')
            Text(this.t('set.aboutName'))
              .fontFamily(AppFonts.family())
              .fontSize(17)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.col('title'))
              .width('100%')
            Text(this.t('set.version'))
              .fontFamily(AppFonts.family())
              .fontSize(13)
              .fontColor(this.col('hint'))
              .width('100%')
            Text(this.t('set.aboutDesc'))
              .fontFamily(AppFonts.family())
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
              .fontFamily(AppFonts.family())
              .fontSize(13)
              .fontColor(this.col('sub'))
              .width('100%')
            Text('AGPL-3.0')
              .fontFamily(AppFonts.family())
              .fontSize(15)
              .fontWeight(FontWeight.Bold)
              .fontColor('#D9534F')
              .width('100%')
            Text(this.t('set.agpl'))
              .fontFamily(AppFonts.family())
              .fontSize(13)
              .fontColor(this.col('text'))
              .lineHeight(20)
              .width('100%')
            Text('https://www.gnu.org/licenses/agpl-3.0.html')
              .fontFamily(AppFonts.family())
              .fontSize(12)
              .fontColor('#4A90D9')
              .width('100%')
            Text(this.t('set.repoTitle'))
              .fontFamily(AppFonts.family())
              .fontSize(13)
              .fontColor(this.col('sub'))
              .width('100%')
              .margin({ top: 6 })
            Text(REPO_URL)
              .fontFamily(AppFonts.family())
              .fontSize(13)
              .fontColor('#4A90D9')
              .decoration({ type: TextDecorationType.Underline, color: '#4A90D9' })
              .width('100%')
              .onClick(() => {
                this.openRepo();
              })
            Text(this.t('set.starTip'))
              .fontFamily(AppFonts.family())
              .fontSize(12)
              .fontColor(this.col('hint'))
              .lineHeight(18)
              .width('100%')
          }
          .width('100%')
          .padding(16)
          .backgroundColor(this.col('card'))
          .borderRadius(14)
          .alignItems(HorizontalAlign.Start)

          Text(this.t('set.themeHint'))
            .fontFamily(AppFonts.family())
            .fontSize(12)
            .fontColor(this.col('hint'))
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding({ top: 4 })

          // 底部水印
          Text(this.t('watermark'))
            .fontFamily(AppFonts.family())
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


@Entry
@Component
struct SettingsEntry {
  build() {
    Column() {
      SettingsContent()
    }
    .width('100%')
    .height('100%')
  }

  pageTransition() {
    PageTransitionEnter({ duration: 300, curve: Curve.EaseInOut })
      .slide(SlideEffect.Right)
    PageTransitionExit({ duration: 260, curve: Curve.EaseInOut })
      .slide(SlideEffect.Left)
  }
}
