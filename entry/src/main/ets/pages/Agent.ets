/**
 * 智能备课 Agent：以“对话框”方式承接用户一句自然语言备课需求，
 * 由 AgentEngine 编排“教案→课件→分层练习”全流程（含质量自检与自动重生成）。
 *  - 分步气泡：编排每一步（思考/生成/完成/重试/错误）以气泡实时呈现；
 *  - 自动读取任教信息（科目/年级/册次/基础水平），并按教材目录推进下一课课题；
 *  - 生成完成后，每个产物气泡下方出现“分享”按钮，经系统文件保存窗口导出产物。
 */
import common from '@ohos.app.ability.common';
import promptAction from '@ohos.promptAction';
import { I18n } from '../common/I18n';
import { AppTheme } from '../common/AppTheme';
import { AppFonts } from '../common/AppFonts';
import { AppSettings } from '../common/AppSettings';
import { SafeInsets } from '../common/SafeInsets';
import { PageHeader } from '../common/components/PageHeader';
import { RichBox } from '../common/components/RichBox';
import { AgentEngine, AgentArtifact, AgentEvent } from '../common/AgentEngine';
import { TeachingProfile } from '../common/TeachingProfile';
import { ShareService } from '../common/ShareService';

/** 一条对话消息：role=user 为用户输入；role=agent 为编排过程气泡 */
class AgentMsg {
  role: string = 'agent';
  kind: string = 'text';
  text: string = '';
  artifact: AgentArtifact | undefined = undefined;
}

@Component
export struct AgentContent {
  @StorageProp('appLang') appLang: string = 'zh';
  @StorageProp('appResolvedTheme') resolvedTheme: string = 'light';
  /** 顶部状态栏/刘海避让高度 */
  @State topInset: number = 0;
  /** 对话消息列表 */
  @State messages: AgentMsg[] = [];
  /** 底部输入框内容 */
  @State input: string = '';
  /** 是否正在编排 */
  @State loading: boolean = false;
  /** 当前展开查看详情的产物气泡下标（-1=无展开） */
  @State expandIdx: number = -1;
  /** 已初始化空态提示 */
  private emptyShown: boolean = false;
  private scroller: Scroller = new Scroller();

  private t(key: string): string {
    void this.appLang;
    return I18n.t(key);
  }

  private col(key: string): string {
    void this.resolvedTheme;
    return AppTheme.color(key, this.resolvedTheme);
  }

  aboutToAppear(): void {
    SafeInsets.topInset(getContext(this) as common.UIAbilityContext).then((v: number): void => {
      this.topInset = v;
    });
    if (this.messages.length === 0) {
      const m: AgentMsg = new AgentMsg();
      m.role = 'agent';
      m.kind = 'empty';
      m.text = this.t('agent.empty');
      this.messages.push(m);
      this.emptyShown = true;
    }
  }

  /** 聊天列表滚动到底（等一帧让新增气泡完成布局） */
  private scrollBottom(): void {
    setTimeout((): void => {
      try {
        this.scroller.scrollEdge(Edge.Bottom);
      } catch (e) {
        // 列表尚未挂载时忽略
      }
    }, 40);
  }

  /** 发起一次 Agent 编排 */
  private async runAgent(): Promise<void> {
    const req: string = this.input.trim();
    if (req === '') {
      promptAction.showToast({ message: this.t('agent.needInput') });
      return;
    }
    // 空态提示在首次输入后移除
    if (this.emptyShown) {
      this.messages = this.messages.filter((m: AgentMsg): boolean => m.kind !== 'empty');
      this.emptyShown = false;
      this.expandIdx = -1;
    }
    this.loading = true;
    const um: AgentMsg = new AgentMsg();
    um.role = 'user';
    um.kind = 'text';
    um.text = req;
    this.messages.push(um);
    this.input = '';
    this.scrollBottom();

    const ctx = getContext(this) as common.UIAbilityContext;
    try {
      const result = await AgentEngine.run(ctx, req, (e: AgentEvent): void => {
        const m: AgentMsg = new AgentMsg();
        m.role = 'agent';
        m.kind = e.kind;
        m.text = e.text;
        if (e.artifact !== undefined) {
          m.artifact = e.artifact;
        }
        this.messages.push(m);
        this.scrollBottom();
      });
      // 编排成功：把本次已教课题记录为首课，教材目录据此推进下一课（下次自动带出）
      if (result.ok) {
        try {
          const teach = await TeachingProfile.current(ctx);
          if (teach.nextTopic !== '') {
            await AppSettings.saveTeachLastTopic(ctx, teach.nextTopic);
          }
        } catch (e) {
          // 记录失败不阻塞
        }
      }
    } catch (e) {
      const mf: AgentMsg = new AgentMsg();
      mf.role = 'agent';
      mf.kind = 'error';
      mf.text = this.t('err.genFail') + ((e as Error).message !== undefined ? (e as Error).message : '');
      this.messages.push(mf);
      this.scrollBottom();
    } finally {
      this.loading = false;
      this.scrollBottom();
    }
  }

