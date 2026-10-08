/**
 * 主界面：底部三 Tab（支持五语言与深浅主题）
 *  备课助手 / 家校沟通 / 我的（历史记录、设置、班级管理等入口）
 *
 * 底部导航使用**系统默认样式** BottomTabBarStyle（图标在上、文字在下），
 * 图标取系统内置符号资源 sys.symbol.{house,message,person}，不额外引入图片。
 * 平板/横屏 与 2in1 分屏形态分别由 IndexWide / IndexWideDuo 渲染，风格一致。
 */
import router from '@ohos.router';
import common from '@ohos.app.ability.common';
import display from '@ohos.display';
import { window } from '@kit.ArkUI';
import { I18n } from '../common/I18n';
import { AppTheme } from '../common/AppTheme';
import { AppFonts } from '../common/AppFonts';
import { AcceptStore } from '../common/AcceptStore';
import { GenTask } from '../common/GenTask';
import { Greeting } from '../common/Greeting';
import { ResultBus } from '../common/ResultBus';
import { DuoDetect } from '../common/DuoDetect';
import { Duo2in1 } from '../common/Duo2in1';
import { FoldDetect } from '../common/FoldDetect';
import { LayoutPolicy } from '../common/LayoutPolicy';
import { VerticalMongolianText } from '../common/components/VerticalMongolianText';
import { HeatMapCard } from '../common/components/HeatMapCard';
import { AnalysisStore, ScoreSnapshot } from '../common/AnalysisStore';
import { HeatMap, HeatMapData } from '../common/HeatMap';
import { IndexWide } from './IndexWide';
import { IndexWideDuo } from './IndexWideDuo';

/** 免责声明弹窗：首次启动显示，倒计时 5 秒后方可同意；同意后永久不再显示 */
@CustomDialog
struct DisclaimerDialog {
  controller: CustomDialogController = new CustomDialogController({ builder: undefined });
  @State remain: number = 5;
  private timer: number = -1;
  @StorageProp('appLang') appLang: string = 'zh';
  @StorageProp('appResolvedTheme') resolvedTheme: string = 'light';

  aboutToAppear(): void {
    this.timer = setInterval(() => {
      if (this.remain > 0) {
        this.remain--;
        if (this.remain === 0 && this.timer !== -1) {
          clearInterval(this.timer);
          this.timer = -1;
        }
      }
    }, 1000);
  }

