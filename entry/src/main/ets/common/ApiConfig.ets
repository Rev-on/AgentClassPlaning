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
  /** 中转代理地址（与 server/README.md 部署端口一致） */
  static readonly PROXY_BASE_URL: string = 'http://123.60.130.45:3000/v1/chat/completions';
  /** 代理共享令牌（与服务器 .env 的 PROXY_TOKEN 一致；服务器未启用则留空） */
  static readonly PROXY_TOKEN: string = '';
  /** 认证服务（Auth Service）/ 华为账号：AGC 客户端 ID（授权与换 token 均用此号） */
  static readonly HUAWEI_CLIENT_ID: string = '6917615335790825716';
  /** 华为登录 OAuth 回调地址（须与 AGC 控制台登记的地址一致） */
  static readonly HUAWEI_REDIRECT: string = 'http://123.60.130.45:3000/api/huawei/cb';
  /** 模型名称：deepseek-v4-flash（性价比高）；如需更强可换 deepseek-v4-pro */
  static readonly MODEL: string = 'deepseek-v4-flash';
  /** 连接超时（毫秒）：短连接超时便于快速失败重试 */
  static readonly CONNECT_TIMEOUT: number = 10000;
  /** 读取超时（毫秒）：长输出留足时间，减少中途断流 */
  static readonly READ_TIMEOUT: number = 150000;
  /** 生成温度（0-2，越小越稳定） */
  static readonly TEMPERATURE: number = 0.9;
  /** 最大输出 tokens */
  static readonly MAX_TOKENS: number = 8192;

  /** 请求地址：统一走自建代理（密钥在服务端） */
  static activeBaseUrl(): string {
    return ApiConfig.PROXY_BASE_URL;
  }
}
