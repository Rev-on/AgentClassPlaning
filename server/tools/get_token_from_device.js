/**
 * 直接从真机提取 HarmonyOS Push Token（不改服务端、不改 App 也能用）。
 *
 * ============================================================================
 * 【为什么需要"直接从设备取"这条路】
 * ============================================================================
 * Push Token 由 `@kit.PushKit` 的 `pushService.getToken()` 在**应用进程内**申请，
 * 外部脚本无法调用它。已有的两条路各有前提：
 *   · 服务端读回  → 需要服务端部署了 GET /api/push/devices（旧版没有）
 *   · App 日志    → PushToken.ets 只打前 12 位，**拿不到全文**
 *
 * 但 Token 申请出来后一定会经过**华为推送服务的客户端**（live_view / push 相关
 * system ability），这些系统进程会把 Token 记进自己的日志。本脚本就是去
 * **系统侧**把它捞出来。
 *
 * ============================================================================
 * 【原理与可靠性说明（重要，别抱不切实际的期待）】
 * ============================================================================
 * 分两步：
 *   Step 1  重启目标应用（默认 com.rev.myapplication），触发它重新 getToken()。
 *           为什么要重启：Token 只在申请那一刻会进日志，不重启就抓不到新记录。
 *   Step 2  在 hilog 里检索形如 `MA...` 的 Base64Url 长串（华为 Push Token 的形态）。
 *
 * **可靠性取决于系统日志是否输出了完整 Token**：
 *   不同 HarmonyOS 版本、不同机型，`push`/`live_view` 系统服务的日志详细程度不同。
 *   有的会打印完整 Token，有的只打长度或前几位。如果 Step 2 只找到长度记录
 *   （例如 "pushToken length: 112"）而没有全文，本脚本会明确告诉你
 *   **降级方案**：改用 `--full` 读服务端（需先部署新接口），
 *   或临时把 PushToken.ets 的日志改成打印完整 token 再重启一次。
 *
 * 本脚本**不会**为了拿 Token 去破解或篡改任何系统数据，只是读日志。
 *
 * ============================================================================
 * 【用法】
 * ============================================================================
 *   cd server
 *
 *   # 最常用：重启 App 并抓取 Token
 *   node tools/get_token_from_device.js
 *
 *   # 只抓当前日志，不重启 App（Token 刚申请过才有）
 *   node tools/get_token_from_device.js --no-restart
 *
 *   # 指定包名 / 抓取时长（秒）
 *   node tools/get_token_from_device.js --bundle com.rev.myapplication --seconds 15
 *
 *   # 同时打印原始候选行，便于人工核对
 *   node tools/get_token_from_device.js --verbose
 */

const { execFileSync, execSync } = require('child_process');
const fs = require('fs');
const path = require('path');

/* ==================== 参数 ==================== */

function parseArgs(argv) {
  const o = {
    bundle: 'com.rev.myapplication',
    seconds: 12,
    restart: true,
    verbose: false,
    json: false
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--no-restart') o.restart = false;
    else if (a === '--verbose' || a === '-v') o.verbose = true;
    else if (a === '--json') o.json = true;
    else if (a === '--bundle') o.bundle = argv[++i] || o.bundle;
    else if (a === '--seconds') o.seconds = Math.max(3, Number(argv[++i]) || 12);
    else if (a === '-h' || a === '--help') o.help = true;
  }
  return o;
}

/* ==================== hdc 定位 ==================== */

function findHdc() {
  const cands = [
    process.env.HDC_PATH || '',
    'D:\\Program Files\\Huawei\\DevEco Studio\\sdk\\default\\openharmony\\toolchains\\hdc.exe',
    'C:\\Program Files\\Huawei\\DevEco Studio\\sdk\\default\\openharmony\\toolchains\\hdc.exe'
  ];
  for (const c of cands) {
    if (c && fs.existsSync(c)) return c;
  }
  try {
    const r = execSync('where hdc', { encoding: 'utf8', timeout: 5000 });
    const first = r.split(/\r?\n/).map((s) => s.trim()).filter((s) => s !== '')[0];
    if (first && fs.existsSync(first)) return first;
  } catch (e) { /* ignore */ }
  return '';
}

