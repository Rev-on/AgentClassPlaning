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

/** 批量删除确认框：取消=白底按钮，删除=红色按钮；删除键需等待 2 秒后才可点击 */
@CustomDialog
struct DeleteHistoryDialog {
  controller: CustomDialogController = new CustomDialogController({ builder: undefined });
  @Link title: string;
  @Link message: string;
  /** 确认回调 */
  onConfirm: () => void = () => {
  };
  @State remain: number = 0;
  @StorageProp('appLang') appLang: string = 'zh';
  @StorageProp('appResolvedTheme') resolvedTheme: string = 'light';
  private tickTimer: number = -1;

  aboutToAppear(): void {
    this.remain = 2;
    if (this.tickTimer === -1) {
      this.tickTimer = setInterval(() => {
        if (this.remain > 0) {
          this.remain--;
        }
        if (this.remain <= 0 && this.tickTimer !== -1) {
          clearInterval(this.tickTimer);
          this.tickTimer = -1;
        }
      }, 1000);
    }
  }

  aboutToDisappear(): void {
    if (this.tickTimer !== -1) {
      clearInterval(this.tickTimer);
      this.tickTimer = -1;
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

  private stopTick(): void {
    if (this.tickTimer !== -1) {
      clearInterval(this.tickTimer);
      this.tickTimer = -1;
    }
  }

  build() {
    Column({ space: 14 }) {
      Text(this.title)
        .fontFamily(AppFonts.family())
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.col('title'))
        .width('100%')
      Text(this.message)
        .fontFamily(AppFonts.family())
        .fontSize(14)
        .fontColor(this.col('text'))
        .lineHeight(21)
        .width('100%')
      Row({ space: 12 }) {
        Button(this.t('btn.cancel'))
          .fontFamily(AppFonts.family())
          .fontSize(15)
          .height(40)
          .layoutWeight(1)
          .backgroundColor('#FFFFFF')
          .fontColor('#1B1B1F')
          .border({ width: 1, color: '#E3E6EB' })
          .onClick(() => {
            this.stopTick();
            this.controller.close();
          })
        Button(this.t('btn.delete') + (this.remain > 0 ? '（' + this.remain + 's）' : ''))
          .fontFamily(AppFonts.family())
          .fontSize(15)
          .height(40)
          .layoutWeight(1)
          .backgroundColor('#DC2626')
          .fontColor(Color.White)
          .enabled(this.remain <= 0)
          .opacity(this.remain <= 0 ? 1 : 0.5)
          .onClick(() => {
            if (this.remain > 0) {
              return;
            }
            this.stopTick();
            this.controller.close();
            this.onConfirm();
          })
      }
      .width('100%')
    }
    .width('86%')
    .padding(20)
    .backgroundColor(this.col('card'))
    .borderRadius(16)
    .alignItems(HorizontalAlign.Start)
  }
}

@Component
export struct HistoryContent {
  @State records: HistoryRecord[] = [];
  @State dialogTitle: string = '';
  @State dialogContent: string = '';
  /** 多选删除状态 */
  @State multi: boolean = false;
  @State picked: Set<string> = new Set<string>();
  /** 页内删除确认遮罩（自绘层，规避系统对话框闪退） */
  @State showDel: boolean = false;
  @State delRemain: number = 2;
  private delTimer: number = -1;
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

  // ============ 长按多选与批量删除 ============

  /** 长按进入多选并选中该条 */
  private enterMulti(record: HistoryRecord): void {
    this.multi = true;
    const s: Set<string> = new Set<string>();
    s.add(HistoryStore.keyOf(record));
    this.picked = s;
  }

  /** 多选模式下点按切换选中 */
  private togglePick(key: string): void {
    const s: Set<string> = new Set<string>(this.picked);
    if (s.has(key)) {
      s.delete(key);
    } else {
      s.add(key);
    }
    this.picked = s;
  }

  /** 退出多选 */
  private exitMulti(): void {
    this.multi = false;
    this.picked = new Set<string>();
  }

  /** 点击删除：显示页内确认遮罩（删除键 2 秒后可确认） */
  private openDeleteSelected(): void {
    if (this.picked.size === 0) {
      promptAction.showToast({ message: I18n.t('hist.chooseHint') });
      return;
    }
    this.showDel = true;
    this.delRemain = 2;
    this.startDelTimer();
  }

  private startDelTimer(): void {
    if (this.delTimer !== -1) {
      return;
    }
    this.delTimer = setInterval(() => {
      if (this.delRemain > 0) {
        this.delRemain--;
      }
      if (this.delRemain <= 0) {
        this.stopDelTimer();
      }
    }, 1000);
  }

  private stopDelTimer(): void {
    if (this.delTimer !== -1) {
      clearInterval(this.delTimer);
      this.delTimer = -1;
    }
  }

  /** 取消删除：返回多选状态 */
  private cancelDelete(): void {
    this.stopDelTimer();
    this.showDel = false;
  }

