/**
 * 后台生成任务：存储 + 串行队列 + 持久化
 * 设计：客户端提交"生成任务"后立即返回，即使客户端进程被杀，任务仍在服务端继续，
 *       完成后可经 Push Kit 推送完成通知（或由客户端下次进入时主动拉取结果）。
 */
const fs = require('fs');
const path = require('path');

const DATA_DIR = process.env.DATA_DIR || path.join(__dirname, '..', 'data');
const TASKS_FILE = path.join(DATA_DIR, 'tasks.json');
const DEVICES_FILE = path.join(DATA_DIR, 'devices.json');

fs.mkdirSync(DATA_DIR, { recursive: true });

const tasks = new Map();      // id -> task
const devices = new Map();    // deviceId -> { token, updatedAt }
let saveTimer = null;

function loadFromFile(file, map) {
  try {
    const arr = JSON.parse(fs.readFileSync(file, 'utf8'));
    if (Array.isArray(arr)) {
      arr.forEach((item) => map.set(item.id || item.deviceId, item));
    }
  } catch (e) {
    // 首次启动或文件损坏时忽略
  }
}

function persist() {
  if (saveTimer) {
    clearTimeout(saveTimer);
  }
  saveTimer = setTimeout(() => {
    saveTimer = null;
    writeNow();
  }, 400);
}

/** 立即把当前内存态写盘 */
function writeNow() {
  try {
    fs.writeFileSync(TASKS_FILE, JSON.stringify([...tasks.values()], null, 2));
    fs.writeFileSync(DEVICES_FILE, JSON.stringify([...devices.values()], null, 2));
  } catch (e) {
    console.error('[tasks] 持久化失败: ' + (e && e.message ? e.message : String(e)));
  }
}

/**
 * 取消尚未触发的防抖写入并**立即落盘**。
 *
 * 为什么清理必须用它：
 *   persist() 是 400ms 防抖，且写入的是**触发时**的内存快照。
 *   若清理后只调 persist()，会留下一个"已排队但未执行"的定时器；
 *   在它触发前若又有人直接改写任务字段，这份旧快照就会把刚删掉的任务
 *   写回磁盘 —— 已删数据"复活"（实测复现过）。
 *   purgeExpired 属于不可逆的删除操作，必须同步落盘且不被旧快照覆盖。
 */
function flushPersist() {
  if (saveTimer) {
    clearTimeout(saveTimer);
    saveTimer = null;
  }
  writeNow();
}

loadFromFile(TASKS_FILE, tasks);
loadFromFile(DEVICES_FILE, devices);

/** 任务状态枚举 */
const STATUS = { PENDING: 'pending', RUNNING: 'running', DONE: 'done', FAILED: 'failed' };

function newId() {
  return 'T' + Date.now().toString(36) + Math.random().toString(36).slice(2, 8);
}

/** 创建任务记录并返回 */
function create({ deviceId, type, label, system, user, notifySeed, notifyTitle, notifyBody, notifyFailTitle, notifyFailBody, subject, grade, thinking }) {
  const task = {
    id: newId(),
    deviceId: String(deviceId || ''),
    type: String(type || 'ai'),
    label: String(label || '内容'),
    system: String(system || ''),
    user: String(user || ''),
    notifySeed: Number(notifySeed || 0),
    notifyTitle: String(notifyTitle || ''),
    notifyBody: String(notifyBody || ''),
    notifyFailTitle: String(notifyFailTitle || ''),
    notifyFailBody: String(notifyFailBody || ''),
    // RAG 学科路由用（客户端可显式传学科/年级；缺省时服务端从 user 文本解析）
    subject: String(subject || ''),
    grade: Number(grade || 0),
    // 深度思考：true 时启用思维链，思考过程存于 reasoning（供重连/轮询补齐展示）
    thinking: thinking === true,
    reasoning: '',
    status: STATUS.PENDING,
    createdAt: Date.now(),
    finishedAt: 0,
    content: '',
    error: '',
    rag: null
  };
  tasks.set(task.id, task);
  persist();
  return task;
}

function get(id) {
  return tasks.get(String(id)) || null;
}

/* ---------------- 数据留存与自动清理 ---------------- */

