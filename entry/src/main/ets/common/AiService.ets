/**
 * AI 服务：封装 DeepSeek 对话补全接口（非流式，稳定性优先）
 *  - thinking 已禁用（快速模式），stream 固定 false
 *  - 偶发失败自动重试（最多 3 次），HTTP 200 但响应异常给出明确提示
 * @param onDelta 保留参数以兼容调用方，当前固定非流式不使用
 */
import http from '@ohos.net.http';
import common from '@ohos.app.ability.common';
import { ApiConfig } from './ApiConfig';
import { GenTask } from './GenTask';
import { HistoryStore } from './HistoryStore';
import { ResultBus } from './ResultBus';
import { GenSession } from './GenSession';
import { SseClient, SseEvent, SseListener } from './SseClient';
import { AttachFile, TaskAttachment } from './AttachTypes';
import { AttachService } from './AttachService';
import { RichHtml } from './RichHtml';

/** 对话消息 */
interface ChatMessage {
  role: string;
  content: string;
}

/** 任务模式参数（启用后生成走服务端后台任务，支持进程被杀后仍完成） */
export interface AiTaskOpts {
  ctx: common.UIAbilityContext;
  /** 功能类型标识（plan/quiz/...），服务端记录用 */
  type: string;
  /** 本地化类型名（用于通知文案，如"教案"） */
  label: string;
  /** 页面是否已销毁/离开（true 后不再回调 UI，结果转为静默保存+通知） */
  gone?: () => boolean;
  /** 本次生成携带的附件（图片/文档/拍照），服务端按多模态处理 */
  attachments?: AttachFile[];
}

/** 思考模式配置：type=disabled 关闭思维链（快速模式） */
interface ThinkingConfig {
  type: string;
}

/** 请求体结构 */
interface ChatRequest {
  model: string;
  messages: ChatMessage[];
  temperature: number;
  max_tokens: number;
  stream: boolean;
  thinking: ThinkingConfig;
  /** 附件（图片/文档），服务端据此构造多模态消息 */
  attachments?: TaskAttachment[];
}

/** 响应中的单条选择 */
interface ChatChoice {
  message: ChatMessage;
  finish_reason?: string;
}

/** 错误信息 */
interface ApiError {
  message?: string;
}

/** 响应体结构 */
interface ChatResponse {
  choices?: ChatChoice[];
  error?: ApiError;
}

/** 任务模式控制信息：记录任务是否已被服务端接受（提交成功） */
interface TaskCtl {
  accepted: boolean;
}

/** 正在进行的生成（按页面 key，如 plan/talk）：用于"停止生成" */
interface ActiveGen {
  taskId: string;
  sse: SseClient | null;
  stopped: boolean;
}

/** 任务 feed 订阅结果 */
interface FeedResult {
  final: boolean;
  content: string;
}

export class AiService {
  /** 最大尝试次数（首次 + 2 次重试） */
  private static readonly MAX_ATTEMPTS: number = 3;
  /** 正在进行的生成任务（key = 页面类型），供"停止生成"使用 */
  private static active: Map<string, ActiveGen> = new Map();

  /**
   * 立即停止某页面正在进行的生成：
   *  - 关闭本地 SSE 订阅 + 通知服务端取消任务（上游连接随即断开，不再产生 token 消耗）
   *  - 已生成的部分文本由页面保留；不写历史、不写会话
   */
  static stop(key: string): void {
    const a: ActiveGen | undefined = AiService.active.get(key);
    if (a === undefined) {
      return;
    }
    a.stopped = true;
    if (a.sse !== null) {
      try {
        a.sse.close();
      } catch (e) {
        // ignore
      }
    }
    if (a.taskId !== '') {
      GenTask.cancel(a.taskId);
    }
  }

  /** 指定 key 的生成是否已被请求停止 */
  static isStopped(key: string): boolean {
    const a: ActiveGen | undefined = AiService.active.get(key);
    return a !== undefined && a.stopped;
  }

