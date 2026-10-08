/**
 * 获取当前设备的 HarmonyOS Push Token（鸿蒙推送设备 Token）。
 *
 * ============================================================================
 * 【为什么需要这个脚本 / 为什么不能用别的办法拿】
 * ============================================================================
 * Token 由 **@kit.PushKit 的 pushService.getToken()** 申请，这是**应用进程内**的
 * 系统 API：它依赖应用自己的 client_id / 签名证书 / AGC 应用身份，
 * 因此**任何外部脚本（Node / Python / 命令行）都无法直接调用它**。
 * shell 也拿不到 —— 它不是文件、不是环境变量、也不在任何系统属性里。
 *
 * 所以本脚本不去"申请" Token，而是从**三个已经存在 Token 的地方**把它读出来：
 *
 *   通道 1（推荐）服务端设备表  GET /api/push/devices
 *        App 启动时 PushToken.ensure() 已经调 getToken() 并 POST /api/push/register
 *        上报过。服务端 tasks.js 把它存在 data/devices.json。
 *        只要 App 启动过一次且联网，Token 就已经在服务端了 —— 直接读即可。
 *
 *   通道 2（本机调试）从 data/devices.json 文件直接读
 *        不依赖服务端在线，适合"服务端在服务器上、你只在本地看"的场景。
 *
 *   通道 3（兜底）从真机 hilog 日志里抓
 *        PushToken.ets 会打印 'getToken 成功: MAxxxx...'（只打前 12 位，打不全）。
 *        因此这个通道**只能确认是否申请成功**，拿不到完整 Token，
 *        除非临时把日志改成打印全文。默认仅用于诊断。
 *
 * ============================================================================
 * 【为什么服务端原本拿不到"读回"能力】
 * ============================================================================
 * server.js 只有 POST /api/push/register（写），**没有读接口** ——
 * 这是有意的：Token 是敏感凭据，谁能读走谁就能冒充服务端给这台设备推消息。
 * 本脚本配套在服务端新增了 GET /api/push/devices，它：
 *   · 走 checkToken（需要 PROXY_TOKEN），与其它管理接口一致；
 *   · 默认**打码**返回 Token（只显示前后各 6 位），需要 --full 才返回明文；
 *   · 支持 ?deviceId= 精确查询单台设备。
 * 若你不希望服务端暴露该接口，请只用通道 2。
 *
 * ============================================================================
 * 【用法】
 * ============================================================================
 *   cd server
 *
 *   # 通道 1：从服务端读（推荐）
 *   node tools/get_device_token.js
 *
 *   # 指定服务器地址与代理口令（默认读 ApiConfig / 环境变量）
 *   node tools/get_device_token.js --server http://1.2.3.4:3000 --token <PROXY_TOKEN>
 *
 *   # 显示完整 Token（不打码）
 *   node tools/get_device_token.js --full
 *
 *   # 只看某一台设备
 *   node tools/get_device_token.js --deviceId <odID>
 *
 *   # 通道 2：直接从本地 data/devices.json 读（服务端不必在线）
 *   node tools/get_device_token.js --local
 *
 *   # 通道 3：诊断真机日志（需 hdc，只能确认申请是否成功）
 *   node tools/get_device_token.js --log
 *
 * ============================================================================
 */

const fs = require('fs');
const path = require('path');
const http = require('http');
const https = require('https');
const { execFileSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..', '..');
const SERVER_DIR = path.resolve(__dirname, '..');
const DEVICES_FILE = path.join(SERVER_DIR, 'data', 'devices.json');
const API_CONFIG = path.join(ROOT, 'entry', 'src', 'main', 'ets', 'common', 'ApiConfig.ets');

/* ==================== 参数解析 ==================== */

function parseArgs(argv) {
  const o = { full: false, local: false, log: false, server: '', token: '', deviceId: '', json: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--full') o.full = true;
    else if (a === '--local') o.local = true;
    else if (a === '--log') o.log = true;
    else if (a === '--json') o.json = true;
    else if (a === '--server') o.server = argv[++i] || '';
    else if (a === '--token') o.token = argv[++i] || '';
    else if (a === '--deviceId') o.deviceId = argv[++i] || '';
    else if (a === '-h' || a === '--help') o.help = true;
  }
  return o;
}

/**
 * 从客户端 ApiConfig.ets 解析默认服务端地址与 PROXY_TOKEN。
 *
 * 为什么要读源码而不是写死：这两个值本来就集中在 ApiConfig.ets，
 * 读它可以让脚本与 App 用的是**同一个地址/口令**，避免两边不一致
 * （这与 GenTask/LiveView 复用同一份 base url 是同一个思路）。
 */
function readApiConfig() {
  const out = { base: '', proxyToken: '' };
  try {
    const src = fs.readFileSync(API_CONFIG, 'utf8');
    const b = src.match(/SERVER_BASE_URL\s*:\s*string\s*=\s*'([^']*)'/);
    if (b) out.base = b[1];
    const t = src.match(/PROXY_TOKEN\s*:\s*string\s*=\s*'([^']*)'/);
    if (t) out.proxyToken = t[1];
  } catch (e) {
    // 读不到就用环境变量兜底
  }
  return out;
}

