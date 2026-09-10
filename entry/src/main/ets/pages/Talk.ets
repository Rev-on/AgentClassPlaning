/**
 * 沟通话术建议：老师描述家校沟通困难，AI 生成得体话术与避坑提示（双语界面 + 深浅主题）
 * 说明：下拉选项按界面语言显示中/英；发送给 AI 的字段值保留中文，便于生成内容
 */
import common from '@ohos.app.ability.common';
import promptAction from '@ohos.promptAction';
import { AiService } from '../common/AiService';
import { GenSession, GenSessionState } from '../common/GenSession';
import { Prompts } from '../common/Prompts';
import { HistoryStore } from '../common/HistoryStore';
import { I18n } from '../common/I18n';
import { AppTheme } from '../common/AppTheme';
import { AppFonts } from '../common/AppFonts';
import { AttachBar } from '../common/components/AttachBar';
import { AttachFile } from '../common/AttachTypes';
import { PageHeader } from '../common/components/PageHeader';
import { ResultPanel } from '../common/components/ResultPanel';
import { RichBox } from '../common/components/RichBox';
import { RichHtml } from '../common/RichHtml';

@Component
export struct TalkContent {
  private sceneZh: string[] = ['学习退步沟通', '课堂表现反馈', '作业问题沟通', '考试后安抚', '家长会发言'];
  private toneZh: string[] = ['温和沟通', '正式规范', '激励引导'];

  @State sceneIndex: number = 0;
  @State toneIndex: number = 0;
  @State situation: string = '小明最近两次数学测验成绩下滑明显，从85分降到68分。家长比较焦虑，希望了解原因。';
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

  aboutToAppear(): void {
    this.resumeGenSession();
  }

  aboutToDisappear(): void {
    // 离开页面前把当前结果留存到生成会话：再次进入可恢复（编辑界面左滑退出同样不丢）
    if (!this.loading && this.result !== '') {
      GenSession.end(this.genKey(), this.result);
    }
    this.leaveGenSession();
        
  }

