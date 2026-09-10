/**
 * 教研科研辅助：选题建议 / 论文大纲 / 摘要润色 三种模式（双语界面 + 深浅主题）
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
import { AttachFile } from '../common/AttachTypes';
import { PageHeader } from '../common/components/PageHeader';
import { ResultPanel } from '../common/components/ResultPanel';
import { RichBox } from '../common/components/RichBox';
import { RichHtml } from '../common/RichHtml';

@Component
export struct ResearchContent {
  @State mode: number = 0;   // 0 选题建议 1 论文大纲 2 摘要润色
  @State input: string = I18n.t('def.researchInput');
  @State remark: string = '';
  /** 附件（图片/文档/拍照），随生成请求一起提交 */
  @State attachFiles: AttachFile[] = [];
  @State loading: boolean = false;
  @State result: string = '';
  /** 生成会话恢复（离开页面后重进仍显示生成中/结果） */
  private sessSub: number = -1;
  /** 实时预览滚动控制器（生成中自动滚到最底部） */
  private liveScroll: Scroller = new Scroller();
  /** 用户是否点击了"停止生成" */
  private stopRequested: boolean = false;

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
    return 'research';
  }
  /** 底部水印闪烁 */
  @State blink: boolean = false;
  @StorageProp('appLang') appLang: string = 'zh';
  @StorageProp('appResolvedTheme') resolvedTheme: string = 'light';
  /** 2in1 独立页面（IndexWideDuo 下半屏）渲染时由壳传入 true：本组件不内嵌结果区 */
  bottomResult: boolean = false;
  private blinkTimer: number = -1;

  aboutToAppear(): void {
    this.resumeGenSession();
    this.blinkTimer = setInterval(() => {
      this.blink = !this.blink;
    }, 650);
  }

  aboutToDisappear(): void {
    // 离开页面前把当前结果留存到生成会话：再次进入可恢复（编辑界面左滑退出同样不丢）
    if (!this.loading && this.result !== '') {
      GenSession.end(this.genKey(), this.result);
      // 本地草稿兜底：异常退出/进程被杀后重进仍可恢复
      PageDraft.save(getContext(this) as common.UIAbilityContext, this.genKey(), this.result);
    }
    this.leaveGenSession();
        
    if (this.blinkTimer !== -1) {
      clearInterval(this.blinkTimer);
      this.blinkTimer = -1;
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

  /** 模式按钮文案：按当前语言（appLang=en 时返回英文） */
  private modeNames(): string[] {
    void this.appLang;
    return [this.t('rm.topic'), this.t('rm.outline'), this.t('rm.abstract')];
  }

  /** 三种模式的输入占位文案：按当前语言（appLang=en 时返回英文） */
  private placeholders(): string[] {
    void this.appLang;
    return [this.t('rm.ph0'), this.t('rm.ph1'), this.t('rm.ph2')];
  }

  private systemPrompt(): string {
    if (this.mode === 0) {
      return Prompts.researchTopicSystem();
    } else if (this.mode === 1) {
      return Prompts.researchOutlineSystem();
    }
    return Prompts.researchAbstractSystem();
  }

  async generate(): Promise<void> {
    if (this.input.trim() === '') {
      promptAction.showToast({ message: this.t('err.noContent') });
      return;
    }
    this.stopRequested = false;
    this.loading = true;
    this.result = '';
    // 开始新的生成：清除旧草稿，避免旧结果回魂
    PageDraft.clear(getContext(this) as common.UIAbilityContext, this.genKey());
    const remarkPart: string = this.remark.trim() !== '' ? '\n【备注】' + this.remark.trim() : '';
    try {
      const content: string = await AiService.chat(this.systemPrompt(), this.input + remarkPart, (partial: string) => {
        this.result = partial;
        this.scrollLiveToBottom();
      }, false, {
        ctx: getContext(this) as common.UIAbilityContext,
        type: 'research',
        label: I18n.t('page.research'),
        attachments: this.attachFiles
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
    }
  }

  /** 自动保存到历史（开关开启且内容非空时静默保存；content 用于页面已离开时的兜底） */
  private autoSaveHistory(content?: string): void {
    const text: string = content !== undefined && content !== '' ? content : this.result;
    if (text === '') {
      return;
    }
    const ctx = getContext(this) as common.UIAbilityContext;
    const typeLabel: string = I18n.t('page.research');
    HistoryStore.autoAdd(ctx, {
      type: typeLabel,
      title: typeLabel + '-' + this.input.slice(0, 12),
      content: text,
      time: HistoryStore.formatNow()
    });
  }

  saveToHistory(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    const typeLabel: string = I18n.t('page.research');
    HistoryStore.addRecord(ctx, {
      type: typeLabel,
      title: typeLabel + '-' + this.input.slice(0, 12),
      content: this.result,
      time: HistoryStore.formatNow()
    }).then(() => {
      promptAction.showToast({ message: I18n.t('toast.saved') });
    });
  }

  /** 生成中：预览框实时滚动到最底部（等一帧让新内容完成布局） */
  private scrollLiveToBottom(): void {
    setTimeout((): void => {
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
  }

  build() {
    Column({ space: 0 }) {
      PageHeader({ title: this.t('page.research') })

      // 模式切换
      Row({ space: 8 }) {
        ForEach(this.modeNames(), (name: string, index: number) => {
          Button(name)
            .fontFamily(AppFonts.family())
            .fontSize(14)
            .fontColor(this.mode === index ? '#FFFFFF' : this.col('sub'))
            .backgroundColor(this.mode === index ? '#7B61C2' : this.col('card'))
            .height(38)
            .layoutWeight(1)
            .onClick(() => {
              this.mode = index;
              this.result = '';
            })
        }, (name: string) => name)
      }
      .width('100%')
      .padding({ top: 4, bottom: 10 })

      // 输入区
      Column({ space: 10 }) {
        // 生成中：输入区整体置灰并锁定（按钮除外）
        Column({ space: 10 }) {
        TextArea({ text: this.input, placeholder: this.placeholders()[this.mode] })
          .fontFamily(AppFonts.family())
          .width('100%')
          .height(120)
          .fontSize(15)
          .onChange((v: string) => { this.input = v; })

        // 备注（支持语音输入：点击麦克风切换"按住说话"，松手发送，上滑取消）
        VoiceRemarkBox({
          text: $remark,
          disabled: this.loading,
          labelText: this.t('label.remark'),
          placeholderText: this.t('ph.remark')
        })

        // 附件：+ 号选择图片/文档/拍照（上限 10）
        AttachBar({ files: $attachFiles, disabled: this.loading })

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
          Button(this.t('act.research'))
            .fontFamily(AppFonts.family())
            .width('100%')
            .height(44)
            .backgroundColor('#7B61C2')
            .onClick(() => {
              this.generate();
            })
        }
      }
      .width('100%')
      .padding(16)
      .backgroundColor(this.col('card'))
      .borderRadius(14)

      if (this.bottomResult) {
        // 2in1（独立页面）：生成结果统一显示在下半屏大面板，本组件不再内嵌结果区
      } else if (this.loading) {
        if (this.result !== '') {
          // 流式输出中：实时展示已生成内容并自动滚动到底部
          Column() {
            Row({ space: 6 }) {
              LoadingProgress().width(14).height(14).color('#7B61C2')
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
            .scrollBar(BarState.Off)
          }
          .width('100%')
          .layoutWeight(1)
          .padding(16)
          .alignItems(HorizontalAlign.Start)
        } else {
          Row({ space: 10 }) {
            LoadingProgress().width(26).height(26).color('#7B61C2')
            Text(this.t('gen.loading')).fontSize(14).fontColor(this.col('sub'))
              .fontFamily(AppFonts.family())
          }.width('100%').justifyContent(FlexAlign.Center).padding(20)
        }
      } else if (this.result !== '') {
        ResultPanel({
          result: this.result,
          type: I18n.t('page.research'),
          title: I18n.t('page.research') + '-' + this.input.slice(0, 12),
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
          .layoutWeight(1)
          .padding(16)
      } else {
        Row() {
          Text(this.t('hint.common'))
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

      // 底部红色呼吸闪烁水印
      Text(this.t('research.wm'))
        .fontFamily(AppFonts.family())
        .fontSize(10)
        .fontColor('#E11D48')
        .width('100%')
        .textAlign(TextAlign.Center)
        .lineHeight(16)
        .padding({ bottom: 4 })
        .opacity(this.blink ? 1 : 0.25)
        .animation({ duration: 450, curve: Curve.EaseInOut })
    }
    .width('100%')
    .height('100%')
    .padding(12)
    .backgroundColor(this.col('bg'))
  }
}


@Entry
@Component
struct ResearchEntry {

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
      ResearchContent()
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
