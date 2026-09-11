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
  /** 最大轮询次数（约 15 分钟，覆盖长教案/课件等大输出） */
  static readonly POLL_MAX: number = 450;
  private static cachedDev: string = '';

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

  /* ==================== 任务接口 ==================== */

  /** 提交生成任务；返回 taskId（成功后写入本地 pending 记录） */
  static async submit(ctx: common.UIAbilityContext, type: string, label: string,
    system: string, user: string, attachments?: AttachFile[],
    thinking?: boolean): Promise<string> {
    const dev = await GenTask.deviceId(ctx);
    const body: TaskSubmitBody = {
      type: type,
      label: label,
      system: system,
      user: user,
      deviceId: dev
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
