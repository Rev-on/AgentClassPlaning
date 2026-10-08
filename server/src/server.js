/**
 * Rev TechingMaster AI 中转代理服务
 *
 * 职责：App 不再携带 DeepSeek API Key，改为请求本服务；
 *       本服务持有密钥并向 DeepSeek 转发补全请求。
 *
 * 接口：
 *   GET  /health               健康检查
 *   POST /v1/chat/completions  与 App 现有调用完全兼容的透传接口
 *   POST /api/chat             简化接口：{ system?, user } -> 返回 OpenAI 格式结果
 *   POST /api/task             提交后台生成任务（杀进程仍继续，完成后 Push 通知）
 *   GET  /api/task/:id         查询任务状态与结果
 *   GET  /api/tasks?deviceId=  按设备列出最近任务
 *   POST /api/push/register    上报设备 Push Token
 *   GET  /api/push/devices     读回已注册设备的 Push Token（默认打码；?full=1 明文）
 *                              —— 供 server/tools/get_device_token.js 使用
 *                              （Token 只能在 App 进程内由 PushKit 申请，外部脚本
 *                                无法自行获取，只能读回服务端已存的那份）
 *   POST /api/data/delete      删除本设备在服务端保存的全部数据（任务 + 设备注册记录）
 *   POST /api/push/receipt     接收华为 Push Kit 消息回执（华为服务器回调）
 *   GET  /api/push/receipt/stats 回执统计（调试用，需代理令牌）
 *
 * 启动：cp .env.example .env 并填写密钥，然后 npm start
 */
require('dotenv').config();
const express = require('express');
const cors = require('cors');
const fs = require('fs');
const http = require('http');
const https = require('https');
const tasks = require('./tasks');
const push = require('./push');
const pushReceipt = require('./pushReceipt');
const rag = require('./rag');

/** 消息推送总开关：客户端已取消通知/推送功能，默认关闭；如需重新启用设环境变量 PUSH_ENABLED=1 */
const PUSH_ENABLED = process.env.PUSH_ENABLED === '1';

/**
 * 向某设备的**全部有效 token** 推送完成通知，并清理失效 token。
 *
 * 为什么不是只推最新一条：
 *   同一用户可能因重装/换机在服务端留下多条 token 记录；只推最新一条时，
 *   若那条恰好失效，整条通知就丢失了（而且日志里仍是"已受理"，很难发现）。
 *   改为广播后，只要有一条 token 有效，通知就能送达。
 *
 * 失效清理：
 *   华为对无效 token 返回 code=80300007 并在 msg 里给出 illegalTokens；
 *   据此把对应记录删掉，避免每次任务完成都重复无效推送。
 *
 * @param {string} deviceId 设备标识
 * @param {{notifyId:number,title:string,body:string,data:object}} msg 通知内容
 */
async function pushToDevice(deviceId, msg) {
  const all = tasks.listDevices();
  const tid = String(deviceId || '');
  // 优先推该设备自己的 token；若查不到（如记录被清理）则回退到全部有效 token
  const mine = all.filter((d) => d.id === tid);
  const targets = mine.length > 0 ? mine : all;
  if (targets.length === 0) {
    console.warn('[push] 无有效设备 token，跳过通知 deviceId=' + tid);
    return;
  }
  const dead = [];
  for (const d of targets) {
    try {
      const r = await push.sendAlert({
        token: d.token,
        notifyId: msg.notifyId,
        title: msg.title,
        body: msg.body,
        data: msg.data
      });
      if (r && r.ok) {
        // 华为受理即认为该 token 可用，无需继续试其它 token
        if (dead.length > 0) {
          tasks.forgetInvalidTokens(dead);
        }
        return;
      }
      if (r && r.illegalTokens && r.illegalTokens.length > 0) {
        for (const t of r.illegalTokens) {
          dead.push(t);
        }
      }
    } catch (e) {
      console.error('[push] 发送异常 deviceId=' + d.id + ' err='
        + String(e && e.message || e));
    }
  }
  if (dead.length > 0) {
    tasks.forgetInvalidTokens(dead);
  }
  console.error('[push] 全部 token 推送失败 deviceId=' + tid + ' 尝试数=' + targets.length);
}

const PORT = Number(process.env.PORT || 3000);
// 监听地址。默认 '::' = IPv6 双栈：
//   Linux 默认 net.ipv6.bindv6only=0，绑定 :: 时同一 socket 也接受 IPv4
//   （对端显示为 ::ffff:x.x.x.x），因此一份配置即可同时服务 IPv4/IPv6 客户端。
//   若显式设为 0.0.0.0 则只监听 IPv4，纯 IPv6 客户端将无法连接。
const HOST = process.env.HOST || '::';
// TLS 配置：证书文件存在（或用 SSL_CERT/SSL_KEY 覆盖路径）即自动启用 HTTPS 监听 PORT
const SSL_CERT = process.env.SSL_CERT || '/etc/ssl/rev-on.site/server.pem';
const SSL_KEY = process.env.SSL_KEY || '/etc/ssl/rev-on.site/private_key.pem';
const TLS_ENABLED = process.env.TLS_ENABLED === undefined
  ? (fs.existsSync(SSL_CERT) && fs.existsSync(SSL_KEY))
  : (process.env.TLS_ENABLED === 'true');
// TLS 开启时可保留的明文端口（平滑迁移用），默认 0 = 不额外监听
const HTTP_PORT = Number(process.env.HTTP_PORT || 0);
const UPSTREAM = process.env.UPSTREAM_URL || 'https://api.deepseek.com/chat/completions';
const MODEL = process.env.MODEL || 'deepseek-flash';
// 深度思考强度（仅当客户端开启"深度思考"时生效）：high | max
const THINK_EFFORT = process.env.THINKING_EFFORT || 'high';
const API_KEY = process.env.DEEPSEEK_API_KEY || '';
const PROXY_TOKEN = process.env.PROXY_TOKEN || '';
const TIMEOUT_MS = Number(process.env.REQUEST_TIMEOUT_MS || 600000);
const RATE_PER_MIN = Number(process.env.RATE_LIMIT_PER_MIN || 120);

const app = express();
app.disable('x-powered-by');
app.use(cors({
  origin: true,
  methods: ['GET', 'POST', 'OPTIONS'],
  allowedHeaders: ['Content-Type', 'x-proxy-token']
}));
// 附件（图片 base64）随任务一起提交，最大 10 个，单请求体积上限相应放宽
app.use(express.json({ limit: '64mb' }));

// 简易内存限流（按来源 IP，每分钟 N 次）
const hits = new Map();
app.use((req, res, next) => {
  const ip = req.ip || 'unknown';
  const now = Date.now();
  const windowHits = (hits.get(ip) || []).filter((t) => now - t < 60000);
  if (windowHits.length >= RATE_PER_MIN) {
    res.status(429).json({ error: { message: '请求过于频繁，请稍后再试' } });
    return;
  }
  windowHits.push(now);
  hits.set(ip, windowHits);
  next();
});

app.get('/health', (req, res) => {
  res.json({ ok: true, time: new Date().toISOString() });
});

/** 校验代理令牌（设置了 PROXY_TOKEN 时生效） */
function checkToken(req, res, next) {
  if (PROXY_TOKEN) {
    const got = req.get('x-proxy-token');
    if (got !== PROXY_TOKEN) {
      res.status(401).json({ error: { message: '代理令牌无效' } });
      return;
    }
  }
  next();
}

