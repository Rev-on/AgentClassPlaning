#!/usr/bin/env node
/**
 * test_liveview_progress.js —— 实况窗**进行中进度推送**的离线回归测试
 *
 * 覆盖的需求（"App 退到后台/被杀，桌面实况窗仍显示生成进度"的服务端半边）：
 *   1. 报文结构：push-type 7 / operation 1（**不是 2**）/ activityId / event /
 *      activityData 进度字段 / target.token / JWT
 *   2. event 与客户端创建时一致（客户端 EVENTS 首选 'TIMER'），且**绝不是**
 *      'PROGRESS'（它是布局类型，不是场景名，会 80100003 被拒）
 *   3. activityId 无效（<=0 / 非数字）时**一条报文都不发**（且不发 HTTP 请求）
 *   4. 失败路径（业务 code != 80000000 / HTTP 非 200 / 非 JSON / fetch 抛异常）
 *      一律**不抛出**，只返回 {ok:false}
 *   5. 未配置 AGC 凭据时静默跳过，且**零网络**
 *   6. 节流生效：最小间隔、进度未前进不发（去抖）、百分比单调不减、条数上限
 *   7. 进度估算与客户端 GenProgress 的形状一致（思考 0-25%、正文 25-95%、
 *      未完成封顶 95%）
 *   8. operation 语义分离：更新=1、结束=2，绝不写反
 *   9. 跨端一致性：服务端发送的场景名集合必须都出现在客户端 EVENTS 里
 *
 * 完全不联网、不需要 AGC 凭据、不需要真机：
 * 用运行时自签的 RSA 私钥伪造凭据，并打桩 globalThis.fetch 断言报文。
 *
 * 运行：cd server; node tools/test_liveview_progress.js
 * 退出码：全部通过 => 0，否则 => 1
 */
'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');

/* ------------------------------------------------------------------ *
 * 0. 隔离数据目录：必须在 require('../src/tasks') 之前设置 DATA_DIR
 *    （否则会污染 server/data/ —— 本测试绝不触碰真实数据）
 * ------------------------------------------------------------------ */
const TMP_ROOT = fs.mkdtempSync(path.join(os.tmpdir(), 'liveview-progress-'));
const DATA_DIR = path.join(TMP_ROOT, 'data');
process.env.DATA_DIR = DATA_DIR;

let cleanedUp = false;
function cleanup() {
  if (cleanedUp) {
    return;
  }
  cleanedUp = true;
  try {
    fs.rmSync(TMP_ROOT, { recursive: true, force: true });
  } catch (e) {
    /* 临时目录清理失败不影响结论 */
  }
}

/** 静默被测代码的 console 输出，保持本脚本输出整洁 */
function muteConsole() {
  const saved = { log: console.log, warn: console.warn, error: console.error };
  console.log = () => {};
  console.warn = () => {};
  console.error = () => {};
  return () => {
    console.log = saved.log;
    console.warn = saved.warn;
    console.error = saved.error;
  };
}

/* ------------------------------------------------------------------ *
 * 迷你断言框架（与 test_notify_contract.js 同风格）
 * ------------------------------------------------------------------ */
let passed = 0;
const failures = [];
let currentSuite = '(none)';

function check(ok, desc, detail) {
  if (ok) {
    passed++;
    console.log('    \u2713 ' + desc);
  } else {
    failures.push({ suite: currentSuite, desc, detail });
    console.log('    \u2717 ' + desc + (detail ? '  \u2190 ' + detail : ''));
  }
  return ok;
}

function eq(actual, expected, desc) {
  return check(
    Object.is(actual, expected),
    desc,
    'expected ' + JSON.stringify(expected) + ', got ' + JSON.stringify(actual)
  );
}

function deepEq(actual, expected, desc) {
  let a;
  let b;
  try {
    a = JSON.stringify(actual);
    b = JSON.stringify(expected);
  } catch (e) {
    return check(false, desc, 'JSON.stringify threw: ' + e.message);
  }
  return check(a === b, desc, 'expected ' + b + ', got ' + a);
}

async function runSuite(title, fn) {
  currentSuite = title;
  console.log('\n[' + title + ']');
  try {
    await fn();
  } catch (e) {
    check(false, 'suite threw unexpectedly: ' + (e && e.message ? e.message : String(e)),
      e && e.stack ? String(e.stack).split('\n')[1] : '');
  }
}

/* ------------------------------------------------------------------ *
 * 被测模块
 * ------------------------------------------------------------------ */
const tasks = require('../src/tasks');
const push = require('../src/push');

const ROOT = path.resolve(__dirname, '..', '..');
const CLIENT_LV = path.join(ROOT, 'entry/src/main/ets/common/LiveView.ets');
const SERVER_PUSH = path.join(ROOT, 'server/src/push.js');
const SERVER_JS = path.join(ROOT, 'server/src/server.js');

/* ------------------------------------------------------------------ *
 * fetch 打桩：只记录请求，绝不真的联网
 * ------------------------------------------------------------------ */
const realFetch = globalThis.fetch;

function installCaptureFetchStub(spec) {
  const captured = [];
  globalThis.fetch = async (url, opts) => {
    captured.push({ url, opts });
    const s = typeof spec === 'function' ? spec(captured.length) : spec;
    if (s.throwError) {
      throw s.throwError;
    }
    return {
      status: s.status,
      ok: s.status >= 200 && s.status < 300,
      text: async () => s.body
    };
  };
  return captured;
}

function installThrowingFetchStub() {
  let called = 0;
  globalThis.fetch = () => {
    called++;
    throw new Error('NETWORK ATTEMPT: fetch() was called but must not be');
  };
  return () => called;
}

/* ------------------------------------------------------------------ *
 * 凭据夹具：运行时自签 RSA 私钥（不写死在仓库里）
 * ------------------------------------------------------------------ */
const FAKE_PEM = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 })
  .privateKey.export({ type: 'pkcs8', format: 'pem' });

