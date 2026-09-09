/**
 * 教案生成：输入课题信息，AI 生成结构化完整教案（双语界面 + 深浅主题）
 */
import common from '@ohos.app.ability.common';
import promptAction from '@ohos.promptAction';
import router from '@ohos.router';
import { AiService, CancelledError } from '../common/AiService';
import { GenSession, GenSessionState } from '../common/GenSession';
import { Prompts } from '../common/Prompts';
import { HistoryStore } from '../common/HistoryStore';
import { I18n } from '../common/I18n';
import { AppTheme } from '../common/AppTheme';
import { AppFonts } from '../common/AppFonts';
import { PageHeader } from '../common/components/PageHeader';
import { ResultPanel } from '../common/components/ResultPanel';
import { StreamPreview } from '../common/components/StreamPreview';

@Component
export struct PlanContent {
  @State subject: string = I18n.t('def.subject');
  @State version: string = I18n.t('def.version');
  @State grade: string = I18n.t('def.grade');
  @State topic: string = I18n.t('def.topic');
  @State period: string = I18n.t('def.period');
  @State remark: string = '';
  @State loading: boolean = false;
  @State result: string = '';
  /** 生成会话恢复（离开页面后重进仍显示生成中/结果） */
  private sessSub: number = -1;

  aboutToAppear(): void {
    this.resumeGenSession();
  }

  aboutToDisappear(): void {
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
    return 'plan';
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

  async generate(): Promise<void> {
    if (this.topic.trim() === '') {
      promptAction.showToast({ message: this.t('err.noTopic') });
      return;
    }
    this.loading = true;
    this.result = '';
    const remarkPart: string = this.remark.trim() !== '' ? '\n【备注】' + this.remark.trim() : '';
    const user: string = `学科：${this.subject}\n教材版本：${this.version}\n年级：${this.grade}\n课题：${this.topic}\n课时：${this.period}\n\n请生成该课题的完整教案。${remarkPart}`;
    try {
      const content: string = await AiService.chat(Prompts.planSystem(), user, (partial: string) => {
        this.result = partial;
      }, false, {
        ctx: getContext(this) as common.UIAbilityContext,
        type: 'plan',
        label: I18n.t('page.plan')
      });
      this.result = content;
      this.autoSaveHistory(content);
    } catch (e) {
      if (e instanceof CancelledError) {
        // 用户主动停止：提示已停止而非生成失败
        promptAction.showToast({ message: this.t('gen.stopped') });
      } else {
        promptAction.showToast({ message: this.t('err.genFail') + (e as Error).message });
      }
    } finally {
      this.loading = false;
    }
  }

  /** 跳转课件大纲页，并把刚生成的教案富文本作为导入内容传递过去 */
  private jumpToCourseware(): void {
    if (this.result === '') {
      return;
    }
    router.pushUrl({
      url: 'pages/Courseware',
      params: { planText: this.result }
    }).catch((err: Error) => {
      promptAction.showToast({ message: I18n.t('err.jumpFail') + ' ' + err.message });
    });
  }

  /** 自动保存到历史（开关开启且内容非空时静默保存；content 用于页面已离开时的兜底） */
  private autoSaveHistory(content?: string): void {
    const text: string = content !== undefined && content !== '' ? content : this.result;
    if (text === '') {
      return;
    }
    const ctx = getContext(this) as common.UIAbilityContext;
    const typeLabel: string = I18n.t('page.plan');
    HistoryStore.autoAdd(ctx, {
      type: typeLabel,
      title: typeLabel + '-' + this.topic,
      content: text,
      time: HistoryStore.formatNow()
    });
  }

  saveToHistory(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    const typeLabel: string = I18n.t('page.plan');
    HistoryStore.addRecord(ctx, {
      type: typeLabel,
      title: typeLabel + '-' + this.topic,
      content: this.result,
      time: HistoryStore.formatNow()
    }).then(() => {
      promptAction.showToast({ message: I18n.t('toast.saved') });
    });
  }

  build() {
    Column({ space: 0 }) {
      PageHeader({ title: this.t('page.plan') })

      Column({ space: 10 }) {
        Row({ space: 10 }) {
          Text(this.t('label.subject')).fontSize(15).fontColor(this.col('title')).width(86)
            .fontFamily(AppFonts.family())
          TextInput({ text: this.subject, placeholder: this.t('ph.subject') })
            .fontFamily(AppFonts.family())
            .layoutWeight(1)
            .height(42)
            .onChange((v: string) => { this.subject = v; })
            .enabled(!this.loading)
            .enabled(!this.loading)
        }
        .width('100%')
        Row({ space: 10 }) {
          Text(this.t('label.version')).fontSize(15).fontColor(this.col('title')).width(86)
            .fontFamily(AppFonts.family())
          TextInput({ text: this.version, placeholder: this.t('ph.version') })
            .fontFamily(AppFonts.family())
            .layoutWeight(1)
            .height(42)
            .onChange((v: string) => { this.version = v; })
            .enabled(!this.loading)
            .enabled(!this.loading)
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
            .enabled(!this.loading)
            .enabled(!this.loading)
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
            .enabled(!this.loading)
            .enabled(!this.loading)
        }
        .width('100%')
        Row({ space: 10 }) {
          Text(this.t('label.period')).fontSize(15).fontColor(this.col('title')).width(86)
            .fontFamily(AppFonts.family())
          TextInput({ text: this.period, placeholder: this.t('ph.period') })
            .fontFamily(AppFonts.family())
            .layoutWeight(1)
            .height(42)
            .onChange((v: string) => { this.period = v; })
            .enabled(!this.loading)
            .enabled(!this.loading)
        }
        .width('100%')
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
          .enabled(!this.loading)

        if (!this.loading && this.result !== '') {
          // 生成完成：主按钮切换为"重新生成"与"跳转至课件大纲生成"
          Row({ space: 10 }) {
            Button(this.t('act.regen'))
              .fontFamily(AppFonts.family())
              .fontSize(15)
              .height(44)
              .layoutWeight(1)
              .backgroundColor('#4A90D9')
              .onClick(() => {
                this.generate();
              })
            Button(this.t('act.toCourseware'))
              .fontFamily(AppFonts.family())
              .fontSize(15)
              .height(44)
              .layoutWeight(1)
              .backgroundColor('#F0A93F')
              .onClick(() => {
                this.jumpToCourseware();
              })
          }
          .width('100%')
        } else {
          Button(this.loading ? this.t('act.stopGen') : this.t('act.plan'))
            .fontFamily(AppFonts.family())
            .width('100%')
            .height(44)
            .backgroundColor(this.loading ? '#9DB8D9' : '#4A90D9')
            .onClick(() => {
              if (this.loading) {
                // 生成中再次点击 = 停止生成（本地停止 + 服务端取消）
                AiService.stop(this.genKey());
              } else {
                this.generate();
              }
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
        // 流式输出中：实时预览已生成内容，随增量自动滚动到底部
        StreamPreview({
          text: this.result,
          plain: false,
          accent: '#4A90D9',
          label: this.t('gen.streaming'),
          labelColor: this.col('sub')
        })
          .layoutWeight(1)
          .padding(16)
      } else if (this.result !== '') {
        ResultPanel({
          result: this.result,
          type: I18n.t('page.plan'),
          title: I18n.t('page.plan') + '-' + this.topic,
          onSave: () => this.saveToHistory(),
          onEdited: (t: string): void => {
            this.result = t;
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
struct PlanEntry {
  build() {
    Column() {
      PlanContent()
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
