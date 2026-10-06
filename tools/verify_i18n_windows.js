/**
 * verify_i18n_windows.js
 * ---------------------------------------------------------------------------
 * Independent verifier for Windows/renderer/js/i18n-data.js.
 *
 * Deliberately does NOT import tools/gen_i18n_windows.js. It builds the
 * expected dictionary by a different method: it locates each Map literal with
 * its own scanner and evaluates every pair's string literals with the JS engine
 * itself (eval), so escape handling is ground-truthed by the runtime rather
 * than by the generator's hand-written unescaper.
 *
 * Asserts, per language, that every source key is present with a
 * byte-identical value, and that no key present in the pre-change target was
 * dropped.
 *
 * Usage: node tools/verify_i18n_windows.js
 * Exit code 0 = all checks pass.
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const COMMON = path.join(ROOT, 'entry', 'src', 'main', 'ets', 'common');
const TARGET = path.join(ROOT, 'Windows', 'renderer', 'js', 'i18n-data.js');
const BASELINE = process.argv[2] || null; // optional pre-change copy to diff against

let failures = 0;
function fail(msg) { failures++; console.log('  FAIL ' + msg); }
function ok(msg) { console.log('  ok   ' + msg); }

/**
 * Blanks out // and block comments, PRESERVING string literals verbatim and
 * PRESERVING TOTAL LENGTH (comment bytes become spaces). Length preservation
 * means indices computed on the stripped text are also valid against the
 * original text, which removes a whole class of off-by-N region bugs.
 */
function stripComments(src) {
  const out = src.split('');
  const blank = (from, to) => { for (let k = from; k < to && k < out.length; k++) if (out[k] !== '\n') out[k] = ' '; };
  let i = 0;
  while (i < src.length) {
    const ch = src[i], nx = src[i + 1];
    if (ch === '/' && nx === '/') {
      let j = i; while (j < src.length && src[j] !== '\n') j++;
      blank(i, j); i = j; continue;
    }
    if (ch === '/' && nx === '*') {
      let j = i + 2; while (j < src.length && !(src[j] === '*' && src[j + 1] === '/')) j++;
      const end = Math.min(j + 2, src.length);
      blank(i, end); i = end; continue;
    }
    if (ch === "'" || ch === '"' || ch === '`') {
      const q = ch; i++;
      while (i < src.length) {
        if (src[i] === '\\') { i += 2; continue; }
        if (src[i] === q) { i++; break; }
        i++;
      }
      continue;
    }
    i++;
  }
  return out.join('');
}

/**
 * Finds every `new Map<string, string>([ ... ])` body in file order.
 *
 * IMPORTANT: comment stripping changes the text length, so every index derived
 * from the stripped text MUST also be used against the stripped text. This
 * function therefore returns regions as {start,end} ranges into the STRIPPED
 * string, and callers must slice that same stripped string.
 */
