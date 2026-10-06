#!/usr/bin/env node
/**
 * gen_i18n_windows.js
 * ---------------------------------------------------------------------------
 * Regenerates the Electron/Windows i18n dictionary from the HarmonyOS source
 * of truth, so the Windows port stays in sync with the ArkTS app.
 *
 * Sources (never modified by this script):
 *   entry/src/main/ets/common/I18n.ets          -> zh, en
 *   entry/src/main/ets/common/UyghurDict.ets    -> ug
 *   entry/src/main/ets/common/TibetanDict.ets   -> bo
 *   entry/src/main/ets/common/MongolianDict.ets -> mn
 *
 * Target:
 *   Windows/renderer/js/i18n-data.js
 *
 * Usage:
 *   node tools/gen_i18n_windows.js            # generate
 *   node tools/gen_i18n_windows.js --check    # verify parity, do not write
 *   node tools/gen_i18n_windows.js --report   # also list target-only keys
 *
 * No external dependencies. Node >= 14.
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const COMMON = path.join(ROOT, 'entry', 'src', 'main', 'ets', 'common');
const TARGET = path.join(ROOT, 'Windows', 'renderer', 'js', 'i18n-data.js');

/** Language code -> description of where its dictionary lives. */
const LANGS = [
  { code: 'zh', file: 'I18n.ets', map: 'zh' },
  { code: 'en', file: 'I18n.ets', map: 'en' },
  { code: 'ug', file: 'UyghurDict.ets', map: 'dict' },
  { code: 'bo', file: 'TibetanDict.ets', map: 'dict' },
  { code: 'mn', file: 'MongolianDict.ets', map: 'dict' },
];

/* ------------------------------------------------------------------ *
 * Parsing
 * ------------------------------------------------------------------ */

/**
 * Decodes an ArkTS string literal body (already stripped of its surrounding
 * quotes) into the real JavaScript string.
 *
 * Handled escapes: \n \r \t \b \f \v \0 \\ \' \" \uXXXX \xXX, plus the
 * line-continuation form. Unknown escapes yield the escaped character itself,
 * matching how most toolchains are lenient here.
 */
function unescapeBody(body) {
  let out = '';
  for (let i = 0; i < body.length; i++) {
    const ch = body[i];
    if (ch !== '\\') {
      out += ch;
      continue;
    }
    const next = body[i + 1];
    if (next === undefined) {
      out += '\\';
      break;
    }
    switch (next) {
      case 'n': out += '\n'; i++; break;
      case 'r': out += '\r'; i++; break;
      case 't': out += '\t'; i++; break;
      case 'b': out += '\b'; i++; break;
      case 'f': out += '\f'; i++; break;
      case 'v': out += '\v'; i++; break;
      case '0': out += '\0'; i++; break;
      case '\\': out += '\\'; i++; break;
      case "'": out += "'"; i++; break;
      case '"': out += '"'; i++; break;
      case '`': out += '`'; i++; break;
      case '\n': i++; break; // line continuation
      case '\r': i++; if (body[i + 1] === '\n') i++; break;
      case 'u': {
        const hex = body.slice(i + 2, i + 6);
        if (/^[0-9a-fA-F]{4}$/.test(hex)) {
          out += String.fromCharCode(parseInt(hex, 16));
          i += 5;
        } else {
          out += next; i++;
        }
        break;
      }
      case 'x': {
        const hex = body.slice(i + 2, i + 4);
        if (/^[0-9a-fA-F]{2}$/.test(hex)) {
          out += String.fromCharCode(parseInt(hex, 16));
          i += 3;
        } else {
          out += next; i++;
        }
        break;
      }
      default:
        out += next; i++; break;
    }
  }
  return out;
}

/**
 * Reads the body of a single-quoted or double-quoted string literal starting
 * at `start` (the index of the opening quote). Returns { raw, end } where
 * `end` is the index just past the closing quote, or null when unterminated.
 */
