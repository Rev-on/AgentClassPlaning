#!/usr/bin/env node
/**
 * test_notify_contract.js —— 离线契约测试（无网络 / 无测试框架 / 无新依赖）
 *
 * 覆盖：
 *   1. tasks.create() 对 5 个通知字段的往返（notifySeed 为 NUMBER，缺省为空串/0）
 *   2. tasks.registerDevice() 的 token 合法性校验、tokenOf 回读
 *   3. tasks.listDevices() 只返回合法 token；forgetInvalidTokens() 精确删除并返回数量
 *   4. push.sendAlert() 未配置凭据时 {skipped:true}，不抛异常，且**绝不调用 fetch**
 *   5. push.sendAlert() 配置假凭据（运行时自签 RSA 私钥）时发出的请求契约：
 *      URL / method / headers / payload 结构 / JWT 头
 *   6. 业务失败路径：HTTP 200 + code=80300007，解析出 illegalTokens
 *
 * 重要：本脚本只 require ../src/push 与 ../src/tasks，
 *      不 require ../src/server.js（会启动 HTTP 监听并读取真实 API Key）。
 *
 * 运行：node server/tools/test_notify_contract.js   （仓库根目录执行）
 * 退出码：全部断言通过 => 0，否则 => 1
 */
'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');

/* ------------------------------------------------------------------ *
 * 0. 隔离数据目录：必须在 require('../src/tasks') 之前设置 process.env.DATA_DIR
 * ------------------------------------------------------------------ */
const TMP_ROOT = fs.mkdtempSync(path.join(os.tmpdir(), 'notify-contract-'));
const DATA_DIR = path.join(TMP_ROOT, 'data');
const KEY_FILE = path.join(TMP_ROOT, 'fake-agc-account.json');
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
    /* 临时目录清理失败不应影响测试结论 */
  }
}

// 静默被测代码里的 console.warn/error/log，保持输出整洁（stub 期间不关心）
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
 * 迷你断言框架
 * ------------------------------------------------------------------ */
let passed = 0;
const failures = [];
let currentTest = '(none)';

