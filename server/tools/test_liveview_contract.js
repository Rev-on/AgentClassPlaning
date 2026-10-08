/**
 * 实况窗（LiveView）端到端契约测试。
 *
 * 覆盖三条"曾经踩过 / 极易踩"的坑：
 *
 *  1) **activityId 必须由客户端自己生成**
 *     SDK 的 `LiveViewResult` 只回 resultCode/message，**不含 id**
 *     （@hms.core.liveview.liveViewManager.d.ts:1416，已核对本地 SDK）。
 *     故客户端必须自己给 `LiveView.id` 赋一个正整数；若沿用 `id: 0`，
 *     服务端拿到的 activityId 恒为 0，push-type 7 永远无法定位实况窗。
 *     本测试断言客户端不再出现 `id: 0`，且存在 nextActivityId() 生成器。
 *
 *  2) **服务端结束报文必须解析 body.code，而不是只看 HTTP 状态**
 *     华为**业务失败也返回 HTTP 200**，真正结果在 body.code。
 *     早期 `sendLiveViewEnd` 只判断 `resp.ok`，把失败记成"已发送"，
 *     导致实况窗残留却查不到原因（与 sendAlert 曾经同款 bug）。
 *
 *  3) **event 不能是 'PROGRESS'**
 *     PROGRESS 是**布局类型**（LAYOUT_TYPE_PROGRESS），不是合法**场景名**。
 *     服务端默认值传 'PROGRESS' 会被华为拒收。
 *     合法场景为 TIMER/RENT/WORKOUT/... （见客户端 EVENTS）。
 *
 * 运行：node tools/test_liveview_contract.js
 */
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const CLIENT_LV = path.join(ROOT, 'entry/src/main/ets/common/LiveView.ets');
const CLIENT_REPORT = path.join(ROOT, 'entry/src/main/ets/common/LiveViewReport.ets');
const CLIENT_AI = path.join(ROOT, 'entry/src/main/ets/common/AiService.ets');
const SERVER_PUSH = path.join(ROOT, 'server/src/push.js');
const SERVER_JS = path.join(ROOT, 'server/src/server.js');

let pass = 0;
let fail = 0;
const failures = [];

function check(name, cond, detail) {
  if (cond) {
    pass++;
  } else {
    fail++;
    failures.push(name + (detail ? ' :: ' + detail : ''));
  }
}