  private resumeGenSession(): void {
    const cur: GenSessionState | undefined = GenSession.stateOf(this.genKey());
    if (cur !== undefined) {
      if (cur.phase === 'busy' && this.result === '') {
        this.loading = true;
      } else if (cur.phase === 'done' && this.result === '') {
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
        this.result = s.text;
        this.loading = false;
      } else {
        this.loading = false;
      }
    });
  }

  private leaveGenSession(): void {
    if (this.sessSub >= 0) {
      GenSession.unsubscribe(this.genKey(), this.sessSub);
      this.sessSub = -1;
    }
  }

  private genKey(): string {
    return 'talk';
  }
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

  /** 界面显示的沟通场景选项（按界面语言取词典，talk.s1..s5） */
  private sceneOptions(): SelectOption[] {
    const opts: SelectOption[] = [];
    for (let i = 0; i < this.sceneZh.length; i++) {
      const opt: SelectOption = { value: this.t('talk.s' + (i + 1)) };
      opts.push(opt);
    }
    return opts;
  }

  /** 界面显示的语气选项（按界面语言取词典，talk.t1..t3） */
  private toneOptions(): SelectOption[] {
    const opts: SelectOption[] = [];
    for (let i = 0; i < this.toneZh.length; i++) {
      const opt: SelectOption = { value: this.t('talk.t' + (i + 1)) };
      opts.push(opt);
    }
    return opts;
  }

  /** 当前场景的界面显示文本 */
  private sceneLabel(): string {
    return this.t('talk.s' + (this.sceneIndex + 1));
  }

  /** 当前语气的界面显示文本 */
  private toneLabel(): string {
    return this.t('talk.t' + (this.toneIndex + 1));
  }

  /** 发送给 AI 的沟通场景（保留中文） */
  private scene(): string {
    return this.sceneZh[this.sceneIndex];
  }

  /** 发送给 AI 的期望语气（保留中文） */
  private tone(): string {
    return this.toneZh[this.toneIndex];
  }

  async generate(): Promise<void> {
    if (this.situation.trim() === '') {
      promptAction.showToast({ message: this.t('err.noSituation') });
      return;
    }
    this.stopRequested = false;
    this.loading = true;
    this.result = '';
    const remarkPart: string = this.remark.trim() !== '' ? '\n【备注】' + this.remark.trim() : '';
    const user: string = `沟通场景：${this.scene()}\n学生情况描述：${this.situation}\n期望语气：${this.tone()}\n\n请生成沟通话术建议。${remarkPart}`;
    try {
      const content: string = await AiService.chat(Prompts.talkSystem(), user, (partial: string) => {
        this.result = partial;
        this.scrollLiveToBottom();
      }, false, {
        ctx: getContext(this) as common.UIAbilityContext,
        type: 'talk',
        label: I18n.t('page.talk'),
        attachments: this.attachFiles
      });
      if (this.stopRequested) {
        // 用户主动停止：保留已生成的部分文本，不覆盖、不入历史
        this.stopRequested = false;
        return;
      }
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
    const typeLabel: string = I18n.t('page.talk');
    HistoryStore.autoAdd(ctx, {
      type: typeLabel,
      title: typeLabel + '-' + this.sceneLabel(),
      content: text,
      time: HistoryStore.formatNow()
    });
  }

  saveToHistory(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    const typeLabel: string = I18n.t('page.talk');
    HistoryStore.addRecord(ctx, {
      type: typeLabel,
      title: typeLabel + '-' + this.sceneLabel(),
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
      PageHeader({ title: this.t('page.talk') })

      Column({ space: 10 }) {
        // 生成中：输入区整体置灰并锁定（按钮除外）
        Column({ space: 10 }) {
        Row({ space: 10 }) {
          Text(this.t('label.scene')).fontSize(15).fontColor(this.col('title')).width(86)
            .fontFamily(AppFonts.family())
          Select(this.sceneOptions())
            .selected(this.sceneIndex)
            .value(this.sceneLabel())
            .layoutWeight(1)
            .onSelect((index: number) => {
              this.sceneIndex = index;
            })
        }
        .width('100%')
        Row({ space: 10 }) {
          Text(this.t('label.tone')).fontSize(15).fontColor(this.col('title')).width(86)
            .fontFamily(AppFonts.family())
          Select(this.toneOptions())
            .selected(this.toneIndex)
            .value(this.toneLabel())
            .layoutWeight(1)
            .onSelect((index: number) => {
              this.toneIndex = index;
            })
        }
        .width('100%')
        Text(this.t('talk.situationDesc'))
          .fontFamily(AppFonts.family())
          .fontSize(13)
          .fontColor(this.col('title'))
          .width('100%')
        TextArea({ text: this.situation, placeholder: this.t('ph.situation') })
          .fontFamily(AppFonts.family())
          .width('100%')
          .height(90)
          .fontSize(14)
          .onChange((v: string) => { this.situation = v; })

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
          Button(this.t('act.talk'))
            .fontFamily(AppFonts.family())
            .width('100%')
            .height(44)
            .backgroundColor('#D9534F')
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
              LoadingProgress().width(14).height(14).color('#D9534F')
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
            LoadingProgress().width(26).height(26).color('#D9534F')
            Text(this.t('gen.loading')).fontSize(14).fontColor(this.col('sub'))
              .fontFamily(AppFonts.family())
          }.width('100%').justifyContent(FlexAlign.Center).padding(20)
        }
      } else if (this.result !== '') {
        ResultPanel({
          result: this.result,
          type: I18n.t('page.talk'),
          title: I18n.t('page.talk') + '-' + this.sceneLabel(),
          onSave: () => this.saveToHistory(),
          onEdited: (t: string): void => {
            this.result = t;
            // 同步到生成会话：离开页面/再次进入时不丢最新内容（含编辑结果）
            GenSession.end(this.genKey(), t);
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
    }
    .width('100%')
    .height('100%')
    .padding(12)
    .backgroundColor(this.col('bg'))
  }
}


@Entry
@Component
struct TalkEntry {

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
      TalkContent()
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