function check(ok, desc, detail) {
  if (ok) {
    passed++;
    console.log('    \u2713 ' + desc);
  } else {
    failures.push({ test: currentTest, desc, detail });
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

function resetCurrentTest(title, fn) {
  currentTest = title;
  console.log('\n[' + title + ']');
  try {
    return fn();
  } catch (e) {
    return check(false, 'test threw unexpectedly: ' + (e && e.message ? e.message : String(e)),
      e && e.stack ? String(e.stack).split('\n')[1] : '');
  }
}

function runTest(title, fn) {
  resetCurrentTest(title, fn);
}

async function runTestAsync(title, fn) {
  currentTest = title;
  console.log('\n[' + title + ']');
  try {
    await fn();
  } catch (e) {
    check(false, 'test threw unexpectedly: ' + (e && e.message ? e.message : String(e)),
      e && e.stack ? String(e.stack).split('\n')[1] : '');
  }
}

/* ------------------------------------------------------------------ *
 * 被测模块
 * ------------------------------------------------------------------ */
const tasks = require('../src/tasks');
const push = require('../src/push');

/* ------------------------------------------------------------------ *
 * 1. tasks.create() 通知字段往返
 * ------------------------------------------------------------------ */
function testCreateRoundTrip() {
  const created = tasks.create({
    deviceId: 'dev-roundtrip',
    type: 'ai',
    label: '练习',
    system: 'sys',
    user: 'usr',
    notifySeed: 424242,
    notifyTitle: '标题A',
    notifyBody: '正文A',
    notifyFailTitle: '失败标题A',
    notifyFailBody: '失败正文A'
  });

  check(!!created && typeof created === 'object', 'create() returns an object');
  check(typeof created.id === 'string' && created.id.length > 0, 'returned task has a non-empty string id');

  const stored = tasks.get(created.id);
  check(!!stored, 'tasks.get(id) returns the stored task');

  eq(created.notifySeed, 424242, 'created.notifySeed is the number 424242');
  eq(typeof created.notifySeed, 'number', 'typeof notifySeed === "number" (not a string)');
  eq(stored.notifySeed, 424242, 'stored notifySeed round-trips');
  eq(typeof stored.notifySeed, 'number', 'stored typeof notifySeed === "number"');

  eq(created.notifyTitle, '标题A', 'created.notifyTitle round-trips');
  eq(created.notifyBody, '正文A', 'created.notifyBody round-trips');
  eq(created.notifyFailTitle, '失败标题A', 'created.notifyFailTitle round-trips');
  eq(created.notifyFailBody, '失败正文A', 'created.notifyFailBody round-trips');

  eq(stored.notifyTitle, '标题A', 'stored notifyTitle round-trips');
  eq(stored.notifyBody, '正文A', 'stored notifyBody round-trips');
  eq(stored.notifyFailTitle, '失败标题A', 'stored notifyFailTitle round-trips');
  eq(stored.notifyFailBody, '失败正文A', 'stored notifyFailBody round-trips');

  // 缺省值：4 个字符串字段 = ''，notifySeed = 0（NUMBER）
  const bare = tasks.create({ deviceId: 'dev-defaults' });
  eq(bare.notifySeed, 0, 'omitted notifySeed defaults to the number 0');
  eq(typeof bare.notifySeed, 'number', 'typeof default notifySeed === "number"');
  eq(bare.notifyTitle, '', 'omitted notifyTitle defaults to ""');
  eq(bare.notifyBody, '', 'omitted notifyBody defaults to ""');
  eq(bare.notifyFailTitle, '', 'omitted notifyFailTitle defaults to ""');
  eq(bare.notifyFailBody, '', 'omitted notifyFailBody defaults to ""');

  // 数字字符串输入需被强制转为 number（上层 JSON 可能传字符串）
  const coerced = tasks.create({ deviceId: 'dev-coerce', notifySeed: '777' });
  eq(coerced.notifySeed, 777, 'string notifySeed "777" is coerced to the number 777');
  eq(typeof coerced.notifySeed, 'number', 'coerced notifySeed typeof === "number"');
}

/* ------------------------------------------------------------------ *
 * 2. registerDevice / tokenOf
 * ------------------------------------------------------------------ */
const VALID_TOKEN = 'MA' + 'aB3_-'.repeat(12); // 62 chars, [A-Za-z0-9_-] only
const VALID_TOKEN_2 = 'MA' + 'Zz9_-'.repeat(12);

function testRegisterAndTokenOf() {
  check(VALID_TOKEN.length >= 40, 'fixture token is >= 40 chars (actual ' + VALID_TOKEN.length + ')');
  eq(tasks.isValidToken(VALID_TOKEN), true, 'isValidToken(valid) === true');

  eq(tasks.registerDevice('dev-ok', VALID_TOKEN), true, 'registerDevice() accepts a valid 40+ char token');

  const shortToken = 'abc';
  eq(tasks.isValidToken(shortToken), false, 'isValidToken("abc") === false');
  eq(tasks.registerDevice('dev-short', shortToken), false, 'registerDevice() rejects a short token');

  const illegalToken = 'abc!@#';
  eq(tasks.isValidToken(illegalToken), false, 'isValidToken("abc!@#") === false');
  eq(tasks.registerDevice('dev-illegal', illegalToken), false, 'registerDevice() rejects a token with illegal chars');

  // 39 字符（刚好低于下限）也必须被拒绝
  const len39 = 'M'.repeat(39);
  eq(tasks.isValidToken(len39), false, 'isValidToken(39 chars) === false');
  eq(tasks.registerDevice('dev-39', len39), false, 'registerDevice() rejects a 39-char token');

  // 40 字符（刚好等于下限）必须被接受
  const len40 = 'M'.repeat(40);
  eq(tasks.isValidToken(len40), true, 'isValidToken(40 chars) === true (inclusive lower bound)');
  eq(tasks.registerDevice('dev-40', len40), true, 'registerDevice() accepts a 40-char token');

  // 被拒绝的设备不得落库
  eq(tasks.tokenOf('dev-short'), '', 'rejected short token was NOT stored (tokenOf === "")');
  eq(tasks.tokenOf('dev-illegal'), '', 'rejected illegal token was NOT stored (tokenOf === "")');
  eq(tasks.tokenOf('dev-39'), '', 'rejected 39-char token was NOT stored (tokenOf === "")');

  // tokenOf 回读注册成功的值
  eq(tasks.tokenOf('dev-ok'), VALID_TOKEN, 'tokenOf("dev-ok") returns exactly the registered token');
  eq(tasks.tokenOf('dev-40'), len40, 'tokenOf("dev-40") returns exactly the registered token');
  eq(tasks.tokenOf('dev-unknown'), '', 'tokenOf(unknown device) returns ""');

  // 空 deviceId 一律拒绝
  eq(tasks.registerDevice('', VALID_TOKEN), false, 'registerDevice() rejects an empty deviceId');

  // 更新同一设备的 token
  eq(tasks.registerDevice('dev-ok', VALID_TOKEN_2), true, 'registerDevice() accepts a token update for an existing device');
  eq(tasks.tokenOf('dev-ok'), VALID_TOKEN_2, 'tokenOf() reflects the updated token');
  eq(tasks.registerDevice('dev-ok', VALID_TOKEN), true, 'registerDevice() restores the original token');
}

/* ------------------------------------------------------------------ *
 * 3. listDevices / forgetInvalidTokens
 * ------------------------------------------------------------------ */
function testListAndForget() {
  // 本测试自带设备，不依赖测试 2 的残留状态（测试 2 结束时会恢复 dev-ok 的 token）
  const T_A = 'MA' + 'Lis7_-'.repeat(12);   // 62 chars -> 唯一
  const T_B = 'MA' + 'L1s7__'.repeat(12);   // 62 chars -> 唯一
  const T_KEEP = 'MA' + 'K33p_-'.repeat(12);
  eq(tasks.registerDevice('dev-list-a', T_A), true, 'registered device dev-list-a with token A');
  eq(tasks.registerDevice('dev-list-b', T_B), true, 'registered device dev-list-b with token B');
  eq(tasks.registerDevice('dev-list-keep', T_KEEP), true, 'registered device dev-list-keep with token KEEP');

  const before = tasks.listDevices();
  const beforeTokens = before.map((d) => d.token);
  check(beforeTokens.indexOf(T_A) !== -1, 'listDevices() contains token A');
  check(beforeTokens.indexOf(T_B) !== -1, 'listDevices() contains token B');
  check(beforeTokens.indexOf(T_KEEP) !== -1, 'listDevices() contains token KEEP');
  check(beforeTokens.indexOf(VALID_TOKEN) !== -1, 'listDevices() also contains the token registered in suite 2');
  check(beforeTokens.indexOf('abc') === -1, 'listDevices() does NOT contain the rejected short token');
  check(beforeTokens.indexOf('abc!@#') === -1, 'listDevices() does NOT contain the rejected illegal-char token');
  check(before.every((d) => typeof d.token === 'string' && d.token.length >= 40),
    'every entry from listDevices() has a token of length >= 40');
  check(before.every((d) => /^[A-Za-z0-9_-]+$/.test(d.token)),
    'every entry from listDevices() matches /^[A-Za-z0-9_-]+$/');
  check(before.every((d) => typeof d.id === 'string' && d.id.length > 0),
    'every entry from listDevices() carries a device id');

  // 空数组 => 0
  eq(tasks.forgetInvalidTokens([]), 0, 'forgetInvalidTokens([]) returns 0');
  eq(tasks.forgetInvalidTokens(null), 0, 'forgetInvalidTokens(null) returns 0');

  // 不存在的 token => 0（不误删）
  const countBeforeNoop = tasks.listDevices().length;
  eq(tasks.forgetInvalidTokens(['no-such-token-'.repeat(4)]), 0,
    'forgetInvalidTokens(unknown token) returns 0 and removes nothing');
  eq(tasks.listDevices().length, countBeforeNoop, 'device count unchanged after a no-op forget');

  // 精确删除：只删 T_A 与 T_B，不碰 T_KEEP
  const otherTokenPresent = tasks.tokenOf('dev-list-keep');
  eq(otherTokenPresent, T_KEEP, 'the unrelated device still holds token KEEP before the forget');
  const removed = tasks.forgetInvalidTokens([T_A, T_B, 'still-not-a-real-token'.repeat(2)]);
  eq(removed, 2, 'forgetInvalidTokens([deadA, deadB, unknown]) returns exactly 2');

  eq(tasks.tokenOf('dev-list-a'), '', 'forgetInvalidTokens() removed dev-list-a');
  eq(tasks.tokenOf('dev-list-b'), '', 'forgetInvalidTokens() removed dev-list-b');
  eq(tasks.tokenOf('dev-list-keep'), T_KEEP, 'forgetInvalidTokens() did NOT remove the unrelated dev-list-keep');

  const after = tasks.listDevices();
  const afterTokens = after.map((d) => d.token);
  check(afterTokens.indexOf(T_A) === -1, 'listDevices() no longer contains the forgotten token A');
  check(afterTokens.indexOf(T_B) === -1, 'listDevices() no longer contains the forgotten token B');
  check(afterTokens.indexOf(T_KEEP) !== -1, 'listDevices() still contains the untouched token KEEP');
  eq(after.length, countBeforeNoop - 2, 'listDevices() count dropped by exactly 2');

  // 重复清理同一批 => 0（幂等）
  eq(tasks.forgetInvalidTokens([T_A, T_B]), 0,
    'forgetInvalidTokens() of already-removed tokens returns 0 (idempotent)');

  // listDevices() 的过滤逻辑：直接与 isValidToken 保持一致
  check(tasks.listDevices().every((d) => tasks.isValidToken(d.token)),
    'every listDevices() entry passes isValidToken()');
}

/* ------------------------------------------------------------------ *
 * 4. fetch stub 工具
 * ------------------------------------------------------------------ */
const realFetch = globalThis.fetch;

function installFetchStub(impl) {
  const stub = function fetchStub(...args) {
    return impl(...args);
  };
  globalThis.fetch = stub;
  return stub;
}

/** 未配置凭据时必须零网络：任何调用都直接失败 */
function installThrowingFetchStub() {
  let called = 0;
  installFetchStub(() => {
    called++;
    throw new Error('NETWORK ATTEMPT: fetch() was called but no credentials are configured');
  });
  return () => called;
}

function installCaptureFetchStub(responseSpec) {
  const captured = [];
  installFetchStub(async (url, opts) => {
    captured.push({ url, opts });
    return {
      status: responseSpec.status,
      ok: responseSpec.status >= 200 && responseSpec.status < 300,
      text: async () => responseSpec.body
    };
  });
  return captured;
}

function b64urlDecode(seg) {
  const pad = seg.length % 4 === 0 ? '' : '='.repeat(4 - (seg.length % 4));
  return Buffer.from(seg.replace(/-/g, '+').replace(/_/g, '/') + pad, 'base64').toString('utf8');
}

/* ------------------------------------------------------------------ *
 * 5. 未配置凭据：skipped + 不抛 + 绝不 fetch
 * ------------------------------------------------------------------ */
async function testNoCredentials() {
  // 确保没有任何 AGC 凭据残留在当前进程环境中
  delete process.env.AGC_PUSH_ACCOUNT_FILE;
  delete process.env.AGC_PROJECT_ID;
  delete process.env.AGC_JWT_KID;
  delete process.env.AGC_JWT_ISS;
  delete process.env.AGC_JWT_PRIVATE_KEY;

  eq(push.configured(), false, 'push.configured() === false when no AGC_* env vars are set');

  const calls = installThrowingFetchStub();
  const restoreConsole = muteConsole();
  let result;
  let threw = null;
  try {
    result = await push.sendAlert({
      token: VALID_TOKEN_2.length ? 'M'.repeat(50) : '',
      notifyId: 1,
      title: 't',
      body: 'b',
      data: { a: 1 }
    });
  } catch (e) {
    threw = e;
  } finally {
    restoreConsole();
  }

  eq(threw, null, 'sendAlert() resolves without throwing when unconfigured');
  check(!!result && result.skipped === true, 'unconfigured sendAlert() returns {skipped:true}',
    'got ' + JSON.stringify(result));
  eq(result.ok, undefined, 'unconfigured result has no ok field');
  eq(calls(), 0, 'global fetch was NOT called (no network attempt)');

  // token 为空 + 已配置 => 同样跳过（用假凭据验证第二条分支，仍不得 fetch）
  console.log('  -- configured but empty token --');
  const keyPair = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });
  const pem = keyPair.privateKey.export({ type: 'pkcs8', format: 'pem' });
  process.env.AGC_PROJECT_ID = 'test-project-0001';
  process.env.AGC_JWT_KID = 'test-kid-0001';
  process.env.AGC_JWT_ISS = 'test-iss-0001';
  process.env.AGC_JWT_PRIVATE_KEY = String(pem);

  eq(push.configured(), true, 'push.configured() === true with fake credential env vars');

  const calls2 = installThrowingFetchStub();
  const restoreConsole2 = muteConsole();
  let emptyResult;
  let emptyThrew = null;
  try {
    emptyResult = await push.sendAlert({ token: '', notifyId: 1, title: 't', body: 'b', data: {} });
  } catch (e) {
    emptyThrew = e;
  } finally {
    restoreConsole2();
  }
  eq(emptyThrew, null, 'sendAlert() with empty token does not throw');
  check(!!emptyResult && emptyResult.skipped === true, 'sendAlert() with empty token returns {skipped:true}',
    'got ' + JSON.stringify(emptyResult));
  eq(calls2(), 0, 'global fetch was NOT called for the empty-token path');

  return pem; // 供后续测试复用同一把运行时自签私钥
}