  /** 消费停止标记并清理注册（生成流程结束时调用） */
  private static consumeStop(key: string): boolean {
    const a: ActiveGen | undefined = AiService.active.get(key);
    if (a === undefined) {
      return false;
    }
    const was: boolean = a.stopped;
    AiService.active.delete(key);
    return was;
  }

  /**
   * 调用 DeepSeek，返回完整回复文本（非流式）
   * @param systemPrompt 系统提示词（角色与输出规范）
   * @param userPrompt 用户输入内容
   * @param onDelta 结果文本回调（任务模式在完成后回调一次；兼容历史流式调用）
   * @param skipNote 为 true 时不追加"AI生成"尾注（如课件大纲 JSON 结构化输出）
   * @param opts 任务模式参数；传入 ctx 后自动使用"服务端后台任务"模式
   *             （提交即返回、可离开页面/杀进程，完成后通知并可在历史中查看）
   */
  static async chat(systemPrompt: string, userPrompt: string, onDelta?: (partial: string) => void,
    skipNote: boolean = false, opts?: AiTaskOpts): Promise<string> {
    // 2in1 上下分屏（appDuo）：本次生成镜像发布到下半屏结果面板（busy=生成中）
    const duoBus: boolean = AiService.duoActive(opts);
    if (duoBus && opts !== undefined) {
      ResultBus.live(opts.type, opts.label, opts.label, '');
    }
    // 生成会话入栈：生成进度与页面生命周期解耦（左滑退出/上滑回桌面不打断，重进页面可恢复）
    const sessKey = (): string => {
      return opts !== undefined && opts.type !== '' ? opts.type : '';
    };
    const sessEnd = (text: string): void => {
      const k: string = sessKey();
      if (k !== '') {
        GenSession.end(k, text);
      }
    };
    const sessClear = (): void => {
      const k: string = sessKey();
      if (k !== '') {
        GenSession.clear(k);
      }
    };
    const sessKeyValue: string = sessKey();
    if (sessKeyValue !== '') {
      GenSession.begin(sessKeyValue);
    }
    try {
      if (opts !== undefined && opts.ctx !== undefined) {
        // 任务已提交成功的标志：一旦服务端接受任务，后续任务态失败/超时不再回退直连重发
        // （否则会把同一篇内容再完整生成一遍，等待时间成倍叠加且可能双份计费/双份通知）
        const ctl: TaskCtl = { accepted: false };
        // 提交前先登记活动项：确保"提交瞬间点停止"也能生效（此时 taskId 尚为空）
        AiService.active.set(opts.type, { taskId: '', sse: null, stopped: false });
        try {
          const byTask: string = await AiService.chatByTask(systemPrompt, userPrompt, skipNote, onDelta, opts, ctl);
          if (AiService.consumeStop(opts.type)) {
            // 用户主动停止：半截文本已由页面保留；不写会话、不镜像、不入历史
            return byTask;
          }
          AiService.mirrorDone(duoBus, opts, byTask);
          sessEnd(byTask);
          return byTask;
        } catch (e) {
          if (AiService.consumeStop(opts.type)) {
            // 停止导致的异常：静默结束（避免弹出"生成失败"）
            return '';
          }
          if (ctl.accepted) {
            // 服务端已接受任务：结果由轮询/通知/recover 兜底，直接上报任务结果，避免重复生成
            if (e instanceof Error) {
              throw e;
            }
            throw new Error('AI 生成失败，请稍后重试');
          }
          // 提交阶段失败（旧版服务端/网络不通等）：回退到传统同步请求，保证可用
        }
      }
      let lastErr: Error = new Error('AI 请求失败，请稍后重试');
      for (let attempt: number = 0; attempt < AiService.MAX_ATTEMPTS; attempt++) {
        try {
          const raw: string = await AiService.requestOnce(systemPrompt, userPrompt,
            opts !== undefined ? opts.attachments : undefined);
          const out: string = AiService.withAiNote(raw, skipNote);
          if (opts !== undefined) {
            AiService.mirrorDone(duoBus, opts, out);
          }
          sessEnd(out);
          return out;
        } catch (e) {
          lastErr = e instanceof Error ? e : new Error('AI 请求失败，请稍后重试');
        }
      }
      throw lastErr;
    } catch (e) {
      sessClear();
      if (duoBus) {
        // 生成失败：下屏结果面板复位为空态，避免停留在"生成中"
        ResultBus.clear();
      }
      if (e instanceof Error) {
        throw e;
      }
      throw new Error('AI 请求失败，请稍后重试');
    }
  }