/**
 * 为什么要清理（合规背景）：
 *   tasks.json 里的任务包含 deviceId、学科/年级、用户提示词、生成结果、思维链(reasoning)，
 *   devices.json 里是设备 Push Token。此前这些数据**只增不删**，属于"无限期留存"，
 *   隐私协议无法如实写明留存期限。这里把留存期做成可配置项，并把清理真正落到磁盘。
 *
 * 设计要点：
 *   - 任务：只有**已结束**的任务（done/failed）才会过期清理，pending/running 永不删；
 *     默认 24 小时，与 listByDevice() 里"已完成超 24h 不返回"的既有语义保持一致
 *     （即：对客户端可见性与磁盘留存同步为同一期限）。
 *   - 设备：devices.json 中 updatedAt 超过留存期的记录删除（长期不活跃设备的 token 不永久留存）。
 *   - 解析容错：环境变量为空/非法/为 0/负数时一律回退默认值 —— 避免误配把留存期变成 0
 *     而把刚刚产生的数据立刻删掉。
 */
function envNum(raw, fallback) {
  const n = Number(raw);
  return Number.isFinite(n) && n > 0 ? n : fallback;
}

const TASK_RETENTION_HOURS = envNum(process.env.TASK_RETENTION_HOURS, 24);
const DEVICE_RETENTION_DAYS = envNum(process.env.DEVICE_RETENTION_DAYS, 90);
const TASK_RETENTION_MS = TASK_RETENTION_HOURS * 3600 * 1000;
const DEVICE_RETENTION_MS = DEVICE_RETENTION_DAYS * 24 * 3600 * 1000;
/** 周期清理间隔（默认 10 分钟，可用 PURGE_INTERVAL_MS 覆盖） */
const PURGE_INTERVAL_MS = envNum(process.env.PURGE_INTERVAL_MS, 10 * 60 * 1000);

/** purgeExpired 的可插拔钩子：任务被删除时，让 server.js 同步清理旁挂的内存 Map */
let onTaskPurged = null;

/**
 * 注册"任务被清理"回调。
 * 为什么需要：server.js 里 taskAttachments / taskReasoning / taskAborters / feedSubs
 * 是以 taskId 为键的旁挂 Map，任务从 tasks 表删除后若不同步删除，这些键会永久残留（内存泄漏）。
 * @param {(id:string)=>void} fn
 */
function setTaskPurgeHook(fn) {
  onTaskPurged = typeof fn === 'function' ? fn : null;
}

/** 任务是否已结束（只有已结束的任务才会被过期清理） */
function isFinishedStatus(status) {
  return status === STATUS.DONE || status === STATUS.FAILED;
}

/** 任务过期基准时间：优先 finishedAt，异常缺失时回退 createdAt */
function taskExpireBase(t) {
  const fin = Number(t.finishedAt || 0);
  return fin > 0 ? fin : Number(t.createdAt || 0);
}

/**
 * 清理过期数据（任务 + 设备）。
 * 可安全重复调用（幂等）；只有真的删掉了东西才重新落盘。
 * @param {number} [now] 当前时间（毫秒），便于测试注入
 * @returns {{tasks:number, devices:number, taskIds:string[]}}
 */
function purgeExpired(now) {
  const at = Number.isFinite(Number(now)) && Number(now) > 0 ? Number(now) : Date.now();
  const removedTaskIds = [];

  for (const [id, t] of [...tasks]) {
    if (!isFinishedStatus(t.status)) {
      continue; // pending/running 永不清理
    }
    const base = taskExpireBase(t);
    if (base > 0 && at - base > TASK_RETENTION_MS) {
      tasks.delete(id);
      removedTaskIds.push(id);
    }
  }

  const removedDeviceIds = [];
  for (const [id, d] of [...devices]) {
    const base = Number((d && d.updatedAt) || 0);
    if (base > 0 && at - base > DEVICE_RETENTION_MS) {
      devices.delete(id);
      removedDeviceIds.push(id);
    }
  }

  // 旁挂内存 Map 的同步清理（放在 set 迭代之外，避免回调修改 Map 引发迭代异常）
  for (const id of removedTaskIds) {
    if (onTaskPurged) {
      try {
        onTaskPurged(id);
      } catch (e) {
        console.error('[tasks] 清理钩子异常 id=' + id + ' err=' + (e && e.message ? e.message : String(e)));
      }
    }
  }

  if (removedTaskIds.length > 0 || removedDeviceIds.length > 0) {
    // 同步落盘：删除不可逆，必须立刻生效且不被 400ms 防抖队列里的旧快照覆盖
    flushPersist();
    console.log('[tasks] 过期清理：删除任务 ' + removedTaskIds.length + ' 条（留存 '
      + TASK_RETENTION_HOURS + 'h）、删除设备 ' + removedDeviceIds.length + ' 条（留存 '
      + DEVICE_RETENTION_DAYS + 'd）');
  }
  return { tasks: removedTaskIds.length, devices: removedDeviceIds.length, taskIds: removedTaskIds };
}

