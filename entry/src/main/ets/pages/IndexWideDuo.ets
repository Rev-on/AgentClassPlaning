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
  /** 底部页签高亮选择块：单格宽度与当前偏移（vp，onAreaChange 测量后生效） */
  @State tabSlot: number = 0;
  @State tabOff: number = 0;
  /** 左栏（手机式面板）宽度（vp） */
  private readonly NAV_W: number = 400;

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

  /** 折痕区高度（vp）：上下屏之间的物理缝隙，内容需要避让 */
  private creaseVp(): number {
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

  /** 测量底部页签容器宽度：计算选择块单格宽度并定位当前偏移 */
  private measureTabs(width: number): void {
    if (width <= 0) {
      return;
    }
    const slot: number = width / 3;
    this.tabSlot = slot;
    this.tabOff = this.tabIndexOf(this.navTab) * slot;
  }

  /** 切换页签：左栏网格与右栏内容带过渡，右栏切到该页签首个工具 */
  private switchTab(tab: string): void {
    if (this.navTab === tab) {
      return;
    }
    const idx: number = this.tabIndexOf(tab);
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
        if (this.tabSlot > 0) {
          // 底部高亮选择块平滑滑到新页签
          this.tabOff = idx * this.tabSlot;
        }
      });
    }, 40);
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
          Text('Agent备课')
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

        // 底部三 Tab：选中高亮块在页签间平滑滑动
        Stack({ alignContent: Alignment.Start }) {
          Column()
            .width(this.tabSlot)
            .height(40)
            .borderRadius(10)
            .backgroundColor('#E8F1FB')
            .offset({ x: this.tabOff })
          Row() {
            ForEach(['assistant', 'family', 'mine'], (tab: string) => {
              Text(this.t(this.groupOf(tab).tabKey))
                .fontFamily(AppFonts.family())
                .fontSize(13)
                .fontColor(this.navTab === tab ? '#4A90D9' : this.col('hint'))
                .fontWeight(this.navTab === tab ? FontWeight.Bold : FontWeight.Normal)
                .textAlign(TextAlign.Center)
                .layoutWeight(1)
                .height(40)
                .onClick(() => this.switchTab(tab))
            }, (tab: string) => tab)
          }
          .width('100%')
          .height(40)
          .onAreaChange((oldValue: Area, newValue: Area) => {
            const w: number = Number(newValue.width);
            this.measureTabs(w);
          })
        }
        .width('100%')
        .height(48)
        .padding(4)
        .backgroundColor(this.col('barBg'))
        .borderRadius(12)
        .margin({ top: 2, bottom: 8 })
      }
      .width(this.NAV_W)
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
      // 单屏形态（展开平板/兼容回退）：FoldSplitContainer 在单屏内上下分栏
      FoldSplitContainer({
        primary: () => {
          this.upperPane()
        },
        secondary: () => {
          this.resultBar()
        },
        expandedLayoutOptions: { verticalSplitRatio: 1.5 },
        hoverModeLayoutOptions: { showExtraRegion: false },
        foldedLayoutOptions: { verticalSplitRatio: 1 }
      })
        .width('100%')
        .height('100%')
    }
  }
}
