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
 *
 * 启动：cp .env.example .env 并填写密钥，然后 npm start
 */
require('dotenv').config();
const express = require('express');
const cors = require('cors');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const PORT = Number(process.env.PORT || 3000);
const HOST = process.env.HOST || '0.0.0.0';
const UPSTREAM = process.env.UPSTREAM_URL || 'https://api.deepseek.com/chat/completions';
const API_KEY = process.env.DEEPSEEK_API_KEY || '';
const PROXY_TOKEN = process.env.PROXY_TOKEN || '';
const TIMEOUT_MS = Number(process.env.REQUEST_TIMEOUT_MS || 150000);
const RATE_PER_MIN = Number(process.env.RATE_LIMIT_PER_MIN || 120);
// 账号体系：AUTH_REQUIRED=true 时，AI 接口要求携带账号令牌
const AUTH_REQUIRED = process.env.AUTH_REQUIRED === 'true';
// 华为登录（Account Kit OAuth）：需要在 AGC 控制台获取 APP_SECRET
const HUAWEI_APP_ID = process.env.HUAWEI_APP_ID || '';
const HUAWEI_APP_SECRET = process.env.HUAWEI_APP_SECRET || '';
const HUAWEI_TOKEN_URL = 'https://oauth-login.cloud.huawei.com/oauth2/v3/token';
const HUAWEI_USERINFO_URL = 'https://oauth-login.cloud.huawei.com/oauth2/v3/userinfo';
const DATA_DIR = path.join(__dirname, '..', 'data');
const USERS_FILE = path.join(DATA_DIR, 'users.json');

const app = express();
app.disable('x-powered-by');
app.use(cors({
  origin: true,
  methods: ['GET', 'POST', 'OPTIONS'],
  allowedHeaders: ['Content-Type', 'Authorization', 'x-proxy-token']
}));
app.use(express.json({ limit: '2mb' }));

/* ===================== 账号体系（本地 JSON 持久化） ===================== */
fs.mkdirSync(DATA_DIR, { recursive: true });
if (!fs.existsSync(USERS_FILE)) {
  fs.writeFileSync(USERS_FILE, '[]', 'utf8');
}
const readUsers = () => {
  try {
    const list = JSON.parse(fs.readFileSync(USERS_FILE, 'utf8') || '[]');
    return Array.isArray(list) ? list : [];
  } catch (e) {
    return [];
  }
};
const writeUsers = (list) => {
  const tmp = USERS_FILE + '.tmp';
  fs.writeFileSync(tmp, JSON.stringify(list, null, 2), 'utf8');
  fs.renameSync(tmp, USERS_FILE);
};
// 会话令牌：{ token: { username, expires } }，重启后需重新登录
const sessions = new Map();
const TOKEN_TTL_MS = 30 * 24 * 3600 * 1000; // 30 天
const genToken = () => crypto.randomBytes(32).toString('hex');
const scryptHash = (pwd, salt) => {
  return crypto.scryptSync(pwd, salt, 32).toString('hex');
};
const safeUser = (u) => ({ username: u.username, createdAt: u.createdAt, kind: u.kind || 'account' });
const publicUser = (username) => {
  const u = readUsers().find((x) => x.username === username);
  return u ? safeUser(u) : null;
};
function issueSession(username) {
  const token = genToken();
  sessions.set(token, { username, expires: Date.now() + TOKEN_TTL_MS });
  return { token, user: publicUser(username) };
}
function authByHeader(req) {
  const h = req.get('authorization') || '';
  const token = h.startsWith('Bearer ') ? h.slice(7) : '';
  const s = sessions.get(token);
  if (s && s.expires > Date.now()) {
    return s;
  }
  return null;
}
function validPwd(pwd) {
  return typeof pwd === 'string' && pwd.length >= 6 && pwd.length <= 64;
}
function validName(name) {
  return typeof name === 'string' && /^[\u4e00-\u9fa5a-zA-Z0-9_\-]{2,24}$/.test(name);
}

// 注册：{ username, password }
app.post('/api/register', (req, res) => {
  const { username, password } = req.body || {};
  if (!validName(username)) {
    res.status(400).json({ error: { message: '用户名需为 2-24 位汉字/字母/数字/_/-' } });
    return;
  }
  if (!validPwd(password)) {
    res.status(400).json({ error: { message: '密码长度需为 6-64 位' } });
    return;
  }
  const users = readUsers();
  if (users.some((u) => u.username === username)) {
    res.status(409).json({ error: { message: '用户名已存在，请直接登录' } });
    return;
  }
  const salt = crypto.randomBytes(16).toString('hex');
  users.push({
    username,
    salt,
    hash: scryptHash(password, salt),
    kind: 'account',
    huaweiOpenIds: [],
    createdAt: new Date().toISOString()
  });
  writeUsers(users);
  res.json(issueSession(username));
});