/**
 * 按 deviceId 删除该设备的**全部**服务端数据（主动删除接口的底层实现）。
 *
 * 为什么需要：
 *   仅有过期清理时，用户无法主动要求删除自己的服务器数据 —— 隐私协议
 *   也就无法承诺"可随时删除服务器数据"。这里提供用户主动触发的删除能力。
 *
 * 删除范围（该 deviceId 名下）：
 *   - 全部任务记录：**不论状态**（pending/running/done/failed 一律删），
 *     因为这是用户明确要求的删除，不能因为"任务还在跑"就拒绝；
 *     调用方（server.js 路由）会先把正在跑的任务中断掉再删。
 *   - devices.json 中的设备注册记录（Push Token）。
 *
 * 安全约束（最重要）：
 *   只删 deviceId **完全相等**的记录。deviceId 为空串时直接返回全 0 且不做任何删除，
 *   否则空串可能匹配到历史脏数据（deviceId 缺失的任务）从而误删他人数据。
 *
 * @param {string} deviceId 设备标识
 * @returns {{tasks:number, devices:number, taskIds:string[]}}
 */
function deleteByDevice(deviceId) {
  const target = String(deviceId === undefined || deviceId === null ? '' : deviceId);
  if (target === '') {
    // 绝不因空 deviceId 而"删除所有 deviceId 为空的历史记录"——宁可什么都不删
    return { tasks: 0, devices: 0, taskIds: [] };
  }

  const removedTaskIds = [];
  for (const [id, t] of [...tasks]) {
    if (String((t && t.deviceId) || '') === target) {
      tasks.delete(id);
      removedTaskIds.push(id);
    }
  }

  let removedDevices = 0;
  if (devices.has(target)) {
    devices.delete(target);
    removedDevices = 1;
  }

  // 旁挂内存 Map 同步清理（与过期清理共用同一钩子）
  for (const id of removedTaskIds) {
    if (onTaskPurged) {
      try {
        onTaskPurged(id);
      } catch (e) {
        console.error('[tasks] 清理钩子异常 id=' + id + ' err=' + (e && e.message ? e.message : String(e)));
      }
    }
  }

  if (removedTaskIds.length > 0 || removedDevices > 0) {
    flushPersist(); // 用户主动删除：同步落盘，不给"复活"留窗口
    console.log('[tasks] 按设备删除数据 deviceId=' + target + '：删除任务 '
      + removedTaskIds.length + ' 条、删除设备记录 ' + removedDevices + ' 条');
  }
  return { tasks: removedTaskIds.length, devices: removedDevices, taskIds: removedTaskIds };
}

// 周期清理：unref() 保证不阻止进程退出
const purgeTimer = setInterval(() => {
  try {
    purgeExpired();
  } catch (e) {
    console.error('[tasks] 周期清理异常: ' + (e && e.message ? e.message : String(e)));
  }
}, PURGE_INTERVAL_MS);
if (purgeTimer && typeof purgeTimer.unref === 'function') {
  purgeTimer.unref();
}

// 启动即清理一次：把上次运行遗留的过期数据尽快落掉（延迟执行，不阻塞启动路径）
const bootPurgeTimer = setTimeout(() => {
  try {
    purgeExpired();
  } catch (e) {
    console.error('[tasks] 启动清理异常: ' + (e && e.message ? e.message : String(e)));
  }
}, 0);
if (bootPurgeTimer && typeof bootPurgeTimer.unref === 'function') {
  bootPurgeTimer.unref();
}

/** 按设备列出任务（含运行中与最近完成），按创建时间倒序 */
function listByDevice(deviceId, limit) {
  const max = Number(limit || 20);
  const now = Date.now();
  const out = [];
  for (const t of tasks.values()) {
    if (t.deviceId !== String(deviceId)) {
      continue;
    }
    // 已结束的任务超过留存期不再提供（结果已由客户端入库）；期限与磁盘清理共用同一配置。
    // 注意：这里与 listByDevice 的历史行为一致，只过滤 done；failed 任务仍按原样返回。
    if (t.status === STATUS.DONE && now - t.finishedAt > TASK_RETENTION_MS) {
      continue;
    }
    out.push(t);
  }
  out.sort((a, b) => b.createdAt - a.createdAt);
  return out.slice(0, max);
}

function patch(id, fields) {
  const t = tasks.get(String(id));
  if (!t) {
    return null;
  }
  Object.assign(t, fields);
  persist();
  return t;
}

/* ---------------- 设备 Push Token 注册 ---------------- */

