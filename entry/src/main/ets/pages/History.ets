/**
 * 历史记录页：展示全部已保存的生成记录（支持中英双语与深浅主题）
 */
import common from '@ohos.app.ability.common';
import promptAction from '@ohos.promptAction';
import pasteboard from '@ohos.pasteboard';
import { HistoryStore, HistoryRecord } from '../common/HistoryStore';
import { I18n } from '../common/I18n';
import { AppTheme } from '../common/AppTheme';
import { AppFonts } from '../common/AppFonts';
import { DocxExporter } from '../common/DocxExporter';
import { PageHeader } from '../common/components/PageHeader';
import { RichBox } from '../common/components/RichBox';
import { RichHtml } from '../common/RichHtml';

/** 历史记录详情弹窗 */
@CustomDialog
struct HistoryDetailDialog {
  controller: CustomDialogController = new CustomDialogController({ builder: undefined });
  @Link title: string;
  @Link content: string;
  @StorageProp('appResolvedTheme') resolvedTheme: string = 'light';
  @StorageProp('appLang') appLang: string = 'zh';

  private t(key: string): string {
    void this.appLang;
    return I18n.t(key);
  }

  private col(key: string): string {
    void this.resolvedTheme;
    return AppTheme.color(key, this.resolvedTheme);
  }

  private copyContent(): void {
    if (this.content === '') {
      return;
    }
    const sysPaste = pasteboard.getSystemPasteboard();
    const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, RichHtml.toPlain(this.content));
    sysPaste.setData(data).then(() => {
      promptAction.showToast({ message: I18n.t('toast.copied') });
    }).catch(() => {
      promptAction.showToast({ message: I18n.t('err.copyFail') });
    });
  }

  private exportContent(): void {
    if (this.content === '') {
      return;
    }
    const ctx = getContext(this) as common.UIAbilityContext;
    const safeTitle: string = this.title === '' ? 'History' : this.title;
    DocxExporter.exportDocx(ctx, this.content, safeTitle + '.docx').catch((err: Error) => {
      promptAction.showToast({ message: I18n.t('err.exportFail') + err.message });
    });
  }

  build() {
    Column({ space: 12 }) {
      Text(this.title)
        .fontFamily(AppFonts.family())
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.col('title'))
        .width('100%')
      Scroll() {
        if (this.content === '') {
          Text('No content')
            .fontFamily(AppFonts.family())
            .fontSize(14)
            .fontColor(this.col('hint'))
        } else {
          RichBox({ html: this.content })
            .width('100%')
        }
      }
      .width('100%')
      .layoutWeight(1)
      .backgroundColor(this.col('bg'))
      .borderRadius(10)
      .padding(10)
      .scrollBar(BarState.Auto)
      Row({ space: 10 }) {
        Button(this.t('btn.exportWord'))
          .fontFamily(AppFonts.family())
          .fontSize(14)
          .height(40)
          .layoutWeight(1)
          .backgroundColor('#2F6DB5')
          .onClick(() => this.exportContent())
        Button(this.t('btn.copy'))
          .fontFamily(AppFonts.family())
          .fontSize(14)
          .height(40)
          .layoutWeight(1)
          .backgroundColor('#4A90D9')
          .onClick(() => this.copyContent())
      }
      .width('100%')
      Button(this.t('btn.close'))
        .fontFamily(AppFonts.family())
        .width('100%')
        .backgroundColor('#4A90D9')
        .onClick(() => {
          this.controller.close();
        })
    }
    .width('90%')
    .padding(18)
    .backgroundColor(this.col('card'))
    .borderRadius(16)
  }
}

@Component
export struct HistoryContent {
  @State records: HistoryRecord[] = [];
  @State dialogTitle: string = '';
  @State dialogContent: string = '';
  @StorageProp('appLang') appLang: string = 'zh';
  @StorageProp('appResolvedTheme') resolvedTheme: string = 'light';
  private dialogController: CustomDialogController =
    new CustomDialogController({
      builder: HistoryDetailDialog({
        title: $dialogTitle,
        content: $dialogContent
      }),
      autoCancel: true
    });

  private t(key: string): string {
    void this.appLang;
    return I18n.t(key);
  }

  private col(key: string): string {
    void this.resolvedTheme;
    return AppTheme.color(key, this.resolvedTheme);
  }

  aboutToAppear(): void {
    this.loadRecords();
  }

  /** 页面显示时刷新 */
  onPageShow(): void {
    this.loadRecords();
  }

  loadRecords(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    HistoryStore.getRecords(ctx).then((list: HistoryRecord[]) => {
      this.records = list;
    });
  }

  /** 查看历史详情 */
  showDetail(record: HistoryRecord): void {
    this.dialogTitle = record.title;
    this.dialogContent = record.content;
    this.dialogController.open();
  }

  /** 清空历史 */
  clearAll(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    HistoryStore.clearRecords(ctx).then(() => {
      this.records = [];
      promptAction.showToast({ message: I18n.t('toast.cleared') });
    });
  }

  build() {
    Column({ space: 10 }) {
      PageHeader({ title: this.t('hist.title') })

      Row() {
        Text(this.t('hist.count').replace('{n}', this.records.length.toString()))
          .fontFamily(AppFonts.family())
          .fontSize(13)
          .fontColor(this.col('sub'))
        Blank()
        Button(this.t('btn.clear'))
          .fontFamily(AppFonts.family())
          .fontSize(13)
          .height(30)
          .backgroundColor(this.col('headBg'))
          .fontColor(this.col('sub'))
          .onClick(() => {
            AlertDialog.show({
              title: this.t('hist.clearTitle'),
              message: this.t('hist.clearMsg'),
              primaryButton: {
                value: this.t('btn.close'), action: () => {}
              },
              secondaryButton: {
                value: this.t('btn.clear'), fontColor: '#DC2626',
                action: () => this.clearAll()
              }
            });
          })
      }
      .width('100%')

      if (this.records.length === 0) {
        Column({ space: 8 }) {
          Text(this.t('hist.empty'))
            .fontFamily(AppFonts.family())
            .fontSize(15)
            .fontColor(this.col('hint'))
          Text(this.t('hist.hint'))
            .fontFamily(AppFonts.family())
            .fontSize(12)
            .fontColor(this.col('faint'))
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: 10 }) {
          ForEach(this.records, (record: HistoryRecord) => {
            ListItem() {
              Row({ space: 12 }) {
                Text(record.type)
                  .fontFamily(AppFonts.family())
                  .fontSize(12)
                  .fontColor('#2B4C7E')
                  .backgroundColor('#E8F1FB')
                  .borderRadius(6)
                  .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                Column({ space: 4 }) {
                  Text(record.title)
                    .fontFamily(AppFonts.family())
                    .fontSize(15)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(this.col('title'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(record.time)
                    .fontFamily(AppFonts.family())
                    .fontSize(11)
                    .fontColor(this.col('hint'))
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                Text(this.t('hist.view'))
                  .fontFamily(AppFonts.family())
                  .fontSize(13)
                  .fontColor('#4A90D9')
              }
              .width('100%')
              .padding(14)
              .backgroundColor(this.col('card'))
              .borderRadius(12)
              .shadow({ radius: 6, color: 'rgba(0,0,0,0.05)', offsetY: 2 })
              .onClick(() => this.showDetail(record))
            }
          }, (record: HistoryRecord) => record.time + record.title)
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
    .padding(16)
    .backgroundColor(this.col('bg'))
  }
}


@Entry
@Component
struct HistoryEntry {
  build() {
    Column() {
      HistoryContent()
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
