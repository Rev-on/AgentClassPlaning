/**
 * 华为 2in1 / 折叠 PC（MateBook Fold 等）专用页面文件（与平板版 IndexWide 完全独立，虽界面同源）
 *  - 采用系统级分屏容器 FoldSplitContainer：primary=上半屏平板式工具界面（工具以 bottomResult=true 渲染，
 *    结果不再内嵌），secondary=下半屏全宽"生成结果大面板"
 *  - 设备折叠/展开/半折状态由系统自动分配两个区域，支持用户拖拽调整分栏比例
 */
import common from '@ohos.app.ability.common';
import promptAction from '@ohos.promptAction';
import { FoldSplitContainer } from '@kit.ArkUI';
import { Duo2in1 } from '../common/Duo2in1';
import { FoldForm } from '../common/FoldDetect';
import { I18n } from '../common/I18n';
import { AppTheme } from '../common/AppTheme';
import { AppFonts } from '../common/AppFonts';
import { ResultBus } from '../common/ResultBus';
import { HistoryStore } from '../common/HistoryStore';
import { ResultPanel } from '../common/components/ResultPanel';
import { PlanContent } from './Plan';

import { CoursewareContent } from './Courseware';
import { QuizContent } from './Quiz';
import { ResearchContent } from './Research';
import { AnalysisContent } from './Analysis';
import { SeatsContent } from './Seats';
import { TalkContent } from './Talk';
import { ReportContent } from './Report';
import { HistoryContent } from './History';
import { SettingsContent } from './Settings';
import { ClassManagerContent } from './ClassManager';

/** 导航条目 */
interface NavEntry {
  id: string;
  icon: string;
  labelKey: string;
  descKey: string;
}

/** 页签分组 */
interface NavGroup {
  tabKey: string;
  entries: NavEntry[];
}

/** 结果面板负载（与 ResultBus JSON 对应） */
interface LivePayload {
  phase: string;
  kind: string;
  type: string;
  title: string;
  text: string;
}

/** 下半屏：生成结果全宽大面板 */
@Component
struct DuoResultBar {
  @StorageLink('liveGenResult') liveJson: string = '{"phase":"idle","kind":"","type":"","title":"","text":""}';
  @StorageProp('appLang') appLang: string = 'zh';
  @StorageProp('appResolvedTheme') resolvedTheme: string = 'light';

  private t(key: string): string {
    void this.appLang;
    return I18n.t(key);
  }

  private col(key: string): string {
    void this.resolvedTheme;
    return AppTheme.color(key, this.resolvedTheme);
  }

  /** 解析负载（异常兜底为空态） */
  private load(): LivePayload {
    const p: LivePayload = { phase: 'idle', kind: '', type: '', title: '', text: '' };
    try {
      const o: Record<string, Object> = JSON.parse(this.liveJson) as Record<string, Object>;
      if (typeof o.phase === 'string') {
        p.phase = o.phase as string;
      }
      if (typeof o.kind === 'string') {
        p.kind = o.kind as string;
      }
      if (typeof o.type === 'string') {
        p.type = o.type as string;
      }
      if (typeof o.title === 'string') {
        p.title = o.title as string;
      }
      if (typeof o.text === 'string') {
        p.text = o.text as string;
      }
    } catch (e) {
      // 忽略异常 JSON
    }
    return p;
  }

  /** 底部编辑后回写总线（保持 done 态） */
  private patchText(text: string): void {
    const p: LivePayload = this.load();
    this.liveJson = ResultBus.pack('done', p.kind, p.type, p.title, text);
  }

  /** 保存当前结果到历史 */
  private saveLive(): void {
    const p: LivePayload = this.load();
    if (p.text === '') {
      return;
    }
    const ctx = getContext(this) as common.UIAbilityContext;
    HistoryStore.addRecord(ctx, {
      type: p.type === '' ? this.t('tab.assistant') : p.type,
      title: p.title === '' ? this.t('tab.assistant') : p.title,
      content: p.text,
      time: HistoryStore.formatNow()
    }).then(() => {
      promptAction.showToast({ message: I18n.t('toast.saved') });
    }).catch(() => {
      // 保存失败静默（下次仍可手动保存）
    });
  }