/* ------------------------------------------------------------------ *
 * 6. 已配置（假凭据）：成功路径请求契约
 * ------------------------------------------------------------------ */
async function testConfiguredSuccess(pem) {
  const PROJECT_ID = process.env.AGC_PROJECT_ID;
  const TOKEN = 'MA' + 'Tok3n_-'.repeat(10); // 82 chars, valid
  eq(tasks.isValidToken(TOKEN), true, 'fixture push token is valid by tasks.isValidToken');
  eq(String(pem).indexOf('-----BEGIN PRIVATE KEY-----'), 0, 'runtime-generated key exported as PKCS8 PEM');

  const captured = installCaptureFetchStub({ status: 200, body: JSON.stringify({ code: '80000000' }) });
  const restoreConsole = muteConsole();
  let res;
  let threw = null;
  try {
    res = await push.sendAlert({
      token: TOKEN,
      notifyId: 987654321,
      title: '生成完成',
      body: '你的练习已生成',
      data: { kind: 'task', taskId: 'T123', nested: { n: 1 } }
    });
  } catch (e) {
    threw = e;
  } finally {
    restoreConsole();
  }

  eq(threw, null, 'sendAlert() does not throw on the success path');
  eq(captured.length, 1, 'fetch was called exactly once');
  if (captured.length !== 1) {
    return;
  }

  check(!!res && res.ok === true, 'success result has ok === true', 'got ' + JSON.stringify(res));
  eq(res.code, '80000000', 'success result carries code "80000000"');

  const { url, opts } = captured[0];

  /* --- URL / method / headers --- */
  check(typeof url === 'string', 'captured url is a string');
  check(url.indexOf(PROJECT_ID) !== -1, 'request URL contains the configured project id');
  check(url.indexOf('/messages:send') !== -1, 'request URL contains "/messages:send"');
  check(url.indexOf('https://push-api.cloud.huawei.com/v3/') === 0,
    'request URL starts with https://push-api.cloud.huawei.com/v3/');
  eq(opts && opts.method, 'POST', 'request method is POST');

  const headers = (opts && opts.headers) || {};
  const headerNames = Object.keys(headers);
  const headerLookup = {};
  headerNames.forEach((k) => { headerLookup[String(k).toLowerCase()] = headers[k]; });

  eq(headerLookup['push-type'], '0', 'headers include push-type: 0');
  eq(headerLookup['content-type'], 'application/json', 'headers include Content-Type: application/json');

  const auth = String(headerLookup['authorization'] || '');
  check(auth.indexOf('Bearer ') === 0, 'headers include an Authorization value starting with "Bearer "',
    'got ' + JSON.stringify(auth.slice(0, 24)));

  /* --- JWT 结构 --- */
  const jwt = auth.slice('Bearer '.length);
  const jwtParts = jwt.split('.');
  eq(jwtParts.length, 3, 'JWT has exactly 3 dot-separated segments');
  if (jwtParts.length === 3) {
    let jwtHeader = null;
    try {
      jwtHeader = JSON.parse(b64urlDecode(jwtParts[0]));
    } catch (e) {
      check(false, 'JWT header is decodable base64url JSON', e.message);
    }
    if (jwtHeader) {
      eq(jwtHeader.alg, 'PS256', 'JWT header decodes to alg: "PS256"');
      eq(jwtHeader.typ, 'JWT', 'JWT header typ is "JWT"');
      eq(jwtHeader.kid, process.env.AGC_JWT_KID, 'JWT header kid matches AGC_JWT_KID');
    }
    check(jwtParts[1].length > 0, 'JWT payload segment is non-empty');
    check(jwtParts[2].length > 0, 'JWT signature segment is non-empty');
    let jwtPayload = null;
    try {
      jwtPayload = JSON.parse(b64urlDecode(jwtParts[1]));
    } catch (e) {
      check(false, 'JWT payload is decodable base64url JSON', e.message);
    }
    if (jwtPayload) {
      eq(jwtPayload.iss, process.env.AGC_JWT_ISS, 'JWT payload iss matches AGC_JWT_ISS');
      eq(jwtPayload.aud, 'https://oauth-login.cloud.huawei.com/oauth2/v3/token',
        'JWT payload aud is the Huawei OAuth v3 token endpoint');
      eq(typeof jwtPayload.exp, 'number', 'JWT payload exp is a number');
      check(jwtPayload.exp > jwtPayload.iat, 'JWT payload exp is after iat');
    }
  }

  /* --- 请求体 --- */
  check(typeof opts.body === 'string', 'request body is a JSON string');
  let body = null;
  try {
    body = JSON.parse(opts.body);
  } catch (e) {
    check(false, 'request body parses as JSON', e.message);
  }
  if (!body) {
    return;
  }

  check(!!body.payload && !!body.payload.notification, 'body has payload.notification');
  const n = body.payload.notification;

  eq(typeof n.notifyId, 'number', 'payload.notification.notifyId is a NUMBER');
  eq(n.notifyId, 987654321, 'payload.notification.notifyId matches the passed notifyId');
  eq(n.title, '生成完成', 'payload.notification.title matches the passed title');
  eq(n.body, '你的练习已生成', 'payload.notification.body matches the passed body');
  eq(typeof n.category, 'string', 'payload.notification.category is a string');
  eq(n.category, 'WORK', 'payload.notification.category defaults to "WORK"');
  eq(typeof n.slotType, 'number', 'payload.notification.slotType is a number');
  // 默认 1 = SOCIAL_COMMUNICATION，对应客户端 NotifySlot.ets 注册的同名渠道。
  // 必须与客户端一致，否则会落到默认低级别渠道 → 不响铃、无横幅。
  eq(n.slotType, 1, 'payload.notification.slotType defaults to 1 (SOCIAL_COMMUNICATION)');
  eq(n.foregroundShow, false, 'payload.notification.foregroundShow === false');

  check(!!n.clickAction && typeof n.clickAction === 'object', 'payload.notification.clickAction exists');
  eq(n.clickAction.actionType, 0, 'clickAction.actionType is 0');
  deepEq(n.clickAction.data, { kind: 'task', taskId: 'T123', nested: { n: 1 } },
    'clickAction.data deep-equals the passed data object');

  check(!!body.target, 'body has a target object');
  check(Array.isArray(body.target.token), 'target.token is an ARRAY');
  if (Array.isArray(body.target.token)) {
    eq(body.target.token.length, 1, 'target.token has exactly one entry');
    eq(body.target.token[0], TOKEN, 'target.token[0] is exactly the passed token');
    eq(body.target.token.indexOf(TOKEN), 0, 'target.token contains the passed token');
  }

  check(!!body.pushOptions && typeof body.pushOptions === 'object', 'body has pushOptions');
  eq(body.pushOptions.ttl, 86400, 'pushOptions.ttl is 86400');
  eq(body.pushOptions.testMessage, false, 'pushOptions.testMessage is false unless AGC_PUSH_TEST=true');

  /* --- notifyId 强制为 NUMBER：字符串输入也应被 Number() 转换 --- */
  const captured2 = installCaptureFetchStub({ status: 200, body: JSON.stringify({ code: '80000000' }) });
  const restoreConsole2 = muteConsole();
  try {
    await push.sendAlert({ token: TOKEN, notifyId: '12345', title: 'x', body: 'y', data: {} });
  } finally {
    restoreConsole2();
  }
  eq(captured2.length, 1, 'second sendAlert() call performed exactly one fetch');
  if (captured2.length === 1) {
    let body2 = null;
    try {
      body2 = JSON.parse(captured2[0].opts.body);
    } catch (e) {
      /* 由下面的断言报告 */
    }
    if (body2) {
      eq(typeof body2.payload.notification.notifyId, 'number',
        'string notifyId "12345" is sent as a NUMBER');
      eq(body2.payload.notification.notifyId, 12345, 'string notifyId "12345" is coerced to 12345');
    } else {
      check(false, 'second request body parses as JSON');
    }
  }
}

