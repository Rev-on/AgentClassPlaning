/**
 * 诊断：Windows 版生成被截断的原因。
 * 怀疑点：max_tokens=8192 与"深度思考"共享预算 —— reasoning_tokens 会吃掉配额，
 *        留给正文的额度不足，导致正文被截断（finish_reason=length）。
 * 用法：node tools/_diag_truncation.js
 */
const https = require('https');

const HOST = 'rev-on.site';
const PORT = 3000;

function post(pathname, body, timeoutMs) {
  return new Promise((resolve, reject) => {
    const data = Buffer.from(JSON.stringify(body), 'utf8');
    const req = https.request({
      host: HOST, port: PORT, path: pathname, method: 'POST',
      headers: { 'Content-Type': 'application/json; charset=utf-8', 'Content-Length': data.length },
      timeout: timeoutMs,
    }, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => resolve({ status: res.statusCode, text: Buffer.concat(chunks).toString('utf8') }));
    });
    req.on('timeout', () => { req.destroy(new Error('timeout')); });
    req.on('error', reject);
    req.write(data);
    req.end();
  });
}

const USER = '写一份八年级物理《光的反射》完整教案，包含教学目标、重难点、教学过程（导入/新课/实验/小结/作业）、板书设计，内容要详细充分。';

async function trial(label, body) {
  try {
    const r = await post('/v1/chat/completions', body, 600000);
    if (r.status !== 200) {
      console.log(label.padEnd(34) + ' HTTP ' + r.status + '  ' + r.text.slice(0, 160));
      return;
    }
    const j = JSON.parse(r.text);
    const ch = j.choices[0];
    const msg = ch.message || {};
    const content = msg.content || '';
    const reason = msg.reasoning_content || '';
    console.log(label.padEnd(34)
      + ' finish=' + String(ch.finish_reason).padEnd(8)
      + ' content=' + String(content.length).padEnd(6)
      + ' reasoning=' + String(reason.length).padEnd(6)
      + ' completion_tokens=' + (j.usage ? j.usage.completion_tokens : '?'));
    if (ch.finish_reason === 'length') {
      console.log('    ^^^ 被截断（finish_reason=length）');
    }
  } catch (e) {
    console.log(label.padEnd(34) + ' ERROR ' + e.message);
  }
}

(async () => {
  console.log('=== 诊断：max_tokens / 深度思考 对截断的影响 ===\n');

  // 1) 关闭思考
  await trial('thinking=disabled max_tokens=8192', {
    model: 'deepseek-flash',
    messages: [{ role: 'user', content: USER }],
    max_tokens: 8192, temperature: 0.9, stream: false,
    thinking: { type: 'disabled' },
  });

  // 2) 开启思考（Windows 版默认可能开启）
  await trial('thinking=enabled  max_tokens=8192', {
    model: 'deepseek-flash',
    messages: [{ role: 'user', content: USER }],
    max_tokens: 8192, temperature: 0.9, stream: false,
    thinking: { type: 'enabled' },
  });

  // 3) 开启思考 + 更大额度
  await trial('thinking=enabled  max_tokens=32768', {
    model: 'deepseek-flash',
    messages: [{ role: 'user', content: USER }],
    max_tokens: 32768, temperature: 0.9, stream: false,
    thinking: { type: 'enabled' },
  });

  // 4) 长时间请求：模拟课件（更长的输出）
  await trial('courseware thinking=on mt=32768', {
    model: 'deepseek-flash',
    messages: [
      { role: 'system', content: '你是备课助手' },
      { role: 'user', content: '生成 12 页初中物理课件 JSON 大纲，每页含 title 与 3-5 条要点，内容详细。' },
    ],
    max_tokens: 32768, temperature: 0.9, stream: false,
    thinking: { type: 'enabled' },
  });

  console.log('\n提示：若 max_tokens 小的那组 finish=length，即证实"额度不足导致截断"。');
})();
