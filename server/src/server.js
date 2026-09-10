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

/** 消息推送总开关：客户端已取消通知/推送功能，默认关闭；如需重新启用设环境变量 PUSH_ENABLED=1 */
const PUSH_ENABLED = process.env.PUSH_ENABLED === '1';

const PORT = Number(process.env.PORT || 3000);
const HOST = process.env.HOST || '0.0.0.0';
// TLS 配置：证书文件存在（或用 SSL_CERT/SSL_KEY 覆盖路径）即自动启用 HTTPS 监听 PORT
const SSL_CERT = process.env.SSL_CERT || '/etc/ssl/rev-on.site/server.pem';
const SSL_KEY = process.env.SSL_KEY || '/etc/ssl/rev-on.site/private_key.pem';
const TLS_ENABLED = process.env.TLS_ENABLED === undefined
  ? (fs.existsSync(SSL_CERT) && fs.existsSync(SSL_KEY))
  : (process.env.TLS_ENABLED === 'true');
// TLS 开启时可保留的明文端口（平滑迁移用），默认 0 = 不额外监听
const HTTP_PORT = Number(process.env.HTTP_PORT || 0);
const UPSTREAM = process.env.UPSTREAM_URL || 'https://api.deepseek.com/chat/completions';
const MODEL = process.env.MODEL || 'deepseek-v4-flash-vision-exp';
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
  messages.push({ role: 'user', content: buildUserContent(user, relayAtts) });
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
 *  - 无图片 -> 纯文本（正文 + 文档附件解析文本 + 未解析附件说明）
 *  - 有图片 -> OpenAI 兼容多模态数组（text + image_url 若干），供视觉模型识别
 */
function buildUserContent(user, atts) {
  let text = user;
  for (const a of atts) {
    if (a.kind === 'text') {
      text += '\n\n【附件：' + a.name + '】\n' + a.text;
    } else if (a.kind === 'file') {
      text += '\n\n【附件：' + a.name + '】（该格式暂不支持内容解析，请结合文件名与用户描述理解）';
    }
  }
  const images = atts.filter((a) => a.kind === 'image');
  if (images.length === 0) {
    return text;
  }
  const parts = [{ type: 'text', text: text }];
  for (const im of images) {
    parts.push({ type: 'image_url', image_url: { url: im.data } });
  }
  return parts;
}

/** taskId -> { ctrl: AbortController, manual: boolean }（取消任务用） */
const taskAborters = new Map();
/** taskId -> Set<res>（feed 订阅连接） */
const feedSubs = new Map();

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