/** 转发到 DeepSeek（透传响应体与状态码；stream=true 时 SSE 逐块透传） */
async function relay(req, res) {
  if (!API_KEY) {
    res.status(500).json({ error: { message: '服务端未配置 DEEPSEEK_API_KEY' } });
    return;
  }
  const body = req.body || {};
  if (!Array.isArray(body.messages) || body.messages.length === 0) {
    res.status(400).json({ error: { message: 'messages 不能为空' } });
    return;
  }
  const out = Object.assign({}, body);
  if (out.stream === undefined) {
    out.stream = false; // 默认非流式（教案等长文本场景）
  }
  // 深度思考：客户端只需传 thinking.type，思考强度由服务端统一补齐
  if (out.thinking && out.thinking.type === 'enabled' && out.reasoning_effort === undefined) {
    out.reasoning_effort = THINK_EFFORT;
  }
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), TIMEOUT_MS);
  // 客户端在响应结束前断开时才中止上游（避免正常 keep-alive 下误触发）
  res.on('close', () => {
    if (!res.writableEnded) {
      ctrl.abort();
    }
  });
  try {
    const resp = await fetch(UPSTREAM, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ' + API_KEY
      },
      body: JSON.stringify(out),
      signal: ctrl.signal
    });
    // ---- 流式：SSE 透传，不缓冲 ----
    if (out.stream === true && resp.body) {
      const ctype = resp.headers.get('content-type') || 'text/event-stream';
      res.writeHead(resp.status || 200, {
        'Content-Type': ctype,
        'Cache-Control': 'no-cache',
        'Connection': 'keep-alive',
        'X-Accel-Buffering': 'no'
      });
      const reader = resp.body.getReader();
      const pump = async () => {
        try {
          for (;;) {
            const { done, value } = await reader.read();
            if (done) {
              break;
            }
            if (value && value.length > 0) {
              res.write(Buffer.from(value));
            }
          }
        } catch (e) {
          // 客户端中止或上游中断：直接结束响应
        } finally {
          clearTimeout(timer);
          res.end();
        }
      };
      pump();
      return;
    }
    const text = await resp.text();
    res.status(resp.status).type('application/json').send(text || '{}');
  } catch (e) {
    const isAbort = e && e.name === 'AbortError';
    console.error('[rev-ai-proxy] relay error name=' + (e && e.name) +
      ' msg=' + (e && e.message ? String(e.message) : '') +
      ' abort=' + isAbort + ' url=' + UPSTREAM);
    const msg = isAbort
      ? '上游请求超时'
      : ('上游请求失败：' + (e && e.message ? e.message : '未知错误'));
    res.status(502).json({ error: { message: msg } });
  } finally {
    clearTimeout(timer);
  }
}

// 与 App 现有请求体完全兼容的透传接口
app.post('/v1/chat/completions', checkToken, (req, res) => {
  relay(req, res);
});

// 简化接口：{ system?, user }
app.post('/api/chat', checkToken, (req, res) => {
  const data = req.body || {};
  const user = typeof data.user === 'string' ? data.user : '';
  if (user.trim() === '') {
    res.status(400).json({ error: { message: 'user 不能为空' } });
    return;
  }
  const messages = [];
  if (typeof data.system === 'string' && data.system.trim() !== '') {
    messages.push({ role: 'system', content: data.system });
  }
  // 直连回退路径同样支持附件（图片走多模态，文档文本并入 user 内容）
  const relayAtts = normalizeAttachments(data.attachments);
  // 同样挂载新课标依据（缺省从 user 文本解析学科/年级）
  const relayRag = ragFor(user, relayAtts, data.subject, data.grade);
  messages.push({ role: 'user', content: buildUserContent(user, relayAtts, relayRag ? relayRag.block : '') });
  req.body = Object.assign({}, data, { messages: messages });
  relay(req, res);
});

/* ===================== 后台生成任务 ===================== */

/** 调用 DeepSeek 生成完整文本（非流式） */
async function fetchDeepSeek(system, user) {
  if (!API_KEY) {
    throw new Error('服务端未配置 DEEPSEEK_API_KEY');
  }
  const messages = [];
  if (system && system.trim() !== '') {
    messages.push({ role: 'system', content: system });
  }
  messages.push({ role: 'user', content: user });
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), TIMEOUT_MS);
  try {
    const resp = await fetch(UPSTREAM, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ' + API_KEY
      },
      body: JSON.stringify({ model: MODEL, messages: messages, stream: false }),
      signal: ctrl.signal
    });
    const text = await resp.text();
    if (!resp.ok) {
      throw new Error('上游返回 ' + resp.status + ': ' + text.slice(0, 200));
    }
    let data = {};
    try {
      data = JSON.parse(text);
    } catch (e) {
      throw new Error('上游响应解析失败');
    }
    const content = data && data.choices && data.choices[0] &&
      data.choices[0].message && data.choices[0].message.content;
    if (typeof content !== 'string' || content.trim() === '') {
      throw new Error('上游未返回内容');
    }
    return content;
  } catch (e) {
    if (e && e.name === 'AbortError') {
      throw new Error('上游请求超时');
    }
    throw e;
  } finally {
    clearTimeout(timer);
  }
}

/* ===================== 任务流式输出（SSE feed） ===================== */
/** taskId -> 附件数组（仅驻内存：图片 base64 体积大，不写入 tasks.json 状态文件） */
const taskAttachments = new Map();
/** 单任务附件数量上限（与客户端一致） */
const MAX_ATTACH = 10;

/** 校验/裁剪客户端提交的附件：image(data=base64 或完整 dataURL) / text(已解析文本) / file(仅文件名) */
function normalizeAttachments(raw) {
  const out = [];
  if (!Array.isArray(raw)) {
    return out;
  }
  for (const a of raw.slice(0, MAX_ATTACH)) {
    if (!a || typeof a !== 'object') {
      continue;
    }
    const name = String(a.name || '附件');
    if (a.kind === 'image') {
      let data = typeof a.data === 'string' ? a.data : '';
      if (data === '') {
        continue;
      }
      // 客户端可传完整 dataURL（带正确 mime）；裸 base64 时按 jpeg 兜底
      if (data.indexOf('data:') !== 0) {
        data = 'data:image/jpeg;base64,' + data;
      }
      out.push({ kind: 'image', name: name, data: data });
    } else if (a.kind === 'text') {
      const text = typeof a.text === 'string' ? a.text : '';
      if (text.trim() === '') {
        continue;
      }
      out.push({ kind: 'text', name: name, text: text.slice(0, 60000) });
    } else {
      out.push({ kind: 'file', name: name });
    }
  }
  return out;
}

/**
 * 构造 user 消息内容：
 *  - 无图片 -> 纯文本（附件使用指令 + 正文 + 文档附件解析文本 + 未解析附件说明）
 *  - 有图片 -> OpenAI 兼容多模态数组（text + image_url 若干），供视觉模型识别
 *  说明：DeepSeek 视觉能力仅 vision 模型可用，image_url 支持 data URL（见官方 Vision 指南）；
 *        实测若不显式要求"必须使用附件"，模型容易只按文字要求作答而忽略附件内容，故此处注入强指令。
 */