function enableFakeCredentials() {
  process.env.AGC_PROJECT_ID = 'test-project-lv';
  process.env.AGC_JWT_KID = 'test-kid-lv';
  process.env.AGC_JWT_ISS = 'test-iss-lv';
  process.env.AGC_JWT_PRIVATE_KEY = String(FAKE_PEM);
  delete process.env.AGC_PUSH_ACCOUNT_FILE;
}

function disableCredentials() {
  delete process.env.AGC_PUSH_ACCOUNT_FILE;
  delete process.env.AGC_PROJECT_ID;
  delete process.env.AGC_JWT_KID;
  delete process.env.AGC_JWT_ISS;
  delete process.env.AGC_JWT_PRIVATE_KEY;
}

/** 合法形态的 Push Token（>=40 字符且仅含 [A-Za-z0-9_-]） */
const TOKEN = 'MA' + 'LvTok3n_-'.repeat(10);

/* ------------------------------------------------------------------ *
 * 报文解析助手
 * ------------------------------------------------------------------ */
function bodyOf(captured) {
  try {
    return JSON.parse(captured.opts.body);
  } catch (e) {
    return null;
  }
}

function headerOf(captured, name) {
  const h = (captured.opts && captured.opts.headers) || {};
  const want = String(name).toLowerCase();
  let out;
  Object.keys(h).forEach((k) => {
    if (String(k).toLowerCase() === want) {
      out = h[k];
    }
  });
  return out;
}

/* ================================================================== *
 * 套件 1：更新报文结构（operation 1）
 * ================================================================== */
async function suite1PayloadContract() {
  enableFakeCredentials();
  eq(push.configured(), true, 'configured() === true with runtime-generated fake credentials');
  eq(tasks.isValidToken(TOKEN), true, 'fixture token passes tasks.isValidToken');

  const captured = installCaptureFetchStub({ status: 200, body: JSON.stringify({ code: '80000000' }) });
  const restore = muteConsole();
  let res;
  let threw = null;
  try {
    res = await push.sendLiveViewUpdate({
      token: TOKEN,
      activityId: 123456789,
      event: 'TIMER',
      percent: 42.4,
      title: '教案生成'
    });
  } catch (e) {
    threw = e;
  } finally {
    restore();
  }

  eq(threw, null, 'sendLiveViewUpdate() resolves without throwing on the success path');
  eq(captured.length, 1, 'exactly one HTTP request was made');
  if (captured.length !== 1) {
    return;
  }
  check(!!res && res.ok === true, 'success result has ok === true', 'got ' + JSON.stringify(res));
  eq(res.code, '80000000', 'success result carries code "80000000"');

  const c = captured[0];
  /* --- 头部：push-type 必须是 7（实况窗场景化消息） --- */
  eq(headerOf(c, 'push-type'), '7', 'header push-type is "7" (LiveView scenario message)');
  eq(headerOf(c, 'content-type'), 'application/json', 'header Content-Type is application/json');
  check(String(headerOf(c, 'authorization') || '').indexOf('Bearer ') === 0,
    'Authorization header is a Bearer token');
  eq(c.opts.method, 'POST', 'HTTP method is POST');
  check(String(c.url).indexOf('/messages:send') !== -1, 'URL ends with /messages:send');
  check(String(c.url).indexOf('test-project-lv') !== -1, 'URL contains the configured project id');

  const body = bodyOf(c);
  if (!check(!!body, 'request body parses as JSON')) {
    return;
  }
  const p = body.payload;
  check(!!p, 'body has payload');
  if (!p) {
    return;
  }

  /* --- 关键：operation 必须是 1（更新），绝不能是 2（结束） --- */
  eq(p.operation, 1, 'payload.operation is 1 (UPDATE, not 2=END)');
  eq(p.activityId, 123456789, 'payload.activityId matches the passed activityId');
  eq(typeof p.activityId, 'number', 'payload.activityId is a NUMBER');
  eq(p.event, 'TIMER', 'payload.event matches the passed event');

  /* --- 进度数据 --- */
  check(!!p.activityData, 'payload.activityData is present for an update');
  const nd = p.activityData && p.activityData.notificationData;
  check(!!nd, 'activityData.notificationData is present');
  if (nd) {
    eq(nd.type, 3, 'notificationData.type is 3 (progress layout)');
    const rp = nd.richProgress;
    check(!!rp, 'notificationData.richProgress is present');
    if (rp) {
      eq(typeof rp.progress, 'number', 'richProgress.progress is a NUMBER');
      eq(rp.progress, 42, 'richProgress.progress is the rounded integer percent (42.4 -> 42)');
      check(rp.progress >= 0 && rp.progress <= 100, 'richProgress.progress is within 0..100');
      check(Array.isArray(rp.nodeIcons) && rp.nodeIcons.length >= 1,
        'richProgress.nodeIcons is a non-empty array (Huawei runtime requires it)');
      eq(typeof rp.color, 'string', 'richProgress.color is a string (#AARRGGBB)');
      eq(typeof rp.bgColor, 'string', 'richProgress.bgColor is a string (#AARRGGBB)');
      check(String(rp.indicatorIcon || '').length > 0, 'richProgress.indicatorIcon is set');
    }
  }
  const cap = p.activityData && p.activityData.capsuleData;
  check(!!cap, 'activityData.capsuleData is present');
  if (cap) {
    eq(cap.type, 1, 'capsuleData.type is 1 (progress capsule)');
    check(!!cap.progressData, 'capsuleData.progressData is present');
    if (cap.progressData) {
      eq(cap.progressData.progress, 42, 'capsuleData.progressData.progress mirrors the percent');
      eq(cap.progressData.max, 100, 'capsuleData.progressData.max is 100');
    }
  }

  /* --- 目标与选项 --- */
  check(Array.isArray(body.target && body.target.token), 'target.token is an ARRAY');
  if (Array.isArray(body.target && body.target.token)) {
    eq(body.target.token.length, 1, 'target.token has exactly one entry');
    eq(body.target.token[0], TOKEN, 'target.token[0] is the passed token');
  }
  eq(body.payload.operation === 2, false, 'the update message is NOT an end message');

  /* --- 百分比夹取 --- */
  const captured2 = installCaptureFetchStub({ status: 200, body: JSON.stringify({ code: '80000000' }) });
  const restore2 = muteConsole();
  try {
    await push.sendLiveViewUpdate({ token: TOKEN, activityId: 5, event: 'TIMER', percent: 150, title: 't' });
    await push.sendLiveViewUpdate({ token: TOKEN, activityId: 5, event: 'TIMER', percent: -3, title: 't' });
    await push.sendLiveViewUpdate({ token: TOKEN, activityId: 5, event: 'TIMER', percent: 'NaN?', title: 't' });
  } finally {
    restore2();
  }
  eq(captured2.length, 3, 'three more update requests were issued');
  const pcts = captured2.map((x) => {
    const b = bodyOf(x);
    return b && b.payload && b.payload.activityData.notificationData.richProgress.progress;
  });
  deepEq(pcts, [100, 0, 0], 'percent is clamped into 0..100 (150->100, -3->0, garbage->0)');
}

