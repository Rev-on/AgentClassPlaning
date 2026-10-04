/**
 * Push Token 管理：向华为 Push Kit 申请设备 Token 并上报到自建服务端。
 *
 * 作用：服务端需要知道"往哪台设备推"。Token 由客户端申请，上报后服务端
 *       在后台任务完成时用它下发"生成完成"通知。
 *
 * 使用：EntryAbility.onCreate 中调用 PushToken.ensure()（失败静默，不影响启动）。
 *
 * 依赖：@kit.PushKit（系统能力，无需额外依赖）
 * 服务端接口：POST /api/push/register  { deviceId, token }
 */
import { pushService } from '@kit.PushKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { http } from '@kit.NetworkKit';
import { ApiConfig } from './ApiConfig';
import deviceInfo from '@ohos.deviceInfo';

const DOMAIN = 0x0000;
const TAG = 'PushToken';
/** AppStorage 键：本次是否已成功申请并上报（避免重复请求） */
const KEY_DONE = 'pushTokenDone';

export class PushToken {
  /** 申请并上报 Push Token（幂等：已成功过则直接返回） */
  static async ensure(): Promise<void> {
    if (AppStorage.get<boolean>(KEY_DONE) === true) {
      return;
    }
    try {
      const token: string = await pushService.getToken();
      if (token === '') {
        hilog.warn(DOMAIN, TAG, 'getToken 返回空串，跳过上报');
        return;
      }
      // 日志里只打印前后片段，避免完整 Token 泄露
      hilog.info(DOMAIN, TAG, 'getToken 成功: %{public}s...', token.substring(0, 12));
      const ok: boolean = await PushToken.report(token);
      if (ok) {
        AppStorage.setOrCreate(KEY_DONE, true);
      }
    } catch (e) {
      const err = e as BusinessError;
      // 常见失败：应用未开通推送服务 / 设备未登录华为账号 / 无网络
      hilog.warn(DOMAIN, TAG, 'getToken 失败: %{public}d %{public}s',
        err.code === undefined ? -1 : err.code, err.message === undefined ? '' : err.message);
    }
  }

  /** 上报 Token 到自建服务端 */
  private static async report(token: string): Promise<boolean> {
    const url: string = ApiConfig.SERVER_BASE_URL + '/push/register';
    const deviceId: string = PushToken.deviceId();
    const body: string = JSON.stringify({ deviceId: deviceId, token: token });
    const req = http.createHttp();
    try {
      const headers: Record<string, string> = { 'Content-Type': 'application/json' };
      const pt: string = ApiConfig.PROXY_TOKEN;
      if (pt !== '') {
        headers['x-proxy-token'] = pt;
      }
      const resp = await req.request(url, {
        method: http.RequestMethod.POST,
        header: headers,
        extraData: body,
        connectTimeout: 10000,
        readTimeout: 15000
      });
      if (resp.responseCode === 200) {
        hilog.info(DOMAIN, TAG, 'Token 上报成功 deviceId=%{public}s', deviceId);
        return true;
      }
      hilog.warn(DOMAIN, TAG, 'Token 上报失败 HTTP %{public}d', resp.responseCode);
      return false;
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(DOMAIN, TAG, 'Token 上报异常: %{public}s',
        err.message === undefined ? String(e) : err.message);
      return false;
    } finally {
      req.destroy();
    }
  }

  /**
   * 稳定的设备标识：优先用系统 odID（同一设备同一应用稳定），
   * 退化到"品牌-型号-系统版本"组合。不采集用户隐私信息。
   */
  static deviceId(): string {
    try {
      const odid: string = deviceInfo.ODID !== undefined ? deviceInfo.ODID : '';
      if (odid !== '') {
        return odid;
      }
    } catch (e) {
      // 某些设备可能不提供 ODID，忽略
    }
    return (deviceInfo.brand || 'dev') + '-' + (deviceInfo.productModel || 'unknown');
  }
}
