/**
 * 学情分析与报告：粘贴 Excel 成绩数据（Tab 分隔），AI 生成学情分析报告
 * 用法：在 Excel 中框选数据区域 → Ctrl+C 复制 → 长按本页输入框粘贴
 * 双语界面 + 深浅主题
 */
import common from '@ohos.app.ability.common';
import promptAction from '@ohos.promptAction';
import { AiService } from '../common/AiService';
import { GenSession, GenSessionState } from '../common/GenSession';
import { PageDraft } from '../common/PageDraft';
import { Prompts } from '../common/Prompts';
import { HistoryStore } from '../common/HistoryStore';
import { I18n } from '../common/I18n';
import { AppTheme } from '../common/AppTheme';
import { AppFonts } from '../common/AppFonts';
import { AttachBar } from '../common/components/AttachBar';
import { VoiceRemarkBox } from '../common/components/VoiceRemarkBox';
import { ThinkSwitch, ThinkPanel } from '../common/components/ThinkPanel';
import { AppSettings } from '../common/AppSettings';
import { AttachFile } from '../common/AttachTypes';
import { ExcelParser } from '../common/ExcelParser';
import { ExcelFileImporter } from '../common/ExcelFileImporter';
import { PageHeader } from '../common/components/PageHeader';
import { ResultPanel } from '../common/components/ResultPanel';
import { RichBox } from '../common/components/RichBox';
import { RichHtml } from '../common/RichHtml';
import { SafeInsets } from '../common/SafeInsets';
import { LiveView } from '../common/LiveView';
import { StreamThrottle } from '../common/StreamThrottle';
import { NameMask, NameMaskSession, MaskError, TableMaskResult } from '../common/NameMask';
import { AnalysisStore } from '../common/AnalysisStore';
import { hilog } from '@kit.PerformanceAnalysisKit';

/** 完成后定位到结果顶部时预留的内边距（vp）：让预览顶部操作按钮完整露出 */
const ResultTopPadding: number = 12;

@Component
export struct AnalysisContent {
  @State excelText: string = I18n.t('def.excel');
  @State remark: string = '';
  /** 附件（图片/文档/拍照），随生成请求一起提交 */
  @State attachFiles: AttachFile[] = [];
  @State previewRows: string[][] = [];
  @State loading: boolean = false;
  /** 深度思考过程全文（开启深度思考生成时实时更新；空表示本次未产生思考过程） */
  @State thinkText: string = '';
  /** 思考过程是否展开（生成中展开实时滚动，生成完成后自动折叠，点击标题可再次展开） */
  @State thinkExpanded: boolean = true;
  @State thinkRunning: boolean = false;
  /**
   * 本次生成是否预期产生思考过程（生成时按"深度思考"开关置位）。
   * 思考框的显示条件用它而非 thinkText !== ''，保证：
   *  - 开关开启时，点击生成立刻出现思考框（占位"正在思考…"），不会因思考增量晚到而缺失；
   *  - 开关关闭（快速模式）时不显示，避免每次生成都闪一个空框。
   */
  @State thinkExpected: boolean = false;
  @State result: string = '';
  /**
   * 流式渲染节流：SSE 分片率远高于屏幕刷新率，
   * 直接每次赋值会触发大量无谓 rebuild（分片落在同一帧内纯属白做）。
   * 这里按固定间隔合并提交最新文本，结束时 flush 保证最终内容不丢。
   */
  private resultThrottle: StreamThrottle = new StreamThrottle((v: string): void => {
    this.result = v;
  });
  /** 生成会话恢复（离开页面后重进仍显示生成中/结果） */
  private sessSub: number = -1;
  /** 实时预览滚动控制器（生成中自动滚到最底部） */
  private liveScroll: Scroller = new Scroller();
  /** 完成后整页滚动控制器（自动下滑到结果预览） */
  private doneScroll: Scroller = new Scroller();
  /** 结果预览在整页滚动内容中的顶部偏移（用于完成后自动定位） */
  private resultTop: number = 0;
  /** 滚动内容容器的屏幕 Y 坐标（onAreaChange 记录，用于把绝对值换算成相对偏移） */
  private scrollContentTop: number = 0;
  /** 结果面板的屏幕 Y 坐标（onAreaChange 记录） */
  private resultAbsTop: number = 0;