/* ================================================================== *
 * 套件 2：event 一致性 + 绝不发 PROGRESS
 * ================================================================== */
async function suite2EventConsistency() {
  const captured = installCaptureFetchStub({ status: 200, body: JSON.stringify({ code: '80000000' }) });
  const restore = muteConsole();
  try {
    // 客户端未传 event 时的兜底
    await push.sendLiveViewUpdate({ token: TOKEN, activityId: 7, percent: 10 });
    await push.sendLiveViewEnd({ token: TOKEN, activityId: 7 });
    // 客户端实际生效的 event 必须原样透传
    await push.sendLiveViewUpdate({ token: TOKEN, activityId: 8, event: 'WORKOUT', percent: 10 });
  } finally {
    restore();
  }

  const events = captured.map((x) => {
    const b = bodyOf(x);
    return b && b.payload && b.payload.event;
  });
  deepEq(events, ['TIMER', 'TIMER', 'WORKOUT'],
    "event defaults to 'TIMER' and a client-supplied event is passed through verbatim");
  eq(events.indexOf('PROGRESS'), -1, "no message ever sends event 'PROGRESS' (layout type, not a scenario)");

  // 静态断言：源码里不得出现 event 兜底为 PROGRESS 的写法
  const src = fs.readFileSync(SERVER_PUSH, 'utf8');
  check(!/event\s*\|\|\s*'PROGRESS'/.test(src), "push.js has no 'PROGRESS' event fallback");
  const srv = fs.readFileSync(SERVER_JS, 'utf8');
  check(!/liveView\.event\s*\|\|\s*'PROGRESS'/.test(srv), "server.js has no 'PROGRESS' event fallback");
}

/* ================================================================== *
 * 套件 3：activityId / token / 凭据 无效时不发报文（且零网络）
 * ================================================================== */
async function suite3InvalidTargetSendsNothing() {
  enableFakeCredentials();

  const bad = [0, -1, NaN, undefined, null, 'abc', ''];
  for (let i = 0; i < bad.length; i++) {
    const calls = installThrowingFetchStub();
    const restore = muteConsole();
    let r;
    let threw = null;
    try {
      r = await push.sendLiveViewUpdate({
        token: TOKEN,
        activityId: bad[i],
        event: 'TIMER',
        percent: 50,
        title: 't'
      });
    } catch (e) {
      threw = e;
    } finally {
      restore();
    }
    eq(threw, null, 'invalid activityId ' + JSON.stringify(bad[i]) + ': does not throw');
    check(!!r && r.skipped === true,
      'invalid activityId ' + JSON.stringify(bad[i]) + ': returns {skipped:true}',
      'got ' + JSON.stringify(r));
    eq(calls(), 0, 'invalid activityId ' + JSON.stringify(bad[i]) + ': fetch was NOT called');
  }

  // 同样校验"结束"接口，避免只测一边
  const callsEnd = installThrowingFetchStub();
  const restoreEnd = muteConsole();
  let endRes;
  try {
    endRes = await push.sendLiveViewEnd({ token: TOKEN, activityId: 0 });
  } finally {
    restoreEnd();
  }
  check(!!endRes && endRes.skipped === true, 'sendLiveViewEnd() with activityId 0 returns {skipped:true}');
  eq(callsEnd(), 0, 'sendLiveViewEnd() with activityId 0 made no network call');

  // token 为空：跳过且零网络
  const callsTok = installThrowingFetchStub();
  const restoreTok = muteConsole();
  let tokRes;
  try {
    tokRes = await push.sendLiveViewUpdate({ token: '', activityId: 99, percent: 10 });
  } finally {
    restoreTok();
  }
  check(!!tokRes && tokRes.skipped === true, 'empty token returns {skipped:true}');
  eq(callsTok(), 0, 'empty token made no network call');

  // 未配置凭据：静默跳过且零网络
  disableCredentials();
  eq(push.configured(), false, 'configured() === false after removing credentials');
  const callsNoCred = installThrowingFetchStub();
  const restoreNoCred = muteConsole();
  let noCredRes;
  try {
    noCredRes = await push.sendLiveViewUpdate({ token: TOKEN, activityId: 99, percent: 10 });
  } finally {
    restoreNoCred();
  }
  check(!!noCredRes && noCredRes.skipped === true,
    'unconfigured credentials: returns {skipped:true} (silently skipped)',
    'got ' + JSON.stringify(noCredRes));
  eq(callsNoCred(), 0, 'unconfigured credentials: NO network attempt at all');
}

/* ================================================================== *
 * 套件 4：失败路径一律不抛出
 * ================================================================== */