/** 去掉注释，避免注释里的反例文字造成假通过/假失败 */
function stripComments(src) {
  return src
    .replace(/\/\*[\s\S]*?\*\//g, '')
    .replace(/(^|[^:])\/\/.*$/gm, '$1');
}

function read(p) {
  return fs.readFileSync(p, 'utf8');
}

/* ---------------- 1. 客户端：activityId 自生成 ---------------- */
const lvRaw = read(CLIENT_LV);
const lv = stripComments(lvRaw);

check('LiveView.ets 定义 nextActivityId()',
  /function\s+nextActivityId\s*\(\s*\)\s*:\s*number/.test(lv));

check('nextActivityId 返回正整数（Date.now 取模 int32）',
  /Date\.now\(\)\s*%\s*2147483647/.test(lv),
  '需保证落在 32 位正整数范围');

check('start() 用 nextActivityId() 赋值 LiveView.id（不再固定 0）',
  /LiveView\.id\s*=\s*nextActivityId\(\)/.test(lv));

// 关键回归：不再向 startLiveView/updateLiveView/stopLiveView 传 id: 0
check('不再向 SDK 传 `id: 0`（否则服务端 activityId 恒为 0）',
  !/id\s*:\s*0\s*,/.test(lv),
  '发现 id: 0 字面量');

check('三处 SDK 调用均使用 LiveView.id',
  (lv.match(/id\s*:\s*LiveView\.id/g) || []).length >= 3,
  '需在 start/update/stop 都带上真实 id');

check('存在 bindTask(taskId) 供拿到 taskId 后补绑',
  /static\s+bindTask\s*\(\s*taskId\s*:\s*string\s*\)/.test(lv));

check('bindTask 在非活动/无效 id 时提前返回（不发无效请求）',
  /if\s*\(!LiveView\.active\s*\|\|\s*LiveView\.id\s*<=\s*0\s*\|\|\s*taskId\s*===\s*''\)/.test(lv));

/* ---------------- 2. 客户端：上报模块 ---------------- */
check('LiveViewReport.ets 存在', fs.existsSync(CLIENT_REPORT));
const rep = stripComments(read(CLIENT_REPORT));

check('上报路径为 /task/<id>/liveview',
  /'\/task\/'\s*\+\s*taskId\s*\+\s*'\/liveview'/.test(rep));

check('上报体同时携带 activityId 与 event',
  /activityId\s*:\s*activityId/.test(rep) && /event\s*:\s*event/.test(rep));

check('上报失败只写日志、不抛出（不阻断生成）',
  /hilog\.warn/.test(rep) && /catch\s*\(e\)/.test(rep));

check('上报走 SERVER_BASE_URL（与其它接口一致）',
  /ApiConfig\.SERVER_BASE_URL/.test(rep));

/* ---------------- 3. 客户端：绑定时机 ---------------- */
const ai = stripComments(read(CLIENT_AI));
check('AiService 在拿到 taskId 后调用 LiveView.bindTask(taskId)',
  /LiveView\.bindTask\(\s*taskId\s*\)/.test(ai),
  '必须在 GenTask.submit 成功之后');
check('AiService 导入了 LiveView',
  /import\s*\{\s*LiveView\s*\}\s*from\s*'\.\/LiveView'/.test(ai));

/* ---------------- 4. 服务端：结束报文正确性 ---------------- */
const push = stripComments(read(SERVER_PUSH));

check('sendLiveViewEnd 校验 activityId 有效性',
  /if\s*\(id\s*<=\s*0\)/.test(push),
  'activityId<=0 时应跳过而非发无效请求');

check('sendLiveViewEnd 解析 body.code（不能只看 resp.ok）',
  /code\s*===\s*'80000000'/.test(push),
  '华为业务失败也返回 HTTP 200');

check('sendLiveViewEnd 成功分支由 code 判定，而非 resp.ok',
  /if\s*\(\s*code\s*===\s*'80000000'\s*\)\s*\{[\s\S]{0,200}已发送/.test(push),
  '成功日志必须在 code 判定分支内');

// 反向断言：函数体内不得再用 resp.ok 判定成功
check('sendLiveViewEnd 内不出现 `if (resp.ok)` 成功判定',
  !/if\s*\(\s*resp\.ok\s*\)\s*\{[\s\S]{0,300}已发送/.test(push),
  'resp.ok 只代表 HTTP 200，不代表业务成功');

// event 默认值不能是 PROGRESS（布局类型，非场景名）
check("sendLiveViewEnd 的 event 兜底不是 'PROGRESS'",
  !/event\s*:\s*String\(event\s*\|\|\s*'PROGRESS'\)/.test(push));

/* ---------------- 5. 服务端：路由与调用点 ---------------- */
const srv = stripComments(read(SERVER_JS));

check('存在 /api/task/:id/liveview 路由',
  /app\.post\('\/api\/task\/:id\/liveview'/.test(srv));

check('路由拒绝无效 activityId（400）',
  /activityId\s*<=\s*0[\s\S]{0,200}status\(400\)/.test(srv));

/**
 * 路由默认 event 为 TIMER（合法场景名）。
 *
 * 【为什么写成"两种形态都接受"】
 *   这条断言最初匹配的是内联三元表达式：
 *       event: typeof body.event === 'string' ? body.event : 'TIMER'
 *   后来路由为了区分"没传 totalChars"与"传了无效值"，把 event 提成了一个
 *   局部常量再复用：
 *       const event = typeof body.event === 'string' && body.event !== '' ? body.event : 'TIMER';
 *       ...
 *       tasks.patch(task.id, { liveView: { event: event, ... } })
 *   **行为完全没变**（默认值仍是 TIMER），但内联形态的断言就此失败 ——
 *   这是"测试耦合了实现写法"的典型翻车：重构被测试拦下，而测试想守的
 *   语义（默认值是合法场景名 TIMER）其实一直成立。
 *
 *   因此这里改为守住**语义**：
 *     ① 无论内联还是局部常量，只要存在"body.event 无效 → 'TIMER'"的兜底；
 *     ② 且该默认值最终被写进 liveView（内联形态或 `event: event` 形态）。
 */
const eventDefaultInline =
  /event\s*:\s*typeof body\.event\s*===\s*'string'[\s\S]{0,80}\?\s*body\.event\s*:\s*'TIMER'/.test(srv);
const eventDefaultLocal =
  /const\s+event\s*=\s*typeof body\.event\s*===\s*'string'[\s\S]{0,80}\?\s*body\.event\s*:\s*'TIMER'/.test(srv)
  && /event:\s*event\s*,/.test(srv);
check('路由默认 event 为 TIMER（合法场景名）', eventDefaultInline || eventDefaultLocal,
  'inline=' + eventDefaultInline + ' local=' + eventDefaultLocal);

check('任务完成时 event 兜底为 TIMER 而非 PROGRESS',
  /event:\s*task\.liveView\.event\s*\|\|\s*'TIMER'/.test(srv));

check('任务完成时按 task.liveView 触发结束',
  /if\s*\(task\.liveView\)[\s\S]{0,200}sendLiveViewEnd/.test(srv));

/* ---------------- 6. 场景名合法性（与客户端 EVENTS 对齐） ---------------- */
const evMatch = lvRaw.match(/const EVENTS:\s*string\[\]\s*=\s*\[([\s\S]*?)\];/);
const events = evMatch
  ? (evMatch[1].match(/'([A-Z_]+)'/g) || []).map((s) => s.replace(/'/g, ''))
  : [];
check('能解出客户端 EVENTS 场景列表', events.length >= 10, 'actual=' + events.length);
check("EVENTS 不含 'PROGRESS'（它是布局类型）", !events.includes('PROGRESS'));
check("EVENTS 首个为 'TIMER'，与服务端默认值一致",
  events.length > 0 && events[0] === 'TIMER', 'first=' + events[0]);

/* ---------------- 汇总 ---------------- */
console.log('='.repeat(72));
console.log('实况窗契约测试（LiveView contract）');
console.log('='.repeat(72));
console.log('客户端 EVENTS: ' + events.join(', '));
console.log('-'.repeat(72));
if (failures.length > 0) {
  console.log('失败项：');
  failures.forEach((f, i) => console.log('  ' + (i + 1) + '. ' + f));
  console.log('-'.repeat(72));
}
console.log('结果: 通过 ' + pass + ' / 共 ' + (pass + fail) + ' 项');
console.log('='.repeat(72));
process.exit(fail === 0 ? 0 : 1);
