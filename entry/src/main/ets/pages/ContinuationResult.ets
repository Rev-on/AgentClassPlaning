/**
 * 流转接收页（目标端：平板 / 2in1）：
 * 从分布式软总线流转收件箱读取手机流转来的生成结果，整页可下滑，
 * 唤醒 RichEditor 富文本编辑继续修改，并支持复制 / 导出 / 保存历史 / 继续流转。
 */
import common from '@ohos.app.ability.common';
import promptAction from '@ohos.promptAction';
import { I18n } from '../common/I18n';
import { AppTheme } from '../common/AppTheme';
import { AppFonts } from '../common/AppFonts';
import { PageHeader } from '../common/components/PageHeader';
import { ResultPanel } from '../common/components/ResultPanel';
import { SafeInsets } from '../common/SafeInsets';
import { HistoryStore } from '../common/HistoryStore';
import { ContinuationService, ContinuePayload } from '../common/ContinuationService';

@Entry
@Component
struct ContinuationResult {
  @StorageProp('appLang') appLang: string = 'zh';
  @StorageProp('appResolvedTheme') resolvedTheme: string = 'light';
  /** 顶部状态栏/刘海避让高度（vp） */
  @State topInset: number = 0;
  /** 流转来的富文本结果 */
  @State result: string = '';
  /** 导出文件名/保存历史用标题 */
  @State title: string = '';
  /** 功能类型（保存历史用） */
  @State ftype: string = '';
  /** 导出模式：'word' | 'json' | 'pptx' */
  @State exportMode: string = 'word';
  /** 课件幻灯片预览（课件页流转过来时保持逐页渲染） */
  @State slideMode: boolean = false;

  aboutToAppear(): void {
    SafeInsets.topInset(getContext(this) as common.UIAbilityContext).then((v: number): void => {
      this.topInset = v;
    });
    const p: ContinuePayload | null = ContinuationService.takeInbox();
    if (p !== null) {
      this.result = p.html;
      this.title = p.title;
      this.ftype = p.type;
      this.exportMode = p.exportMode;
      this.slideMode = p.slideMode;
    }
  }

  private t(key: string): string {
    void this.appLang;
    return I18n.t(key);
  }

  private col(key: string): string {
    void this.resolvedTheme;
    return AppTheme.color(key, this.resolvedTheme);
  }

  /** 保存流转结果到历史 */
  private saveToHistory(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    const typeLabel: string = this.ftype !== '' ? this.ftype : I18n.t('cont.title');
    HistoryStore.addRecord(ctx, {
      type: typeLabel,
      title: this.title !== '' ? this.title : typeLabel,
      content: this.result,
      time: HistoryStore.formatNow()
    });
    promptAction.showToast({ message: I18n.t('toast.saved') });
  }

  build() {
    Column({ space: 0 }) {
      // 固定标题栏：预留顶部安全区（状态栏/刘海避让）
      Column() {
        PageHeader({ title: this.t('cont.title') })
      }
      .width('100%')
      .padding({ top: this.topInset })

      if (this.result === '') {
        Column({ space: 10 }) {
          Text(this.t('cont.empty'))
            .fontFamily(AppFonts.family())
            .fontSize(15)
            .fontColor(this.col('hint'))
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Scroll() {
          Column({ space: 12 }) {
            Row({ space: 6 }) {
              Text(this.t('cont.hint'))
                .fontFamily(AppFonts.family())
                .fontSize(12)
                .fontColor(this.col('sub'))
                .lineHeight(18)
            }
            .width('100%')

            ResultPanel({
              result: this.result,
              type: this.ftype,
              title: this.title,
              exportMode: this.exportMode,
              slideMode: this.slideMode,
              scrollPage: true,
              onSave: () => this.saveToHistory(),
              onEdited: (t: string): void => {
                if (t.trim() !== '') {
                  this.result = t;
                }
              }
            })
              .width('100%')
          }
          .width('100%')
          .padding(12)
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .align(Alignment.TopStart)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.col('bg'))
  }
}