function readStringLiteral(src, start) {
  const quote = src[start];
  let i = start + 1;
  let raw = '';
  while (i < src.length) {
    const ch = src[i];
    if (ch === '\\') {
      raw += ch;
      if (i + 1 < src.length) raw += src[i + 1];
      i += 2;
      continue;
    }
    if (ch === quote) return { raw, end: i + 1 };
    raw += ch;
    i++;
  }
  return null;
}

/** Removes // line comments and block comments while preserving string content. */
function stripComments(src) {
  let out = '';
  let i = 0;
  while (i < src.length) {
    const ch = src[i];
    const next = src[i + 1];
    if (ch === '/' && next === '/') {
      while (i < src.length && src[i] !== '\n') i++;
      continue;
    }
    if (ch === '/' && next === '*') {
      i += 2;
      while (i < src.length && !(src[i] === '*' && src[i + 1] === '/')) i++;
      i += 2;
      continue;
    }
    if (ch === "'" || ch === '"' || ch === '`') {
      const lit = readStringLiteral(src, i);
      if (lit) {
        out += src.slice(i, lit.end);
        i = lit.end;
        continue;
      }
    }
    out += ch;
    i++;
  }
  return out;
}

/**
 * Extracts pair entries of the form `['key', 'value']` from a source file.
 *
 * `anchorIndex` (optional) restricts extraction to the region starting at the
 * `new Map<string, string>([` declaration whose index is >= anchorIndex, which
 * is required for I18n.ets because it holds two maps in one file.
 *
 * `region` is the map body between the outermost `([` and its matching `])`.
 * Tolerance notes:
 *  - both single- and double-quoted keys/values are accepted (I18n.ets mixes
 *    them: `['splash.l2', "if only you'd known sooner."]`);
 *  - trailing commas are optional on the final entry;
 *  - the region stops at the `])` that closes the outermost array, so a `])`
 *    appearing inside a string value can never truncate it.
 */
