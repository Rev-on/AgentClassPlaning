/**
 * 华为 Push Kit 服务端推送（HarmonyOS v3 REST API）
 *
 * 覆盖三类报文（均走 POST {PUSH_URL}{projectId}/messages:send）：
 *   - push-type 0 通知消息（sendAlert）
 *   - push-type 7 实况窗消息（sendLiveViewUpdate / sendLiveViewEnd）
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

/* ===================== 实况窗（Live View）远程下发 ===================== */

/**
 * 实况窗进度更新的**节流与去抖**。
 *
 * 【为什么必须节流】
 *   1) 华为对实况窗消息有频率限制，超频会返回 1003500008（同时也有每日配额）；
 *      本地 LiveView.ets 已按"百分比变化"节流，服务端同样必须克制。
 *   2) 客户端进程被挂起/杀掉后，本地更新链路彻底失效 —— 这是本机制存在的**唯一理由**；
 *      客户端活着时它自己在更新，服务端只是兜底，不该跟着刷屏。
 *   3) 实况窗长时间不更新会被系统降级/清除（胶囊与锁屏 2 小时、整体 4 小时），
 *      所以也不能完全不推 —— 需要"少而准时"。
 *
 * 【策略】
 *   - **百分比变化才推**：本地按百分比节流，远端若按每次增量推，报文频率会高一个数量级。
 *     远端不掌握客户端的 EXPECT_CHARS 表，故约定客户端在创建实况窗时上报"预期总字符数"
 *     （POST /api/task/:id/liveview 的 totalChars 字段），服务端据此算百分比；
 *     未上报时退回该类型的默认预期长度。
 *   - **最小间隔**：同一任务两次更新之间至少间隔 MIN_MS（默认 10 秒），
 *     即单任务上限约 6 条/分钟；可用 LIVEVIEW_MIN_UPDATE_MS 调整。
 *   - **每档只推一次**：同一百分比档位重复推进不再发送（去抖），
 *     保证"进度条不倒退、不抖动"。
 *   - **单调不减**：百分比只增不减，且运行期封顶 CAP_RUNNING(95)
 *     （100 只由完成/结束给出），与客户端 GenProgress 的"未完成不显示 100%"约定一致。
 *   - **超预算放弃**：累计推送超过 LIVEVIEW_MAX_UPDATES（默认 30）后不再推送，
 *     把配额留给"完成/结束"这条最重要的消息。
 *
 * 【与客户端的一致性】
 *   event 必须与创建实况窗时**实际生效**的场景名一致（客户端会把成功的 event 在上报时带上），
 *   否则华为按 80100003 拒收。缺省用 'TIMER'（客户端 EVENTS 首选场景）。
 */
const MIN_UPDATE_MS = Math.max(1000, Number(process.env.LIVEVIEW_MIN_UPDATE_MS || 10000));
const MAX_UPDATES = Math.max(1, Number(process.env.LIVEVIEW_MAX_UPDATES || 30));
/** 未完成时的进度上限（与客户端 GenProgress.CAP_RUNNING 保持一致） */
const CAP_RUNNING = 95;

/**
 * 思考阶段锚点（与客户端 GenProgress.ANCHOR_THINK 一致）。
 *
 * ⚠️ 这里曾经是 10，并配了"思考阶段 0-25%"的注释，但**正文分支会把它整个吃掉**
 *    （正文基线 25 无条件覆盖 10），等于该锚点在正文出现后形同虚设。
 *    已修正为 12，并把正文基线提到 30 —— 详见 ANCHOR_BODY_MIN 的说明。
 */
const ANCHOR_THINK = 12;

/**
 * 正文阶段基线（与客户端 GenProgress.ANCHOR_BODY_MIN 一致）。
 *
 * 【为什么必须是 30 而不是 25 —— 这是一个真实缺陷的修复】
 *   客户端是 `ANCHOR_BODY_MIN + shaped * (95 - ANCHOR_BODY_MIN)`。
 *   服务端若用 25 做基线，正文阶段两端**恒差 5 个百分点**
 *   （实测 plan/totalChars=4000：正文 1 字服务端 25% / 客户端 30%，
 *    200 字 30%/35%，1000 字 47%/50%）。
 *
 *   而两端交替更新是**设计内**行为（客户端本地约 2s 一次、服务端约 10s 一次），
 *   只要客户端领先，服务端下一次推送就会把进度条**往回拉**，
 *   直接破坏 server.js 里"两端内容一致、交替更新不跳变"的承诺，并破坏单调性。
 *   思考模式是本应用默认开启（AppSettings.KEY_THINK），故这是主路径而非边角情况。
 */
