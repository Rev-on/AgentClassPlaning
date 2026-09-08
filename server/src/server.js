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
const MODEL = process.env.MODEL || 'deepseek-v4-flash';
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
app.use(express.json({ limit: '2mb' }));

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
  messages.push({ role: 'user', content: user });
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

/** 串行执行一个任务：生成 -> 保存 -> 推送完成/失败通知 */
function runTask(taskId) {
  const task = tasks.get(taskId);
  if (!task) {
    return;
  }
  tasks.enqueue(async () => {
    tasks.patch(taskId, { status: tasks.STATUS.RUNNING });
    try {
      const content = await fetchDeepSeek(task.system, task.user);
      tasks.patch(taskId, {
        status: tasks.STATUS.DONE,
        content: content,
        finishedAt: Date.now(),
        error: ''
      });
      console.log('[tasks] done id=' + taskId + ' type=' + task.type + ' len=' + content.length);
      // 若客户端创建过实况窗，先经 Push Kit 结束"生成中"实况窗（进程被杀也能结束）
      if (task.liveView) {
        await push.sendLiveViewEnd({
          token: tasks.tokenOf(task.deviceId),
          activityId: task.liveView.activityId,
          event: task.liveView.event || 'PROGRESS'
        }).catch((e) => console.error('[tasks] liveview end 失败: ' + String(e && e.message || e)));
      }
      // 完成通知：notifyId 与客户端"生成中"通知一致 -> 覆盖
      await push.sendAlert({
        token: tasks.tokenOf(task.deviceId),
        notifyId: task.notifySeed,
        title: task.notifyTitle,
        body: task.notifyBody,
        data: { taskId: taskId, type: task.type, status: 'done' }
      }).catch((e) => console.error('[tasks] push done 失败: ' + String(e && e.message || e)));
    } catch (e) {
      const msg = e && e.message ? String(e.message) : '生成失败';
      tasks.patch(taskId, {
        status: tasks.STATUS.FAILED,
        content: '',
        finishedAt: Date.now(),
        error: msg
      });
      console.error('[tasks] failed id=' + taskId + ' err=' + msg);
      await push.sendAlert({
        token: tasks.tokenOf(task.deviceId),
        notifyId: task.notifySeed,
        title: task.notifyFailTitle,
        body: task.notifyFailBody,
        data: { taskId: taskId, type: task.type, status: 'failed' }
      }).catch((e) => console.error('[tasks] push fail 失败: ' + String(e && e.message || e)));
    }
  }).catch((e) => console.error('[tasks] task error: ' + (e && e.message ? e.message : String(e))));
}

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
  runTask(task.id);
  res.status(202).json({ ok: true, taskId: task.id, status: task.status });
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
