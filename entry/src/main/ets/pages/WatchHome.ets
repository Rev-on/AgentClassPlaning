/**
 * 手表端"上课指挥"页：接收由手机端流转解析出的教案环节，按环节分时上课。
 *
 * 交互流程：
 *   1. 手机端检测到手表并把教案环节推入分布式库 → 本页监听到 status=ready；
 *   2. 先弹出"已接收教案"提示，随后切换至大大的绿色"开始上课"按钮；
 *   3. 点击"开始上课"进入分环节计时：当前环节显示环节名、提示与倒计时；
 *   4. 每个环节到点 → 震动提醒，但【不自动切换】；无论是否到点，用户【上滑】才进入下一环节，
 *      下一环节重新按其时长计时；最后一环再上滑进入结束态。
 *
 * 版式：按屏幕形态区分圆屏/方屏，圆屏把内容内缩到内切正方形内避让四角裁圆。
 */
import common from '@ohos.app.ability.common';
import { WatchLayout, WatchAvoid } from '../common/WatchLayout';
import { WatchLink, WatchLessonBundle } from '../common/WatchLink';
import { LessonPlanParser, LessonStage } from '../common/LessonPlanParser';

//#if OHOS
import { vibrator } from '@kit.SensorServiceKit';
//#endif

const C_BG_DARK = '#0C1522';
const C_GREEN = '#2ECC71';
const C_GREEN_DEEP = '#1E9E5A';
const C_TEXT = '#F2F6FB';
const C_SUB = '#A7B7CC';

@Entry
@Component
struct WatchHome {
  @State avoid: WatchAvoid = { round: false, inset: 0, top: 0, bottom: 0, left: 0, right: 0 };
  /** 已接收的教案预案 */
  @State plan: WatchLessonBundle | null = null;
  /** 阶段：0=等待接收 1=已接收提示 2=待开始 3=上课中 4=下课 */
  @State phase: number = 0;
  /** 当前环节下标 */
  @State segIdx: number = 0;
  /** 当前环节剩余秒数 */
  @State remain: number = 0;
  /** 当前环节是否已到点（震动过，等待上滑） */
  @State overtime: boolean = false;
  private timerId: number = -1;
  private ctx: common.UIAbilityContext | null = null;

  aboutToAppear(): void {
    const c = getContext(this) as common.UIAbilityContext;
    this.ctx = c;
    WatchLayout.avoid(c).then((a: WatchAvoid): void => {
      this.avoid = a;
    });
    if (WatchLayout.isWatch()) {
      WatchLink.watchObserve(c, (b: WatchLessonBundle): void => {
        this.onPlan(b);
      });
    }
  }

  aboutToDisappear(): void {
    this.stopTimer();
  }

  /** 收到教案预案 */
  private onPlan(b: WatchLessonBundle): void {
    this.stopTimer();
    this.plan = b;
    this.segIdx = 0;
    this.overtime = false;
    this.phase = 1;
    setTimeout((): void => {
      if (this.plan !== null) {
        this.phase = 2;
      }
    }, 1600);
  }

  /** 点击"开始上课" */
  private startClass(): void {
    if (this.plan === null || this.plan.stages.length === 0) {
      return;
    }
    this.phase = 3;
    this.segIdx = 0;
    this.beginStage();
  }

  private stage(): LessonStage {
    const p = this.plan;
    if (p === null || this.segIdx < 0 || this.segIdx >= p.stages.length) {
      return LessonPlanParser.DEFAULT_STAGES[0];
    }
    return p.stages[this.segIdx];
  }

  private beginStage(): void {
    const st = this.stage();
    this.overtime = false;
    this.remain = (st.endMin - st.startMin) * 60;
    if (this.remain < 1) {
      this.remain = 1;
    }
    this.stopTimer();
    this.timerId = setInterval((): void => {
      this.tick();
    }, 1000);
  }

  private tick(): void {
    if (this.remain > 0) {
      this.remain -= 1;
      if (this.remain <= 0) {
        this.remain = 0;
        this.overtime = true;
        this.vibrate();
      }
    }
  }

  /**
   * 上滑切环节：阶段到点与否都切换；进入下一环节后按其时长重新计时；最后一环后进入结束态。
   */
  private advance(): void {
    const p = this.plan;
    if (p === null || this.phase !== 3) {
      return;
    }
    if (this.segIdx + 1 < p.stages.length) {
      this.segIdx += 1;
      this.phase = 3;
      this.beginStage();
    } else {
      this.phase = 4;
      this.stopTimer();
      const c = this.ctx;
      if (c !== null) {
        WatchLink.clear(c);
      }
    }
  }

  private stopTimer(): void {
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
  }

  /** 环节到点震动提醒（不切换） */
  private vibrate(): void {
    //#if OHOS
    try {
      vibrator.startVibration({ type: 'time', duration: 400 },
        { usage: 'unknown' }).catch((): void => {
        // 部分设备不支持则忽略
      });
    } catch (e) {
      // 忽略
    }
    //#endif
  }

  // ============ UI ============

