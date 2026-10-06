/**
 * 华为 Push Kit 服务端推送（HarmonyOS v3 REST API）
 *
 * 依赖环境变量（在 .env 中配置，未配置时所有发送自动跳过，不影响任务本身）：
 *   AGC_PROJECT_ID        AppGallery Connect 项目ID（项目设置页获取）
 *   AGC_JWT_KID           服务账号密钥文件 key_id
 *   AGC_JWT_ISS           服务账号 sub_account（iss）
 *   AGC_JWT_PRIVATE_KEY   服务账号私钥 PEM（含换行用 \n，或使用 AGC_PUSH_ACCOUNT_FILE）
 *   AGC_PUSH_ACCOUNT_FILE 或直接指向 AGC 下载的服务账号 JSON（含 key_id/sub_account/private_key）
 *   AGC_PUSH_TEST         true 表示调测消息（每日全网 1000 条限额）
 *
 * 参考：https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/push-send-alert
 */
const crypto = require('crypto');
const fs = require('fs');

const PUSH_URL = 'https://push-api.cloud.huawei.com/v3/';
const AUD = 'https://oauth-login.cloud.huawei.com/oauth2/v3/token';

function readAccount() {
  const file = process.env.AGC_PUSH_ACCOUNT_FILE;
  if (file) {
    try {
      const j = JSON.parse(fs.readFileSync(file, 'utf8'));
      return {
        projectId: process.env.AGC_PROJECT_ID || j.project_id || '',
        kid: j.key_id || '',
        iss: j.sub_account || j.client_email || '',
        privateKey: j.private_key || ''
      };
    } catch (e) {
      console.error('[push] 读取 AGC_PUSH_ACCOUNT_FILE 失败: ' + (e && e.message ? e.message : String(e)));
    }
  }
  return {
    projectId: process.env.AGC_PROJECT_ID || '',
    kid: process.env.AGC_JWT_KID || '',
    iss: process.env.AGC_JWT_ISS || '',
    privateKey: process.env.AGC_JWT_PRIVATE_KEY || ''
  };
}

function configured() {
  const a = readAccount();
  return !!(a.projectId && a.kid && a.iss && a.privateKey);
}