function findMapRegions(stripped) {
  const regions = [];
  const re = /new\s+Map\s*<\s*string\s*,\s*string\s*>\s*\(\s*\[/g;
  let m;
  while ((m = re.exec(stripped))) {
    const bodyStart = m.index + m[0].length;
    const close = stripped.indexOf('])', bodyStart);
    if (close < 0) throw new Error('unterminated Map literal');
    regions.push({ start: bodyStart, end: close });
  }
  return regions;
}

/** Extracts pairs from a region of the STRIPPED source, evaluating literals with the JS engine. */
function pairsFromStripped(stripped, region) {
  const text = stripped.slice(region.start, region.end);
  const re = /\[\s*('(?:[^'\\]|\\.)*'|"(?:[^"\\]|\\.)*")\s*,\s*('(?:[^'\\]|\\.)*'|"(?:[^"\\]|\\.)*")\s*\]/g;
  const out = new Map();
  const dups = [];
  let m;
  while ((m = re.exec(text))) {
    /* eslint-disable no-eval */
    const key = eval(m[1]);
    const val = eval(m[2]);
    if (out.has(key)) dups.push(key);
    out.set(key, val);
  }
  return { map: out, dups };
}

/** Loads expected dictionaries. I18n.ets region 0 = zh, region 1 = en. */
function expected() {
  const i18nSrc = fs.readFileSync(path.join(COMMON, 'I18n.ets'), 'utf8');
  const i18n = stripComments(i18nSrc);
  const regions = findMapRegions(i18n);
  if (regions.length < 2) throw new Error('expected 2 Map literals in I18n.ets, found ' + regions.length);
  const zh = pairsFromStripped(i18n, regions[0]);
  const en = pairsFromStripped(i18n, regions[1]);

  const dicts = {};
  for (const [code, file] of [['ug', 'UyghurDict.ets'], ['bo', 'TibetanDict.ets'], ['mn', 'MongolianDict.ets']]) {
    const stripped = stripComments(fs.readFileSync(path.join(COMMON, file), 'utf8'));
    const regs = findMapRegions(stripped);
    if (!regs.length) throw new Error('no Map literal in ' + file);
    dicts[code] = pairsFromStripped(stripped, regs[0]);
  }

  return {
    zh: zh.map, en: en.map,
    ug: dicts.ug.map, bo: dicts.bo.map, mn: dicts.mn.map,
    dups: { zh: zh.dups, en: en.dups, ug: dicts.ug.dups, bo: dicts.bo.dups, mn: dicts.mn.dups },
  };
}

/** Reads the emitted target by executing it in a sandboxed window shim. */
function actual() {
  const text = fs.readFileSync(TARGET, 'utf8');
  if (!text.startsWith('/* Auto-generated from HarmonyOS dictionaries */')) {
    throw new Error('target is missing the Auto-generated header comment');
  }
  if (!/window\.I18N_DATA\s*=\s*\{/.test(text)) {
    throw new Error('target does not assign window.I18N_DATA as a plain object');
  }
  const window = {};
  // eslint-disable-next-line no-new-func
  new Function('window', text)(window);
  return { data: window.I18N_DATA, text };
}

console.log('Independent verification of Windows/renderer/js/i18n-data.js');
console.log('='.repeat(70));

const exp = expected();
const { data, text } = actual();

// ---- structural checks ----
console.log('\n[structure]');
const wantOrder = ['zh', 'en', 'ug', 'bo', 'mn'];
const gotOrder = Object.keys(data);
if (JSON.stringify(gotOrder) === JSON.stringify(wantOrder)) ok('language codes and order: ' + gotOrder.join(', '));
else fail('language order is ' + JSON.stringify(gotOrder) + ', expected ' + JSON.stringify(wantOrder));

if (text.trim().endsWith(';')) ok('file ends with ";" and is valid JS (executed successfully)');
else fail('file does not end with ";"');
if (text.length > 0) ok('target size ' + Buffer.byteLength(text, 'utf8') + ' bytes');

// JSON round-trip: proves the payload is pure JSON-compatible data
try {
  const round = JSON.parse(JSON.stringify(data));
  if (JSON.stringify(round) === JSON.stringify(data)) ok('payload is JSON-serializable and stable under round-trip');
  else fail('payload does not round-trip through JSON');
} catch (e) { fail('payload is not JSON-serializable: ' + e.message); }

// ---- per-language parity ----
console.log('\n[parity: every source key present with byte-identical value]');
const counts = {};
for (const code of wantOrder) {
  const src = exp[code];
  const tgt = data[code] || {};
  const missing = [];
  const differing = [];
  for (const [k, v] of src) {
    if (!Object.prototype.hasOwnProperty.call(tgt, k)) missing.push(k);
    else if (tgt[k] !== v) differing.push({ k, want: v, got: tgt[k] });
  }
  counts[code] = { source: src.size, emitted: Object.keys(tgt).length, missing: missing.length, differing: differing.length };
  const extra = Object.keys(tgt).filter((k) => !src.has(k));

  console.log(`  ${code}: source=${src.size} emitted=${Object.keys(tgt).length} missing=${missing.length} differing=${differing.length} extra=${extra.length}`);
  if (missing.length) { fail(`${code} missing ${missing.length}: ` + missing.slice(0, 12).join(', ')); }
  if (differing.length) {
    fail(`${code} differing ${differing.length}`);
    for (const d of differing.slice(0, 12)) {
      console.log(`       ${d.k}\n         want ${JSON.stringify(d.want)}\n         got  ${JSON.stringify(d.got)}`);
    }
  }
  if (extra.length) fail(`${code} has ${extra.length} key(s) not in source: ` + extra.slice(0, 12).join(', '));
  if (exp.dups[code] && exp.dups[code].length) fail(`${code} source has duplicate keys: ` + exp.dups[code].join(', '));
  if (!missing.length && !differing.length && !extra.length && !(exp.dups[code] || []).length) {
    ok(`${code} exact parity (${src.size} keys, zero mismatches)`);
  }
}

// ---- explicitly verify the 18 previously-missing keys ----
// Expectation: zh/en carry all 18. ug/bo/mn carry 12 (all watch.* and share.*)
// and deliberately omit the 6 dotted notify.* keys, for which I18n.t() falls
// back to zh; inventing translations for those is out of scope.
console.log('\n[the 18 previously-missing keys]');
const GAP = [
  'notify.done.title', 'notify.done.body.a', 'notify.done.body.b',
  'notify.fail.title', 'notify.fail.body.a', 'notify.fail.body.b',
  'watch.waitTitle', 'watch.waitHint', 'watch.received', 'watch.ready',
  'watch.start', 'watch.stageRunning', 'watch.overtime', 'watch.classEnd',
  'watch.stageCount', 'watch.again', 'share.bundleName', 'share.bundleDesc',
];
const EXPECT_IN = { zh: 18, en: 18, ug: 12, bo: 12, mn: 12 };
for (const code of wantOrder) {
  const inSource = GAP.filter((k) => exp[code].has(k));
  const inTarget = GAP.filter((k) => Object.prototype.hasOwnProperty.call(data[code] || {}, k));
  const want = EXPECT_IN[code];
  console.log(`  ${code}: in-source ${inSource.length}/18, in-target ${inTarget.length}/18 (expected ${want})`);
  if (inTarget.length < want) {
    const stillMissing = GAP.filter((k) => exp[code].has(k) && !(k in (data[code] || {})));
    fail(`${code} target is missing source keys: ` + stillMissing.join(', '));
  } else if (inTarget.length > want && code !== 'zh' && code !== 'en') {
    // extra invented translations for keys absent from the minority-language dict
    const invented = inTarget.filter((k) => !exp[code].has(k));
    fail(`${code} has ${invented.length} invented key(s) not in its own dictionary: ` + invented.join(', '));
  } else {
    ok(`${code} carries exactly its expected ${want} key(s) from the gap list`);
  }
}
// Every gap key that exists in a source dictionary must reach the target.
for (const code of wantOrder) {
  const lost = GAP.filter((k) => exp[code].has(k) && !(k in (data[code] || {})));
  if (!lost.length) ok(`${code}: no gap key present in source was dropped`);
}

// ---- escaping traps ----
console.log('\n[escaping traps]');
const waitHintZh = data.zh['watch.waitHint'];
console.log('  zh watch.waitHint decoded: ' + JSON.stringify(waitHintZh));
if (waitHintZh === '手机端点击\u201c流转\u201d\n并选择本手表') ok('zh watch.waitHint: curly quotes intact and \\n is a real newline');
else fail('zh watch.waitHint mismatch: ' + JSON.stringify(waitHintZh));

const waitHintEn = data.en['watch.waitHint'];
if (waitHintEn === 'Tap \u201cContinue\u201d on the phone\nand pick this watch') ok('en watch.waitHint matches source exactly');
else fail('en watch.waitHint mismatch: ' + JSON.stringify(waitHintEn));

// The emitted FILE must contain the two-character escape sequence \n, not a raw newline inside a string.
const rawWaitHint = /"watch\.waitHint":\s*"((?:[^"\\]|\\.)*)"/g;
let sawEscapedN = false;
let m2;
while ((m2 = rawWaitHint.exec(text))) {
  if (m2[1].includes('\\n')) sawEscapedN = true;
  if (m2[1].includes('\n')) fail('raw newline found inside emitted watch.waitHint string');
}
if (sawEscapedN) ok('emitted file encodes the newline as the escape sequence \\n (no raw newline in a JSON string)');