function parseMapEntries(src, anchorIndex = 0) {
  const code = stripComments(src);
  const declRe = /new\s+Map\s*<\s*string\s*,\s*string\s*>\s*\(\s*\[/g;
  if (anchorIndex > 0) declRe.lastIndex = anchorIndex;

  const decl = declRe.exec(code);
  if (!decl) {
    throw new Error(
      `no \`new Map<string, string>([\` declaration found at or after index ${anchorIndex}`
    );
  }

  const bodyStart = decl.index + decl[0].length;
  const closeIdx = code.indexOf('])', bodyStart);
  if (closeIdx < 0) throw new Error('unterminated Map literal (no closing `])`)');
  const region = code.slice(bodyStart, closeIdx);

  const entries = [];
  let i = 0;
  while (i < region.length) {
    if (region[i] === '[') {
      let j = i + 1;
      while (j < region.length && /\s/.test(region[j])) j++;
      if (region[j] !== "'" && region[j] !== '"') { i++; continue; }
      const keyLit = readStringLiteral(region, j);
      if (!keyLit) { i++; continue; }
      let k = keyLit.end;
      while (k < region.length && /\s/.test(region[k])) k++;
      if (region[k] !== ',') { i++; continue; }
      k++;
      while (k < region.length && /\s/.test(region[k])) k++;
      if (region[k] !== "'" && region[k] !== '"') { i++; continue; }
      const valLit = readStringLiteral(region, k);
      if (!valLit) { i++; continue; }
      let m = valLit.end;
      while (m < region.length && /\s/.test(region[m])) m++;
      if (region[m] !== ']') { i++; continue; }

      entries.push({
        key: unescapeBody(keyLit.raw),
        value: unescapeBody(valLit.raw),
      });
      i = m + 1;
      continue;
    }
    i++;
  }

  return entries;
}

/** Loads every source dictionary and returns { zh: Map, en: Map, ... }. */
function collectSource(cache) {
  const byCode = {};
  for (const lang of LANGS) {
    const key = `${lang.file}::${lang.map}`;
    if (!cache.has(key)) {
      const filePath = path.join(COMMON, lang.file);
      if (!fs.existsSync(filePath)) {
        throw new Error(`missing HarmonyOS dictionary: ${filePath}`);
      }
      const src = fs.readFileSync(filePath, 'utf8');
      if (lang.map === 'zh' || lang.map === 'en') {
        // I18n.ets declares zh first, then en; anchor `en` past the zh map.
        let anchor = 0;
        if (lang.map === 'en') {
          const zhDecl = /new\s+Map\s*<\s*string\s*,\s*string\s*>\s*\(\s*\[/g.exec(stripComments(src));
          anchor = zhDecl ? zhDecl.index + 1 : 0;
        }
        cache.set(key, parseMapEntries(src, anchor));
      } else {
        cache.set(key, parseMapEntries(src));
      }
    }
    byCode[lang.code] = cache.get(key);
  }
  return byCode;
}

/** Detects duplicate keys, which would silently shadow an earlier value. */
function findDuplicates(entries) {
  const seen = new Map();
  const dups = [];
  for (const { key } of entries) {
    seen.set(key, (seen.get(key) || 0) + 1);
  }
  for (const [key, n] of seen) if (n > 1) dups.push({ key, count: n });
  return dups;
}

/** Reads the currently emitted target file, if present. */
function readTarget() {
  if (!fs.existsSync(TARGET)) return null;
  const text = fs.readFileSync(TARGET, 'utf8');
  const m = /window\.I18N_DATA\s*=\s*(\{[\s\S]*\})\s*;\s*$/.exec(text.trim());
  if (!m) return null;
  try {
    return JSON.parse(m[1]);
  } catch {
    return null;
  }
}

/* ------------------------------------------------------------------ *
 * Main
 * ------------------------------------------------------------------ */

function main() {
  const argv = process.argv.slice(2);
  const checkOnly = argv.includes('--check');
  const wantReport = argv.includes('--report') || checkOnly;

  const cache = new Map();
  const source = collectSource(cache);

  // ---- build the emitted object, preserving the existing language order ----
  const previous = readTarget();
  const order = previous ? Object.keys(previous) : LANGS.map((l) => l.code);
  for (const l of LANGS) if (!order.includes(l.code)) order.push(l.code);

  const data = {};
  const emittedCounts = {};
  for (const code of order) {
    const entries = source[code];
    if (!entries) continue;
    const obj = {};
    for (const { key, value } of entries) obj[key] = value;
    data[code] = obj;
    emittedCounts[code] = entries.length;
  }

  // ---- summary ----
  console.log('HarmonyOS i18n -> Windows i18n-data.js');
  console.log('-'.repeat(64));
  console.log('lang  source  emitted  previous  duplicates');
  for (const lang of LANGS) {
    const srcCount = source[lang.code].length;
    const dupCount = findDuplicates(source[lang.code]).length;
    const prevCount = previous && previous[lang.code]
      ? Object.keys(previous[lang.code]).length
      : 0;
    console.log(
      `${lang.code.padEnd(5)} ${String(srcCount).padStart(6)} ${String(emittedCounts[lang.code] ?? 0).padStart(8)} ${String(prevCount).padStart(9)} ${String(dupCount).padStart(11)}`
    );
  }
  console.log('-'.repeat(64));

  let duplicatesFound = false;
  for (const lang of LANGS) {
    const dups = findDuplicates(source[lang.code]);
    if (dups.length) {
      duplicatesFound = true;
      console.log(`duplicate keys in source ${lang.code} (${lang.file}):`);
      for (const d of dups) console.log(`  ${d.key} x${d.count}`);
    }
  }

  // ---- parity check against the raw source ----
  console.log('\nparity check (source -> emitted, identical values required):');
  let mismatches = 0;
  const coverage = {};
  for (const lang of LANGS) {
    const entries = source[lang.code];
    const obj = data[lang.code] || {};
    const missing = [];
    const differing = [];
    const dupConflicts = [];
    const firstValue = new Map();
    for (const { key, value } of entries) {
      if (firstValue.has(key)) {
        if (firstValue.get(key) !== value) {
          dupConflicts.push({ key, a: firstValue.get(key), b: value });
        }
        continue;
      }
      firstValue.set(key, value);
    }
    for (const [key, value] of firstValue) {
      if (!Object.prototype.hasOwnProperty.call(obj, key)) missing.push(key);
      else if (obj[key] !== value) differing.push(key);
    }
    mismatches += missing.length + differing.length + dupConflicts.length;
    coverage[lang.code] = firstValue.size;
    const status = missing.length || differing.length || dupConflicts.length ? 'FAIL' : 'OK';
    console.log(
      `  ${lang.code.padEnd(3)} ${status.padEnd(5)} source=${entries.length} unique=${firstValue.size} emitted=${Object.keys(obj).length}` +
      (missing.length ? ` missing=${missing.length}` : '') +
      (differing.length ? ` differing=${differing.length}` : '') +
      (dupConflicts.length ? ` dup-conflicts=${dupConflicts.length}` : '')
    );
    for (const k of missing.slice(0, 10)) console.log(`      missing: ${k}`);
    for (const k of differing.slice(0, 10)) {
      console.log(`      differing: ${k}\n        source : ${JSON.stringify(firstValue.get(k))}\n        emitted: ${JSON.stringify(obj[k])}`);
    }
    if (missing.length > 10) console.log(`      ... ${missing.length - 10} more missing`);
  }

  // ---- keys that exist only in the current Windows file ----
  const droppedKeys = {};
  if (previous) {
    for (const code of Object.keys(previous)) {
      const srcSet = new Set(source[code] ? source[code].map((e) => e.key) : []);
      const onlyInTarget = Object.keys(previous[code]).filter((k) => !srcSet.has(k));
      if (onlyInTarget.length) droppedKeys[code] = onlyInTarget;
    }
  }
  if (wantReport && Object.keys(droppedKeys).length) {
    console.log('\nkeys present in the existing Windows file but ABSENT from HarmonyOS');
    console.log('(they cannot be carried over; reported for the Lead to decide):');
    for (const code of Object.keys(droppedKeys)) {
      console.log(`  ${code} (${droppedKeys[code].length}): ${droppedKeys[code].join(', ')}`);
    }
  } else if (previous) {
    const total = Object.values(droppedKeys).reduce((n, a) => n + a.length, 0);
    console.log(`\nkeys in existing Windows file but absent from HarmonyOS: ${total}` +
      (total ? ' (rerun with --report to list)' : ''));
  }

  if (mismatches > 0) {
    console.error(`\nFAILED: ${mismatches} parity mismatch(es); target not written.`);
    process.exit(1);
  }
  if (duplicatesFound) {
    console.error('\nFAILED: duplicate keys in source dictionaries; target not written.');
    process.exit(1);
  }

  if (checkOnly) {
    console.log('\nparity OK (--check: no file written).');
    return;
  }

  // ---- emit ----
  const payload =
    '/* Auto-generated from HarmonyOS dictionaries */\n' +
    'window.I18N_DATA = ' +
    JSON.stringify(data, null, 2) +
    ';\n';
  fs.mkdirSync(path.dirname(TARGET), { recursive: true });
  const before = fs.existsSync(TARGET) ? fs.statSync(TARGET).size : 0;
  fs.writeFileSync(TARGET, payload, 'utf8');
  const after = fs.statSync(TARGET).size;
  console.log(`\nparity OK. wrote ${path.relative(ROOT, TARGET).replace(/\\/g, '/')}`);
  console.log(`  size ${before} -> ${after} bytes, total keys ${Object.values(emittedCounts).reduce((a, b) => a + b, 0)}`);
  console.log(`  coverage ${Object.entries(coverage).map(([k, v]) => `${k}=${v}`).join(' ')}`);
}

main();