function buildUserContent(user, atts, ragBlock) {
  const images = atts.filter((a) => a.kind === 'image');
  const texts = atts.filter((a) => a.kind === 'text');
  const files = atts.filter((a) => a.kind === 'file');
  let head = '';
  if (atts.length > 0) {
    head += '【本次提交的附件（必须使用）】共 ' + atts.length + ' 个。'
      + '请先完整读取并理解全部附件内容，再结合下方的文字要求生成结果；'
      + '生成结果必须体现附件中的关键信息（图片里的文字/公式/图表/板书，文档里的要点与硬性要求），不得忽略或只按文字要求作答。\n';
    if (images.length > 0) {
      head += '· 图片 ' + images.length + ' 张：' + images.map((a) => a.name).join('、')
        + '（请逐张识别图中文字与结构，识别到的内容必须落入生成结果）\n';
    }
    if (texts.length > 0) {
      head += '· 文档 ' + texts.length + ' 个：' + texts.map((a) => a.name).join('、')
        + '（已解析为文本，见下方【附件：文件名】段落，其中的要求优先级最高）\n';
    }
    if (files.length > 0) {
      head += '· 其他附件 ' + files.length + ' 个：' + files.map((a) => a.name).join('、')
        + '（暂无法解析内容，请结合文件名理解）\n';
    }
    head += '\n';
  }
  let text = head + user;
  for (const a of atts) {
    if (a.kind === 'text') {
      text += '\n\n【附件：' + a.name + '】\n' + a.text;
    } else if (a.kind === 'file') {
      text += '\n\n【附件：' + a.name + '】（该格式暂不支持内容解析，请结合文件名与用户描述理解）';
    }
  }
  // 新课标 RAG 依据块放在最后：最终指令靠后，模型遵循度更高
  if (ragBlock && ragBlock !== '') {
    text += '\n\n' + ragBlock;
  }
  if (images.length === 0) {
    return text;
  }
  const parts = [{ type: 'text', text: text }];
  for (const im of images) {
    // detail: high 保留原图细节，利于识别图片中的文字、公式与图表
    parts.push({ type: 'image_url', image_url: { url: im.data, detail: 'high' } });
  }
  return parts;
}

/** 附件文本汇总（仅取文档类附件，用于 RAG 查询扩展） */
function attachmentsText(atts) {
  let s = '';
  for (const a of atts) {
    if (a.kind === 'text' && a.text) {
      s += ' ' + a.text.slice(0, 1500);
    }
  }
  return s;
}

/**
 * 为一次生成请求检索新课标依据
 * @returns {{block:string, info:object}|null}
 */
function ragFor(user, atts, subject, grade) {
  if (!rag.isReady()) {
    return null;
  }
  try {
    const res = rag.buildBlock({
      user: user,
      subject: subject,
      grade: grade,
      extraText: attachmentsText(atts)
    });
    if (res && res.info) {
      console.log('[rag] 命中 学科=' + (res.info.subjectName || '未识别') +
        ' 学段=' + (res.info.stage || '-') + ' 年级=' + (res.info.grade || '-') +
        ' 条目=' + res.info.hits.length + ' 注入=' + res.info.blockChars + '字' +
        ' 路由=' + (res.info.source || '-'));
    }
    return res;
  } catch (e) {
    console.error('[rag] 检索异常：' + (e && e.message ? e.message : String(e)));
    return null;
  }
}

/** taskId -> { ctrl: AbortController, manual: boolean }（取消任务用） */
const taskAborters = new Map();
/** taskId -> Set<res>（feed 订阅连接） */
const feedSubs = new Map();
/** taskId -> 运行中已累积的思考文本（深度思考；供 feed 重连时补齐） */
const taskReasoning = new Map();

/* ===================== 实况窗进度：服务端侧持续推进 ===================== */

/**
 * 为什么要有这一段（用户需求的核心）：
 *   实况窗（Live View）默认由 App 自己用 liveViewManager.updateLiveView 本地更新，
 *   而本地更新的前提是 **App 进程活着**。用户把应用退到后台后进程可能被挂起，
 *   甚至被系统回收 —— 此时客户端更新链路彻底断掉，桌面实况窗的进度条就卡住不动。
 *   任务其实还在服务端跑，因此由**服务端**通过 Push Kit（push-type 7 / operation 1）
 *   补推进度更新，系统直接刷新实况窗，不依赖 App 进程存活。
 */

/**
 * 任务运行时状态（仅内存，不落盘）。
 *
 * 为什么不写进 tasks.json：进度推送是**纯运行时行为**，写盘既无必要（进程重启后
 * 任务本来就不再运行、也不会再推），又会让 flushPersist/防抖快照多出一堆噪声字段。
 * 附件 base64（taskAttachments）与思维链（taskReasoning）出于同样理由只驻内存。
 */
const liveViewFeedback = new Map(); // taskId -> { content, reasoning, startedAt }

/** 节流游标（任务结束/被删除时必须 reset，否则内存泄漏） */
const liveViewThrottle = push.createThrottle();

/**
 * 尝试为任务推送一次实况窗进度。
 *
 * 容错原则（与既有通知/实况窗逻辑一致）：
 *   - **绝不抛出**：任何异常只写 console 日志。实况窗是锦上添花，
 *     不能因为推送失败影响任务生成本身。
 *   - **未配置凭据静默跳过**：push.configured() 为 false 时什么都不发
 *     （sendLiveViewUpdate 内部还会再兜一次底）。
 *   - **只在真正开推时才需要 token**：未绑实况窗的任务连设备查询都不做，
 *     避免每次增量都白跑一遍 listDevices()。
 *
 * 与客户端的分工：
 *   客户端进程活着时由它本地更新（粒度更细，约 2s 一次）；服务端在节流窗口到期时补推。
 *   两端写入的是**同一个进度条**，因此公式必须逐项一致 —— 否则服务端一推就把
 *   客户端刚推进的进度**往回拉**（曾因正文基线差 5pp 真实发生过，
 *   详见 push.js estimatePercent 的注释与 test_liveview_progress.js 的跨端断言）。
 */
function maybeSendLiveViewUpdate(taskId, task) {
  if (!PUSH_ENABLED) {
    // 与完成通知共用同一总开关：PUSH_ENABLED 未开时连推送分支都不进
    //（排查时"日志里完全没有实况窗字样"就是这一条）
    return;
  }
  try {
    if (!task || !task.liveView) {
      return; // 客户端未上报实况窗（未创建/创建失败），无需推送
    }
    if (!push.configured()) {
      return; // 未配置 AGC 凭据：静默跳过
    }
    const st = liveViewFeedback.get(taskId);
    if (!st) {
      return; // 尚未开始生成
    }
    const pct = push.estimatePercent(task, st);
    const decision = liveViewThrottle.consider(taskId, pct, Date.now());
    if (!decision.send) {
      return; // 节流：太频繁 / 进度未前进 / 配额用尽
    }
    const token = tasks.tokenOf(task.deviceId);
    if (!token) {
      // 设备 Push Token 缺失（未上报或已被清理）：跳过。
      // 注意游标已被 consider() 推进 —— 这是有意的：若这里回滚游标，
      // 后续每个增量都会重算一遍，等于把节流关掉了。
      console.warn('[push] 无 Push Token，跳过实况窗进度推送 deviceId=' + task.deviceId);
      return;
    }
    if (!st.dispatched) {
      st.dispatched = true;
      // 只打一次：生成过程中增量回调极多，逐条打日志会把日志刷爆
      console.log('[rev-ai-proxy] 实况窗进度推送已启用 taskId=' + taskId
        + ' activityId=' + task.liveView.activityId
        + ' 最小间隔=' + push.liveViewConfig.MIN_UPDATE_MS + 'ms');
    }
    push.sendLiveViewUpdate({
      token: token,
      activityId: task.liveView.activityId,
      // 与创建实况窗时实际生效的 event 一致；缺省 TIMER
      //（PROGRESS 是布局类型不是场景名，传它会被华为拒收）
      event: task.liveView.event || 'TIMER',
      percent: decision.percent,
      title: task.label
    }).catch((e) => {
      // sendLiveViewUpdate 内部已兜底不抛，这里是第二道保险
      console.error('[push] 实况窗进度推送失败 taskId=' + taskId + ' err='
        + String((e && e.message) || e));
    });
  } catch (e) {
    console.error('[push] 实况窗进度调度异常 taskId=' + taskId + ' err='
      + String((e && e.message) || e));
  }
}

