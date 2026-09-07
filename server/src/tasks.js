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
    try {
      fs.writeFileSync(TASKS_FILE, JSON.stringify([...tasks.values()], null, 2));
      fs.writeFileSync(DEVICES_FILE, JSON.stringify([...devices.values()], null, 2));
    } catch (e) {
      console.error('[tasks] 持久化失败: ' + (e && e.message ? e.message : String(e)));
    }
  }, 400);
}

loadFromFile(TASKS_FILE, tasks);
loadFromFile(DEVICES_FILE, devices);

/** 任务状态枚举 */
const STATUS = { PENDING: 'pending', RUNNING: 'running', DONE: 'done', FAILED: 'failed' };

function newId() {
  return 'T' + Date.now().toString(36) + Math.random().toString(36).slice(2, 8);
}

/** 创建任务记录并返回 */
function create({ deviceId, type, label, system, user, notifySeed, notifyTitle, notifyBody, notifyFailTitle, notifyFailBody }) {
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
    status: STATUS.PENDING,
    createdAt: Date.now(),
    finishedAt: 0,
    content: '',
    error: ''
  };
  tasks.set(task.id, task);
  persist();
  return task;
}

function get(id) {
  return tasks.get(String(id)) || null;
}

/** 按设备列出任务（含运行中与最近完成），按创建时间倒序 */
function listByDevice(deviceId, limit) {
  const max = Number(limit || 20);
  const out = [];
  for (const t of tasks.values()) {
    if (t.deviceId !== String(deviceId)) {
      continue;
    }
    if (t.status === STATUS.DONE && Date.now() - t.finishedAt > 24 * 3600 * 1000) {
      continue; // 已完成超过 24 小时的不再提供（结果已由客户端入库）
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

function registerDevice(deviceId, token) {
  devices.set(String(deviceId), { id: String(deviceId), token: String(token || ''), updatedAt: Date.now() });
  persist();
}

function tokenOf(deviceId) {
  const d = devices.get(String(deviceId));
  return d ? d.token : '';
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

module.exports = { STATUS, create, get, listByDevice, patch, registerDevice, tokenOf, enqueue };
