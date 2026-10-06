/**
 * 端到端联调自检（离线、不联网、不需要 AGC 凭据、不需要真机）。
 *
 * 目标：验证"提交生成任务时，客户端上报的通知字段确实被服务端接收并存入任务"。
 * 这是整条推送链路里**本地唯一能验证的一段**——服务端存对了，
 * 剩下的（华为凭据、设备 token、系统权限）才轮到真机。
 *
 * 用法（**两段式**，见下方"为什么不是单脚本"）：
 *   终端 A：  cd server
 *             $env:PORT="34519"; $env:HOST="127.0.0.1"
 *             $env:DATA_DIR="$env:TEMP\notify-e2e"
 *             $env:DEEPSEEK_API_KEY="sk-fake-offline"
 *             $env:PROXY_TOKEN="e2e-proxy-token"
 *             node src/server.js
 *   终端 B：  node server/tools/test_notify_e2e.js
 *
 * 为什么不是单脚本自启服务：
 *   本脚本原本用 child_process.spawn 起服务端子进程，但在受限沙箱下
 *   spawn 会以 EPERM 失败（无法创建带管道的子进程）。改为**只做 HTTP 断言、
 *   由调用方先启动服务端**，既绕开该限制，也让脚本在普通环境下同样可用。
 *
 * 注意：server.js 在 DEEPSEEK_API_KEY 缺失时会拒绝创建任务（500），
 *       因此需注入一个假 key —— 任务会因上游不可达而失败，
 *       但**任务记录与通知字段在提交那一刻就已写入**，不影响本脚本的断言。
 *       另外刻意不配置任何 AGC 凭据、不设 PUSH_ENABLED，用来同时证明
 *       "未配置凭据时推送被安全跳过，且不影响任务创建"。
 */
const PORT = Number(process.env.E2E_PORT || 34519);
const BASE = 'http://127.0.0.1:' + PORT;

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

const headers = { 'Content-Type': 'application/json', 'x-proxy-token': 'e2e-proxy-token' };

/** 仿照客户端 GenTask.submit 组装并提交任务 */
async function submitTask(feature, label, notifySeed, texts) {
  const body = {
    type: feature,
    label: label,
    system: 'sys',
    user: '学科：物理\n年级：八年级\n请生成内容',
    deviceId: 'e2e-device-001',
    notifySeed: notifySeed,
    notifyTitle: texts.title,
    notifyBody: texts.body,
    notifyFailTitle: texts.failTitle,
    notifyFailBody: texts.failBody
  };
  const r = await fetch(BASE + '/api/task', { method: 'POST', headers: headers, body: JSON.stringify(body) });
  const text = await r.text();
  let j = null;
  try { j = JSON.parse(text); } catch (e) { /* ignore */ }
  return { status: r.status, json: j, raw: text };
}

async function fetchTask(id) {
  const r = await fetch(BASE + '/api/task/' + id, { headers: headers });
  const j = JSON.parse(await r.text());
  return { status: r.status, task: j && j.task ? j.task : {} };
}

