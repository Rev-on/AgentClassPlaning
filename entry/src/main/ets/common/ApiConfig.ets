/**
 * AI 服务配置（代理模式）
 *
 * 安全说明：
 *  - DeepSeek API Key 只保存在你自己的云服务器（server/.env 的 DEEPSEEK_API_KEY），
 *    本 App 不再包含任何密钥明文。
 *  - 前端所有 AI 请求统一转发到自建代理服务，由服务端注入鉴权头后访问 DeepSeek。
 *  - 可选共享令牌 PROXY_TOKEN 用于防滥用，需与服务器 .env 中 PROXY_TOKEN 一致；
 *    若服务器未设置令牌，请保持本字段为空字符串。
 */
export class ApiConfig {
  /** 中转代理地址（HTTPS；与 server/src/server.js TLS 配置一致，端口 3000） */
  static readonly PROXY_BASE_URL: string = 'https://rev-on.site:3000/v1/chat/completions';
  /** 服务端 API 根地址（后台生成任务 / Push 注册） */
  static readonly SERVER_BASE_URL: string = 'https://rev-on.site:3000/api';
  /** 代理共享令牌（与服务器 .env 的 PROXY_TOKEN 一致；服务器未启用则留空） */
  static readonly PROXY_TOKEN: string = '';
  /** 模型名称：deepseek-v4-flash（性价比高）；如需更强可换 deepseek-v4-pro */
  static readonly MODEL: string = 'deepseek-v4-flash';
  /** 连接超时（毫秒）：短连接超时便于快速失败重试 */
  static readonly CONNECT_TIMEOUT: number = 10000;
  /** 读取超时（毫秒）：长输出留足时间（与 server REQUEST_TIMEOUT_MS 一致），减少中途断流 */
  static readonly READ_TIMEOUT: number = 300000;
  /** 生成温度（0-2，越小越稳定） */
  static readonly TEMPERATURE: number = 0.9;
  /** 最大输出 tokens */
  static readonly MAX_TOKENS: number = 8192;

  /** 请求地址：统一走自建代理（密钥在服务端） */
  static activeBaseUrl(): string {
    return ApiConfig.PROXY_BASE_URL;
  }
}
