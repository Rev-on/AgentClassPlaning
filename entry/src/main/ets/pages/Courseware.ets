/**
 * 课件大纲：输入课题，AI 生成逐页 PPT 大纲（含配图建议）（双语界面 + 深浅主题）
 */
import common from '@ohos.app.ability.common';
import promptAction from '@ohos.promptAction';
import router from '@ohos.router';
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

/** 从教案页跳转携带的路由参数 */
interface PlanImportParams {
  planText?: string;
}

@Component
export struct CoursewareContent {
  @State subject: string = I18n.t('def.subject');
  @State grade: string = I18n.t('def.grade');
  @State topic: string = I18n.t('def.topic');
  @State usage: string = I18n.t('def.usage');
  @State remark: string = '';
  /** 附件（图片/文档/拍照），随生成请求一起提交 */
  @State attachFiles: AttachFile[] = [];
  @State loading: boolean = false;
  @State result: string = '';
  /** 从教案页导入：非空表示处于"教案导入"模式（隐藏输入框，直接基于教案生成） */
  @State importedPlan: string = '';
  @State importMode: boolean = false;
  /** 生成会话恢复（离开页面后重进仍显示生成中/结果） */
  private sessSub: number = -1;
  /** 实时预览滚动控制器（生成中自动滚到最底部） */
  private liveScroll: Scroller = new Scroller();
  /** 用户是否点击了"停止生成" */
  private stopRequested: boolean = false;