(async () => {
  console.log('='.repeat(70));
  console.log('端到端联调：任务提交 -> 通知字段入库');
  console.log('='.repeat(70));
  console.log('目标服务: ' + BASE);
  console.log('（需先在另一个终端以 DATA_DIR/PORT/DEEPSEEK_API_KEY 启动 src/server.js）');
  console.log('');

  // ---------- 0. 就绪检查 ----------
  let ready = false;
  try {
    const r = await fetch(BASE + '/health');
    ready = r.ok;
  } catch (e) {
    ready = false;
  }
  if (!ready) {
    console.log('  FAIL  服务端不可达：' + BASE + '/health');
    console.log('');
    console.log('  请先启动服务端，例如：');
    console.log('    cd server');
    console.log('    $env:PORT="' + PORT + '"; $env:DATA_DIR="$env:TEMP\\notify-e2e"');
    console.log('    $env:DEEPSEEK_API_KEY="sk-fake-offline"; $env:PROXY_TOKEN="e2e-proxy-token"');
    console.log('    node src/server.js');
    process.exit(1);
  }
  console.log('  服务端已就绪');
  console.log('');

  // ---------- 1. 提交任务 ----------
  console.log('一、提交任务（含 5 个通知字段）');
  const zhTexts = {
    title: '生成完成',
    body: '「教案生成」已生成完成，点击查看',
    failTitle: '生成失败',
    failBody: '「教案生成」生成失败，点击重试'
  };
  const sub = await submitTask('plan', '教案生成', 7101, zhTexts);
  check('POST /api/task 返回 202', sub.status === 202, 'status=' + sub.status + ' body=' + sub.raw.slice(0, 200));
  check('响应含 taskId', !!(sub.json && typeof sub.json.taskId === 'string' && sub.json.taskId !== ''));

  if (!sub.json || !sub.json.taskId) {
    console.log('');
    console.log('  （无法继续：未拿到 taskId）');
    process.exit(1);
  }
  const taskId = sub.json.taskId;

  // ---------- 2. 回查通知字段 ----------
  console.log('');
  console.log('二、回查任务，确认通知字段完整入库');
  const got = await fetchTask(taskId);
  check('GET /api/task/:id 返回 200', got.status === 200, 'status=' + got.status);
  const task = got.task;
  check('notifySeed 为数字 7101', task.notifySeed === 7101, 'got=' + JSON.stringify(task.notifySeed));
  check('notifyTitle 原样保存', task.notifyTitle === zhTexts.title, 'got=' + JSON.stringify(task.notifyTitle));
  check('notifyBody 原样保存', task.notifyBody === zhTexts.body, 'got=' + JSON.stringify(task.notifyBody));
  check('notifyFailTitle 原样保存', task.notifyFailTitle === zhTexts.failTitle, 'got=' + JSON.stringify(task.notifyFailTitle));
  check('notifyFailBody 原样保存', task.notifyFailBody === zhTexts.failBody, 'got=' + JSON.stringify(task.notifyFailBody));

  // ---------- 3. 凭据缺失时的安全性 ----------
  console.log('');
  console.log('三、未配置 AGC 凭据时的安全性（推送须被跳过且不影响任务）');
  check('无凭据时任务仍能创建（推送未阻塞主流程）', sub.status === 202);
  check('任务状态合法',
    ['pending', 'running', 'done', 'failed'].indexOf(String(task.status)) >= 0, 'status=' + task.status);
  const still = await fetch(BASE + '/health').then((r) => r.ok).catch(() => false);
  check('服务端进程存活（未因推送缺配置崩溃）', still === true);

  // ---------- 4. 幂等性 ----------
  console.log('');
  console.log('四、幂等性：同一功能重复提交，notifySeed 必须一致（通知覆盖而非堆积）');
  const sub2 = await submitTask('plan', '教案生成', 7101, zhTexts);
  check('第二次提交同样成功', sub2.status === 202, 'status=' + sub2.status);
  if (sub2.json && sub2.json.taskId) {
    const got2 = await fetchTask(sub2.json.taskId);
    check('第二次的 notifySeed 与第一次相同（新通知覆盖旧通知）',
      got2.task.notifySeed === 7101, 'got=' + got2.task.notifySeed);
    check('两次任务 id 不同（内容各自独立）', sub2.json.taskId !== taskId);
  }

  // ---------- 展示 ----------
  console.log('');
  console.log('  入库的通知内容（将由华为推送给用户）:');
  console.log('    标题: ' + task.notifyTitle);
  console.log('    正文: ' + task.notifyBody);
  console.log('    notifyId: ' + task.notifySeed);

  console.log('');
  console.log('='.repeat(70));
  console.log('结果: 通过 ' + passed + ' / 共 ' + (passed + failed) + ' 项' + (failed > 0 ? '，失败 ' + failed : ''));
  console.log('='.repeat(70));
  process.exit(failed > 0 ? 1 : 0);
})().catch((e) => {
  console.log('  FAIL  脚本异常: ' + (e && e.message ? e.message : String(e)));
  process.exit(1);
});