  /** 头部标题：生成中显示类型，完成后显示记录标题 */
  private headerText(): string {
    const p: LivePayload = this.load();
    if (p.phase === 'busy') {
      return p.type === '' ? this.t('gen.loading') : p.type + ' · ' + this.t('gen.loading');
    }
    if (p.phase === 'done') {
      return p.title === '' ? p.type : p.title;
    }
    return '';
  }

  @Builder
  headerRow() {
    Row({ space: 8 }) {
      if (this.load().phase === 'busy') {
        LoadingProgress().width(16).height(16).color('#4A90D9')
      }
      Text(this.headerText())
        .fontFamily(AppFonts.family())
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.col('title'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      if (this.load().phase === 'done') {
        Text(this.t('duo.clear'))
          .fontFamily(AppFonts.family())
          .fontSize(12)
          .fontColor('#C0392B')
          .padding({ left: 12, right: 4, top: 4, bottom: 4 })
          .onClick(() => {
            ResultBus.clear();
          })
      }
    }
    .width('100%')
    .height(34)
    .padding({ left: 14, right: 8 })
  }

  @Builder
  bodyBusy(p: LivePayload) {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        LoadingProgress().width(18).height(18).color('#4A90D9')
        Text(this.t('gen.loading')).fontSize(13).fontColor(this.col('sub'))
          .fontFamily(AppFonts.family())
      }
      .width('100%')
      .justifyContent(FlexAlign.Start)
      .padding({ left: 14, top: 2 })

      if (p.text !== '') {
        Scroll() {
          Text(p.text)
            .fontFamily(AppFonts.family())
            .fontSize(13)
            .fontColor(this.col('hint'))
            .lineHeight(20)
            .width('100%')
        }
        .width('100%')
        .layoutWeight(1)
        .align(Alignment.TopStart)
        .scrollBar(BarState.Off)
        .padding({ left: 14, right: 14, bottom: 10 })
      }
    }
    .width('100%')
    .layoutWeight(1)
  }

  build() {
    Column({ space: 0 }) {
      this.headerRow()
      if (this.load().phase === 'busy') {
        this.bodyBusy(this.load())
      } else if (this.load().phase === 'done') {
        Column() {
          ResultPanel({
            result: this.load().text,
            type: this.load().type,
            title: this.load().title,
            exportMode: this.load().kind === 'courseware' ? 'json' : 'word',
            onSave: () => this.saveLive(),
            onEdited: (t: string): void => {
              this.patchText(t);
            }
          })
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: 14, right: 14, bottom: 12 })
      } else {
        Column() {
          Text(this.t('duo.idle'))
            .fontFamily(AppFonts.family())
            .fontSize(13)
            .fontColor(this.col('faint'))
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.col('card'))
    .border({ width: { top: 1 }, color: this.col('inputBg') })
  }
}

/** 2in1 全屏专用页面：
 *  - 双屏形态（无磁吸键盘、窗口跨轴铺满上/下两块物理屏）：手动按显示器几何精确分区
 *    上半屏=平板式工具界面，下半屏=生成结果大面板（中间留折痕避让带）
 *  - 单屏形态（展开平板等）：沿用 FoldSplitContainer 在单屏内上下分栏 */