  aboutToAppear(): void {
    // 教案页跳转导入：读取路由参数进入"教案导入"模式（普通入口无参数时为空对象，必须判空）
    const rawParams = router.getParams();
    if (rawParams !== undefined && rawParams !== null) {
      const pr = rawParams as PlanImportParams;
      if (pr.planText !== undefined && pr.planText !== '') {
        this.importedPlan = pr.planText;
        this.importMode = true;
        this.topic = this.t('def.importedPlan');
      }
    }
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
    if (cur !== undefined && !this.importMode) {
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
    return 'courseware';
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

  /** 从原始输出中提取合法 JSON 并格式化为缩进文本；失败返回 null */
  private normalizeJson(raw: string): string | null {
    let text: string = raw.trim();
    const fenceStart: number = text.indexOf('```');
    if (fenceStart >= 0) {
      const fenceEnd: number = text.lastIndexOf('```');
      if (fenceEnd > fenceStart) {
        text = text.substring(fenceStart + 3, fenceEnd).trim();
      }
    }
    const s: number = text.indexOf('[');
    const e: number = text.lastIndexOf(']');
    if (s < 0 || e <= s) {
      return null;
    }
    text = text.substring(s, e + 1);
    let obj: object | null = null;
    try {
      obj = JSON.parse(text) as object;
    } catch (err) {
      return null;
    }
    if (obj === null || !Array.isArray(obj)) {
      return null;
    }
    return JSON.stringify(obj, null, 2);
  }

  async generate(): Promise<void> {
    const importText: string = this.importMode ? this.importedPlan : '';
    if (!this.importMode && this.topic.trim() === '') {
      promptAction.showToast({ message: this.t('err.noTopic') });
      return;
    }
    this.stopRequested = false;
    this.loading = true;
    this.result = '';
    // 开始新的生成：清除旧草稿，避免旧结果回魂
    PageDraft.clear(getContext(this) as common.UIAbilityContext, this.genKey());
    let user: string = '';
    if (importText !== '') {
      // 教案导入模式：直接基于已生成的教案内容生成配套课件大纲
      user = '以下是一份已经生成并通过审阅的完整教案：\n' + importText +
        '\n\n请基于该教案的课题、结构重难点与教学环节，生成配套的逐页课件大纲（严格 JSON 格式，字段与页面顺序同常规课件大纲要求）。';
    } else {
      const remarkPart: string = this.remark.trim() !== '' ? '\n【备注】' + this.remark.trim() : '';
      user = `学科：${this.subject}\n年级：${this.grade}\n课题：${this.topic}\n课型/用途：${this.usage}\n\n请生成该课题的逐页课件大纲（JSON 格式）。${remarkPart}`;
    }
    try {
      const content: string = await AiService.chat(Prompts.coursewareSystem(), user, (partial: string) => {
        this.result = partial;
        this.scrollLiveToBottom();
      }, true, {
        ctx: getContext(this) as common.UIAbilityContext,
        type: 'courseware',
        label: I18n.t('page.courseware'),
        attachments: this.attachFiles
      });
      if (this.stopRequested) {
        // 用户主动停止：保留已生成的部分文本，不覆盖、不入历史
        this.stopRequested = false;
        return;
      }
      const pretty: string | null = this.normalizeJson(content);
      const finalText: string = pretty !== null ? pretty : content;
      if (pretty !== null) {
        this.result = pretty;
      } else {
        this.result = content;
        promptAction.showToast({ message: this.t('err.jsonInvalid') });
      }
      this.autoSaveHistory(finalText);
      // 结果即时落盘草稿：任何异常退出/进程被杀都能恢复
      PageDraft.save(getContext(this) as common.UIAbilityContext, this.genKey(), finalText);
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
    const typeLabel: string = I18n.t('page.courseware');
    HistoryStore.autoAdd(ctx, {
      type: typeLabel,
      title: typeLabel + '-' + this.topic,
      content: text,
      time: HistoryStore.formatNow()
    });
  }

  saveToHistory(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    const typeLabel: string = I18n.t('page.courseware');
    HistoryStore.addRecord(ctx, {
      type: typeLabel,
      title: typeLabel + '-' + this.topic,
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
      PageHeader({ title: this.t('page.courseware') })

      Column({ space: 10 }) {
        // 生成中：输入区整体置灰并锁定（按钮除外）
        Column({ space: 10 }) {
        // 教案导入模式：隐藏全部原有输入框（学科/年级/课题/课型/备注），只保留生成按钮与提示
        if (!this.importMode) {
        Row({ space: 10 }) {
          Text(this.t('label.subject')).fontSize(15).fontColor(this.col('title')).width(86)
            .fontFamily(AppFonts.family())
          TextInput({ text: this.subject, placeholder: this.t('ph.subject') })
            .fontFamily(AppFonts.family())
            .layoutWeight(1)
            .height(42)
            .onChange((v: string) => { this.subject = v; })
        }
        .width('100%')
        Row({ space: 10 }) {
          Text(this.t('label.grade')).fontSize(15).fontColor(this.col('title')).width(86)
            .fontFamily(AppFonts.family())
          TextInput({ text: this.grade, placeholder: this.t('ph.grade') })
            .fontFamily(AppFonts.family())
            .layoutWeight(1)
            .height(42)
            .onChange((v: string) => { this.grade = v; })
        }
        .width('100%')
        Row({ space: 10 }) {
          Text(this.t('label.topic')).fontSize(15).fontColor(this.col('title')).width(86)
            .fontFamily(AppFonts.family())
          TextInput({ text: this.topic, placeholder: this.t('ph.topic') })
            .fontFamily(AppFonts.family())
            .layoutWeight(1)
            .height(42)
            .onChange((v: string) => { this.topic = v; })
        }
        .width('100%')
        Row({ space: 10 }) {
          Text(this.t('label.usage')).fontSize(15).fontColor(this.col('title')).width(86)
            .fontFamily(AppFonts.family())
          TextInput({ text: this.usage, placeholder: this.t('ph.usage') })
            .fontFamily(AppFonts.family())
            .layoutWeight(1)
            .height(42)
            .onChange((v: string) => { this.usage = v; })
        }
        .width('100%')
        // 备注（支持语音输入：点击麦克风切换"按住说话"，松手发送，上滑取消）
        VoiceRemarkBox({
          text: $remark,
          disabled: this.loading,
          labelText: this.t('label.remark'),
          placeholderText: this.t('ph.remark')
        })
        }

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
          Button(this.t('act.courseware'))
            .fontFamily(AppFonts.family())
            .width('100%')
            .height(44)
            .backgroundColor('#F0A93F')
            .onClick(() => {
              this.generate();
            })
        }
        if (this.importMode) {
          // 教案导入模式：生成按钮下方绿字提示
          Text(this.t('import.planImported'))
            .fontFamily(AppFonts.family())
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor('#2E9E63')
            .width('100%')
            .padding({ top: 2 })
        }
        Text(this.t('hint.coursewareJson'))
          .fontFamily(AppFonts.family())
          .fontSize(11)
          .fontColor(this.col('hint'))
          .width('100%')
          .lineHeight(16)
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
              LoadingProgress().width(14).height(14).color('#F0A93F')
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
            LoadingProgress().width(26).height(26).color('#F0A93F')
            Text(this.t('gen.loading')).fontSize(14).fontColor(this.col('sub'))
              .fontFamily(AppFonts.family())
          }.width('100%').justifyContent(FlexAlign.Center).padding(20)
        }
      } else if (this.result !== '') {
        ResultPanel({
          result: this.result,
          type: I18n.t('page.courseware'),
          title: I18n.t('page.courseware') + '-' + this.topic,
          exportMode: 'pptx',
          slideMode: true,
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
    }
    .width('100%')
    .height('100%')
    .padding(12)
    .backgroundColor(this.col('bg'))
  }
}


@Entry
@Component
struct CoursewareEntry {

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
      CoursewareContent()
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