  /** 由两个屏幕绝对坐标求「结果面板在滚动内容内的相对偏移」 */
  private computeResultOffset(): number {
    const rel: number = this.resultAbsTop - this.scrollContentTop;
    return rel > 0 ? rel : 0;
  }
  /** 用户是否点击了"停止生成" */
  private stopRequested: boolean = false;

  /** 生成完成后自动下滑到结果预览顶部（输入卡片滑出视口，预览填充可见区域并保持可下滑查看剩余内容） */
  private autoShowResult(): void {
    if (this.result === '') {
      return;
    }
    const target: number = this.computeResultOffset();
    this.resultTop = target;
    this.doneScroll.scrollTo({
      xOffset: 0,
      yOffset: Math.max(0, target - ResultTopPadding),
      animation: { duration: 350 }
    });
  }

  private resumeGenSession(): void {
    const cur: GenSessionState | undefined = GenSession.stateOf(this.genKey());
    if (cur !== undefined) {
      if (cur.phase === 'busy' && this.result === '') {
        this.loading = true;
      } else if (cur.phase === 'done' && cur.text !== '' && this.result === '') {
        this.result = cur.text;
        this.loading = false;
      }
    }
    this.sessSub = GenSession.subscribe(this.genKey(), (s: GenSessionState): void => {
      if (s.phase === 'busy') {
        if (this.result === '') {
          this.loading = true;
        }
      } else if (s.phase === 'done') {
        // 仅在有内容时回写：避免异常空结果把已显示的预览清空
        if (s.text !== '') {
          this.result = s.text;
        }
        this.loading = false;
      } else {
        this.loading = false;
      }
    });

    // 会话无内容时回退到本地草稿：即使异常退出/进程被杀，重进也能恢复预览
    if (this.result === '') {
      const draft: string = PageDraft.load(getContext(this) as common.UIAbilityContext, this.genKey());
      if (draft !== '') {
        this.result = draft;
      }
    }
  }

  private leaveGenSession(): void {
    if (this.sessSub >= 0) {
      GenSession.unsubscribe(this.genKey(), this.sessSub);
      this.sessSub = -1;
    }
  }

