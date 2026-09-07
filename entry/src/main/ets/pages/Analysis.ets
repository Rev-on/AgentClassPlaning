/**
 * 学情分析与报告：粘贴 Excel 成绩数据（Tab 分隔），AI 生成学情分析报告
 * 用法：在 Excel 中框选数据区域 → Ctrl+C 复制 → 长按本页输入框粘贴
 * 双语界面 + 深浅主题
 */
import common from '@ohos.app.ability.common';
import promptAction from '@ohos.promptAction';
import { AiService } from '../common/AiService';
import { Prompts } from '../common/Prompts';
import { HistoryStore } from '../common/HistoryStore';
import { I18n } from '../common/I18n';
import { AppTheme } from '../common/AppTheme';
import { AppFonts } from '../common/AppFonts';
import { ExcelParser } from '../common/ExcelParser';
import { ExcelFileImporter } from '../common/ExcelFileImporter';
import { PageHeader } from '../common/components/PageHeader';
import { ResultPanel } from '../common/components/ResultPanel';

@Component
export struct AnalysisContent {
  @State excelText: string = I18n.t('def.excel');
  @State remark: string = '';
  @State previewRows: string[][] = [];
  @State loading: boolean = false;
  @State result: string = '';
  @StorageProp('appLang') appLang: string = 'zh';
  @StorageProp('appResolvedTheme') resolvedTheme: string = 'light';
  /** 2in1 独立页面（IndexWideDuo 下半屏）渲染时由壳传入 true：本组件不内嵌结果区 */
  bottomResult: boolean = false;

  private t(key: string): string {
    void this.appLang;
    return I18n.t(key);
  }

  private col(key: string): string {
    void this.resolvedTheme;
    return AppTheme.color(key, this.resolvedTheme);
  }

  /** 解析预览（输入变化时刷新） */
  refreshPreview(): void {
    this.previewRows = ExcelParser.parse(this.excelText);
  }

  aboutToAppear(): void {
    this.refreshPreview();
  }