/** 任务结束（完成/失败/取消）时释放该任务的实况窗运行时状态 */
function liveViewFeedbackDone(taskId) {
  liveViewFeedback.delete(taskId);
  liveViewThrottle.reset(taskId);
}

/**
 * 任务被过期清理时，同步释放以 taskId 为键的旁挂内存 Map。
 *
 * 为什么需要：tasks.js 只知道自己那张 tasks 表；server.js 里还旁挂了
 * taskAttachments（附件 base64，体积最大）、taskReasoning（思维链）、
 * taskAborters、feedSubs。任务从 tasks 表删掉后如果不同步删这些键，
 * 它们会永久残留 —— 尤其是从未被消费的附件（任务在 pending 中进程重启等），
 * 属于实打实的内存泄漏。同时把仍未结束的 feed 连接结束掉，避免客户端挂死等待。
 */
tasks.setTaskPurgeHook((taskId) => {
  taskAttachments.delete(taskId);
  taskReasoning.delete(taskId);
  taskAborters.delete(taskId);
  liveViewFeedback.delete(taskId); // 实况窗进度节流游标
  feedClose(taskId); // 内部会 res.end() 所有订阅连接并删除 feedSubs 中的键
});

function feedSend(taskId, event, obj) {
  const subs = feedSubs.get(taskId);
  if (!subs) {
    return;
  }
  const line = 'event: ' + event + '\ndata: ' + JSON.stringify(obj) + '\n\n';
  for (const res of subs) {
    try {
      res.write(line);
    } catch (e) {
      // ignore
    }
  }
}

/** 任务结束：结束所有 feed 连接并清理状态 */
function feedClose(taskId) {
  const subs = feedSubs.get(taskId);
  if (subs) {
    for (const res of subs) {
      try {
        res.end();
      } catch (e) {
        // ignore
      }
    }
    feedSubs.delete(taskId);
  }
  taskAborters.delete(taskId);
}

/**
 * 流式调用 DeepSeek：完整返回 { content, reasoning }，同时把每个增量片段回调
 * onDelta（正文）/ onThink（思考过程），可被 cancel 中断。
 * task.thinking === true 时启用思维链（深度思考），否则关闭（快速模式）。
 */
async function fetchDeepSeekStreamed(task, onDelta, onThink) {
  if (!API_KEY) {
    throw new Error('服务端未配置 DEEPSEEK_API_KEY');
  }
  const ab = { ctrl: new AbortController(), manual: false };
  taskAborters.set(task.id, ab);
  const timer = setTimeout(() => {
    if (!ab.manual) {
      ab.ctrl.abort();
    }
  }, TIMEOUT_MS);
  const decoder = new TextDecoder('utf-8');
  let buf = '';
  let full = '';
  let reason = '';
  let prev = 0;
  let prevR = 0;
  const flushRemain = () => {
    if (reason.length > prevR) {
      const piece = reason.slice(prevR);
      prevR = reason.length;
      if (onThink) {
        onThink(piece);
      }
    }
    if (full.length > prev) {
      const piece = full.slice(prev);
      prev = full.length;
      onDelta(piece);
    }
  };
  // 实况窗进度推送的"心跳"：随 150ms 的增量 flush 一起走。
  // 放在这里而不是每个 delta 上，是为了复用同一个节拍、且天然按节流窗口合并。
  const flushLiveView = () => {
    const st = liveViewFeedback.get(task.id);
    if (st) {
      st.content = full;
      st.reasoning = reason;
    }
    maybeSendLiveViewUpdate(task.id, tasks.get(task.id) || task);
  };
  try {
    const atts = taskAttachments.get(task.id) || [];
    // 新课标依据：题目/备注 -> 学科索引路由 -> 内容索引检索
    const ragRes = ragFor(String(task.user || ''), atts, task.subject, task.grade);
    if (ragRes && ragRes.info) {
      tasks.patch(task.id, { rag: ragRes.info });
    }
    const messages = [];
    if (task.system && String(task.system).trim() !== '') {
      let sys = String(task.system);
      if (ragRes && !(ragRes.info && ragRes.info.notIndexed)) {
        sys += '\n\n【硬性要求】本次请求附带了《义务教育课程标准（2022年版）》的检索片段'
          + '（见用户消息末尾的"课标依据"块）。教学设计必须以该课标为依据，'
          + '不得使用其他版本的课标或编造课标条文。';
      } else if (ragRes) {
        sys += '\n\n【硬性要求】本学科的课标未纳入系统课标库，'
          + '严禁编造或凭记忆引用该学科课标条文（详见用户消息末尾的说明）。';
      }
      messages.push({ role: 'system', content: sys });
    }
    messages.push({
      role: 'user',
      content: buildUserContent(String(task.user || ''), atts, ragRes ? ragRes.block : '')
    });
    const payload = {
      model: MODEL,
      messages: messages,
      stream: true,
      // 深度思考开关：关闭时跳过思维链直接输出（快速模式，响应更快）
      thinking: { type: task.thinking === true ? 'enabled' : 'disabled' }
    };
    if (task.thinking === true) {
      payload.reasoning_effort = THINK_EFFORT;
    }
    const resp = await fetch(UPSTREAM, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ' + API_KEY
      },
      body: JSON.stringify(payload),
      signal: ab.ctrl.signal
    });
    if (!resp.ok) {
      const t = await resp.text();
      throw new Error('上游返回 ' + resp.status + ': ' + String(t).slice(0, 200));
    }
    if (!resp.body) {
      throw new Error('上游未返回流式内容');
    }
    const reader = resp.body.getReader();
    const flushTimer = setInterval(flushRemain, 150);
    const lvTimer = setInterval(flushLiveView, 3000);
    try {
      for (;;) {
        const { done, value } = await reader.read();
        if (done) {
          break;
        }
        if (!value || value.length === 0) {
          continue;
        }
        buf += decoder.decode(value, { stream: true });
        let idx;
        while ((idx = buf.indexOf('\n\n')) >= 0) {
          const ev = buf.slice(0, idx);
          buf = buf.slice(idx + 2);
          const lines = ev.split('\n');
          for (const ln of lines) {
            if (!ln.startsWith('data:')) {
              continue;
            }
            const data = ln.slice(5).trim();
            if (data === '' || data === '[DONE]') {
              continue;
            }
            try {
              const j = JSON.parse(data);
              const delta = j && j.choices && j.choices[0] && j.choices[0].delta;
              if (!delta) {
                continue;
              }
              // 思考过程（深度思考开启时才有）：与正文分流，单独回传
              if (typeof delta.reasoning_content === 'string') {
                reason += delta.reasoning_content;
              }
              if (typeof delta.content === 'string') {
                full += delta.content;
              }
            } catch (e) {
              // 忽略非 JSON 心跳/注释行
            }
          }
        }
      }
    } finally {
      clearInterval(flushTimer);
      clearInterval(lvTimer);
    }
    flushRemain();
    if (full.trim() === '') {
      throw new Error('上游未返回内容');
    }
    return { content: full, reasoning: reason };
  } catch (e) {
    if (e && e.name === 'AbortError') {
      if (ab.manual) {
        throw new Error('任务已取消');
      }
      throw new Error('上游请求超时');
    }
    throw e;
  } finally {
    clearTimeout(timer);
    if (taskAborters.get(task.id) === ab) {
      taskAborters.delete(task.id);
    }
    // 附件仅在生成期间需要，结束即释放，避免大 base64 常驻内存
    taskAttachments.delete(task.id);
  }
}

