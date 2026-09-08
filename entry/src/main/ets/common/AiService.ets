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

export class AiService {
  /** 最大尝试次数（首次 + 2 次重试） */
  private static readonly MAX_ATTEMPTS: number = 3;

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
    try {
      if (opts !== undefined && opts.ctx !== undefined) {
        // 任务已提交成功的标志：一旦服务端接受任务，后续任务态失败/超时不再回退直连重发
        // （否则会把同一篇内容再完整生成一遍，等待时间成倍叠加且可能双份计费/双份通知）
        const ctl: TaskCtl = { accepted: false };
        try {
          const byTask: string = await AiService.chatByTask(systemPrompt, userPrompt, skipNote, onDelta, opts, ctl);
          AiService.mirrorDone(duoBus, opts, byTask);
          return byTask;
        } catch (e) {
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
          const raw: string = await AiService.requestOnce(systemPrompt, userPrompt);
          const out: string = AiService.withAiNote(raw, skipNote);
          if (opts !== undefined) {
            AiService.mirrorDone(duoBus, opts, out);
          }
          return out;
        } catch (e) {
          lastErr = e instanceof Error ? e : new Error('AI 请求失败，请稍后重试');
        }
      }
      throw lastErr;
    } catch (e) {
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
   * 后台任务模式：提交到服务端任务队列 -> 发布"生成中"通知 -> 轮询结果。
   * 页面销毁后（gone()=true）不再回调 UI，改为静默保存历史并更新通知；进程被杀则完全依赖服务端完成与推送。
   */
  private static async chatByTask(systemPrompt: string, userPrompt: string, skipNote: boolean,
    onDelta: ((partial: string) => void) | undefined, opts: AiTaskOpts, ctl: TaskCtl): Promise<string> {
    const seed: number = GenTask.nextSeed();
    const taskId: string = await GenTask.submit(opts.ctx, opts.type, opts.label, systemPrompt, userPrompt, seed);
    // 提交成功：服务端已接受任务并开始生成，此后任何任务态失败都不应回退直连重发
    ctl.accepted = true;
    // 生成中反馈：实况窗（PROGRESS 进度）优先，不可用回退常驻"生成中"通知
    const lvOk: boolean = await GenTask.publishRunning(opts.ctx, seed, opts.label);
    if (lvOk) {
      await GenTask.reportLive(taskId, seed); // 通知服务端：完成后推送结束消息清理实况窗
    }
    await GenTask.markRunningMode(opts.ctx, lvOk); // 记录反馈模式：实况窗免重建；普通通知需常驻/可心跳恢复
    let goneFlag: boolean = opts.gone !== undefined ? opts.gone() : false;
    const sleep = (ms: number): Promise<void> => new Promise<void>((resolve) => setTimeout(resolve, ms));
    for (let i: number = 0; i < GenTask.POLL_MAX; i++) {
      await sleep(GenTask.POLL_MS);
      goneFlag = opts.gone !== undefined ? opts.gone() : false;
      // 每约 10 秒一次：实况窗模式在页面存活时推进进度；
      // 普通通知模式心跳重建（被清除立即恢复），常驻效果覆盖离开页面后进程仍存活的轮询阶段
      if (i % 5 === 0 && i < 200) {
        if (lvOk && !goneFlag) {
          const seq: number = 2 + Math.floor(i / 5);
          const prog: number = 12 + i * 3;
          await GenTask.updateProgress(seed, opts.label, seq, prog);
        } else if (!lvOk) {
          await GenTask.refreshRunning(seed, opts.label);
        }
      }
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
        await GenTask.publishResult(seed, opts.label, true);
        await GenTask.clearPending(opts.ctx);
        if (lvOk) {
          await GenTask.stopLiveLocal(seed, opts.label);
        }
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
        await GenTask.publishResult(seed, opts.label, false);
        await GenTask.clearPending(opts.ctx);
        if (lvOk) {
          await GenTask.stopLiveLocal(seed, opts.label);
        }
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
    // 轮询超时：保留任务与"生成中"通知，下次进入 App 时由 recover 接管
    throw new Error('AI 生成较慢，请稍后在通知或历史中查看结果');
  }

  /** 在生成内容末尾追加"AI 生成"标注（软件层统一生效，课件 JSON 除外）；内容为富文本 HTML */
  static withAiNote(content: string, skip: boolean): string {
    if (skip || content === '') {
      return content;
    }
    const lang: string | undefined = AppStorage.get<string>('appLang');
    const tailPlain: string = lang === 'en' ? '(AI-generated, for reference only)' : '（AI生成，仅供参考）';
    if (content.indexOf(tailPlain) >= 0) {
      return content;
    }
    const tailHtml: string = lang === 'en' ?
      '<br><br><i>(AI-generated, for reference only)</i>' :
      '<br><br><i>（AI生成，仅供参考）</i>';
    return content + tailHtml;
  }

  /** 单次请求 */
  private static async requestOnce(systemPrompt: string, userPrompt: string): Promise<string> {
    const httpRequest = http.createHttp();
    try {
      const response = await httpRequest.request(ApiConfig.activeBaseUrl(), {
        method: http.RequestMethod.POST,
        header: AiService.buildHeader(),
        extraData: AiService.buildBody(systemPrompt, userPrompt),
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

  private static buildBody(systemPrompt: string, userPrompt: string): string {
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
    return JSON.stringify(req);
  }
}
