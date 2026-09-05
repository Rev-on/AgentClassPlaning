/**
 * 账号接口：调用自建服务器（server/）完成注册/登录/华为登录
 *  - 服务端地址复用 ApiConfig 的代理地址，自动取服务器根路径
 *  - 错误信息统一取服务端返回的 error.message，页面可直接提示
 */
import http from '@ohos.net.http';
import { ApiConfig } from './ApiConfig';

/** 会话中的用户信息 */
export interface SessionUser {
  username: string;
  kind: string;
  nickname?: string;
  avatar?: string;
}

/** 会话响应（成功） */
export interface SessionResult {
  token: string;
  user: SessionUser;
}

/** 服务端错误体 */
interface ErrorBody {
  message?: string;
}

/** 服务端完整响应 */
interface SessionResp {
  token?: string;
  user?: SessionUser;
  error?: ErrorBody;
}

/** 账号请求体（显式声明的接口，字段按需携带） */
interface AccountRequestBody {
  username?: string;
  password?: string;
  code?: string;
  redirectUri?: string;
}

/** 资料更新请求体 */
interface ProfileRequestBody {
  nickname?: string;
  avatar?: string;
}

/** 资料更新响应 */
interface ProfileResp {
  user?: SessionUser;
  error?: ErrorBody;
}

export class AccountApi {
  /** 服务器根地址（从代理 URL 反推：…:3000/v1/chat/completions -> …:3000） */
  static serverRoot(): string {
    const base = ApiConfig.PROXY_BASE_URL;
    const idx = base.indexOf('/v1/chat/completions');
    if (idx > 0) {
      return base.substring(0, idx);
    }
    return base;
  }

  private static async post(path: string, body: AccountRequestBody): Promise<SessionResult> {
    const req = http.createHttp();
    try {
      const resp = await req.request(AccountApi.serverRoot() + path, {
        method: http.RequestMethod.POST,
        header: { 'Content-Type': 'application/json' },
        extraData: JSON.stringify(body),
        connectTimeout: 10000,
        readTimeout: 30000
      });
      const raw: string = typeof resp.result === 'string' ? resp.result : JSON.stringify(resp.result);
      let data: SessionResp | null = null;
      try {
        data = JSON.parse(raw) as SessionResp;
      } catch (e) {
        data = null;
      }
      const code: number = resp.responseCode;
      if (code === 200 && data !== null && data.token !== undefined && data.token !== '') {
        const src = data.user !== undefined ? data.user : null;
        const user: SessionUser = {
          username: src !== null && src.username !== undefined ? src.username : '',
          kind: src !== null && src.kind !== undefined ? src.kind : 'account',
          nickname: src !== null && src.nickname !== undefined ? src.nickname : undefined,
          avatar: src !== null && src.avatar !== undefined ? src.avatar : undefined
        };
        const out: SessionResult = { token: data.token, user: user };
        return out;
      }
      const msg: string = data !== null && data.error !== undefined && data.error.message !== undefined
        ? data.error.message
        : ('服务返回异常（HTTP ' + code + '），请稍后重试');
      throw new Error(msg);
    } finally {
      req.destroy();
    }
  }

  /** 账号密码登录 */
  static login(username: string, password: string): Promise<SessionResult> {
    const body: AccountRequestBody = { username: username, password: password };
    return AccountApi.post('/api/login', body);
  }

  /** 注册并直接登录 */
  static register(username: string, password: string): Promise<SessionResult> {
    const body: AccountRequestBody = { username: username, password: password };
    return AccountApi.post('/api/register', body);
  }

  /** 华为授权码换会话（服务端完成 code -> openid 交换） */
  static huaweiLogin(code: string, redirectUri: string): Promise<SessionResult> {
    const body: AccountRequestBody = { code: code, redirectUri: redirectUri };
    return AccountApi.post('/api/huawei-login', body);
  }

  /** 更新资料（昵称/头像），返回最新用户信息 */
  static async updateProfile(token: string, nickname: string, avatar: string): Promise<SessionUser> {
    const body: ProfileRequestBody = {};
    if (nickname !== '') {
      body.nickname = nickname;
    }
    if (avatar !== '') {
      body.avatar = avatar;
    }
    const req = http.createHttp();
    try {
      const resp = await req.request(AccountApi.serverRoot() + '/api/profile', {
        method: http.RequestMethod.PATCH,
        header: { 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + token },
        extraData: JSON.stringify(body),
        connectTimeout: 10000,
        readTimeout: 30000
      });
      const raw: string = typeof resp.result === 'string' ? resp.result : JSON.stringify(resp.result);
      let data: ProfileResp | null = null;
      try {
        data = JSON.parse(raw) as ProfileResp;
      } catch (e) {
        data = null;
      }
      const code: number = resp.responseCode;
      if (code === 200 && data !== null && data.user !== undefined) {
        const u: SessionUser = {
          username: data.user.username !== undefined ? data.user.username : '',
          kind: data.user.kind !== undefined ? data.user.kind : 'account',
          nickname: data.user.nickname !== undefined ? data.user.nickname : undefined,
          avatar: data.user.avatar !== undefined ? data.user.avatar : undefined
        };
        return u;
      }
      const msg: string = data !== null && data.error !== undefined && data.error.message !== undefined
        ? data.error.message
        : ('保存资料失败（HTTP ' + code + '）');
      throw new Error(msg);
    } finally {
      req.destroy();
    }
  }
}