const ANCHOR_BODY_MIN = 30;

/* ---------------- 时间滑轨参数（必须与客户端 GenProgress 逐项一致） ---------------- */

/**
 * 为什么服务端要复用**客户端的渐近滑轨**，而不是自己那套"线性推进"：
 *   两端是同一个进度条的交替写入者，形状不一致就会互相拉回。
 *   实测旧线性兜底与客户端差异极大（t=2min 服务端 95% / 客户端 61%），
 *   一旦被推上去就再也下不来。
 *   而客户端滑轨 `3 + 85·t/(t+45s)` 的渐近终值是 88（< 95），
 *   在任何时刻都不足以把已到 95% 的锚点拉回去 —— 取 max 天然安全。
 */
/** 起始百分比：任务一提交就先显示 3% */
const RAMP_START = 3;
/** 渐近终值：无论跑多久，时间滑轨自己最高只到 88% */
const RAMP_ASYMPTOTE = 88;
/** 时间常数：t = TAU 时滑轨约走完 (1-1/e)≈63% 的剩余量 */
const RAMP_TAU_MS = 45000;
/** 硬下限兜底：超过 SLA_FLOOR_MS 还没结束，至少显示 SLA_FLOOR_PCT */
const SLA_FLOOR_MS = 150000;
const SLA_FLOOR_PCT = 78;

/** 各生成类型的内容长度预期（字符），与客户端 GenProgress.EXPECT_CHARS 对齐 */
const EXPECT_CHARS = {
  plan: 4000,
  courseware: 2600,
  quiz: 3000,
  research: 2400,
  analysis: 3200,
  talk: 2000,
  report: 2800
};
const DEFAULT_EXPECT = 3000;

/**
 * 各类型的"预期总耗时"（毫秒），与客户端 GenProgress.EXPECT_MS 对齐。
 *
 * ⚠️ 当前**不参与百分比计算**，仅作记录与诊断导出。
 *    原因见 estimatePercent 里的说明：客户端滑轨用的是**绝对流逝时间**配固定
 *    时间常数 RAMP_TAU_MS(45s)，不随类型缩放。若服务端按类型把时间重新缩放，
 *    两端就不再是同一个钟（实测 t=45s 处偏差 18pp）。宁可这张表暂时用不上，
 *    也不能让两端的进度条互相拉回。
 */
const EXPECT_MS = {
  plan: 110000,
  courseware: 75000,
  quiz: 85000,
  research: 70000,
  analysis: 90000,
  talk: 60000,
  report: 80000
};
const DEFAULT_EXPECT_MS = 90000;

function expectChars(type) {
  const e = EXPECT_CHARS[String(type || '')];
  return e === undefined ? DEFAULT_EXPECT : e;
}

function expectMs(type) {
  const m = EXPECT_MS[String(type || '')];
  return m === undefined ? DEFAULT_EXPECT_MS : m;
}

/**
 * 时间滑轨：ramp(t) = 3 + 85 · t/(t + 45s)，另加 SLA 硬下限 78%。
 * 与客户端 GenProgress.ramp() 为同一公式（跨端防漂移断言会逐项核对常量）。
 *
 * ⚠️ 入参 t 必须是**绝对流逝毫秒数**，不许做任何缩放 —— 见 estimatePercent 的说明。
 */
function ramp(elapsedMs) {
  if (!(elapsedMs > 0)) {
    return RAMP_START;
  }
  const r = elapsedMs / (elapsedMs + RAMP_TAU_MS);
  let v = RAMP_START + (RAMP_ASYMPTOTE - RAMP_START) * r;
  if (elapsedMs >= SLA_FLOOR_MS && v < SLA_FLOOR_PCT) {
    v = SLA_FLOOR_PCT;
  }
  return v;
}

/**
 * 计算进度百分比。
 *
 * 与客户端 GenProgress 保持**同一形状**（两端交替更新时进度条才不跳变）：
 *   - 思考锚点 12%（收到过思考增量）
 *   - 正文锚点 30 → 95（ratio^0.85 缓升），ratio = 已生成长度 / 预期总长度
 *   - 时间滑轨 3 → 88（渐近），与阶段锚点取 max
 *   - 未完成时统一封顶 95，绝不显示 100
 *
 * 【时间滑轨对"客户端被杀"场景尤其关键】
 *   进程被挂起/杀掉后增量回调不再产生，服务端的 content/reasoning 会冻结在最后一帧。
 *   此时只有时间滑轨还能让实况窗继续前进 —— 这正是需求里"被杀后进度仍能推进"的来源。
 *
 * 不变量：ramp(t) ≤ 88 < CAP_RUNNING(95)，故时间滑轨永远无法把已抬高的锚点拉回去，
 *         两端取值天然单调、不会互相倒吸。
 *
 * @returns {number} 0-100 的整数
 */