  /** 是否处于 2in1 上下分屏形态（此时需把结果镜像发布到下半屏面板） */
  private static duoActive(opts: AiTaskOpts | undefined): boolean {
    if (opts === undefined || opts.ctx === undefined) {
      return false;
    }
    return AppStorage.get<boolean>('appDuo') === true;
  }

  /** 生成完成：把与手机/平板完全一致的结果内容发布到下屏结果面板（空内容按失败复位） */
  private static mirrorDone(duo: boolean, opts: AiTaskOpts, content: string): void {
    if (!duo) {
      return;
    }
    if (content === '') {
      ResultBus.clear();
      return;
    }
    ResultBus.done(opts.type, opts.label, opts.label, content);
  }

  /**
   * 后台任务模式：提交到服务端任务队列 -> 优先订阅 SSE feed 边生成边回调 -> 兜底轮询。
   * 页面销毁后（gone()=true）不订阅 feed，改为轮询静默入库；进程被杀则下次启动由 recover 静默接管。
   */
  private static async chatByTask(systemPrompt: string, userPrompt: string, skipNote: boolean,
    onDelta: ((partial: string) => void) | undefined, opts: AiTaskOpts, ctl: TaskCtl): Promise<string> {
    const taskId: string = await GenTask.submit(opts.ctx, opts.type, opts.label, systemPrompt, userPrompt,
      opts.attachments);
    // 提交成功：服务端已接受任务并开始生成，此后任何任务态失败都不应回退直连重发
    ctl.accepted = true;
    // 登记到活动表：页面点"停止生成"时据此断开流并取消服务端任务
    const existing: ActiveGen | undefined = AiService.active.get(opts.type);
    const act: ActiveGen = existing !== undefined ? existing : { taskId: taskId, sse: null, stopped: false };
    act.taskId = taskId;
    AiService.active.set(opts.type, act);
    if (act.stopped) {
      // 提交完成前用户已点停止：立即取消刚创建的任务
      GenTask.cancel(taskId);
      await GenTask.clearPending(opts.ctx);
      return '';
    }
    let goneFlag: boolean = opts.gone !== undefined ? opts.gone() : false;
    // ---- 流式阶段：页面存活且需要增量展示时才订阅 feed；失败/断开自动退回轮询 ----
    if (!goneFlag && onDelta !== undefined) {
      const feed = await AiService.feedOnce(taskId, onDelta,
        (): boolean => act.stopped,
        (c: SseClient): void => { act.sse = c; });
      if (act.stopped) {
        // 用户已停止：结束任务、清 pending，半截文本由页面保留
        await GenTask.clearPending(opts.ctx);
        return '';
      }
      if (feed.final) {
        await GenTask.clearPending(opts.ctx);
        const left: boolean = opts.gone !== undefined ? opts.gone() : false;
        if (left && feed.content !== '') {
          // 页面在流式过程中离开：结果静默入库，避免丢失
          await HistoryStore.autoAdd(opts.ctx, {
            type: opts.label,
            title: opts.label,
            content: feed.content,
            time: HistoryStore.formatNow()
          });
        }
        return AiService.withAiNote(feed.content, skipNote);
      }
      goneFlag = opts.gone !== undefined ? opts.gone() : false;
    }
    const sleep = (ms: number): Promise<void> => new Promise<void>((resolve) => setTimeout(resolve, ms));
    for (let i: number = 0; i < GenTask.POLL_MAX; i++) {
      if (act.stopped) {
        // 轮询期间用户点了"停止生成"
        await GenTask.clearPending(opts.ctx);
        return '';
      }
      await sleep(GenTask.POLL_MS);
      goneFlag = opts.gone !== undefined ? opts.gone() : false;
      let content: string = '';
      let status: string = '';
      try {
        const t = await GenTask.fetchTask(taskId);
        if (t === null) {
          continue;
        }
        status = t.status;
        content = t.content !== undefined ? t.content : '';
      } catch (e) {
        continue; // 网络抖动：跳过本轮继续轮询
      }
      if (status === 'done') {
        await GenTask.clearPending(opts.ctx);
        if (goneFlag) {
          // 页面已离开：结果静默入库，避免丢失
          if (content !== '') {
            await HistoryStore.autoAdd(opts.ctx, {
              type: opts.label,
              title: opts.label,
              content: content,
              time: HistoryStore.formatNow()
            });
          }
        } else if (onDelta !== undefined) {
          onDelta(content);
        }
        return AiService.withAiNote(content, skipNote);
      }
      if (status === 'failed') {
        await GenTask.clearPending(opts.ctx);
        let msg: string = 'AI 生成失败，请稍后重试';
        try {
          const t2 = await GenTask.fetchTask(taskId);
          if (t2 !== null && t2.error !== undefined && t2.error !== '') {
            msg = t2.error;
          }
        } catch (e) {
          // ignore
        }
        throw new Error(msg);
      }
    }
    // 轮询超时：保留任务与 pending，下次进入 App 时由 recover 静默接管
    throw new Error('AI 生成较慢，请稍后到历史记录中查看结果');
  }