@Component
export struct IndexWideDuo {
  @StorageProp('appLang') appLang: string = 'zh';
  @StorageProp('appResolvedTheme') resolvedTheme: string = 'light';
  /** 是否处于跨轴双屏形态（由 Index 在 duo + displayId=999 存在时写入） */
  @StorageProp('appTwoScreen') twoScreen: boolean = false;
  /** 左栏当前页签：assistant / family / mine */
  @State navTab: string = 'assistant';
  /** 右栏当前选中的功能 id（默认教案生成） */
  @State selId: string = 'plan';
  /** 右栏内容入场动画（切换工具时淡入 + 右移滑入） */
  @State paneIn: boolean = true;
  /** 左栏卡片网格过渡（切换页签时淡入 + 左移） */
  @State gridIn: boolean = true;
  /**
   * 左栏导航当前索引（0=备课助手 1=家校沟通 2=我的），与 navTab 一一对应。
   * 由 Tabs **构造参数** `index:` 消费（TabsAttribute 上没有 `.index()` 修饰器），
   * 并在 `.onChange()` 里回写，保持"外部改 navTab → Tabs 跟随"的单向同步。
   */
  @State tabsIndex: number = 0;
  /** 左栏（手机式面板）宽度：由 LayoutPolicy 按设备形态给出（三折叠/阔折叠更宽），缺省 400 */
  @StorageProp('appSidebarVp') sidebarVp: number = 400;

  private t(key: string): string {
    void this.appLang;
    return I18n.t(key);
  }

  private col(key: string): string {
    void this.resolvedTheme;
    return AppTheme.color(key, this.resolvedTheme);
  }

  /** 上半屏（displayId=0）显示区域高度（vp）：双屏形态下工具区精确占满上屏 */
  private screenTopVp(): number {
    return Duo2in1.topHeightVp();
  }

  /** 折痕区高度（vp）：上下屏之间的物理缝隙，内容需要避让。
   *  优先取 FoldDetect 汇总值（三折叠会返回多条折痕，已累加），无则回退 2in1 接缝实现。 */
  private creaseVp(): number {
    const fromFold: number = AppStorage.get<number>('appCreaseVp') as number;
    if (fromFold !== undefined && fromFold > 0) {
      return fromFold;
    }
    return Duo2in1.creaseVp();
  }

  /** 卡片图标底色（与手机首页卡片一致） */
  private iconBg(id: string): string {

    if (id === 'courseware') {
      return '#FFF4E5';
    }
    if (id === 'quiz') {
      return '#EAF7EF';
    }
    if (id === 'research') {
      return '#F3EDFB';
    }
    if (id === 'analysis') {
      return '#E6F4F2';
    }
    if (id === 'seats') {
      return '#FFF0E6';
    }
    if (id === 'talk') {
      return '#FFF0F0';
    }
    if (id === 'report') {
      return '#E8F1FB';
    }
    if (id === 'history') {
      return '#FFF4E5';
    }
    if (id === 'settings') {
      return '#EDF0FA';
    }
    if (id === 'classes') {
      return '#FDEFF0';
    }
    return '#E8F1FB';
  }

  private groupOf(tab: string): NavGroup {
    if (tab === 'family') {
      return {
        tabKey: 'tab.family',
        entries: [
          { id: 'talk', icon: '话', labelKey: 'card.talk', descKey: 'card.talk.desc' },
          { id: 'report', icon: '报', labelKey: 'card.report', descKey: 'card.report.desc' }
        ]
      };
    }
    if (tab === 'mine') {
      return {
        tabKey: 'tab.mine',
        entries: [
          { id: 'history', icon: '史', labelKey: 'card.history', descKey: 'card.history.desc' },
          { id: 'settings', icon: '设', labelKey: 'card.settings', descKey: 'card.settings.desc' },
          { id: 'classes', icon: '班', labelKey: 'card.classes', descKey: 'card.classes.desc' }
        ]
      };
    }
    return {
      tabKey: 'tab.assistant',
      entries: [

        { id: 'plan', icon: '教', labelKey: 'card.plan', descKey: 'card.plan.desc' },
        { id: 'courseware', icon: '课', labelKey: 'card.courseware', descKey: 'card.courseware.desc' },
        { id: 'quiz', icon: '题', labelKey: 'card.quiz', descKey: 'card.quiz.desc' },
        { id: 'research', icon: '研', labelKey: 'card.research', descKey: 'card.research.desc' },
        { id: 'analysis', icon: '析', labelKey: 'card.analysis', descKey: 'card.analysis.desc' },
        { id: 'seats', icon: '位', labelKey: 'card.seats', descKey: 'card.seats.desc' }
      ]
    };
  }