/** 串行执行一个任务：流式生成 -> 保存 -> SSE 广播增量 -> 结束广播 */
function runTask(taskId) {
  const task = tasks.get(taskId);
  if (!task) {
    return;
  }
  tasks.enqueue(async () => {
    tasks.patch(taskId, { status: tasks.STATUS.RUNNING });
    taskReasoning.set(taskId, '');
    // 初始化实况窗进度状态：
    // startedAt 用于"既无思考也无正文"时的按时间线性推进 —— 客户端进程被挂起/杀掉后，
    // 服务端仍能靠时间给出一个不动的进度，而不是永远停在 0%。
    liveViewFeedback.set(taskId, { content: '', reasoning: '', startedAt: Date.now(), dispatched: false });
    try {
      const res = await fetchDeepSeekStreamed(task,
        (d) => feedSend(taskId, 'chunk', { d: d }),
        (r) => {
          // 思考过程实时滚动回传（客户端灰色小字展示，完成后自动折叠）
          taskReasoning.set(taskId, (taskReasoning.get(taskId) || '') + r);
          feedSend(taskId, 'think', { d: r });
        });
      const content = res.content;
      const reasoning = res.reasoning || taskReasoning.get(taskId) || '';
      // 结束前补推一次最终进度：长文本常常"最后一波增量还没到节流窗口就结束了"，
      // 不补这一下，实况窗会停在 60% 之类的位置直接被结束消息收掉。必须 await：
      // 否则结束消息（operation 2）可能先于更新（operation 1）到达，顺序颠倒。
      if (task.liveView) {
        const fin = liveViewFeedback.get(taskId);
        if (fin) {
          fin.content = content;
          fin.reasoning = reasoning;
        }
        const finPct = push.estimatePercent(task, fin || { content: content, reasoning: reasoning });
        const finToken = tasks.tokenOf(task.deviceId);
        if (PUSH_ENABLED && push.configured() && finToken && finPct > 0) {
          await push.sendLiveViewUpdate({
            token: finToken,
            activityId: task.liveView.activityId,
            event: task.liveView.event || 'TIMER',
            percent: finPct,
            title: task.label
          }).catch(() => { /* 兜底：失败不影响任务完成 */ });
        }
      }
      tasks.patch(taskId, {
        status: tasks.STATUS.DONE,
        content: content,
        reasoning: reasoning,
        finishedAt: Date.now(),
        error: ''
      });
      console.log('[tasks] done id=' + taskId + ' type=' + task.type +
        ' len=' + content.length + ' think=' + reasoning.length);
      feedSend(taskId, 'done', { c: content, r: reasoning });
      feedClose(taskId);
      taskReasoning.delete(taskId);
      liveViewFeedbackDone(taskId);
      // 完成通知（默认关闭：客户端已取消消息通知功能；仅当 PUSH_ENABLED=1 时启用）
      if (PUSH_ENABLED) {
        if (task.liveView) {
          await push.sendLiveViewEnd({
            token: tasks.tokenOf(task.deviceId),
            activityId: task.liveView.activityId,
            // 与客户端创建实况窗时实际生效的 event 保持一致。
            // 默认值用 'TIMER'（客户端 EVENTS 首选场景），而非 'PROGRESS'
            // —— PROGRESS 是**布局类型**不是场景名，传它会被华为拒收。
            event: task.liveView.event || 'TIMER'
          }).catch((e) => console.error('[tasks] liveview end 失败: ' + String(e && e.message || e)));
        }
        await pushToDevice(task.deviceId, {
          notifyId: task.notifySeed,
          title: task.notifyTitle,
          body: task.notifyBody,
          data: { taskId: taskId, type: task.type, status: 'done' }
        });
      }
    } catch (e) {
      const msg = e && e.message ? String(e.message) : '生成失败';
      const cancelled = msg === '任务已取消';
      tasks.patch(taskId, {
        status: tasks.STATUS.FAILED,
        content: '',
        reasoning: taskReasoning.get(taskId) || '',
        finishedAt: Date.now(),
        error: msg
      });
      console.error('[tasks] failed id=' + taskId + ' err=' + msg);
      feedSend(taskId, cancelled ? 'cancelled' : 'error', { m: msg });
      feedClose(taskId);
      taskReasoning.delete(taskId);
      // 失败/取消不推"100%"：实况窗最终进度由客户端的 error 事件自行处理；
      // 服务端只负责清理节流状态，避免该 taskId 的游标常驻内存。
      liveViewFeedbackDone(taskId);
      if (PUSH_ENABLED) {
        await pushToDevice(task.deviceId, {
          notifyId: task.notifySeed,
          title: task.notifyFailTitle,
          body: task.notifyFailBody,
          data: { taskId: taskId, type: task.type, status: 'failed' }
        });
      }
    }
  }).catch((e) => console.error('[tasks] task error: ' + (e && e.message ? e.message : String(e))));
}

// 任务增量订阅（SSE 流）：生成中推送 chunk，结束推送 done/error/cancelled
app.get('/api/task/:id/feed', checkToken, (req, res) => {
  const id = req.params.id;
  const t = tasks.get(id);
  if (!t) {
    res.status(404).json({ error: { message: '任务不存在' } });
    return;
  }
  res.writeHead(200, {
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache',
    'Connection': 'keep-alive',
    'X-Accel-Buffering': 'no'
  });
  if (t.status === tasks.STATUS.DONE) {
    if (t.reasoning) {
      res.write('event: think\ndata: ' + JSON.stringify({ d: t.reasoning }) + '\n\n');
    }
    res.write('event: done\ndata: ' + JSON.stringify({ c: t.content || '', r: t.reasoning || '' }) + '\n\n');
    res.end();
    return;
  }
  if (t.status === tasks.STATUS.FAILED) {
    res.write('event: error\ndata: ' + JSON.stringify({ m: t.error || '生成失败' }) + '\n\n');
    res.end();
    return;
  }
  res.write('event: open\ndata: {}\n\n');
  // 重连补齐：把运行中已产生的思考过程先全量补发一次（客户端按增量追加展示）
  const thinkSoFar = taskReasoning.get(id);
  if (thinkSoFar) {
    res.write('event: think\ndata: ' + JSON.stringify({ d: thinkSoFar }) + '\n\n');
  }
  let subs = feedSubs.get(id);
  if (!subs) {
    subs = new Set();
    feedSubs.set(id, subs);
  }
  subs.add(res);
  const hb = setInterval(() => {
    try {
      res.write(': ping\n\n');
    } catch (e) {
      clearInterval(hb);
    }
  }, 15000);
  res.on('close', () => {
    clearInterval(hb);
    if (subs) {
      subs.delete(res);
      if (subs.size === 0) {
        feedSubs.delete(id);
      }
    }
  });
});