/* ==================== 华为 Push Token 形态 ==================== */

/**
 * 华为 Push Token 特征：
 *   · 以 "MA" 开头（实测及官方文档一致）
 *   · 长度通常 100+，最短也在 40 以上（服务端 tasks.js 的 TOKEN_MIN_LEN = 40）
 *   · 字符集为 Base64Url：[A-Za-z0-9_-]
 *
 * 这里要求 >= 60 是为了避免把日志里其它短的 base64 片段误当成 Token
 * （例如 session id、trace id）。真实 Token 长度普遍 100 上下。
 */
const TOKEN_RE = /MA[A-Za-z0-9_-]{60,}/g;

/** 日志里"只报了长度、没报全文"的痕迹，用于给出准确结论 */
const LEN_ONLY_RE = /pushToken\s+length[:：]?\s*(\d+)/i;

/* ==================== 主流程 ==================== */

function run(hdc, args, timeout) {
  try {
    return execFileSync(hdc, args, {
      encoding: 'utf8',
      timeout: timeout || 20000,
      maxBuffer: 64 * 1024 * 1024,
      stdio: ['ignore', 'pipe', 'pipe']
    });
  } catch (e) {
    // hilog -x 会持续输出直到超时被杀，属预期：捕获已产出的部分
    if (e && e.stdout) return String(e.stdout);
    if (e && e.stderr && String(e.stderr).trim() !== '') {
      return String(e.stdout || '') + '\n' + String(e.stderr);
    }
    return String((e && e.stdout) || '');
  }
}