async function suite4FailuresNeverThrow() {
  enableFakeCredentials();

  const cases = [
    { name: 'business failure code 1003500008 (rate limited)', spec: { status: 200, body: JSON.stringify({ code: '1003500008', msg: 'too frequent' }) } },
    { name: 'business failure code 80100003 (invalid parameter)', spec: { status: 200, body: JSON.stringify({ code: '80100003', msg: 'invalid' }) } },
    { name: 'HTTP 500', spec: { status: 500, body: 'Internal Server Error' } },
    { name: 'non-JSON body', spec: { status: 200, body: '<html>gateway</html>' } },
    { name: 'fetch rejects', spec: { throwError: new Error('ECONNRESET') } },
    { name: 'empty body', spec: { status: 200, body: '' } }
  ];

  for (const c of cases) {
    const captured = installCaptureFetchStub(c.spec);
    const restore = muteConsole();
    let r;
    let threw = null;
    try {
      r = await push.sendLiveViewUpdate({ token: TOKEN, activityId: 555, event: 'TIMER', percent: 30, title: 't' });
    } catch (e) {
      threw = e;
    } finally {
      restore();
    }
    eq(threw, null, c.name + ': does not throw');
    check(!!r && r.ok === false, c.name + ': returns {ok:false}', 'got ' + JSON.stringify(r));
    eq(captured.length, 1, c.name + ': exactly one attempt was made');
  }

  // 业务失败时不得把 skipped/ok:true 混进来
  const captured = installCaptureFetchStub({ status: 200, body: JSON.stringify({ code: '1003500008' }) });
  const restore = muteConsole();
  let r;
  try {
    r = await push.sendLiveViewEnd({ token: TOKEN, activityId: 556 });
  } finally {
    restore();
  }
  eq(captured.length, 1, 'failed end message still attempted the call');
  eq(r.ok, false, 'failed end message reports ok === false');
  eq(r.code, '1003500008', 'failed end message surfaces the Huawei business code');
  eq(r.skipped, undefined, 'failed end message is not reported as skipped');
}

/* ================================================================== *
 * 套件 5：operation 语义分离（更新=1 / 结束=2）
 * ================================================================== */
async function suite5OperationSeparation() {
  enableFakeCredentials();
  const captured = installCaptureFetchStub({ status: 200, body: JSON.stringify({ code: '80000000' }) });
  const restore = muteConsole();
  try {
    await push.sendLiveViewUpdate({ token: TOKEN, activityId: 900, event: 'TIMER', percent: 20, title: 't' });
    await push.sendLiveViewEnd({ token: TOKEN, activityId: 900, event: 'TIMER' });
    await push.sendLiveViewUpdate({ token: TOKEN, activityId: 900, event: 'TIMER', percent: 90, title: 't' });
  } finally {
    restore();
  }
  const ops = captured.map((x) => {
    const b = bodyOf(x);
    return b && b.payload && b.payload.operation;
  });
  deepEq(ops, [1, 2, 1], 'sendLiveViewUpdate sends operation 1 and sendLiveViewEnd sends operation 2');

  // 结构断言：更新报文必须带 activityData，结束报文不带
  const upd = bodyOf(captured[0]);
  const end = bodyOf(captured[1]);
  check(!!upd.payload.activityData, 'the UPDATE message carries activityData');
  eq(end.payload.activityData, undefined, 'the END message carries no activityData (minimal payload)');
  deepEq(Object.keys(end.payload).sort(), ['activityId', 'event', 'operation'],
    'the END message payload has exactly {activityId, event, operation}');
}

/* ================================================================== *
 * 套件 5b：跨端公式逐项相等（回归：服务端补推曾把进度条拉回 5pp）
 *
 * 背景（真实缺陷）：
 *   客户端约 2s 本地更新一次，服务端约 10s 补推一次，**两者交替写入同一个进度条**。
 *   当服务端正文基线还是 25（客户端 30）时，服务端每一次补推都会把客户端刚推进的
 *   进度往回拉最多 5pp。思考模式是本应用默认开启，所以这是主路径。
 *
 * 本套件用**字面量**复刻客户端 GenProgress 的公式（不解析客户端源码表达式，
 * 避免"解析失败=静默假通过"），逐点比对服务端 estimatePercent，容差 ≤ 1pp。
 * ================================================================== */