// 登录：{ username, password }
app.post('/api/login', (req, res) => {
  const { username, password } = req.body || {};
  const u = readUsers().find((x) => x.username === username);
  if (!u || typeof u.hash !== 'string') {
    res.status(401).json({ error: { message: '用户名或密码错误' } });
    return;
  }
  const hash = scryptHash(String(password || ''), u.salt);
  if (hash !== u.hash) {
    res.status(401).json({ error: { message: '用户名或密码错误' } });
    return;
  }
  res.json(issueSession(username));
});

// 华为登录（服务端换取 code -> openid，自动创建/匹配账号）
app.post('/api/huawei-login', async (req, res) => {
  const { code, redirectUri } = req.body || {};
  if (!code || !HUAWEI_APP_ID || !HUAWEI_APP_SECRET) {
    res.status(501).json({ error: { message: '服务端未配置 HUAWEI_APP_ID / HUAWEI_APP_SECRET' } });
    return;
  }
  try {
    const form = new URLSearchParams();
    form.set('grant_type', 'authorization_code');
    form.set('client_id', HUAWEI_APP_ID);
    form.set('client_secret', HUAWEI_APP_SECRET);
    form.set('code', String(code));
    if (redirectUri) { form.set('redirect_uri', String(redirectUri)); }
    const tokResp = await fetch(HUAWEI_TOKEN_URL, { method: 'POST', body: form });
    const tok = await tokResp.json();
    if (!tok.access_token) {
      res.status(401).json({ error: { message: '华为授权码校验失败' } });
      return;
    }
    const infoResp = await fetch(HUAWEI_USERINFO_URL + '?access_token=' + encodeURIComponent(tok.access_token));
    const info = await infoResp.json();
    const openId = info.openID || info.openid || '';
    if (!openId) {
      res.status(401).json({ error: { message: '未能获取华为账号信息' } });
      return;
    }
    const users = readUsers();
    let u = users.find((x) => (x.huaweiOpenIds || []).includes(openId));
    if (!u) {
      // 自动创建华为登录账号
      const base = 'huawei_' + openId.slice(-8);
      let username = base;
      let n = 1;
      while (users.some((x) => x.username === username)) {
        username = base + '_' + (n++);
      }
      u = {
        username,
        salt: '',
        hash: '',
        kind: 'huawei',
        huaweiOpenIds: [openId],
        createdAt: new Date().toISOString()
      };
      users.push(u);
      writeUsers(users);
    }
    res.json(issueSession(u.username));
  } catch (e) {
    res.status(502).json({ error: { message: '华为登录服务异常，请稍后再试' } });
  }
});

// 会话校验 / 用户信息 / 退出
app.get('/api/me', (req, res) => {
  const s = authByHeader(req);
  if (!s) { res.status(401).json({ error: { message: '登录已过期，请重新登录' } }); return; }
  res.json({ user: publicUser(s.username) });
});
app.post('/api/logout', (req, res) => {
  const h = req.get('authorization') || '';
  const token = h.startsWith('Bearer ') ? h.slice(7) : '';
  sessions.delete(token);
  res.json({ ok: true });
});
// AI 接口可选的账号校验（AUTH_REQUIRED=true 时强制登录）
function checkSession(req, res, next) {
  if (AUTH_REQUIRED && !authByHeader(req)) {
    res.status(401).json({ error: { message: '请先登录后使用' } });
    return;
  }
  next();
}

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

/** 转发到 DeepSeek（透传响应体与状态码） */
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
    out.stream = false; // 默认非流式，与 App 当前策略一致
  }
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), TIMEOUT_MS);
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
    const text = await resp.text();
    res.status(resp.status).type('application/json').send(text || '{}');
  } catch (e) {
    const msg = e && e.name === 'AbortError'
      ? '上游请求超时'
      : ('上游请求失败：' + (e && e.message ? e.message : '未知错误'));
    res.status(502).json({ error: { message: msg } });
  } finally {
    clearTimeout(timer);
  }
}

// 与 App 现有请求体完全兼容的透传接口
app.post('/v1/chat/completions', checkToken, checkSession, (req, res) => {
  relay(req, res);
});

// 简化接口：{ system?, user }
app.post('/api/chat', checkToken, checkSession, (req, res) => {
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

// 统一异常兜底
app.use((err, req, res, next) => {
  res.status(500).json({ error: { message: '服务异常，请稍后再试' } });
});

app.listen(PORT, HOST, () => {
  console.log('[rev-ai-proxy] listening on http://' + HOST + ':' + PORT);
  if (!API_KEY) {
    console.warn('[rev-ai-proxy] 警告：尚未配置 DEEPSEEK_API_KEY（请检查 .env）');
  }
});
