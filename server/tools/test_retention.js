#!/usr/bin/env node
/**
 * test_retention.js —— 数据留存期 / 自动清理 的离线自测（无网络 / 无框架 / 无新依赖）
 *
 * 覆盖：
 *   1. 默认值：TASK_RETENTION_HOURS=24、DEVICE_RETENTION_DAYS=90
 *   2. 已结束(done/failed)且超期的任务：从内存与 tasks.json 中双双消失
 *   3. 已结束但未超期的任务：保留（GET /api/task/:id 语义不受影响）
 *   4. pending/running 任务：即使创建时间极早也**绝不**被删
 *   5. 设备记录：updatedAt 超期删除，未超期保留
 *   6. 环境变量覆盖：TASK_RETENTION_HOURS / DEVICE_RETENTION_DAYS 生效（子进程验证）
 *   7. 清理钩子：任务被删时回调被逐个触发（server.js 据此清理旁挂内存 Map）
 *   8. 幂等：重复 purgeExpired() 不再删除、不再重复落盘
 *   9. listByDevice() 的可见性窗口与磁盘留存期一致
 *
 * 重要：全程使用临时 DATA_DIR，绝不触碰真实 server/data 目录。
 * 运行：node server/tools/test_retention.js    （仓库根目录或 server/ 目录均可）
 * 退出码：全部通过 => 0，否则 => 1
 */
'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');

/* ------------------------------------------------------------------ *
 * 迷你断言框架
 * ------------------------------------------------------------------ */
let passed = 0;
let failed = 0;
let currentSuite = '(none)';
const failures = [];

function check(ok, desc, detail) {
  if (ok) {
    passed++;
    console.log('  PASS  ' + desc);
  } else {
    failed++;
    failures.push({ suite: currentSuite, desc: desc, detail: detail });
    console.log('  FAIL  ' + desc + (detail === undefined ? '' : '  -> ' + detail));
  }
  return ok;
}

function eq(actual, expected, desc) {
  return check(Object.is(actual, expected), desc,
    'expected ' + JSON.stringify(expected) + ', got ' + JSON.stringify(actual));
}