async function suite5bCrossEndFormulaParity() {
  /* ---- 客户端常量：字面量写死，与 GenProgress.ets 逐项对照 ---- */
  const C_ANCHOR_THINK = 12;
  const C_ANCHOR_BODY_MIN = 30;
  const C_CAP_RUNNING = 95;
  const C_RAMP_START = 3;
  const C_RAMP_ASYMPTOTE = 88;
  const C_RAMP_TAU_MS = 45000;
  const C_SLA_FLOOR_MS = 150000;
  const C_SLA_FLOOR_PCT = 78;
  const C_EXPECT_CHARS = { plan: 4000, courseware: 2600, quiz: 3000, research: 2400,
    analysis: 3200, talk: 2000, report: 2800 };
  const C_DEFAULT_EXPECT = 3000;

  /** 客户端时间的渐近滑轨（复刻 GenProgress.ramp） */
  const clientRamp = (t) => {
    if (!(t > 0)) {
      return C_RAMP_START;
    }
    let v = C_RAMP_START + (C_RAMP_ASYMPTOTE - C_RAMP_START) * (t / (t + C_RAMP_TAU_MS));
    if (t >= C_SLA_FLOOR_MS && v < C_SLA_FLOOR_PCT) {
      v = C_SLA_FLOOR_PCT;
    }
    return v;
  };

  /**
   * 客户端 current() 的期望值（复刻 GenProgress）：
   *   max(阶段锚点, 时间滑轨)，封顶 CAP_RUNNING，四舍五入。
   * @param elapsedMs 已流逝毫秒；startedAt 已按 elapsedMs 反推，故滑轨项一致
   */
  const clientPercent = (kind, len, thinked, elapsedMs, totalChars) => {
    const expect = (totalChars && totalChars > 0) ? totalChars
      : (C_EXPECT_CHARS[kind] === undefined ? C_DEFAULT_EXPECT : C_EXPECT_CHARS[kind]);
    let anchor = 0;
    if (thinked) {
      anchor = Math.max(anchor, C_ANCHOR_THINK);
    }
    if (len > 0) {
      const shaped = Math.pow(Math.min(1, len / expect), 0.85);
      anchor = Math.max(anchor, C_ANCHOR_BODY_MIN + shaped * (C_CAP_RUNNING - C_ANCHOR_BODY_MIN));
    }
    let v = Math.max(anchor, clientRamp(elapsedMs));
    return Math.round(Math.min(v, C_CAP_RUNNING));
  };

  /** 服务端取值：把 startedAt 反推成 elapsedMs 前，使两端的时间项可比 */
  const serverPercent = (kind, len, thinked, elapsedMs, totalChars) => push.estimatePercent(
    { type: kind, liveView: { activityId: 1, event: 'TIMER', totalChars: totalChars || 0 } },
    {
      content: 'x'.repeat(len),
      reasoning: thinked ? 't'.repeat(20) : '',
      startedAt: Date.now() - elapsedMs
    }
  );

  const TOLERANCE = 1; // pp
  const lens = [0, 1, 100, 1000, 4000];
  const thinkStates = [false, true];

  /* ---- 1. 锚点常量逐项相等（直接比对导出的常量，最硬的断言） ---- */
  eq(push.anchors.ANCHOR_THINK, C_ANCHOR_THINK,
    'server ANCHOR_THINK === client ANCHOR_THINK (12)');
  eq(push.anchors.ANCHOR_BODY_MIN, C_ANCHOR_BODY_MIN,
    'server ANCHOR_BODY_MIN === client ANCHOR_BODY_MIN (30)');
  eq(push.anchors.CAP_RUNNING, C_CAP_RUNNING,
    'server CAP_RUNNING === client CAP_RUNNING (95)');
  eq(push.anchors.RAMP_START, C_RAMP_START, 'server RAMP_START === client RAMP_START (3)');
  eq(push.anchors.RAMP_ASYMPTOTE, C_RAMP_ASYMPTOTE,
    'server RAMP_ASYMPTOTE === client RAMP_ASYMPTOTE (88)');
  eq(push.anchors.RAMP_TAU_MS, C_RAMP_TAU_MS, 'server RAMP_TAU_MS === client RAMP_TAU_MS (45000)');
  eq(push.anchors.SLA_FLOOR_MS, C_SLA_FLOOR_MS,
    'server SLA_FLOOR_MS === client SLA_FLOOR_MS (150000)');
  eq(push.anchors.SLA_FLOOR_PCT, C_SLA_FLOOR_PCT,
    'server SLA_FLOOR_PCT === client SLA_FLOOR_PCT (78)');

  // 关键回归：正文基线绝不能回到 25（那正是 5pp 回拉缺陷的根因）
  check(push.anchors.ANCHOR_BODY_MIN !== 25,
    'ANCHOR_BODY_MIN is NOT 25 (the value that caused the 5pp pull-back bug)');
  check(push.anchors.RAMP_ASYMPTOTE < push.anchors.CAP_RUNNING,
    'the time ramp asymptote (88) stays below the running cap (95): ' +
    'a lagging server can never pull a client-raised anchor back down');

  /* ---- 2. 逐点相等：0/1/100/1000/4000 字符 × 有/无思考 ---- */
  // 时间项取 0，隔离出纯"阶段锚点"公式，这才是当初出问题的分支
  for (const thinked of thinkStates) {
    for (const len of lens) {
      const s = serverPercent('plan', len, thinked, 0, 4000);
      const c = clientPercent('plan', len, thinked, 0, 4000);
      const diff = Math.abs(s - c);
      check(diff <= TOLERANCE,
        'plan len=' + len + ' think=' + thinked + ': server ' + s + '% == client ' + c + '%'
        + ' (diff ' + diff + 'pp <= ' + TOLERANCE + ')');
    }
  }

  /* ---- 3. 同样的逐点比对，在滑动的时间轴上（两端时间项都要对） ---- */
  const times = [0, 5000, 45000, 90000, 150000, 300000];
  let maxDiff = 0;
  for (const thinked of thinkStates) {
    for (const len of lens) {
      for (const el of times) {
        const s = serverPercent('plan', len, thinked, el, 4000);
        const c = clientPercent('plan', len, thinked, el, 4000);
        maxDiff = Math.max(maxDiff, Math.abs(s - c));
      }
    }
  }
  check(maxDiff <= TOLERANCE,
    'over the full 0/1/100/1000/4000 x think(2) x time(6) grid the max deviation is '
    + maxDiff + 'pp (<= ' + TOLERANCE + 'pp)');

  /* ---- 4. totalChars 必须被优先使用 ---- */
  // plan 默认预期 4000 字符：正文 4000 字 → 95%
  eq(serverPercent('plan', 4000, false, 0, 0), 95,
    'without totalChars the server uses the type default (plan=4000 -> 95%)');
  // 客户端上报 totalChars=1000 时，4000 字早已超额 → 仍是 95%
  eq(serverPercent('plan', 4000, false, 0, 1000), 95,
    'with totalChars=1000 the same 4000 chars is already over target -> 95%');
  // totalChars=8000 时，4000 字只走了一半
  const half = serverPercent('plan', 4000, false, 0, 8000);
  const halfClient = clientPercent('plan', 4000, false, 0, 8000);
  eq(half, halfClient, 'totalChars=8000 aligns server and client at 4000 chars (' + half + '%)');
  check(half < 95, 'totalChars=8000 keeps the progress below the cap at 4000 chars');

  /* ---- 5. 七个生成类型逐一跨端比对（EXPECT_CHARS 表不得漂移） ---- */
  let typeMaxDiff = 0;
  const typeMismatch = [];
  Object.keys(C_EXPECT_CHARS).forEach((kind) => {
    eq(push.expectChars(kind), C_EXPECT_CHARS[kind],
      "server EXPECT_CHARS['" + kind + "'] === client literal (" + C_EXPECT_CHARS[kind] + ')');
    [0, 1, 100, 1000].forEach((len) => {
      const s = serverPercent(kind, len, true, 30000, 0);
      const c = clientPercent(kind, len, true, 30000, 0);
      const d = Math.abs(s - c);
      if (d > typeMaxDiff) {
        typeMaxDiff = d;
      }
      if (d > TOLERANCE) {
        typeMismatch.push(kind + '@' + len + '(' + s + 'vs' + c + ')');
      }
    });
  });
  check(typeMismatch.length === 0,
    'all 7 generation types agree with the client across 4 lengths (max ' + typeMaxDiff + 'pp)',
    typeMismatch.join(', '));

  /* ---- 6. 单调性：服务端在同一时间轴上绝不回落 ---- */
  let monotonic = true;
  const badStep = [];
  for (const len of [0, 1, 50, 100, 500, 1000, 2000, 3000, 4000, 5000, 8000]) {
    let prev = -1;
    for (const el of times) {
      const s = serverPercent('plan', len, true, el, 4000);
      if (s < prev) {
        monotonic = false;
        badStep.push('len=' + len + ' el=' + el + ' ' + prev + '->' + s);
      }
      prev = s;
    }
  }
  check(monotonic, 'server progress never decreases as content grows and time advances',
    badStep.join(', '));

  /* ---- 7. 不可逆性：时间滑轨永不能把已抬高的锚点拉回去 ---- */
  // 这正是"客户端领先、服务端补推把进度条拉回"的根因判据：
  // 服务端的时间项上界必须严格低于 CAP_RUNNING。
  const maxRamp = clientRamp(24 * 3600 * 1000); // 跑满 24 小时
  check(maxRamp <= C_RAMP_ASYMPTOTE,
    'the time ramp saturates at ' + Math.round(maxRamp) + '% and never reaches the 95% cap');
  const capped = serverPercent('plan', 4000, false, 24 * 3600 * 1000, 4000);
  eq(capped, 95, 'an anchor already at 95% stays at 95% however long the task runs');
}