/* ==================== 工具 ==================== */

/** Token 打码：保留前后各 6 位，中间用省略号（默认输出用） */
function maskToken(t) {
  const s = String(t || '');
  if (s.length <= 14) return '*'.repeat(s.length);
  return s.slice(0, 6) + '...(' + s.length + ' chars)...' + s.slice(-6);
}

/** 只打印 Token 前后片段（与 PushToken.ets 的日志策略一致，避免泄露） */
function shortToken(t) {
  const s = String(t || '');
  return s.length <= 12 ? s : s.slice(0, 12) + '...';
}

function httpGetJson(url, headers) {
  return new Promise((resolve, reject) => {
    const mod = url.startsWith('https:') ? https : http;
    const req = mod.get(url, { headers, timeout: 10000 }, (res) => {
      let body = '';
      res.setEncoding('utf8');
      res.on('data', (c) => { body += c; });
      res.on('end', () => {
        let parsed = null;
        try { parsed = JSON.parse(body); } catch (e) { /* 非 JSON */ }
        resolve({ status: res.statusCode, body, json: parsed });
      });
    });
    req.on('timeout', () => { req.destroy(new Error('请求超时')); });
    req.on('error', reject);
  });
}

function fmtTime(ms) {
  if (!ms) return '-';
  try { return new Date(Number(ms)).toLocaleString(); } catch (e) { return String(ms); }
}

/* ==================== 通道 1：服务端接口 ==================== */

async function fromServer(opts) {
  const cfg = readApiConfig();
  const base = (opts.server || process.env.REV_SERVER || cfg.base || '').replace(/\/+$/, '');
  const token = opts.token || process.env.REV_PROXY_TOKEN || cfg.proxyToken || '';

  if (base === '') {
    console.log('  ✗ 未找到服务端地址。请用 --server http://host:port 指定。');
    return null;
  }
  let url = base + '/api/push/devices';
  if (opts.deviceId !== '') {
    url += '?deviceId=' + encodeURIComponent(opts.deviceId);
  }
  if (opts.full) {
    url += (url.indexOf('?') >= 0 ? '&' : '?') + 'full=1';
  }

  const headers = {};
  if (token !== '') headers['x-proxy-token'] = token;

  console.log('  GET ' + url);
  let r;
  try {
    r = await httpGetJson(url, headers);
  } catch (e) {
    console.log('  ✗ 请求失败：' + (e && e.message ? e.message : String(e)));
    console.log('    （服务端没启动 / 地址不对 / 不在同一网络）');
    return null;
  }

  if (r.status === 401 || r.status === 403) {
    console.log('  ✗ 鉴权失败 HTTP ' + r.status + '：PROXY_TOKEN 不对。');
    console.log('    请用 --token <PROXY_TOKEN> 指定（见服务端 .env）。');
    return null;
  }
  if (r.status === 404) {
    console.log('  ✗ 404：服务端还没有 GET /api/push/devices 接口。');
    console.log('    该接口是本脚本配套新增的（见 server/src/server.js）。');
    return null;
  }
  if (r.status !== 200 || !r.json) {
    console.log('  ✗ HTTP ' + r.status + '：' + String(r.body).slice(0, 200));
    return null;
  }
  return r.json;
}

/* ==================== 通道 2：本地 devices.json ==================== */

function fromLocal(opts) {
  if (!fs.existsSync(DEVICES_FILE)) {
    console.log('  ✗ 文件不存在：' + DEVICES_FILE);
    console.log('    App 从未成功上报过 Token，或服务端数据目录不在这里。');
    return null;
  }
  let arr = [];
  try {
    const raw = JSON.parse(fs.readFileSync(DEVICES_FILE, 'utf8'));
    arr = Array.isArray(raw) ? raw : [];
  } catch (e) {
    console.log('  ✗ 解析失败：' + e.message);
    return null;
  }
  if (opts.deviceId !== '') {
    arr = arr.filter((d) => String((d && (d.id || d.deviceId)) || '') === opts.deviceId);
  }
  // 补 tokenLen：服务端接口会返回该字段，本地文件没有，这里按真实长度补上，
  // 保证摘要/合法性自检在两条通道下行为一致（不打码时无需，但统一更省心）。
  arr = arr.map((d) => ({
    id: d && (d.id || d.deviceId),
    token: d && d.token,
    tokenLen: String((d && d.token) || '').length,
    updatedAt: d && d.updatedAt
  }));
  return { ok: true, count: arr.length, devices: arr };
}