function main() {
  const opts = parseArgs(process.argv.slice(2));
  if (opts.help) {
    console.log('用法：node tools/get_token_from_device.js [--no-restart] [--bundle COM] [--seconds N] [--verbose]');
    return;
  }

  console.log('='.repeat(78));
  console.log('从真机提取 HarmonyOS Push Token');
  console.log('='.repeat(78));

  const hdc = findHdc();
  if (hdc === '') {
    console.log('\n✗ 未找到 hdc.exe。');
    console.log('  通常在：DevEco Studio/sdk/default/openharmony/toolchains/hdc.exe');
    console.log('  可用环境变量 HDC_PATH 指定完整路径。');
    process.exitCode = 1;
    return;
  }
  console.log('\nhdc: ' + hdc);

  // ---- 设备检查 ----
  const targets = run(hdc, ['list', 'targets'], 15000).trim();
  if (targets === '' || /empty/i.test(targets)) {
    console.log('\n✗ 没有连接真机。请用 USB 连接设备并开启「开发者选项 → USB 调试」。');
    process.exitCode = 1;
    return;
  }
  const dev = targets.split(/\r?\n/).map((s) => s.trim()).filter((s) => s !== '')[0];
  console.log('设备: ' + dev);

  // ---- 清日志 + 重启 App，触发重新申请 Token ----
  run(hdc, ['shell', 'hilog', '-r'], 15000);
  console.log('\n已清空设备日志。');

  if (opts.restart) {
    console.log('正在重启应用 ' + opts.bundle + ' ...');
    run(hdc, ['shell', 'aa', 'force-stop', opts.bundle], 20000);
    const started = run(hdc, ['shell', 'aa', 'start', '-a', 'EntryAbility', '-b', opts.bundle], 20000);
    if (/fail|error/i.test(started) && !/successfully/i.test(started)) {
      console.log('  ⚠ 启动返回：' + started.trim().slice(0, 200));
    } else {
      console.log('  已启动，等待 ' + opts.seconds + ' 秒让它申请并上报 Token ...');
    }
  } else {
    console.log('（--no-restart：不清日志、不重启，直接读当前缓冲区）');
  }

  // ---- 抓日志 ----
  const waitMs = opts.restart ? opts.seconds * 1000 : 3000;
  const t0 = Date.now();
  // 分多次短抓取，避免单次 hilog -x 阻塞过久
  let raw = '';
  while (Date.now() - t0 < waitMs) {
    raw += run(hdc, ['shell', 'hilog', '-x'], 4000);
    if (raw.length > 8 * 1024 * 1024) break;
  }

  const lines = raw.split(/\r?\n/).filter((l) => l.length > 0 && l.length < 4000);

  console.log('\n共抓取日志 ' + lines.length + ' 行。');

  // ---- 1) 本应用的 PushToken 记录（确认申请成功与否）----
  const appLines = lines.filter((l) => l.indexOf(opts.bundle) >= 0 && /PushToken|getToken/i.test(l));
  if (appLines.length > 0) {
    console.log('\n【应用侧记录】');
    for (const l of appLines.slice(-6)) {
      console.log('  ' + l.trim().slice(0, 220));
    }
  } else {
    console.log('\n【应用侧记录】未发现 PushToken 日志。');
    console.log('  可能：应用未启动 / 未走到 PushToken.ensure()（它在 EntryAbility.onCreate 里）');
  }

  // ---- 2) 系统侧完整 Token ----
  const found = new Map();
  for (const l of lines) {
    const m = l.match(TOKEN_RE);
    if (m) {
      for (const tk of m) {
        if (!found.has(tk)) found.set(tk, l.trim());
      }
    }
  }

  // ---- 3) 只报长度的痕迹 ----
  let lenOnly = '';
  for (const l of lines) {
    const m = l.match(LEN_ONLY_RE);
    if (m) { lenOnly = m[1]; break; }
  }

  console.log('\n' + '-'.repeat(78));

  if (found.size > 0) {
    console.log('\n✅ 找到 ' + found.size + ' 个完整 Token：\n');
    let i = 0;
    for (const [tk, src] of found) {
      i++;
      console.log('  [' + i + '] Token（' + tk.length + ' 字符）：');
      console.log('      ' + tk);
      if (opts.verbose) {
        console.log('      来源行: ' + src.slice(0, 200));
      }
      console.log('');
    }
    if (found.size > 1) {
      console.log('  ⚠ 找到多个候选。华为 Token 会随重装/恢复出厂变化，');
      console.log('    通常**取最新申请的那个**（一般是最长/最后出现的）。');
      console.log('    可用服务端 deviceId 与 Token 的对应关系交叉确认（见 docs）。');
    }
    console.log('\n  验证方式：把它填到 server/data/devices.json：');
    console.log('    [{"id":"<你的 deviceId>","token":"<上面的 Token>","updatedAt":' + Date.now() + '}]');
    console.log('  或用 curl 上报：');
    console.log('    curl -X POST <SERVER>/api/push/register \\');
    console.log('         -H "Content-Type: application/json" \\');
    console.log('         -H "x-proxy-token: <PROXY_TOKEN>" \\');
    console.log('         -d \'{"deviceId":"<id>","token":"<上面 Token>"}\'');
  } else {
    console.log('\n⚠ 没有在日志里找到完整的 Push Token。');
    if (lenOnly !== '') {
      console.log('\n  但发现系统只报了**长度**（pushToken length: ' + lenOnly + '），没有报全文。');
      console.log('  说明这台设备的系统日志不会输出 Token 明文（出于安全是合理设计）。');
    } else {
      console.log('\n  系统日志里既没有 Token 全文，也没有长度记录。');
    }
    console.log('\n  → 请改用以下任一方式（按推荐顺序）：');
    console.log('     1) 部署带 GET /api/push/devices 的服务端后：');
    console.log('          node tools/get_device_token.js --server <你的服务器> --full');
    console.log('        （App 一启动就会把 Token 上报，服务端本来就有这份数据）');
    console.log('     2) 临时把 entry/src/main/ets/common/PushToken.ets 的日志');
    console.log('          第 37 行 token.substring(0, 12) 改成 token');
    console.log('        重新装包并启动一次，本脚本即可抓到全文（用完记得改回）。');
    process.exitCode = 2;
  }

  console.log('\n' + '='.repeat(78));
}

main();