  /** 右栏内容平滑入场：先瞬时隐藏，再 240ms 淡入并轻微右滑 */
  private enterPane(): void {
    setTimeout(() => {
      animateTo({ duration: 240, curve: Curve.EaseOut }, () => {
        this.paneIn = true;
      });
    }, 30);
  }

  /** 页签索引（assistant/family/mine → 0/1/2） */
  private tabIndexOf(tab: string): number {
    if (tab === 'family') {
      return 1;
    }
    if (tab === 'mine') {
      return 2;
    }
    return 0;
  }

  /** 页签索引反查（0/1/2 → assistant/family/mine），与 tabIndexOf 互为逆运算 */
  private tabKeyOf(index: number): string {
    if (index === 1) {
      return 'family';
    }
    if (index === 2) {
      return 'mine';
    }
    return 'assistant';
  }

  /**
   * 系统默认底部导航项：BottomTabBarStyle(icon, text)，与手机主页面 / 平板页面同款。
   *
   * 原实现是手写的 Stack + Row：一个靠 `measureTabs()` 测宽、再按 tabOff 平移的
   * `#E8F1FB` 高亮块 + 一排纯文字（没有图标、没有系统选中态与点击动效）。
   * 换成系统默认样式后，图标在上、文字在下，选中态/着色/动效/深浅色适配全部由
   * 系统接管；当前页由 Tabs 构造参数 `index: this.tabsIndex` 指定。
   *
   * 图标用系统内置符号资源 `$r('sys.symbol.*')`，不新增图片文件；符号名取自 SDK
   * 资源索引 toolchains/id_defined.json（type=='symbol'），均已确认存在：
   *   house · message · person
   */
  private bottomStyle(icon: string, textKey: string): BottomTabBarStyle {
    return BottomTabBarStyle.of($r('sys.symbol.' + icon), this.t(textKey));
  }

  /**
   * 切换页签：左栏网格与右栏内容带过渡，右栏切到该页签首个工具。
   *
   * 同时把 tabsIndex 对齐到目标页签 —— 放在**早退之前**，与 IndexWide 保持一致，
   * 这样无论从哪条路径调用本方法，底部系统页签的选中态都不会与 navTab 脱节。
   */
  private switchTab(tab: string): void {
    this.tabsIndex = this.tabIndexOf(tab);
    if (this.navTab === tab) {
      return;
    }
    this.paneIn = false;
    this.gridIn = false;
    this.navTab = tab;
    const g: NavGroup = this.groupOf(tab);
    if (g.entries.length > 0) {
      this.selId = g.entries[0].id;
    }
    setTimeout(() => {
      animateTo({ duration: 260, curve: Curve.EaseOut }, () => {
        this.paneIn = true;
        this.gridIn = true;
      });
    }, 40);
  }

  /**
   * 左栏底部导航（系统默认 BottomTabBarStyle）。
   *
   * 为什么这里自己套了一层 Tabs：
   *   左栏本身是 split-screen 分栏里的一列（上面是标题 + 可滚动的卡片 Grid），
   *   系统默认底栏必须挂在 Tabs 组件上，所以这里用一个"**只有页签栏可见**"的 Tabs
   *   来承载它：内容区高度为 0（TabContent 逐项 .height(0)），Tabs 总高 56，
   *   页签栏靠 `barPosition: End` 正好落在这 56vp 里。
   *   这样 Tabs 既不会吃掉分栏高度，也不会在左栏里再造一套滚动内容，
   *   原来的三处内容（标题 / 卡片网格 / 右栏工具区）与分屏逻辑一行未动。
   */
  @Builder
  navTabs() {
    Tabs({ barPosition: BarPosition.End, index: this.tabsIndex }) {
      // 仅提供页签项；内容区高度为 0，真正的界面仍由 navTab 驱动的既有 Grid/右栏渲染
      TabContent() {
      }
      .height(0)
      .tabBar(this.bottomStyle('house', 'tab.assistant'))

      TabContent() {
      }
      .height(0)
      .tabBar(this.bottomStyle('message', 'tab.family'))

      TabContent() {
      }
      .height(0)
      .tabBar(this.bottomStyle('person', 'tab.mine'))
    }
    .width('100%')
    // 固定 56vp：系统默认底栏高度，显式约束避免在分屏列里被拉高或撑开
    .height(56)
    .barHeight(56)
    .barMode(BarMode.Fixed)
    .scrollable(false)
    // 与手机/平板页一致：背景交给主题色同步，高度/分割线由系统底栏样式决定
    .barBackgroundColor(this.col('barBg'))
    .onChange((index: number) => {
      // Tabs 索引 → 既有 tabKey，复用 switchTab 的全部既有行为
      // （设置 navTab、把 selId 重置为该分组首项、保留 paneIn/gridIn 过渡动画）
      // tabsIndex 由 switchTab 内部统一对齐，这里不重复赋值，避免两处状态源。
      this.switchTab(this.tabKeyOf(index));
    })
  }