  /** 分享某一步产物：kind=courseware→PPTX；其余→Word（系统分享面板） */
  private share(art: AgentArtifact | undefined, idx: number): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    if (art === undefined || art.content === '') {
      return;
    }
    ShareService.exportAndShare(ctx, art.key === 'courseware' ? 'courseware' : 'doc', art.label,
      art.content, 'agentShare' + (idx + 1));
  }

  /** 产物气泡标题（本地化显示） */
  private artTitle(key: string): string {
    if (key === 'plan') {
      return this.t('agent.plan');
    }
    if (key === 'courseware') {
      return this.t('agent.courseware');
    }
    if (key === 'quiz') {
      return this.t('agent.quiz');
    }
    return this.t('agent.plan');
  }

  /** 用户气泡 */
  @Builder
  userBubble(text: string) {
    Column() {
      Text(text)
        .fontFamily(AppFonts.family())
        .fontSize(15)
        .fontColor('#FFFFFF')
        .lineHeight(22)
        .width('100%')
    }
    .padding(12)
    .backgroundColor('#4A90D9')
    .borderRadius(12)
    .constraintSize({ maxWidth: '86%' })
    .alignItems(HorizontalAlign.Start)
  }

  /** 普通信息/思考/重试/错误/完成 气泡 */
  @Builder
  plainBubble(kind: string, text: string) {
    Row({ space: 8 }) {
      if (kind === 'thinking') {
        LoadingProgress().width(14).height(14).color('#4A90D9')
      } else if (kind === 'info') {
        Text('●').fontSize(10).fontColor('#4A90D9')
      } else if (kind === 'retry') {
        Text('↻').fontSize(14).fontColor('#E67E22')
      } else if (kind === 'error') {
        Text('!').fontSize(14).fontColor('#C0392B')
      } else if (kind === 'done') {
        Text('✓').fontSize(14).fontColor('#27AE60')
      }
      Text(text)
        .fontFamily(AppFonts.family())
        .fontSize(14)
        .fontColor(kind === 'error' ? '#C0392B'
          : kind === 'retry' ? '#E67E22' : this.col('text'))
        .lineHeight(21)
        .layoutWeight(1)
    }
    .width('100%')
    .padding({ top: 4, bottom: 4 })
    .alignItems(VerticalAlign.Top)
  }

  /** 产物步骤气泡：标题 + 展开预览 + 分享按钮（生成完成后可见） */
  @Builder
  stepBubble(msg: AgentMsg, idx: number) {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Text('📄')
          .fontSize(16)
          .fontColor('#4A90D9')
        Text(this.artTitle(msg.artifact !== undefined ? msg.artifact.key : 'plan'))
          .fontFamily(AppFonts.family())
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.col('title'))
          .layoutWeight(1)
        Text(this.t('agent.view'))
          .fontFamily(AppFonts.family())
          .fontSize(12)
          .fontColor('#4A90D9')
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (this.expandIdx === idx && msg.artifact !== undefined) {
        // 课件为 OOXML 分页片段，不适合富文本预览，仅提示并可直接分享导出
        if (msg.artifact.key === 'courseware') {
          Text(this.t('agent.coursewareHint'))
            .fontFamily(AppFonts.family())
            .fontSize(12)
            .fontColor(this.col('hint'))
            .lineHeight(18)
            .width('100%')
        } else if (msg.artifact.content !== '') {
          Scroll() {
            RichBox({ html: msg.artifact.content })
              .width('100%')
          }
          .width('100%')
          .height(240)
          .align(Alignment.TopStart)
          .scrollBar(BarState.Auto)
        }
      }

      // 生成完成后，气泡下方显示“分享”按钮：拉起系统分享面板分发产物
      if (!this.loading && msg.artifact !== undefined) {
        Button() {
          Row({ space: 6 }) {
            Text('⇪').fontSize(14).fontColor('#FFFFFF')
            Text(this.t('agent.share')).fontSize(13).fontColor('#FFFFFF')
          }
        }
        .width('100%')
        .height(36)
        .backgroundColor('#4A90D9')
        .borderRadius(8)
        .id('agentShare' + (idx + 1))
        .onClick(() => {
          this.share(msg.artifact, idx);
        })
      }
    }
    .width('100%')
    .padding(12)
    .backgroundColor(this.col('card'))
    .borderRadius(12)
    .alignItems(HorizontalAlign.Start)
    .onClick(() => {
      this.expandIdx = this.expandIdx === idx ? -1 : idx;
    })
  }

  /** 一条对话消息渲染 */
  @Builder
  renderMsg(msg: AgentMsg, idx: number) {
    if (msg.role === 'user') {
      Column({ space: 6 }) {
        Text(this.t('agent.you'))
          .fontFamily(AppFonts.family())
          .fontSize(11)
          .fontColor(this.col('faint'))
          .width('100%')
          .textAlign(TextAlign.End)
        this.userBubble(msg.text)
      }
      .width('100%')
      .alignItems(HorizontalAlign.End)
    } else {
      Row({ space: 8 }) {
        Text('🤖')
          .fontSize(16)
          .fontColor('#4A90D9')
        Column({ space: 6 }) {
          if (msg.kind === 'step') {
            this.stepBubble(msg, idx)
          } else {
            this.plainBubble(msg.kind, msg.text)
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
    }
  }

  /** 底部输入栏 */
  @Builder
  inputBar() {
    Row({ space: 8 }) {
      TextArea({ text: this.input, placeholder: this.t('agent.placeholder') })
        .fontFamily(AppFonts.family())
        .fontSize(14)
        .layoutWeight(1)
        .maxLength(500)
        .height(46)
        .onChange((v: string) => {
          this.input = v;
        })
      if (this.loading) {
        Button(this.t('gen.loading'))
          .fontFamily(AppFonts.family())
          .fontSize(14)
          .height(46)
          .width(96)
          .backgroundColor(this.col('inputBg'))
          .fontColor(this.col('hint'))
          .borderRadius(23)
          .enabled(false)
      } else {
        Button(this.t('agent.send'))
          .fontFamily(AppFonts.family())
          .fontSize(15)
          .height(46)
          .width(96)
          .backgroundColor(this.input.trim() === '' ? this.col('inputBg') : '#4A90D9')
          .fontColor(this.input.trim() === '' ? this.col('hint') : '#FFFFFF')
          .borderRadius(23)
          .onClick(() => {
            this.runAgent();
          })
      }
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
    .backgroundColor(this.col('barBg'))
  }

  build() {
    Column({ space: 0 }) {
      // 固定标题栏 + 顶部安全区
      Column() {
        PageHeader({ title: this.t('page.agent') })
      }
      .width('100%')
      .padding({ top: this.topInset })

      // 消息列表
      Scroll(this.scroller) {
        Column({ space: 10 }) {
          ForEach(this.messages, (m: AgentMsg, idx: number) => {
            this.renderMsg(m, idx)
          }, (m: AgentMsg, idx: number) => idx.toString())
        }
        .width('100%')
        .padding(12)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      .align(Alignment.TopStart)

      this.inputBar()
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.col('bg'))
  }
}

@Entry
@Component
struct AgentEntry {
  build() {
    Column() {
      AgentContent()
    }
    .width('100%')
    .height('100%')
  }
}