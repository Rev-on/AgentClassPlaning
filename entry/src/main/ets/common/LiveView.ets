/**
 * 实况窗管理（Live View Kit）
 *
 * 行为：
 *   - 生成**开始**即创建实况窗（胶囊 + 卡片），随后随生成进度更新百分比
 *   - 生成完成/失败/停止时结束实况窗
 *   - 进程被系统回收后，客户端无法再更新；此时由**服务端**在任务完成时
 *     用 Push Kit（push-type 7）结束实况窗（见 server/src/push.js 的 sendLiveViewEnd）
 *
 * 关键实现约束（来自本地 SDK @hms.core.liveview.liveViewManager.d.ts）：
 *   - LiveView 顶层是 `id: number` + `event: string` + `liveViewData`，
 *     **没有** activityId 字段（网上部分示例已过时）
 *   - 进度百分比走 ProgressLayout.progress（layoutType=3），需 SDK 26.0.0
 *   - lifeCycleMode 用于声明进程终止时是否自动结束
 *
 * 容错：任何失败都只写日志，绝不抛出 —— 实况窗是锦上添花，不能影响生成主流程。
 */
import { liveViewManager } from '@kit.LiveViewKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { wantAgent, WantAgent } from '@kit.AbilityKit';
import { GenProgress } from './GenProgress';

const DOMAIN = 0x0000;
const TAG = 'LiveView';

/** 图标资源（放在 resources/rawfile/ 下，用文件名引用；缺失时系统回退应用图标） */
const ICON: string = 'liveview/liveview_icon.png';

/**
 * 进度条上的节点图标（nodeIcons）。
 *
 * 虽然 SDK 里 nodeIcons 是可选字段（nodeIcons?），但**运行时会强制校验**，
 * 不传直接报 401：
 *   The type of layoutData.nodeIcons must be Array<string | image.PixelMap>
 *   [or the parameter is mandatory]
 * 因此这里固定提供"已完成 / 待完成"两个节点图标。
 */
const NODE_ICONS: string[] = ['liveview/node_done.png', 'liveview/node_todo.png'];

/**
 * 构造进度条布局。
 *
 * 重要背景（为什么每个字段都填）：
 *   SDK 的 .d.ts 把 ProgressLayout 中除 layoutType/progress 外的字段**全标为可选**，
 *   但**运行时会逐个强制校验**，缺一个就报：
 *     401 Parameter error. The type of <字段> ... [or the parameter is mandatory]
 *   已经依次踩到：clickAction → nodeIcons。
 *   逐个试错的代价是每轮都要重新打包 + 重装，因此这里**一次性填全所有字段**。
 */
function buildProgressLayout(progress: number, title: string): liveViewManager.ProgressLayout {
  return {
    layoutType: liveViewManager.LayoutType.LAYOUT_TYPE_PROGRESS,
    progress: progress,
    color: '#FF4A90D9',
    backgroundColor: '#FFE5E5E5',
    indicatorType: liveViewManager.IndicatorType.INDICATOR_TYPE_UNDISPLAYED,
    indicatorIcon: NODE_ICONS[0],
    lineType: liveViewManager.LineType.LINE_TYPE_NORMAL_SOLID_LINE,
    nodeIcons: NODE_ICONS,
    title: title
  } as liveViewManager.ProgressLayout;
}

/**
 * 构造胶囊数据。
 *
 * 本轮真机报错即来自此处的 backgroundColor：
 *   401 The type of capsule.backgroundColor must be string
 *       [or the parameter is mandatory]
 * 故 CapsuleData 的全部字段（type/status/icon/backgroundColor/
 * isContentDisplayed/tailIcon/isTailIconDisplayed）与 ProgressCapsule 的
 * 全部字段（max/progress/indeterminate/content）均显式填写。
 */
function buildCapsule(progress: number): liveViewManager.ProgressCapsule {
  return {
    type: liveViewManager.CapsuleType.CAPSULE_TYPE_PROGRESS,
    status: 1,
    icon: ICON,
    // 胶囊背景：系统胶囊通常为深色，这里用主题深蓝保证与白色文字对比
    backgroundColor: '#FF2B3A4A',
    isContentDisplayed: true,
    tailIcon: ICON,
    isTailIconDisplayed: true,
    // ---- ProgressCapsule 专属 ----
    max: 100,
    progress: progress,
    indeterminate: false,
    content: progress + '%'
  } as liveViewManager.ProgressCapsule;
}

/**
 * 构造 primary 区域。
 *
 * PrimaryData 在 SDK 中也**全部为可选**，同理全部填上，避免再次逐个踩坑。
 */