// 手动取消正在生成的任务（中断上游请求，任务标记失败"任务已取消"）
app.post('/api/task/:id/cancel', checkToken, (req, res) => {
  const id = req.params.id;
  const ab = taskAborters.get(id);
  if (ab) {
    ab.manual = true;
    ab.ctrl.abort();
    res.json({ ok: true });
    return;
  }
  const t = tasks.get(id);
  if (!t) {
    res.status(404).json({ error: { message: '任务不存在' } });
    return;
  }
  res.json({ ok: true, status: t.status }); // 任务已结束，无需取消
});

// 提交后台生成任务（立即返回 taskId；生成在服务端按并发队列执行）
app.post('/api/task', checkToken, (req, res) => {
  const body = req.body || {};
  const user = typeof body.user === 'string' ? body.user : '';
  const deviceId = typeof body.deviceId === 'string' ? body.deviceId : '';
  if (user.trim() === '') {
    res.status(400).json({ error: { message: 'user 不能为空' } });
    return;
  }
  if (deviceId === '') {
    res.status(400).json({ error: { message: 'deviceId 不能为空' } });
    return;
  }
  if (!API_KEY) {
    res.status(500).json({ error: { message: '服务端未配置 DEEPSEEK_API_KEY' } });
    return;
  }
  const task = tasks.create({
    deviceId: deviceId,
    type: typeof body.type === 'string' ? body.type : 'ai',
    label: typeof body.label === 'string' ? body.label : '内容',
    system: typeof body.system === 'string' ? body.system : '',
    user: user,
    notifySeed: body.notifySeed,
    notifyTitle: typeof body.notifyTitle === 'string' ? body.notifyTitle : '',
    notifyBody: typeof body.notifyBody === 'string' ? body.notifyBody : '',
    notifyFailTitle: typeof body.notifyFailTitle === 'string' ? body.notifyFailTitle : '',
    notifyFailBody: typeof body.notifyFailBody === 'string' ? body.notifyFailBody : '',
    // 学科索引路由：客户端显式传学科/年级（缺省时服务端从 user 文本中的"学科："解析）
    subject: typeof body.subject === 'string' ? body.subject : '',
    grade: Number(body.grade) || 0,
    // 深度思考开关：true 时启用思维链（reasoning_content 实时回传给客户端展示）
    thinking: body.thinking === true
  });
  // 附件需在任务开始执行前入表（runTask 内部异步消费）
  const atts = normalizeAttachments(body.attachments);
  if (atts.length > 0) {
    taskAttachments.set(task.id, atts);
  }
  runTask(task.id);
  res.status(202).json({ ok: true, taskId: task.id, status: task.status, attachments: atts.length });
});

// 查询任务
app.get('/api/task/:id', checkToken, (req, res) => {
  const task = tasks.get(req.params.id);
  if (!task) {
    res.status(404).json({ error: { message: '任务不存在' } });
    return;
  }
  res.json({ ok: true, task: task });
});

/**
 * 上报：客户端已为任务创建实况窗。
 *
 * 服务端据此做两件事：
 *   ① 生成**进行中**按节奏推实况窗进度（push-type 7 / operation 1），
 *      保证 App 进程被挂起或杀掉后进度条仍能推进；
 *   ② 任务**完成**时下发结束消息（operation 2），清理可能残留的实况窗。
 *
 * 可选字段（向后兼容，全部可缺省 —— 旧客户端只传 activityId/event 也照常工作）：
 *   totalChars      本次生成**预期**的正文总字符数。服务端不掌握客户端的
 *                   EXPECT_CHARS 表，拿到它才能算出与客户端一致的进度百分比；
 *                   缺省时退化为按时间线性推进。
 *   expectedMinutes 预期生成时长（分钟），同样是缺省时的兜底依据。
 */
app.post('/api/task/:id/liveview', checkToken, (req, res) => {
  const task = tasks.get(req.params.id);
  if (!task) {
    res.status(404).json({ error: { message: '任务不存在' } });
    return;
  }
  const body = req.body || {};
  const activityId = Number(body.activityId) || 0;
  if (activityId <= 0) {
    res.status(400).json({ error: { message: 'activityId 无效' } });
    return;
  }
  // totalChars / expectedMinutes 都是**可选**字段。
  // 语义要分清："没传"要区分"老客户端压根不知道这个概念" 与 "新客户端明确说不知道"，
  // 因此保留字段是否出现的布尔量，而不是把两者都压成 0 —— 后者会让日志无法区分
  // "客户端没上报"和"客户端上报了一个无效值"，排查时很容易误判。
  const hasTotalChars = body.totalChars !== undefined && body.totalChars !== null;
  const hasExpectedMinutes = body.expectedMinutes !== undefined && body.expectedMinutes !== null;
  const totalChars = Number(body.totalChars) || 0;
  const expectedMinutes = Number(body.expectedMinutes) || 0;
  const event = typeof body.event === 'string' && body.event !== '' ? body.event : 'TIMER';
  const prev = task.liveView || {};
  tasks.patch(task.id, {
    liveView: {
      // activityId 是定位实况窗的唯一依据，必须以本次上报为准
      activityId: activityId,
      // 场景名必须与客户端创建时一致；客户端未传时用其首选场景 TIMER
      //（PROGRESS 是布局类型，不是合法场景名）
      event: event,
      // 被华为拒收时服务端会打 `[push] 实况窗消息失败 ... body=` 日志，
      // 届时再按报错删字段即可（真机联调待办，见 task-2 汇报）。这里显式落一个
      // 标记位，便于线上排查"到底发的是哪一版报文"。
      rejectedFields: Array.isArray(prev.rejectedFields) ? prev.rejectedFields : [],
      // 非正数一律落 0（= 未提供），避免误配把进度估算拉到 0% 或除零。
      // 已上报过的值不因后续省略而被清掉。
      totalChars: totalChars > 0 ? totalChars : Number(prev.totalChars) || 0,
      expectedMinutes: expectedMinutes > 0 ? expectedMinutes : Number(prev.expectedMinutes) || 0
    }
  });
  console.log('[rev-ai-proxy] 实况窗已绑定 taskId=' + task.id
    + ' activityId=' + activityId
    + ' event=' + event
    + ' totalChars=' + (totalChars > 0 ? totalChars
      : (hasTotalChars ? '无效(' + JSON.stringify(body.totalChars) + ')' : '未上报->按类型默认'))
    + ' expectedMinutes=' + (expectedMinutes > 0 ? expectedMinutes
      : (hasExpectedMinutes ? '无效' : '未上报->按类型默认'))
    + '（进行中进度将由服务端补推）');
  res.json({ ok: true, progressPush: PUSH_ENABLED });
});