/* ================================================================== *
 * 套件 6：节流（最小间隔 / 去抖 / 单调 / 条数上限）
 * ================================================================== */
async function suite6Throttle() {
  const th = push.createThrottle({ minIntervalMs: 10000, maxUpdates: 3 });

  // 第一次：立刻发
  const d1 = th.consider('T-throttle', 5, 1000000);
  eq(d1.send, true, 'first progress point is sent immediately');
  eq(d1.seq, 1, 'first send has seq 1');

  // 间隔不足：不发（合并到下一次）
  const d2 = th.consider('T-throttle', 30, 1000000 + 999);
  eq(d2.send, false, 'a point inside the min interval is NOT sent');
  eq(d2.reason, 'too-soon', 'reason is "too-soon" inside the min interval');

  // 间隔足够且进度前进：发
  const d3 = th.consider('T-throttle', 30, 1000000 + 10000);
  eq(d3.send, true, 'after the min interval elapses the update is sent');
  eq(d3.percent, 30, 'the buffered (larger) percent is used, not the stale one');

  // 进度未前进：不发（去抖）
  const d4 = th.consider('T-throttle', 30, 1000000 + 60000);
  eq(d4.send, false, 'an unchanged percent is NOT re-sent (debounce)');
  eq(d4.reason, 'no-progress', 'reason is "no-progress" for an unchanged percent');

  // 进度倒退：不发
  const d5 = th.consider('T-throttle', 12, 1000000 + 90000);
  eq(d5.send, false, 'a decreasing percent is NOT sent (monotonic progress)');

  // 条数上限
  const d6 = th.consider('T-throttle', 40, 1000000 + 120000);
  eq(d6.send, true, 'third distinct progress point is sent (limit is 3)');
  const d7 = th.consider('T-throttle', 80, 1000000 + 200000);
  eq(d7.send, false, 'the 4th point is suppressed: max updates reached');
  eq(d7.reason, 'max-updates', 'reason is "max-updates" once the quota is spent');

  // 单任务相互独立
  const dOther = th.consider('T-other', 5, 1000000 + 200001);
  eq(dOther.send, true, 'a different task id has its own independent bucket');

  // reset 后重新计数
  th.reset('T-throttle');
  const dAfterReset = th.consider('T-throttle', 5, 1000000 + 300000);
  eq(dAfterReset.send, true, 'after reset() the task can send again');
  eq(dAfterReset.seq, 1, 'after reset() the sequence restarts at 1');

  /* --- 用默认配置核对"频率克制"的量级 --- */
  eq(push.liveViewConfig.MIN_UPDATE_MS, 10000, 'default min interval is 10000 ms');
  eq(push.liveViewConfig.MAX_UPDATES, 30, 'default per-task update cap is 30');
  check(push.liveViewConfig.CAP_RUNNING === 95,
    'running progress is capped at 95% (never shows 100% before completion)');
  const perMinute = 60000 / push.liveViewConfig.MIN_UPDATE_MS;
  check(perMinute <= 6, 'the throttle allows at most 6 updates/minute per task (actual ' + perMinute + ')',
    'Huawei rate-limits LiveView updates (1003500008)');
  const totalMinutes = (push.liveViewConfig.MAX_UPDATES * push.liveViewConfig.MIN_UPDATE_MS) / 60000;
  check(totalMinutes >= 4,
    'the cap still covers a ~5 minute generation (actual ' + totalMinutes + ' min of coverage)');
}

/* ================================================================== *
 * 套件 7：进度估算与客户端 GenProgress 形状一致
 * ================================================================== */