function buildPrimary(progress: number, title: string,
  agent: WantAgent | null): liveViewManager.PrimaryData {
  return {
    title: title,
    content: [{ text: progress <= 0 ? '正在生成…' : ('已生成 ' + progress + '%') }],
    clickAction: agent === null ? undefined : agent,
    layoutData: buildProgressLayout(progress, title),
    // 实况窗存活时长（秒）：生成通常几分钟，给 30 分钟足够，系统上限 8 小时
    keepTime: 1800,
    aliveTime: 1800
  } as liveViewManager.PrimaryData;
}

/**
 * 实况窗场景（event）。
 *
 * **华为支持的 14 个场景**（取值必须原样使用下列大写英文，含下划线）：
 *   TAXI             出行打车（网约车/出租车/拼车/顺风车）
 *   DELIVERY         即时配送（外卖/生鲜/同城配送）
 *   FLIGHT           航班
 *   TRAIN            高铁/火车
 *   QUEUE            排队叫号（办事大厅/医院/银行/餐饮）
 *   PICK_UP          取餐（注意是 PICK_UP，带下划线，不是 PICKUP）
 *   SCORE            赛事比分
 *   RENT             共享租赁（单车/充电宝/停车场）
 *   TIMER            计时（正计时/倒计时，官方限定"仅工具类应用"）
 *   SUBSCRIBE_TIMER  订阅计时（开售倒计时）
 *   WORKOUT          运动锻炼
 *   NAVIGATION       导航
 *   CHECK_IN         打卡（上下班）
 *   EXPRESS          快递取件
 *
 * 注意：`PROGRESS` **不是**场景名 —— 它是 **布局类型** LAYOUT_TYPE_PROGRESS
 * （用于 liveViewData.primary.layoutData），本文件下方已正确使用。
 * 二者容易混淆：AGC 开通的是"场景"，布局由代码指定。
 *
 * event 必须与 AGC「实况窗」权益中开通的场景一致，否则 startLiveView 返回
 * 1003500005（The right of liveView is not enabled）。
 *
 * 因此按优先级依次尝试全部 14 个合法场景，首个成功者被记住并复用 ——
 * 这样无论 AGC 中实际开通的是哪一个，都能自动匹配，无需为试 event 反复重装。
 */
const EVENTS: string[] = [
  // ① 语义最贴近："AI 生成进度"＝时段性进度、无业务状态节点
  'TIMER',
  // ② 同为持续性进度类，且不强制状态流转
  'RENT', 'WORKOUT', 'SUBSCRIBE_TIMER', 'QUEUE',
  // ③ 取餐/快递类（与"生成产物"语义尚可类比）
  'PICK_UP', 'EXPRESS', 'CHECK_IN',
  // ④ 其余合法场景兜底（仅用于匹配 AGC 实际开通项）
  'DELIVERY', 'TAXI', 'TRAIN', 'FLIGHT', 'SCORE', 'NAVIGATION'
];

/** 单实例管理：同一时刻只维护一个实况窗 */
export class LiveView {
  private static id: number = 0;
  private static active: boolean = false;
  private static progress: GenProgress | null = null;
  private static title: string = '';
  private static seq: number = 0;
  /** 上次上报的百分比，避免无变化时频繁调用（系统对更新频率有限制） */
  private static lastPct: number = -1;
  /** 可用的事件名（首次成功后固定下来） */
  private static okEvent: string = '';
  /**
   * 点击实况窗时跳转的 WantAgent。
   *
   * **clickAction 是必填项**：不传会报
   *   401 Parameter error. The type of primary.clickAction must be WantAgent
   * （真机日志实测确认，且与 event 取值无关）。
   * 创建后缓存复用，避免每次更新都重新构造。
   */
  private static clickAgent: WantAgent | null = null;

  /** 构造/复用"点击实况窗回到应用"的 WantAgent */
  private static async getClickAgent(): Promise<WantAgent | null> {
    if (LiveView.clickAgent !== null) {
      return LiveView.clickAgent;
    }
    try {
      const info: wantAgent.WantAgentInfo = {
        wants: [
          {
            bundleName: 'com.rev.myapplication',
            abilityName: 'EntryAbility'
          }
        ],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      LiveView.clickAgent = await wantAgent.getWantAgent(info);
      return LiveView.clickAgent;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'getWantAgent 失败: %{public}s', LiveView.msg(e));
      return null;
    }
  }