// 按设备列出最近任务
app.get('/api/tasks', checkToken, (req, res) => {
  const deviceId = typeof req.query.deviceId === 'string' ? req.query.deviceId : '';
  if (deviceId === '') {
    res.status(400).json({ error: { message: 'deviceId 不能为空' } });
    return;
  }
  // 列表接口顺带做一次过期清理：磁盘留存期与"对客户端可见"的窗口保持一致，
  // 不必等到下一个 10 分钟周期。purgeExpired 幂等且无删除时不做任何落盘，开销可忽略。
  try {
    tasks.purgeExpired();
  } catch (e) {
    console.error('[rev-ai-proxy] 列表前清理异常: ' + (e && e.message ? e.message : String(e)));
  }
  res.json({ ok: true, tasks: tasks.listByDevice(deviceId, Number(req.query.limit) || 20) });
});

// 上报设备 Push Token
app.post('/api/push/register', checkToken, (req, res) => {
  const body = req.body || {};
  const deviceId = typeof body.deviceId === 'string' ? body.deviceId : '';
  const token = typeof body.token === 'string' ? body.token : '';
  if (deviceId === '' || token === '') {
    res.status(400).json({ error: { message: 'deviceId 与 token 不能为空' } });
    return;
  }
  tasks.registerDevice(deviceId, token);
  res.json({ ok: true });
});

/**
 * 读回已注册设备的 Push Token（供 server/tools/get_device_token.js 使用）。
 *
 * 【为什么需要】
 *   Push Token 由客户端的 `pushService.getToken()`（@kit.PushKit）在**应用进程内**
 *   申请 —— 它依赖应用自己的 client_id / 签名证书 / AGC 身份，因此
 *   **任何外部脚本都无法直接调用它**，shell 也取不到（不是文件、不是系统属性）。
 *   唯一已经拿到 Token 的地方就是 App 上报后的服务端设备表，
 *   所以"在电脑上看当前设备的 Token"只能通过本接口读回。
 *
 * 【安全设计（重要）】
 *   Token 是敏感凭据：拿到它就能冒充服务端给这台设备推消息。因此：
 *     1. 走 checkToken（需 x-proxy-token），与其它管理接口一致，**不对外开放**；
 *     2. **默认打码**：只返回前后各 6 位与长度，避免明文 Token 出现在日志/终端历史里；
 *        需要明文必须显式带 `?full=1`；
 *     3. 支持 `?deviceId=` 精确查询单台设备；
 *     4. 只读，不写、不删。
 *   若不需要该能力，可删除本路由；本地读取仍可用
 *   `node tools/get_device_token.js --local` 直接读 data/devices.json。
 *
 * 用法：GET /api/push/devices            → 全部设备（Token 打码）
 *       GET /api/push/devices?full=1     → 全部设备（Token 明文）
 *       GET /api/push/devices?deviceId=X → 指定设备
 */
app.get('/api/push/devices', checkToken, (req, res) => {
  const wantFull = String(req.query.full || '') === '1';
  const wantId = typeof req.query.deviceId === 'string' ? req.query.deviceId : '';

  let list = tasks.listDevices();
  if (wantId !== '') {
    list = list.filter((d) => String(d.id || '') === wantId);
  }

  /**
   * 打码：保留前后各 6 位。
   * 短串（<=14）整体打星，避免"打码后仍可还原"。
   */
  const mask = (t) => {
    const s = String(t || '');
    if (s.length <= 14) return '*'.repeat(s.length);
    return s.slice(0, 6) + '...(' + s.length + ' chars)...' + s.slice(-6);
  };

  const devices = list.map((d) => ({
    id: d.id,
    token: wantFull ? d.token : mask(d.token),
    tokenLen: String(d.token || '').length,
    updatedAt: d.updatedAt
  }));

  res.json({ ok: true, count: devices.length, masked: !wantFull, devices });
});

/**
 * 删除本设备在服务端保存的全部数据（用户主动行使删除权）。
 *
 * 为什么需要：仅有周期性过期清理时，用户无法**主动要求**删除自己的服务器数据，
 * 隐私协议也就无法承诺"可随时删除"。本接口补齐该能力。
 *
 * 删除范围：该 deviceId 名下的**全部任务记录**（含 user/system 提示词、content 生成结果、
 * reasoning 思维链，不论 pending/running/done/failed）与 devices.json 中的设备注册记录。
 * **只删该 deviceId 的数据，其他人的数据不受影响**（见 tasks.deleteByDevice 的相等匹配与空值保护）。
 *
 * 鉴权：与其它受保护路由一致走 checkToken（配置了 PROXY_TOKEN 时需带 x-proxy-token），
 * 避免任意人凭一个 deviceId 就删掉他人数据。
 *
 * 用法：POST /api/data/delete  body: {"deviceId":"..."}
 *      返回：{ok:true, tasks:n, devices:m}
 */
app.post('/api/data/delete', checkToken, (req, res) => {
  const body = req.body || {};
  const deviceId = typeof body.deviceId === 'string' ? body.deviceId : '';
  if (deviceId === '') {
    res.status(400).json({ error: { message: 'deviceId 不能为空' } });
    return;
  }
  // 先把该设备正在生成的任务中断掉：删除后任务已不存在，继续跑只会浪费上游额度，
  // 且其回调会往已删除的 taskId 上写状态。
  const running = tasks.listByDevice(deviceId, Number.MAX_SAFE_INTEGER)
    .filter((t) => t.status === tasks.STATUS.RUNNING || t.status === tasks.STATUS.PENDING);
  for (const t of running) {
    const ab = taskAborters.get(t.id);
    if (ab) {
      ab.manual = true;
      try {
        ab.ctrl.abort();
      } catch (e) {
        // 已结束的任务 abort 无副作用，忽略
      }
    }
  }
  if (running.length > 0) {
    console.log('[rev-ai-proxy] 主动删除前中断任务 ' + running.length + ' 个 deviceId=' + deviceId);
  }
  const r = tasks.deleteByDevice(deviceId);
  res.json({ ok: true, tasks: r.tasks, devices: r.devices });
});

/* ===================== 华为 Push Kit 消息回执 ===================== */

/**
 * 回执接收地址：由华为推送服务器回调（不是 App 调用）。
 *
 * 在 AppGallery Connect「项目设置 → 消息回执」中把「回调地址」填成本服务地址，
 * 形如：https://<域名或IP>:<端口>/api/push/receipt
 *
 * 注意：本路由**不使用 checkToken** —— 调用方是华为服务器，它只会带
 * X-HUAWEI-CALLBACK-ID 鉴权头；代理令牌校验在这里由 pushReceipt.verify 取代。
 *
 * 关于 AGC 控制台的「回执测试」：
 *   该测试发的是**连通性探测**（不带 X-HUAWEI-CALLBACK-ID、无业务数据），
 *   为了让控制台能通过校验，探测请求返回 200 + code=0。
 *   真实回执若带了鉴权头但签名不符，仍会被拒绝（code=1）。
 */