/**
 * Push Token 的基本格式校验。
 *
 * 为什么需要：
 *   客户端上报接口是公开的，若不加校验，任何探测请求（例如健康检查里随手发的
 *   {deviceId:'healthcheck', token:'x'}）都会被当成真实设备存下来。
 *   更糟的是"取最新一条"的推送逻辑会把这个野数据当成推送目标，
 *   导致**真实设备的推送被顶掉**——实测中确实发生过。
 *
 * 华为 Push Token 形态：以 MA 开头、长度通常 100+ 的 Base64Url 串。
 * 这里做保守校验：过短或含非法字符一律拒绝。
 */
const TOKEN_MIN_LEN = 40;
const TOKEN_RE = /^[A-Za-z0-9_\-]+$/;

function isValidToken(token) {
  const t = String(token || '');
  return t.length >= TOKEN_MIN_LEN && TOKEN_RE.test(t);
}

/**
 * 注册/更新设备 token。
 * @returns {boolean} 是否被接受（false = 格式非法，已忽略）
 */
function registerDevice(deviceId, token) {
  const id = String(deviceId || '');
  if (id === '' || id.length > 200) {
    return false;
  }
  if (!isValidToken(token)) {
    console.warn('[tasks] 忽略非法 token 上报 deviceId=' + id
      + ' tokenLen=' + String(token || '').length);
    return false;
  }
  const old = devices.get(id);
  devices.set(id, { id, token: String(token), updatedAt: Date.now() });
  persist();
  if (!old || old.token !== String(token)) {
    console.log('[tasks] 设备已注册 deviceId=' + id);
  }
  return true;
}

/** 取某设备的 token */
function tokenOf(deviceId) {
  const d = devices.get(String(deviceId));
  return d ? d.token : '';
}

/**
 * 列出全部有效设备（按最近上报排序）。
 *
 * 用于"广播式推送"：同一个用户可能因重装/换机存在多条记录，
 * 只推最新一条时，若那条恰好失效就整条消息丢失。
 * 全部推送可显著提升送达率（无效的那些会被华为判为 tokenFormatError，
 * 由 forgetInvalidTokens 清理）。
 */
function listDevices() {
  const out = [];
  devices.forEach((v) => {
    if (isValidToken(v.token)) {
      out.push({ id: v.id, token: v.token, updatedAt: v.updatedAt });
    }
  });
  out.sort((a, b) => b.updatedAt - a.updatedAt);
  return out;
}

/**
 * 移除指定的失效 token。
 *
 * 华为在 token 失效时返回 code=80300007 且 msg 里带 illegalTokens.tokenFormatError，
 * 据此可精确定位哪条 token 需要清理，避免每次任务完成都重复推送失败。
 * @param {string[]} tokens 失效的 token 列表
 * @returns {number} 实际移除的记录数
 */
function forgetInvalidTokens(tokens) {
  if (!tokens || tokens.length === 0) {
    return 0;
  }
  const dead = new Set(tokens.map((t) => String(t)));
  let removed = 0;
  const ids = [];
  devices.forEach((v, k) => { ids.push(k); });
  for (const k of ids) {
    const v = devices.get(k);
    if (v && dead.has(v.token)) {
      devices.delete(k);
      removed++;
      console.log('[tasks] 清理失效 token deviceId=' + k);
    }
  }
  if (removed > 0) {
    persist();
  }
  return removed;
}

/* ---------------- 并发执行队列（默认同时最多 2 个任务，可配置） ---------------- */

const CONCURRENCY = Math.max(1, Number(process.env.TASK_CONCURRENCY || 2));
let active = 0;
const queue = [];

function pump() {
  while (active < CONCURRENCY && queue.length > 0) {
    const task = queue.shift();
    active++;
    task().then(() => {
      active--;
      pump();
    }).catch((e) => {
      active--;
      console.error('[tasks] worker error: ' + (e && e.message ? e.message : String(e)));
      pump();
    });
  }
}

function enqueue(worker) {
  return new Promise((resolve, reject) => {
    const task = async () => {
      try {
        resolve(await worker());
      } catch (e) {
        reject(e);
      }
    };
    queue.push(task);
    pump();
  });
}

module.exports = {
  STATUS, create, get, listByDevice, patch, enqueue,
  registerDevice, tokenOf, listDevices, forgetInvalidTokens,
  isValidToken,
  // 数据留存与清理
  purgeExpired, deleteByDevice, setTaskPurgeHook, isFinishedStatus, flushPersist,
  TASK_RETENTION_HOURS, DEVICE_RETENTION_DAYS,
  TASK_RETENTION_MS, DEVICE_RETENTION_MS, PURGE_INTERVAL_MS
};