for (const code of wantOrder) {
  const s = data[code]['notify.done.body.a'];
  if (s !== undefined) {
    const want = code === 'zh' ? '「' : (code === 'en' ? '"' : null);
    if (want !== null && s !== want) fail(`${code} notify.done.body.a is ${JSON.stringify(s)}, expected ${JSON.stringify(want)}`);
  }
}
ok('notify.* body delimiter values checked for zh/en');

const md = { zh: '排\\座', en: 'Row\\Seat' };
for (const [code, want] of Object.entries(md)) {
  if (data[code]['seats.mdHeader'] !== want) fail(`${code} seats.mdHeader is ${JSON.stringify(data[code]['seats.mdHeader'])}, expected ${JSON.stringify(want)}`);
  else ok(`${code} seats.mdHeader keeps a literal backslash: ${JSON.stringify(want)}`);
}

const ap = data.en['greet.work.noon'];
if (ap === "Lunch first \u2014 a teacher's appetite deserves ritual too") ok('en \\u0027 decoded to an apostrophe correctly');
else fail('en greet.work.noon mismatch: ' + JSON.stringify(ap));

// ---- no dropped keys vs an optional baseline ----
if (BASELINE && fs.existsSync(BASELINE)) {
  console.log('\n[dropped-key diff vs baseline ' + BASELINE + ']');
  const bl = JSON.parse(/window\.I18N_DATA\s*=\s*(\{[\s\S]*\})\s*;\s*$/.exec(fs.readFileSync(BASELINE, 'utf8').trim())[1]);
  let dropped = 0;
  for (const code of Object.keys(bl)) {
    const lost = Object.keys(bl[code]).filter((k) => !(k in (data[code] || {})));
    if (lost.length) { dropped += lost.length; fail(`${code} dropped ${lost.length}: ` + lost.join(', ')); }
  }
  if (!dropped) ok('no key present in the baseline was dropped');
}

console.log('\n' + '='.repeat(70));
console.log('per-language: ' + wantOrder.map((c) => `${c}=${counts[c].emitted}`).join(' '));
console.log(failures === 0 ? 'RESULT: PASS (zero mismatches)' : `RESULT: FAIL (${failures} problem(s))`);
process.exit(failures === 0 ? 0 : 1);
