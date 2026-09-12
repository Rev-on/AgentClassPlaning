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
import window from '@ohos.window';
import { I18n } from '../I18n';
import { AppTheme } from '../AppTheme';
import { AppFonts } from '../AppFonts';
import { RichHtml, RichRun, StyleOp } from '../RichHtml';
import { RichBox } from './RichBox';
import { DocxExporter } from '../DocxExporter';
import { PptxExporter, CourseSlide } from '../PptxExporter';

/** 编辑器可用的强调色板 */
const FONT_COLORS: string[] = ['#E5484D', '#E8930C', '#30A46C', '#0091FF', '#6E56CF', '#AD1FAC', '#0E7490', '#8B4513'];

/**
 * RichEditor 回读的样式判定工具：
 * fontWeight/fontStyle/decoration 返回的是"枚举序号/语义值"两种形态之一
 * （FontWeight 枚举：Lighter0 Normal1 Regular2 Medium3 Bold4 Bolder5；也可能回读 400/700 等语义数值；
 *   个别版本会回读字符串 'bold'/'400'），这里全形态兼容，
 * 否则加粗等样式会被误判为"未开启"（导致无法取消加粗、保存/导出丢失样式）。
 */
function isBoldWeightOf(w: number | string | undefined): boolean {
  if (w === undefined) {
    return false;
  }
  if (typeof w === 'string') {
    const low: string = w.toLowerCase();
    if (low === 'bold' || low === 'bolder' || low === 'medium' || low === 'semibold') {
      return true;
    }
    const num: number = Number(low);
    if (!isNaN(num)) {
      return num >= 600;
    }
    return false;
  }
  // 枚举序号：Medium3/Bold4/Bolder5 均视为"加粗档"；语义数值：600~900
  if (w >= 600) {
    return true;
  }
  return w === FontWeight.Medium || w === FontWeight.Bold || w === FontWeight.Bolder;
}

function isItalicStyleOf(fs: FontStyle | string | undefined): boolean {
  if (fs === undefined) {
    return false;
  }
  if (typeof fs === 'string') {
    return fs.toLowerCase() === 'italic';
  }
  return fs === FontStyle.Italic;
}

function isUnderlineOf(d: DecorationStyleResult | undefined): boolean {
  if (d === undefined || d.type === undefined) {
    return false;
  }
  const t: number = d.type as number;
  return t === TextDecorationType.Underline || t === 1;
}