  /** 导入 .xlsx 文件 */
  async importExcel(): Promise<void> {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const rows: string[][] = await ExcelFileImporter.pickAndParse(ctx);
      if (rows.length === 0) {
        promptAction.showToast({ message: this.t('err.noFile') });
        return;
      }
      this.excelText = ExcelFileImporter.toTabText(rows);
      this.refreshPreview();
      promptAction.showToast({ message: this.t('toast.imported').replace('{n}', (rows.length - 1).toString()) });
    } catch (e) {
      promptAction.showToast({ message: this.t('err.importFail') + (e as Error).message });
    }
  }

  async generate(): Promise<void> {
    const rows: string[][] = ExcelParser.parse(this.excelText);
    if (rows.length < 2) {
      promptAction.showToast({ message: this.t('err.noExcelData') });
      return;
    }
    this.loading = true;
    this.result = '';
    const remarkPart: string = this.remark.trim() !== '' ? '\n【备注】' + this.remark.trim() : '';
    const user: string = `班级成绩数据（由 Excel 表格解析生成）：\n${ExcelParser.toJson(rows)}\n\n请生成班级学情分析报告。${remarkPart}`;
    try {
      const content: string = await AiService.chat(Prompts.analysisSystem(), user, (partial: string) => {
        this.result = partial;
      }, false, {
        ctx: getContext(this) as common.UIAbilityContext,
        type: 'analysis',
        label: I18n.t('page.analysis')
      });
      this.result = content;
      this.autoSaveHistory(content);
    } catch (e) {
      promptAction.showToast({ message: this.t('err.genFail') + (e as Error).message });
    } finally {
      this.loading = false;
    }
  }

  /** 自动保存到历史（开关开启且内容非空时静默保存；content 用于页面已离开时的兜底） */
  private autoSaveHistory(content?: string): void {
    const text: string = content !== undefined && content !== '' ? content : this.result;
    if (text === '') {
      return;
    }
    const ctx = getContext(this) as common.UIAbilityContext;
    const typeLabel: string = I18n.t('page.analysis');
    HistoryStore.autoAdd(ctx, {
      type: typeLabel,
      title: typeLabel + '-' + HistoryStore.formatNow().slice(5, 10),
      content: text,
      time: HistoryStore.formatNow()
    });
  }

  saveToHistory(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    const typeLabel: string = I18n.t('page.analysis');
    HistoryStore.addRecord(ctx, {
      type: typeLabel,
      title: typeLabel + '-' + HistoryStore.formatNow().slice(5, 10),
      content: this.result,
      time: HistoryStore.formatNow()
    }).then(() => {
      promptAction.showToast({ message: I18n.t('toast.saved') });
    });
  }

  build() {
    Column({ space: 0 }) {
      PageHeader({ title: this.t('page.analysis') })

      Column({ space: 8 }) {
        Row() {
          Column({ space: 2 }) {
            Text(this.t('excel.title'))
              .fontFamily(AppFonts.family())
              .fontSize(14)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.col('title'))
              .width('100%')
            Text(this.t('excel.sub'))
              .fontFamily(AppFonts.family())
              .fontSize(12)
              .fontColor(this.col('sub'))
              .width('100%')
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          Button(this.t('excel.import'))
            .fontFamily(AppFonts.family())
            .fontSize(13)
            .height(34)
            .backgroundColor('#3E948A')
            .onClick(() => {
              this.importExcel();
            })
        }
        .width('100%')
        TextArea({ text: this.excelText, placeholder: this.t('ph.excel') })
          .fontFamily(AppFonts.family())
          .width('100%')
          .height(120)
          .fontSize(13)
          .onChange((v: string) => {
            this.excelText = v;
            this.refreshPreview();
          })

        if (this.previewRows.length > 0) {
          Column({ space: 4 }) {
            Text(this.t('excel.preview').replace('{n}', String(this.previewRows.length - 1)))
              .fontFamily(AppFonts.family())
              .fontSize(12)
              .fontColor('#4A90D9')
              .width('100%')
            Text(this.t('label.pasteNote'))
              .fontFamily(AppFonts.family())
              .fontSize(11)
              .fontColor(this.col('hint'))
              .width('100%')
            // 表头
            Row() {
              ForEach(this.previewRows[0], (h: string) => {
                Text(h)
                  .fontFamily(AppFonts.family())
                  .fontSize(12)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(this.col('title'))
                  .layoutWeight(1)
                  .padding(4)
                  .textAlign(TextAlign.Center)
              }, (h: string) => h)
            }
            .width('100%')
            .backgroundColor(this.col('headBg'))
            .borderRadius(6)
            // 数据行（最多预览 5 行）
            ForEach(this.previewRows.slice(1, 6), (row: string[]) => {
              Row() {
                ForEach(row, (c: string) => {
                  Text(c)
                    .fontFamily(AppFonts.family())
                    .fontSize(12)
                    .fontColor(this.col('text'))
                    .layoutWeight(1)
                    .padding(4)
                    .textAlign(TextAlign.Center)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }, (c: string, idx: number) => c + idx)
              }
              .width('100%')
              .border({ width: { top: 0.5 }, color: this.col('line') })
            }, (row: string[]) => row.join(','))
          }
          .width('100%')
          .padding(8)
          .backgroundColor(this.col('card'))
          .borderRadius(8)
        }

        Text(this.t('label.remark'))
          .fontFamily(AppFonts.family())
          .fontSize(12)
          .fontColor(this.col('hint'))
          .width('100%')
        TextInput({ text: this.remark, placeholder: this.t('ph.remark') })
          .fontFamily(AppFonts.family())
          .width('100%')
          .height(42)
          .fontSize(13)
          .onChange((v: string) => { this.remark = v; })

        Button(this.loading ? this.t('gen.loading') : this.t('act.analysis'))
          .fontFamily(AppFonts.family())
          .width('100%')
          .height(44)
          .backgroundColor(this.loading ? '#8FBDB6' : '#3E948A')
          .enabled(!this.loading)
          .onClick(() => {
            this.generate();
          })
      }
      .width('100%')
      .padding(16)
      .backgroundColor(this.col('card'))
      .borderRadius(14)

      if (this.bottomResult) {
        // 2in1（独立页面）：生成结果统一显示在下半屏大面板，本组件不再内嵌结果区
      } else if (this.loading) {
        Row({ space: 10 }) {
          LoadingProgress().width(26).height(26).color('#3E948A')
          Text(this.t('gen.loading')).fontSize(14).fontColor(this.col('sub'))
            .fontFamily(AppFonts.family())
        }.width('100%').justifyContent(FlexAlign.Center).padding(20)
      } else if (this.result !== '') {
        ResultPanel({
          result: this.result,
          type: I18n.t('page.analysis'),
          title: I18n.t('page.analysis') + '-' + HistoryStore.formatNow().slice(5, 10),
          onSave: () => this.saveToHistory(),
          onEdited: (t: string): void => {
            this.result = t;
          }
        })
          .layoutWeight(1)
          .padding(16)
      } else {
        Row() {
          Text(this.t('hint.safety'))
            .fontFamily(AppFonts.family())
            .fontSize(12)
            .fontColor(this.col('hint'))
            .lineHeight(18)
        }
        .width('100%')
        .padding(16)
        .layoutWeight(1)
        .alignItems(VerticalAlign.Top)
      }
    }
    .width('100%')
    .height('100%')
    .padding(12)
    .backgroundColor(this.col('bg'))
  }
}


@Entry
@Component
struct AnalysisEntry {
  build() {
    Column() {
      AnalysisContent()
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
