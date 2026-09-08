/**
 * 通用结果展示组件：以富文本（受限 HTML）渲染 AI 生成结果
 * - 只读态：RichText 富文本渲染，支持复制（纯文本）/导出 Word / 保存历史 / 整屏编辑
 * - 编辑态：RichEditor 富文本编辑器，顶栏提供 加粗(B)/斜体(I)/下划线(U)/删除线(S)/颜色 等基础格式，
 *   选中文字后点按应用；完成/保存会序列化为受限 HTML 回写（含样式持久化到历史与 Word 导出）
 * 支持中英双语与深浅主题；富文本正文统一使用"白底文档纸"保证可读性
 */
import pasteboard from '@ohos.pasteboard';
import promptAction from '@ohos.promptAction';
import common from '@ohos.app.ability.common';
import { I18n } from '../I18n';
import { AppTheme } from '../AppTheme';
import { AppFonts } from '../AppFonts';
import { RichHtml, RichRun } from '../RichHtml';
import { RichBox } from './RichBox';
import { DocxExporter } from '../DocxExporter';

/** 编辑器可用的强调色板 */
const FONT_COLORS: string[] = ['#E5484D', '#E8930C', '#30A46C', '#0091FF', '#6E56CF', '#AD1FAC', '#0E7490', '#8B4513'];

@Component
export struct ResultPanel {
  /** 生成结果文本（富文本 HTML；兼容历史遗留纯文本） */
  @Prop result: string = '';
  /** 功能类型（保存历史用） */
  type: string = '';
  /** 记录标题（保存历史用） */
  title: string = '';
  /** 保存回调（由父页面实现写入历史库） */
  onSave: (() => void) = () => {};
  /** 编辑完成后的富文本回写（父页面据此更新 result） */
  onEdited: ((t: string) => void) = (t: string): void => {
  };
  /** 导出模式：'word' 导出 Word（默认）；'json' 导出 JSON */
  exportMode: string = 'word';
  @StorageProp('appLang') appLang: string = 'zh';
  @StorageProp('appResolvedTheme') resolvedTheme: string = 'light';

  /** 是否处于编辑态 */
  @State editing: boolean = false;
  /** 颜色板是否展开 */
  @State showColors: boolean = false;
  /** 编辑器内容是否已载入 */
  @State editorReady: boolean = false;
  /** 当前选中区（-1 表示无选区） */
  @State hasSelection: boolean = false;

  /** 富文本控制器（每次进入编辑态重建，避免重复装载） */
  private rc: RichEditorController = new RichEditorController();
  private selStart: number = -1;
  private selEnd: number = -1;

  private t(key: string): string {
    void this.appLang;
    return I18n.t(key);
  }

  private col(key: string): string {
    void this.resolvedTheme;
    return AppTheme.color(key, this.resolvedTheme);
  }

  /**
   * 读取片段颜色为 6 位十六进制（'' 表示未指定）。
   * RichEditor 回读的 fontColor 可能是 '#AARRGGBB' 字符串或 ARGB 数值，
   * 必须取"最后 6 位十六进制"，否则会把 alpha 当作红色分量（表现为文字变红）。
   */
  private decodeColor(fc: ResourceColor): string {
    try {
      if (typeof fc === 'number') {
        const n: number = fc as number;
        const hex: string = ((n & 0xFFFFFF)).toString(16);
        return ('000000' + hex).slice(-6).toLowerCase();
      }
      const s: string = fc as string;
      const idx: number = s.lastIndexOf('#');
      const hexPart: string = idx >= 0 ? s.substring(idx + 1) : s;
      const m = hexPart.match(/[0-9a-fA-F]{6}$/);
      if (m !== null) {
        return m[0].toLowerCase();
      }
      return '';
    } catch (e) {
      return '';
    }
  }

