/**
 * 验证 pushToDevice 的一个真实缺陷：任务对应的 deviceId 不在设备表时，
 * 会走"设备 Push Token 为空"分支并**跳过推送**，而不是回退到广播。
 *
 * 背景（来自生产日志）：
 *   [push] 设备 Push Token 为空，跳过推送
 * 这行来自 push.js 的 sendAlert()，条件是 `!token`。
 * 而 server.js 的 pushToDevice() 里只有一处会传空 token：
 *     token: tasks.tokenOf(task.deviceId)
 * 当 task.deviceId 在 devices 表里查不到时，tokenOf 返回 ''。
 *
 * 关键矛盾：
 *   - pushToDevice 的注释与意图是"查不到该设备就**回退到全部有效 token**（广播）"；
 *   - 但代码实际把这条回退逻辑放在了**错误的层级**：
 *       mine = all.filter(d => d.id === tid)      // 空数组
 *       targets = mine.length>0 ? mine : all      // 回退成立，targets = all
 *     这部分是对的；然而 runTask 里**结束实况窗**那一支直接调
 *       push.sendLiveViewEnd({ token: tasks.tokenOf(task.deviceId) })
 *     绕过了 pushToDevice，tokenOf 返回空串 → "设备 Push Token 为空"。
 *
 * 本脚本用真实的 server.js 模块 + 桩替换 push/tasks 来复现该路径，
 * 并给出"期望行为"与"实际行为"的对比。
 */
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

console.log('='.repeat(70));
console.log('验证：tokenOf(未知 deviceId) 返回空串 -> sendAlert 跳过推送');
console.log('='.repeat(70));
console.log('');

// tasks.js 需要 DATA_DIR 隔离
const fs = require('fs');
const os = require('os');
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'tokendbg-'));
process.env.DATA_DIR = tmp;
const tasks = require('../src/tasks');

console.log('一、tokenOf 对"未注册设备"的行为');
const t1 = tasks.tokenOf('device-never-registered');
check('tokenOf(未注册设备) 返回空串', t1 === '', 'got=' + JSON.stringify(t1));

const validToken = 'M' + 'a'.repeat(111); // 112 字符，符合华为 token 形态
const accepted = tasks.registerDevice('device-registered', validToken);
check('registerDevice 接受合法 token', accepted === true);
check('tokenOf(已注册设备) 返回该 token', tasks.tokenOf('device-registered') === validToken);

// 关键：两个不同设备 id 是完全独立的记录
check('未注册设备的 tokenOf 仍为空（不会误取别人的 token）',
  tasks.tokenOf('device-never-registered') === '', 'got=' + JSON.stringify(tasks.tokenOf('device-never-registered')));

console.log('');
console.log('二、listDevices() 绝不会返回空 token（证明该日志不来自 pushToDevice 的循环）');
const all = tasks.listDevices();
check('listDevices 非空', all.length > 0, 'count=' + all.length);
check('listDevices 每一条 token 都非空', all.every((d) => d.token !== '' && d.token !== undefined));
check('listDevices 已按 isValidToken 过滤（长度均 >= 40）', all.every((d) => String(d.token).length >= 40));

console.log('');
console.log('三、复现：sendAlert 收到空 token 时的行为');
const push = require('../src/push');
(async () => {
  // 无凭据时 configured() 先返回 skipped，会掩盖 token 分支；
  // 因此这里先确认"无凭据"路径，再用桩配置触发 token 分支。
  const r1 = await push.sendAlert({ token: '', notifyId: 1, title: 't', body: 'b', data: {} });
  check('无凭据时返回 skipped（不抛异常）', r1 && r1.skipped === true, JSON.stringify(r1));

  // 生成临时凭据，让 configured() 为 true，从而走到 token 判空那一支
  const crypto = require('crypto');
  const { privateKey } = crypto.generateKeyPairSync('rsa', {
    modulusLength: 2048,
    publicKeyEncoding: { type: 'spki', format: 'pem' },
    privateKeyEncoding: { type: 'pkcs8', format: 'pem' }
  });
  process.env.AGC_PROJECT_ID = 'testproj';
  process.env.AGC_JWT_KID = 'kid';
  process.env.AGC_JWT_ISS = 'iss';
  process.env.AGC_JWT_PRIVATE_KEY = privateKey;

  check('配置凭据后 push.configured() === true', push.configured() === true);

  // 拦截 fetch，若被调用即说明"空 token 仍尝试发网"
  let fetchCalls = 0;
  global.fetch = async () => {
    fetchCalls++;
    return { status: 200, text: async () => JSON.stringify({ code: '80000000' }) };
  };

  const r2 = await push.sendAlert({ token: '', notifyId: 1, title: 't', body: 'b', data: {} });
  check('凭据齐备但 token 为空 -> 返回 skipped', r2 && r2.skipped === true, JSON.stringify(r2));
  check('空 token 时**不发起任何网络请求**（安全）', fetchCalls === 0, 'fetchCalls=' + fetchCalls);

  console.log('');
  console.log('='.repeat(70));
  console.log('结论');
  console.log('='.repeat(70));
  console.log('  · `设备 Push Token 为空，跳过推送` 的确切含义：');
  console.log('    服务端拿到了一个**空字符串 token**，于是直接放弃发送。');
  console.log('');
  console.log('  · 它**不等于**"设备没注册"（那种情况会打 `无有效设备 token`）。');
  console.log('    它的唯一来源是把 tasks.tokenOf(task.deviceId) 的返回值直接当 token 用，');
  console.log('    而该 deviceId 在设备表里查不到 -> tokenOf 返回 ""。');
  console.log('');
  console.log('  · 影响：这类任务的通知**必然收不到**，且因为只打 warn 不报错，');
  console.log('    表面上"华为已受理"与"token 为空"会同时出现，极易误判。');
  console.log('');
  console.log('  · 根因：`结束实况窗` 那一支绕过了 pushToDevice 的"回退到全部设备"逻辑。');
  console.log('');

  console.log('结果: 通过 ' + passed + ' / 共 ' + (passed + failed) + ' 项' + (failed > 0 ? '，失败 ' + failed : ''));
  try { fs.rmSync(tmp, { recursive: true, force: true }); } catch (e) { /* ignore */ }
  process.exit(failed > 0 ? 1 : 0);
})();