/* ==================== 通道 3：真机日志诊断 ==================== */

/**
 * 从 hilog 抓 Token。
 *
 * 【重要】PushToken.ets 当前**只打印前 12 位**（避免完整 Token 进日志），
 * 因此这里通常**拿不到完整 Token**，只能确认"是否申请成功"。
 * 若要拿全文，需要临时把 PushToken.ets 的日志改成打印完整 token，
 * 或直接用通道 1 / 2（推荐）。
 */
function fromLog(opts) {
  const hdc = findHdc();
  if (hdc === '') {
    console.log('  ✗ 未找到 hdc.exe（HarmonyOS 设备调试工具）。');
    console.log('    通常在 DevEco Studio/sdk/default/openharmony/toolchains/hdc.exe');
    return null;
  }
  console.log('  使用 hdc: ' + hdc);
  try {
    const devs = execFileSync(hdc, ['list', 'targets'], { encoding: 'utf8', timeout: 15000 });
    console.log('  已连接设备：' + (devs.trim() === '' ? '（无）' : devs.trim()));
    if (devs.trim() === '') {
      console.log('  ✗ 没有连接真机。请用 USB 连接并打开开发者模式/USB 调试。');
      return null;
    }
  } catch (e) {
    console.log('  ✗ hdc list targets 失败：' + (e && e.message ? e.message : String(e)));
    return null;
  }

  console.log('\n  正在抓取 hilog（约 12 秒，请在真机上启动一次 App）...\n');
  let out = '';
  try {
    out = execFileSync(hdc, ['shell', 'hilog', '-x'], {
      encoding: 'utf8', timeout: 12000, maxBuffer: 32 * 1024 * 1024
    });
  } catch (e) {
    // hilog -x 会一直输出直到超时被杀，属于预期；已捕获的部分在 e.stdout
    out = (e && e.stdout) ? String(e.stdout) : '';
  }

  const lines = out.split(/\r?\n/);
  const hits = [];
  for (const ln of lines) {
    if (ln.length > 1000) continue; // 跳过巨型行
    if (/PushToken|getToken|push\.register|MA[A-Za-z0-9_-]{20,}/.test(ln)) {
      hits.push(ln);
    }
  }

  if (hits.length === 0) {
    console.log('  未在日志中发现 PushToken 相关记录。');
    console.log('  可能原因：App 未启动 / 日志已被冲掉 / 未连接真机。');
    return { ok: true, count: 0, devices: [] };
  }

  console.log('  命中 ' + hits.length + ' 行相关日志：');
  const seen = new Set();
  const found = [];
  for (const ln of hits) {
    const m = ln.match(/MA[A-Za-z0-9_\-]{30,}/);
    if (m && !seen.has(m[0])) {
      seen.add(m[0]);
      found.push({ token: m[0], line: ln.trim() });
    }
  }

  console.log('');
  for (const h of hits.slice(-20)) {
    console.log('    ' + h.trim().slice(0, 200));
  }

  if (found.length === 0) {
    console.log('\n  ⚠ 日志里只有截断的 Token 片段（PushToken.ets 只打印前 12 位），');
    console.log('    无法还原完整 Token。请改用通道 1（--server）或通道 2（--local）。');
    return { ok: true, count: 0, devices: [] };
  }

  console.log('\n  从日志提取到完整 Token（' + found.length + ' 个）：');
  return {
    ok: true,
    count: found.length,
    devices: found.map((f) => ({ id: '(来自日志)', token: f.token, updatedAt: 0 }))
  };
}

function findHdc() {
  const cands = [
    process.env.HDC_PATH || '',
    'D:\\Program Files\\Huawei\\DevEco Studio\\sdk\\default\\openharmony\\toolchains\\hdc.exe',
    'C:\\Program Files\\Huawei\\DevEco Studio\\sdk\\default\\openharmony\\toolchains\\hdc.exe'
  ];
  for (const c of cands) {
    if (c && fs.existsSync(c)) return c;
  }
  try {
    const r = execFileSync('where', ['hdc'], { encoding: 'utf8', timeout: 5000 });
    const first = r.split(/\r?\n/).map((s) => s.trim()).filter((s) => s !== '')[0];
    if (first && fs.existsSync(first)) return first;
  } catch (e) { /* ignore */ }
  return '';
}