app.post('/api/push/receipt', (req, res) => {
  const v = pushReceipt.verify(req);
  if (!v.ok) {
    // 诊断增强：鉴权失败时把**原始头**与本地时钟一并打出。
    // 为什么需要：`timestamp expired` 有多种成因（时钟偏差、上游代理改写头、
    // 回调密钥不一致导致 value 被误判），只看 reason 无法区分，导致反复盲猜。
    // 打印原始 timestamp 与本地时间可直接判定是不是时钟问题。
    const raw = req.get('X-HUAWEI-CALLBACK-ID') || '';
    const m = /timestamp=(\d+)/.exec(raw);
    const huaweiTs = m ? Number(m[1]) : 0;
    const nowSec = Math.floor(Date.now() / 1000);
    console.warn('[push-receipt] 鉴权失败: ' + v.reason
      + ' | 华为timestamp=' + (huaweiTs || '(未解析到)')
      + ' 本地=' + nowSec
      + ' 差值=' + (huaweiTs ? (nowSec - huaweiTs) : '?') + '秒'
      + ' | 原始头长度=' + raw.length);
    // 华为要求返回 200 + code；鉴权失败时用非 0 code 明确拒绝
    res.status(200).json({ code: '1', message: 'auth failed: ' + v.reason });
    return;
  }
  const body = req.body || {};
  const r = pushReceipt.handleStatuses(body.statuses);
  if (v.probe === true) {
    // 连通性探测：无回执数据，仅确认地址可达
    console.log('[push-receipt] 收到连通性探测（无鉴权头），已返回 200');
  } else {
    console.log('[push-receipt] 收到回执 ' + r.received + ' 条：成功 ' + r.ok + '，失败 ' + r.fail);
  }
  res.status(200).json({ code: '0', message: 'success' });
});

// 连通性探测：部分控制台校验用 GET 探活，同样返回 200（否则会报 404）
app.get('/api/push/receipt', (req, res) => {
  res.status(200).json({ code: '0', message: 'success' });
});

// 回执统计（调试用；此路由是给运维/开发看的，故保留代理令牌校验）
app.get('/api/push/receipt/stats', checkToken, (req, res) => {
  res.json({ ok: true, receipt: pushReceipt.stats() });
});

/* ===================== 新课标 RAG 索引（学科索引 + 内容索引） ===================== */

// 检索调试：索引概况
app.get('/api/rag/stats', checkToken, (req, res) => {
  res.json({ ok: true, rag: rag.stats() });
});

// 检索调试：直接看某个查询命中了哪些课标条目（不调用模型）
app.get('/api/rag/search', checkToken, (req, res) => {
  const q = typeof req.query.q === 'string' ? req.query.q : '';
  if (q.trim() === '') {
    res.status(400).json({ error: { message: 'q 不能为空' } });
    return;
  }
  const subject = typeof req.query.subject === 'string' ? req.query.subject : '';
  const grade = Number(req.query.grade) || 0;
  const info = rag.parseRequest(q, subject);
  const hits = rag.search(q, {
    subjectId: info.subjectId, stage: info.stage, grade: grade || info.grade, topK: Number(req.query.topK) || 10
  });
  res.json({
    ok: true,
    parsed: info,
    hits: hits.map((h) => ({
      score: Math.round(h.score * 100) / 100, subject: h.c.s, sec: h.c.sec,
      page: h.c.p, doc: h.c.d, text: h.c.t.slice(0, 400)
    }))
  });
});

// 检索调试：预览最终注入模型的"课标依据"块
app.get('/api/rag/block', checkToken, (req, res) => {
  const q = typeof req.query.q === 'string' ? req.query.q : '';
  if (q.trim() === '') {
    res.status(400).json({ error: { message: 'q 不能为空' } });
    return;
  }
  const out = rag.buildBlock({
    user: q,
    subject: typeof req.query.subject === 'string' ? req.query.subject : '',
    grade: Number(req.query.grade) || 0
  });
  if (!out) {
    res.json({ ok: true, hit: false, block: '' });
    return;
  }
  res.json({ ok: true, hit: true, info: out.info, block: out.block });
});

// 统一异常兜底
app.use((err, req, res, next) => {
  console.error('[rev-ai-proxy] unhandled url=' + req.url + ' err=' +
    (err && err.stack ? String(err.stack) : String(err)));
  res.status(500).json({ error: { message: '服务异常，请稍后再试' } });
});

/* ===================== 启动：证书就绪则 HTTPS，否则 HTTP 回退 ===================== */
// 先载入新课标 RAG 索引（学科索引 + 内容索引），失败不影响主服务启动
rag.load();

/**
 * 绑定监听地址，并在**双栈不可用**时自动回退 IPv4。
 *
 * 为什么需要回退：
 *   默认 HOST='::'（双栈）。但若内核缺少 IPv6 支持或已 `sysctl
 *   net.ipv6.conf.all.disable_ipv6=1`，绑定 '::' 会抛 EAFNOSUPPORT，
 *   Node 的 listen 错误是**异步**的（'error' 事件），若不处理会直接让进程退出。
 *   为免"改个监听地址把服务弄挂"，失败时打印告警并回退到 0.0.0.0。
 *
 * @param {http.Server|https.Server} server 已创建但未监听的 server
 * @param {number} port 端口
 * @param {string} label 日志前缀（区分主端口/兼容端口）
 * @param {() => void} onOk 绑定成功回调
 */
function listenWithFallback(server, port, label, onOk) {
  const bind = (host, isFallback) => {
    server.listen(port, host, () => {
      if (isFallback) {
        console.warn('[rev-ai-proxy] 注意：IPv6 不可用，已回退为仅监听 IPv4（'
          + host + ':' + port + '）');
      }
      onOk();
    });
  };
  server.once('error', (e) => {
    if (e && e.code === 'EAFNOSUPPORT' && HOST === '::') {
      console.error('[rev-ai-proxy] 绑定 :: 失败（本机未启用 IPv6）：'
        + (e.message || String(e)) + '，回退 0.0.0.0');
      bind('0.0.0.0', true);
      return;
    }
    console.error('[rev-ai-proxy] 监听失败 ' + label + ' port=' + port
      + ' host=' + HOST + ' err=' + (e && e.message ? e.message : String(e)));
  });
  bind(HOST, false);
}

function onListen(scheme) {
  // HOST='::' 时打印成可读形式：实际同时接受 IPv4 与 IPv6
  const shown = HOST === '::' ? '[::] (IPv6+IPv4 双栈)' : HOST;
  console.log('[rev-ai-proxy] listening on ' + scheme + '://' + shown + ':' + PORT);
  if (!API_KEY) {
    console.warn('[rev-ai-proxy] 警告：尚未配置 DEEPSEEK_API_KEY（请检查 .env）');
  }
}

if (TLS_ENABLED) {
  let tlsOpts = null;
  try {
    tlsOpts = {
      cert: fs.readFileSync(SSL_CERT),
      key: fs.readFileSync(SSL_KEY)
    };
  } catch (e) {
    console.error('[rev-ai-proxy] TLS 证书读取失败：' + (e && e.message ? e.message : String(e)));
    console.error('[rev-ai-proxy] 已回退明文 HTTP，请检查证书路径：' + SSL_CERT + ' / ' + SSL_KEY);
  }
  if (tlsOpts) {
    listenWithFallback(https.createServer(tlsOpts, app), PORT, 'https', () => onListen('https'));
    // 平滑迁移：TLS 生效期间仍可设置 HTTP_PORT 保留明文入口（如旧版 App 未升级前）
    if (HTTP_PORT > 0) {
      listenWithFallback(http.createServer(app), HTTP_PORT, 'http-compat', () => {
        console.log('[rev-ai-proxy] (兼容) 明文 HTTP 监听 http://' + HOST + ':' + HTTP_PORT);
      });
    }
  } else {
    listenWithFallback(http.createServer(app), PORT, 'http', () => onListen('http'));
  }
} else {
  listenWithFallback(http.createServer(app), PORT, 'http', () => onListen('http'));
}
