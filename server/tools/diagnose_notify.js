/**
 * 一键诊断：7 大 AI 生成功能"完成通知收不到"。
 *
 * 用法（上传到服务器后执行，避免 PowerShell 引号问题）：
 *   scp -i c:\Users\laoyu\.ssh\rev_deploy server/tools/diagnose_notify.js root@123.60.130.45:/opt/rev-server/tools/
 *   ssh -i c:\Users\laoyu\.ssh\rev_deploy root@123.60.130.45 "cd /opt/rev-server && node tools/diagnose_notify.js"
 *
 * 本脚本按"通知送达的 5 个必要条件"逐层检查，并在第一处失败点给出修复建议。
 * 全程只读，不修改任何文件、不发送任何推送。
 */
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const OK = '  [通过] ';
const BAD = '  [失败] ';
const WARN = '  [注意] ';
const INFO = '  [信息] ';

let firstFailure = '';
function fail(msg, fix) {
  console.log(BAD + msg);
  if (fix) {
    console.log('         → 修复：' + fix);
  }
  if (firstFailure === '') {
    firstFailure = msg;
  }
}
function ok(msg) { console.log(OK + msg); }
function warn(msg, fix) {
  console.log(WARN + msg);
  if (fix) {
    console.log('         → 建议：' + fix);
  }
}
function info(msg) { console.log(INFO + msg); }

// 加载 .env（脚本在 tools/ 下，.env 在上一级）
const envPath = path.join(__dirname, '..', '.env');
if (fs.existsSync(envPath)) {
  require('dotenv').config({ path: envPath });
  info('.env 已加载: ' + envPath);
} else {
  warn('.env 不存在: ' + envPath, '服务端可能未正确配置');
}

console.log('');
console.log('='.repeat(72));
console.log('完成通知诊断 —— 逐层检查 5 个必要条件');
console.log('='.repeat(72));
console.log('');

/* ---------------------------------------------------------------- *
 * 第 1 层：推送总开关
 * ---------------------------------------------------------------- */
console.log('【第 1 层】推送总开关 PUSH_ENABLED');
const pushEnabled = process.env.PUSH_ENABLED === '1';
info('PUSH_ENABLED = ' + JSON.stringify(process.env.PUSH_ENABLED) + '  解析结果 = ' + pushEnabled);
if (pushEnabled) {
  ok('开关已开启，服务端会尝试推送');
} else {
  fail('开关未开启：server.js 根本不会进入推送分支（连日志都不会打）',
    '在 /opt/rev-server/.env 加一行 PUSH_ENABLED=1，然后 pm2 restart rev-server');
}

/* ---------------------------------------------------------------- *
 * 第 2 层：AGC 凭据
 * ---------------------------------------------------------------- */
console.log('');
console.log('【第 2 层】AGC 凭据（华为推送鉴权）');
let pushMod = null;
try {
  pushMod = require('../src/push');
} catch (e) {
  fail('无法加载 src/push.js: ' + (e && e.message ? e.message : String(e)));
}
if (pushMod) {
  const configured = pushMod.configured();
  info('push.configured() = ' + configured);
  const accountFile = process.env.AGC_PUSH_ACCOUNT_FILE || '';
  info('AGC_PUSH_ACCOUNT_FILE = ' + (accountFile === '' ? '(空)' : accountFile));
  info('AGC_PROJECT_ID        = ' + (process.env.AGC_PROJECT_ID || '(空)'));
  info('AGC_JWT_KID           = ' + (process.env.AGC_JWT_KID || '(空)'));
  info('AGC_JWT_ISS           = ' + (process.env.AGC_JWT_ISS || '(空)'));
  info('AGC_JWT_PRIVATE_KEY   = ' + (process.env.AGC_JWT_PRIVATE_KEY ? '(已设置)' : '(空)'));

  if (accountFile !== '' && !fs.existsSync(accountFile)) {
    fail('AGC_PUSH_ACCOUNT_FILE 指向的文件不存在: ' + accountFile, '检查路径是否正确、文件是否已上传');
  } else if (accountFile !== '') {
    // 复用 push.js 的解析逻辑校对内容
    try {
      const j = JSON.parse(fs.readFileSync(accountFile, 'utf8'));
      const hasKid = !!(j.key_id);
      const hasIss = !!(j.sub_account || j.client_email);
      const hasKey = !!(j.private_key);
      const hasProj = !!(process.env.AGC_PROJECT_ID || j.project_id);
      info('服务账号文件字段: key_id=' + hasKid + ' sub_account=' + hasIss
        + ' private_key=' + hasKey + ' project_id=' + hasProj);
      if (!hasKid || !hasIss || !hasKey || !hasProj) {
        fail('服务账号文件缺少必要字段', '重新从 AGC 下载服务账号 JSON 并覆盖');
      }
    } catch (e) {
      fail('服务账号文件不是合法 JSON: ' + (e && e.message ? e.message : String(e)));
    }
  }

  if (configured) {
    ok('凭据齐备，configured() = true');
    // 真做一次 PS256 签名，确认私钥可用（这是最有价值的一步）
    try {
      const f = accountFile !== '' && fs.existsSync(accountFile)
        ? JSON.parse(fs.readFileSync(accountFile, 'utf8')) : {};
      const kid = f.key_id || process.env.AGC_JWT_KID || '';
      const iss = f.sub_account || f.client_email || process.env.AGC_JWT_ISS || '';
      const pk = f.private_key || process.env.AGC_JWT_PRIVATE_KEY || '';
      const b64 = (b) => Buffer.from(b).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
      const now = Math.floor(Date.now() / 1000);
      const input = b64(JSON.stringify({ kid, alg: 'PS256', typ: 'JWT' })) + '.'
        + b64(JSON.stringify({
          aud: 'https://oauth-login.cloud.huawei.com/oauth2/v3/token',
          iss, iat: now, exp: now + 3600
        }));
      const key = crypto.createPrivateKey(String(pk).replace(/\\n/g, '\n'));
      const s = crypto.createSign('RSA-SHA256');
      s.update(input);
      s.end();
      const sig = s.sign({ key, padding: crypto.constants.RSA_PKCS1_PSS_PADDING, saltLength: 32 });
      ok('PS256 JWT 签名成功（私钥可用，签名长度 ' + sig.length + ' 字节）');
    } catch (e) {
      fail('JWT 签名失败（私钥格式有问题）: ' + (e && e.message ? e.message : String(e)),
        '私钥需为 PKCS8 PEM；换行符在 .env 中要写成 \\n');
    }
  } else {
    fail('凭据不完整，推送会被跳过并打印"未配置 AGC 推送凭据"',
      '在 .env 中补齐 AGC_PROJECT_ID + AGC_JWT_KID + AGC_JWT_ISS + AGC_JWT_PRIVATE_KEY（或 AGC_PUSH_ACCOUNT_FILE）后 pm2 restart');
  }
}

