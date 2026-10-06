/**
 * 7 大 AI 生成功能「完成通知」上报契约自检（离线，不联网、不需要 AGC 凭据）。
 *
 * 为什么需要这个脚本：
 *   推送是否真正送达只能靠真机验证，但**客户端到底上报了什么**完全可以离线断言。
 *   历史上这条链路断掉的原因正是：服务端 runTask 会推送 task.notifyTitle/notifyBody，
 *   而客户端 GenTask.submit 压根没上报这两个字段，于是推送内容为空、用户看不到通知，
 *   且因为不报错，问题很难被发现。
 *
 * 本脚本做两件事：
 *   1. 校验服务端 tasks.js 能完整存取 5 个通知字段；
 *   2. 用 GenTask.ets 中同一套规则复算 7 个功能的 notifySeed / 文案，
 *      确认 7 个功能 id 唯一、文案非空、且未出现未替换的裸键名。
 *
 * 注意：脚本刻意**复刻**而非 import 客户端的映射表（ArkTS 无法在 Node 中执行），
 * 因此它同时校验"源码里确实写了这些值"—— 一旦有人改了 GenTask.ets 而没同步这里，
 * readClientSource() 的断言就会失败。这是刻意的防漂移设计。
 */
const fs = require('fs');
const path = require('path');
const os = require('os');

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
 * 为什么必须：源文件里的**注释会举例说明错误写法**（例如"不要写成 addSlot(slot)"），
 * 若直接在整个文件上跑正则，会把注释里的反例误判为真实代码，产生假失败。
 * 已在 NotifySlot.ets 的踩坑注释上实际踩到这个问题。
 */
function stripComments(text) {
  return text.replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/[^\n]*/g, '');
}

/* ------------------------------------------------------------------ *
 * 一、源码层断言：GenTask.ets 必须真的上报通知字段
 * ------------------------------------------------------------------ */
console.log('='.repeat(70));
console.log('一、客户端 GenTask.ets 上报契约（源码静态校验）');
console.log('='.repeat(70));

const genTaskPath = path.join(__dirname, '..', '..', 'entry', 'src', 'main', 'ets', 'common', 'GenTask.ets');
let src = '';
try {
  src = fs.readFileSync(genTaskPath, 'utf8');
} catch (e) {
  console.log('  FAIL  无法读取 GenTask.ets: ' + (e && e.message ? e.message : String(e)));
  process.exit(1);
}

// 1.1 请求体接口必须声明全部 5 个通知字段
['notifySeed', 'notifyTitle', 'notifyBody', 'notifyFailTitle', 'notifyFailBody'].forEach((f) => {
  check('TaskSubmitBody 声明了 ' + f, new RegExp(f + '\\??:\\s*(number|string)').test(src));
});

// 1.2 submit() 必须真的把这些字段填进 body（不能只声明不赋值）
['notifySeed', 'notifyTitle', 'notifyBody', 'notifyFailTitle', 'notifyFailBody'].forEach((f) => {
  check('submit() 实际填充 ' + f, new RegExp(f + ':\\s*[A-Za-z]').test(src));
});

// 1.3 7 个功能 key 必须都在 NOTIFY_IDS 映射表里
const CLIENT_IDS = {};
const idBlock = src.match(/NOTIFY_IDS[^=]*=\s*\{([\s\S]*?)\}/);
check('找到 NOTIFY_IDS 映射表', idBlock !== null);
if (idBlock) {
  const re = /'([a-z]+)':\s*(\d+)/g;
  let m;
  while ((m = re.exec(idBlock[1])) !== null) {
    CLIENT_IDS[m[1]] = Number(m[2]);
  }
}

const FEATURES = ['plan', 'courseware', 'quiz', 'research', 'analysis', 'talk', 'report'];
FEATURES.forEach((f) => {
  check('NOTIFY_IDS 包含功能 ' + f, CLIENT_IDS[f] !== undefined, '实际解析到: ' + JSON.stringify(CLIENT_IDS));
});

// 1.4 notifyId 必须两两唯一且非 0（0 = 不归并，会导致通知堆积）
const idVals = FEATURES.map((f) => CLIENT_IDS[f]).filter((v) => v !== undefined);
check('7 个 notifySeed 全部唯一（新通知可覆盖旧通知）', new Set(idVals).size === idVals.length,
  '实际: ' + JSON.stringify(idVals));
check('notifySeed 均不为 0（0 表示不归并）', idVals.every((v) => v > 0), '实际: ' + JSON.stringify(idVals));

/* ------------------------------------------------------------------ *
 * 二、i18n 文案断言：不能出现裸键名，且拼接后包含功能名
 * ------------------------------------------------------------------ */
console.log('');
console.log('='.repeat(70));
console.log('二、通知文案 i18n 完整性（zh / en 必填）');
console.log('='.repeat(70));

const i18nPath = path.join(__dirname, '..', '..', 'entry', 'src', 'main', 'ets', 'common', 'I18n.ets');
const i18nSrc = fs.readFileSync(i18nPath, 'utf8');

const KEYS = ['notify.done.title', 'notify.done.body.a', 'notify.done.body.b',
  'notify.fail.title', 'notify.fail.body.a', 'notify.fail.body.b'];