function estimatePercent(task, state) {
  if (!task) {
    return 0;
  }
  const textLen = String((state && state.content) || '').length;
  const thinkLen = String((state && state.reasoning) || '').length;

  let anchor = 0;
  if (thinkLen > 0) {
    anchor = ANCHOR_THINK;
  }
  if (textLen > 0) {
    const expect = Number(task.liveView && task.liveView.totalChars) > 0
      ? Number(task.liveView.totalChars)
      : expectChars(task.type);
    const ratio = Math.min(1, textLen / expect);
    const body = ANCHOR_BODY_MIN + Math.pow(ratio, 0.85) * (CAP_RUNNING - ANCHOR_BODY_MIN);
    if (body > anchor) {
      anchor = body;
    }
  }

  // ---- 时间滑轨：必须用**绝对流逝时间**，与客户端同一个钟 ----
  //
  // 【这里曾经出过一个真实缺陷】
  //   为了"让客户端上报的 expectedMinutes 生效"，曾把流逝时间按类型期望耗时
  //   重新缩放（elapsed * 45s/spanMs）再喂给滑轨。但客户端的滑轨是
  //   `3 + 85·t/(t+45s)`，t 是**绝对流逝时间**、时间常数固定 45s，从不随类型缩放。
  //   于是两端的时间轴不再是同一个钟：实测 plan 在 t=45s 处服务端 28% / 客户端 46%，
  //   偏差 18pp —— 而服务端落后同样会造成"客户端已涨上去、服务端将来补推更低值"的回拉。
  //   现在直接传原样 elapsed，两端时间项逐点相等（见 test_liveview_progress.js 套件 5b）。
  //
  // 【代价（有意接受）】
  //   expectedMinutes 从此**不再影响百分比计算**，仅作记录/诊断。
  //   换取的是"两端同一个钟"这条更重要的不变量。客户端也确认不应为对齐而改动
  //   其渐近曲线（会丢掉"永不假完成"的语义），故以客户端曲线为准。
  const startedAt = Number(state && state.startedAt) > 0 ? Number(state.startedAt) : Date.now();
  const elapsed = Date.now() - startedAt;
  const rampV = ramp(elapsed);

  let v = Math.max(anchor, rampV);
  if (v > CAP_RUNNING) {
    v = CAP_RUNNING;
  }
  return v < 0 ? 0 : Math.round(v);
}

/**
 * 端点校验：activityId 是定位实况窗的**唯一依据**，无效时绝不能发。
 *
 * ⚠️ 重要（华为原文）：若发送的 activityId 对应的实况窗**不存在**（更新/结束场景），
 *    将限制使用该 activityId 发送实况窗消息 **24 小时**。
 *    因此这里宁可少发也不乱发：activityId/token/凭据任一缺失都直接跳过。
 *
 * @returns {{ok:true,id:number}|{ok:false,reason:string}}
 */
function checkLiveViewTarget({ token, activityId }) {
  if (!configured()) {
    return { ok: false, reason: 'no-credentials' };
  }
  if (!token) {
    return { ok: false, reason: 'no-token' };
  }
  const id = Number(activityId) || 0;
  if (id <= 0) {
    return { ok: false, reason: 'bad-activityId' };
  }
  return { ok: true, id: id };
}

/**
 * 下发一条实况窗消息（push-type 7）。
 *
 * operation: 0 创建（本服务不使用，创建由客户端 Live View Kit 本地完成）、
 *            1 更新、2 结束。
 *
 * 更新时 activityData 整体缺省：华为规定"更新和结束实况窗时，对于非必选字段，
 * 若无特殊说明和默认值，则不携带时默认继承上一次的状态"，因此只带活动标识即可，
 * 客户端本地的图标/节点图资源不必在服务端重复维护一份。
 *
 * @returns {Promise<{ok:boolean,code?:string,status?:number,body?:string,skipped?:boolean}>}
 *          **永不抛出**（结果只经返回值/日志体现）
 */