  aboutToDisappear(): void {
    if (this.timer !== -1) {
      clearInterval(this.timer);
      this.timer = -1;
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

  /** 同意：写入标记后关闭，此后不再显示 */
  private onAgree(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    AcceptStore.setAccepted(ctx).then(() => {
      this.controller.close();
    }).catch(() => {
      this.controller.close();
    });
  }

  /** 不同意：直接退出应用（不写标记，下次进入仍显示） */
  private onDisagree(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    ctx.terminateSelf().catch(() => {
      // 退出失败则关闭弹窗兜底
      this.controller.close();
    });
  }

  build() {
    Column({ space: 14 }) {
      VerticalMongolianText({
        content: this.t('dlg.title'),
        textSize: 18,
        textColor: this.col('title'),
        isBold: true,
        fillWidth: true
      })
      VerticalMongolianText({
        content: this.t('dlg.body'),
        textSize: 14,
        textColor: this.col('text'),
        fillWidth: true
      })
      if (this.remain > 0) {
        VerticalMongolianText({
          content: this.t('dlg.count').replace('{n}', this.remain.toString()),
          textSize: 12,
          textColor: this.col('hint'),
          fillWidth: true
        })
      }
      Row({ space: 10 }) {
        Button(this.t('dlg.agree'))
          .fontFamily(AppFonts.family())
          .fontSize(14)
          .height(40)
          .layoutWeight(1)
          .backgroundColor('#4A90D9')
          .enabled(this.remain === 0)
          .opacity(this.remain === 0 ? 1 : 0.45)
          .onClick(() => this.onAgree())
        Button(this.t('dlg.disagree'))
          .fontFamily(AppFonts.family())
          .fontSize(14)
          .height(40)
          .layoutWeight(1)
          .backgroundColor('#C0392B')
          .onClick(() => this.onDisagree())
      }
      .width('100%')
    }
    .width('88%')
    .padding(20)
    .backgroundColor(this.col('card'))
    .borderRadius(18)
  }
}

/** 功能入口卡片（@Prop 单向同步，保证语言切换后标题描述即时更新） */
@Component
struct FunCard {
  icon: string = '';
  @Prop title: string = '';
  @Prop desc: string = '';
  bgColor: string = '#E8F1FB';
  onTap: () => void = () => {};
  @StorageProp('appResolvedTheme') resolvedTheme: string = 'light';
  @StorageProp('appLang') appLang: string = 'zh';

  private t(key: string): string {
    void this.appLang;
    return I18n.t(key);
  }

  private col(key: string): string {
    void this.resolvedTheme;
    return AppTheme.color(key, this.resolvedTheme);
  }

  build() {
    Column({ space: 8 }) {
      Text(this.icon)
        .fontFamily(AppFonts.family())
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor('#2B4C7E')
        .width(46)
        .height(46)
        .textAlign(TextAlign.Center)
        .backgroundColor(this.bgColor)
        .borderRadius(12)
      VerticalMongolianText({
        content: this.title,
        textSize: 16,
        textColor: this.col('title'),
        isBold: true
      })
      VerticalMongolianText({
        content: this.desc,
        textSize: 12,
        textColor: this.col('hint'),
        centerText: true
      })
    }
    .width('100%')
    .padding(14)
    .backgroundColor(this.col('card'))
    .borderRadius(14)
    .shadow({ radius: 8, color: 'rgba(0,0,0,0.06)', offsetY: 3 })
    .onClick(() => this.onTap())
  }
}

@Entry
@Component
struct Index {
  @StorageProp('appLang') @Watch('onLangChanged') appLang: string = 'zh';
  @StorageProp('appResolvedTheme') resolvedTheme: string = 'light';
  /** 首页问候：大字/小字文案 key（随系统时间与工作日/节假日变化） */
  @State greetBigKey: string = 'greet.big.morning';
  @State greetSmallKey: string = 'greet.work.morning';
  /** 打字机已显示字符数 */
  @State greetBigLen: number = 0;
  @State greetSmallLen: number = 0;
  private greetTimer: number = -1;
  /** 平板/横屏两栏模式（AppStorage 全局标志，供功能页感知以隐藏返回按钮/内嵌导航） */
  @StorageProp('appWideLayout') wideLayout: boolean = false;
  /** 2in1 全屏上下分屏模式（仅华为 2in1 且磁吸键盘未连接时启用） */
  @StorageProp('appDuo') @Watch('onDuoModeChanged') appDuo: boolean = false;
  /** 当前选中的底部页签序号（0=备课助手 / 1=家校沟通 / 2=我的），驱动页签选中态 */
  @State tabsIndex: number = 0;
  /** 成绩热力图数据（来自最近一次导入的学情分析 Excel） */
  @State heatData: HeatMapData = { subjects: [], rows: [], valid: false, nameCol: -1, time: '' };
  /** 成绩数据的导入时间（展示用） */
  @State heatTime: string = '';
  /** 热力图是否正在加载（首帧避免闪"暂无数据"） */
  @State heatLoading: boolean = true;
  private win: window.Window | undefined = undefined;
  /** 跨轴铺窗（瀑布模式）是否正在执行 / 已生效：用于去重与防抖 */
  private spanBusy: boolean = false;
  private spanDone: boolean = false;
  /** 跨轴铺窗看门狗（每 800ms 校验一次窗口是否真正铺满上下两屏） */
  private spanTimer: number = -1;
  private lastSpanTry: number = 0;
  private spanFailCount: number = 0;
  /** 最近一次窗口尺寸（vp），供键盘热插拔后重新判定形态 */
  private lastVw: number = 0;
  private lastVh: number = 0;
  private dialogController: CustomDialogController = new CustomDialogController({
    builder: DisclaimerDialog(),
    autoCancel: false
  });

  /**
   * 系统默认底部导航项：BottomTabBarStyle(icon, text)。
   *
   * 为什么改成系统默认：
   *   原实现 `.tabBar('文字')` 只传字符串，是"纯文字页签"—— 没有图标，
   *   也没有系统的选中态与点击动效，观感与鸿蒙系统应用不一致。
   *   BottomTabBarStyle 是 ArkUI 内置的底部导航样式：**图标在上、文字在下**，
   *   选中态/着色/动效/深浅色适配全部由系统接管
   *   （API 见 SDK 的 component/tab_content.d.ts）。
   *
   * 图标用系统内置符号资源 `$r('sys.symbol.*')`，不新增图片文件。
   * 符号名取自 SDK 资源索引 toolchains/id_defined.json，均已确认存在：
   *   house · message · person
   *
   * 选中/未选中由 Tabs 按当前索引自动着色；当前页由 Tabs 构造参数的
   * `index: this.tabsIndex` 指定，并靠 `.onChange()` 回写 tabsIndex 保持同步。
   * 这里不手工替换图标，避免与系统动效打架。
   */
  private bottomStyle(icon: string, textKey: string): BottomTabBarStyle {
    return BottomTabBarStyle.of($r('sys.symbol.' + icon), this.t(textKey));
  }

  /** 问候大字当前可见文本（打字机逐字展开；语言切换后按新词典续显） */
  private shownBig(): string {
    return I18n.t(this.greetBigKey).slice(0, this.greetBigLen);
  }
  /** 问候小字当前可见文本 */
  private shownSmall(): string {
    return I18n.t(this.greetSmallKey).slice(0, this.greetSmallLen);
  }

  /** 界面语言切换后重新播放问候打字机（文案随新语言词典逐字出现） */
  private onLangChanged(): void {
    this.startGreeting();
  }

  /** 判定并应用布局（折叠屏形态 + 窗口尺寸 + 输入设备 → 单栏/双栏/上下分屏）
   *  折叠屏：展开按大屏布局、半折按上下分屏；2in1：大横屏且未接键盘时上下分屏 */
  private applyWide(vw: number, vh: number): void {
    this.lastVw = vw;
    this.lastVh = vh;
    AppStorage.setOrCreate('appWideLayout', vw > vh && vw >= 900 && vh >= 520);
    this.refreshDuo(vw, vh);
    // 窗口尺寸变化后（展开/半折切换、跨轴铺窗完成等）重试一次双屏铺窗，保证状态自愈
    this.syncDuoWindow();
  }

  /** 应用一次布局决策（把 LayoutPolicy 的结果写入 AppStorage，供各页面消费） */
  private applyDecision(vw: number, vh: number, kb: boolean, lowerHalf: boolean): void {
    this.lastVw = vw;
    this.lastVh = vh;
    const d = LayoutPolicy.decide(vw, vh, kb, lowerHalf);
    AppStorage.setOrCreate('appWideLayout', d.wide);
    AppStorage.setOrCreate('appDuo', d.duo);
    AppStorage.setOrCreate('appTwoScreen', d.twoScreen);
    AppStorage.setOrCreate('appSidebarVp', d.sidebarVp);
    AppStorage.setOrCreate('appFoldForm', d.form as number);
    AppStorage.setOrCreate('appCreaseVp', d.creaseVp);
  }

  /** 2in1 上下分屏判定（键盘模式=平板布局；折叠屏半折/双屏形态优先上下分区） */
  private refreshDuo(vw: number, vh: number): void {
    const lowerHalf: boolean = DuoDetect.supported() && DuoDetect.hasLowerHalf();
    DuoDetect.keyboardDocked().then((kb: boolean) => {
      this.applyDecision(vw, vh, kb, lowerHalf);
    }).catch(() => {
      this.applyDecision(vw, vh, false, lowerHalf);
    });
  }

  /** 输入设备（磁吸键盘）插拔后按最近窗口尺寸重新判定形态 */
  private onDeviceChange(): void {
    if (this.lastVw > 0 && this.lastVh > 0) {
      this.refreshDuo(this.lastVw, this.lastVh);
    }
  }

  /** duo 形态变化（键盘热插拔 / 启动检测完成）后同步窗口：半折叠双屏时把结果铺到物理下半屏 */
  private onDuoModeChanged(): void {
    this.syncDuoWindow();
  }

  /**
   * 双屏铺窗同步：
   *  - duo 开启且处于半折叠双屏形态（displayId=999 存在）→ 把主窗口跨轴铺满上下两屏，
   *    IndexWideDuo 上半屏=工具界面、下半屏=生成结果大面板；未铺满前由看门狗持续重试
   *  - duo 开启但单屏（展开平板）→ 保持原有内嵌布局
   *  - duo 关闭且双屏仍存在（手动关闭）→ 收回跨轴窗口；键盘吸回（下半屏消失）由系统自动收拢
   */
  private syncDuoWindow(): void {
    // 同步“跨轴双屏”标志：供 IndexWideDuo 决定用手动精确分区还是 FoldSplitContainer
    const duo: boolean = this.appDuo;
    const twoScreen: boolean = duo && DuoDetect.supported() && DuoDetect.hasLowerHalf();
    AppStorage.setOrCreate('appTwoScreen', twoScreen);
    const mw: window.Window | undefined = this.win;
    if (duo && twoScreen) {
      // 事件触发时重置失败计数，允许重新尝试
      this.spanFailCount = 0;
      if (mw !== undefined) {
        this.ensureSpanned(mw);
        this.startSpanWatchdog(mw);
      }
    } else {
      this.stopSpanWatchdog();
      const wasSpanned: boolean = this.spanDone;
      this.spanDone = false;
      if (wasSpanned && DuoDetect.hasLowerHalf()) {
        this.collapseFold();
      }
    }
  }

  /** 主窗口是否已真正跨轴铺满上下两屏（用窗口实际矩形与上屏高度比对，避免误判） */
  private isSpanned(mw: window.Window): boolean {
    return Duo2in1.isAcrossSpan(mw);
  }

  /** 未铺满时触发一次跨轴最大化（busy 去重） */
  private ensureSpanned(mw: window.Window): void {
    if (this.spanBusy || this.isSpanned(mw)) {
      return;
    }
    this.spanDone = false;
    this.lastSpanTry = Date.now();
    this.trySpanFold(0);
  }

  /**
   * 看门狗：双屏形态下每 800ms 校验一次窗口矩形，
   * 未铺满则再次跨轴最大化（下屏/折叠状态就绪前一直重试，最多 30 次），铺满后自动停止。
   */
  private startSpanWatchdog(mw: window.Window): void {
    if (this.spanTimer !== -1) {
      return;
    }
    this.spanTimer = setInterval(() => {
      if (!this.appDuo || !DuoDetect.hasLowerHalf() || this.isSpanned(mw)) {
        this.stopSpanWatchdog();
        return;
      }
      if (this.spanBusy) {
        return;
      }
      if (this.spanFailCount >= 30) {
        // 已多次失败（如系统不支持跨轴），停止轮询避免空转；等待下次形态事件再触发
        this.stopSpanWatchdog();
        return;
      }
      const now: number = Date.now();
      if (now - this.lastSpanTry < 1000) {
        return;
      }
      this.spanFailCount++;
      this.lastSpanTry = now;
      this.trySpanFold(0);
    }, 800);
  }

  private stopSpanWatchdog(): void {
    if (this.spanTimer !== -1) {
      clearInterval(this.spanTimer);
      this.spanTimer = -1;
    }
  }

  /** 主窗口最大化时跨轴进入瀑布模式：窗口覆盖折叠电脑上、下两屏 */
  private trySpanFold(attempt: number): void {
    const mw: window.Window | undefined = this.win;
    if (!this.appDuo || mw === undefined || this.spanBusy) {
      return;
    }
    if (attempt > 4) {
      return;
    }
    this.spanBusy = true;
    try {
      // acrossDisplay=true：半折叠态下主窗口进入瀑布模式（铺满上下两屏，结果面板真正落到物理下半屏）
      Duo2in1.enterFold(mw).then((ok: boolean): void => {
        this.spanBusy = false;
        if (ok) {
          this.spanDone = this.isSpanned(mw);
        } else {
          // 形态/下屏可能尚未就绪，稍后由看门狗重试
          setTimeout(() => this.trySpanFold(attempt + 1), 350);
        }
      }).catch(() => {
        this.spanBusy = false;
        setTimeout(() => this.trySpanFold(attempt + 1), 350);
      });
    } catch (e) {
      this.spanBusy = false;
      setTimeout(() => this.trySpanFold(attempt + 1), 350);
    }
  }

  /** 收回跨轴窗口（回到仅占上半屏/单屏的常规窗口状态） */
  private collapseFold(): void {
    const mw: window.Window | undefined = this.win;
    if (mw === undefined) {
      return;
    }
    Duo2in1.collapseFold(mw);
  }

  /** 按当前窗口尺寸立即刷新一次两栏判定 */
  private refreshWide(): void {
    try {
      const d = display.getDefaultDisplaySync();
      this.applyWide(px2vp(d.width), px2vp(d.height));
    } catch (e) {
      AppStorage.setOrCreate('appWideLayout', false);
    }
  }

  /** 注册窗口尺寸监听：旋转 / 分屏后即时切换两栏与窄屏；键盘插拔监听用于 2in1 形态切换 */
  private initWideLayout(): void {
    this.refreshWide();
    const ctx = getContext(this) as common.UIAbilityContext;
    window.getLastWindow(ctx).then((mw: window.Window) => {
      this.win = mw;
      mw.on('windowSizeChange', (sz: window.Size) => {
        this.applyWide(px2vp(sz.width), px2vp(sz.height));
      });
      // 窗口就绪后再同步一次双屏铺窗（启动时 duo 判定可能先于窗口获取完成）
      this.syncDuoWindow();
    }).catch(() => {
      // 无法获取窗口时保持初始判定
    });
    DuoDetect.attach(() => {
      this.onDeviceChange();
    });
    // 显示器增删/变化（折叠电脑拆下键盘出现下半屏 displayId=999、吸回后消失）→ 延迟重判并同步铺窗
    try {
      display.on('add', () => {
        this.onDisplayLayoutChange();
      });
      display.on('remove', () => {
        this.onDisplayLayoutChange();
      });
      display.on('change', () => {
        this.onDisplayLayoutChange();
      });
    } catch (e) {
      // 不支持显示器监听时依赖键盘热插拔事件
    }
    // 折叠屏形态变化（双折叠/阔折叠/三折叠的折叠↔半折↔展开、内外屏切换）→ 重判布局。
    // 展开瞬间窗口尺寸可能尚未更新，故延迟一帧再读取实际尺寸，避免按旧尺寸误判而闪回单栏。
    FoldDetect.attach(() => {
      this.onFoldChanged();
    });
  }

  /** 折叠形态变化：延迟重判（等系统完成窗口尺寸切换后再读取，避免过渡态误判） */
  private onFoldChanged(): void {
    setTimeout(() => {
      this.refreshWide();
    }, 120);
    // 再补一次：部分机型尺寸切换较慢，二次确认保证最终形态正确
    setTimeout(() => {
      this.refreshWide();
      this.syncDuoWindow();
    }, 420);
  }

  /** 屏幕增删/变化后稍作延迟重判形态，等系统完成上下屏切换后再铺窗 */
  private onDisplayLayoutChange(): void {
    setTimeout(() => {
      this.refreshWide();
      this.syncDuoWindow();
    }, 300);
  }

  aboutToDisappear(): void {
    if (this.win !== undefined) {
      try {
        this.win.off('windowSizeChange');
      } catch (e) {
        // ignore
      }
      this.win = undefined;
    }
    this.stopSpanWatchdog();
    try {
      display.off('add');
      display.off('remove');
      display.off('change');
    } catch (e) {
      // ignore
    }
    DuoDetect.detach();
    FoldDetect.detach();
  }

  /** 启动问候打字机：大字逐字出现后小字逐字出现（快速效果） */
  private startGreeting(): void {
    if (this.greetTimer !== -1) {
      clearInterval(this.greetTimer);
      this.greetTimer = -1;
    }
    const g = Greeting.forNow();
    this.greetBigKey = g.bigKey;
    this.greetSmallKey = g.smallKey;
    this.greetBigLen = 0;
    this.greetSmallLen = 0;
    this.greetTimer = setInterval(() => {
      const big: string = I18n.t(this.greetBigKey);
      const small: string = I18n.t(this.greetSmallKey);
      if (this.greetBigLen < big.length) {
        this.greetBigLen = Math.min(big.length, this.greetBigLen + (big.length > 12 ? 2 : 1));
        return;
      }
      if (this.greetSmallLen < small.length) {
        this.greetSmallLen = Math.min(small.length, this.greetSmallLen + (small.length > 24 ? 3 : 1));
        return;
      }
      if (this.greetTimer !== -1) {
        clearInterval(this.greetTimer);
        this.greetTimer = -1;
      }
    }, 70);
  }

  aboutToAppear(): void {
    this.ensureFonts();
    // 布局形态初始占位（避免 @StorageProp/@StorageLink 首帧未绑定）
    AppStorage.setOrCreate('appDuo', false);
    AppStorage.setOrCreate('appTwoScreen', false);
    AppStorage.setOrCreate('appSidebarVp', 400);
    AppStorage.setOrCreate('appFoldForm', 0);
    AppStorage.setOrCreate('appCreaseVp', 0);
    ResultBus.init();
    // 进入应用：按时段与工作日/节假日计算问候语并逐字显示
    this.startGreeting();
    // 平板/横屏两栏布局检测（旋转/分屏自动切换）
    this.initWideLayout();
    // 首次进入（未同意过免责声明）时弹出使用须知
    const ctx = getContext(this) as common.UIAbilityContext;
    AcceptStore.getAccepted(ctx).then((acc: boolean) => {
      if (!acc) {
        this.dialogController.open();
      }
    }).catch(() => {
    });
    // 恢复未完成的后台生成任务（进程被杀/离开页面后的完成结果在此接收并保存）
    GenTask.recover(ctx).catch(() => {
    });
    // 成绩热力图：读取最近一次「学情分析」导入的成绩表
    this.loadHeatMap();
  }

  /**
   * 加载成绩热力图数据。
   *
   * 数据来自 AnalysisStore 持久化的"最近一次导入的成绩 Excel"。
   * 放在 aboutToAppear 会漏掉"从学情分析页导入后返回"的场景，
   * 因此 onPageShow 也会调用（见下方 onPageShow）。
   */
  private loadHeatMap(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    this.heatLoading = true;
    AnalysisStore.loadScores(ctx).then((snap: ScoreSnapshot | null) => {
      if (snap === null) {
        this.heatData = { subjects: [], rows: [], valid: false, nameCol: -1, time: '' };
        this.heatTime = '';
      } else {
        this.heatData = HeatMap.build(snap.headers, snap.rows, snap.time);
        this.heatTime = snap.time;
      }
      this.heatLoading = false;
    }).catch(() => {
      this.heatData = { subjects: [], rows: [], valid: false, nameCol: -1, time: '' };
      this.heatTime = '';
      this.heatLoading = false;
    });
  }

  /** 页面重新可见时刷新热力图（导入新成绩后返回即可看到更新） */
  onPageShow(): void {
    this.loadHeatMap();
  }

  /** 注册内置少数民族字体（进程内仅执行一次；失败不阻塞界面） */
  private ensureFonts(): void {
    if (AppStorage.get<boolean>('revFontsReg') === true) {
      return;
    }
    try {
      this.getUIContext().getFont().registerFont({
        familyName: AppFonts.TIBETAN,
        familySrc: $rawfile('fonts/ctrc-uchen.ttf')
      });
      this.getUIContext().getFont().registerFont({
        familyName: AppFonts.UYGHUR,
        familySrc: $rawfile('fonts/UKIJMejT.ttf')
      });
      // 蒙古文已改为西里尔蒙古文（标准西里尔字符集），系统默认字体即可显示
    } catch (e) {
      // 注册失败时回退系统字体
    }
    AppStorage.setOrCreate('revFontsReg', true);
  }

  private t(key: string): string {
    void this.appLang;
    return I18n.t(key);
  }

  private col(key: string): string {
    void this.resolvedTheme;
    return AppTheme.color(key, this.resolvedTheme);
  }

  build() {
    if (this.appDuo) {
      // 华为 2in1 上下分屏（无磁吸键盘）：
      // 半折叠双屏形态下窗口已跨轴铺开 → primary/上半屏=工具界面 + secondary/下半屏=生成结果；
      // 展开单屏形态 → FoldSplitContainer 在单屏内上下分栏。
      Column() {
        IndexWideDuo()
      }
      .width('100%')
      .height('100%')
    } else if (this.wideLayout) {
      // 平板/横屏 / 2in1 磁吸键盘模式：左导航 + 右内容两栏
      Column() {
        IndexWide()
      }
      .width('100%')
      .height('100%')
    } else {
    Tabs({ barPosition: BarPosition.End, index: this.tabsIndex }) {
      // ============ Tab1 备课助手 ============
      TabContent() {
        Scroll() {
          Column({ space: 14 }) {
            Row() {
              Column({ space: 4 }) {
                // 第一屏头部：按系统时间/工作日节假日显示问候语（打字机逐字出现）
                VerticalMongolianText({
                  content: this.shownBig(),
                  textSize: 22,
                  textColor: this.col('title'),
                  isBold: true
                })
                VerticalMongolianText({
                  content: this.shownSmall(),
                  textSize: 12,
                  textColor: this.col('hint')
                })
              }
              .alignItems(HorizontalAlign.Start)
              Blank()
            }
            .width('100%')

            Grid() {
              GridItem() {
                FunCard({

                  icon: I18n.badge('教', 'card.plan'), title: this.t('card.plan'), desc: this.t('card.plan.desc'),
                  bgColor: '#E8F1FB',
                  onTap: () => router.pushUrl({ url: 'pages/Plan' })
                })
              }
              GridItem() {
                FunCard({
                  icon: I18n.badge('课', 'card.courseware'), title: this.t('card.courseware'), desc: this.t('card.courseware.desc'),
                  bgColor: '#FFF4E5',
                  onTap: () => router.pushUrl({ url: 'pages/Courseware' })
                })
              }
              GridItem() {
                FunCard({
                  icon: I18n.badge('题', 'card.quiz'), title: this.t('card.quiz'), desc: this.t('card.quiz.desc'),
                  bgColor: '#EAF7EF',
                  onTap: () => router.pushUrl({ url: 'pages/Quiz' })
                })
              }
              GridItem() {
                FunCard({
                  icon: I18n.badge('研', 'card.research'), title: this.t('card.research'), desc: this.t('card.research.desc'),
                  bgColor: '#F3EDFB',
                  onTap: () => router.pushUrl({ url: 'pages/Research' })
                })
              }
              GridItem() {
                FunCard({
                  icon: I18n.badge('析', 'card.analysis'), title: this.t('card.analysis'), desc: this.t('card.analysis.desc'),
                  bgColor: '#E6F4F2',
                  onTap: () => router.pushUrl({ url: 'pages/Analysis' })
                })
              }
              GridItem() {
                FunCard({
                  icon: I18n.badge('位', 'card.seats'), title: this.t('card.seats'), desc: this.t('card.seats.desc'),
                  bgColor: '#FFF0E6',
                  onTap: () => router.pushUrl({ url: 'pages/Seats' })
                })
              }
            }
            .columnsTemplate('1fr 1fr')
            .columnsGap(12)
            .rowsGap(12)
            .width('100%')
          }
          .width('100%')
          .padding(16)
        }
        .width('100%')
        .height('100%')
        .backgroundColor(this.col('bg'))
      }
      .tabBar(this.bottomStyle('house', 'tab.assistant'))

      // ============ Tab2 家校沟通 ============
      TabContent() {
        Scroll() {
          Column({ space: 14 }) {
            Row() {
              Column({ space: 4 }) {
                VerticalMongolianText({
                  content: this.t('tab.family'),
                  textSize: 22,
                  textColor: this.col('title'),
                  isBold: true
                })
                VerticalMongolianText({
                  content: this.t('sub.family'),
                  textSize: 12,
                  textColor: this.col('hint')
                })
              }
              .alignItems(HorizontalAlign.Start)
              Blank()
            }
            .width('100%')

            Grid() {
              GridItem() {
                FunCard({
                  icon: I18n.badge('话', 'card.talk'), title: this.t('card.talk'), desc: this.t('card.talk.desc'),
                  bgColor: '#FFF0F0',
                  onTap: () => router.pushUrl({ url: 'pages/Talk' })
                })
              }
              GridItem() {
                FunCard({
                  icon: I18n.badge('报', 'card.report'), title: this.t('card.report'), desc: this.t('card.report.desc'),
                  bgColor: '#E8F1FB',
                  onTap: () => router.pushUrl({ url: 'pages/Report' })
                })
              }
            }
            .columnsTemplate('1fr 1fr')
            .columnsGap(12)
            .rowsGap(12)
            .width('100%')
          }
          .width('100%')
          .padding(16)
        }
        .width('100%')
        .height('100%')
        .backgroundColor(this.col('bg'))
      }
      .tabBar(this.bottomStyle('message', 'tab.family'))

      // ============ Tab3 我的 ============
      TabContent() {
        Scroll() {
          Column({ space: 14 }) {
            Row() {
              Column({ space: 4 }) {
                VerticalMongolianText({
                  content: this.t('tab.mine'),
                  textSize: 22,
                  textColor: this.col('title'),
                  isBold: true
                })
                VerticalMongolianText({
                  content: this.t('sub.mine'),
                  textSize: 12,
                  textColor: this.col('hint')
                })
              }
              .alignItems(HorizontalAlign.Start)
              Blank()
            }
            .width('100%')

            // 成绩热力图：数据来自最近一次「学情分析」导入的 Excel 成绩表
            HeatMapCard({
              data: this.heatData,
              timeText: this.heatTime,
              loading: this.heatLoading,
              onOpen: () => router.pushUrl({ url: 'pages/HeatMapDetail' })
            })

            Grid() {
              GridItem() {
                FunCard({
                  icon: I18n.badge('史', 'card.history'), title: this.t('card.history'), desc: this.t('card.history.desc'),
                  bgColor: '#FFF4E5',
                  onTap: () => router.pushUrl({ url: 'pages/History' })
                })
              }
              GridItem() {
                FunCard({
                  icon: I18n.badge('设', 'card.settings'), title: this.t('card.settings'), desc: this.t('card.settings.desc'),
                  bgColor: '#E6F4F2',
                  onTap: () => router.pushUrl({ url: 'pages/Settings' })
                })
              }
              GridItem() {
                FunCard({
                  icon: I18n.badge('班', 'card.classes'), title: this.t('card.classes'), desc: this.t('card.classes.desc'),
                  bgColor: '#F3EDFB',
                  onTap: () => router.pushUrl({ url: 'pages/ClassManager' })
                })
              }
            }
            .columnsTemplate('1fr 1fr')
            .columnsGap(12)
            .rowsGap(12)
            .width('100%')

            VerticalMongolianText({
              content: this.t('mine.local'),
              textSize: 11,
              textColor: this.col('faint'),
              fillWidth: true,
              centerText: true
            })
          }
          .width('100%')
          .padding(16)
        }
        .width('100%')
        .height('100%')
        .backgroundColor(this.col('bg'))
      }
      .tabBar(this.bottomStyle('person', 'tab.mine'))
    }
    .width('100%')
    .height('100%')
    // 系统默认导航栏外观：背景/高度/分割线交给系统，仅保留主题背景色同步
    .barBackgroundColor(this.col('barBg'))
    .barHeight(56)
    .barMode(BarMode.Fixed)
    .scrollable(false)
    .onChange((index: number) => {
      this.tabsIndex = index;
    })
    .backgroundColor(this.col('bg'))
    }
  }

  }
