/**
 * 后台生成任务服务（已取消消息通知功能）
 *
 * 职责：
 *  1. 提交"生成任务"到服务端（提交后立即返回，即使本机进程被杀任务仍在服务器继续）；
 *  2. 轮询/查询任务结果（应用内通过 GenSession 展示"生成中/结果"，不发布任何系统通知）；
 *  3. 应用重启/回到前台时恢复未完成任务（recover：完成静默入历史，失败清理）。
 */
import http from '@ohos.net.http';
import preferences from '@ohos.data.preferences';
import common from '@ohos.app.ability.common';
import { ApiConfig } from './ApiConfig';
import { HistoryStore } from './HistoryStore';
import { AttachFile, TaskAttachment } from './AttachTypes';
import { AttachService } from './AttachService';
import { PushToken } from './PushToken';
import { I18n } from './I18n';

/** 服务端任务信息（与 server/tasks.js 字段对应） */
interface ServerTaskInfo {
  id: string;
  status: string;
  content?: string;
  /** 深度思考过程（思考模式下由服务端保存，供重连/轮询补齐展示） */
  reasoning?: string;
  error?: string;
  type?: string;
  label?: string;
}

/** 本地"未完成任务"记录（进程被杀后据此恢复） */
interface PendingTask {
  type: string;
  label: string;
  taskId: string;
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
  /** 深度思考：true 时服务端启用思考模式（thinking.type=enabled）并回传思考过程 */
  thinking?: boolean;
  /** 附件（图片/文档/拍照）：服务端据此构造多模态消息 */
  attachments?: TaskAttachment[];
  /**
   * 完成通知的 notifyId：同一功能复用同一个 id，华为侧新通知会**覆盖**旧通知，
   * 避免同一功能反复生成时通知栏堆积。
   */
  notifySeed?: number;
  /** 完成通知标题/正文（客户端已按当前语言本地化，服务端仅透传） */
  notifyTitle?: string;
  notifyBody?: string;
  /** 失败通知标题/正文 */
  notifyFailTitle?: string;
  notifyFailBody?: string;
}

/** 查询响应 */
interface GetResp {
  ok?: boolean;
  task?: ServerTaskInfo;
}

/** 一次生成任务的通知文案（完成 + 失败两组） */
interface NotifyTexts {
  title: string;
  body: string;
  failTitle: string;
  failBody: string;
}

export class GenTask {
  private static readonly STORE: string = 'ai_lesson_store';
  private static readonly PKEY: string = 'ai_pending_task';
  private static readonly DKEY: string = 'ai_device_id';
  /** 轮询间隔（毫秒） */
  static readonly POLL_MS: number = 2000;
  /** 最大轮询次数（约 15 分钟，覆盖长教案/课件等大输出） */
  static readonly POLL_MAX: number = 450;
  private static cachedDev: string = '';

  private static api(path: string): string {
    return GenTask.apiUrl(path);
  }

  /**
   * 服务端接口绝对地址。
   *
   * 对外开放的原因：实况窗后台续更（LiveView.pump）需要在**后台短时窗口**里
   * 用极短超时拉一次任务态，而 GenTask.fetchTask 固定 15s readTimeout ——
   * 一个慢请求就会吃掉整个短时额度。因此 LiveView 自建轻量请求，但复用
   * 同一份 base url / header 规则，避免两处硬编码漂移。
   */
  static apiUrl(path: string): string {
    return ApiConfig.SERVER_BASE_URL + path;
  }

  private static headers(): Record<string, string> {
    return GenTask.httpHeaders();
  }

  /** 统一的请求头（含代理 token）；同样供 LiveView 后台探测复用 */
  static httpHeaders(): Record<string, string> {
    const h: Record<string, string> = { 'Content-Type': 'application/json' };
    if (ApiConfig.PROXY_TOKEN !== '') {
      h['x-proxy-token'] = ApiConfig.PROXY_TOKEN;
    }
    return h;
  }