async function suite7PercentEstimation() {
  const mk = (o) => Object.assign({ type: 'plan', liveView: { activityId: 1, event: 'TIMER' } }, o);

  // 起手：无内容无思考时由时间滑轨给出 RAMP_START(3%)，与客户端构造时一致
  eq(push.estimatePercent(mk({}), { content: '', reasoning: '', startedAt: Date.now() }), 3,
    'a fresh task shows the ramp start 3% (client RAMP_START)');

  const thinking = push.estimatePercent(mk({}), { content: '', reasoning: 'x'.repeat(50), startedAt: Date.now() });
  eq(thinking, 12, 'thinking only -> 12% (client ANCHOR_THINK), not the old 10%');

  // 正文阶段：30% 起步（客户端 ANCHOR_BODY_MIN），随长度上升
  const p0 = push.estimatePercent(mk({}), { content: 'a', reasoning: '', startedAt: Date.now() });
  eq(p0, 30, 'the first body character lands exactly on ANCHOR_BODY_MIN = 30%');
  const pHalf = push.estimatePercent(mk({}), { content: 'x'.repeat(2000), reasoning: '', startedAt: Date.now() });
  check(pHalf > p0 && pHalf < 95, 'progress rises with body length and stays under the cap (got ' + pHalf + ')');
  // 回归：正文分支绝不能"吞掉"思考锚点（曾经 25 基线无条件覆盖 12 的思考值）
  const thinkPlusBody = push.estimatePercent(mk({}),
    { content: 'x'.repeat(200), reasoning: 'thinking...', startedAt: Date.now() });
  const bodyOnly = push.estimatePercent(mk({}),
    { content: 'x'.repeat(200), reasoning: '', startedAt: Date.now() });
  eq(thinkPlusBody, bodyOnly,
    'with or without thinking the body anchor is identical (no branch is silently overwritten)');
  const pFull = push.estimatePercent(mk({}), { content: 'x'.repeat(40000), reasoning: '', startedAt: Date.now() });
  eq(pFull, 95, 'an over-long body is capped at 95% while running');

  // 预期长度可被 liveView.totalChars 覆盖
  const shortExpect = push.estimatePercent(
    mk({ liveView: { activityId: 1, event: 'TIMER', totalChars: 100 } }),
    { content: 'x'.repeat(100), reasoning: '', startedAt: Date.now() });
  eq(shortExpect, 95, 'liveView.totalChars drives the ratio when the client reports it');

  // 客户端类型预期表与服务端保持一致（防漂移）
  const clientSrc = fs.readFileSync(path.join(ROOT, 'entry/src/main/ets/common/GenProgress.ets'), 'utf8');
  const pairs = [['plan', 4000], ['courseware', 2600], ['quiz', 3000], ['research', 2400],
    ['analysis', 3200], ['talk', 2000], ['report', 2800]];
  let expectTableOk = true;
  const mismatches = [];
  for (const [kind, n] of pairs) {
    const re = new RegExp("'" + kind + "'\\s*:\\s*(\\d+)");
    const m = clientSrc.match(re);
    const got = push.expectChars(kind);
    if (!m || Number(m[1]) !== n || got !== n) {
      expectTableOk = false;
      mismatches.push(kind + '(client=' + (m ? m[1] : '?') + ',server=' + got + ')');
    }
  }
  check(expectTableOk,
    'server EXPECT_CHARS matches the client GenProgress table for all 7 generation types',
    mismatches.join(', '));
  eq(push.expectChars('unknown-type'), 3000, 'unknown type falls back to 3000 chars (client DEFAULT_EXPECT)');

  // 未完成时绝不显示 100%
  for (const len of [0, 1, 500, 5000, 50000, 500000]) {
    const v = push.estimatePercent(mk({ type: 'quiz' }), { content: 'x'.repeat(len), reasoning: '', startedAt: Date.now() });
    check(v <= 95, 'progress with ' + len + ' chars stays <= 95% (got ' + v + ')');
  }
}

/* ================================================================== *
 * 套件 8：跨端一致性（服务端场景名 ∈ 客户端 EVENTS）
 * ================================================================== */