async function postLiveView({ token, activityId, event, operation, activityData }) {
  const chk = checkLiveViewTarget({ token: token, activityId: activityId });
  if (!chk.ok) {
    console.warn('[push] 跳过实况窗消息（operation=' + operation + '，原因=' + chk.reason + '）');
    return { skipped: true, reason: chk.reason };
  }
  const a = readAccount();
  const url = PUSH_URL + a.projectId + '/messages:send';
  const payload = {
    payload: {
      activityId: chk.id,
      operation: Number(operation),
      // event 必须与创建时一致，否则华为按 80300007/80100003 拒收
      event: String(event || 'TIMER')
    },
    target: { token: [token] },
    pushOptions: {
      testMessage: process.env.AGC_PUSH_TEST === 'true',
      ttl: 86400
    }
  };
  if (activityData) {
    payload.payload.activityData = activityData;
  }
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
    // 与 sendAlert 同理：华为**业务失败也返回 HTTP 200**，必须解析 body.code。
    // 此前只看 resp.ok，把 code != 80000000 的失败也记成"已发送"，掩盖了真实错误。
    let code = '';
    try {
      const j = JSON.parse(text);
      code = String(j.code || '');
    } catch (e) {
      // 响应体非 JSON：保持 code 为空，走失败分支
    }
    if (code === '80000000') {
      return { ok: true, code };
    }
    console.error('[push] 实况窗消息失败 operation=' + operation + ' httpCode=' + resp.status
      + ' code=' + code + ' activityId=' + chk.id + ' body=' + text.slice(0, 300));
    return { ok: false, code, status: resp.status, body: text.slice(0, 300) };
  } catch (e) {
    console.error('[push] 实况窗消息异常 operation=' + operation + ': '
      + (e && e.message ? e.message : String(e)));
    return { ok: false };
  }
}

/**
 * 通过 Push Kit **结束**本地创建的实况窗（push-type 7，operation 2）。
 *
 * 用途：客户端进程在生成途中被系统杀掉时，本地实况窗没人收尾会一直残留；
 *      任务仍在服务端跑完，故由服务端下发结束消息清理。
 *
 * @param {string} token 设备 Push Token
 * @param {number} activityId **业务侧自有**的实况窗标识（= 客户端 LiveView.id）
 * @param {string} event 创建实况窗时实际生效的场景名，必须与之一致
 */
async function sendLiveViewEnd({ token, activityId, event }) {
  const r = await postLiveView({
    token: token,
    activityId: activityId,
    event: event,
    operation: 2
  });
  if (r && r.ok) {
    console.log('[push] 实况窗结束消息已发送 activityId=' + (Number(activityId) || 0)
      + ' event=' + String(event || 'TIMER'));
  }
  return r;
}

/**
 * 通过 Push Kit **更新**实况窗进度（push-type 7，operation 1）。
 *
 * 这是"App 退到后台/被杀，桌面实况窗仍实时显示生成进度"的服务端半边：
 * 客户端本地更新依赖 App 进程存活，进程被挂起或回收后进度条就停住了；
 * 由服务端按进度节奏补推更新消息，系统直接刷新实况窗，无需 App 进程参与。
 *
 * 与 sendLiveViewEnd 的区别仅在 operation（1=更新，2=结束），**切勿写反**：
 * 写反会把正在生成的实况窗提前结束掉。两个函数共用 postLiveView，避免分叉。
 *
 * @param {string} token 设备 Push Token
 * @param {number} activityId 客户端创建的实况窗 id（必须已存在，否则会被限用 24h）
 * @param {string} event 与创建时一致的场景名（缺省 TIMER）
 * @param {number} percent 进度百分比 0-100（内部会取整并夹到 [0,100]）
 * @param {string} [title] 卡片标题；缺省不携带（继承上一次状态）
 */
async function sendLiveViewUpdate({ token, activityId, event, percent, title }) {
  const pct = Math.max(0, Math.min(100, Math.round(Number(percent) || 0)));
  const activityData = {
    notificationData: {
      // type = 3：进度可视化布局（与客户端 LAYOUT_TYPE_PROGRESS 同族）
      type: 3,
      contentTitle: String(title || ''),
      contentText: [{ text: pct + '%' }],
      // 进度可视化布局用 richProgress：progress 即百分比，nodeIcons 取客户端 rawfile 资源名
      richProgress: {
        type: 0,
        nodeIcons: ['liveview/node_done.png', 'liveview/node_todo.png'],
        indicatorIcon: 'liveview/liveview_icon.png',
        progress: pct,
        indicatorType: 0,
        color: '#FF4A90D9',
        bgColor: '#FFE5E5E5'
      }
    },
    capsuleData: {
      // type = 1：胶囊；胶囊用 progressData，字段取值以官方示例为准（0/1，非 SDK 枚举值 4/3）
      type: 1,
      status: 1,
      icon: 'liveview/liveview_icon.png',
      bgColor: '#FF2B3A4A',
      progressData: {
        max: 100,
        progress: pct,
        indeterminate: false,
        content: pct + '%'
      }
    }
  };
  const r = await postLiveView({
    token: token,
    activityId: activityId,
    event: event,
    operation: 1,
    activityData: activityData
  });
  if (r && r.ok) {
    console.log('[push] 实况窗进度已更新 activityId=' + (Number(activityId) || 0)
      + ' event=' + String(event || 'TIMER') + ' progress=' + pct + '%');
  }
  return r;
}