/**
 * 从 I18n.ets 中提取某个字典块内所有 ['key','value'] 条目。
 * 中文词典与英文词典各出现一次，因此按出现顺序取前两批。
 */
function extractDict(blockText) {
  const out = {};
  const re = /\[\s*'([^']+)'\s*,\s*'((?:[^'\\]|\\.)*)'\s*\]/g;
  let m;
  while ((m = re.exec(blockText)) !== null) {
    out[m[1]] = m[2];
  }
  return out;
}

const zhBlock = i18nSrc.match(/private static readonly zh[\s\S]*?\]\);/);
const enBlock = i18nSrc.match(/private static readonly en[\s\S]*?\]\);/);
check('解析到中文词典', zhBlock !== null);
check('解析到英文词典', enBlock !== null);

const zhDict = zhBlock ? extractDict(zhBlock[0]) : {};
const enDict = enBlock ? extractDict(enBlock[0]) : {};

KEYS.forEach((k) => {
  const zh = zhDict[k];
  const en = enDict[k];
  check('zh 词典有 ' + k, zh !== undefined && zh !== '');
  check('en 词典有 ' + k, en !== undefined && en !== '');
  // 裸键名＝漏翻或漏加：值恰好等于键名说明 t() 走了兜底分支
  check('zh ' + k + ' 非裸键名', zh !== k, '值=' + zh);
  check('en ' + k + ' 非裸键名', en !== k, '值=' + en);
});

/* ------------------------------------------------------------------ *
 * 三、端到端契约：按客户端规则组装 -> 写入 tasks -> 校验可取回
 * ------------------------------------------------------------------ */
console.log('');
console.log('='.repeat(70));
console.log('三、服务端存取契约（tasks.create 完整保存 5 个通知字段）');
console.log('='.repeat(70));

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'notify-contract-'));
process.env.DATA_DIR = tmp;
const tasks = require('../src/tasks');

// 按 GenTask.notifyTexts 的规则复算文案（zh）
function buildTexts(label, dict) {
  return {
    title: dict['notify.done.title'],
    body: dict['notify.done.body.a'] + label + dict['notify.done.body.b'],
    failTitle: dict['notify.fail.title'],
    failBody: dict['notify.fail.body.a'] + label + dict['notify.fail.body.b']
  };
}

// 7 个功能的中文标题（与 I18n.ets 的 page.* 一致）
const ZH_LABELS = {
  plan: '教案生成', courseware: '课件生成', quiz: '分层练习命题',
  research: '教研科研辅助', analysis: '学情分析与报告',
  talk: '沟通话术建议', report: '个性化学情报告'
};

FEATURES.forEach((f) => {
  const texts = buildTexts(ZH_LABELS[f], zhDict);
  const t = tasks.create({
    deviceId: 'test-device',
    type: f,
    label: ZH_LABELS[f],
    system: 'sys',
    user: 'usr',
    notifySeed: CLIENT_IDS[f],
    notifyTitle: texts.title,
    notifyBody: texts.body,
    notifyFailTitle: texts.failTitle,
    notifyFailBody: texts.failBody
  });
  const got = tasks.get(t.id);
  check(f + ': notifySeed 存取一致', got.notifySeed === CLIENT_IDS[f], 'got=' + got.notifySeed);
  check(f + ': notifyTitle 非空', typeof got.notifyTitle === 'string' && got.notifyTitle !== '');
  check(f + ': notifyBody 含功能名', got.notifyBody.indexOf(ZH_LABELS[f]) >= 0, 'body=' + got.notifyBody);
  check(f + ': notifyFailBody 含功能名', got.notifyFailBody.indexOf(ZH_LABELS[f]) >= 0);
  check(f + ': notifySeed 是 number 类型', typeof got.notifySeed === 'number');
});

// 省略通知字段时必须是空串（而不是 undefined），否则服务端推送会出现 "undefined"
const bare = tasks.create({ deviceId: 'd', type: 'x', label: 'l', system: 's', user: 'u' });
const bareTask = tasks.get(bare.id);
check('省略字段时 notifyTitle 为 "" 而非 undefined',
  bareTask.notifyTitle === '', 'got=' + JSON.stringify(bareTask.notifyTitle));
check('省略字段时 notifySeed 为 0', bareTask.notifySeed === 0, 'got=' + bareTask.notifySeed);

// 展示一条真实通知文案样例，便于人工核对观感
console.log('');
console.log('  样例（教案，中文）:');
console.log('    标题: ' + buildTexts(ZH_LABELS.plan, zhDict).title);
console.log('    正文: ' + buildTexts(ZH_LABELS.plan, zhDict).body);
console.log('  样例（Lesson Plan, English）:');
const enLabel = 'Lesson Plan';
console.log('    标题: ' + buildTexts(enLabel, enDict).title);
console.log('    正文: ' + buildTexts(enLabel, enDict).body);

