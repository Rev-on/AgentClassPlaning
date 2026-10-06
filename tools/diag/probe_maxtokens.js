/**
 * 验证：提高 max_tokens 是否会超过模型上限而被拒；并找出安全上限。
 * 用法：node tools/_probe_maxtokens.js
 */
const https = require('https');

function post(pathname, body, timeoutMs) {
  return new Promise((resolve, reject) => {
    const data = Buffer.from(JSON.stringify(body), 'utf8');
    const req = https.request({
      host: 'rev-on.site', port: 3000, path: pathname, method: 'POST',
      headers: { 'Content-Type': 'application/json; charset=utf-8', 'Content-Length': data.length },
      timeout: timeoutMs,
    }, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => resolve({ status: res.statusCode, text: Buffer.concat(chunks).toString('utf8') }));
    });
    req.on('timeout', () => req.destroy(new Error('timeout')));
    req.on('error', reject);
    req.write(data);
    req.end();
  });
}

async function probe(mt) {
  // 只发极短请求，目的仅是看服务端/上游是否接受该 max_tokens 值
  try {
    const r = await post('/v1/chat/completions', {
      model: 'deepseek-flash',
      messages: [{ role: 'user', content: '1+1=?' }],
      max_tokens: mt, temperature: 0.9, stream: false,
      thinking: { type: 'disabled' },
    }, 90000);
    if (r.status === 200) {
      const j = JSON.parse(r.text);
      console.log('max_tokens=' + String(mt).padEnd(7) + ' -> HTTP 200  finish=' + j.choices[0].finish_reason
        + '  completion_tokens=' + (j.usage ? j.usage.completion_tokens : '?'));
    } else {
      console.log('max_tokens=' + String(mt).padEnd(7) + ' -> HTTP ' + r.status + '  ' + r.text.slice(0, 200));
    }
  } catch (e) {
    console.log('max_tokens=' + String(mt).padEnd(7) + ' -> ERROR ' + e.message);
  }
}

(async () => {
  console.log('=== 探测 max_tokens 上限（服务端/上游是否接受）===\n');
  for (const mt of [8192, 16384, 32768, 65536, 131072]) {
    await probe(mt);
  }
  console.log('\n结论：只要没有报错，即可安全采用更大的值。');
})();
