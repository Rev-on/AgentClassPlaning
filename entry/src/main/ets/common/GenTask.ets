/**
 * 后台生成任务与通知服务
 *
 * 职责：
 *  1. 提交"生成任务"到服务端（提交后立即返回，即使本机进程被杀任务仍在服务器继续）；
 *  2. 提交成功后发布"生成中"本地通知（通知中心常驻，图标为应用图标）；
 *  3. 轮询/查询任务结果，完成后以"完成通知"覆盖"生成中"通知；
 *  4. 应用重启/回到前台时恢复未完成任务（recover）；
 *  5. 向服务端注册设备 Push Token（服务端推送完成通知）。
 *
 * 通知幂等策略：本地通知与服务端推送共用 notifySeed 作为 notifyId，
 * "完成通知"覆盖"生成中通知"，避免悬挂过期的"生成中"条目。
 */
import http from '@ohos.net.http';
import preferences from '@ohos.data.preferences';
import common from '@ohos.app.ability.common';
import { notificationManager } from '@kit.NotificationKit';
import { pushService } from '@kit.PushKit';
import { liveViewManager } from '@kit.LiveViewKit';
import { ApiConfig } from './ApiConfig';
import { HistoryStore } from './HistoryStore';
import { I18n } from './I18n';

/** 服务端任务信息（与 server/tasks.js 字段对应） */
interface ServerTaskInfo {
  id: string;
  status: string;
  content?: string;
  error?: string;
  type?: string;
  label?: string;
}

/** 本地"未完成任务"记录（进程被杀后据此恢复） */
interface PendingTask {
  seed: number;
  type: string;
  label: string;
  taskId: string;
  /** 运行中反馈是否为实况窗模式（recover 据此决定是否重建"生成中"普通通知） */
  lv?: boolean;
}

/** 提交任务响应 */
interface SubmitResp {
  ok?: boolean;
  taskId?: string;
  status?: string;
}

/** 提交任务请求体 */
interface TaskSubmitBody {
  type: string;
  label: string;
  system: string;
  user: string;
  deviceId: string;
  notifySeed: number;
  notifyTitle: string;
  notifyBody: string;
  notifyFailTitle: string;
  notifyFailBody: string;
}

/** Push Token 注册请求体 */
interface PushRegBody {
  deviceId: string;
  token: string;
}

/** 实况窗创建成功上报请求体 */
interface LiveReportBody {
  activityId: number;
  event: string;
}

/** 查询响应 */
interface GetResp {
  ok?: boolean;
  task?: ServerTaskInfo;
}

export class GenTask {
  private static readonly STORE: string = 'ai_lesson_store';
  private static readonly PKEY: string = 'ai_pending_task';
  private static readonly DKEY: string = 'ai_device_id';
  /** 轮询间隔（毫秒） */
  static readonly POLL_MS: number = 2000;
  /** 最大轮询次数（约 10 分钟） */
  static readonly POLL_MAX: number = 300;
  private static cachedDev: string = '';

  /** 生成通知/请求用 seed（正整数 < 2^31） */
  static nextSeed(): number {
    const base: number = Date.now() % 100000000;
    const rand: number = Math.floor(Math.random() * 900000);
    return 100000000 + base + rand;
  }

  /** 实况窗事件：进度类型（Live View Kit 新增合规场景：手动开启的任务进度提醒） */
  private static readonly LIVE_EVENT: string = 'PROGRESS';
  /** 运行中实况窗的伪进度上限（无精确进度，展示"进行中"感） */
  private static readonly LIVE_PROGRESS_MAX: number = 85;

  private static api(path: string): string {
    return ApiConfig.SERVER_BASE_URL + path;
  }

  private static headers(): Record<string, string> {
    const h: Record<string, string> = { 'Content-Type': 'application/json' };
    if (ApiConfig.PROXY_TOKEN !== '') {
      h['x-proxy-token'] = ApiConfig.PROXY_TOKEN;
    }
    return h;
  }

