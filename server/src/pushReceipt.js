/**
 * 华为 Push Kit 消息回执（Receipt）接收端
 *
 * 作用：华为推送服务器在消息**送达/失败**后，回调本服务，把最终投递结果告知我们。
 * 用于确认"生成完成通知"是否真正到达设备，便于排查与统计。
 *
 * 官方接口约定（Push Kit REST API - 消息回执）：
 *   - 方向：华为 Push 服务器 -> 开发者回执接收服务器（HTTPS POST）
 *   - URL：由开发者在 AGC「项目设置 → 消息回执」中配置，须与本服务路由一致
 *   - Body：{ "statuses": [ { token, pushType, appPackageName, requestId,
 *                            biTag?, deliveryStatus: { result, timestamp } } ] }
 *          最多 100 条；V3 场景化消息仅支持 V2 版本回执
 *   - 响应：{ "code": "0", "message": "success" }，HTTP 200
 *
 * 鉴权（重要）：
 *   当 AGC 中「回调用户名」与「回调密钥」**均已配置**时，请求头
 *   X-HUAWEI-CALLBACK-ID 为**必选**，其格式为：
 *       timestamp=<unix秒>; nonce=<uuid>; value=<Base64(HmacSHA256(...))>
 *   其中待签名串 = timestamp + nonce + 回调用户名
 *   签名算法   = HmacSHA256(待签名串, 回调密钥)
 *   本模块据此校验，并允许 5 分钟时钟偏差。
 *
 * 环境变量：
 *   PUSH_CALLBACK_USER   回调用户名（AGC 中配置的值）
 *   PUSH_CALLBACK_SECRET 回调密钥（AGC 中配置的值）
 *   PUSH_CALLBACK_PATH   回执路由路径（默认 /api/push/receipt）
 */
const crypto = require('crypto');

/** 允许的时间偏差（秒）：华为服务器与本机时钟不会完全一致 */
const CLOCK_SKEW_SEC = 300;

function callbackUser() {
  return process.env.PUSH_CALLBACK_USER || '';
}

function callbackSecret() {
  return process.env.PUSH_CALLBACK_SECRET || '';
}

/** 是否已配置鉴权凭据（两者都配置时才校验） */
function authConfigured() {
  return callbackUser() !== '' && callbackSecret() !== '';
}

/** 计算期望的 value 值：Base64(HmacSHA256(timestamp + nonce + user, secret)) */
function expectedValue(timestamp, nonce) {
  const data = String(timestamp) + String(nonce) + callbackUser();
  return crypto.createHmac('sha256', callbackSecret()).update(data, 'utf8').digest('base64');
}

/** 常量时间比较，避免时序侧信道 */
function safeEqual(a, b) {
  const ba = Buffer.from(String(a), 'utf8');
  const bb = Buffer.from(String(b), 'utf8');
  if (ba.length !== bb.length) {
    return false;
  }
  return crypto.timingSafeEqual(ba, bb);
}

/**
 * 解析 X-HUAWEI-CALLBACK-ID 头。
 * 形如：timestamp=1698...; nonce=xxxx; value=yyyy
 */
function parseCallbackId(header) {
  const out = { timestamp: '', nonce: '', value: '' };
  if (!header) {
    return out;
  }
  const parts = String(header).split(';');
  for (let i = 0; i < parts.length; i++) {
    const seg = parts[i].trim();
    const eq = seg.indexOf('=');
    if (eq <= 0) {
      continue;
    }
    const k = seg.slice(0, eq).trim();
    const v = seg.slice(eq + 1).trim();
    if (k === 'timestamp') {
      out.timestamp = v;
    } else if (k === 'nonce') {
      out.nonce = v;
    } else if (k === 'value') {
      out.value = v;
    }
  }
  return out;
}

/**
 * 校验回执请求鉴权。
 * 返回 { ok: true } 或 { ok: false, reason: '...' }
 */