function isStrikeOf(d: DecorationStyleResult | undefined): boolean {
  if (d === undefined || d.type === undefined) {
    return false;
  }
  const t: number = d.type as number;
  return t === TextDecorationType.LineThrough || t === 3;
}

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
  /** 导出模式：'word' 导出 Word（默认）；'json' 导出 JSON；'pptx' 导出 PPTX 粗稿 */
  exportMode: string = 'word';
  /** 课件大纲预览：true 时把 JSON 渲染为逐页幻灯片框架（白底黑字） */
  slideMode: boolean = false;
  /** 是否允许进入编辑态：false 时隐藏编辑按钮并禁用编辑（课件页等以成品预览为主的场景） */
  editable: boolean = true;
  /** 是否显示复制按钮：false 时隐藏（课件页等以导出为主的场景） */
  showCopy: boolean = true;
  /**
   * 整页滚动模式：预览内容自然撑高（不内嵌独立滚动），由外层页面级 Scroll 统一滚动。
   * 用于"生成完毕后整个功能页下滑、完整显示预览框与顶部操作按钮"的形态；
   * 默认 false 时保持原有"面板内独立滚动"行为（2in1 下半屏等受限高度场景）。
   */
  scrollPage: boolean = false;
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
  /** 顶部系统栏高度（vp）：全屏编辑内容需下移避开时间栏 */
  @State topInset: number = 0;
  /** 退出确认层：0=无 1=保存并退出 2=放弃并退出（自绘于编辑页内，避免系统弹窗叠加全屏覆盖崩溃） */
  @State confirmMode: number = 0;
  /** 确认倒计时（秒），为 0 后可点确认 */
  @State confirmRemain: number = 0;
  private confirmTimer: number = -1;

  /** 富文本控制器（每次进入编辑态重建，避免重复装载） */
  private rc: RichEditorController = new RichEditorController();
  private selStart: number = -1;
  private selEnd: number = -1;
  /** 本次编辑会话是否做过样式/颜色操作（未操作且文本未变时，保存直接回写原文，避免 SDK 回读抖动剥除整篇样式） */
  private editedFlag: boolean = false;
  /** 本次编辑会话记录的样式操作（保存时确定性回写，避免依赖 SDK 样式读回） */
  private styleOps: StyleOp[] = [];
  /** AppStorage 键：编辑浮层是否打开（页面 onBackPress 据此拦截左滑返回，避免直接退出页面丢结果） */
  static readonly EDIT_OPEN_KEY: string = 'editorOpen';
  /** AppStorage 键：页面请求关闭编辑浮层（值为时间戳，@Watch 触发） */
  static readonly EDIT_CLOSE_KEY: string = 'editorCloseReq';
  /** 页面返回手势请求关闭编辑：与"关闭"按钮一致，先确认"放弃并退出" */
  @StorageProp('editorCloseReq') @Watch('onCloseReq') closeReq: number = 0;

  onCloseReq(): void {
    if (this.editing) {
      this.askDiscardExit();
    }
  }
  /** 选区样式快照：在 onSelect 时计算（点击工具栏按钮后选区可能被系统收起，不能用实时选区判断 toggle） */
  private selBold: boolean = false;
  private selItalic: boolean = false;
  private selUnderline: boolean = false;
  private selStrike: boolean = false;

  private t(key: string): string {
    void this.appLang;
    return I18n.t(key);
  }

  private col(key: string): string {
    void this.resolvedTheme;
    return AppTheme.color(key, this.resolvedTheme);
  }

  /** 是否深色主题 */
  private isDark(): boolean {
    return this.resolvedTheme === 'dark';
  }

  /** 当前墨色：深色用浅色白字，浅色保持黑字（预览/编辑器纸张深色时保证可读） */
  private inkHex(): string {
    return this.isDark() ? '#E7EAF0' : '#1B1B1F';
  }

  /** 纸张底色：深色模式用深色纸，浅色保持白纸（导出仍是白纸黑字，与本预览无关） */
  private paperHex(): string {
    return this.isDark() ? '#1C222C' : '#FFFFFF';
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

  /** 导出按钮文案：按模式显示"导出PPTX/导出JSON/导出Word" */
  private exportLabel(): string {
    if (this.exportMode === 'pptx') {
      return this.t('btn.exportPptx');
    }
    if (this.isJsonMode()) {
      return this.t('btn.exportJson');
    }
    return this.t('btn.exportWord');
  }

  /** 导出 PPTX 粗稿（课件大纲） */
  private exportPptx(content: string): void {
    if (content === '') {
      return;
    }
    const ctx = getContext(this) as common.UIAbilityContext;
    const safeTitle: string = this.title === '' ? 'Outline' : this.title;
    PptxExporter.exportPptx(ctx, content, safeTitle + '.pptx').catch((err: Error) => {
      promptAction.showToast({ message: I18n.t('err.exportFail') + err.message });
    });
  }

  private doExport(content: string): void {
    if (this.exportMode === 'pptx') {
      this.exportPptx(content);
      return;
    }
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
    this.editedFlag = false;
    this.styleOps = [];
    this.refreshTopInset();
    // 标记编辑浮层已打开：页面侧拦截返回手势，改为"放弃并退出"确认，避免左滑直接把页面弹栈丢结果
    AppStorage.setOrCreate(ResultPanel.EDIT_OPEN_KEY, true);
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
      this.rc.setTypingStyle({ fontColor: this.inkHex(), fontSize: 15 });
      this.rc.setCaretOffset(0);
      for (let i: number = 0; i < runs.length; i++) {
        const run: RichRun = runs[i];
        const st: RichEditorTextStyle = {};
        if (run.bold || run.heading > 0) {
          st.fontWeight = FontWeight.Bold;
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
        st.fontColor = run.color !== '' ? ('#' + run.color) : this.inkHex();
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
    // 计算选区样式快照：全部文本片段同一种样式时视为"该样式已开启"，混合样式视为未开启（点按即统一设置为开启）
    let anyText: boolean = false;
    let bAll: boolean = true;
    let iAll: boolean = true;
    let uAll: boolean = true;
    let sAll: boolean = true;
    for (let i: number = 0; i < sel.spans.length; i++) {
      const sp = sel.spans[i];
      const mayText: RichEditorTextSpanResult = sp as RichEditorTextSpanResult;
      if (mayText.textStyle === undefined) {
        continue;
      }
      anyText = true;
      const ts: RichEditorTextStyleResult = mayText.textStyle;
      if (!isBoldWeightOf(ts.fontWeight)) {
        bAll = false;
      }
      if (!isItalicStyleOf(ts.fontStyle)) {
        iAll = false;
      }
      const dec = ts.decoration;
      if (!isUnderlineOf(dec)) {
        uAll = false;
      }
      if (!isStrikeOf(dec)) {
        sAll = false;
      }
    }
    this.selBold = anyText && bAll;
    this.selItalic = anyText && iAll;
    this.selUnderline = anyText && uAll;
    this.selStrike = anyText && sAll;
  }

  /**
   * 读回编辑器全部内容（样式片段 → HTML）
   * 优先走"原文 + 样式操作"的确定性回写：只要纯文本未被改动，就直接按记录的样式操作
   * 改写原文 HTML，完全不依赖 RichEditor 的样式读回（部分设备读回会把内联标签整篇丢掉）；
   * 仅在用户改动了文字时才退回 SDK 读回（此时原样式偏移已失效）。
   */
  private readHtml(): string {
    if (!this.editorReady) {
      return this.result;
    }
    let plainNow: string = '';
    try {
      const spans = this.rc.getSpans();
      for (let i: number = 0; i < spans.length; i++) {
        const sp = spans[i];
        const mayText: RichEditorTextSpanResult = sp as RichEditorTextSpanResult;
        if (mayText.value !== undefined) {
          plainNow += mayText.value;
        }
      }
    } catch (e) {
      plainNow = '';
    }
    if (plainNow !== '' && plainNow === RichHtml.plainOf(this.result)) {
      // 文字未变：仅样式变化 —— 确定性回写（无样式操作则原样返回）
      if (this.styleOps.length === 0) {
        return this.result;
      }
      return RichHtml.applyStyleOps(this.result, this.styleOps);
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
        const bold: boolean = isBoldWeightOf(ts.fontWeight);
        const italic: boolean = isItalicStyleOf(ts.fontStyle);
        const underline: boolean = isUnderlineOf(ts.decoration);
        const strike: boolean = isStrikeOf(ts.decoration);
        // 取最后 6 位十六进制（处理 #AARRGGBB/ARGB 数值），默认墨色不计为自定义颜色
        const col: string = this.decodeColor(ts.fontColor);
        const color: string = col === '1b1b1f' ? '' : col;
        const size: number = ts.fontSize || 0;
        runs.push({
          text: value, bold: bold, italic: italic, underline: underline, strike: strike,
          color: color, heading: 0, size: size
        });
      }
      // 文字有改动：用读回片段 + 映射后的样式操作重建（保证改动前后的样式尽量保留）
      const mapped: StyleOp[] = RichHtml.mapOps(this.styleOps, RichHtml.plainOf(this.result), plainNow);
      return RichHtml.runsToHtml(RichHtml.applyOpsToRuns(runs, mapped));
    } catch (e) {
      return this.result;
    }
  }

  /** 选区样式快照读取（供工具栏 toggle；工具栏点击后实时选区可能被收起，因此只用 onSelect 时快照） */
  private selStyleOn(kind: string): boolean {
    if (kind === 'bold') {
      return this.selBold;
    }
    if (kind === 'italic') {
      return this.selItalic;
    }
    if (kind === 'underline') {
      return this.selUnderline;
    }
    if (kind === 'strike') {
      return this.selStrike;
    }
    return false;
  }

  /** 样式应用后同步更新快照（保证连续点按切换正确） */
  private flipSelStyle(kind: string, on: boolean): void {
    if (kind === 'bold') {
      this.selBold = on;
    } else if (kind === 'italic') {
      this.selItalic = on;
    } else if (kind === 'underline') {
      this.selUnderline = on;
    } else if (kind === 'strike') {
      this.selStrike = on;
    }
  }

  /** 对当前选区应用/取消一种样式（已开启则再次点击取消，支持连续切换） */
  private applySelectionStyle(kind: string): void {
    if (!this.hasSelection || this.selStart < 0 || this.selEnd <= this.selStart) {
      promptAction.showToast({ message: I18n.t('editor.formatTip') });
      return;
    }
    const on: boolean = !this.selStyleOn(kind);
    const st: RichEditorTextStyle = {};
    if (kind === 'bold') {
      st.fontWeight = on ? FontWeight.Bold : FontWeight.Regular;
    } else if (kind === 'italic') {
      st.fontStyle = on ? FontStyle.Italic : FontStyle.Normal;
    } else if (kind === 'underline') {
      st.decoration = { type: on ? TextDecorationType.Underline : TextDecorationType.None };
    } else if (kind === 'strike') {
      st.decoration = { type: on ? TextDecorationType.LineThrough : TextDecorationType.None };
    }
    this.editedFlag = true;
    const op: StyleOp = { kind: kind, on: on, color: '', start: this.selStart, end: this.selEnd };
    this.styleOps.push(op);
    this.updateRange(st);
    this.flipSelStyle(kind, on);
  }

  /** 对当前选区设置颜色；空串 = 清除自定义颜色 */
  private applySelectionColor(colorHex: string): void {
    if (!this.hasSelection || this.selStart < 0 || this.selEnd <= this.selStart) {
      promptAction.showToast({ message: I18n.t('editor.formatTip') });
      return;
    }
    const st: RichEditorTextStyle = {};
    st.fontColor = colorHex === '' ? this.inkHex() : colorHex;
    this.editedFlag = true;
    const hex: string = colorHex === '' ? '' : colorHex.replace('#', '').toLowerCase();
    const op: StyleOp = { kind: 'color', on: colorHex !== '', color: hex, start: this.selStart, end: this.selEnd };
    this.styleOps.push(op);
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

  // ============ 编辑态：退出确认（页面内自绘层）与全屏避让 ============

  /** 读取系统状态栏高度（vp）：全屏编辑内容下移，避免时间栏遮挡完成/关闭 */
  private refreshTopInset(): void {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      window.getLastWindow(ctx).then((w: window.Window): void => {
        try {
          const area = w.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
          const px: number = area.topRect.height;
          this.topInset = px > 0 ? px2vp(px) : 0;
        } catch (e) {
          this.topInset = 0;
        }
      }).catch(() => {
        this.topInset = 0;
      });
    } catch (e) {
      this.topInset = 0;
    }
  }

  /** 点击"完成"：显示"保存并退出？"确认层（确认按钮 1 秒后可用） */
  private askSaveExit(): void {
    this.confirmMode = 1;
    this.confirmRemain = 1;
    this.startConfirmTick();
  }

  /** 点击"关闭"：显示"放弃并退出？"确认层（确认按钮 2 秒后可用） */
  private askDiscardExit(): void {
    this.confirmMode = 2;
    this.confirmRemain = 2;
    this.startConfirmTick();
  }

  private startConfirmTick(): void {
    this.stopConfirmTick();
    this.confirmTimer = setInterval(() => {
      if (this.confirmRemain > 0) {
        this.confirmRemain--;
      }
      if (this.confirmRemain <= 0) {
        this.stopConfirmTick();
      }
    }, 1000);
  }

  private stopConfirmTick(): void {
    if (this.confirmTimer !== -1) {
      clearInterval(this.confirmTimer);
      this.confirmTimer = -1;
    }
  }

  /** 取消：仅关闭确认层，返回编辑 */
  private cancelConfirm(): void {
    this.stopConfirmTick();
    this.confirmMode = 0;
  }

  /** 确认：按当前模式执行"保存并退出"或"放弃并退出" */
  private applyConfirm(): void {
    const mode: number = this.confirmMode;
    this.stopConfirmTick();
    this.confirmMode = 0;
    if (mode === 1) {
      this.doneEdit();
    } else if (mode === 2) {
      this.cancelEdit();
    }
  }

  /** 确认保存并退出：回写富文本并关闭编辑 */
  private doneEdit(): void {
    this.onEdited(this.readHtml());
    this.editing = false;
    AppStorage.setOrCreate(ResultPanel.EDIT_OPEN_KEY, false);
  }

  /** 放弃本次编辑（内容不写回） */
  private cancelEdit(): void {
    this.editing = false;
    AppStorage.setOrCreate(ResultPanel.EDIT_OPEN_KEY, false);
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
        .fontColor(this.hasSelection ? (color === '' ? this.inkHex() : color) : '#9AA0A6')
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
    Stack() {
      Column({ space: 8 }) {
      // 顶栏：关闭 + 标题 + 完成
      Row() {
        Text(this.t('btn.close'))
          .fontFamily(AppFonts.family())
          .fontSize(14)
          .fontColor(this.col('hint'))
          .padding({ left: 4, right: 10, top: 6, bottom: 6 })
          .onClick(() => {
            this.askDiscardExit();
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
            this.askSaveExit();
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
      .backgroundColor(this.paperHex())
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
        Button(this.exportLabel())
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
    // 顶部按系统状态栏高度下移，避免时间栏遮挡"关闭/完成"
    .padding({ left: 12, right: 12, top: this.topInset + 4, bottom: 12 })

    // 退出确认层：页面内自绘，避免系统弹窗叠加全屏覆盖导致崩溃/杀进程
    if (this.confirmMode > 0) {
      this.confirmOverlay()
    }
    }
    .width('100%')
    .height('100%')
  }

  /** 退出确认文案（按模式取标题/说明/确认按钮文字） */
  private confirmTitleText(): string {
    return this.confirmMode === 1 ? this.t('editor.saveExitTitle') : this.t('editor.discardTitle');
  }

  private confirmMessageText(): string {
    return this.confirmMode === 1 ? this.t('editor.saveExitMsg') : this.t('editor.discardMsg');
  }

  private confirmApplyLabel(): string {
    return this.confirmMode === 1 ? this.t('btn.done') : this.t('btn.close');
  }

  /** 退出确认层（页面内自绘，确认按钮带倒计时防误触） */
  @Builder
  confirmOverlay() {
    Column() {
      Column({ space: 14 }) {
        Text(this.confirmTitleText())
          .fontFamily(AppFonts.family())
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.col('title'))
          .width('100%')
        Text(this.confirmMessageText())
          .fontFamily(AppFonts.family())
          .fontSize(14)
          .fontColor(this.col('text'))
          .lineHeight(21)
          .width('100%')
        Row({ space: 12 }) {
          Button(this.t('editor.cancel'))
            .fontFamily(AppFonts.family())
            .fontSize(15)
            .height(40)
            .layoutWeight(1)
            .backgroundColor(this.col('inputBg'))
            .fontColor(this.col('text'))
            .onClick(() => {
              this.cancelConfirm();
            })
          Button(this.confirmApplyLabel() + (this.confirmRemain > 0 ? '（' + this.confirmRemain + 's）' : ''))
            .fontFamily(AppFonts.family())
            .fontSize(15)
            .height(40)
            .layoutWeight(1)
            .backgroundColor('#4A90D9')
            .fontColor(Color.White)
            .enabled(this.confirmRemain <= 0)
            .opacity(this.confirmRemain <= 0 ? 1 : 0.5)
            .onClick(() => {
              if (this.confirmRemain <= 0) {
                this.applyConfirm();
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
    .backgroundColor('rgba(0,0,0,0.38)')
  }

  /** 课件：按需渲染幻灯片框架（优先解析 AI 直出 OOXML 片段，其次 HTML 课件，回退旧 JSON 大纲）；都无法解析时回退富文本显示原文 */
  private slidesNow(): CourseSlide[] {
    const o: CourseSlide[] | null = PptxExporter.parseOoxmlFragments(this.result);
    if (o !== null && o.length > 0) {
      return o;
    }
    const html: CourseSlide[] | null = PptxExporter.parseHtmlCourseware(this.result);
    if (html !== null && html.length > 0) {
      return html;
    }
    const s: CourseSlide[] | null = PptxExporter.parseSlides(this.result);
    if (s !== null && s.length > 0) {
      return s;
    }
    const empty: CourseSlide[] = [];
    return empty;
  }

  /** 课件大纲：按需渲染幻灯片框架；JSON 无法解析时回退富文本显示原文 */
  @Builder
  slideContent() {
    if (this.slidesNow().length > 0) {
      this.slidesPreview(this.slidesNow())
    } else {
      RichBox({ html: this.result })
        .width('100%')
    }
  }

  /** 课件：逐页 16:9 幻灯片卡片预览（白底、一张一页、可下滑） */
  @Builder
  slidesPreview(slides: CourseSlide[]) {
    Column({ space: 12 }) {
      ForEach(slides, (s: CourseSlide, index: number) => {
        Column({ space: 5 }) {
          Row({ space: 8 }) {
            if (s.type !== '') {
              Text(s.type)
                .fontFamily(AppFonts.family())
                .fontSize(10)
                .fontColor('#2B4C7E')
                .backgroundColor('#E8F1FB')
                .borderRadius(6)
                .padding({ left: 7, right: 7, top: 2, bottom: 2 })
            }
            Blank()
            Text((index + 1) + ' / ' + slides.length)
              .fontFamily(AppFonts.family())
              .fontSize(11)
              .fontColor('#9AA0A6')
          }
          .width('100%')

          Text(s.title !== '' ? s.title : this.t('cw.page').replace('{n}', (index + 1).toString()))
            .fontFamily(AppFonts.family())
            .fontSize(17)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.inkHex())
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .padding({ top: 2, bottom: 2 })
          Divider().color(this.isDark() ? '#333C4A' : '#EDF0F4')

          if (s.points.length > 0) {
            ForEach(s.points.slice(0, 5), (pt: string, pi: number) => {
              Row() {
                Text('•  ')
                  .fontFamily(AppFonts.family())
                  .fontSize(13)
                  .fontColor(this.inkHex())
                Text(pt)
                  .fontFamily(AppFonts.family())
                  .fontSize(13)
                  .fontColor(this.inkHex())
                  .lineHeight(18)
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
              }
              .width('100%')
              .alignItems(VerticalAlign.Top)
            }, (pt: string, pi: number) => s.page.toString() + '_' + pi.toString())
          } else {
            Text(this.t('cw.noPoints'))
              .fontFamily(AppFonts.family())
              .fontSize(12)
              .fontColor('#9AA0A6')
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
          }
          if (s.visual !== '') {
            Text(this.t('cw.visual') + s.visual)
              .fontFamily(AppFonts.family())
              .fontSize(12)
              .fontColor(this.inkHex())
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
              .padding({ top: 2 })
          }
        }
        .width('100%')
        // 16:9 幻灯片画布：内容按 16:9 完整呈现，超出部分裁切（提示词已约束内容不溢出）
        .aspectRatio(16 / 9)
        .padding(12)
        .backgroundColor(this.paperHex())
        .borderRadius(12)
        .clip(true)
        .alignItems(HorizontalAlign.Start)
      }, (s: CourseSlide, index: number) => s.page.toString())
    }
    .width('100%')
  }

  /** 只读预览视图 */
  @Builder
  previewView() {
    Column({ space: 8 }) {
      Row() {
        if (this.editable && this.result !== '') {
          Button(this.t('btn.edit'))
            .fontFamily(AppFonts.family())
            .fontSize(13)
            .height(30)
            .backgroundColor('#7A6BC4')
            .onClick(() => this.openEditor())
        }
        Blank()
        if (this.showCopy) {
          Button(this.t('btn.copy'))
            .fontFamily(AppFonts.family())
            .fontSize(13)
            .height(30)
            .backgroundColor('#4A90D9')
            .onClick(() => this.copyText(this.result))
        }
        Button(this.exportLabel())
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

      if (this.scrollPage) {
        // 整页滚动模式：正文自然撑高，与顶部操作按钮一起随外层页面级别 Scroll 滚动，
        // 保证"下滑后完整显示预览框和顶部操作按钮"
        Column() {
          if (this.result === '') {
            Text(this.t('cw.empty'))
              .fontFamily(AppFonts.family())
              .fontSize(15)
              .fontColor(this.col('hint'))
              .width('100%')
          } else if (this.slideMode) {
            this.slideContent()
          } else {
            RichBox({ html: this.result })
              .width('100%')
          }
        }
        .width('100%')
      } else {
        Scroll() {
          if (this.result === '') {
            Text(this.t('cw.empty'))
              .fontFamily(AppFonts.family())
              .fontSize(15)
              .fontColor(this.col('hint'))
              .width('100%')
          } else if (this.slideMode) {
            this.slideContent()
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
    }
    .width('100%')
    // 整页滚动模式下高度取自然撑高（正文完整展开，随页面级 Scroll 可下滑）；
    // 受限高度模式保持 100% 依赖内部 Scroll
    .height(this.scrollPage ? 'auto' : '100%')
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
    // 整页滚动模式下由外层页面级 Scroll 撑高；受限高度场景保持 100% 让正文独立滚动
    .height(this.scrollPage ? 'auto' : '100%')
    // 全屏编辑：点击"编辑"后以整窗内容覆盖呈现，编辑区占满整屏
    .bindContentCover(this.editing, this.editorView(), {
      backgroundColor: this.col('bg'),
      // 左滑/点击遮罩想关闭编辑浮层时：不直接关闭，改为弹出"放弃并退出"确认，
      // 避免误触退出编辑、也避免底层页面被一起弹栈导致生成结果丢失
      onWillDismiss: (action: DismissContentCoverAction): void => {
        void action;
        this.onCloseReq();
      }
    })
  }
}