/* ------------------------------------------------------------------ *
 * 7. 已配置（假凭据）：业务失败路径
 * ------------------------------------------------------------------ */
async function testConfiguredFailure() {
  const failEnvelope = {
    code: '80300007',
    msg: JSON.stringify({ illegalTokens: { tokenFormatError: ['dead-token'] } })
  };

  const captured = installCaptureFetchStub({ status: 200, body: JSON.stringify(failEnvelope) });
  const restoreConsole = muteConsole();
  let res;
  let threw = null;
  try {
    res = await push.sendAlert({
      token: 'MA' + 'Dead_-.'.repeat(10),
      notifyId: 42,
      title: 't',
      body: 'b',
      data: { k: 'v' }
    });
  } catch (e) {
    threw = e;
  } finally {
    restoreConsole();
  }

  eq(threw, null, 'sendAlert() does not throw on the business-failure path');
  eq(captured.length, 1, 'fetch was called exactly once on the failure path');
  check(!!res && res.ok === false, 'failure result has ok === false', 'got ' + JSON.stringify(res));
  if (!res) {
    return;
  }
  eq(res.code, '80300007', 'failure result carries code "80300007"');
  eq(res.status, 200, 'failure result records the HTTP status 200 (Huawei returns 200 even on failure)');
  check(Array.isArray(res.illegalTokens), 'failure result illegalTokens is an ARRAY',
    'got ' + JSON.stringify(res.illegalTokens));
  if (Array.isArray(res.illegalTokens)) {
    check(res.illegalTokens.indexOf('dead-token') !== -1,
      'illegalTokens contains "dead-token"', 'got ' + JSON.stringify(res.illegalTokens));
    eq(res.illegalTokens.length, 1, 'illegalTokens contains exactly one entry');
  }
  check(typeof res.body === 'string' && res.body.length > 0, 'failure result includes a response body excerpt');

  // 与 tasks.forgetInvalidTokens 的联动：把解析出的失效 token 交给清理逻辑
  const liveToken = 'MA' + 'L1ve_-'.repeat(10);
  const deadButValidShaped = 'MA' + 'Dead_-'.repeat(10);
  eq(tasks.registerDevice('dev-dead', deadButValidShaped), true,
    'registered a valid-shaped token that Huawei later reports as illegal');
  eq(tasks.registerDevice('dev-live', liveToken), true, 'registered a valid live token');
  eq(tasks.isValidToken('dead-token'), false,
    'the raw "dead-token" from illegalTokens is itself below the 40-char floor');
  const removedNow = tasks.forgetInvalidTokens(res.illegalTokens);
  eq(removedNow, 0, 'forgetInvalidTokens(illegalTokens) removes 0 — raw wire value is not a registered token');
  eq(tasks.tokenOf('dev-live'), liveToken, 'the unrelated live device survived the cleanup attempt');
  eq(tasks.forgetInvalidTokens([deadButValidShaped]), 1,
    'forgetInvalidTokens() does remove a registered token when the reported value matches it');
  eq(tasks.tokenOf('dev-dead'), '', 'the dead device was removed by token match');
}