/* ==================== 输出 ==================== */

function printDevices(res, opts, source) {
  const list = (res && res.devices) ? res.devices : [];
  console.log('\n  来源：' + source);
  console.log('  设备数：' + list.length);
  if (list.length === 0) {
    console.log('\n  ⚠ 没有找到任何 Token。');
    console.log('  → 说明 App 从未成功上报 Token。请检查：');
    console.log('     1. App 启动过且联网（PushToken.ensure 在 EntryAbility.onCreate 调用）');
    console.log('     2. AGC 已为当前**签名证书**开通「推送服务」（Push Kit）');
    console.log('     3. 设备已登录华为账号');
    console.log('     4. 服务端地址与 PROXY_TOKEN 配置正确');
    return;
  }

  console.log('');
  console.log('  ' + 'deviceId'.padEnd(40) + 'token'.padEnd(46) + '更新时间');
  console.log('  ' + '-'.repeat(110));
  for (const d of list) {
    const id = String((d && (d.id || d.deviceId)) || '').slice(0, 38);
    const tk = opts.full ? String(d.token || '') : maskToken(d.token);
    console.log('  ' + id.padEnd(40) + tk.padEnd(46) + fmtTime(d.updatedAt));
  }

  // ---- 摘要与合法性自检 ----
  // 注意：必须用**未打码的真实长度**（服务端返回的 tokenLen）来判断，
  // 不能用打码后的字符串 —— 否则会拿 "MA1234...(28 chars)...abcdef" 去校验，
  // 得出"含非法字符/长度不足"的错误结论（这是本脚本初版的真实 bug）。
  const first = list[0] || {};
  const realLen = Number(first.tokenLen) > 0
    ? Number(first.tokenLen)
    : String(first.token || '').length;

  if (!opts.full) {
    console.log('\n  （Token 已打码，只显示前后各 6 位。需要明文请加 --full）');
  }

  if (realLen > 0) {
    console.log('\n  === 第一台设备的 Token ===');
    if (opts.full) {
      console.log('  ' + String(first.token || ''));
      if (!/^[A-Za-z0-9_-]+$/.test(String(first.token || ''))) {
        console.log('  ⚠ 含非 Base64Url 字符，可能不是合法 Token。');
      }
    }
    console.log('  长度：' + realLen + ' 字符');
    if (realLen < 40) {
      console.log('  ⚠ 长度 < 40（服务端 tasks.js 的 TOKEN_MIN_LEN），会被 isValidToken 拒绝。');
    } else {
      console.log('  ✓ 长度合法（服务端 TOKEN_MIN_LEN = 40）');
    }
    console.log('  摘要：' + (opts.full ? shortToken(first.token) : maskToken(first.token)));
  }
}

/* ==================== main ==================== */

async function main() {
  const opts = parseArgs(process.argv.slice(2));

  if (opts.help) {
    console.log(fs.readFileSync(__filename, 'utf8').split('/* ====')[0].split('【用法】')[1] || '');
    console.log('用法：node tools/get_device_token.js [--local|--log] [--full] [--server URL] [--token TOKEN] [--deviceId ID]');
    return;
  }

  console.log('='.repeat(78));
  console.log('获取当前设备的 HarmonyOS Push Token');
  console.log('='.repeat(78));

  let res = null;
  let source = '';

  if (opts.local) {
    console.log('\n[通道 2] 从本地 data/devices.json 读取');
    res = fromLocal(opts);
    source = '本地文件 ' + DEVICES_FILE;
  } else if (opts.log) {
    console.log('\n[通道 3] 从真机 hilog 诊断');
    res = fromLog(opts);
    source = '真机 hilog';
  } else {
    console.log('\n[通道 1] 从服务端 GET /api/push/devices 读取');
    res = await fromServer(opts);
    source = '服务端接口';
    if (res === null) {
      console.log('\n  通道 1 失败，回退到通道 2（本地文件）...');
      res = fromLocal(opts);
      source = '本地文件（回退）' + DEVICES_FILE;
    }
  }

  if (res === null) {
    console.log('\n未获取到数据。');
    process.exitCode = 1;
    return;
  }

  if (opts.json) {
    console.log(JSON.stringify(res, null, 2));
    return;
  }

  printDevices(res, opts, source);
  console.log('\n' + '='.repeat(78));
}

main().catch((e) => {
  console.error('脚本异常：' + (e && e.stack ? e.stack : String(e)));
  process.exitCode = 1;
});
