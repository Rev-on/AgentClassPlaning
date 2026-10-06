/**
 * 真机验证：修复后（深度思考 max_tokens=32768）是否还会截断。
 * 对比修复前 8192 的行为，打真实服务器。
 * 用法：node tools/_verify_truncation_fix.js
 */
const https = require('https');

function post(body, timeoutMs) {
  return new Promise((resolve, reject) => {
    const data = Buffer.from(JSON.stringify(body), 'utf8');
    const req = https.request({
      host: 'rev-on.site', port: 3000, path: '/v1/chat/completions', method: 'POST',
      headers: { 'Content-Type': 'application/json; charset=utf-8', 'Content-Length': data.length },
      timeout: timeoutMs,
    }, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    });
    req.on('timeout', () => req.destroy(new Error('timeout')));
    req.on('error', reject);
    req.write(data);
    req.end();
  });
}

const USER = '写一份八年级物理《光的反射》完整教案，包含教学目标、重难点、教学过程（导入/新课/实验/小结/作业）、板书设计，内容要详细充分。';

async function run(label, maxTokens) {
  const t0 = Date.now();
  try {
    const text = await post({
      model: 'deepseek-flash',
      messages: [{ role: 'user', content: USER }],
      max_tokens: maxTokens, temperature: 0.9, stream: false,
      thinking: { type: 'enabled' },
    }, 900000);
    const j = JSON.parse(text);
    const ch = j.choices[0];
    const msg = ch.message || {};
    const content = msg.content || '';
    const reason = msg.reasoning_content || '';
    const ok = ch.finish_reason !== 'length';
    const secs = ((Date.now() - t0) / 1000).toFixed(0);
    console.log(label.padEnd(30)
      + ' finish=' + String(ch.finish_reason).padEnd(8)
      + ' 正文=' + String(content.length).padEnd(6)
      + ' 思考=' + String(reason.length).padEnd(6)
      + ' tokens=' + String(j.usage ? j.usage.completion_tokens : '?').padEnd(6)
      + ' 耗时=' + secs + 's  ' + (ok ? '✅ 完整' : '❌ 截断'));
    return ok;
  } catch (e) {
    console.log(label.padEnd(30) + ' ERROR ' + e.message);
    return false;
  }
}

(async () => {
  console.log('=== 深度思考下的截断：修复前 vs 修复后（真实服务器）===\n');
  const before = await run('修复前 max_tokens=8192', 8192);
  const after = await run('修复后 max_tokens=32768', 32768);
  console.log('');
  console.log('修复前: ' + (before ? '完整' : '截断'));
  console.log('修复后: ' + (after ? '完整' : '截断'));
  console.log(after && !before ? '\n✅ 修复有效：同一条提示词，修复后不再截断。'
    : (after ? '\n✅ 修复后完整（修复前本次也未复现截断，与提示词长度有关）。'
      : '\n⚠️ 修复后仍截断，需要进一步加大额度。'));
})();