/**
 * 创建一个"按进度节流"的调度器（每个任务一个实例，server.js 持有）。
 *
 * 把节流逻辑放在 push.js 而不是 server.js，是为了让**离线回归测试可以直接构造它**：
 * 测试不需要启动 HTTP 服务，也不需要真的联网。
 *
 * @param {object} opts
 * @param {number} [opts.minIntervalMs] 两次更新之间的最小间隔（默认 MIN_UPDATE_MS）
 * @param {number} [opts.maxUpdates]   单任务最多推送条数（默认 MAX_UPDATES）
 * @returns {{consider:Function, reset:Function}}
 *   consider(percent, now) -> {send:boolean, reason:string, percent:number, seq:number}
 *   reset()  -> void（任务结束时释放该任务的节流状态，避免内存泄漏）
 */
function createThrottle(opts) {
  const o = opts || {};
  const minInterval = Number(o.minIntervalMs) > 0 ? Number(o.minIntervalMs) : MIN_UPDATE_MS;
  const maxUpdates = Number(o.maxUpdates) > 0 ? Number(o.maxUpdates) : MAX_UPDATES;
  const state = new Map(); // taskId -> { pct, at, seq, count }

  return {
    /**
     * 判断"这个进度点值不值得发一条推送"。
     * 纯函数式判定（不改网络状态），但会推进内存中的节流游标。
     */
    consider: function (taskId, percent, now) {
      const id = String(taskId || '');
      const t = Number.isFinite(Number(now)) ? Number(now) : Date.now();
      const cur = state.get(id) || { pct: -1, at: 0, seq: 0, count: 0 };
      const pct = Math.max(0, Math.min(100, Math.round(Number(percent) || 0)));

      if (cur.count >= maxUpdates) {
        // 配额用尽：留额度给"结束"消息，避免把每日配额耗在中间进度上
        return { send: false, reason: 'max-updates', percent: pct, seq: cur.seq };
      }
      if (pct <= cur.pct) {
        // 进度没有前进：不推（进度条不倒退、不抖动）
        return { send: false, reason: 'no-progress', percent: pct, seq: cur.seq };
      }
      if (cur.at > 0 && t - cur.at < minInterval) {
        // 距上次推送太近：等下一次触发再合并发送（天然去抖）
        return { send: false, reason: 'too-soon', percent: pct, seq: cur.seq };
      }
      cur.pct = pct;
      cur.at = t;
      cur.seq += 1;
      cur.count += 1;
      state.set(id, cur);
      return { send: true, reason: 'ok', percent: pct, seq: cur.seq };
    },
    reset: function (taskId) {
      state.delete(String(taskId || ''));
    },
    /** 只读快照（测试/排查用） */
    peek: function (taskId) {
      return Object.assign({}, state.get(String(taskId || '')) || { pct: -1, at: 0, seq: 0, count: 0 });
    }
  };
}

module.exports = {
  sendAlert,
  sendLiveViewEnd,
  sendLiveViewUpdate,
  configured,
  // ---- 供 server.js 的节流调度与离线测试使用 ----
  createThrottle: createThrottle,
  estimatePercent: estimatePercent,
  expectChars: expectChars,
  expectMs: expectMs,
  /** 阶段锚点/上限常量：跨端防漂移断言与 server.js 诊断用 */
  anchors: {
    ANCHOR_THINK: ANCHOR_THINK,
    ANCHOR_BODY_MIN: ANCHOR_BODY_MIN,
    CAP_RUNNING: CAP_RUNNING,
    RAMP_START: RAMP_START,
    RAMP_ASYMPTOTE: RAMP_ASYMPTOTE,
    RAMP_TAU_MS: RAMP_TAU_MS,
    SLA_FLOOR_MS: SLA_FLOOR_MS,
    SLA_FLOOR_PCT: SLA_FLOOR_PCT
  },
  liveViewConfig: {
    MIN_UPDATE_MS: MIN_UPDATE_MS,
    MAX_UPDATES: MAX_UPDATES,
    CAP_RUNNING: CAP_RUNNING
  }
};
