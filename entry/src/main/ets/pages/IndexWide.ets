/**
 * 平板 / 横屏两栏布局（Index 在宽屏时使用）
 *  - 左栏（加宽）：手机式三 Tab 界面 —— 底部页签「备课助手 / 家校沟通 / 我的」+ 当前页签的功能入口卡片
 *  - 右栏：渲染所选功能页面（组件化复用，无整屏跳转）
 * 手机/窄屏保持原有底部 Tabs（由 Index 决定使用本组件与否）
 */
import { I18n } from '../common/I18n';
import { AppTheme } from '../common/AppTheme';
import { AppFonts } from '../common/AppFonts';
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

@Component
export struct IndexWide {
  @StorageProp('appLang') appLang: string = 'zh';
  @StorageProp('appResolvedTheme') resolvedTheme: string = 'light';
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
  /** 左侧栏宽度：由 LayoutPolicy 按设备形态给出（三折叠/阔折叠更宽），缺省 400 */
  @StorageProp('appSidebarVp') sidebarVp: number = 400;

  private t(key: string): string {
    void this.appLang;
    return I18n.t(key);
  }

  private col(key: string): string {
    void this.resolvedTheme;
    return AppTheme.color(key, this.resolvedTheme);
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

  /** 右栏内容：按当前选中项渲染对应功能页面组件 */
  @Builder
  renderContent() {
    if (this.selId === 'plan') {
      PlanContent()
    } else if (this.selId === 'courseware') {
      CoursewareContent()
    } else if (this.selId === 'quiz') {
      QuizContent()
    } else if (this.selId === 'research') {
      ResearchContent()
    } else if (this.selId === 'analysis') {
      AnalysisContent()
    } else if (this.selId === 'seats') {
      SeatsContent()
    } else if (this.selId === 'talk') {
      TalkContent()
    } else if (this.selId === 'report') {
      ReportContent()
    } else if (this.selId === 'history') {
      HistoryContent()
    } else if (this.selId === 'classes') {
      ClassManagerContent()
    } else {
      SettingsContent()
    }
  }

  /** 左栏单个工具卡片（手机首页 FunCard 同款视觉） */
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

  build() {
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

        // 当前页签的功能入口（两列紧凑卡片；可滚动区域吸收剩余高度，底部页签固定）
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
          // 滑动高亮块
          Column()
            .width(this.tabSlot)
            .height(40)
            .borderRadius(10)
            .backgroundColor('#E8F1FB')
            .offset({ x: this.tabOff })
          // 页签文字
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
      .width(this.sidebarVp)
      .height('100%')
      .padding({ left: 10, right: 10 })
      .backgroundColor(this.col('card'))
      .border({ width: { right: 1 }, color: this.col('inputBg') })

      // ============ 右栏：所选工具页面 ============
      Column() {
        this.renderContent()
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
}
