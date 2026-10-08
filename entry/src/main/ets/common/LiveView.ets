/**
 * 实况窗管理（Live View Kit）
 *
 * ============================================================================
 * 【核心诉求】7 大 AI 生成功能（plan/courseware/quiz/research/analysis/talk/report）
 * 生成过程中，用户把应用退出到后台，桌面（状态栏 / 锁屏 / 胶囊）的实况窗必须
 * **继续实时显示生成进度**，而不是冻结在退出那一刻的百分比。
 * ============================================================================
 *
 * ----------------------------------------------------------------------------
 * 一、问题根因（为什么 v1 会在后台冻结）
 * ----------------------------------------------------------------------------
 * v1 的进度链路是**纯进程内回调驱动**的：
 *     页面 SSE onDelta → LiveView.onContent(partial) → GenProgress.onLength
 *     → liveViewManager.updateLiveView()
 * 用户按 Home / 锁屏后，鸿蒙把应用进程置为**挂起（suspended）**状态，JS 引擎
 * 被冻结，上述回调**不再被触发**；同时下面这个循环体本身也依赖进程在跑：
 *     AiService.chatByTask → SSE feed / 轮询 → onDelta
 * 两个环节同时停摆 ⇒ updateLiveView 再也不会被调用 ⇒ 实况窗进度永久冻结。
 * 这不是实况窗本身的问题，而是"**驱动源在进程里**"的架构问题。
 *
 * ----------------------------------------------------------------------------
 * 二、v2 方案（三条腿，缺一不可）
 * ----------------------------------------------------------------------------
 * 腿 1【时间驱动的进度模型】—— 解决"重新被调度时能补齐"
 *   GenProgress v2 把进度改成 max(阶段锚点, 时间滑轨)：
 *   · 阶段锚点：回调驱动（保留 v1 语义），后台挂起期间不动；
 *   · 时间滑轨：只依赖 `Date.now() - startTime`，与回调完全无关。
 *   进程被挂起期间当然什么都不会变（这是系统的硬约束，任何纯软件手段都无法
 *   在挂起态执行 JS）；但**只要进程被重新调度**，下一次 current() 就会按真实
 *   流逝时间把百分比补齐到"本该到的位置"，观感上是"一直在走"，而不是卡死。
 *   这是所有后续手段的地基。
 *
 * 腿 2【后台短时任务 requestSuspendDelay】—— 解决"挂起后根本没有调度机会"
 *   只有腿 1 还不够：若进程被无限期挂起，滑轨永远没有机会被读取。
 *   因此在"生成开始"时申请一个**短时任务（transient task）**：
 *     backgroundTaskManager.requestSuspendDelay(reason, callback)
 *   · 官方语义：申请后应用**延迟进入挂起态**，系统在 actualDelayTime(ms)
 *     内仍会让应用（短时）运行；到期时回调告知。
 *   · **不需要任何权限**：本地 SDK
 *     @ohos.resourceschedule.backgroundTaskManager.d.ts:553 的函数声明处
 *     没有 @permission 标注（对比 startBackgroundRunning:570 明确要求
 *     ohos.permission.KEEP_BACKGROUND_RUNNING）。@since 9，公开 API。
 *   · 于是"退到后台"这段时间里，我们的看门狗定时器仍在跑，周期 `pump()`：
 *       ① 按时间补齐并 updateLiveView —— 实况窗**真的在实时动**；
 *       ② 顺带用 GenTask.fetchTask 拉服务端权威进度（让百分比贴近真实产出）；
 *       ③ 当滑轨逼近渐近上限或短时额度将尽时，重新申请一次短时任务（续期）。
 *   · 到期/额度耗尽后进程仍会被挂起 —— 此时退回腿 1 的语义：静默停住，
 *     但滑轨的 max() 保证恢复调度瞬间就补齐，绝不回退、不错乱。
 *
 * 腿 3【生命周期接缝 EntryAbility.onForeground/onBackground】—— 解决"谁在后台驱动"
 *   onBackground 时：标记后台态 + 确保看门狗在跑 + 确保短时任务在手
 *                    （这一动作**绝不**结束实况窗，v1 也没有任何地方结束它，
 *                      本版把这个语义显式化并加了回归测试）。
 *   onForeground 时：复位前台态，让页面回调重新拿到主导权（看门狗继续做补齐）。
 *
 * 【为什么不用长时任务 startBackgroundRunning】
 *   · 它是**受限权限**：需要 ohos.permission.KEEP_BACKGROUND_RUNNING
 *     （@ohos.resourceschedule.backgroundTaskManager.d.ts:570 明确标注），
 *     该权限属受限开放权限，需在 AGC 单独申请、审核严格，还要在 module.json5
 *     声明 backgroundModes；
 *   · 它会**常驻一条系统通知**（"应用正在后台运行"），而本应用的完成通知
 *     已经由 Push Kit 负责，再加一条常驻通知属于打扰用户；
 *   · 本场景是"生成中的短时进度展示"（几十秒~几分钟），不是导航/录音那种
 *     必须持续运行的长时业务，短时任务 + 时间滑轨已足够覆盖，合规成本最低。
 *   ⇒ 明确**不采用**长时任务；因此也**不需要**改 module.json5 加权限。
 *     若 AGC 后续开通了长时任务且产品需要超长生成(>10min)的后台实时性，
 *     再在此处增加 startBackgroundRunning 分支即可（接口见 SDK :662）。
 *
 * 【为什么不在客户端用 Push Kit 做周期性进度推送】
 *   1) 客户端无 Push Kit 的"应用内消息"权限；
 *   2) 自建 Node 服务端用 REST API 发**数据消息**需要应用在前台才展示，
 *      不适合做进度；
 *   3) 退一步：即使不推送进度，"结束实况窗"这件事已经由服务端 push-type 7
 *      兜底（见 LiveViewReport.ets），不会残留。
 *
 * ----------------------------------------------------------------------------
 * 三、兜底链路（进程真的被杀时）
 * ----------------------------------------------------------------------------
 *   ① 服务端任务在云端队列继续跑完（不受客户端生死影响）；
 *   ② 任务结束后端用 Push Kit push-type 7 结束实况窗（LiveViewReport.bind 已绑定
 *      activityId）——不会残留"生成中"；
 *   ③ GenTask.recover 在下次启动时静默把结果补进历史；
 *   ④ 完成通知（notifySeed 复用同一 notifyId，覆盖旧通知）。
 *   另外 startLiveView 传 lifeCycleMode=AUTO_STOP_WHEN_APP_TERMINATE，
 *   进程被系统终止时实况窗由系统直接收起。
 *
 * ----------------------------------------------------------------------------
 * 四、SDK 契约约束（来自本地 @hms.core.liveview.liveViewManager.d.ts，
 *     HarmonyOS 26.0.0 / API 26，绝对权威）
 * ----------------------------------------------------------------------------
 *   - LiveView 顶层是 `id: number` + `event: string` + `liveViewData`，
 *     **没有** activityId 字段（网上部分示例已过时）
 *   - 进度百分比走 ProgressLayout.progress（layoutType=3），需 SDK 26.0.0
 *   - lifeCycleMode（@since 26.0.0）声明进程终止时是否自动结束
 *   - liveViewManager 是**系统代理**，必须在 UIAbility 的 Context 下调用
 *     （子系统代理的调用方校验），故本类显式持有 UIAbilityContext
 *
 * 容错：任何失败（实况窗 / 后台任务 / 网络）都只写 hilog，绝不抛出、
 *       绝不 await 阻塞生成主流程 —— 实况窗是锦上添花，不能影响生成。
 */