  private genKey(): string {
    return 'analysis';
  }
  @StorageProp('appLang') appLang: string = 'zh';
  @StorageProp('appResolvedTheme') resolvedTheme: string = 'light';
  /** 2in1 独立页面（IndexWideDuo 下半屏）渲染时由壳传入 true：本组件不内嵌结果区 */
  bottomResult: boolean = false;
  /** 顶部状态栏/刘海避让高度（vp）：整页滚动时预留顶部安全区 */
  @State topInset: number = 0;

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
    // 读取顶部状态栏/刘海避让高度：整页滚动时预留顶部安全区
    SafeInsets.topInset(getContext(this) as common.UIAbilityContext).then((v: number): void => {
      this.topInset = v;
    });
    this.refreshPreview();
    this.resumeGenSession();
  }

  aboutToDisappear(): void {
    // 离开页面前把当前结果留存到生成会话：再次进入可恢复（编辑界面左滑退出同样不丢）
    if (!this.loading && this.result !== '') {
      GenSession.end(this.genKey(), this.result);
      // 本地草稿兜底：异常退出/进程被杀后重进仍可恢复
      PageDraft.save(getContext(this) as common.UIAbilityContext, this.genKey(), this.result);
    }
    this.leaveGenSession();
        
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
    this.stopRequested = false;
    this.loading = true;
    this.result = '';
    // 深度思考：清空上一次的思考过程并展开（生成中实时滚动展示）
    this.thinkText = '';
    this.thinkExpanded = true;
    this.thinkRunning = true;
    // 本次生成是否预期产生思考过程（按开关决定）：用于让思考框立即出现，
    // 避免思考增量晚于正文首块到达时思考框整个不显示。
    this.thinkExpected = AppStorage.get<boolean>(AppSettings.KEY_THINK) === true;
    // 开始新的生成：清除旧草稿，避免旧结果回魂
    PageDraft.clear(getContext(this) as common.UIAbilityContext, this.genKey());
    // 实况窗：生成开始即创建，之后随进度更新百分比（失败静默，不影响生成）
    LiveView.start('analysis', this.t('page.analysis')).catch((e: Error) => {
      hilog.warn(0x0000, 'Analysis', 'LiveView.start 异常: %{public}s', e.message);
    });
    const remarkPart: string = this.remark.trim() !== '' ? '\n【备注】' + this.remark.trim() : '';
    /**
     * 【隐私】发给 AI 的成绩数据必须**按列脱敏**：只有姓名列被换成编号（张三→S001），
     * 语文/数学/总分/学号等列逐字节保持原样。
     *
     * 为什么不能对整串 JSON 做无差别替换：
     *   没有列语义的替换会把"优/良/及格"这类成绩等级、学号数字一起改掉，
     *   AI 收到的是错数据（分析结论直接失真），还原后也与老师原文对不上。
     *   列识别逻辑在 NameMask.maskTable（支持「姓名/学生姓名/名字/学生/name…」多写法）。
     *
     * 无姓名列时（如只有"题号/得分"的统计表）不是脱敏失败，而是合法输入：
     * 此时 masked=false，这里提示老师确认表格里确实没有学生隐私字段。
     */
    const mask: NameMaskSession = NameMask.session();
    const tableMask: TableMaskResult = { rows: rows, nameColumns: [], masked: false };
    let tableJson: string = '';
    try {
      tableJson = ExcelParser.toJsonMaskedText(mask, rows, tableMask, false);
    } catch (e) {
      // 脱敏环节自身异常：fail-closed，绝不退回原文发送
      const me: MaskError = e as MaskError;
      hilog.error(0x0000, 'Analysis', '表格脱敏失败，已阻断外发: %{public}s', me.code);
      this.loading = false;
      this.thinkRunning = false;
      this.thinkExpected = false;
      LiveView.done().catch((er: Error) => {
        hilog.warn(0x0000, 'Analysis', 'LiveView.done 异常: %{public}s', er.message);
      });
      promptAction.showToast({ message: this.t('err.maskFail') });
      return;
    }
    if (!tableMask.masked) {
      // 未识别到姓名列：表格按原样发送。这里只提示，不阻断 ——
      // 统计类表格（无学生字段）是合法用法，阻断会让功能不可用。
      promptAction.showToast({ message: this.t('excel.errNoNameCol') });
    }
    // 自由文本（备注 / 表格外的补充说明）同样兜底：已知姓名一律抹成编号
    const remarkMasked: string = NameMask.maskFreeText(mask, remarkPart);

    /**
     * 【两次对比】读取上一次的学情分析报告，附进 prompt 让 AI 做总体对比。
     *
     * 为什么放在脱敏之后：上次报告是**已经生成并还原过的本地文本**，
     * 其中可能含真实姓名（生成完成时我们做过 restore）。
     * 直接拼进 prompt 会绕过姓名脱敏 —— 因此这里必须对上次报告
     * 同样做一次 maskFreeText，把已知姓名重新抹成编号。
     */
    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    const last = await AnalysisStore.loadReport(ctx);
    let systemPrompt: string = Prompts.analysisSystem();
    let user: string = '';
    if (last !== null) {
      const lastMasked: string = NameMask.maskFreeText(mask, last.content);
      systemPrompt = Prompts.analysisCompareSystem();
      user = `【本次成绩数据】（由 Excel 表格解析生成）：\n${tableJson}\n\n` +
        `【上一次学情分析报告】（生成于 ${last.time}）：\n${lastMasked}\n\n` +
        `请生成本次班级学情分析报告，并在「两次对比」一章中逐项对照上次结论。${remarkMasked}`;
      hilog.info(0x0000, 'Analysis', '已附带上次分析记录用于对比');
    } else {
      user = `班级成绩数据（由 Excel 表格解析生成）：\n${tableJson}\n\n请生成班级学情分析报告。${remarkMasked}`;
    }

    // 保存本次导入的成绩表格（供「我的」页热力图使用）；失败不影响生成
    AnalysisStore.saveScores(ctx, rows).catch((e: Error) => {
      hilog.warn(0x0000, 'Analysis', 'saveScores 异常: %{public}s', e.message);
    });

    /**
     * 【隐私 fail-closed】出网前最后一道闸：prompt 里只要还残留任何已知真实姓名就抛错阻断。
     *
     * 本页**不传流式文本**给 applyToFlow：表格里的姓名已按列替换成编号，
     * 界面上出现的编号不存在泄漏风险，无需在流式期做任何替换；
     * 结果还原统一在生成完成时对最终完整文本做一次（见下方 mask.restore）。
     * 这样也就不存在"编号被 token 切成 S0 + 01 导致逐段还原失败"的问题。
     */
    try {
      NameMask.applyToFlow(mask, systemPrompt, user);
    } catch (e) {
      const me: MaskError = e as MaskError;
      hilog.error(0x0000, 'Analysis', '脱敏校验未通过，已阻断外发: %{public}s', me.code);
      this.loading = false;
      this.thinkRunning = false;
      this.thinkExpected = false;
      LiveView.done().catch((er: Error) => {
        hilog.warn(0x0000, 'Analysis', 'LiveView.done 异常: %{public}s', er.message);
      });
      promptAction.showToast({ message: this.t('err.maskFail') });
      return;
    }
    try {
      const content: string = await AiService.chat(systemPrompt, user, (partial: string) => {
        if (this.thinkRunning) {
          // 第一个正文字块到达＝思考阶段完成、正文开始输出：此刻折叠思考框
          this.thinkRunning = false;
          this.thinkExpanded = false;
        }
        // 【流式还原的坑】partial 是累计全文，但任意前缀都可能在编号中间被切断。
        // 逐段还原会漏掉 "S0"+"01" 这种跨界编号，故流式期间不还原，
        // 只在生成结束后对最终完整文本统一还原一次。
        this.resultThrottle.push(partial);
        // 实况窗：随正文进度更新百分比
        LiveView.onContent(partial).catch((e: Error) => {
          hilog.warn(0x0000, 'Analysis', 'LiveView.onContent 异常: %{public}s', e.message);
        });
        this.scrollLiveToBottom();
      }, false, {
        ctx: getContext(this) as common.UIAbilityContext,
        type: 'analysis',
        label: I18n.t('page.analysis'),
        attachments: this.attachFiles,
        // 深度思考：按当前开关决定本次是否使用思考模式（默认关闭＝快速模式）
        thinking: AppStorage.get<boolean>(AppSettings.KEY_THINK) === true
      }, (think: string): void => {
        // 思考过程实时更新（服务端按"当前全文"语义回传，直接覆盖即可）
        this.thinkText = think;
        // 实况窗：思考阶段推进基准进度
        LiveView.onThinking().catch((e: Error) => {
          hilog.warn(0x0000, 'Analysis', 'LiveView.onThinking 异常: %{public}s', e.message);
        });
      });
      if (this.stopRequested) {
        // 用户主动停止：保留已生成的部分文本，不覆盖、不入历史
        this.stopRequested = false;
        // 停止时把节流中最后一片补上，避免末尾内容缺失
        this.resultThrottle.flush();
        // 停止时手上的也是"最终可获得文本"：整体还原一次，用户看到真名版本
        this.result = mask.restore(this.result);
        return;
      }
      // 【结果还原】最终完整文本一次还原：展示/导出/存历史/草稿全部使用真名版本
      const shown: string = mask.restore(content);
      this.result = shown;
      this.autoSaveHistory(shown);
      // 结果即时落盘草稿：任何异常退出/进程被杀都能恢复（存真名版本，仅本机可见）
      PageDraft.save(getContext(this) as common.UIAbilityContext, this.genKey(), shown);
      // 记录本次结论，供**下一次**学情分析做两次对比（存还原后的真名版本，仅本机）
      AnalysisStore.saveReport(getContext(this) as common.UIAbilityContext, shown)
        .catch((er: Error) => {
          hilog.warn(0x0000, 'Analysis', 'saveReport 异常: %{public}s', er.message);
        });
    } catch (e) {
      promptAction.showToast({ message: this.t('err.genFail') + (e as Error).message });
      // 失败路径：补上节流中已收到的部分内容
      this.resultThrottle.flush();
    } finally {
      // 丢弃未提交的中间态：成功路径已由 this.result = content 写入权威内容，
      // 此处若 flush 会用滞后的 partial 覆盖它。
      this.resultThrottle.cancel();
      this.loading = false;
      this.thinkRunning = false;
      // 思考框随生成态结束而收起；若本次确实产生了思考内容，
      // 完成态视图会按 thinkText !== '' 继续展示（可点击标题展开）
      this.thinkExpected = false;
      // 实况窗：生成结束（完成/失败/停止）即结束，避免残留
      LiveView.done().catch((e: Error) => {
        hilog.warn(0x0000, 'Analysis', 'LiveView.done 异常: %{public}s', e.message);
      });
      // 生成结束（完成/失败/停止）：思考过程自动折叠，用户点击标题可展开查看
          this.thinkExpanded = false;
          // 生成完成后自动下滑定位到结果预览，仅留预览顶部操作按钮
          setTimeout(() => this.autoShowResult(), 120);
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

  /** 生成中：预览框实时滚动到最底部（等一帧让新内容完成布局） */
  private scrollLiveToBottom(): void {
    setTimeout((): void => {
      // 生成完成的这帧会把预览框 Scroller 从布局中移除（切换为整页滚动），
      // 若此时仍对已销毁的 Scroller 调 scrollEdge，会在原生层崩溃导致闪退，故用 loading 守卫跳过
      if (!this.loading) {
        return;
      }
      try {
        this.liveScroll.scrollEdge(Edge.Bottom);
      } catch (e) {
        // 预览区尚未挂载时忽略
      }
    }, 32);
  }

  /** 停止生成：立即取消任务与订阅，保留半截预览文本，回到生成前状态 */
  private stopGen(): void {
    this.stopRequested = true;
    AiService.stop(this.genKey());
    GenSession.clear(this.genKey());
    this.loading = false;
    this.thinkRunning = false;
    // 停止生成后思考过程同样自动折叠
    this.thinkExpanded = false;
  }

  /** 输入卡片 + 生成按钮区（生成中整卡置灰锁定按钮除外） */
  @Builder
  inputCard() {
    Column({ space: 8 }) {
      // 输入区：生成中整体置灰并锁定（按钮除外）
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
          .backgroundColor(this.col('inputBg'))
          .placeholderColor(this.col('hint'))
          .caretColor('#4A90D9')
          .borderRadius(10)
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

        // 备注（支持语音输入：点击麦克风切换"按住说话"，松手发送，上滑取消）
        VoiceRemarkBox({
          text: $remark,
          disabled: this.loading,
          labelText: this.t('label.remark'),
          placeholderText: this.t('ph.remark')
        })

        // 附件：+ 号选择图片/文档/拍照（上限 10）
        AttachBar({ files: $attachFiles, disabled: this.loading })

        // 深度思考开关：开启后本次生成走思考模式（模型先推理再作答），思考过程实时展示
        ThinkSwitch()
      }
      .width('100%')
      .enabled(!this.loading)
      .opacity(this.loading ? 0.6 : 1)

      // 生成中：按钮显示"生成中…"并禁用，避免重复提交。
      // （"停止生成"在页面顶部固定操作条，此处不重复提供）
      if (this.loading) {
        Button(this.t('gen.loading'))
          .fontFamily(AppFonts.family())
          .fontSize(15)
          .width('100%')
          .height(44)
          .fontColor('#FFFFFF')
          .backgroundColor('#9AA7B5')
          .enabled(false)
      } else {
        Button(this.t('act.analysis'))
          .fontFamily(AppFonts.family())
          .width('100%')
          .height(44)
          .backgroundColor('#3E948A')
          .onClick(() => {
            this.generate();
          })
      }
    }
    .width('100%')
    .padding(16)
    .backgroundColor(this.col('card'))
    .borderRadius(14)
  }

  /** 生成中：仅预览框内部滚动（整页固定，自动滚到底） */
  @Builder
  loadingPreview() {
    Column({ space: 8 }) {
      if (this.result !== '') {
        // 流式输出中：顶部小字提示 + 内容在预览框内部滚动到底
        Row({ space: 6 }) {
          LoadingProgress().width(14).height(14).color('#3E948A')
          Text(this.t('gen.streaming'))
            .fontFamily(AppFonts.family())
            .fontSize(12)
            .fontColor(this.col('sub'))
        }
        .width('100%')
        .justifyContent(FlexAlign.Start)
        .padding({ bottom: 8 })
        Scroll(this.liveScroll) {
          RichBox({ html: RichHtml.liveSafe(this.result) })
            .width('100%')
        }
        .width('100%')
        .layoutWeight(1)
        .align(Alignment.TopStart)
        .scrollBar(BarState.Off)
      } else {
        Row({ space: 10 }) {
          LoadingProgress().width(26).height(26).color('#3E948A')
          Text(this.t('gen.loading')).fontSize(14).fontColor(this.col('sub'))
            .fontFamily(AppFonts.family())
        }.width('100%').justifyContent(FlexAlign.Center).padding(20)
      }
    }
    .width('100%')
    .layoutWeight(1)
    .backgroundColor(this.col('card'))
    .padding(16)
    .borderRadius(14)
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    Column({ space: 0 }) {
      // 固定标题栏：整页滚动时标题栏保持不滚，并预留顶部安全区（状态栏/刘海避让）
      Column() {
        PageHeader({ title: this.t('page.analysis') })
        // 生成中：标题栏下方固定一条"停止生成"操作条。
        // 放在固定标题栏内而非输入卡片内 —— 生成过程中输入区可能被收起/禁用，
        // 若停止按钮留在卡片里会随之消失或不可点，用户无法中断生成。
        if (this.loading) {
          Row() {
            Button(this.t('act.stop'))
              .fontFamily(AppFonts.family())
              .fontSize(14)
              .fontColor('#FFFFFF')
              .height(34)
              .backgroundColor('#C0564F')
              .borderRadius(17)
              .onClick(() => {
                this.stopGen();
              })
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)
          .padding({ left: 12, right: 12, bottom: 8 })
        }
      }
      .width('100%')
      .padding({ top: this.topInset })

      if (this.loading) {
        // 生成中：输入卡片固定不下滑（整页不随生成滚动），仅预览框内部滚动到底
        Column({ space: 0 }) {
          this.inputCard()
          // 深度思考过程：生成中实时滚动；完成后自动折叠
          // 条件用 thinkExpected（本次预期有思考过程）而非 thinkText !== ''，
          // 否则思考增量尚未到达时思考框不会出现，用户会看到"直接跳到正文生成"。
          if (this.thinkExpected) {
            ThinkPanel({
              text: this.thinkText,
              expanded: $thinkExpanded,
              running: this.thinkRunning
            })
              .width('100%')
              .margin({ top: 10 })
          }
          this.loadingPreview()
        }
        .width('100%')
        .layoutWeight(1)
        .padding(12)
      } else {
        // 生成完成后：整页可下滑，完整显示预览框与顶部操作按钮
        Scroll(this.doneScroll) {
          Column({ space: 0 }) {
            this.inputCard()

            // 深度思考过程：灰色小字；生成完成后自动折叠，点击标题可展开查看
            if (this.thinkText !== '') {
              ThinkPanel({
                text: this.thinkText,
                expanded: $thinkExpanded,
                running: this.thinkRunning
              })
                .width('100%')
                .margin({ top: 10 })
            }

            if (this.bottomResult) {
              // 2in1（独立页面）：生成结果统一显示在下半屏大面板，本组件不再内嵌结果区
            } else if (this.result !== '') {
              ResultPanel({
                result: this.result,
                type: I18n.t('page.analysis'),
                title: I18n.t('page.analysis') + '-' + HistoryStore.formatNow().slice(5, 10),
                scrollPage: true,
                onSave: () => this.saveToHistory(),
                onEdited: (t: string): void => {
                  if (t.trim() === '') {
                    // 异常空回写保护：避免已有结果被清空导致预览框消失
                    return;
                  }
                  this.result = t;
                  // 同步到生成会话：离开页面/再次进入时不丢最新内容（含编辑结果）
                  GenSession.end(this.genKey(), t);
                  PageDraft.save(getContext(this) as common.UIAbilityContext, this.genKey(), t);
                }
              })
                    .width('100%')
                    .padding(16)
                    .onAreaChange((_o: Area, n: Area): void => {
                      this.resultAbsTop = Number(n.globalPosition.y);
                    })
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
              .alignItems(VerticalAlign.Top)
            }
          }
          .width('100%')
          .padding(12)
          .onAreaChange((_o: Area, n: Area): void => {
            // 滚动内容容器的屏幕 Y 坐标：用于把结果面板的绝对坐标换算成相对偏移
            this.scrollContentTop = Number(n.globalPosition.y);
          })
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


@Entry
@Component
struct AnalysisEntry {

  /**
   * 编辑浮层打开时拦截返回手势/返回键：
   * 交由编辑器弹出"放弃并退出"确认，避免左滑直接把页面弹栈导致生成结果丢失
   */
  onBackPress(): boolean {
    if (AppStorage.get<boolean>('editorOpen') === true) {
      AppStorage.setOrCreate('editorCloseReq', Date.now());
      return true;
    }
    return false;
  }
  build() {
    Column() {
      AnalysisContent()
    }
    .width('100%')
    .height('100%')
  }

  }