/* ---------------------------------------------------------------- *
 * 第 3 层：设备 Push Token
 * ---------------------------------------------------------------- */
console.log('');
console.log('【第 3 层】设备 Push Token（"往哪台设备推"）');
try {
  const tasks = require('../src/tasks');
  const devices = tasks.listDevices();
  info('已注册设备数 = ' + devices.length);
  if (devices.length === 0) {
    fail('没有任何有效设备 token —— 推送没有目标，必然收不到',
      '打开 App 让它启动一次（EntryAbility 会自动申请并上报 token）。'
      + '若仍为 0，检查：应用是否在 AGC 开通了推送服务、设备是否登录华为账号');
  } else {
    devices.slice(0, 5).forEach((d, i) => {
      info('  设备' + (i + 1) + ': id=' + d.id
        + ' token=' + String(d.token).slice(0, 10) + '...'
        + ' (长度 ' + String(d.token).length + ')'
        + ' 更新于 ' + new Date(d.updatedAt).toLocaleString());
    });
    ok('存在 ' + devices.length + ' 个可用 token');
    const newest = devices[0];
    const ageMin = Math.round((Date.now() - newest.updatedAt) / 60000);
    if (ageMin > 60 * 24 * 30) {
      warn('最新 token 已是 ' + ageMin + ' 分钟前上报，可能对应已卸载/重装的旧设备');
    }
  }
} catch (e) {
  fail('无法读取设备列表: ' + (e && e.message ? e.message : String(e)));
}

/* ---------------------------------------------------------------- *
 * 第 4 层：任务侧的通知字段
 * ---------------------------------------------------------------- */
console.log('');
console.log('【第 4 层】最近任务是否带上了通知文案');
try {
  const tasks = require('../src/tasks');
  // 直接读持久化文件，看最近任务的 notify 字段
  const dataDir = process.env.DATA_DIR || path.join(__dirname, '..', 'data');
  const tf = path.join(dataDir, 'tasks.json');
  info('任务文件: ' + tf);
  if (fs.existsSync(tf)) {
    const arr = JSON.parse(fs.readFileSync(tf, 'utf8'));
    info('历史任务数 = ' + arr.length);
    const recent = arr.slice().sort((a, b) => b.createdAt - a.createdAt).slice(0, 5);
    if (recent.length === 0) {
      warn('还没有任何任务记录', '先在 App 里发起一次生成');
    }
    recent.forEach((t) => {
      console.log('    - type=' + t.type + ' status=' + t.status
        + ' notifyId=' + JSON.stringify(t.notifySeed)
        + ' title=' + JSON.stringify(t.notifyTitle)
        + ' body=' + JSON.stringify(t.notifyBody));
    });
    const withNotify = recent.filter((t) => t.notifySeed && t.notifyTitle);
    if (withNotify.length === 0) {
      fail('最近任务都没有 notifySeed/notifyTitle —— 说明提交任务的是**旧版客户端**',
        '旧版 App 不上报通知字段。需要用包含本次改动的客户端重新构建安装（GenTask.ets 的改动）');
    } else {
      ok('最近 ' + withNotify.length + '/' + recent.length + ' 个任务带有完整通知文案');
    }
  } else {
    warn('任务文件不存在（服务端可能尚无生成任务）', '先在 App 里发起一次生成');
  }
} catch (e) {
  fail('读取任务记录失败: ' + (e && e.message ? e.message : String(e)));
}

