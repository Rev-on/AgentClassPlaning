/**
 * 课件大纲：输入课题，AI 生成逐页 PPT 大纲（含配图建议）（双语界面 + 深浅主题）
 */
import common from '@ohos.app.ability.common';
import promptAction from '@ohos.promptAction';
import router from '@ohos.router';
import { AiService } from '../common/AiService';
import { GenSession, GenSessionState } from '../common/GenSession';
import { Prompts } from '../common/Prompts';
import { HistoryStore } from '../common/HistoryStore';
import { I18n } from '../common/I18n';
import { AppTheme } from '../common/AppTheme';
import { AppFonts } from '../common/AppFonts';
import { PageHeader } from '../common/components/PageHeader';
import { ResultPanel } from '../common/components/ResultPanel';

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
  @State loading: boolean = false;
  @State result: string = '';
  /** 从教案页导入：非空表示处于"教案导入"模式（隐藏输入框，直接基于教案生成） */
  @State importedPlan: string = '';
  @State importMode: boolean = false;
  /** 生成会话恢复（离开页面后重进仍显示生成中/结果） */
  private sessSub: number = -1;

  aboutToAppear(): void {
    // 教案页跳转导入：读取路由参数进入"教案导入"模式（普通入口无参数时为空对象，必须判空）
    const rawParams = router.getParams();
    if (rawParams !== undefined && rawParams !== null) {
      const pr = rawParams as PlanImportParams;
      if (pr.planText !== undefined && pr.planText !== '') {
        this.importedPlan = pr.planText;
        this.importMode = true;
        this.topic = I18n.currentLang() === 'en' ? 'Imported Plan' : '教案导入';
      }
    }
    this.resumeGenSession();
  }

  aboutToDisappear(): void {
    this.leaveGenSession();
  }

  private resumeGenSession(): void {
    const cur: GenSessionState | undefined = GenSession.stateOf(this.genKey());
    if (cur !== undefined && !this.importMode) {
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
    this.loading = true;
    this.result = '';
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
      }, true, {
        ctx: getContext(this) as common.UIAbilityContext,
        type: 'courseware',
        label: I18n.t('page.courseware')
      });
      const pretty: string | null = this.normalizeJson(content);
      const finalText: string = pretty !== null ? pretty : content;
      if (pretty !== null) {
        this.result = pretty;
      } else {
        this.result = content;
        promptAction.showToast({ message: this.t('err.jsonInvalid') });
      }
      this.autoSaveHistory(finalText);
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

  build() {
    Column({ space: 0 }) {
      PageHeader({ title: this.t('page.courseware') })

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
        }

        Button(this.loading ? this.t('gen.loading') : this.t('act.courseware'))
          .fontFamily(AppFonts.family())
          .width('100%')
          .height(44)
          .backgroundColor(this.loading ? '#E9C98F' : '#F0A93F')
          .enabled(!this.loading)
          .onClick(() => {
            this.generate();
          })
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
        Row({ space: 10 }) {
          LoadingProgress().width(26).height(26).color('#F0A93F')
          Text(this.t('gen.loading')).fontSize(14).fontColor(this.col('sub'))
            .fontFamily(AppFonts.family())
        }.width('100%').justifyContent(FlexAlign.Center).padding(20)
      } else if (this.result !== '') {
        ResultPanel({
          result: this.result,
          type: I18n.t('page.courseware'),
          title: I18n.t('page.courseware') + '-' + this.topic,
          exportMode: 'pptx',
          slideMode: true,
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
struct CoursewareEntry {
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
