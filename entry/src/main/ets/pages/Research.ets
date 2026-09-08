/**
 * 教研科研辅助：选题建议 / 论文大纲 / 摘要润色 三种模式（双语界面 + 深浅主题）
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
import { PageHeader } from '../common/components/PageHeader';
import { ResultPanel } from '../common/components/ResultPanel';

@Component
export struct ResearchContent {
  @State mode: number = 0;   // 0 选题建议 1 论文大纲 2 摘要润色
  @State input: string = '我教八年级物理，想研究如何利用错题本提升学生物理成绩，请给选题建议';
  @State remark: string = '';
  @State loading: boolean = false;
  @State result: string = '';
  /** 生成会话恢复（离开页面后重进仍显示生成中/结果） */
  private sessSub: number = -1;

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
    this.loading = true;
    this.result = '';
    const remarkPart: string = this.remark.trim() !== '' ? '\n【备注】' + this.remark.trim() : '';
    try {
      const content: string = await AiService.chat(this.systemPrompt(), this.input + remarkPart, (partial: string) => {
        this.result = partial;
      }, false, {
        ctx: getContext(this) as common.UIAbilityContext,
        type: 'research',
        label: I18n.t('page.research')
      });
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
        TextArea({ text: this.input, placeholder: this.placeholders()[this.mode] })
          .fontFamily(AppFonts.family())
          .width('100%')
          .height(120)
          .fontSize(15)
          .onChange((v: string) => { this.input = v; })

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

        Button(this.loading ? this.t('gen.loading') : this.t('act.research'))
          .fontFamily(AppFonts.family())
          .width('100%')
          .height(44)
          .backgroundColor(this.loading ? '#B3A3D9' : '#7B61C2')
          .enabled(!this.loading)
          .onClick(() => {
            this.generate();
          })
      }
      .width('100%')
      .padding(16)
      .backgroundColor(this.col('card'))
      .borderRadius(14)

      if (this.bottomResult) {
        // 2in1（独立页面）：生成结果统一显示在下半屏大面板，本组件不再内嵌结果区
      } else if (this.loading) {
        Row({ space: 10 }) {
          LoadingProgress().width(26).height(26).color('#7B61C2')
          Text(this.t('gen.loading')).fontSize(14).fontColor(this.col('sub'))
            .fontFamily(AppFonts.family())
        }.width('100%').justifyContent(FlexAlign.Center).padding(20)
      } else if (this.result !== '') {
        ResultPanel({
          result: this.result,
          type: I18n.t('page.research'),
          title: I18n.t('page.research') + '-' + this.input.slice(0, 12),
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