  /** 复制纯文本（剥离标签）到剪贴板 */
  private copyText(content: string): void {
    const plain: string = RichHtml.toPlain(content);
    if (plain === '') {
      return;
    }
    const sysPaste = pasteboard.getSystemPasteboard();
    const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, plain);
    sysPaste.setData(data).then(() => {
      promptAction.showToast({ message: I18n.t('toast.copied') });
    }).catch(() => {
      promptAction.showToast({ message: I18n.t('err.copyFail') });
    });
  }

  /** 导出 Word 文档（富文本 HTML 或遗留文本均可） */
  private exportWord(content: string): void {
    if (content === '') {
      return;
    }
    const ctx = getContext(this) as common.UIAbilityContext;
    const safeTitle: string = this.title === '' ? 'Result' : this.title;
    DocxExporter.exportDocx(ctx, content, safeTitle + '.docx').catch((err: Error) => {
      promptAction.showToast({ message: I18n.t('err.exportFail') + err.message });
    });
  }

  /** 导出 JSON 文件 */
  private exportJsonFile(content: string): void {
    if (content === '') {
      return;
    }
    const ctx = getContext(this) as common.UIAbilityContext;
    const safeTitle: string = this.title === '' ? 'Result' : this.title;
    DocxExporter.exportJson(ctx, content, safeTitle + '.json').catch((err: Error) => {
      promptAction.showToast({ message: I18n.t('err.exportFail') + err.message });
    });
  }

  private isJsonMode(): boolean {
    return this.exportMode === 'json';
  }

  private doExport(content: string): void {
    if (this.isJsonMode()) {
      this.exportJsonFile(content);
    } else {
      this.exportWord(content);
    }
  }

  // ============ 编辑态：载入 ============

  /** 进入编辑态：重建控制器与状态 */
  private openEditor(): void {
    this.rc = new RichEditorController();
    this.editorReady = false;
    this.hasSelection = false;
    this.showColors = false;
    this.selStart = -1;
    this.selEnd = -1;
    this.editing = true;
  }

  /** 编辑器就绪后装载内容（HTML → 样式片段） */
  private loadEditorContent(): void {
    if (this.editorReady) {
      return;
    }
    this.editorReady = true;
    const runs: RichRun[] = RichHtml.htmlToRuns(this.result);
    try {
      this.rc.setTypingStyle({ fontColor: '#1B1B1F', fontSize: 15 });
      this.rc.setCaretOffset(0);
      for (let i: number = 0; i < runs.length; i++) {
        const run: RichRun = runs[i];
        const st: RichEditorTextStyle = {};
        if (run.bold || run.heading > 0) {
          st.fontWeight = 'bold';
        }
        if (run.italic) {
          st.fontStyle = FontStyle.Italic;
        }
        if (run.strike) {
          st.decoration = { type: TextDecorationType.LineThrough };
        } else if (run.underline) {
          st.decoration = { type: TextDecorationType.Underline };
        }
        if (run.size > 0) {
          st.fontSize = run.size;
        }
        // 未指定颜色时显式使用"墨色"：避免 RichEditor 缺省样式（含 alpha 通道）被误读为彩色/红色
        st.fontColor = run.color !== '' ? ('#' + run.color) : '#1B1B1F';
        this.rc.addTextSpan(run.text, { style: st });
      }
      this.rc.setSelection(0, 0);
    } catch (e) {
      // 装载失败时保留可输入的空编辑器，用户仍可手动输入/粘贴
    }
  }

  // ============ 编辑态：选区与样式 ============

  private onEditorSelect(sel: RichEditorSelection): void {
    const s: number = sel.selection[0];
    const e: number = sel.selection[1];
    this.selStart = s;
    this.selEnd = e;
    this.hasSelection = e > s;
  }

  /** 读回编辑器全部内容（样式片段 → HTML） */
  private readHtml(): string {
    if (!this.editorReady) {
      return this.result;
    }
    try {
      const spans = this.rc.getSpans();
      const runs: RichRun[] = [];
      for (let i: number = 0; i < spans.length; i++) {
        const sp = spans[i];
        const mayText: RichEditorTextSpanResult = sp as RichEditorTextSpanResult;
        if (mayText.textStyle === undefined) {
          continue;
        }
        const ts: RichEditorTextStyleResult = mayText.textStyle;
        const value: string = mayText.value;
        let bold: boolean = false;
        let italic: boolean = false;
        let underline: boolean = false;
        let strike: boolean = false;
        let color: string = '';
        let size: number = 0;
        try {
          bold = (ts.fontWeight as number) >= 600;
        } catch (e) {
          bold = false;
        }
        try {
          italic = ts.fontStyle === FontStyle.Italic;
        } catch (e) {
          italic = false;
        }
        try {
          const dec = ts.decoration;
          if (dec !== undefined && dec.type === TextDecorationType.LineThrough) {
            strike = true;
          } else if (dec !== undefined && dec.type === TextDecorationType.Underline) {
            underline = true;
          }
        } catch (e) {
          strike = false;
          underline = false;
        }
        try {
          // 取最后 6 位十六进制（处理 #AARRGGBB/ARGB 数值），默认墨色不计为自定义颜色
          const col: string = this.decodeColor(ts.fontColor);
          color = col === '1b1b1f' ? '' : col;
        } catch (e) {
          color = '';
        }
        try {
          size = (ts.fontSize as number) || 0;
        } catch (e) {
          size = 0;
        }
        runs.push({
          text: value, bold: bold, italic: italic, underline: underline, strike: strike,
          color: color, heading: 0, size: size
        });
      }
      return RichHtml.runsToHtml(runs);
    } catch (e) {
      return this.result;
    }
  }

  /** 编辑器内的样式是否开启（依据选区第一个文本片段的样式，供 toggle） */
  private selStyleOn(kind: string): boolean {
    try {
      const sel = this.rc.getSelection();
      for (let i: number = 0; i < sel.spans.length; i++) {
        const sp = sel.spans[i];
        const mayText: RichEditorTextSpanResult = sp as RichEditorTextSpanResult;
        if (mayText.textStyle === undefined) {
          continue;
        }
        const ts: RichEditorTextStyleResult = mayText.textStyle;
        if (kind === 'bold') {
          return (ts.fontWeight as number) >= 600;
        }
        if (kind === 'italic') {
          return ts.fontStyle === FontStyle.Italic;
        }
        if (kind === 'underline') {
          const d = ts.decoration;
          return d !== undefined && d.type === TextDecorationType.Underline;
        }
        if (kind === 'strike') {
          const d = ts.decoration;
          return d !== undefined && d.type === TextDecorationType.LineThrough;
        }
      }
    } catch (e) {
      return false;
    }
    return false;
  }

  /** 对当前选区应用/取消一种样式 */
  private applySelectionStyle(kind: string): void {
    if (!this.hasSelection || this.selStart < 0 || this.selEnd <= this.selStart) {
      promptAction.showToast({ message: I18n.t('editor.formatTip') });
      return;
    }
    const st: RichEditorTextStyle = {};
    if (kind === 'bold') {
      st.fontWeight = this.selStyleOn('bold') ? 400 : 'bold';
    } else if (kind === 'italic') {
      st.fontStyle = this.selStyleOn('italic') ? FontStyle.Normal : FontStyle.Italic;
    } else if (kind === 'underline') {
      st.decoration = this.selStyleOn('underline') ?
        { type: TextDecorationType.None } : { type: TextDecorationType.Underline };
    } else if (kind === 'strike') {
      st.decoration = this.selStyleOn('strike') ?
        { type: TextDecorationType.None } : { type: TextDecorationType.LineThrough };
    }
    this.updateRange(st);
  }

  /** 对当前选区设置颜色；空串 = 清除自定义颜色 */
  private applySelectionColor(colorHex: string): void {
    if (!this.hasSelection || this.selStart < 0 || this.selEnd <= this.selStart) {
      promptAction.showToast({ message: I18n.t('editor.formatTip') });
      return;
    }
    const st: RichEditorTextStyle = {};
    st.fontColor = colorHex === '' ? '#1B1B1F' : colorHex;
    this.updateRange(st);
  }

  private updateRange(st: RichEditorTextStyle): void {
    try {
      this.rc.setSelection(this.selStart, this.selEnd);
      this.rc.updateSpanStyle({ start: this.selStart, end: this.selEnd, textStyle: st });
      // 应用后保持选区，便于连续设置多种格式
      this.rc.setSelection(this.selStart, this.selEnd);
    } catch (e) {
      // 极少数设备富文本接口异常时忽略，不打断编辑
    }
  }

  // ============ 编辑态：退出/保存 ============

  private doneEdit(): void {
    this.onEdited(this.readHtml());
    this.editing = false;
  }

  /** 放弃本次编辑（内容不写回） */
  private cancelEdit(): void {
    this.editing = false;
  }

  private saveEdited(): void {
    this.onEdited(this.readHtml());
    this.onSave();
  }

  // ============ 视图 ============

  /** 格式工具栏按钮（B/I/U/S/颜色） */
  @Builder
  fmtChip(label: string, kind: string, underline: boolean, strike: boolean, color: string) {
    Column() {
      Text(label)
        .fontFamily(AppFonts.family())
        .fontSize(17)
        .fontWeight(kind === 'bold' ? FontWeight.Bold : FontWeight.Normal)
        .fontStyle(kind === 'italic' ? FontStyle.Italic : FontStyle.Normal)
        .decoration({
          type: strike ? TextDecorationType.LineThrough : (underline ? TextDecorationType.Underline : TextDecorationType.None),
          color: color
        })
        .fontColor(this.hasSelection ? (color === '' ? '#1B1B1F' : color) : '#9AA0A6')
    }
    .width(40)
    .height(40)
    .justifyContent(FlexAlign.Center)
    .backgroundColor(this.col('inputBg'))
    .borderRadius(10)
    .onClick(() => {
      if (kind === 'color') {
        this.showColors = !this.showColors;
        return;
      }
      this.applySelectionStyle(kind);
    })
  }

  /** 编辑态整屏视图（作为全屏内容覆盖层展示） */
  @Builder
  editorView() {
    Column({ space: 8 }) {
      // 顶栏：关闭 + 标题 + 完成
      Row() {
        Text(this.t('btn.close'))
          .fontFamily(AppFonts.family())
          .fontSize(14)
          .fontColor(this.col('hint'))
          .padding({ left: 4, right: 10, top: 6, bottom: 6 })
          .onClick(() => {
            this.cancelEdit();
          })
        Text(this.t('editor.title'))
          .fontFamily(AppFonts.family())
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.col('title'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text(this.t('btn.done'))
          .fontFamily(AppFonts.family())
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor('#4A90D9')
          .padding({ left: 10, right: 4, top: 6, bottom: 6 })
          .onClick(() => {
            this.doneEdit();
          })
      }
      .width('100%')
      .padding({ left: 2, right: 2 })
      .alignItems(VerticalAlign.Center)

      // 格式工具栏：B / I / U / S / A（颜色）
      Column({ space: 6 }) {
        Row({ space: 8 }) {
          this.fmtChip('B', 'bold', false, false, '')
          this.fmtChip('I', 'italic', false, false, '')
          this.fmtChip('U', 'underline', true, false, '')
          this.fmtChip('S', 'strike', false, true, '')
          this.fmtChip('A', 'color', true, false, '#E5484D')
          Column() {
            Text(this.t('editor.tip'))
              .fontFamily(AppFonts.family())
              .fontSize(11)
              .fontColor(this.col('faint'))
              .maxLines(2)
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.End)
        }
        .width('100%')

        // 颜色板（点击 A 展开/收起）
        if (this.showColors) {
          Row({ space: 8 }) {
            ForEach(FONT_COLORS, (c: string) => {
              Column()
                .width(26)
                .height(26)
                .backgroundColor(c)
                .borderRadius(13)
                .border({ width: 1.5, color: '#D0D5DD' })
                .onClick(() => {
                  this.applySelectionColor(c);
                })
            }, (c: string) => c)
            Text(this.t('editor.clearColor'))
              .fontFamily(AppFonts.family())
              .fontSize(12)
              .fontColor(this.col('hint'))
              .padding({ left: 10, right: 10, top: 5, bottom: 5 })
              .backgroundColor(this.col('inputBg'))
              .borderRadius(12)
              .onClick(() => {
                this.applySelectionColor('');
              })
          }
          .width('100%')
          .padding({ top: 4, bottom: 2 })
        }
      }
      .width('100%')
      .padding(10)
      .backgroundColor(this.col('card'))
      .borderRadius(12)

      // 富文本编辑区（白底文档纸）
      Column() {
        RichEditor({ controller: this.rc })
          .width('100%')
          .height('100%')
          .onReady(() => {
            this.loadEditorContent();
          })
          .onSelect((sel: RichEditorSelection) => {
            this.onEditorSelect(sel);
          })
      }
      .width('100%')
      .layoutWeight(1)
      .padding(10)
      .backgroundColor('#FFFFFF')
      .borderRadius(10)

      // 底部操作
      Row({ space: 10 }) {
        Button(this.t('btn.copy'))
          .fontFamily(AppFonts.family())
          .fontSize(14)
          .height(40)
          .layoutWeight(1)
          .backgroundColor('#4A90D9')
          .onClick(() => this.copyText(this.readHtml()))
        Button(this.isJsonMode() ? this.t('btn.exportJson') : this.t('btn.exportWord'))
          .fontFamily(AppFonts.family())
          .fontSize(14)
          .height(40)
          .layoutWeight(1)
          .backgroundColor('#2F6DB5')
          .onClick(() => this.doExport(this.readHtml()))
        Button(this.t('btn.saveHist'))
          .fontFamily(AppFonts.family())
          .fontSize(14)
          .height(40)
          .layoutWeight(1)
          .backgroundColor('#5BA8A0')
          .onClick(() => this.saveEdited())
      }
      .width('100%')
      .padding({ top: 4 })
    }
    .width('100%')
    .height('100%')
    .padding({ left: 12, right: 12, top: 4, bottom: 12 })
  }

  /** 只读预览视图 */
  @Builder
  previewView() {
    Column({ space: 8 }) {
      Row() {
        if (this.result !== '') {
          Button(this.t('btn.edit'))
            .fontFamily(AppFonts.family())
            .fontSize(13)
            .height(30)
            .backgroundColor('#7A6BC4')
            .onClick(() => this.openEditor())
        }
        Blank()
        Button(this.t('btn.copy'))
          .fontFamily(AppFonts.family())
          .fontSize(13)
          .height(30)
          .backgroundColor('#4A90D9')
          .onClick(() => this.copyText(this.result))
        Button(this.isJsonMode() ? this.t('btn.exportJson') : this.t('btn.exportWord'))
          .fontFamily(AppFonts.family())
          .fontSize(13)
          .height(30)
          .backgroundColor('#2F6DB5')
          .margin({ left: 8 })
          .onClick(() => this.doExport(this.result))
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
          RichBox({ html: this.result })
            .width('100%')
        }
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      .align(Alignment.TopStart)
    }
    .width('100%')
    .height('100%')
  }

  build() {
    Column() {
      if (this.editing) {
        // 编辑内容由全屏覆盖层承载，此处仅占位
        Column()
          .width('100%')
          .height('100%')
      } else {
        this.previewView()
      }
    }
    .width('100%')
    .height('100%')
    // 全屏编辑：点击"编辑"后以整窗内容覆盖呈现，编辑区占满整屏
    .bindContentCover(this.editing, this.editorView(), { backgroundColor: this.col('bg') })
  }
}