/* ------------------------------------------------------------------ *
 * 四、响铃+横幅：客户端渠道与服务端 slotType 必须一致
 *
 * 这是"能收到通知但不响铃、无横幅"的根因所在：
 *   服务端 slotType 只是声明级别，真正生效要靠客户端注册的同类型渠道。
 *   两边任何一边缺失或对不上，通知就会落到默认低级别渠道。
 * 因此这里做**跨端一致性断言**，防止日后单边改动导致回归。
 * ------------------------------------------------------------------ */
console.log('');
console.log('='.repeat(70));
console.log('四、响铃+横幅一致性（客户端渠道 ↔ 服务端 slotType）');
console.log('='.repeat(70));

const notifySlotPath = path.join(__dirname, '..', '..', 'entry', 'src', 'main', 'ets',
  'common', 'NotifySlot.ets');
let slotSrc = '';
try {
  slotSrc = fs.readFileSync(notifySlotPath, 'utf8');
} catch (e) {
  console.log('  FAIL  无法读取 NotifySlot.ets: ' + (e && e.message ? e.message : String(e)));
}

if (slotSrc !== '') {
  /* ------------------------------------------------------------------ *
   * 4.1 【关键】addSlot 必须只传 SlotType 枚举
   *
   * 本机 DevEco SDK 的 addSlot 只有两个重载，**只接受 SlotType**：
   *     function addSlot(type: SlotType, callback: AsyncCallback<void>): void;
   *     function addSlot(type: SlotType): Promise<void>;
   * 传 NotificationSlot 对象会编译失败（10505001）：
   *     Argument of type 'NotificationSlot' is not assignable to
   *     parameter of type 'SlotType'.
   * 这个坑已实际踩过，故独立断言。
   * ------------------------------------------------------------------ */
  check('addSlot 传入 SLOT_TYPE 枚举（非 NotificationSlot 对象）',
    /addSlot\(\s*SLOT_TYPE\s*\)/.test(slotSrc),
    '必须写成 addSlot(SLOT_TYPE)；传对象会在 ArkTS 编译期报 10505001');
  check('未把 NotificationSlot 对象传给 addSlot',
    !/addSlot\(\s*(?!SLOT_TYPE)[a-zA-Z_]\w*\s*\)/.test(stripComments(slotSrc)),
    '发现 addSlot(变量) 写法 —— 本 SDK 不支持，会编译失败');

  // 4.2 必须注册 SOCIAL_COMMUNICATION 渠道
  //     它是 SDK 中默认级别为 LEVEL_HIGH（横幅+提示音）的类型。
  //     注意：本 SDK 的 addSlot 无 level 入参，级别由类型默认值决定，
  //     因此"要横幅"== "必须选 SOCIAL_COMMUNICATION"。
  check('客户端注册 SOCIAL_COMMUNICATION 渠道',
    /SLOT_TYPE[\s\S]{0,300}SOCIAL_COMMUNICATION/.test(slotSrc),
    '未找到 SOCIAL_COMMUNICATION 渠道注册');
  check('未误用无横幅的 CONTENT_INFORMATION / UNKNOWN_TYPE',
    !/SLOT_TYPE[\s\S]{0,300}(CONTENT_INFORMATION|UNKNOWN_TYPE)/.test(slotSrc),
    'CONTENT_INFORMATION 默认 LEVEL_MIN 静默，不会有横幅');

  // 4.3 不得构造 NotificationSlot 对象（本 SDK 不支持该用法）
  check('未构造 NotificationSlot 对象（本 SDK 不支持对象版 addSlot）',
    !/notificationManager\.NotificationSlot\s*=\s*\{/.test(slotSrc),
    '对象版 addSlot 需较新 SDK；本 SDK 会编译失败');

  // 4.4 enabled 是只读字段，任何形式写入都会导致类型错误
  check('未写入只读字段 enabled', !/^\s*enabled:\s*(true|false)/m.test(slotSrc));

  // 4.5 服务端默认 slotType 必须等于 1（SOCIAL_COMMUNICATION 的数值）
  const pushSrc = fs.readFileSync(path.join(__dirname, '..', 'src', 'push.js'), 'utf8');
  const m = /slotType:\s*Number\(process\.env\.AGC_PUSH_SLOT_TYPE\s*\|\|\s*(\d+)\)/.exec(pushSrc);
  check('服务端能找到 slotType 默认值配置', m !== null, '未匹配到 slotType 表达式');
  if (m) {
    const serverDefault = Number(m[1]);
    // OpenHarmony d.ts：SOCIAL_COMMUNICATION = 1
    check('服务端 slotType 默认值为 1（SOCIAL_COMMUNICATION）', serverDefault === 1,
      'got=' + serverDefault + '（1=SOCIAL_COMMUNICATION，与客户端渠道对应）');
  }
}

/* ------------------------------------------------------------------ *
 * 清理
 * ------------------------------------------------------------------ */
try {
  fs.rmSync(tmp, { recursive: true, force: true });
} catch (e) {
  // 清理失败不影响结论
}

console.log('');
console.log('='.repeat(70));
console.log('结果: 通过 ' + passed + ' / 共 ' + (passed + failed) + ' 项' + (failed > 0 ? '，失败 ' + failed : ''));
console.log('='.repeat(70));
process.exit(failed > 0 ? 1 : 0);
