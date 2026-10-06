/**
 * deviceId 一致性校验（服务端侧）。
 *
 * 【为什么需要】
 *   这是"服务端日志显示已发送、手机却收不到通知"的**真正根因**，且极易复发：
 *   服务端推送时用 `tokenOf(task.deviceId)` 去设备表里查推送 token。
 *   若"提交生成任务用的 deviceId" 与 "上报推送 token 用的 deviceId" 不是同一个值，
 *   就永远查不到 → 推送走广播或推给失效 token → 通知收不到。
 *
 *   实测数据（2026-10-06）：任务 deviceId 36 个、设备表 id 15 个，**交集仅 4 个**。
 *   原因：GenTask.deviceId() 生成 12 位短 ID，PushToken.deviceId() 用 deviceInfo.ODID
 *        （36 位 UUID），两者**从不相等**。
 *
 * 本脚本做两件事：
 *   一、源码静态断言：GenTask.deviceId 必须复用 PushToken.deviceId（同源）
 *   二、线上数据断言（可选，需连服务器）：任务与设备的 deviceId 交集不应为空
 *
 * 用法：node server/tools/test_deviceid_consistency.js
 */
const fs = require('fs');
const path = require('path');

let passed = 0;
let failed = 0;
function check(name, cond, detail) {
  if (cond) {
    passed++;
    console.log('  PASS  ' + name);
  } else {
    failed++;
    console.log('  FAIL  ' + name + (detail === undefined ? '' : '  -> ' + detail));
  }
}

/**
 * 去掉注释后再做源码断言。
 *
 * 为什么必须：本文件与源码的注释里都会**引用旧的错误写法**
 * （例如 "历史 bug：原先生成 'd'+Date.now().toString(36)"），
 * 若直接在整个文件上跑正则，会把注释里的反例误判成真实代码，产生假失败。
 *
 * 注意：必须**先**去块注释再逐行去行注释。若先按行处理，
 * 块注释中以 `*` 开头的行不会被 `//` 规则去掉，仍会残留。
 */
function stripComments(text) {
  // 先去掉块注释（非贪婪，跨行）
  let out = text.replace(/\/\*[\s\S]*?\*\//g, '');
  // 再去掉行注释
  out = out.replace(/\/\/[^\n]*/g, '');
  return out;
}

const ROOT = path.join(__dirname, '..', '..');
const genTaskPath = path.join(ROOT, 'entry', 'src', 'main', 'ets', 'common', 'GenTask.ets');
const pushTokenPath = path.join(ROOT, 'entry', 'src', 'main', 'ets', 'common', 'PushToken.ets');

console.log('='.repeat(72));
console.log('deviceId 一致性校验（"推送已发送但收不到"的根因防护）');
console.log('='.repeat(72));
console.log('');

/* ------------------------------------------------------------------ *
 * 一、源码静态断言
 * ------------------------------------------------------------------ */
console.log('一、客户端：任务 deviceId 必须与推送 deviceId 同源');

const genTaskSrc = fs.readFileSync(genTaskPath, 'utf8');
const genTaskCode = stripComments(genTaskSrc);
const pushTokenSrc = fs.readFileSync(pushTokenPath, 'utf8');

check('GenTask.ets 存在', genTaskSrc !== '');
check('PushToken.ets 存在', pushTokenSrc !== '');

// 1.1 GenTask 必须 import PushToken
check('GenTask 引入了 PushToken',
  /import\s*\{[^}]*PushToken[^}]*\}\s*from\s*'\.\/PushToken'/.test(genTaskCode),
  '必须复用 PushToken.deviceId()，否则两端 ID 不同源');