  /** 选择工具：右栏内容过渡切换 */
  private pick(entry: NavEntry): void {
    if (this.selId === entry.id) {
      return;
    }
    this.paneIn = false;
    this.selId = entry.id;
    this.enterPane();
  }

  /** 右栏内容（2in1 专用）：AI 工具以 bottomResult=true 渲染，结果由下半屏承接 */
  @Builder
  renderContent() {
    if (this.selId === 'plan') {
      PlanContent({ bottomResult: true })
    } else if (this.selId === 'courseware') {
      CoursewareContent({ bottomResult: true })
    } else if (this.selId === 'quiz') {
      QuizContent({ bottomResult: true })
    } else if (this.selId === 'research') {
      ResearchContent({ bottomResult: true })
    } else if (this.selId === 'analysis') {
      AnalysisContent({ bottomResult: true })
    } else if (this.selId === 'seats') {
      SeatsContent()
    } else if (this.selId === 'talk') {
      TalkContent({ bottomResult: true })
    } else if (this.selId === 'report') {
      ReportContent({ bottomResult: true })
    } else if (this.selId === 'history') {
      HistoryContent()
    } else if (this.selId === 'classes') {
      ClassManagerContent()
    } else {
      SettingsContent()
    }
  }

  /** 左栏单个工具卡片（与平板版同款视觉） */
  @Builder
  toolCard(entry: NavEntry) {
    Column({ space: 7 }) {
      Text(I18n.badge(entry.icon, entry.labelKey))
        .fontFamily(AppFonts.family())
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor('#2B4C7E')
        .textAlign(TextAlign.Center)
        .width(44)
        .height(44)
        .borderRadius(11)
        .backgroundColor(this.iconBg(entry.id))
      Text(this.t(entry.labelKey))
        .fontFamily(AppFonts.family())
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.col('title'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .textAlign(TextAlign.Center)
      Text(this.t(entry.descKey))
        .fontFamily(AppFonts.family())
        .fontSize(10)
        .fontColor(this.col('hint'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .height(120)
    .justifyContent(FlexAlign.Center)
    .padding(8)
    .backgroundColor(this.col('card'))
    .borderRadius(13)
    .border({
      width: this.selId === entry.id ? 2 : 0,
      color: this.selId === entry.id ? '#4A90D9' : this.col('inputBg')
    })
    .shadow({ radius: 6, color: 'rgba(0,0,0,0.05)', offsetY: 2 })
    .onClick(() => this.pick(entry))
  }

  /** 主区：与平板一致的左侧导航 + 右侧工具（可滚动） */
  @Builder
  upperPane() {
    Row() {
      // ============ 左栏：加宽的手机式三 Tab 面板 ============
      Column() {
        // 当前页签标题
        Row() {
          Text(this.t(this.groupOf(this.navTab).tabKey))
            .fontFamily(AppFonts.family())
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.col('title'))
          Blank()
          Text($r('app.string.app_name'))
            .fontFamily(AppFonts.family())
            .fontSize(12)
            .fontColor(this.col('faint'))
        }
        .width('100%')
        .padding({ left: 4, right: 4, top: 14, bottom: 6 })

        // 当前页签的功能入口（两列紧凑卡片）
        Scroll() {
          Grid() {
            ForEach(this.groupOf(this.navTab).entries, (entry: NavEntry) => {
              GridItem() {
                this.toolCard(entry)
              }
            }, (entry: NavEntry) => entry.id)
          }
          .columnsTemplate('1fr 1fr')
          .columnsGap(10)
          .rowsGap(10)
          .width('100%')
          .padding({ left: 8, right: 8, top: 8, bottom: 8 })
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Off)
        .opacity(this.gridIn ? 1 : 0)
        .translate({ x: this.gridIn ? 0 : -18 })

        // 底部三 Tab：系统默认 BottomTabBarStyle（图标在上、文字在下，选中态由系统着色）
        this.navTabs()
      }
      .width(this.sidebarVp)
      .height('100%')
      .padding({ left: 10, right: 10 })
      .backgroundColor(this.col('card'))
      .border({ width: { right: 1 }, color: this.col('inputBg') })

      // ============ 右栏：所选工具页面（可滚动） ============
      Column() {
        Scroll() {
          Column() {
            this.renderContent()
          }
          .width('100%')
        }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        .align(Alignment.Top)
      }
      .layoutWeight(1)
      .height('100%')
      .backgroundColor(this.col('bg'))
      .opacity(this.paneIn ? 1 : 0)
      .translate({ x: this.paneIn ? 0 : 26 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.col('bg'))
  }

  /** 次区：下半屏结果大面板（FoldSplitContainer secondary / 双屏手动分区的下半区） */
  @Builder
  resultBar() {
    DuoResultBar()
      .width('100%')
      .height('100%')
  }

  /**
   * 双屏跨轴形态：按真实显示器几何精确分区，让上下两区正好各占一块物理屏。
   *  - 上半区：工具界面（upperPane），高度=上屏（displayId=0）高度
   *  - 中间：折痕避让带（物理缝隙，不放置任何内容）
   *  - 下半区：生成结果大面板（DuoResultBar），占满下屏剩余全部高度
   */
  @Builder
  duoTwoPane() {
    Column({ space: 0 }) {
      Column() {
        this.upperPane()
      }
      .width('100%')
      .height(this.screenTopVp())

      // 折痕避让带（背景与页面一致，避免缝隙处露白/显示错乱）
      Column()
        .width('100%')
        .height(this.creaseVp())
        .backgroundColor(this.col('bg'))

      Column() {
        this.resultBar()
      }
      .width('100%')
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.col('bg'))
  }

  build() {
    if (this.twoScreen) {
      // 双屏形态：窗口已跨轴铺满上下两屏，手动按物理屏精确分区（结果真正落到下屏）
      this.duoTwoPane()
    } else {
      // 单屏形态（展开平板 / 折叠屏半折 / 兼容回退）：FoldSplitContainer 按系统折叠状态自动分栏
      //  - expandedLayoutOptions：完全展开（双折叠/阔折叠/三折叠展开）时工具区与结果区比例
      //  - hoverModeLayoutOptions：半折悬停时上下分区
      //  - foldedLayoutOptions：合起（用外屏）时上下比例
      FoldSplitContainer({
        primary: () => {
          this.upperPane()
        },
        secondary: () => {
          this.resultBar()
        },
        expandedLayoutOptions: { verticalSplitRatio: this.expandedRatio() },
        hoverModeLayoutOptions: { showExtraRegion: false },
        foldedLayoutOptions: { verticalSplitRatio: 1 }
      })
        .width('100%')
        .height('100%')
    }
  }

  /**
   * 展开态上下比例：
   *  - 三折叠展开后纵向空间充裕，工具区给更大比例（1.7）以完整展示卡片网格
   *  - 其余（单折轴折叠屏 / 平板 / 2in1）沿用 1.5
   */
  private expandedRatio(): number {
    const form: number = AppStorage.get<number>('appFoldForm') as number;
    // FoldForm: NONE=0 DUAL=1 WIDE=2 TRIPLE=3
    if (form === FoldForm.TRIPLE) {
      return 1.7;
    }
    return 1.5;
  }
}