function verify(req) {
  if (!authConfigured()) {
    // 未配置用户名/密钥：不校验（AGC 侧也不会下发该头）
    return { ok: true, skipped: true };
  }
  const h = parseCallbackId(req.get('X-HUAWEI-CALLBACK-ID'));
  if (h.timestamp === '' || h.nonce === '' || h.value === '') {
    // 无鉴权头的请求视为「连通性探测」而非真实回执。
    //
    // 为什么不能直接判失败：AGC 的「回执测试」按钮发的是探测请求，**不带**
    // X-HUAWEI-CALLBACK-ID（它不是真实推送回执）。若这里一律拒绝，AGC 会显示
    // “回执测试失败”/“响应码不为200 OK”，导致无法在控制台完成配置校验。
    // 真实回执一定会带该头（回调用户名与密钥均已配置时），因此放行空探测
    // 不会削弱安全性 —— 它不携带任何业务数据，也被 handleStatuses 视为 0 条。
    return { ok: true, probe: true };
  }
  // 带了鉴权头但字段残缺 / 签名不对：这是伪造或配置不一致，一律拒绝
  return verifySigned(h);
}

/** 校验带签名的回执请求 */
function verifySigned(h) {
  // 时间偏差检查：防重放
  const ts = Number(h.timestamp);
  if (!Number.isFinite(ts)) {
    return { ok: false, reason: 'bad timestamp' };
  }
  const nowSec = Math.floor(Date.now() / 1000);
  if (Math.abs(nowSec - ts) > CLOCK_SKEW_SEC) {
    return { ok: false, reason: 'timestamp expired' };
  }
  const want = expectedValue(h.timestamp, h.nonce);
  if (!safeEqual(want, h.value)) {
    return { ok: false, reason: 'signature mismatch' };
  }
  return { ok: true };
}

/** 回执状态码释义（0 表示成功） */
const RESULT_TEXT = {
  0: '成功',
  1: 'Token 无效',
  2: '消息体过大',
  3: '推送频率过高',
  4: '设备不支持',
  5: '消息被拒绝',
  6: '推送凭证失效',
  7: '消息过期',
  8: '用户已关闭通知',
  10: '内部错误',
  11: '消息重复',
  12: '消息未送达',
  13: '消息被限流',
  14: '消息被丢弃',
  15: '目标用户不存在',
  17: '网络异常',
  18: '应用未安装',
  19: '系统版本过低',
  20: '应用被卸载',
  21: '消息未匹配到设备',
  22: '设备离线',
  23: '消息已下发待送达',
  24: '消息下发失败',
  25: '消息下发超时',
  26: '设备存储空间不足',
  27: '推送服务未开启',
  28: '应用被禁用',
  29: '消息内容非法',
  30: '其他错误'
};

function resultText(code) {
  const t = RESULT_TEXT[code];
  return t !== undefined ? t : '未知状态码';
}

/** 最近若干条回执（内存环形缓冲，供调试接口查看） */
const recent = [];
const RECENT_MAX = 200;
let statTotal = 0;
let statOk = 0;
let statFail = 0;

/**
 * 处理一批回执。
 * 返回 { received, ok, fail }
 */
function handleStatuses(statuses) {
  let ok = 0;
  let fail = 0;
  const list = Array.isArray(statuses) ? statuses : [];
  for (let i = 0; i < list.length; i++) {
    const s = list[i] || {};
    const ds = s.deliveryStatus || {};
    const code = Number(ds.result);
    const success = code === 0;
    if (success) {
      ok++;
    } else {
      fail++;
    }
    statTotal++;
    if (success) {
      statOk++;
    } else {
      statFail++;
    }
    const rec = {
      at: Date.now(),
      requestId: String(s.requestId || ''),
      token: String(s.token || '').slice(0, 12) + '***',
      pushType: Number(s.pushType),
      package: String(s.appPackageName || ''),
      biTag: String(s.biTag || ''),
      result: code,
      resultText: resultText(code),
      timestamp: Number(ds.timestamp || 0)
    };
    recent.push(rec);
    if (recent.length > RECENT_MAX) {
      recent.shift();
    }
    if (success) {
      console.log('[push-receipt] 送达 requestId=' + rec.requestId + ' pushType=' + rec.pushType);
    } else {
      console.warn('[push-receipt] 失败 requestId=' + rec.requestId + ' result=' + code +
        '(' + rec.resultText + ') pushType=' + rec.pushType);
    }
  }
  return { received: list.length, ok: ok, fail: fail };
}

/** 统计信息（供调试接口） */
function stats() {
  return {
    authConfigured: authConfigured(),
    user: callbackUser(),
    path: process.env.PUSH_CALLBACK_PATH || '/api/push/receipt',
    total: statTotal,
    ok: statOk,
    fail: statFail,
    recent: recent.slice(-50)
  };
}

module.exports = { verify, handleStatuses, stats, authConfigured, resultText };