  aboutToDisappear(): void {
    this.stopDelTimer();
  }

  /** 确认删除所选记录 */
  private doDeleteSelected(): void {
    this.stopDelTimer();
    const ctx = getContext(this) as common.UIAbilityContext;
    const keys: string[] = [];
    this.picked.forEach((k: string) => {
      keys.push(k);
    });
    this.exitMulti();
    this.showDel = false;
    HistoryStore.removeRecords(ctx, keys).then(() => {
      this.loadRecords();
      promptAction.showToast({ message: I18n.t('toast.delDone') });
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

  /** 删除确认遮罩层（自绘：白底取消 + 红色删除，删除键 2 秒冷却） */
  @Builder
  deleteConfirmOverlay() {
    Column() {
      Column({ space: 14 }) {
        Text(this.t('hist.delTitle'))
          .fontFamily(AppFonts.family())
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.col('title'))
          .width('100%')
        Text(this.t('hist.delMsg').replace('{n}', this.picked.size.toString()))
          .fontFamily(AppFonts.family())
          .fontSize(14)
          .fontColor(this.col('text'))
          .lineHeight(21)
          .width('100%')
        Row({ space: 12 }) {
          Button(this.t('btn.cancel'))
            .fontFamily(AppFonts.family())
            .fontSize(15)
            .height(40)
            .layoutWeight(1)
            .backgroundColor('#FFFFFF')
            .fontColor('#1B1B1F')
            .border({ width: 1, color: '#E3E6EB' })
            .onClick(() => {
              this.cancelDelete();
            })
          Button(this.t('btn.delete') + (this.delRemain > 0 ? '（' + this.delRemain + 's）' : ''))
            .fontFamily(AppFonts.family())
            .fontSize(15)
            .height(40)
            .layoutWeight(1)
            .backgroundColor('#DC2626')
            .fontColor(Color.White)
            .enabled(this.delRemain <= 0)
            .opacity(this.delRemain <= 0 ? 1 : 0.5)
            .onClick(() => {
              if (this.delRemain <= 0) {
                this.doDeleteSelected();
              }
            })
        }
        .width('100%')
      }
      .width('86%')
      .padding(20)
      .backgroundColor(this.col('card'))
      .borderRadius(16)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor('rgba(0,0,0,0.45)')
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column({ space: 10 }) {
        PageHeader({ title: this.t('hist.title') })

      if (this.multi) {
        Row({ space: 10 }) {
          Text(this.t('hist.multiTitle').replace('{n}', this.picked.size.toString()))
            .fontFamily(AppFonts.family())
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.col('title'))
            .layoutWeight(1)
          Button(this.t('btn.cancel'))
            .fontFamily(AppFonts.family())
            .fontSize(13)
            .height(30)
            .backgroundColor(this.col('headBg'))
            .fontColor(this.col('sub'))
            .onClick(() => {
              this.exitMulti();
            })
          Button(this.t('btn.delete'))
            .fontFamily(AppFonts.family())
            .fontSize(13)
            .height(30)
            .backgroundColor('#DC2626')
            .fontColor(Color.White)
            .onClick(() => {
              this.openDeleteSelected();
            })
        }
        .width('100%')
      } else {
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
      }

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
                if (this.multi) {
                  Column() {
                    Text(this.picked.has(HistoryStore.keyOf(record)) ? '✓' : '')
                      .fontFamily(AppFonts.family())
                      .fontSize(14)
                      .fontColor(Color.White)
                  }
                  .width(24)
                  .height(24)
                  .justifyContent(FlexAlign.Center)
                  .borderRadius(12)
                  .backgroundColor(this.picked.has(HistoryStore.keyOf(record)) ? '#4A90D9' : this.col('inputBg'))
                  .border({ width: this.picked.has(HistoryStore.keyOf(record)) ? 0 : 1, color: '#C9CED6' })
                } else {
                  Text(this.t('hist.view'))
                    .fontFamily(AppFonts.family())
                    .fontSize(13)
                    .fontColor('#4A90D9')
                }
              }
              .width('100%')
              .padding(14)
              .backgroundColor(this.picked.has(HistoryStore.keyOf(record)) ? this.col('inputBg') : this.col('card'))
              .borderRadius(12)
              .border({ width: this.picked.has(HistoryStore.keyOf(record)) ? 1.5 : 0, color: '#4A90D9' })
              .shadow({ radius: 6, color: 'rgba(0,0,0,0.05)', offsetY: 2 })
              .gesture(
                LongPressGesture({ repeat: false })
                  .onAction(() => {
                    if (!this.multi) {
                      this.enterMulti(record);
                    }
                  })
              )
              .onClick(() => {
                if (this.multi) {
                  this.togglePick(HistoryStore.keyOf(record));
                } else {
                  this.showDetail(record);
                }
              })
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

      if (this.showDel) {
        this.deleteConfirmOverlay()
      }
    }
    .width('100%')
    .height('100%')
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