  private static async postJson(path: string, body: TaskSubmitBody): Promise<string> {
    const req = http.createHttp();
    try {
      const resp = await req.request(GenTask.api(path), {
        method: http.RequestMethod.POST,
        header: GenTask.headers(),
        extraData: JSON.stringify(body),
        connectTimeout: 15000,
        // 带图片附件时请求体可达数 MB，上传超时放宽到 60s
        readTimeout: 60000
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

  /**
   * 设备标识 —— **必须与 PushToken 上报的 deviceId 完全一致**。
   *
   * 【为什么】（这是"通知收不到"的真正根因，已实测确认）
   *   服务端推送时的查找逻辑是 `tokenOf(task.deviceId)`：
   *   用**任务的 deviceId** 去设备表里找推送 token。
   *   若两者不是同一个值，就永远查不到 → 推送要么走广播、要么推给失效 token，
   *   表现为"服务端日志显示已完成通知已发送（华为已受理），但手机收不到"。
   *
   *   历史 bug：本方法原先生成 `'d'+Date.now().toString(36)+随机数`（12 位短 ID），
   *   而 PushToken 用 deviceInfo.ODID（36 位 UUID），两者从不相等。
   *   实测数据：任务 deviceId 36 个、设备表 id 15 个，**交集仅 4 个**。
   *
   * 【修法】直接复用 PushToken.deviceId()，保证两端同源。
   *   本地持久化保留：一旦确定就不再变，避免任务与设备记录再次错位。
   *   注意：老用户本地可能残留旧的短 ID，需**忽略它**并迁移到新值，
   *   否则老设备永远对不上（服务端设备表里已是 UUID）。
   */
  static async deviceId(ctx: common.UIAbilityContext): Promise<string> {
    if (GenTask.cachedDev !== '') {
      return GenTask.cachedDev;
    }
    // 权威来源：与推送 token 上报时用的是同一个值
    const dev: string = PushToken.deviceId();
    GenTask.cachedDev = dev;
    try {
      const store = await GenTask.prefs(ctx);
      // 覆盖旧值（老版本写入的是短 ID，必须迁移掉）
      await store.put(GenTask.DKEY, dev);
      await store.flush();
    } catch (e) {
      // ignore
    }
    return dev;
  }

  /* ==================== 任务接口 ==================== */

  /**
   * 各生成功能的通知 ID（固定值，保证同一功能的新通知覆盖旧通知）。
   *
   * 为什么用固定值而不是时间戳/随机数：
   *   华为推送按 notifyId 归并通知。若每次生成都用新 id，用户连生成 3 次教案
   *   就会在通知栏留下 3 条"教案已生成完成"，观感差且难以清理。
   *   固定 id 让同一功能始终只占一条通知位。
   *
   * 取值避开 0（0 表示不归并）与实况窗占用的区间，从 7101 起按功能顺序编号。
   */
  private static readonly NOTIFY_IDS: Record<string, number> = {
    'plan': 7101,
    'courseware': 7102,
    'quiz': 7103,
    'research': 7104,
    'analysis': 7105,
    'talk': 7106,
    'report': 7107
  };
  /** 未知功能的兜底通知 ID（保证仍有通知可覆盖，不与 7 个已知功能冲突） */
  private static readonly NOTIFY_ID_FALLBACK: number = 7199;

  /** 取某功能的通知 ID；未知功能返回兜底值 */
  static notifyIdFor(type: string): number {
    const id: number | undefined = GenTask.NOTIFY_IDS[type];
    return id === undefined ? GenTask.NOTIFY_ID_FALLBACK : id;
  }

  /**
   * 组装完成/失败通知文案（按当前界面语言）。
   *
   * 注意：I18n.t 不做占位符替换（见 I18n.ets 的 t 实现），因此正文按
   * "前缀 + 功能名 + 后缀"三段拼接，而不是在词典里写 {name}。
   * 功能名直接用页面的 label（已是当前语言的标题，如"教案生成"）。
   */
  private static notifyTexts(label: string): NotifyTexts {
    const name: string = label !== '' ? label : I18n.t('card.history');
    return {
      title: I18n.t('notify.done.title'),
      body: I18n.t('notify.done.body.a') + name + I18n.t('notify.done.body.b'),
      failTitle: I18n.t('notify.fail.title'),
      failBody: I18n.t('notify.fail.body.a') + name + I18n.t('notify.fail.body.b')
    };
  }

  /** 提交生成任务；返回 taskId（成功后写入本地 pending 记录） */
  static async submit(ctx: common.UIAbilityContext, type: string, label: string,
    system: string, user: string, attachments?: AttachFile[],
    thinking?: boolean): Promise<string> {
    const dev = await GenTask.deviceId(ctx);
    const texts: NotifyTexts = GenTask.notifyTexts(label);
    const body: TaskSubmitBody = {
      type: type,
      label: label,
      system: system,
      user: user,
      deviceId: dev,
      // 完成通知：服务端在 PUSH_ENABLED=1 且 AGC 凭据齐备时下发
      notifySeed: GenTask.notifyIdFor(type),
      notifyTitle: texts.title,
      notifyBody: texts.body,
      notifyFailTitle: texts.failTitle,
      notifyFailBody: texts.failBody
    };
    if (thinking === true) {
      body.thinking = true;
    }
    if (attachments !== undefined && attachments.length > 0) {
      body.attachments = AttachService.toTask(attachments);
    }
    const raw: string = await GenTask.postJson('/task', body);
    const resp = JSON.parse(raw) as SubmitResp;
    if (resp.taskId === undefined || resp.taskId === '') {
      throw new Error(I18n.t('err.submitFail'));
    }
    const pending: PendingTask = { type: type, label: label, taskId: resp.taskId };
    await GenTask.savePending(ctx, pending);
    return resp.taskId;
  }

  /** 查询任务 */
  static async fetchTask(taskId: string): Promise<ServerTaskInfo | null> {
    const raw: string = await GenTask.getJson('/task/' + taskId);
    const resp = JSON.parse(raw) as GetResp;
    return resp.task !== undefined ? resp.task : null;
  }

  /** 取消服务端任务（"停止生成"）：上游随即断开，不再继续产生内容；不阻塞调用方 */
  static cancel(taskId: string): void {
    if (taskId === '') {
      return;
    }
    const req = http.createHttp();
    req.request(GenTask.api('/task/' + taskId + '/cancel'), {
      method: http.RequestMethod.POST,
      header: GenTask.headers(),
      extraData: '{}',
      connectTimeout: 8000,
      readTimeout: 8000
    }).then(() => {
      req.destroy();
    }).catch(() => {
      req.destroy();
    });
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
   * 恢复未完成任务（应用冷/热启动回到主界面时调用，不产生任何系统通知）：
   * done -> 结果静默写入历史；failed -> 清理；running -> 保持 pending，下次继续恢复
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
      // 服务端已无此任务（超 24h 清理等）：清理本地记录
      await GenTask.clearPending(ctx);
      return;
    }
    if (task.status === 'done') {
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
      await GenTask.clearPending(ctx);
    }
    // running：不打扰用户，保留 pending 供下次启动继续恢复
  }
}