import { liveViewManager } from '@kit.LiveViewKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import http from '@ohos.net.http';
import common from '@ohos.app.ability.common';
import { wantAgent, WantAgent } from '@kit.AbilityKit';
import { GenProgress } from './GenProgress';
import { LiveViewReport } from './LiveViewReport';
import { GenTask } from './GenTask';

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

/* ==================== 看门狗 / 后台短时任务参数 ==================== */

/** 实况窗更新节拍（毫秒）。系统对实况窗更新频率有限制，2s 足够"实时"且不越界 */
const TICK_MS: number = 2000;
/**
 * 服务端权威进度拉取节流（毫秒）。
 *
 * 【为什么是 8s 而不是更小】
 *   服务端在任务进行中会**自己**按 LIVEVIEW_MIN_UPDATE_MS（默认 10s）补推
 *   实况窗进度。两条链路写的是同一个实况窗，取值刻意避开 10s 的整除相位
 *   （2s tick 若用 6s 会与 10s 每隔 30s 精确锁步撞在一起，形成周期性的
 *   "同一秒两次更新"），8s 与 10s 的最小公倍数是 40s，冲突频率最低。
 *   再密也没有收益：服务端产出长度的变化本来就被它自己的 10s 节流限制住了。
 */
const POLL_MS: number = 8000;
/** 运行期上限：超过则停掉看门狗（防止异常路径下定时器泄漏） */
const MAX_TICK_MS: number = 45 * 60 * 1000;
/** 短时任务剩余不足该值时，在后台重新申请续期 */
const RENEW_BELOW_MS: number = 6000;
/** 网络查询单次超时（毫秒），避免后台卡在慢请求上 */
const FETCH_TIMEOUT_MS: number = 4000;