  private static async postJson(path: string, body: TaskSubmitBody | PushRegBody | LiveReportBody): Promise<string> {
    const req = http.createHttp();
    try {
      const resp = await req.request(GenTask.api(path), {
        method: http.RequestMethod.POST,
        header: GenTask.headers(),
        extraData: JSON.stringify(body),
        connectTimeout: 10000,
        readTimeout: 15000
      });
      return typeof resp.result === 'string' ? resp.result : JSON.stringify(resp.result);
    } finally {
      req.destroy();
    }
  }

  private static async getJson(path: string): Promise<string> {
    const req = http.createHttp();
    try {
      const resp = await req.request(GenTask.api(path), {
        method: http.RequestMethod.GET,
        header: GenTask.headers(),
        connectTimeout: 10000,
        readTimeout: 15000
      });
      return typeof resp.result === 'string' ? resp.result : JSON.stringify(resp.result);
    } finally {
      req.destroy();
    }
  }

  private static async prefs(ctx: common.UIAbilityContext): Promise<preferences.Preferences> {
    return await preferences.getPreferences(ctx, GenTask.STORE);
  }

  /** 设备标识（生成一次后持久化） */
  static async deviceId(ctx: common.UIAbilityContext): Promise<string> {
    if (GenTask.cachedDev !== '') {
      return GenTask.cachedDev;
    }
    try {
      const store = await GenTask.prefs(ctx);
      const v = await store.get(GenTask.DKEY, '');
      if (typeof v === 'string' && v !== '') {
        GenTask.cachedDev = v;
        return v;
      }
    } catch (e) {
      // ignore
    }
    const dev: string = 'd' + Date.now().toString(36) + Math.floor(Math.random() * 46656).toString(36);
    GenTask.cachedDev = dev;
    try {
      const store = await GenTask.prefs(ctx);
      await store.put(GenTask.DKEY, dev);
      await store.flush();
    } catch (e) {
      // ignore
    }
    return dev;
  }

  /* ==================== 通知 ==================== */

  private static tpl(key: string, type: string): string {
    return I18n.t(key).split('{type}').join(type);
  }

  /** 请求通知权限（应用启动时调用一次） */
  static async requestNotifyPermission(ctx: common.UIAbilityContext): Promise<void> {
    try {
      await notificationManager.requestEnableNotification(ctx);
    } catch (e) {
      // 用户拒绝或系统限制：静默
    }
  }

