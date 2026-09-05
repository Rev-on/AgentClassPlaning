/**
 * AI 服务：封装 DeepSeek 对话补全接口（非流式，稳定性优先）
 *  - thinking 已禁用（快速模式），stream 固定 false
 *  - 偶发失败自动重试（最多 3 次），HTTP 200 但响应异常给出明确提示
 * @param onDelta 保留参数以兼容调用方，当前固定非流式不使用
 */
import http from '@ohos.net.http';
import { ApiConfig } from './ApiConfig';

/** 对话消息 */
interface ChatMessage {
  role: string;
  content: string;
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

export class AiService {
  /** 最大尝试次数（首次 + 2 次重试） */
  private static readonly MAX_ATTEMPTS: number = 3;

  /**
   * 调用 DeepSeek，返回完整回复文本（非流式）
   * @param systemPrompt 系统提示词（角色与输出规范）
   * @param userPrompt 用户输入内容
   * @param onDelta 保留参数（兼容历史调用），当前实现不使用
   * @param skipNote 为 true 时不追加"AI生成"尾注（如课件大纲 JSON 结构化输出）
   */
  static async chat(systemPrompt: string, userPrompt: string, onDelta?: (partial: string) => void,
    skipNote: boolean = false): Promise<string> {
    let lastErr: Error = new Error('AI 请求失败，请稍后重试');
    for (let attempt: number = 0; attempt < AiService.MAX_ATTEMPTS; attempt++) {
      try {
        const raw: string = await AiService.requestOnce(systemPrompt, userPrompt);
        return AiService.withAiNote(raw, skipNote);
      } catch (e) {
        lastErr = e instanceof Error ? e : new Error('AI 请求失败，请稍后重试');
      }
    }
    throw lastErr;
  }

  /** 在生成内容末尾追加"AI 生成"标注（软件层统一生效，课件 JSON 除外） */
  static withAiNote(content: string, skip: boolean): string {
    if (skip || content === '') {
      return content;
    }
    const lang: string | undefined = AppStorage.get<string>('appLang');
    const tail: string = lang === 'en' ? '(AI-generated, for reference only)' : '（AI生成，仅供参考）';
    if (content.trim().endsWith(tail)) {
      return content;
    }
    return content + '\n\n' + tail;
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