/* ---------------------------------------------------------------- *
 * 第 5 层：前台展示开关（本次"前台收不到"的高度可疑项）
 * ---------------------------------------------------------------- */
console.log('');
console.log('【第 5 层】前台是否展示通知');
try {
  const src = fs.readFileSync(path.join(__dirname, '..', 'src', 'push.js'), 'utf8');
  const m = src.match(/foregroundShow:\s*(true|false)/);
  const cfgVar = /AGC_PUSH_FOREGROUND_SHOW/.test(src);
  if (cfgVar) {
    const on = process.env.AGC_PUSH_FOREGROUND_SHOW === 'true';
    info('push.js 支持 AGC_PUSH_FOREGROUND_SHOW 开关，当前 = '
      + JSON.stringify(process.env.AGC_PUSH_FOREGROUND_SHOW) + ' → 前台展示 = ' + on);
    if (on) {
      ok('前台也会展示通知（便于前台联调）');
    } else {
      warn('前台不展示：App 停留在前台时，即使推送成功，系统也会**静默不弹通知**。'
        + '这是华为的设计（前台已有实况窗，避免重复提醒）。'
        + '**前台测试收不到属预期行为，不是故障。**',
        '联调期可临时在 .env 加 AGC_PUSH_FOREGROUND_SHOW=true 并重启，即可在前台看到通知；'
        + '正式体验建议保持默认 false，改到"生成中退到桌面/杀进程"场景验证。');
    }
  } else if (m) {
    info('push.js 中 foregroundShow 硬编码 = ' + m[1] + '（该版本不支持环境变量开关）');
    if (m[1] === 'false') {
      warn('前台不展示：App 停留在前台时，即使推送成功，系统也会**静默不弹通知**。'
        + '**前台测试收不到属预期行为，不是故障。**',
        '改到"生成中退到桌面/杀进程"场景复测，那才是推送要解决的场景');
    }
  }
  const slot = process.env.AGC_PUSH_SLOT_TYPE || '1';
  const cat = process.env.AGC_PUSH_CATEGORY || 'WORK';
  // slotType 与"响铃+横幅"直接相关：0=静默 1=社交(横幅+提示音) 2=服务提醒(仅提示音) 3=静默
  const slotNames = {
    '0': '未知/静默', '1': '社交通信（横幅+提示音）',
    '2': '服务提醒（仅提示音）', '3': '内容资讯（静默）'
  };
  info('AGC_PUSH_SLOT_TYPE = ' + slot + ' → ' + (slotNames[String(slot)] || '未知取值'));
  info('AGC_PUSH_CATEGORY  = ' + cat);
  if (String(slot) === '1') {
    ok('slotType=1（SOCIAL_COMMUNICATION）：配合客户端渠道可响铃 + 弹横幅');
    console.log('         注意：横幅是否真的出现，还取决于**客户端是否注册了同类型渠道**。');
    console.log('             客户端未注册 → 落到默认低级别渠道 → 只收到、不响铃、无横幅。');
    console.log('             客户端实现见 entry/src/main/ets/common/NotifySlot.ets');
  } else if (String(slot) === '3' || String(slot) === '0') {
    fail('slotType=' + slot + ' 属静默类型，不会有横幅和提示音',
      '设为 1（社交通信）才能响铃 + 弹横幅');
  } else if (String(slot) === '2') {
    warn('slotType=2（服务提醒）只有提示音、**没有横幅**',
      '若要横幅请设为 1（SOCIAL_COMMUNICATION）');
  }
  if (String(cat) === 'MARKETING') {
    warn('category=MARKETING 属营销类，用户可整体关闭营销通知而收不到', '改为 WORK');
  }
} catch (e) {
  fail('无法读取 push.js: ' + (e && e.message ? e.message : String(e)));
}

/* ---------------------------------------------------------------- *
 * 汇总
 * ---------------------------------------------------------------- */
console.log('');
console.log('='.repeat(72));
if (firstFailure === '') {
  console.log('结论：5 层检查均未发现硬性阻断。');
  console.log('');
  console.log('若前台测试收不到，最可能就是第 5 层的 foregroundShow=false（属预期行为）。');
  console.log('请改到"生成中退到桌面/杀进程"场景复测 —— 那才是推送要解决的场景。');
} else {
  console.log('结论：第一处硬性阻断是 ——');
  console.log('  ' + firstFailure);
  console.log('');
  console.log('请先按上面的"→ 修复"处理该层，再重新运行本脚本。');
}
console.log('='.repeat(72));