  /** 生成开始：创建实况窗 */
  static async start(kind: string, title: string): Promise<void> {
    try {
      const enabled: boolean = await liveViewManager.isLiveViewEnabled();
      if (!enabled) {
        hilog.info(DOMAIN, TAG, '实况窗未开启（用户或系统关闭），跳过');
        return;
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'isLiveViewEnabled 失败: %{public}s', LiveView.msg(e));
      return;
    }

    LiveView.progress = new GenProgress(kind);
    LiveView.title = title;
    LiveView.seq = 1;
    LiveView.lastPct = -1;
    LiveView.id = 0;
    LiveView.active = false;

    const evts: string[] = LiveView.okEvent !== '' ? [LiveView.okEvent] : EVENTS;
    for (let i = 0; i < evts.length; i++) {
      const ok: boolean = await LiveView.tryStart(evts[i]);
      if (ok) {
        LiveView.okEvent = evts[i];
        LiveView.active = true;
        hilog.info(DOMAIN, TAG, '实况窗已创建 event=%{public}s', evts[i]);
        return;
      }
    }
    hilog.warn(DOMAIN, TAG, '实况窗创建失败（所有 event 均被拒）');
  }

  /** 尝试用某个 event 创建；成功返回 true */
  private static async tryStart(event: string): Promise<boolean> {
    const agent: WantAgent | null = await LiveView.getClickAgent();
    const lv: liveViewManager.LiveView = {
      id: 0,
      event: event,
      sequence: 1,
      // 进程被系统终止时由系统结束实况窗，避免残留
      lifeCycleMode: liveViewManager.LifeCycleMode.AUTO_STOP_WHEN_APP_TERMINATE,
      liveViewData: {
        primary: buildPrimary(0, LiveView.title, agent),
        capsule: buildCapsule(0)
      }
    };
    try {
      const r: liveViewManager.LiveViewResult = await liveViewManager.startLiveView(lv);
      LiveView.id = Number(r.resultCode) === 0 ? lv.id : LiveView.id;
      return true;
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(DOMAIN, TAG, 'startLiveView event=%{public}s 失败 code=%{public}d %{public}s',
        event, err.code === undefined ? -1 : err.code, LiveView.msg(e));
      return false;
    }
  }

  /** 思考阶段有进展 */
  static async onThinking(): Promise<void> {
    if (!LiveView.active || LiveView.progress === null) {
      return;
    }
    LiveView.progress.onThinking();
    await LiveView.push();
  }

  /** 正文有进展（传入当前已生成正文） */
  static async onContent(content: string): Promise<void> {
    if (!LiveView.active || LiveView.progress === null) {
      return;
    }
    LiveView.progress.onContent(content);
    await LiveView.push();
  }

  /**
   * 正文有进展（只知道长度时使用）。
   * 用于课件页：该页刻意不保留半成品正文，但可用已生成长度驱动进度。
   */
  static async onLength(len: number): Promise<void> {
    if (!LiveView.active || LiveView.progress === null) {
      return;
    }
    LiveView.progress.onLength(len);
    await LiveView.push();
  }

  /** 把当前进度推送到实况窗（百分比无变化时跳过，降低调用频率） */
  private static async push(): Promise<void> {
    if (LiveView.progress === null) {
      return;
    }
    const pct: number = LiveView.progress.current();
    if (pct === LiveView.lastPct) {
      return;
    }
    LiveView.lastPct = pct;
    LiveView.seq++;
    const lv: liveViewManager.LiveView = {
      id: LiveView.id,
      event: LiveView.okEvent === '' ? EVENTS[0] : LiveView.okEvent,
      sequence: LiveView.seq,
      liveViewData: {
        primary: buildPrimary(pct, LiveView.title, LiveView.clickAgent),
        capsule: buildCapsule(pct)
      }
    };
    try {
      await liveViewManager.updateLiveView(lv);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'updateLiveView 失败 code=%{public}d', LiveView.code(e));
    }
  }

  /** 生成结束：先置 100% 再结束 */
  static async done(): Promise<void> {
    if (!LiveView.active || LiveView.progress === null) {
      return;
    }
    LiveView.progress.onDone();
    LiveView.lastPct = -1;
    await LiveView.push();
    await LiveView.stop();
  }

  /** 结束实况窗 */
  static async stop(): Promise<void> {
    if (!LiveView.active) {
      return;
    }
    const lv: liveViewManager.LiveView = {
      id: LiveView.id,
      event: LiveView.okEvent === '' ? EVENTS[0] : LiveView.okEvent,
      sequence: LiveView.seq + 1,
      liveViewData: { primary: { title: LiveView.title } }
    };
    try {
      await liveViewManager.stopLiveView(lv);
      hilog.info(DOMAIN, TAG, '实况窗已结束');
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'stopLiveView 失败 code=%{public}d', LiveView.code(e));
    }
    LiveView.active = false;
    LiveView.progress = null;
    LiveView.lastPct = -1;
  }

  /** 是否处于活动状态（供调用方避免无谓调用） */
  static isActive(): boolean {
    return LiveView.active;
  }

  private static code(e: Object): number {
    const err = e as BusinessError;
    return err.code === undefined ? -1 : err.code;
  }

  private static msg(e: Object): string {
    const err = e as BusinessError;
    if (err.message !== undefined && err.message !== '') {
      return err.message;
    }
    return String(e);
  }
}
