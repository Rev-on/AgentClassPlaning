/**
 * Push Kit 连通性自检。
 *
 * 重要：必须复用 src/push.js 的 readAccount() 逻辑，而不是直接读 AGC_JWT_* 环境变量。
 * 因为生产配置走的是 AGC_PUSH_ACCOUNT_FILE（指向 AGC 下载的服务账号 JSON），
 * 只有 AGC_JWT_* 那几个变量才直接来自环境变量。上一版脚本读错了来源，
 * 导致明明配置正确却报"JWT 生成失败"。
 *
 * 本脚本做两件事：
 *   1. 校验凭据能否生成 JWT（PS256 签名）
 *   2. 拿 JWT 向华为 oauth 换取 access_token —— 这是"凭据真实有效"的唯一硬证据
 */
const path = require('path');
const fs = require('fs');
const crypto = require('crypto');
const https = require('https');

// 加载 .env（脚本可能被放在 server/ 或 server/tools/）
for (const c of [path.join(__dirname, '.env'), path.join(__dirname, '..', '.env')]) {
  if (fs.existsSync(c)) {
    require('dotenv').config({ path: c });
    break;
  }
}

// 定位 src/push.js
function findPush() {
  const cands = [
    path.join(__dirname, 'src', 'push'),
    path.join(__dirname, '..', 'src', 'push'),
    path.join(process.cwd(), 'src', 'push')
  ];
  for (const c of cands) {
    if (fs.existsSync(c + '.js')) {
      return c;
    }
  }
  console.error('找不到 src/push.js');
  process.exit(1);
}
const push = require(findPush());

function b64url(buf) {
  return Buffer.from(buf).toString('base64')
    .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

/** 与 push.js 内部一致地解析账号信息 */
function readAccount() {
  const file = process.env.AGC_PUSH_ACCOUNT_FILE;
  if (file && fs.existsSync(file)) {
    const j = JSON.parse(fs.readFileSync(file, 'utf8'));
    return {
      source: 'AGC_PUSH_ACCOUNT_FILE (' + file + ')',
      projectId: process.env.AGC_PROJECT_ID || j.project_id || '',
      kid: j.key_id || '',
      iss: j.sub_account || j.client_email || '',
      privateKey: j.private_key || ''
    };
  }
  return {
    source: '环境变量 AGC_JWT_*',
    projectId: process.env.AGC_PROJECT_ID || '',
    kid: process.env.AGC_JWT_KID || '',
    iss: process.env.AGC_JWT_ISS || '',
    privateKey: process.env.AGC_JWT_PRIVATE_KEY || ''
  };
}

function buildJwt(a, aud) {
  const now = Math.floor(Date.now() / 1000);
  const header = b64url(JSON.stringify({ kid: a.kid, alg: 'PS256', typ: 'JWT' }));
  const payload = b64url(JSON.stringify({ aud: aud, iss: a.iss, iat: now, exp: now + 3600 }));
  const input = header + '.' + payload;
  const key = crypto.createPrivateKey(String(a.privateKey).replace(/\\n/g, '\n'));
  const signer = crypto.createSign('RSA-SHA256');
  signer.update(input);
  signer.end();
  const sig = signer.sign({ key: key, padding: crypto.constants.RSA_PKCS1_PSS_PADDING, saltLength: 32 });
  return input + '.' + b64url(sig);
}

const AUD = 'https://oauth-login.cloud.huawei.com/oauth2/v3/token';

console.log('='.repeat(66));
console.log('Push Kit 连通性自检');
console.log('='.repeat(66));
console.log();

const a = readAccount();
console.log('一、凭据来源');
console.log('  来源       : %s', a.source);
console.log('  projectId  : %s', a.projectId || '(空)');
console.log('  key_id     : %s', a.kid || '(空)');
console.log('  sub_account: %s', a.iss || '(空)');
console.log('  privateKey : %s', a.privateKey ? '(已提供, 长度 ' + String(a.privateKey).length + ')' : '(空)');
console.log();

console.log('二、push.configured()');
console.log('  结果: %s', push.configured());
console.log();

if (!push.configured()) {
  console.log('=> 凭据不完整，推送会被静默跳过。');
  process.exit(1);
}

console.log('三、JWT 签名（PS256）');
let jwt = '';
try {
  jwt = buildJwt(a, AUD);
  console.log('  ✔ 成功，长度 %d', jwt.length);
} catch (e) {
  console.log('  ✘ 失败: %s', e && e.message ? e.message : String(e));
  process.exit(1);
}

console.log();
console.log('四、向华为换取 access_token（凭据有效性的硬证据）');
const qs = require('querystring');
const body = qs.stringify({
  grant_type: 'client_credentials',
  client_id: a.iss,
  client_secret: jwt
});
const req = https.request({
  hostname: 'oauth-login.cloud.huawei.com',
  path: '/oauth2/v3/token',
  method: 'POST',
  headers: {
    'Content-Type': 'application/x-www-form-urlencoded',
    'Content-Length': Buffer.byteLength(body)
  }
}, (res) => {
  let data = '';
  res.on('data', (c) => { data += c; });
  res.on('end', () => {
    console.log('  HTTP %d', res.statusCode);
    let j = null;
    try {
      j = JSON.parse(data);
    } catch (e) {
      console.log('  原始响应: %s', data.slice(0, 300));
      return;
    }
    if (j.access_token) {
      console.log('  ✔ access_token 获取成功: %s...', String(j.access_token).slice(0, 24));
      console.log('  ✔ expires_in: %s 秒', j.expires_in);
      console.log();
      console.log('='.repeat(66));
      console.log('结论: Push Kit 凭据【可用】');
      console.log('='.repeat(66));
    } else {
      console.log('  ✘ 未取得 access_token');
      console.log('  返回: %s', JSON.stringify(j).slice(0, 500));
      console.log();
      console.log('='.repeat(66));
      console.log('结论: 凭据【不可用】');
      console.log('='.repeat(66));
    }
  });
});
req.on('error', (e) => {
  console.log('  ✘ 请求失败: %s', e.message);
});
req.write(body);
req.end();