// 1.2 GenTask.deviceId() 的实现体内必须调用 PushToken.deviceId()
//
// 注意：不能用 "GenTask.deviceId 后面 N 字符内出现 PushToken.deviceId" 这种写法 ——
// `GenTask.deviceId` 也会在 submit() 里以**调用形式**出现（GenTask.deviceId(ctx)），
// 而方法**声明**在它之前，方向是反的，会导致假失败（已实际踩到）。
// 正确做法：定位方法声明本身，取其后一段实现体来断言。
const declIdx = genTaskCode.search(/static\s+async\s+deviceId\s*\(/);
check('找到 GenTask.deviceId() 方法声明', declIdx >= 0);
if (declIdx >= 0) {
  // 取方法体：从声明起 2000 字符（足够覆盖整个方法实现）
  const body = genTaskCode.slice(declIdx, declIdx + 2000);
  check('GenTask.deviceId() 实现体内调用 PushToken.deviceId()',
    /PushToken\.deviceId\(\)/.test(body),
    'deviceId 必须取自 PushToken，保证与推送 token 上报用同一个值');
}

// 1.3 【回归防护】不得再出现"自己造 ID"的老写法
//     老写法特征：'d' + Date.now().toString(36) + 随机数
const oldPattern = /'d'\s*\+\s*Date\.now\(\)\.toString\(36\)/;
check('GenTask 未使用旧的"自造 ID"写法（已修复的 bug）',
  !oldPattern.test(genTaskCode),
  "仍存在 'd'+Date.now().toString(36) 写法 → 会与 PushToken 的 UUID 不一致，通知必然收不到");

// 1.4 PushToken.deviceId() 必须仍是"稳定标识"来源
check('PushToken.deviceId() 使用 deviceInfo 稳定标识',
  /deviceInfo\.ODID/.test(pushTokenSrc),
  'PushToken 应以 ODID 为主，保证同一设备稳定');

// 1.5 PushToken.deviceId() 不得返回空串（否则 GenTask 兜底逻辑被触发，双方又不同源）
check('PushToken.deviceId() 有非空兜底',
  /return\s*\(deviceInfo\.brand[\s\S]{0,80}deviceInfo\.productModel/.test(pushTokenSrc),
  'ODID 缺失时需回退到 brand+model，不能返回空串');

/* ------------------------------------------------------------------ *
 * 二、线上数据断言（若本地有 data/ 目录则顺带检查）
 * ------------------------------------------------------------------ */
console.log('');
console.log('二、线上数据：任务与设备的 deviceId 交集（需本地 data/ 副本）');

const dataDir = process.env.DATA_DIR || path.join(__dirname, '..', 'data');
const tasksFile = path.join(dataDir, 'tasks.json');
const devicesFile = path.join(dataDir, 'devices.json');

if (fs.existsSync(tasksFile) && fs.existsSync(devicesFile)) {
  try {
    const tasks = JSON.parse(fs.readFileSync(tasksFile, 'utf8'));
    const devices = JSON.parse(fs.readFileSync(devicesFile, 'utf8'));
    const tids = new Set(tasks.map((x) => String(x.deviceId || '')));
    const dids = new Set(devices.map((x) => String(x.id || '')));
    let inter = 0;
    tids.forEach((x) => { if (dids.has(x)) { inter++; } });

    console.log('    任务 deviceId 去重: ' + tids.size + '，设备 id 去重: ' + dids.size
      + '，交集: ' + inter);
    // 只对"最近任务"做交集判断：历史脏数据不应让测试常红
    const recent = tasks.slice().sort((a, b) => (b.createdAt || 0) - (a.createdAt || 0)).slice(0, 3);
    const recentHit = recent.filter((k) => dids.has(String(k.deviceId || ''))).length;
    check('最近 3 个任务的 deviceId 能在设备表中找到（' + recentHit + '/'
      + recent.length + '）', recent.length === 0 || recentHit > 0,
      '若为 0：说明任务与设备 ID 不同源，推送会走广播/失败 → 通知收不到');
  } catch (e) {
    console.log('    （跳过：data 文件解析失败 ' + (e && e.message ? e.message : String(e)) + '）');
  }
} else {
  console.log('    （跳过：本地无 data/ 副本。线上核对请用 server/tools/diag_deviceid_mismatch.sh）');
}

console.log('');
console.log('='.repeat(72));
console.log('结果: 通过 ' + passed + ' / 共 ' + (passed + failed) + ' 项'
  + (failed > 0 ? '，失败 ' + failed : ''));
console.log('='.repeat(72));
process.exit(failed > 0 ? 1 : 0);
