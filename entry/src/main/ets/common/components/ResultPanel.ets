/**
 * 通用结果展示组件：渲染 AI 生成结果，提供复制、导出 Word、保存到历史
 * 支持中英双语与深浅主题
 */
import pasteboard from '@ohos.pasteboard';
import promptAction from '@ohos.promptAction';
import common from '@ohos.app.ability.common';
import { I18n } from '../I18n';
import { AppTheme } from '../AppTheme';
import { AppFonts } from '../AppFonts';
import { MdView } from './MdView';
import { DocxExporter } from '../DocxExporter';

@Component
export struct ResultPanel {
  /** 生成结果文本 */
  @Prop result: string = '';
  /** 功能类型（保存历史用） */
  type: string = '';
  /** 记录标题（保存历史用） */
  title: string = '';
  /** 保存回调（由父页面实现写入历史库） */
  onSave: (() => void) = () => {};
  @StorageProp('appLang') appLang: string = 'zh';
  @StorageProp('appResolvedTheme') resolvedTheme: string = 'light';

  private t(key: string): string {
    void this.appLang;
    return I18n.t(key);
  }

  private col(key: string): string {
    void this.resolvedTheme;
    return AppTheme.color(key, this.resolvedTheme);
  }

  private copyText(): void {
    if (this.result === '') {
      return;
    }
    const sysPaste = pasteboard.getSystemPasteboard();
    const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.result);
    sysPaste.setData(data).then(() => {
      promptAction.showToast({ message: I18n.t('toast.copied') });
    }).catch(() => {
      promptAction.showToast({ message: I18n.t('err.copyFail') });
    });
  }

  /** 导出为 Word 文档 */
  private exportWord(): void {
    if (this.result === '') {
      return;
    }
    const ctx = getContext(this) as common.UIAbilityContext;
    const safeTitle: string = this.title === '' ? 'Result' : this.title;
    DocxExporter.exportDocx(ctx, this.result, safeTitle + '.docx').catch((err: Error) => {
      promptAction.showToast({ message: I18n.t('err.exportFail') + err.message });
    });
  }

  build() {
    Column({ space: 8 }) {
      Row() {
        Blank()
        Button(this.t('btn.copy'))
          .fontFamily(AppFonts.family())
          .fontSize(13)
          .height(30)
          .backgroundColor('#4A90D9')
          .onClick(() => this.copyText())
        Button(this.t('btn.exportWord'))
          .fontFamily(AppFonts.family())
          .fontSize(13)
          .height(30)
          .backgroundColor('#2F6DB5')
          .margin({ left: 8 })
          .onClick(() => this.exportWord())
        Button(this.t('btn.saveHist'))
          .fontFamily(AppFonts.family())
          .fontSize(13)
          .height(30)
          .backgroundColor('#5BA8A0')
          .margin({ left: 8 })
          .onClick(() => {
            if (this.result !== '') {
              this.onSave();
            }
          })
      }
      .width('100%')
      .padding({ left: 4, right: 4 })

      Scroll() {
        if (this.result === '') {
          Text('（结果将在这里显示）')
            .fontFamily(AppFonts.family())
            .fontSize(15)
            .fontColor(this.col('hint'))
            .width('100%')
        } else {
          MdView({ markdown: this.result })
            .width('100%')
        }
      }
      .width('100%')
      .layoutWeight(1)
      .backgroundColor(this.col('card'))
      .borderRadius(12)
      .padding(12)
      .align(Alignment.TopStart)
      .scrollBar(BarState.Auto)
    }
    .width('100%')
    .height('100%')
  }
}