  private static async publishLocal(seed: number, title: string, text: string, ongoing: boolean = false): Promise<void> {
    const request: notificationManager.NotificationRequest = {
      id: seed,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: title,
          text: text
        }
      },
      // 常驻(ONGOING)：支持的系统上"生成中"通知不可被用户手动清除；
      // 官方当前将 isOngoing 标注为预留能力，不支持时静默忽略（另有轮询心跳兜底重建）
      isOngoing: ongoing
    };
    try {
      await notificationManager.publish(request);
    } catch (e) {
      // 通知发布失败不阻塞业务
    }
  }

  /**
   * 发布"生成中"反馈：优先创建实况窗（PROGRESS 进度类型，应用图标），
   * 实况窗不可用时回退为"生成中"普通通知。
   * @returns true=实况窗已创建；false=已回退为普通通知
   */
  static async publishRunning(ctx: common.UIAbilityContext, seed: number, type: string): Promise<boolean> {
    const title: string = GenTask.tpl('notify.runningTitle', type);
    const text: string = GenTask.tpl('notify.runningText', type);
    try {
      if (await liveViewManager.isLiveViewEnabled()) {
        await liveViewManager.startLiveView(GenTask.buildLive(seed, type, 1, title, text, 10));
        return true;
      }
    } catch (e) {
      // 权益未申请/开关未开/非前台等：回退普通通知
    }
    void ctx;
    // 回退为"生成中"普通通知：标记常驻（支持的系统上不可手动清除），删除后由轮询心跳即时重建
    await GenTask.publishLocal(seed, title, text, true);
    return false;
  }

  /** 心跳重建"生成中"普通通知（非实况窗模式）：若被用户/系统清除，立即以相同 seed 恢复，达到常驻效果 */
  static async refreshRunning(seed: number, type: string): Promise<void> {
    const title: string = GenTask.tpl('notify.runningTitle', type);
    const text: string = GenTask.tpl('notify.runningText', type);
    await GenTask.publishLocal(seed, title, text, true);
  }

  /** 更新实况窗进度（仅当实况窗模式） */
  static async updateProgress(seed: number, type: string, sequence: number, progress: number): Promise<void> {
    const title: string = GenTask.tpl('notify.runningTitle', type);
    const text: string = GenTask.tpl('notify.runningText', type);
    try {
      await liveViewManager.updateLiveView(GenTask.buildLive(seed, type, sequence, title, text, progress));
    } catch (e) {
      // 更新失败忽略（可能已被系统清理或已结束）
    }
  }

  /** 本地结束实况窗（页面/恢复逻辑感知完成时调用；未创建时静默） */
  static async stopLiveLocal(seed: number, type: string): Promise<void> {
    try {
      await liveViewManager.stopLiveView(GenTask.buildLive(seed, type, 999, '', '', 100));
    } catch (e) {
      // ignore
    }
  }

  /** 上报实况窗已创建（任务完成后服务端据此推送结束消息，杀进程也能清理） */
  static async reportLive(taskId: string, seed: number): Promise<void> {
    try {
      await GenTask.postJson('/task/' + taskId + '/liveview', {
        activityId: seed,
        event: GenTask.LIVE_EVENT
      });
    } catch (e) {
      // 上报失败不影响主流程
    }
  }

  /** 构造 PROGRESS 进度实况窗实例 */
  private static buildLive(seed: number, type: string, sequence: number,
    title: string, text: string, progress: number): liveViewManager.LiveView {
    const barColor: string = '#FF5BA8A0';
    return {
      id: seed,
      event: GenTask.LIVE_EVENT,
      sequence: sequence,
      isMute: true,
      liveViewData: {
        primary: {
          title: title,
          content: [{ text: text }],
          keepTime: 0,
          layoutData: {
            layoutType: liveViewManager.LayoutType.LAYOUT_TYPE_PROGRESS,
            progress: Math.min(Math.max(progress, 0), GenTask.LIVE_PROGRESS_MAX),
            color: barColor,
            backgroundColor: '#26000000'
          }
        },
        capsule: {
          type: liveViewManager.CapsuleType.CAPSULE_TYPE_TEXT,
          status: 1,
          title: title,
          content: text,
          backgroundColor: '#FF5BA8A0'
        }
      }
    };
  }

  /** 发布"完成/失败"通知（同 seed 覆盖"生成中"） */
  static async publishResult(seed: number, type: string, done: boolean): Promise<void> {
    if (done) {
      await GenTask.publishLocal(seed, GenTask.tpl('notify.doneTitle', type), GenTask.tpl('notify.doneBody', type));
    } else {
      await GenTask.publishLocal(seed, GenTask.tpl('notify.failTitle', type), GenTask.tpl('notify.failBody', type));
    }
  }

  /** 移除指定通知 */
  static async cancelNotify(seed: number): Promise<void> {
    try {
      await notificationManager.cancel(seed);
    } catch (e) {
      // ignore
    }
  }

  /* ==================== Push Token 注册 ==================== */

  /** 获取 Push Token 并上报服务端（失败静默，不影响其它功能） */
  static async registerPush(ctx: common.UIAbilityContext): Promise<void> {
    try {
      const token: string = await pushService.getToken();
      if (token === '') {
        return;
      }
      const dev = await GenTask.deviceId(ctx);
      await GenTask.postJson('/push/register', { deviceId: dev, token: token });
    } catch (e) {
      // 未登录华为账号 / 无推送环境：静默跳过
    }
  }

  /* ==================== 任务接口 ==================== */

  /** 提交生成任务；返回 taskId（成功后写入本地 pending 记录）。seed 由调用方生成 */
  static async submit(ctx: common.UIAbilityContext, type: string, label: string,
    system: string, user: string, seed: number): Promise<string> {
    const dev = await GenTask.deviceId(ctx);
    const raw: string = await GenTask.postJson('/task', {
      type: type,
      label: label,
      system: system,
      user: user,
      deviceId: dev,
      notifySeed: seed,
      notifyTitle: GenTask.tpl('notify.doneTitle', label),
      notifyBody: GenTask.tpl('notify.doneBody', label),
      notifyFailTitle: GenTask.tpl('notify.failTitle', label),
      notifyFailBody: GenTask.tpl('notify.failBody', label)
    });
    const resp = JSON.parse(raw) as SubmitResp;
    if (resp.taskId === undefined || resp.taskId === '') {
      throw new Error('任务提交失败，请稍后重试');
    }
    const pending: PendingTask = { seed: seed, type: type, label: label, taskId: resp.taskId };
    await GenTask.savePending(ctx, pending);
    return resp.taskId;
  }

  /** 查询任务 */
  static async fetchTask(taskId: string): Promise<ServerTaskInfo | null> {
    const raw: string = await GenTask.getJson('/task/' + taskId);
    const resp = JSON.parse(raw) as GetResp;
    return resp.task !== undefined ? resp.task : null;
  }

  /* ==================== pending 记录 ==================== */

  private static async savePending(ctx: common.UIAbilityContext, p: PendingTask): Promise<void> {
    try {
      const store = await GenTask.prefs(ctx);
      await store.put(GenTask.PKEY, JSON.stringify(p));
      await store.flush();
    } catch (e) {
      // ignore
    }
  }

  /** 记录运行中反馈是否为实况窗模式（recover 据此判断是否需要重建"生成中"普通通知） */
  static async markRunningMode(ctx: common.UIAbilityContext, lv: boolean): Promise<void> {
    try {
      const p = await GenTask.loadPending(ctx);
      if (p === null) {
        return;
      }
      p.lv = lv;
      await GenTask.savePending(ctx, p);
    } catch (e) {
      // ignore
    }
  }

  private static async loadPending(ctx: common.UIAbilityContext): Promise<PendingTask | null> {
    try {
      const store = await GenTask.prefs(ctx);
      const v = await store.get(GenTask.PKEY, '');
      if (typeof v !== 'string' || v === '') {
        return null;
      }
      return JSON.parse(v) as PendingTask;
    } catch (e) {
      return null;
    }
  }

  static async clearPending(ctx: common.UIAbilityContext): Promise<void> {
    try {
      const store = await GenTask.prefs(ctx);
      await store.put(GenTask.PKEY, '');
      await store.flush();
    } catch (e) {
      // ignore
    }
  }

  /**
   * 恢复未完成任务（应用冷/热启动回到主界面时调用）：
   * done -> 保存历史 + 结束实况窗 + 本地完成通知；failed -> 失败通知；running -> 保持实况窗/通知不变
   */
  static async recover(ctx: common.UIAbilityContext): Promise<void> {
    const p = await GenTask.loadPending(ctx);
    if (p === null) {
      return;
    }
    let task: ServerTaskInfo | null = null;
    try {
      task = await GenTask.fetchTask(p.taskId);
    } catch (e) {
      return; // 网络异常：保留 pending，下次再恢复
    }
    if (task === null) {
      // 服务端已无此任务（超 24h 清理等）：清理本地并移除通知/实况窗
      await GenTask.stopLiveLocal(p.seed, p.label);
      await GenTask.cancelNotify(p.seed);
      await GenTask.clearPending(ctx);
      return;
    }
    if (task.status === 'done') {
      await GenTask.stopLiveLocal(p.seed, p.label);
      await GenTask.publishResult(p.seed, p.label, true);
      const content: string = task.content !== undefined ? task.content : '';
      if (content !== '') {
        await HistoryStore.autoAdd(ctx, {
          type: p.label,
          title: p.label,
          content: content,
          time: HistoryStore.formatNow()
        });
      }
      await GenTask.clearPending(ctx);
    } else if (task.status === 'failed') {
      await GenTask.stopLiveLocal(p.seed, p.label);
      await GenTask.publishResult(p.seed, p.label, false);
      await GenTask.clearPending(ctx);
    } else if (p.lv !== true) {
      // running + 普通通知模式：进程重启后系统可能已清理该通知（用户也可能误删），
      // 重建"生成中"常驻通知，避免任务状态从通知栏消失而被误判为生成失败
      await GenTask.publishRunning(ctx, p.seed, p.label);
    }
    // running + 实况窗模式：实况窗跨进程保留，服务端完成时会结束实况窗并下发完成通知，无需重建；继续保持 pending
  }
}
