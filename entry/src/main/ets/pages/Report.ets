/**
 * 个性化学情报告：输入学生成绩与课堂观察，AI 生成给家长的学情报告（双语界面 + 深浅主题）
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
import { PageHeader } from '../common/components/PageHeader';
import { ResultPanel } from '../common/components/ResultPanel';
import { RichBox } from '../common/components/RichBox';
import { RichHtml } from '../common/RichHtml';
import { SafeInsets } from '../common/SafeInsets';

@Component
export struct ReportContent {
  @State studentName: string = I18n.t('def.studentName');
  @State className: string = I18n.t('def.className');
  @State grades: string = I18n.t('def.grades');
  @State observation: string = I18n.t('def.observation');
  @State remark: string = '';
  /** 附件（图片/文档/拍照），随生成请求一起提交 */
  @State attachFiles: AttachFile[] = [];
  @State loading: boolean = false;
  /** 深度思考过程全文（开启深度思考生成时实时更新；空表示本次未产生思考过程） */
  @State thinkText: string = '';
  /** 思考过程是否展开（生成中展开实时滚动，生成完成后自动折叠，点击标题可再次展开） */
  @State thinkExpanded: boolean = true;
  @State thinkRunning: boolean = false;
  @State result: string = '';
  /** 生成会话恢复（离开页面后重进仍显示生成中/结果） */
  private sessSub: number = -1;
  /** 实时预览滚动控制器（生成中自动滚到最底部） */
  private liveScroll: Scroller = new Scroller();
  /** 完成后整页滚动控制器（自动下滑到结果预览） */
  private doneScroll: Scroller = new Scroller();
  /** 结果预览在整页滚动内容中的顶部偏移（用于完成后自动定位） */
  private resultTop: number = 0;
  /** 用户是否点击了"停止生成" */
  private stopRequested: boolean = false;

  /** 生成完成后自动下滑到结果预览顶部（输入卡片滑出视口，预览填充可见区域并保持可下滑查看剩余内容） */
  private autoShowResult(): void {
    if (this.result === '') {
      return;
    }
    this.doneScroll.scrollTo({ xOffset: 0, yOffset: Math.max(0, this.resultTop), animation: { duration: 350 } });
  }

  aboutToAppear(): void {
    // 读取顶部状态栏/刘海避让高度：整页滚动时预留顶部安全区
    SafeInsets.topInset(getContext(this) as common.UIAbilityContext).then((v: number): void => {
      this.topInset = v;
    });
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
    return 'report';
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

  async generate(): Promise<void> {
    if (this.studentName.trim() === '') {
      promptAction.showToast({ message: this.t('err.noName') });
      return;
    }
    this.stopRequested = false;
    this.loading = true;
    this.result = '';
    // 深度思考：清空上一次的思考过程并展开（生成中实时滚动展示）
    this.thinkText = '';
    this.thinkExpanded = true;
    this.thinkRunning = true;
    // 开始新的生成：清除旧草稿，避免旧结果回魂
    PageDraft.clear(getContext(this) as common.UIAbilityContext, this.genKey());
    const remarkPart: string = this.remark.trim() !== '' ? '\n【备注】' + this.remark.trim() : '';
    const user: string = `学生姓名：${this.studentName}\n班级：${this.className}\n各科成绩：${this.grades}\n课堂观察记录：${this.observation}\n\n请生成给家长的个性化学情报告。${remarkPart}`;
    try {
      const content: string = await AiService.chat(Prompts.studentReportSystem(), user, (partial: string) => {
        if (this.thinkRunning) {
          // 第一个正文字块到达＝思考阶段完成、正文开始输出：此刻折叠思考框
          this.thinkRunning = false;
          this.thinkExpanded = false;
        }
        this.result = partial;
        this.scrollLiveToBottom();
      }, false, {
        ctx: getContext(this) as common.UIAbilityContext,
        type: 'report',
        label: I18n.t('page.report'),
        attachments: this.attachFiles,
        // 深度思考：按当前开关决定本次是否使用思考模式（默认关闭＝快速模式）
        thinking: AppStorage.get<boolean>(AppSettings.KEY_THINK) === true
      }, (think: string): void => {
        // 思考过程实时更新（服务端按"当前全文"语义回传，直接覆盖即可）
        this.thinkText = think;
      });
      if (this.stopRequested) {
        // 用户主动停止：保留已生成的部分文本，不覆盖、不入历史
        this.stopRequested = false;
        return;
      }
      this.result = content;
      this.autoSaveHistory(content);
      // 结果即时落盘草稿：任何异常退出/进程被杀都能恢复
      PageDraft.save(getContext(this) as common.UIAbilityContext, this.genKey(), content);
    } catch (e) {
      promptAction.showToast({ message: this.t('err.genFail') + (e as Error).message });
    } finally {
      this.loading = false;
      this.thinkRunning = false;
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
    const typeLabel: string = I18n.t('page.report');
    HistoryStore.autoAdd(ctx, {
      type: typeLabel,
      title: typeLabel + '-' + this.studentName,
      content: text,
      time: HistoryStore.formatNow()
    });
  }

  saveToHistory(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    const typeLabel: string = I18n.t('page.report');
    HistoryStore.addRecord(ctx, {
      type: typeLabel,
      title: typeLabel + '-' + this.studentName,
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
    Column({ space: 10 }) {
      // 输入区：生成中整体置灰并锁定（按钮除外）
      Column({ space: 10 }) {
        Row({ space: 10 }) {
          Text(this.t('label.student')).fontSize(15).fontColor(this.col('title')).width(86)
            .fontFamily(AppFonts.family())
          TextInput({
            text: this.studentName,
            placeholder: this.t('ph.reportName')
          })
            .layoutWeight(1)
            .height(42)
            .onChange((v: string) => { this.studentName = v; })
        }
        .width('100%')
        Row({ space: 10 }) {
          Text(this.t('label.class')).fontSize(15).fontColor(this.col('title')).width(86)
            .fontFamily(AppFonts.family())
          TextInput({
            text: this.className,
            placeholder: this.t('ph.reportClass')
          })
            .layoutWeight(1)
            .height(42)
            .onChange((v: string) => { this.className = v; })
        }
        .width('100%')
        Text(this.t('label.grades'))
          .fontFamily(AppFonts.family())
          .fontSize(13)
          .fontColor(this.col('title'))
          .width('100%')
        TextArea({ text: this.grades, placeholder: this.t('ph.scores') })
          .fontFamily(AppFonts.family())
          .width('100%')
          .height(70)
          .fontSize(13)
          .onChange((v: string) => { this.grades = v; })
        Text(this.t('label.observation'))
          .fontFamily(AppFonts.family())
          .fontSize(13)
          .fontColor(this.col('title'))
          .width('100%')
        TextArea({ text: this.observation, placeholder: this.t('ph.observation') })
          .fontFamily(AppFonts.family())
          .width('100%')
          .height(80)
          .fontSize(13)
          .onChange((v: string) => { this.observation = v; })

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

      if (this.loading) {
        // 生成中：按钮变为"停止生成"（点击即停，保留半截预览）
        Button(this.t('act.stop'))
          .fontFamily(AppFonts.family())
          .width('100%')
          .height(44)
          .backgroundColor('#C0564F')
          .onClick(() => {
            this.stopGen();
          })
      } else {
        Button(this.t('act.report'))
          .fontFamily(AppFonts.family())
          .width('100%')
          .height(44)
          .backgroundColor('#4A90D9')
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
          LoadingProgress().width(14).height(14).color('#4A90D9')
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
          LoadingProgress().width(26).height(26).color('#4A90D9')
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
        PageHeader({ title: this.t('page.report') })
      }
      .width('100%')
      .padding({ top: this.topInset })

      if (this.loading) {
        // 生成中：输入卡片固定不下滑（整页不随生成滚动），仅预览框内部滚动到底
        Column({ space: 0 }) {
          this.inputCard()
          // 深度思考过程：生成中实时滚动；完成后自动折叠
          if (this.thinkText !== '') {
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
                type: I18n.t('page.report'),
                title: I18n.t('page.report') + '-' + this.studentName,
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
                      this.resultTop = Number(n.globalPosition.y);
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
struct ReportEntry {

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
      ReportContent()
    }
    .width('100%')
    .height('100%')
  }

  }