/** 流式调用 DeepSeek：完整返回全文，同时把每个增量片段回调 onDelta（可被 cancel 中断） */
async function fetchDeepSeekStreamed(task, onDelta) {
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
  let prev = 0;
  const flushRemain = () => {
    if (full.length > prev) {
      const piece = full.slice(prev);
      prev = full.length;
      onDelta(piece);
    }
  };
  try {
    const atts = taskAttachments.get(task.id) || [];
    const messages = [];
    if (task.system && String(task.system).trim() !== '') {
      messages.push({ role: 'system', content: task.system });
    }
    messages.push({ role: 'user', content: buildUserContent(String(task.user || ''), atts) });
    const resp = await fetch(UPSTREAM, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ' + API_KEY
      },
      body: JSON.stringify({
        model: MODEL,
        messages: messages,
        stream: true,
        thinking: { type: 'disabled' }
      }),
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
              const d = j && j.choices && j.choices[0] && j.choices[0].delta &&
                j.choices[0].delta.content;
              if (typeof d === 'string') {
                full += d;
              }
            } catch (e) {
              // 忽略非 JSON 心跳/注释行
            }
          }
        }
      }
    } finally {
      clearInterval(flushTimer);
    }
    flushRemain();
    if (full.trim() === '') {
      throw new Error('上游未返回内容');
    }
    return full;
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
    try {
      const content = await fetchDeepSeekStreamed(task, (d) => feedSend(taskId, 'chunk', { d: d }));
      tasks.patch(taskId, {
        status: tasks.STATUS.DONE,
        content: content,
        finishedAt: Date.now(),
        error: ''
      });
      console.log('[tasks] done id=' + taskId + ' type=' + task.type + ' len=' + content.length);
      feedSend(taskId, 'done', { c: content });
      feedClose(taskId);
      // 完成通知（默认关闭：客户端已取消消息通知功能；仅当 PUSH_ENABLED=1 时启用）
      if (PUSH_ENABLED) {
        if (task.liveView) {
          await push.sendLiveViewEnd({
            token: tasks.tokenOf(task.deviceId),
            activityId: task.liveView.activityId,
            event: task.liveView.event || 'PROGRESS'
          }).catch((e) => console.error('[tasks] liveview end 失败: ' + String(e && e.message || e)));
        }
        await push.sendAlert({
          token: tasks.tokenOf(task.deviceId),
          notifyId: task.notifySeed,
          title: task.notifyTitle,
          body: task.notifyBody,
          data: { taskId: taskId, type: task.type, status: 'done' }
        }).catch((e) => console.error('[tasks] push done 失败: ' + String(e && e.message || e)));
      }
    } catch (e) {
      const msg = e && e.message ? String(e.message) : '生成失败';
      const cancelled = msg === '任务已取消';
      tasks.patch(taskId, {
        status: tasks.STATUS.FAILED,
        content: '',
        finishedAt: Date.now(),
        error: msg
      });
      console.error('[tasks] failed id=' + taskId + ' err=' + msg);
      feedSend(taskId, cancelled ? 'cancelled' : 'error', { m: msg });
      feedClose(taskId);
      if (PUSH_ENABLED) {
        await push.sendAlert({
          token: tasks.tokenOf(task.deviceId),
          notifyId: task.notifySeed,
          title: task.notifyFailTitle,
          body: task.notifyFailBody,
          data: { taskId: taskId, type: task.type, status: 'failed' }
        }).catch((e) => console.error('[tasks] push fail 失败: ' + String(e && e.message || e)));
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
    res.write('event: done\ndata: ' + JSON.stringify({ c: t.content || '' }) + '\n\n');
    res.end();
    return;
  }
  if (t.status === tasks.STATUS.FAILED) {
    res.write('event: error\ndata: ' + JSON.stringify({ m: t.error || '生成失败' }) + '\n\n');
    res.end();
    return;
  }
  res.write('event: open\ndata: {}\n\n');
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
    notifyFailBody: typeof body.notifyFailBody === 'string' ? body.notifyFailBody : ''
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

// 上报：客户端已为任务创建实况窗（完成时服务端据此结束实况窗）
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
  tasks.patch(task.id, {
    liveView: {
      activityId: activityId,
      event: typeof body.event === 'string' && body.event !== '' ? body.event : 'PROGRESS'
    }
  });
  res.json({ ok: true });
});

// 按设备列出最近任务
app.get('/api/tasks', checkToken, (req, res) => {
  const deviceId = typeof req.query.deviceId === 'string' ? req.query.deviceId : '';
  if (deviceId === '') {
    res.status(400).json({ error: { message: 'deviceId 不能为空' } });
    return;
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

// 统一异常兜底
app.use((err, req, res, next) => {
  console.error('[rev-ai-proxy] unhandled url=' + req.url + ' err=' +
    (err && err.stack ? String(err.stack) : String(err)));
  res.status(500).json({ error: { message: '服务异常，请稍后再试' } });
});

/* ===================== 启动：证书就绪则 HTTPS，否则 HTTP 回退 ===================== */
function onListen(scheme) {
  console.log('[rev-ai-proxy] listening on ' + scheme + '://' + HOST + ':' + PORT);
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
    https.createServer(tlsOpts, app).listen(PORT, HOST, () => onListen('https'));
    // 平滑迁移：TLS 生效期间仍可设置 HTTP_PORT 保留明文入口（如旧版 App 未升级前）
    if (HTTP_PORT > 0) {
      http.createServer(app).listen(HTTP_PORT, HOST, () => {
        console.log('[rev-ai-proxy] (兼容) 明文 HTTP 监听 http://' + HOST + ':' + HTTP_PORT);
      });
    }
  } else {
    http.createServer(app).listen(PORT, HOST, () => onListen('http'));
  }
} else {
  http.createServer(app).listen(PORT, HOST, () => onListen('http'));
}
