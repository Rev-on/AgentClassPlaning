/**
 * 个性化学情报告：输入学生成绩与课堂观察，AI 生成给家长的学情报告（双语界面 + 深浅主题）
 */
import common from '@ohos.app.ability.common';
import promptAction from '@ohos.promptAction';
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
import { StreamPreview } from '../common/components/StreamPreview';

@Component
export struct ReportContent {
  @State studentName: string = I18n.t('def.studentName');
  @State className: string = I18n.t('def.className');
  @State grades: string = I18n.t('def.grades');
  @State observation: string = I18n.t('def.observation');
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
    return 'report';
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
    if (this.studentName.trim() === '') {
      promptAction.showToast({ message: this.t('err.noName') });
      return;
    }
    this.loading = true;
    this.result = '';
    const remarkPart: string = this.remark.trim() !== '' ? '\n【备注】' + this.remark.trim() : '';
    const user: string = `学生姓名：${this.studentName}\n班级：${this.className}\n各科成绩：${this.grades}\n课堂观察记录：${this.observation}\n\n请生成给家长的个性化学情报告。${remarkPart}`;
    try {
      const content: string = await AiService.chat(Prompts.studentReportSystem(), user, (partial: string) => {
        this.result = partial;
      }, false, {
        ctx: getContext(this) as common.UIAbilityContext,
        type: 'report',
        label: I18n.t('page.report')
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

  build() {
    Column({ space: 0 }) {
      PageHeader({ title: this.t('page.report') })

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
            .enabled(!this.loading)
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
            .enabled(!this.loading)
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
          .enabled(!this.loading)
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
          .enabled(!this.loading)

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

        Button(this.loading ? this.t('act.stopGen') : this.t('act.report'))
          .fontFamily(AppFonts.family())
          .width('100%')
          .height(44)
          .backgroundColor(this.loading ? '#9DB8D9' : '#4A90D9')
          .onClick(() => {
            // 生成中：停止当前生成任务；空闲：开始生成
            if (this.loading) {
              AiService.stop('report');
            } else {
              this.generate();
            }
          })
      }
      .width('100%')
      .padding(16)
      .backgroundColor(this.col('card'))
      .borderRadius(14)

      if (this.bottomResult) {
        // 2in1（独立页面）：生成结果统一显示在下半屏大面板，本组件不再内嵌结果区
      } else if (this.loading) {
        // 生成中：实时流式预览区（自动滚动到底部）
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
          type: I18n.t('page.report'),
          title: I18n.t('page.report') + '-' + this.studentName,
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
struct ReportEntry {
  build() {
    Column() {
      ReportContent()
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
