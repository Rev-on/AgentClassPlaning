/**
 * AI 服务配置
 *
 * 参赛演示版说明：
 *  本文件包含 DeepSeek API 密钥，仅用于参赛作品本地演示。
 *  安全提示：正式发布或提交公网前，请改为"服务端代理"方式（密钥保存在服务器，
 *  App 只请求代理地址），避免 API Key 随安装包泄露。
 *  可在 deepseek 开放平台后台随时轮换（重置）密钥。
 */
export class ApiConfig {
  /** DeepSeek API 端点（OpenAI 兼容格式） */
  static readonly BASE_URL: string = 'https://api.deepseek.com/chat/completions';
  /** 模型名称：deepseek-v4-flash（性价比高）；如需更强可换 deepseek-v4-pro */
  static readonly MODEL: string = 'deepseek-v4-flash';
  /** API Key（开发演示用） */
  static readonly API_KEY: string = 'sk-c980bbcbafb64db694a7615d8360c238';
  /** 连接超时（毫秒）：短连接超时便于快速失败重试 */
  static readonly CONNECT_TIMEOUT: number = 10000;
  /** 读取超时（毫秒）：流式/长输出留足时间，减少中途断流 */
  static readonly READ_TIMEOUT: number = 150000;
  /** 生成温度（0-2，越小越稳定） */
  static readonly TEMPERATURE: number = 0.7;
  /** 最大输出 tokens */
  static readonly MAX_TOKENS: number = 8192;
}