/** 服务端任务状态（只取本文件关心的字段） */
interface TaskProbe {
  status: string;
  content?: string;
  reasoning?: string;
}

/** 服务端 /task/:id 响应 */
interface TaskResp {
  ok?: boolean;
  task?: TaskProbe;
}

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
 *
 * @param progress 百分比
 * @param title 标题（功能名）
 * @param agent 点击跳转
 * @param suffix 进度文案后缀：前台回调驱动时为空（"已生成 N%"），
 *               后台时间外推时带"约"（"约 N%"），避免把估算值说成真实值
 */
function buildPrimary(progress: number, title: string,
  agent: WantAgent | null, suffix: string): liveViewManager.PrimaryData {
  return {
    title: title,
    content: [{
      text: progress <= 0
        ? '正在生成…'
        : (suffix === '' ? ('已生成 ' + progress + '%') : (suffix + progress + '%'))
    }],
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

/**
 * 生成一个**业务侧自有**的 activityId（实况窗唯一标识）。
 *
 * 【为什么必须自己生成】
 *   Push Kit 结束实况窗（push-type 7）时报文里只有 `activityId`，
 *   系统靠它与本地实况窗对应。而 `LiveViewResult` **只返回 resultCode/message，
 *   不含任何 id**（见 SDK @hms.core.liveview.liveViewManager.d.ts:1416）——
 *   也就是说**服务端拿不到系统分配的标识，必须由 App 自己指定 id**。
 *   官方接入说明亦明确：客户端 `view.id` 需与服务端 `HmPayload.activityId` 一致。
 *
 * 【取值约束】
 *   必须是正整数（Number.isInteger 且 > 0），否则 startLiveView 报 401。
 *   用 Date.now() 毫秒值：单调递增、天然唯一，且远大于 0，跨进程重启也不会撞。
 *   末尾 `% 2147483647` 保证落在 32 位有符号正整数范围内（部分实现按 int32 校验）。
 */
function nextActivityId(): number {
  return Date.now() % 2147483647;
}

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

  /** 实况窗 id 对应的服务端任务 id（用于后台拉权威进度 / 判断是否已结束） */
  private static taskId: string = '';
  /** 应用上下文（UIAbilityContext）。系统代理要求调用方是 UIAbility */
  private static ctx: common.UIAbilityContext | null = null;
  /** 当前任务类型（plan/courseware/...），用于时间滑轨的时间尺度 */
  private static kind: string = '';

  /* ---- 看门狗（与页面解耦的进度驱动定时器） ---- */
  private static tick: number = -1;
  private static startedAt: number = 0;
  private static lastFetch: number = 0;
  /** 是否处于后台（由 EntryAbility.onBackground/onForeground 驱动） */
  private static bg: boolean = false;
  /** 当前百分比是否来自时间外推（后台、无回调），决定文案用不用"约" */
  private static estimated: boolean = false;
  private static fetchBusy: boolean = false;

  /* ---- 后台短时任务 ---- */
  private static suspendId: number = -1;
  private static suspendLeft: number = 0;
  /** 收到"短时任务即将到期"通知时的时间戳，用于节流续期申请 */
  private static lastExpireLog: number = 0;

  /* ==================== 初始化 ==================== */

  /**
   * 注入应用上下文（在 UIAbility.onCreate 中调用）。
   *
   * 【为什么必须显式注入】
   *   liveViewManager 是系统代理（SystemCapability.LiveView.LiveViewService），
   *   对调用方有 UIAbility 身份校验；从"页面/后台定时器"里直接拿全局上下文
   *   有风险，因此由 EntryAbility 在最早时机把 context 交给本类保存。
   *   同时它也是后台任务 requestSuspendDelay 的唯一入口。
   */
  static attach(ctx: common.UIAbilityContext): void {
    LiveView.ctx = ctx;
    hilog.info(DOMAIN, TAG, 'LiveView 已绑定 UIAbilityContext');
  }

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

  /* ==================== 生成开始 / 结束 ==================== */

  /** 生成开始：创建实况窗 + 启动时间驱动的看门狗（+ 后台短时任务） */
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

    // 同一时刻只维护一个实况窗：上一次若仍活动（异常路径残留），先收干净
    if (LiveView.active) {
      await LiveView.stop();
    }

    const now: number = Date.now();
    LiveView.startedAt = now;
    LiveView.lastFetch = now;
    LiveView.kind = kind;
    // 进度模型以"实况窗创建时刻"为 0 点，时间滑轨与实况窗生命周期严格同源
    LiveView.progress = new GenProgress(kind, now);
    LiveView.title = title;
    LiveView.seq = 1;
    LiveView.lastPct = -1;
    LiveView.taskId = '';
    LiveView.estimated = false;
    // 业务侧自有的 activityId：服务端结束实况窗时原样回传（push-type 7）
    LiveView.id = nextActivityId();
    LiveView.active = false;

    const evts: string[] = LiveView.okEvent !== '' ? [LiveView.okEvent] : EVENTS;
    for (let i = 0; i < evts.length; i++) {
      const ok: boolean = await LiveView.tryStart(evts[i]);
      if (ok) {
        LiveView.okEvent = evts[i];
        LiveView.active = true;
        hilog.info(DOMAIN, TAG, '实况窗已创建 event=%{public}s activityId=%{public}d', evts[i], LiveView.id);
        // 注意：此处**不**上报服务端 —— 此时 taskId 还没生成。
        // 由 AiService 在拿到 taskId 后调用 LiveView.bindTask(taskId) 补绑。
        // 看门狗与写入/恢复无关，只依赖"实况窗是否 active"，故此处即可启动。
        LiveView.startWatchdog('start');
        return;
      }
    }
    hilog.warn(DOMAIN, TAG, '实况窗创建失败（所有 event 均被拒）');
  }

  /**
   * 把当前实况窗的 activityId 绑定到服务端任务（供 push-type 7 结束实况窗）。
   *
   * 调用时机：`LiveView.start()` 在"生成开始"时就创建了实况窗，但此时**还没有
   * taskId**（任务要稍后由 GenTask.submit 提交）。因此 activityId 先存在
   * LiveView 内部，等拿到 taskId 后由调用方（AiService.chatByTask）调用本方法补绑。
   *
   * 【本版增强 1】同时记录 taskId 到内部状态：后台看门狗据此拉取**服务端权威进度**
   *   （已生成长度 / 思考长度），让实况窗在后台显示的百分比贴近真实产出，
   *   而不只是客户端的时间外推。
   *
   * 【本版增强 2·跨端对齐】一并上报 totalChars / expectedMinutes。
   *   服务端现在会在生成**进行中**按节流（默认 10s/条、最多 30 条）补推进度
   *   （push-type 7 / operation 1），与客户端看门狗**交替写同一个实况窗**。
   *   它不掌握客户端的 EXPECT_CHARS 表，不告诉它就只能按时间线性兜底，
   *   于是两端百分比形状不同 → 每次服务端补推都把进度条拉回去（实测 5pp）。
   *   因此这里把 GenProgress 的公开契约值传过去，让两端用同一套基线。
   *
   * 失败只写日志：实况窗是增强体验，不能影响生成主流程。
   */
  static bindTask(taskId: string): void {
    if (!LiveView.active || LiveView.id <= 0 || taskId === '') {
      return;
    }
    LiveView.taskId = taskId;
    const event: string = LiveView.okEvent === '' ? EVENTS[0] : LiveView.okEvent;
    // 跨端进度契约：取值一律来自 GenProgress 的 public static（单一事实来源），
    // 绝不在本文件里再写一遍字面量，避免第三个副本继续漂移。
    const kind: string = LiveView.kind;
    LiveViewReport.bind(taskId, LiveView.id, event,
      GenProgress.expectedChars(kind), GenProgress.expectedMinutes(kind)).catch((e: Error) => {
      hilog.warn(DOMAIN, TAG, '绑定任务失败: %{public}s', e.message);
    });
  }

  /** 对外暴露当前 activityId（0 表示无活动实况窗） */
  static currentActivityId(): number {
    return LiveView.active ? LiveView.id : 0;
  }

  /** 尝试用某个 event 创建；成功返回 true */
  private static async tryStart(event: string): Promise<boolean> {
    const agent: WantAgent | null = await LiveView.getClickAgent();
    const lv: liveViewManager.LiveView = {
      // 使用业务侧自有的 activityId（非 0）——服务端靠它结束实况窗
      id: LiveView.id,
      event: event,
      sequence: 1,
      // 进程被系统终止时由系统结束实况窗，避免残留
      lifeCycleMode: liveViewManager.LifeCycleMode.AUTO_STOP_WHEN_APP_TERMINATE,
      liveViewData: {
        primary: buildPrimary(0, LiveView.title, agent, ''),
        capsule: buildCapsule(0)
      }
    };
    try {
      const r: liveViewManager.LiveViewResult = await liveViewManager.startLiveView(lv);
      // 成功判定：以 resultCode 为准（0 = 成功）。liveView id 是**我们传入的**，
      // 不由系统回传，故这里无需（也无法）从 r 里取 id。
      void r;
      return true;
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(DOMAIN, TAG, 'startLiveView event=%{public}s 失败 code=%{public}d %{public}s',
        event, err.code === undefined ? -1 : err.code, LiveView.msg(e));
      return false;
    }
  }

  /* ==================== 页面回调入口（前台主路径） ==================== */

  /** 思考阶段有进展 */
  static async onThinking(): Promise<void> {
    if (!LiveView.active || LiveView.progress === null) {
      return;
    }
    LiveView.progress.onThinking();
    LiveView.estimated = false;
    await LiveView.push();
  }

  /** 正文有进展（传入当前已生成正文） */
  static async onContent(content: string): Promise<void> {
    if (!LiveView.active || LiveView.progress === null) {
      return;
    }
    LiveView.progress.onContent(content);
    LiveView.estimated = false;
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
    LiveView.estimated = false;
    await LiveView.push();
  }

  /**
   * 把当前进度推送到实况窗（百分比无变化时跳过，降低调用频率）。
   *
   * @param estimated 本次百分比是否来自"时间外推"（后台无回调时）。
   *        仅影响展示文案（"约 N%"），不影响数值语义。
   */
  private static async push(estimated?: boolean): Promise<void> {
    if (LiveView.progress === null) {
      return;
    }
    const est: boolean = estimated === true;
    const pct: number = LiveView.progress.current();
    // 百分比没变就跳过（系统对实况窗更新频率有限制），
    // 但"估算→实测"的文案切换需要放行一次，避免后台一直显示"约"
    if (pct === LiveView.lastPct && est === LiveView.estimated) {
      return;
    }
    LiveView.lastPct = pct;
    LiveView.estimated = est;
    LiveView.seq++;
    const lv: liveViewManager.LiveView = {
      id: LiveView.id,
      event: LiveView.okEvent === '' ? EVENTS[0] : LiveView.okEvent,
      sequence: LiveView.seq,
      liveViewData: {
        primary: buildPrimary(pct, LiveView.title, LiveView.clickAgent, est ? '约 ' : ''),
        capsule: buildCapsule(pct)
      }
    };
    try {
      await liveViewManager.updateLiveView(lv);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'updateLiveView 失败 code=%{public}d', LiveView.code(e));
    }
  }

  /* ==================== 后台续更核心：看门狗 + 短时任务 ==================== */

  /**
   * 启动"与页面完全解耦"的进度看门狗。
   *
   * 为什么必须是独立定时器，而不是复用页面回调：
   *   页面回调只在进程被调度且 SSE/轮询在跑时才有事件；后台挂起后两者都停。
   *   看门狗不依赖任何页面/网络事件，只依赖 Date.now()，因此：
   *     · 前台：与页面回调并行，两者取 max，进度只增不减，不冲突；
   *     · 后台：它是唯一还在推进进度的东西（在有短时任务窗口时）。
   */
  private static startWatchdog(why: string): void {
    if (LiveView.tick !== -1) {
      return;
    }
    LiveView.tick = setInterval((): void => {
      LiveView.pump().catch((e: Error) => {
        hilog.warn(DOMAIN, TAG, 'pump 异常: %{public}s', LiveView.safeMsg(e));
      });
    }, TICK_MS);
    hilog.info(DOMAIN, TAG, '进度看门狗已启动（%{public}s，%{public}d ms/次）', why, TICK_MS);
  }

  /** 停止看门狗（结束实况窗时调用，避免定时器泄漏） */
  private static stopWatchdog(): void {
    if (LiveView.tick !== -1) {
      clearInterval(LiveView.tick);
      LiveView.tick = -1;
    }
  }

  /**
   * 看门狗单次心跳 —— **后台续更的真正执行体**。
   *
   * 每拍做三件事（全部容错，任何异常都不影响生成）：
   *   ① 按时间补齐百分比并更新实况窗（不依赖任何回调）；
   *   ② 有 taskId 时（节流）拉服务端权威任务态：用真实产出长度抬高进度，
   *      并在服务端已 done/failed 时**主动收尾**（覆盖客户端没收到回调的场景）；
   *   ③ 后台态下确保短时任务在手，额度将尽时续期。
   */
  private static async pump(): Promise<void> {
    if (!LiveView.active) {
      LiveView.stopWatchdog();
      return;
    }
    // 异常保护：超过运行上限（正常几分钟内必结束）则停表，避免定时器泄漏
    const elapsed: number = Date.now() - LiveView.startedAt;
    if (elapsed > MAX_TICK_MS) {
      hilog.warn(DOMAIN, TAG, '看门狗超时保护触发，停止推进（已运行 %{public}d ms）', elapsed);
      LiveView.stopWatchdog();
      return;
    }

    // ---- ③ 后台短时任务：续期（必须在 push 之前，尽量保证这一拍能发出去）----
    if (LiveView.bg) {
      LiveView.ensureSuspend();
    }

    // ---- ② 服务端权威进度 ----
    if (LiveView.taskId !== '' && !LiveView.fetchBusy
      && (Date.now() - LiveView.lastFetch) >= POLL_MS) {
      LiveView.lastFetch = Date.now();
      await LiveView.fetchAuthoritative();
    }

    // ---- ① 时间驱动的进度推进 ----
    // push 内部读的是 progress.current()，它 = max(阶段锚点, 时间滑轨)，
    // 因此即使进程刚被恢复调度、这段时间内没有任何回调，这里也会一次性补齐。
    const fromTime: boolean = LiveView.isTimeDriven();
    await LiveView.push(fromTime);

    if (LiveView.bg && LiveView.progress !== null) {
      hilog.debug(DOMAIN, TAG, '后台续更 第%{public}d拍 pct=%{public}d elapsed=%{public}dms',
        LiveView.seq, LiveView.progress.current(), elapsed);
    }
  }

  /**
   * 判断当前百分比是否由"时间滑轨"主导（而非回调锚点）。
   * 用于文案：后台纯外推时显示"约 N%"，更诚实。
   */
  private static isTimeDriven(): boolean {
    if (LiveView.progress === null) {
      return false;
    }
    return LiveView.bg;
  }

  /**
   * 拉取服务端任务的权威进度。
   *
   * 【为什么值得在后台做这件事】
   *   服务端 tasks.js 会持续保存已生成内容的长度与思考全文，即使客户端进程
   *   被挂起，服务端仍在推进。用它换算出的百分比比纯时间外推更接近真实，
   *   并且在服务端已 done/failed 时能**立刻收尾**（避免实况窗多挂一会儿）。
   *
   * 全部失败静默：网络不可用是常态（后台/锁屏省电），不能因此影响任何东西。
   */
  private static async fetchAuthoritative(): Promise<void> {
    const id: string = LiveView.taskId;
    if (id === '') {
      return;
    }
    LiveView.fetchBusy = true;
    try {
      const t: TaskProbe | null = await LiveView.probe(id);
      if (t === null || !LiveView.active) {
        return;
      }
      if (t.status === 'done') {
        hilog.info(DOMAIN, TAG, '后台探测到任务已完成，主动收尾实况窗 taskId=%{public}s', id);
        await LiveView.done();
        return;
      }
      if (t.status === 'failed') {
        hilog.info(DOMAIN, TAG, '后台探测到任务已失败，收尾实况窗 taskId=%{public}s', id);
        await LiveView.stop();
        return;
      }
      // running：用真实产出长度抬高进度锚点（只增不减，不会让进度回退）
      if (LiveView.progress === null) {
        return;
      }
      const rl: number = t.reasoning === undefined ? 0 : t.reasoning.length;
      if (rl > 0) {
        LiveView.progress.onThinking();
      }
      const cl: number = t.content === undefined ? 0 : t.content.length;
      if (cl > 0) {
        LiveView.progress.onLength(cl);
      }
    } catch (e) {
      // 静默：后台网络失败属常态
      hilog.debug(DOMAIN, TAG, '后台拉取任务态失败: %{public}s', LiveView.safeMsg(e));
    } finally {
      LiveView.fetchBusy = false;
    }
  }

  /**
   * 单次 GET /task/:id（带超时）。
   *
   * 这里刻意**不**复用 GenTask.fetchTask：后者固定 15s readTimeout，
   * 后台短时窗口里一个慢请求就可能吃掉整个额度。本方法把超时压到 4s，
   * 并直接返回所需的最小字段集（只读 status/content/reasoning）。
   *
   * 用的是 @ohos.net.http（与 GenTask 同款，复用同一份 base url / header 规则），
   * 而不是全局 fetch：应用内网络请求已统一走 http 模块，避免两套超时/代理语义。
   */
  private static async probe(id: string): Promise<TaskProbe | null> {
    const req = http.createHttp();
    try {
      const resp = await req.request(GenTask.apiUrl('/task/' + id), {
        method: http.RequestMethod.GET,
        header: GenTask.httpHeaders(),
        connectTimeout: FETCH_TIMEOUT_MS,
        readTimeout: FETCH_TIMEOUT_MS
      });
      const raw: string = typeof resp.result === 'string' ? resp.result : JSON.stringify(resp.result);
      const parsed = JSON.parse(raw) as TaskResp;
      return parsed.task === undefined ? null : parsed.task;
    } finally {
      req.destroy();
    }
  }

  /* ==================== 后台短时任务（transient task） ==================== */

  /**
   * 确保"短时任务"在手 —— 应用退到后台后系统仍给一小段运行时间，
   * 让看门狗能真的把实况窗进度推出去。
   *
   * 【SDK 依据】@ohos.resourceschedule.backgroundTaskManager.d.ts:553
   *   function requestSuspendDelay(reason: string, callback: Callback<void>): DelaySuspendInfo;
   *   · 声明处**没有** @permission 标注 ⇒ 无需任何权限，@since 9 公开 API；
   *     （对比 :570 startBackgroundRunning 明确要求 KEEP_BACKGROUND_RUNNING
   *       受限权限 —— 这也是本方案不采用长时任务的原因，详见文件顶部论证。）
   *   · 返回 DelaySuspendInfo{ requestId, actualDelayTime(ms) }；
   *   · 到期时回调通知 —— 此时应用即将被挂起。
   *
   * 【合规】不申请任何新权限、不注册长时任务、不产生常驻通知；
   *   requestSuspendDelay 有每日总配额，超额会抛 9900001/9900002，全部静默降级。
   */
  private static ensureSuspend(): void {
    const now: number = Date.now();
    if (LiveView.suspendId !== -1) {
      // 已在手：只在"剩余额度将尽"时续期（重新申请），避免无谓消耗配额
      const left: number = LiveView.suspendDeadline() - now;
      if (left > RENEW_BELOW_MS) {
        return;
      }
      // 从"即将到期"回调起 15s 内不重复申请，防止回调风暴打爆短时任务配额
      if (LiveView.lastExpireLog !== 0 && (now - LiveView.lastExpireLog) < 15000) {
        return;
      }
      hilog.info(DOMAIN, TAG, '短时任务剩余 %{public}d ms，申请续期', left);
      LiveView.cancelSuspend();
    }
    LiveView.requestSuspend('AI 生成进度实况窗更新');
  }

  /** 短时任务到期时刻（0 表示未持有或无期限信息） */
  private static suspendDeadline(): number {
    return LiveView.suspendLeft > 0 ? LiveView.suspendLeft : 0;
  }

  /**
   * 申请短时任务。失败（含配额耗尽 9900001/9900002）只写日志并静默降级 ——
   * 降级后的行为退化为"腿 1 时间滑轨"：重新被调度时补齐百分比。
   */
  private static requestSuspend(reason: string): void {
    try {
      const info: backgroundTaskManager.DelaySuspendInfo =
        backgroundTaskManager.requestSuspendDelay(reason, (): void => {
          // 系统通知：短时任务即将到期，应用马上要被挂起
          LiveView.lastExpireLog = Date.now();
          LiveView.suspendId = -1;
          LiveView.suspendLeft = 0;
          hilog.info(DOMAIN, TAG, '短时任务到期，应用即将被挂起（实况窗转为按时间补齐模式）');
        });
      LiveView.suspendId = info.requestId;
      LiveView.suspendLeft = Date.now() + (info.actualDelayTime > 0 ? info.actualDelayTime : 0);
      hilog.info(DOMAIN, TAG, '已申请后台短时任务 requestId=%{public}d actualDelayTime=%{public}dms',
        info.requestId, info.actualDelayTime);
    } catch (e) {
      const err = e as BusinessError;
      // 9900001/9900002 = 短时任务校验失败/配额不足：属预期内的降级路径，不是错误
      hilog.warn(DOMAIN, TAG, '申请后台短时任务失败 code=%{public}d %{public}s（静默降级为时间补齐）',
        err.code === undefined ? -1 : err.code, LiveView.msg(e));
      LiveView.suspendId = -1;
      LiveView.suspendLeft = 0;
    }
  }

  /** 取消短时任务（结束生成时） */
  private static cancelSuspend(): void {
    if (LiveView.suspendId === -1) {
      return;
    }
    try {
      backgroundTaskManager.cancelSuspendDelay(LiveView.suspendId);
      hilog.info(DOMAIN, TAG, '已取消后台短时任务 requestId=%{public}d', LiveView.suspendId);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, '取消短时任务失败: %{public}s', LiveView.safeMsg(e));
    }
    LiveView.suspendId = -1;
    LiveView.suspendLeft = 0;
  }

  /* ==================== 前后台接缝 ==================== */

  /**
   * 应用进入后台（EntryAbility.onBackground 调用）。
   *
   * 【关键语义】这一动作**只做"确保后台仍能推进"**，绝不结束实况窗 ——
   *   用户"退出到后台"正是实况窗要发挥作用的时刻。
   *   v1 里没有任何地方处理 onBackground（实况窗不会被结束，但也没有任何人
   *   继续驱动它 ⇒ 冻结）。本版把它变成"后台续更"的启动信号。
   */
  static onBackground(): void {
    LiveView.bg = true;
    if (!LiveView.active) {
      return;
    }
    hilog.info(DOMAIN, TAG, '进入后台：保持实况窗并启用后台续更');
    // 看门狗在 start() 时就已启动；这里兜底（覆盖异常路径下定时器丢失的情况）
    LiveView.startWatchdog('onBackground');
    // 争取后台运行窗口，让看门狗真的能跑几拍
    LiveView.ensureSuspend();
  }

  /**
   * 应用回到前台（EntryAbility.onForeground 调用）。
   *
   * 恢复页面级同步：立刻按已流逝时间补一次进度（把挂起期间"欠"的百分比补上），
   * 之后页面回调重新拿到主导权；看门狗继续保留，做两件事的取 max。
   */
  static onForeground(): void {
    const wasBg: boolean = LiveView.bg;
    LiveView.bg = false;
    if (!LiveView.active) {
      return;
    }
    if (wasBg) {
      hilog.info(DOMAIN, TAG, '回到前台：按已流逝时间补齐进度并恢复页面级同步');
    }
    // 回到前台后短时任务不再需要（前台本身就是"运行中"），及时释放额度给别的场景
    LiveView.cancelSuspend();
    // 立即补一次（不等下一个 2s 节拍），让用户切回来的瞬间看到正确百分比
    LiveView.push(false).catch((e: Error) => {
      hilog.warn(DOMAIN, TAG, '前台补齐失败: %{public}s', LiveView.safeMsg(e));
    });
  }

  /** 是否处于后台态（供诊断 / 测试） */
  static isBackground(): boolean {
    return LiveView.bg;
  }

  /** 看门狗是否在运行（供诊断 / 测试） */
  static isWatching(): boolean {
    return LiveView.tick !== -1;
  }

  /* ==================== 结束 ==================== */

  /** 生成结束：先置 100% 再结束 */
  static async done(): Promise<void> {
    if (!LiveView.active || LiveView.progress === null) {
      return;
    }
    LiveView.progress.onDone();
    LiveView.lastPct = -1;
    LiveView.estimated = false;
    await LiveView.push(false);
    await LiveView.stop();
  }

  /** 结束实况窗（同时收掉看门狗与后台短时任务） */
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
    LiveView.estimated = false;
    LiveView.taskId = '';
    // 收尾：定时器与后台任务都必须释放，否则会持续消耗电量/配额
    LiveView.stopWatchdog();
    LiveView.cancelSuspend();
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

  /** 与 msg 相同，但接收 Error（回调里捕获到的异常类型） */
  private static safeMsg(e: Object): string {
    try {
      return LiveView.msg(e);
    } catch (inner) {
      return 'unknown';
    }
  }
}