  /**
   * 订阅服务端任务 feed（SSE）：
   * chunk 增量拼接后回调 onDelta（整段进度文本）；done 事件返回权威完整内容。
   * 任何断线/异常/停滞（30s 无数据）都按 final=false 返回，由调用方退回轮询，绝不悬挂。
   */
  private static async feedOnce(taskId: string,
    onDelta: (partial: string) => void,
    isStopped?: () => boolean,
    onClient?: (c: SseClient) => void): Promise<FeedResult> {
    return new Promise<FeedResult>((resolve) => {
      let acc: string = '';
      let settled: boolean = false;
      let stallTimer: number = -1;
      let cl: SseClient | null = null;
      const settle = (final: boolean, content: string): void => {
        if (settled) {
          return;
        }
        settled = true;
        if (stallTimer !== -1) {
          clearTimeout(stallTimer);
          stallTimer = -1;
        }
        if (cl !== null) {
          cl.close();
          cl = null;
        }
        const fr: FeedResult = { final: final, content: content };
        resolve(fr);
      };
      const touch = (): void => {
        if (stallTimer !== -1) {
          clearTimeout(stallTimer);
        }
        stallTimer = setTimeout(() => {
          settle(false, '');
        }, 30000);
      };
      const listener: SseListener = {
        onEvent: (evt: SseEvent): void => {
          if (isStopped !== undefined && isStopped()) {
            settle(false, '');
            return;
          }
          touch();
          const payload: string = evt.payload;
          let obj: Record<string, Object> | null = null;
          if (payload !== '') {
            try {
              obj = JSON.parse(payload) as Record<string, Object>;
            } catch (e) {
              obj = null;
            }
          }
          if (evt.event === 'chunk') {
            const d: string = obj !== null && obj['d'] !== undefined ? String(obj['d']) : '';
            if (d !== '') {
              acc += d;
              onDelta(acc);
            }
          } else if (evt.event === 'done') {
            const c: string = obj !== null && obj['c'] !== undefined && String(obj['c']) !== ''
              ? String(obj['c']) : acc;
            settle(true, c);
          } else if (evt.event === 'error' || evt.event === 'cancelled') {
            settle(false, ''); // 交给轮询兜底读取失败/取消详情
          }
        },
        onEnd: (): void => {
          settle(false, '');
        },
        onError: (msg: string): void => {
          void msg;
          settle(false, '');
        }
      };
      cl = new SseClient(listener);
      const sse: SseClient = cl;
      if (onClient !== undefined) {
        onClient(sse); // 暴露给"停止生成"以便立即断开
      }
      sse.open('/task/' + taskId + '/feed').then((code: number): void => {
        if (code !== 200) {
          settle(false, '');
        }
      }).catch(() => {
        settle(false, '');
      });
      touch();
    });
  }