  @Builder
  waitingView() {
    Column({ space: 10 }) {
      Text('⌛')
        .fontSize(34)
      Text('等待接收教案')
        .fontFamily('sans-serif')
        .fontSize(16)
        .fontColor(C_TEXT)
        .fontWeight(FontWeight.Medium)
      Text('手机端点击“流转”\n并选择本手表')
        .fontFamily('sans-serif')
        .fontSize(12)
        .fontColor(C_SUB)
        .textAlign(TextAlign.Center)
        .lineHeight(17)
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  receivedView() {
    Column({ space: 8 }) {
      Text('✓')
        .fontSize(44)
        .fontColor(C_GREEN)
        .fontWeight(FontWeight.Bold)
      Text('已接收教案')
        .fontFamily('sans-serif')
        .fontSize(20)
        .fontColor(C_TEXT)
        .fontWeight(FontWeight.Bold)
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  startView() {
    Column({ space: 18 }) {
      Text('教案已就绪')
        .fontFamily('sans-serif')
        .fontSize(15)
        .fontColor(C_SUB)
      Button() {
        Column({ space: 4 }) {
          Text('▶')
            .fontSize(26)
            .fontColor('#FFFFFF')
          Text('开始上课')
            .fontFamily('sans-serif')
            .fontSize(18)
            .fontColor('#FFFFFF')
            .fontWeight(FontWeight.Bold)
        }
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      }
      .width(this.avoid.round ? 150 : 168)
      .height(this.avoid.round ? 150 : 112)
      .backgroundColor(C_GREEN)
      .borderRadius(this.avoid.round ? 75 : 20)
      .shadow({ radius: 18, color: '#662ECC71' })
      .stateStyles({
        pressed: { backgroundColor: C_GREEN_DEEP }
      })
      .onClick((): void => {
        this.startClass();
      })
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  runningView() {
    Column({ space: 6 }) {
      // 环节序号 + 名
      Row({ space: 6 }) {
        Text((this.segIdx + 1) + ' / ' + this.stageTotal() + ' · ' + this.stage().name)
          .fontFamily('sans-serif')
          .fontSize(15)
          .fontColor(C_TEXT)
          .fontWeight(FontWeight.Medium)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)

      // 倒计时
      Text(LessonPlanParser.formatClock(this.remain))
        .fontFamily('sans-serif')
        .fontSize(this.avoid.round ? 34 : 40)
        .fontColor(this.overtime ? C_GREEN : '#FFD24A')
        .fontWeight(FontWeight.Bold)
        .opacity(this.overtime ? 0.85 : 1)

      // 提示
      Text(this.stage().hint === '' ? '本环节进行中' : this.stage().hint)
        .fontFamily('sans-serif')
        .fontSize(12)
        .fontColor(C_SUB)
        .textAlign(TextAlign.Center)
        .lineHeight(16)
        .constraintSize({ maxWidth: '90%' })

      if (this.overtime) {
        Row({ space: 4 }) {
          Text('▲')
            .fontSize(12)
            .fontColor(C_GREEN)
          Text('时间到 · 上滑进入下一环节')
            .fontFamily('sans-serif')
            .fontSize(11)
            .fontColor(C_GREEN)
        }
        .margin({ top: 6 })
      }
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  endView() {
    Column({ space: 12 }) {
      Text('🎉')
        .fontSize(40)
      Text('本节课结束')
        .fontFamily('sans-serif')
        .fontSize(18)
        .fontColor(C_TEXT)
        .fontWeight(FontWeight.Bold)
      Text('共 ' + this.stageTotal() + ' 个环节')
        .fontFamily('sans-serif')
        .fontSize(12)
        .fontColor(C_SUB)
      Button() {
        Text('再来一遍')
          .fontFamily('sans-serif')
          .fontSize(14)
          .fontColor('#FFFFFF')
      }
      .width(120)
      .height(40)
      .backgroundColor(C_GREEN)
      .borderRadius(20)
      .onClick((): void => {
        this.phase = 2;
      })
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  private stageTotal(): number {
    const p = this.plan;
    return p === null ? 0 : p.stages.length;
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 背景渐变
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(C_BG_DARK)
        .linearGradient({
          angle: 180,
          colors: [[C_BG_DARK, 0.0], ['#101F33', 1.0]]
        })

      // 圆屏：内切避让；方屏：仅系统安全区
      Column() {
        if (this.phase === 0) {
          this.waitingView()
        } else if (this.phase === 1) {
          this.receivedView()
        } else if (this.phase === 2) {
          this.startView()
        } else if (this.phase === 4) {
          this.endView()
        } else {
          this.runningView()
        }
      }
      .width('100%')
      .height('100%')
      .padding({
        left: this.avoid.left + this.avoid.inset,
        right: this.avoid.right + this.avoid.inset,
        top: this.avoid.top + this.avoid.inset,
        bottom: this.avoid.bottom + this.avoid.inset
      })
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .backgroundBlurStyle(BlurStyle.Thin)
      .borderRadius(this.avoid.round ? 8 : 0)
    }
    .width('100%')
    .height('100%')
    .gesture(SwipeGesture({ direction: SwipeDirection.Vertical, speed: 100 })
      .onAction((event: GestureEvent): void => {
        // 仅"上滑"(offsetY<0)才切环节；下滑不算
        if (event.offsetY < 0) {
          this.advance();
        }
      }))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}