/* ------------------------------------------------------------------ *
 * 主流程
 * ------------------------------------------------------------------ */
async function main() {
  console.log('='.repeat(72));
  console.log('notify / push contract — offline test');
  console.log('node ' + process.version + '  |  DATA_DIR=' + DATA_DIR);
  console.log('temp root: ' + TMP_ROOT);
  console.log('='.repeat(72));

  // 确认隔离生效：tasks.js 使用的是我们的临时目录
  runTest('0. DATA_DIR isolation', () => {
    eq(process.env.DATA_DIR, DATA_DIR, 'process.env.DATA_DIR points at the temp dir');
    eq(tasks.isValidToken('x'), false, 'tasks module loaded and callable');
    // 真实数据目录不得被本测试写入
    const realData = path.join(__dirname, '..', 'data');
    check(path.resolve(DATA_DIR) !== path.resolve(realData), 'DATA_DIR is NOT the real server/data directory');
  });

  runTest('1. tasks.create() round-trips the five notify fields', testCreateRoundTrip);
  runTest('2. tasks.registerDevice() validates tokens; tokenOf() reads back', testRegisterAndTokenOf);
  runTest('3. tasks.listDevices() filters invalid; forgetInvalidTokens() removes exactly the named ones',
    testListAndForget);

  runTest('4. push.configured() === false before credentials are set', () => {
    delete process.env.AGC_PUSH_ACCOUNT_FILE;
    delete process.env.AGC_PROJECT_ID;
    delete process.env.AGC_JWT_KID;
    delete process.env.AGC_JWT_ISS;
    delete process.env.AGC_JWT_PRIVATE_KEY;
    eq(push.configured(), false, 'configured() is false with no env credentials');
  });

  await runTestAsync('5. push.sendAlert() with NO credentials: skipped, no throw, no fetch', testNoCredentials);

  const pem = String(process.env.AGC_JWT_PRIVATE_KEY);

  // 清理自定义 AGC_* 变量后再测空 token 分支之外的配置读取已由 5 完成
  await runTestAsync('6. push.sendAlert() with fake credentials: outgoing request contract', () => testConfiguredSuccess(pem));
  await runTestAsync('7. push.sendAlert() with code=80300007: parsed illegalTokens', testConfiguredFailure);

  /* --- 收尾 --- */
  globalThis.fetch = realFetch;
  delete process.env.AGC_PROJECT_ID;
  delete process.env.AGC_JWT_KID;
  delete process.env.AGC_JWT_ISS;
  delete process.env.AGC_JWT_PRIVATE_KEY;
  delete process.env.AGC_PUSH_ACCOUNT_FILE;

  const totalTests = 7;
  const testTitles = [
    '0. DATA_DIR isolation',
    '1. tasks.create() round-trips the five notify fields',
    '2. tasks.registerDevice() validates tokens; tokenOf() reads back',
    '3. tasks.listDevices() filters invalid; forgetInvalidTokens() removes exactly the named ones',
    '4. push.configured() === false before credentials are set',
    '5. push.sendAlert() with NO credentials: skipped, no throw, no fetch',
    '6. push.sendAlert() with fake credentials: outgoing request contract',
    '7. push.sendAlert() with code=80300007: parsed illegalTokens'
  ];

  const failedTitles = [];
  failures.forEach((f) => {
    if (failedTitles.indexOf(f.test) === -1) {
      failedTitles.push(f.test);
    }
  });

  console.log('\n' + '='.repeat(72));
  console.log('SUMMARY');
  console.log('  assertion suites run : ' + testTitles.length);
  console.log('  assertions passed    : ' + passed);
  console.log('  assertions failed    : ' + failures.length);
  if (failures.length > 0) {
    console.log('\n  FAILED ASSERTIONS:');
    failures.forEach((f, i) => {
      console.log('   ' + (i + 1) + ') [' + f.test + '] ' + f.desc + (f.detail ? '  \u2190 ' + f.detail : ''));
    });
  }
  console.log('\n  per-suite:');
  testTitles.forEach((t) => {
    const bad = failedTitles.indexOf(t) !== -1;
    console.log('   ' + (bad ? 'FAIL' : 'PASS') + '  ' + t);
  });
  console.log('\n  suites passed : ' + (testTitles.length - failedTitles.length) + '/' + testTitles.length);
  console.log('  RESULT: ' + (failures.length === 0 ? 'PASS' : 'FAIL')
    + '  (' + passed + ' passed / ' + (passed + failures.length) + ' total assertions)');
  console.log('='.repeat(72));

  // tasks.persist() 是 400ms 防抖写；先等它落盘再删临时目录，
  // 否则删除目录后定时器写入会抛出 ENOENT（会把噪声打进 stderr）。
  await sleep(600);
  cleanup();
  globalThis.fetch = realFetch;
  process.exitCode = failures.length === 0 ? 0 : 1;
  return { totalTests, passed, failed: failures.length };
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

main().then(() => {
  // 结论已打印；确保事件循环清空后以确定性的退出码结束
  globalThis.fetch = realFetch;
  process.exit(failures.length === 0 ? 0 : 1);
}).catch((e) => {
  console.error('\nFATAL: test harness crashed');
  console.error(e && e.stack ? e.stack : String(e));
  cleanup();
  process.exit(1);
});

process.on('exit', cleanup);
process.on('SIGINT', () => { cleanup(); process.exit(1); });