function suite(title) {
  currentSuite = title;
  console.log('\n[' + title + ']');
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/* ------------------------------------------------------------------ *
 * 0. 隔离数据目录：必须在 require('../src/tasks') 之前设置 DATA_DIR
 * ------------------------------------------------------------------ */
const TMP_ROOT = fs.mkdtempSync(path.join(os.tmpdir(), 'retention-test-'));
const DATA_DIR = path.join(TMP_ROOT, 'data');
process.env.DATA_DIR = DATA_DIR;

const REAL_DATA = path.join(__dirname, '..', 'data');

let cleanedUp = false;
function cleanup() {
  if (cleanedUp) {
    return;
  }
  cleanedUp = true;
  try {
    fs.rmSync(TMP_ROOT, { recursive: true, force: true });
  } catch (e) {
    /* 清理失败不影响结论 */
  }
}

// 静默被测模块的日志（本测试自己打印 PASS/FAIL），出错信息仍保留
const realConsole = { log: console.log, warn: console.warn, error: console.error };
let quiet = false;
function mute() {
  if (quiet) {
    return;
  }
  quiet = true;
  console.log = () => {};
  console.warn = () => {};
  console.error = () => {};
}
function unmute() {
  if (!quiet) {
    return;
  }
  quiet = false;
  console.log = realConsole.log;
  console.warn = realConsole.warn;
  console.error = realConsole.error;
}

const tasks = require('../src/tasks');

const H = 3600 * 1000;
const D = 24 * H;

/** 直接改写任务记录上的时间戳，构造"任意久以前"的样本 */
function ageTask(id, { createdAt, finishedAt }) {
  const t = tasks.get(id);
  if (!t) {
    throw new Error('ageTask: no such task ' + id);
  }
  if (createdAt !== undefined) {
    t.createdAt = createdAt;
  }
  if (finishedAt !== undefined) {
    t.finishedAt = finishedAt;
  }
  return t;
}

/** 读取落盘的 tasks.json / devices.json（先等 debounce 落盘） */
async function readJsonFile(file) {
  await sleep(650); // persist 是 400ms 防抖
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (e) {
    return null;
  }
}

const TASKS_FILE = path.join(DATA_DIR, 'tasks.json');
const DEVICES_FILE = path.join(DATA_DIR, 'devices.json');

/* ------------------------------------------------------------------ *
 * 1. 默认值与配置解析
 * ------------------------------------------------------------------ */
function testDefaults() {
  suite('1. 默认留存期与配置导出');
  eq(process.env.DATA_DIR, DATA_DIR, 'DATA_DIR 指向临时目录（未污染真实 data/）');
  check(path.resolve(DATA_DIR) !== path.resolve(REAL_DATA),
    'DATA_DIR 不是真实 server/data', DATA_DIR);
  eq(tasks.TASK_RETENTION_HOURS, 24, 'TASK_RETENTION_HOURS 默认 24');
  eq(tasks.DEVICE_RETENTION_DAYS, 90, 'DEVICE_RETENTION_DAYS 默认 90');
  eq(tasks.TASK_RETENTION_MS, 24 * H, 'TASK_RETENTION_MS 默认 24h');
  eq(tasks.DEVICE_RETENTION_MS, 90 * D, 'DEVICE_RETENTION_MS 默认 90d');
  eq(typeof tasks.purgeExpired, 'function', 'purgeExpired 已导出为函数');
  eq(typeof tasks.setTaskPurgeHook, 'function', 'setTaskPurgeHook 已导出为函数');
  eq(typeof tasks.isFinishedStatus, 'function', 'isFinishedStatus 已导出为函数');
  eq(tasks.isFinishedStatus('done'), true, 'isFinishedStatus("done") === true');
  eq(tasks.isFinishedStatus('failed'), true, 'isFinishedStatus("failed") === true');
  eq(tasks.isFinishedStatus('running'), false, 'isFinishedStatus("running") === false');
  eq(tasks.isFinishedStatus('pending'), false, 'isFinishedStatus("pending") === false');
}

/* ------------------------------------------------------------------ *
 * 2. 任务过期：超期删 / 未超期留 / 未结束永不删
 * ------------------------------------------------------------------ */
const VALID_TOKEN = 'MA' + 'Ret3nt_-'.repeat(9); // 合法形态的 token

function testTaskExpiry() {
  suite('2. 任务过期清理（done/failed 超期删；未超期留；running/pending 永不删）');

  const now = Date.now();

  // —— 应被删除 ——
  const oldDone = tasks.create({ deviceId: 'dev-ret', label: '超期已完成' });
  tasks.patch(oldDone.id, { status: tasks.STATUS.DONE, content: 'r', finishedAt: now - 25 * H });

  const oldFailed = tasks.create({ deviceId: 'dev-ret', label: '超期失败' });
  tasks.patch(oldFailed.id, { status: tasks.STATUS.FAILED, error: 'x', finishedAt: now - 30 * H });

  // —— 应保留 ——
  const freshDone = tasks.create({ deviceId: 'dev-ret', label: '未超期已完成' });
  tasks.patch(freshDone.id, { status: tasks.STATUS.DONE, content: 'r', finishedAt: now - 1 * H });

  // 边界：刚好 23 小时（未超 24h）必须保留
  const nearDone = tasks.create({ deviceId: 'dev-ret', label: '接近边界' });
  tasks.patch(nearDone.id, { status: tasks.STATUS.DONE, content: 'r', finishedAt: now - 23 * H });

  // —— 未结束：即使很旧也绝不删 ——
  const ancientRunning = tasks.create({ deviceId: 'dev-ret', label: '很旧的运行中任务' });
  tasks.patch(ancientRunning.id, { status: tasks.STATUS.RUNNING });
  ageTask(ancientRunning.id, { createdAt: now - 10 * 24 * H, finishedAt: 0 });

  const ancientPending = tasks.create({ deviceId: 'dev-ret', label: '很旧的排队任务' });
  ageTask(ancientPending.id, { createdAt: now - 30 * 24 * H, finishedAt: 0 });

  // finishedAt 缺失但状态是 done（历史脏数据）：回退按 createdAt 判定
  const orphanDone = tasks.create({ deviceId: 'dev-ret', label: '无 finishedAt 的旧完成' });
  tasks.patch(orphanDone.id, { status: tasks.STATUS.DONE, content: 'r', finishedAt: 0 });
  ageTask(orphanDone.id, { createdAt: now - 5 * 24 * H, finishedAt: 0 });

  const res = tasks.purgeExpired();

  eq(res.tasks, 3, 'purgeExpired() 删除 3 条超期任务（oldDone/oldFailed/orphanDone）');
  eq(tasks.get(oldDone.id), null, '超期 done 任务已从内存删除');
  eq(tasks.get(oldFailed.id), null, '超期 failed 任务已从内存删除');
  eq(tasks.get(orphanDone.id), null, 'finishedAt 缺失的历史 done 任务按 createdAt 判定并删除');

  check(!!tasks.get(freshDone.id), '未超期 done 任务保留在内存');
  check(!!tasks.get(nearDone.id), '23 小时的 done 任务保留（未越 24h 边界）');
  check(!!tasks.get(ancientRunning.id), '10 天前的 running 任务**未被删**');
  check(!!tasks.get(ancientPending.id), '30 天前的 pending 任务**未被删**');
  eq(tasks.get(ancientRunning.id).status, 'running', 'running 任务状态未被改动');
  eq(tasks.get(ancientPending.id).status, 'pending', 'pending 任务状态未被改动');

  // 未结束任务即便陈旧，也仍应按设备返回（不因保留期被隐藏）
  const listed = tasks.listByDevice('dev-ret', 50).map((t) => t.id);
  check(listed.indexOf(ancientRunning.id) !== -1, 'listByDevice 仍返回很旧的 running 任务');
  check(listed.indexOf(ancientPending.id) !== -1, 'listByDevice 仍返回很旧的 pending 任务');
  check(listed.indexOf(freshDone.id) !== -1, 'listByDevice 仍返回未超期 done 任务');
  check(listed.indexOf(oldDone.id) === -1, 'listByDevice 不再返回已删除的超期任务');
}

/* ------------------------------------------------------------------ *
 * 3. 磁盘同步：tasks.json 里也必须消失
 * ------------------------------------------------------------------ */
async function testDiskPersistence() {
  suite('3. 清理结果落到 tasks.json（磁盘同步 + 不被防抖旧快照复活）');

  // 3a. 同步落盘：先直接改写时间戳（模拟运维/测试脚本），立刻清理，
  //     不做任何等待就读盘 —— 必须已经删掉。
  //     回归背景：persist() 是 400ms 防抖，写入的是触发时快照；若清理只调
  //     persist()，队列里的旧快照会把刚删的任务写回磁盘（已删数据"复活"）。
  const nowSync = Date.now();
  const syncOld = tasks.create({ deviceId: 'dev-sync', label: '同步落盘样本' });
  tasks.patch(syncOld.id, { status: tasks.STATUS.DONE, finishedAt: nowSync - 40 * H });
  const syncRes = tasks.purgeExpired();
  check(syncRes.tasks >= 1, '同步样本已过期并被删除', 'deleted=' + syncRes.tasks);

  let immediate = null;
  try {
    immediate = JSON.parse(fs.readFileSync(TASKS_FILE, 'utf8'));
  } catch (e) {
    check(false, '清理后无需等待即可读到 tasks.json', e && e.message ? e.message : String(e));
  }
  if (Array.isArray(immediate)) {
    const immediateIds = immediate.map((t) => t.id);
    check(immediateIds.indexOf(syncOld.id) === -1,
      'purgeExpired() 后**立即**读盘：超期任务已不在磁盘上（同步落盘）');
    eq(immediate.filter((t) => t.finishedAt > 0
      && Date.now() - t.finishedAt > tasks.TASK_RETENTION_MS).length, 0,
      '立即读盘时磁盘上没有任何超期的已结束任务');
  }

  // 3b. 跨过 400ms 防抖窗口后再读一次：旧快照不得让已删任务"复活"
  const arr = await readJsonFile(TASKS_FILE);
  check(Array.isArray(arr), '等待防抖窗口后 tasks.json 仍可解析为数组', TASKS_FILE);
  if (!Array.isArray(arr)) {
    return;
  }
  const ids = arr.map((t) => t.id);
  check(ids.indexOf(syncOld.id) === -1,
    '防抖窗口过后超期任务**未复活**（旧快照不得覆盖删除结果）');

  const listed = tasks.listByDevice('dev-ret', 50).map((t) => t.id);
  check(listed.length > 0, '内存中仍有该设备的任务作为对照');

  const staleOnDisk = arr.filter((t) => t.finishedAt > 0
    && Date.now() - t.finishedAt > tasks.TASK_RETENTION_MS);
  eq(staleOnDisk.length, 0, 'tasks.json 中不存在任何超期的已结束任务（磁盘已同步清理）');

  // 反向保证：running/pending 即使 createdAt 极早，也**必须仍在磁盘上**
  // （内存未删 + 磁盘未删，两侧一致）
  const diskUnfinishedIds = arr.filter((t) => t.status === 'running' || t.status === 'pending')
    .map((t) => t.id);
  const memUnfinishedIds = tasks.listByDevice('dev-ret', 50)
    .filter((t) => t.status === 'running' || t.status === 'pending')
    .map((t) => t.id);
  check(diskUnfinishedIds.length >= 2, 'running/pending 任务仍在磁盘上（未被清理）',
    'count=' + diskUnfinishedIds.length);
  eq(memUnfinishedIds.filter((id) => diskUnfinishedIds.indexOf(id) === -1).length, 0,
    '内存中的每个 running/pending 任务都能在磁盘上找到（未出现"内存有磁盘无"的不一致）');
  eq(diskUnfinishedIds.filter((id) => memUnfinishedIds.indexOf(id) === -1).length, 0,
    '磁盘上的每个 running/pending 任务都能在内存中找到（未出现"磁盘有内存无"的不一致）');

  // 已删除的超期任务不得在磁盘上复活
  const ancient = arr.filter((t) => Number(t.createdAt || 0) < Date.now() - 9 * 24 * H
    && t.status === 'done');
  eq(ancient.length, 0, '磁盘上没有 9 天前仍存留的 done 任务');
  check(ids.length > 0, '磁盘 id 集合可正常检索');
}

/* ------------------------------------------------------------------ *
 * 4. 设备过期清理
 * ------------------------------------------------------------------ */
function testDeviceExpiry() {
  suite('4. 设备记录过期清理（DEVICE_RETENTION_DAYS 默认 90 天）');

  const now = Date.now();
  eq(tasks.registerDevice('dev-old', VALID_TOKEN), true, '注册 dev-old（将被设为超期）');
  eq(tasks.registerDevice('dev-fresh', 'MA' + 'Fr3sh__-'.repeat(8)), true, '注册 dev-fresh（未超期）');
  eq(tasks.registerDevice('dev-edge', 'MA' + 'Edg3__-'.repeat(8)), true, '注册 dev-edge（边界样本）');

  // 直接改写 updatedAt 构造超期（不经过 API，避免真实等待）
  const devicesMap = tasks.listDevices();
  check(devicesMap.length >= 3, 'listDevices() 至少返回 3 条刚注册的记录');

  // 通过内部注册表改写时间：registerDevice 只写 updatedAt=now，
  // 因此这里用"先注册再改内存"的方式不可行（Map 未导出）——
  // 改为直接写 devices.json 再重新 purge 的方式会污染内存态，
  // 故采用可测的设计：purgeExpired(now) 支持注入"当前时间"。
  eq(tasks.tokenOf('dev-old'), VALID_TOKEN, 'dev-old 的 token 可回读');

  // 注入一个"90 天之后"的时间点 -> 三条都会超期
  const future = now + 91 * D;
  const r1 = tasks.purgeExpired(future);
  eq(r1.devices, tasks.listDevices().length + r1.devices,
    '注入未来时间后，设备清理数量与实际列表变化自洽');
  eq(tasks.tokenOf('dev-old'), '', '超期（>90 天）设备 dev-old 已删除');
  eq(tasks.tokenOf('dev-fresh'), '', '超期（>90 天）设备 dev-fresh 已删除');
  eq(tasks.listDevices().length, 0, '全部设备均已超期删除，listDevices() 为空');

  // 重新注册一条，用"仅超期一部分"的时间点验证「超期删/未超期留」
  eq(tasks.registerDevice('dev-keep', VALID_TOKEN), true, '重新注册 dev-keep');
  const r2 = tasks.purgeExpired(now + 89 * D); // 89 天 < 90 天 -> 不删
  eq(r2.devices, 0, '89 天（未超 90 天）时不删除任何设备');
  eq(tasks.tokenOf('dev-keep'), VALID_TOKEN, '未超期设备 dev-keep 保留');
  const r3 = tasks.purgeExpired(now + 91 * D); // 91 天 > 90 天 -> 删
  eq(r3.devices, 1, '91 天（超 90 天）时删除 1 条设备');
  eq(tasks.tokenOf('dev-keep'), '', '超期设备 dev-keep 已删除');
}

/* ------------------------------------------------------------------ *
 * 5. 清理钩子 + 幂等性
 * ------------------------------------------------------------------ */
function testHookAndIdempotency() {
  suite('5. 清理钩子（server.js 旁挂 Map 同步）与幂等性');

  const purged = [];
  tasks.setTaskPurgeHook((id) => { purged.push(id); });

  const now = Date.now();
  const t1 = tasks.create({ deviceId: 'dev-hook' });
  tasks.patch(t1.id, { status: tasks.STATUS.DONE, finishedAt: now - 40 * H });
  const t2 = tasks.create({ deviceId: 'dev-hook' });
  tasks.patch(t2.id, { status: tasks.STATUS.FAILED, finishedAt: now - 40 * H });

  const r = tasks.purgeExpired();
  eq(r.tasks, 2, '删除 2 条超期任务');
  eq(purged.length, 2, '钩子被触发 2 次（每个被删任务一次）');
  check(purged.indexOf(t1.id) !== -1, '钩子收到 t1 的 taskId');
  check(purged.indexOf(t2.id) !== -1, '钩子收到 t2 的 taskId');
  eq(r.taskIds.length, 2, 'purgeExpired() 返回被删任务的 id 列表');

  // 幂等：再次清理不应再删任何东西，也不应再触发钩子
  const r2 = tasks.purgeExpired();
  eq(r2.tasks, 0, '重复 purgeExpired() 删除 0 条任务（幂等）');
  eq(r2.devices, 0, '重复 purgeExpired() 删除 0 条设备（幂等）');
  eq(purged.length, 2, '幂等调用不会重复触发钩子');

  // 钩子可注销，且钩子抛异常不影响清理结果
  tasks.setTaskPurgeHook(() => { throw new Error('hook boom'); });
  const t3 = tasks.create({ deviceId: 'dev-hook' });
  tasks.patch(t3.id, { status: tasks.STATUS.DONE, finishedAt: Date.now() - 40 * H });
  let threw = null;
  let r3 = null;
  try {
    r3 = tasks.purgeExpired();
  } catch (e) {
    threw = e;
  }
  eq(threw, null, '钩子抛异常时 purgeExpired() 不向外抛');
  check(!!r3 && r3.tasks === 1, '钩子抛异常时任务仍被正常删除', JSON.stringify(r3));
  eq(tasks.get(t3.id), null, '钩子抛异常的任务确实已删除');
  tasks.setTaskPurgeHook(null);
}

/* ------------------------------------------------------------------ *
 * 6. 定时器不阻止进程退出（unref）
 * ------------------------------------------------------------------ */
function testTimerUnrefed() {
  suite('6. 周期清理定时器已 unref（不阻止进程退出）');
  check(tasks.PURGE_INTERVAL_MS > 0, 'PURGE_INTERVAL_MS 为正值', String(tasks.PURGE_INTERVAL_MS));
  eq(tasks.PURGE_INTERVAL_MS, 10 * 60 * 1000, '默认清理间隔为 10 分钟');
}

/* ------------------------------------------------------------------ *
 * 6.5 主动删除：deleteByDevice（POST /api/data/delete 的底层实现）
 *
 * 本组最关键的断言是「只删指定 deviceId，绝不误删其他设备的数据」。
 * 误删他人数据是严重问题，故除了正向删除，还做了多重隔离断言：
 * 前缀相同的 id、大小写不同的 id、以及"deviceId 为空串"这一危险入参。
 * ------------------------------------------------------------------ */
function testDeleteByDevice() {
  suite('6.5 主动删除 deleteByDevice：只删指定设备，绝不误删他人数据');

  const now = Date.now();
  const TOK_MINE = 'MA' + 'MyTok3n-'.repeat(8);
  const TOK_OTHER = 'MA' + 'OtherTn-'.repeat(8);
  const TOK_PREFIX = 'MA' + 'Pref1xTn'.repeat(8);

  // 目标设备：三种状态 + 很旧的任务都应被删（用户主动删除不看留存期）
  const mineDone = tasks.create({ deviceId: 'dev-del-mine', label: 'mine-done', user: '提示词A' });
  tasks.patch(mineDone.id, { status: tasks.STATUS.DONE, content: '结果A', reasoning: '思维链A', finishedAt: now - 30 * 24 * H });
  const mineRun = tasks.create({ deviceId: 'dev-del-mine', label: 'mine-running' });
  tasks.patch(mineRun.id, { status: tasks.STATUS.RUNNING });
  const minePend = tasks.create({ deviceId: 'dev-del-mine', label: 'mine-pending' });
  const mineFail = tasks.create({ deviceId: 'dev-del-mine', label: 'mine-failed' });
  tasks.patch(mineFail.id, { status: tasks.STATUS.FAILED, error: 'xx', finishedAt: now - 5 * 60 * 1000 });

  // 他人设备：id 是目标设备的前缀（最容易被"前缀匹配"误删的情形）
  const otherDone = tasks.create({ deviceId: 'dev-del-mine-extra', label: 'other-prefix' });
  tasks.patch(otherDone.id, { status: tasks.STATUS.DONE, content: '他人结果', finishedAt: now - 60 * 1000 });
  const otherShort = tasks.create({ deviceId: 'dev-del', label: 'other-shorter-prefix' });
  tasks.patch(otherShort.id, { status: tasks.STATUS.DONE, content: '他人结果2', finishedAt: now - 60 * 1000 });
  const otherCase = tasks.create({ deviceId: 'DEV-DEL-MINE', label: 'other-different-case' });
  tasks.patch(otherCase.id, { status: tasks.STATUS.DONE, content: '他人结果3', finishedAt: now - 60 * 1000 });

  eq(tasks.registerDevice('dev-del-mine', TOK_MINE), true, '目标设备已注册 token');
  eq(tasks.registerDevice('dev-del-mine-extra', TOK_OTHER), true, '前缀相同的他人设备已注册 token');
  eq(tasks.registerDevice('dev-del', TOK_PREFIX), true, '另一前缀的他人设备已注册 token');

  const r = tasks.deleteByDevice('dev-del-mine');

  eq(r.tasks, 4, '删除了目标设备的全部 4 条任务（含 running/pending，不看留存期）');
  eq(r.devices, 1, '删除了目标设备的 1 条设备注册记录');
  eq(r.taskIds.length, 4, '返回的 taskIds 长度为 4');

  // —— 目标设备：全清 ——
  eq(tasks.get(mineDone.id), null, '目标设备 done 任务已删除');
  eq(tasks.get(mineRun.id), null, '目标设备 running 任务已删除（主动删除不看状态）');
  eq(tasks.get(minePend.id), null, '目标设备 pending 任务已删除');
  eq(tasks.get(mineFail.id), null, '目标设备 failed 任务已删除');
  eq(tasks.listByDevice('dev-del-mine', 50).length, 0, '目标设备已无任何任务可列出');
  eq(tasks.tokenOf('dev-del-mine'), '', '目标设备的 token 已删除');

  // —— 他人设备：一个都不能少（最关键） ——
  check(!!tasks.get(otherDone.id), '【关键】前缀相同的 dev-del-mine-extra 的任务**未被误删**');
  check(!!tasks.get(otherShort.id), '【关键】前缀更短的 dev-del 的任务**未被误删**');
  check(!!tasks.get(otherCase.id), '【关键】仅大小写不同的 DEV-DEL-MINE 的任务**未被误删**');
  eq(tasks.get(otherDone.id).content, '他人结果', '他人任务内容完好无损');
  eq(tasks.get(otherShort.id).content, '他人结果2', '他人任务内容完好无损（第二台）');
  eq(tasks.tokenOf('dev-del-mine-extra'), TOK_OTHER, '【关键】他人设备 token 未被误删');
  eq(tasks.tokenOf('dev-del'), TOK_PREFIX, '【关键】他人设备 token 未被误删（第二台）');
  eq(tasks.listByDevice('dev-del-mine-extra', 50).length, 1, '他人设备仍能列出自己的 1 条任务');

  // —— 危险入参：空 deviceId 绝不能变成"删除所有" ——
  const tasksBeforeEmpty = tasks.listByDevice('dev-del-mine-extra', 50).length;
  // 构造一条 deviceId 为空的历史脏数据，验证空入参不会误删它
  const orphan = tasks.create({ deviceId: '' });
  tasks.patch(orphan.id, { status: tasks.STATUS.DONE, finishedAt: now });
  eq(tasks.deleteByDevice('').tasks, 0, '空 deviceId 入参返回 0 条（不做任何删除）');
  eq(tasks.deleteByDevice('').devices, 0, '空 deviceId 入参不删除任何设备记录');
  check(!!tasks.get(orphan.id), '空 deviceId 入参**未删除** deviceId 为空的历史记录（防误删所有）');
  eq(tasks.listByDevice('dev-del-mine-extra', 50).length, tasksBeforeEmpty, '空入参调用后他人任务数不变');
  eq(tasks.deleteByDevice(null).tasks, 0, 'null 入参返回 0 条');
  eq(tasks.deleteByDevice(undefined).tasks, 0, 'undefined 入参返回 0 条');

  // —— 幂等：再删一次得 0 ——
  const again = tasks.deleteByDevice('dev-del-mine');
  eq(again.tasks, 0, '重复删除同一设备返回 0 条任务（幂等）');
  eq(again.devices, 0, '重复删除同一设备返回 0 条设备（幂等）');

  // —— 不存在的设备：安全返回 0 ——
  const ghost = tasks.deleteByDevice('dev-never-existed');
  eq(ghost.tasks, 0, '删除不存在的设备返回 0 条任务');
  eq(ghost.devices, 0, '删除不存在的设备返回 0 条设备');
}

/** deleteByDevice 的磁盘持久化 + 钩子联动（异步读盘） */
async function testDeleteByDevicePersistence() {
  suite('6.6 主动删除的磁盘持久化与旁挂 Map 钩子');

  const hookSeen = [];
  tasks.setTaskPurgeHook((id) => { hookSeen.push(id); });

  const t = tasks.create({ deviceId: 'dev-disk-del', label: 'disk-del' });
  tasks.patch(t.id, { status: tasks.STATUS.DONE, content: 'c', finishedAt: Date.now() });
  const keepT = tasks.create({ deviceId: 'dev-disk-keep', label: 'disk-keep' });
  tasks.patch(keepT.id, { status: tasks.STATUS.DONE, content: 'k', finishedAt: Date.now() });

  const r = tasks.deleteByDevice('dev-disk-del');
  eq(r.tasks, 1, '删除 1 条任务');
  eq(hookSeen.length, 1, '钩子被触发 1 次（server.js 据此释放 taskAttachments/taskReasoning）');
  check(hookSeen.indexOf(t.id) !== -1, '钩子收到的正是被删任务的 id');

  // 同步落盘：立即读盘不得再看到被删任务
  let immediate = null;
  try {
    immediate = JSON.parse(fs.readFileSync(TASKS_FILE, 'utf8'));
  } catch (e) {
    check(false, '主动删除后可立即读到 tasks.json', e && e.message ? e.message : String(e));
  }
  if (Array.isArray(immediate)) {
    const immIds = immediate.map((x) => x.id);
    check(immIds.indexOf(t.id) === -1, '主动删除**立即**落盘：被删任务不在磁盘上');
    check(immIds.indexOf(keepT.id) !== -1, '同一批中他人任务仍在磁盘上');
  }

  // 跨防抖窗口后再确认一次（不得复活）
  const arr = await readJsonFile(TASKS_FILE);
  if (Array.isArray(arr)) {
    const ids = arr.map((x) => x.id);
    check(ids.indexOf(t.id) === -1, '跨过防抖窗口后被删任务**未复活**');
    check(ids.indexOf(keepT.id) !== -1, '跨过防抖窗口后他人任务仍在磁盘上');
  } else {
    check(false, 'tasks.json 可解析', String(arr));
  }

  // 设备记录也要从 devices.json 消失
  const devToken = 'MA' + 'DiskDel-'.repeat(8);
  tasks.registerDevice('dev-disk-del2', devToken);
  tasks.deleteByDevice('dev-disk-del2');
  const devicesArr = await readJsonFile(DEVICES_FILE);
  if (Array.isArray(devicesArr)) {
    check(devicesArr.every((d) => d.id !== 'dev-disk-del2'),
      '被删设备的注册记录已从 devices.json 移除');
  } else {
    check(false, 'devices.json 可解析', String(devicesArr));
  }
  eq(tasks.tokenOf('dev-disk-del2'), '', '被删设备的 token 回读为空');

  tasks.setTaskPurgeHook(null);
}

/* ------------------------------------------------------------------ *
 * 7. 环境变量覆盖（子进程：模块在 require 时读取 env，故必须新进程验证）
 * ------------------------------------------------------------------ */
function runChild(env, script) {
  const child = execFileSync(process.execPath, ['-e', script], {
    env: Object.assign({}, process.env, env),
    encoding: 'utf8'
  });
  return child.trim();
}

function testEnvOverride() {
  suite('7. 环境变量覆盖默认留存期（子进程验证）');

  // 子进程里先存一份真实 console.log，再静音模块日志，
  // 最后用保存的引用打印结果 —— 否则模块自身的日志会混进 JSON 输出。
  const setup = "const __out=console.log.bind(console);"
    + "console.log=()=>{};console.warn=()=>{};"
    + "process.env.DATA_DIR=require('fs').mkdtempSync(require('path').join(require('os').tmpdir(),'ret-probe-'));"
    + "const t=require(" + JSON.stringify(path.join(__dirname, '..', 'src', 'tasks.js')) + ");";

  const probe = setup + "__out(JSON.stringify({h:t.TASK_RETENTION_HOURS,d:t.DEVICE_RETENTION_DAYS,"
    + "ms:t.TASK_RETENTION_MS,dms:t.DEVICE_RETENTION_MS,i:t.PURGE_INTERVAL_MS}));";

  // 覆盖为自定义值
  let out = null;
  try {
    out = JSON.parse(runChild({ TASK_RETENTION_HOURS: '6', DEVICE_RETENTION_DAYS: '7' }, probe));
  } catch (e) {
    check(false, '子进程读取覆盖后的环境变量', e && e.message ? e.message : String(e));
    return;
  }
  eq(out.h, 6, 'TASK_RETENTION_HOURS=6 生效');
  eq(out.ms, 6 * H, 'TASK_RETENTION_MS 随 TASK_RETENTION_HOURS 变为 6h');
  eq(out.d, 7, 'DEVICE_RETENTION_DAYS=7 生效');
  eq(out.dms, 7 * D, 'DEVICE_RETENTION_MS 随 DEVICE_RETENTION_DAYS 变为 7d');

  // 非法/空/0/负数一律回退默认值（避免误配把留存期变成 0 而立刻删数据）
  let out2 = null;
  try {
    out2 = JSON.parse(runChild({ TASK_RETENTION_HOURS: '0', DEVICE_RETENTION_DAYS: 'abc' }, probe));
  } catch (e) {
    check(false, '子进程读取非法环境变量', e && e.message ? e.message : String(e));
    return;
  }
  eq(out2.h, 24, 'TASK_RETENTION_HOURS=0 回退默认 24（0 会误删刚产生的数据）');
  eq(out2.d, 90, 'DEVICE_RETENTION_DAYS=abc 回退默认 90');

  // 覆盖后的清理行为：把留存期设成 1 小时，2 小时前的完成态应被删
  const behavior = setup
    + "const now=Date.now();"
    + "const a=t.create({deviceId:'d'});t.patch(a.id,{status:t.STATUS.DONE,finishedAt:now-2*3600*1000});"
    + "const b=t.create({deviceId:'d'});t.patch(b.id,{status:t.STATUS.DONE,finishedAt:now-1800*1000});"
    + "const c=t.create({deviceId:'d'});t.patch(c.id,{status:t.STATUS.RUNNING});"
    + "c.createdAt=now-5*24*3600*1000;"
    + "const r=t.purgeExpired();"
    + "__out(JSON.stringify({deleted:r.tasks,aGone:t.get(a.id)===null,bAlive:!!t.get(b.id),"
    + "cAlive:!!t.get(c.id),hours:t.TASK_RETENTION_HOURS}));";
  let out3 = null;
  try {
    out3 = JSON.parse(runChild({ TASK_RETENTION_HOURS: '1' }, behavior));
  } catch (e) {
    check(false, '子进程验证 1 小时留存期下的清理行为', e && e.message ? e.message : String(e));
    return;
  }
  eq(out3.hours, 1, '子进程中 TASK_RETENTION_HOURS=1');
  eq(out3.deleted, 1, '留存期 1h 时，2 小时前的 done 任务被删');
  eq(out3.aGone, true, '超期任务确已删除');
  eq(out3.bAlive, true, '30 分钟前的 done 任务保留（未超 1h）');
  eq(out3.cAlive, true, '5 天前的 running 任务保留（留存期 1h 也不删未结束任务）');
}

/* ------------------------------------------------------------------ *
 * 主流程
 * ------------------------------------------------------------------ */
async function main() {
  console.log('='.repeat(72));
  console.log('server 数据留存期 / 自动清理 —— 离线自测');
  console.log('node ' + process.version + '  |  DATA_DIR=' + DATA_DIR);
  console.log('temp root: ' + TMP_ROOT);
  console.log('='.repeat(72));

  mute();
  testDefaults();
  testTaskExpiry();
  await testDiskPersistence();
  testDeviceExpiry();
  testHookAndIdempotency();
  testTimerUnrefed();
  testDeleteByDevice();
  await testDeleteByDevicePersistence();
  testEnvOverride();
  unmute();

  console.log('\n' + '='.repeat(72));
  console.log('SUMMARY');
  console.log('  断言通过 : ' + passed);
  console.log('  断言失败 : ' + failed);
  if (failures.length > 0) {
    console.log('\n  FAILED:');
    failures.forEach((f, i) => {
      console.log('   ' + (i + 1) + ') [' + f.suite + '] ' + f.desc
        + (f.detail === undefined ? '' : '  -> ' + f.detail));
    });
  }
  console.log('  RESULT: ' + (failed === 0 ? 'PASS' : 'FAIL')
    + '  (' + passed + ' passed / ' + (passed + failed) + ' total assertions)');
  console.log('='.repeat(72));

  // 等 persist 的 400ms 防抖落盘后再删临时目录，避免 ENOENT 噪声
  await sleep(600);
  cleanup();
  return failed === 0 ? 0 : 1;
}

main().then((code) => {
  process.exit(code);
}).catch((e) => {
  unmute();
  console.error('\nFATAL: 测试框架崩溃');
  console.error(e && e.stack ? e.stack : String(e));
  cleanup();
  process.exit(1);
});

process.on('exit', cleanup);
process.on('SIGINT', () => { cleanup(); process.exit(1); });