  /** 在生成内容末尾追加"AI 生成"标注（软件层统一生效，课件 JSON 除外）；内容为富文本 HTML */
  static withAiNote(content: string, skip: boolean): string {
    if (skip || content === '') {
      return content;
    }
    // 确定性富文本兜底：模型（尤其视觉模型）若未输出行内样式，此处按通用规律补齐加粗/重点色，
    // 保证预览与 Word/PPTX 导出都具备一致的富文本观感
    const body: string = RichHtml.enhanceFormatting(content);
    const lang: string | undefined = AppStorage.get<string>('appLang');
    const tailPlain: string = lang === 'en' ? '(AI-generated, for reference only)' : '（AI生成，仅供参考）';
    if (body.indexOf(tailPlain) >= 0) {
      return body;
    }
    const tailHtml: string = lang === 'en' ?
      '<br><br><i>(AI-generated, for reference only)</i>' :
      '<br><br><i>（AI生成，仅供参考）</i>';
    return body + tailHtml;
  }

  /** 单次请求（attachments 为本次生成携带的附件，服务端负责多模态拼装） */
  private static async requestOnce(systemPrompt: string, userPrompt: string,
    attachments?: AttachFile[]): Promise<string> {
    const httpRequest = http.createHttp();
    try {
      const response = await httpRequest.request(ApiConfig.activeBaseUrl(), {
        method: http.RequestMethod.POST,
        header: AiService.buildHeader(),
        extraData: AiService.buildBody(systemPrompt, userPrompt, attachments),
        connectTimeout: ApiConfig.CONNECT_TIMEOUT,
        readTimeout: ApiConfig.READ_TIMEOUT
      });
      const code: number = response.responseCode;
      const raw: string = typeof response.result === 'string' ? response.result : JSON.stringify(response.result);
      // 解析响应；解析失败按"异常响应"处理
      let data: ChatResponse | null = null;
      if (raw.trim() !== '') {
        try {
          data = JSON.parse(raw) as ChatResponse;
        } catch (parseErr) {
          data = null;
        }
      }
      if (data === null) {
        throw new Error('AI 服务返回了无法解析的内容（HTTP ' + code + '），请稍后重试');
      }
      if (code === 200) {
        if (data.choices !== undefined && data.choices.length > 0) {
          const content: string = data.choices[0].message.content;
          if (content !== undefined && content !== '') {
            return content;
          }
          const reason: string = data.choices[0].finish_reason !== undefined ? data.choices[0].finish_reason : '';
          if (reason === 'length') {
            throw new Error('内容生成被截断（输出长度不足），请减少输入内容后重试');
          }
          throw new Error('AI 未返回有效内容，请稍后重试');
        }
      }
      if (data.error !== undefined && data.error.message !== undefined && data.error.message !== '') {
        throw new Error(data.error.message);
      }
      throw new Error('AI 服务返回异常（HTTP ' + code + '），请稍后重试');
    } finally {
      httpRequest.destroy();
    }
  }

  private static buildHeader(): Record<string, string> {
    // 密钥保存在服务端，App 不携带任何 DeepSeek 鉴权；仅可选携带共享令牌
    const h: Record<string, string> = { 'Content-Type': 'application/json' };
    if (ApiConfig.PROXY_TOKEN !== '') {
      h['x-proxy-token'] = ApiConfig.PROXY_TOKEN;
    }
    return h;
  }

  private static buildBody(systemPrompt: string, userPrompt: string, attachments?: AttachFile[]): string {
    const messages: ChatMessage[] = [
      { role: 'system', content: systemPrompt },
      { role: 'user', content: userPrompt }
    ];
    const req: ChatRequest = {
      model: ApiConfig.MODEL,
      messages: messages,
      temperature: ApiConfig.TEMPERATURE,
      max_tokens: ApiConfig.MAX_TOKENS,
      stream: false,
      // 关闭思考模式（快速模式）：跳过思维链直接输出，缩短响应时间
      thinking: { type: 'disabled' }
    };
    if (attachments !== undefined && attachments.length > 0) {
      req.attachments = AttachService.toTask(attachments);
    }
    return JSON.stringify(req);
  }
}