function b64url(buf) {
  return Buffer.from(buf).toString('base64')
    .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

/** 生成 PS256 JWT（Authorization Bearer），有效期 1 小时 */
function buildJwt() {
  const a = readAccount();
  const now = Math.floor(Date.now() / 1000);
  const header = b64url(JSON.stringify({ kid: a.kid, alg: 'PS256', typ: 'JWT' }));
  const payload = b64url(JSON.stringify({ aud: AUD, iss: a.iss, iat: now, exp: now + 3600 }));
  const input = header + '.' + payload;
  const key = crypto.createPrivateKey(String(a.privateKey).replace(/\\n/g, '\n'));
  const signer = crypto.createSign('RSA-SHA256');
  signer.update(input);
  signer.end();
  const sig = signer.sign({ key: key, padding: crypto.constants.RSA_PKCS1_PSS_PADDING, saltLength: 32 });
  return input + '.' + b64url(sig);
}

/**
 * 发送通知消息（push-type 0，Alert）。
 * notifyId 与客户端本地"生成中"通知保持一致，实现"完成通知覆盖进行中通知"。
 */
async function sendAlert({ token, notifyId, title, body, data }) {
  if (!configured()) {
    console.warn('[push] 未配置 AGC 推送凭据，跳过推送（title=' + title + '）');
    return { skipped: true };
  }
  if (!token) {
    console.warn('[push] 设备 Push Token 为空，跳过推送');
    return { skipped: true };
  }
  const a = readAccount();
  const url = PUSH_URL + a.projectId + '/messages:send';
  const payload = {
    payload: {
      notification: {
        // 通知分类。华为把通知分为「服务/通讯」与「资讯营销」两类：
        // MARKETING 属营销类，用户可整体关闭营销通知而收不到；
        // 本应用的通知是**用户主动发起的生成任务已完成**，属功能/服务提醒，
        // 故默认使用 WORK。
        // 合法取值（用华为推送接口实测确认，返回 80000000）：
        //   MARKETING, IM, VOIP, SUBSCRIPTION, TRAVEL, HEALTH, WORK,
        //   ACCOUNT, EXPRESS, FINANCE, DEVICE_REMINDER, MAIL, NEWS
        // 非法取值（返回 80100003 invalid category）：
        //   TODO, LOCATION, SOCIAL, RECOMMEND, SERVICE, PLAY_VOICE
        category: process.env.AGC_PUSH_CATEGORY || 'WORK',
        // 通知渠道类型：决定是否有提示音与横幅。
        //
        // ⚠️ 重要：这里的数字必须与**客户端已注册的通知渠道**对应，
        //    只设这里而客户端没注册渠道是无效的（会落到默认低级别渠道，
        //    表现为"能收到通知但不响铃、无横幅"）。
        //    客户端注册逻辑见 entry/src/main/ets/common/NotifySlot.ets。
        //
        // 取值与客户端 SlotType 常量一一对应（以 OpenHarmony 官方 d.ts 为准）：
        //   0 = UNKNOWN_TYPE          未知（LEVEL_MIN，静默）
        //   1 = SOCIAL_COMMUNICATION  社交通信，默认 LEVEL_HIGH → 横幅 + 提示音
        //   2 = SERVICE_INFORMATION   服务提醒，默认 LEVEL_HIGH
        //   3 = CONTENT_INFORMATION   内容资讯，默认 LEVEL_MIN（静默）
        //   4 = LIVE_VIEW             实况窗
        //   5 = CUSTOMER_SERVICE      客服消息
        //
        // 本应用默认用 1：生成完成通知要**响铃 + 弹横幅**，
        // 且客户端已注册 SOCIAL_COMMUNICATION 渠道（NotifySlot.ets）。
        slotType: Number(process.env.AGC_PUSH_SLOT_TYPE || 1),
        title: String(title || ''),
        body: String(body || ''),
        clickAction: { actionType: 0, data: data || {} },
        // 前台是否展示通知。
        //   默认 false：华为设计如此 —— App 在前台时系统不弹通知，避免与页面内
        //   展示重复（本应用前台已有实况窗 + 结果面板显示进度）。
        //   副作用：**前台测试时永远收不到通知**，容易被误判为"推送不工作"。
        //   可用 AGC_PUSH_FOREGROUND_SHOW=true 打开，便于前台联调验证链路是否通。
        foregroundShow: process.env.AGC_PUSH_FOREGROUND_SHOW === 'true',
        notifyId: Number(notifyId || 0)
      }
    },
    target: { token: [token] },
    pushOptions: {
      testMessage: process.env.AGC_PUSH_TEST === 'true',
      ttl: 86400
    }
  };
  try {
    const resp = await fetch(url, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ' + buildJwt(),
        'push-type': '0'
      },
      body: JSON.stringify(payload)
    });
    const text = await resp.text();
    // 关键：华为**即使业务失败也返回 HTTP 200**，真正的结果在响应体的 code 字段。
    // 早前只看 resp.ok 判断成败，导致 code=80300007（token 无效）被误判为"发送成功"，
    // 失效 token 因此一直得不到清理。必须解析 body.code。
    let code = '';
    let illegal = [];
    try {
      const j = JSON.parse(text);
      code = String(j.code || '');
      // 80300007：token 格式错误/已失效，msg 里带 illegalTokens 明细
      if (j.msg) {
        try {
          const inner = JSON.parse(j.msg);
          if (inner && inner.illegalTokens) {
            Object.keys(inner.illegalTokens).forEach((k) => {
              (inner.illegalTokens[k] || []).forEach((t) => illegal.push(t));
            });
          }
        } catch (e2) {
          // msg 非 JSON：忽略
        }
      }
    } catch (e) {
      // 响应体非 JSON
    }

    if (code === '80000000') {
      console.log('[push] 完成通知已发送（华为已受理）');
      return { ok: true, code };
    }

    console.error('[push] 发送失败 httpCode=' + resp.status + ' code=' + code
      + ' body=' + text.slice(0, 300));
    // 把失效 token 一并抛出，交由调用方清理
    return { ok: false, code, status: resp.status, illegalTokens: illegal, body: text.slice(0, 300) };
  } catch (e) {
    console.error('[push] 发送异常: ' + (e && e.message ? e.message : String(e)));
    return { ok: false };
  }
}

/**
 * 通过 Push Kit 结束本地创建的实况窗（push-type 7，operation 2）。
 * 用于任务完成时清理"生成中"实况窗（即使客户端进程已被杀掉也能结束）。
 */
async function sendLiveViewEnd({ token, activityId, event }) {
  if (!configured()) {
    console.warn('[push] 未配置 AGC 推送凭据，跳过实况窗结束消息');
    return { skipped: true };
  }
  if (!token) {
    console.warn('[push] 设备 Push Token 为空，跳过实况窗结束消息');
    return { skipped: true };
  }
  const a = readAccount();
  const url = PUSH_URL + a.projectId + '/messages:send';
  const payload = {
    payload: {
      activityId: Number(activityId || 0),
      operation: 2,
      event: String(event || 'PROGRESS')
    },
    target: { token: [token] },
    pushOptions: {
      testMessage: process.env.AGC_PUSH_TEST === 'true',
      ttl: 86400
    }
  };
  try {
    const resp = await fetch(url, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ' + buildJwt(),
        'push-type': '7'
      },
      body: JSON.stringify(payload)
    });
    const text = await resp.text();
    if (resp.ok) {
      console.log('[push] 实况窗结束消息已发送 activityId=' + activityId);
      return { ok: true };
    }
    console.error('[push] 实况窗结束消息失败 code=' + resp.status + ' body=' + text.slice(0, 300));
    return { ok: false, status: resp.status };
  } catch (e) {
    console.error('[push] 实况窗结束消息异常: ' + (e && e.message ? e.message : String(e)));
    return { ok: false };
  }
}

module.exports = { sendAlert, sendLiveViewEnd, configured };