async function suite8CrossEndConsistency() {
  const lvRaw = fs.readFileSync(CLIENT_LV, 'utf8');
  const m = lvRaw.match(/const EVENTS:\s*string\[\]\s*=\s*\[([\s\S]*?)\];/);
  const events = m ? (m[1].match(/'([A-Z_]+)'/g) || []).map((s) => s.replace(/'/g, '')) : [];
  check(events.length >= 10, 'parsed the client EVENTS scenario list', 'count=' + events.length);
  eq(events[0], 'TIMER', "the client's first (preferred) scenario is TIMER");

  // 服务端所有兜底/默认场景名都必须落在客户端的合法清单里
  const srvPush = fs.readFileSync(SERVER_PUSH, 'utf8');
  const srvJs = fs.readFileSync(SERVER_JS, 'utf8');
  const used = new Set();
  [srvPush, srvJs].forEach((src) => {
    const re = /event[^\n]*?\|\|\s*'([A-Z_]+)'/g;
    let x;
    while ((x = re.exec(src)) !== null) {
      used.add(x[1]);
    }
  });
  check(used.size > 0, 'found scenario-name fallbacks in the server source');
  used.forEach((name) => {
    check(events.indexOf(name) !== -1,
      "server fallback scenario '" + name + "' is a legal client scenario");
  });
  eq(used.has('PROGRESS'), false, "the server never falls back to 'PROGRESS'");

  // 服务端进度推送必须使用 push-type 7 与 operation 1/2
  const opUpdate = /operation:\s*1/.test(srvPush);
  const opEnd = /operation:\s*2/.test(srvPush);
  check(opUpdate, 'push.js sends operation 1 for progress updates');
  check(opEnd, 'push.js sends operation 2 for the end message');
  check(/'push-type':\s*'7'/.test(srvPush), "push.js sets header push-type: '7' for LiveView messages");

  // server.js 必须在生成过程中调用进度推送（而不只是完成时结束）
  check(/sendLiveViewUpdate\(/.test(srvJs),
    'server.js calls push.sendLiveViewUpdate during generation (not only at the end)');
  check(/maybeSendLiveViewUpdate\(/.test(srvJs),
    'server.js has a throttled progress dispatcher invoked while streaming');
  check(/liveViewThrottle\.consider\(/.test(srvJs),
    'server.js routes progress through the throttle before sending');
  check(/liveViewFeedbackDone\(/.test(srvJs),
    'server.js releases per-task LiveView state when the task finishes');
  check(/clearInterval\(lvTimer\)/.test(srvJs),
    'the progress heartbeat interval is cleared when streaming ends (no timer leak)');
}

/* ================================================================== *
 * 套件 9：假凭据真签 JWT（证明凭据链路未被破坏）
 * ================================================================== */
async function suite9JwtStillSigned() {
  enableFakeCredentials();
  const captured = installCaptureFetchStub({ status: 200, body: JSON.stringify({ code: '80000000' }) });
  const restore = muteConsole();
  try {
    await push.sendLiveViewUpdate({ token: TOKEN, activityId: 4242, event: 'TIMER', percent: 10, title: 't' });
  } finally {
    restore();
  }
  eq(captured.length, 1, 'one request issued for the JWT check');
  const auth = String(headerOf(captured[0], 'authorization') || '');
  const jwt = auth.replace('Bearer ', '');
  const parts = jwt.split('.');
  eq(parts.length, 3, 'Authorization carries a 3-segment JWT');
  if (parts.length === 3) {
    const pad = (s) => s + (s.length % 4 === 0 ? '' : '='.repeat(4 - (s.length % 4)));
    let hdr = null;
    try {
      hdr = JSON.parse(Buffer.from(pad(parts[0].replace(/-/g, '+').replace(/_/g, '/')), 'base64').toString('utf8'));
    } catch (e) {
      check(false, 'JWT header decodes as base64url JSON', e.message);
    }
    if (hdr) {
      eq(hdr.alg, 'PS256', 'JWT alg is PS256 (Huawei requirement)');
      eq(hdr.kid, process.env.AGC_JWT_KID, 'JWT kid matches the configured AGC_JWT_KID');
    }
    check(parts[2].length > 0, 'JWT signature segment is non-empty (PS256 signature was produced)');
  }
}

/* ================================================================== *
 * 主流程
 * ================================================================== */
async function main() {
  console.log('='.repeat(72));
  console.log('实况窗进度推送（LiveView progress push）— 离线回归测试');
  console.log('node ' + process.version + '  |  DATA_DIR=' + DATA_DIR);
  console.log('='.repeat(72));

  await runSuite('0. 隔离与前置检查', async () => {
    eq(process.env.DATA_DIR, DATA_DIR, 'process.env.DATA_DIR points at the temp dir');
    const realData = path.join(__dirname, '..', 'data');
    check(path.resolve(DATA_DIR) !== path.resolve(realData),
      'DATA_DIR is NOT the real server/data directory');
    check(typeof push.sendLiveViewUpdate === 'function', 'push.sendLiveViewUpdate is exported');
    check(typeof push.createThrottle === 'function', 'push.createThrottle is exported');
    check(typeof push.estimatePercent === 'function', 'push.estimatePercent is exported');
    check(typeof realFetch === 'function', 'a real fetch implementation exists for restore');
  });

  await runSuite('1. 更新报文结构（push-type 7 / operation 1）', suite1PayloadContract);
  await runSuite('2. event 一致性（默认 TIMER，绝不发 PROGRESS）', suite2EventConsistency);
  await runSuite('3. activityId / token / 凭据无效时零网络', suite3InvalidTargetSendsNothing);
  await runSuite('4. 所有失败路径一律不抛出', suite4FailuresNeverThrow);
  await runSuite('5. operation 语义分离（更新=1 / 结束=2）', suite5OperationSeparation);
  await runSuite('5b. 跨端公式逐项相等（防 5pp 回拉回归）', suite5bCrossEndFormulaParity);
  await runSuite('6. 节流与频率克制', suite6Throttle);
  await runSuite('7. 进度估算与客户端形状一致', suite7PercentEstimation);
  await runSuite('8. 跨端一致性与接线检查', suite8CrossEndConsistency);
  await runSuite('9. 假凭据下的 JWT 签名', suite9JwtStillSigned);

  /* --- 收尾：还原全局状态，避免影响其它脚本 --- */
  globalThis.fetch = realFetch;
  disableCredentials();

  const suiteTitles = [
    '0. 隔离与前置检查',
    '1. 更新报文结构（push-type 7 / operation 1）',
    '2. event 一致性（默认 TIMER，绝不发 PROGRESS）',
    '3. activityId / token / 凭据无效时零网络',
    '4. 所有失败路径一律不抛出',
    '5. operation 语义分离（更新=1 / 结束=2）',
    '5b. 跨端公式逐项相等（防 5pp 回拉回归）',
    '6. 节流与频率克制',
    '7. 进度估算与客户端形状一致',
    '8. 跨端一致性与接线检查',
    '9. 假凭据下的 JWT 签名'
  ];
  const failedSuites = [];
  failures.forEach((f) => {
    if (failedSuites.indexOf(f.suite) === -1) {
      failedSuites.push(f.suite);
    }
  });

  console.log('\n' + '='.repeat(72));
  console.log('SUMMARY');
  console.log('  assertion suites run : ' + suiteTitles.length);
  console.log('  assertions passed    : ' + passed);
  console.log('  assertions failed    : ' + failures.length);
  if (failures.length > 0) {
    console.log('\n  FAILED ASSERTIONS:');
    failures.forEach((f, i) => {
      console.log('   ' + (i + 1) + ') [' + f.suite + '] ' + f.desc + (f.detail ? '  \u2190 ' + f.detail : ''));
    });
  }
  console.log('\n  per-suite:');
  suiteTitles.forEach((t) => {
    console.log('   ' + (failedSuites.indexOf(t) !== -1 ? 'FAIL' : 'PASS') + '  ' + t);
  });
  console.log('\n  suites passed : ' + (suiteTitles.length - failedSuites.length) + '/' + suiteTitles.length);
  console.log('  RESULT: ' + (failures.length === 0 ? 'PASS' : 'FAIL')
    + '  (' + passed + ' passed / ' + (passed + failures.length) + ' total assertions)');
  console.log('='.repeat(72));

  // tasks.persist() 是 400ms 防抖写盘：先等它落地再删临时目录，避免 ENOENT 噪声
  await new Promise((r) => setTimeout(r, 600));
  cleanup();
  process.exit(failures.length === 0 ? 0 : 1);
}

process.on('exit', () => {
  globalThis.fetch = realFetch;
  cleanup();
});
process.on('SIGINT', () => {
  cleanup();
  process.exit(1);
});

main().catch((e) => {
  console.error('\nFATAL: test harness crashed');
  console.error(e && e.stack ? e.stack : String(e));
  cleanup();
  process.exit(1);
});
