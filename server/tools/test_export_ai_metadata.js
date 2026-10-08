/**
 * 导出文件「AI 生成」元数据标识 —— 回归测试（真实产物级）
 *
 * ============================================================================
 * 【本脚本最重要的设计：不把实现抄一份】
 * ============================================================================
 * 本项目刚踩过这个坑（见 verify_talk_masking.js v1 的注释）：测试自带一份实现副本，
 * 于是"改了源码、测试输出逐字不变"，测试退化成恒真的死测试。
 *
 * 本脚本因此坚持**执行真源码**，而不是复刻：
 *   · Windows 侧是纯 JS（Electron renderer 模块），**直接 require 真实文件**：
 *       - renderer/js/ooxml-ai-metadata.js  → 元数据部件纯函数
 *       - renderer/js/office.js             → 完整 docx 打包链路（含 3 个注册点）
 *     用 Node + 真实 jszip 跑出**真实 .docx/.pptx 字节**，再解包逐项断言。
 *     改了实现 → 断言必然跟着变，不存在"抄一份副本"的脱钩空间。
 *
 *   · 鸿蒙侧是 ArkTS（无法在 Node 直接 require，含 @kit.* 与 .ets 语法），
 *     因此采用**从源码解析**（同 verify_talk_masking.js v2 的做法）：
 *       - 解析 I18n.ets 的 meta.ai.* 键值 → 断言中文标识真的在词典里；
 *       - 解析 OoxmlAiMetadata.ets 的注册点常量与 core.xml 模板 → 断言与
 *         Windows 侧逐字同构（跨端一致性，防止只改一端）。
 *     任一处解析失败**直接抛错退出**，绝不静默回退到硬编码期望值。
 *
 * ============================================================================
 * 覆盖（对应 task-8 验收点）
 * ============================================================================
 *   A. docx 真实产物解包：docProps/core.xml + app.xml 存在、含 AI 标识
 *   B. docx 三个注册点齐全：core.xml 部件 / app.xml 部件 / [Content_Types].xml Override
 *      / _rels/.rels Relationship（漏掉后两者 Word 会直接报文件损坏）
 *   C. XML 结构合法：标签名配平、命名空间声明存在、必须的 xsi:type="dcterms:W3CDTF"
 *   D. 反向断言：无 "PptxGenJS" 残留、无未替换占位符 {{...}} / ${...} / %s
 *   E. 时间戳为 W3CDTF UTC（形如 2026-10-08T12:34:56Z，无毫秒、以 Z 结尾）
 *   F. pptx 真实产物：骨架自带的 PptxGenJS 元数据被**覆盖**，其余部件不受损
 *   G. 跨端一致性：鸿蒙 I18n.ets 的 meta.ai.* 与 Windows i18n-data.js 中文段一致；
 *      两侧 OoxmlAiMetadata 常量与 core.xml 字段集同构
 *   H. 正文尾注「（AI生成，仅供参考）」仍在（元数据是**第二层**标识，不能替代它）
 *   I. 幂等 / 健壮性：重复加元数据不产生重复 Override；XML 特殊字符正确转义
 *
 * 运行：cd server && node tools/test_export_ai_metadata.js
 * 证据：真实产物写到 server/tools/out/（可复现，含 ZIP 条目清单与关键 XML）
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const WIN = path.join(ROOT, 'Windows');
const WIN_JS = path.join(WIN, 'renderer', 'js');
const OUT_DIR = path.join(__dirname, 'out');

const zipmini = require(path.join(__dirname, 'lib', 'zipmini.js'));

/* ---------------- 迷你断言框架（与项目其它测试同风格） ---------------- */
let pass = 0;
const failures = [];
function check(name, cond, detail) {
  if (cond) { pass++; return true; }
  failures.push(name + (detail ? ' :: ' + detail : ''));
  return false;
}
function section(t) { console.log('\n' + t); }

/* ============================================================================
 * 0. 载入真实实现（Windows 纯 JS 侧）
 * ==========================================================================*/
console.log('='.repeat(78));
console.log('导出文件「AI 生成」元数据标识 —— 真实产物级回归测试');
console.log('='.repeat(78));

const AIM_JS_PATH = path.join(WIN_JS, 'ooxml-ai-metadata.js');
const OFFICE_JS_PATH = path.join(WIN_JS, 'office.js');

check('renderer/js/ooxml-ai-metadata.js 存在', fs.existsSync(AIM_JS_PATH));
check('renderer/js/office.js 存在', fs.existsSync(OFFICE_JS_PATH));

const AIM = require(AIM_JS_PATH);

/* 真实 jszip：用 renderer 自带的 vendor 单文件版，即 Electron 运行时用的那一份 */
const JSZIP_SRC = fs.readFileSync(path.join(WIN_JS, 'vendor', 'jszip.min.js'), 'utf8');
const jszipSandbox = { window: {} };
new Function('window', 'setTimeout', 'clearTimeout', JSZIP_SRC)(jszipSandbox.window, setTimeout, clearTimeout);
const JSZip = jszipSandbox.window.JSZip;
check('renderer vendor JSZip 可用', typeof JSZip === 'function');

/* 真实 i18n 词典（与实际运行时同一份文件） */
const I18N_SRC = fs.readFileSync(path.join(WIN_JS, 'i18n-data.js'), 'utf8');
const i18nSandbox = { window: {} };
new Function('window', I18N_SRC)(i18nSandbox.window);
const I18N_DATA = i18nSandbox.window.I18N_DATA;
check('renderer/js/i18n-data.js 可解析出五语言词典',
  !!I18N_DATA && !!I18N_DATA.zh && !!I18N_DATA.en,
  Object.keys(I18N_DATA || {}).join(','));

/* office.js 是 IIFE，挂在 window 上；用 Function 提供 window/JSZip/require 运行它。
 * 注意：注入的 require 必须**按 office.js 所在目录解析**（Node 的 require 是相对
 * 调用方文件解析的，而这里调用方是测试脚本），故用 createRequire 固定基准目录。 */
const { createRequire } = require('module');
const winRequire = createRequire(path.join(WIN_JS, 'office.js'));

function loadOfficeModule() {
  const src = fs.readFileSync(OFFICE_JS_PATH, 'utf8');
  const sandbox = {
    window: {
      JSZip: JSZip,
      I18N_DATA: I18N_DATA,
      rtmI18n: {
        t: function (key) {
          const d = I18N_DATA.zh || {};
          return d[key] !== undefined ? d[key] : key;
        }
      }
    },
    console: console
  };
  sandbox.window.window = sandbox.window;
  new Function('window', 'console', 'require', src)(sandbox.window, console, winRequire);
  return sandbox.window.RTM_OFFICE;
}
const RTM_OFFICE = loadOfficeModule();
check('office.js 载入后导出 RTM_OFFICE', !!RTM_OFFICE);
check('office.js 暴露 docxFromMarkdown / pptxFromCourseware',
  !!(RTM_OFFICE && RTM_OFFICE.docxFromMarkdown && RTM_OFFICE.pptxFromCourseware));

/* ============================================================================
 * 1. 从鸿蒙 ArkTS 源码解析（不硬编码副本）
 * ==========================================================================*/
section('[1] 从鸿蒙 ArkTS 源码解析常量与词典（与实现绑定，拒绝副本）');

const I18N_ETS = path.join(ROOT, 'entry', 'src', 'main', 'ets', 'common', 'I18n.ets');
const AIM_ETS = path.join(ROOT, 'entry', 'src', 'main', 'ets', 'common', 'OoxmlAiMetadata.ets');
const DOCX_ETS = path.join(ROOT, 'entry', 'src', 'main', 'ets', 'common', 'DocxExporter.ets');
const PPTX_ETS = path.join(ROOT, 'entry', 'src', 'main', 'ets', 'common', 'PptxExporter.ets');

const i18nSrc = fs.readFileSync(I18N_ETS, 'utf8');
const aimEtsSrc = fs.readFileSync(AIM_ETS, 'utf8');
const docxEtsSrc = fs.readFileSync(DOCX_ETS, 'utf8');
const pptxEtsSrc = fs.readFileSync(PPTX_ETS, 'utf8');

/**
 * 解析 I18n.ets 中某个键在指定语言段里的文案。
 * zh 段 = `private static readonly zh` 到 `private static readonly en` 之间；
 * en 段 = `private static readonly en` 到 `private static readonly pick`（或文件末）。
 * 解析不到 → 抛错（不静默回退，静默退化正是死测试的病根）。
 */
function parseI18nKey(src, lang, key) {
  const startMark = 'private static readonly ' + lang + ': Map<string, string> = new Map<string, string>([';
  const si = src.indexOf(startMark);
  if (si < 0) throw new Error('I18n.ets 中找不到 ' + lang + ' 词典段');
  const nextZh = src.indexOf('private static readonly zh: Map<string, string>', si + startMark.length);
  const nextEn = src.indexOf('private static readonly en: Map<string, string>', si + startMark.length);
  let end = src.length;
  [nextZh, nextEn].forEach((n) => { if (n > si && n < end) end = n; });
  const seg = src.slice(si, end);
  const re = new RegExp("\\['" + key.replace(/\./g, '\\.') + "'\\s*,\\s*'((?:[^'\\\\]|\\\\.)*)'\\s*\\]");
  const m = seg.match(re);
  if (!m) throw new Error('I18n.ets 的 ' + lang + ' 词典里找不到键 ' + key);
  return m[1].replace(/\\'/g, "'").replace(/\\\\/g, '\\');
}

const META_KEYS = ['meta.ai.mark', 'meta.ai.creator', 'meta.ai.desc', 'meta.ai.app', 'meta.ai.keywords'];
const etaZh = {};
const etaEn = {};
try {
  META_KEYS.forEach((k) => { etaZh[k] = parseI18nKey(i18nSrc, 'zh', k); etaEn[k] = parseI18nKey(i18nSrc, 'en', k); });
} catch (e) {
  console.error('\n✗ ' + e.message);
  process.exit(1);
}
META_KEYS.forEach((k) => console.log('  ' + k + '\n      zh: ' + etaZh[k] + '\n      en: ' + etaEn[k]));

const AI_MARK_ZH = 'AI 生成，仅供参考';
check('I18n 新增键全部存在（zh/en 各 ' + META_KEYS.length + ' 个）',
  META_KEYS.every((k) => etaZh[k] && etaEn[k]));

/* —— 核心要求：中文标识必须稳定存在，界面切英文也不丢 —— */
check('zh 的 meta.ai.mark 含中文「' + AI_MARK_ZH + '」', etaZh['meta.ai.mark'].indexOf(AI_MARK_ZH) >= 0,
  '实得: ' + etaZh['meta.ai.mark']);
check('**en 的 meta.ai.mark 同样含中文**（元数据给外部接收方看，切英文也不丢中文）',
  etaEn['meta.ai.mark'].indexOf(AI_MARK_ZH) >= 0, '实得: ' + etaEn['meta.ai.mark']);
check('en 的 meta.ai.mark 同时含英文 AI-generated', /AI-generated/i.test(etaEn['meta.ai.mark']),
  '实得: ' + etaEn['meta.ai.mark']);
check('zh 的 meta.ai.creator 含「AI 生成」', etaZh['meta.ai.creator'].indexOf('AI 生成') >= 0,
  '实得: ' + etaZh['meta.ai.creator']);
check('en 的 meta.ai.creator 也含中文标识', etaEn['meta.ai.creator'].indexOf('AI 生成') >= 0,
  '实得: ' + etaEn['meta.ai.creator']);
/* 与项目既有责任机制一致：导出器不得另造一套文案 */
check('zh 的 meta.ai.mark 与既有 ai.note 同源措辞（「AI生成，仅供参考」）',
  etaZh['meta.ai.mark'].replace(/\s/g, '').indexOf('AI生成，仅供参考') >= 0,
  '实得: ' + etaZh['meta.ai.mark']);

/* —— 从 OoxmlAiMetadata.ets 解析注册点常量 —— */
function parseEtsConst(src, name) {
  const re = new RegExp("static\\s+readonly\\s+" + name + "\\s*:\\s*string\\s*=\\s*'([^']*)'");
  const m = src.match(re);
  if (!m) throw new Error('OoxmlAiMetadata.ets 中解析不到常量 ' + name);
  return m[1];
}
let etsConsts = {};
try {
  etsConsts = {
    CORE_PATH: parseEtsConst(aimEtsSrc, 'CORE_PATH'),
    APP_PATH: parseEtsConst(aimEtsSrc, 'APP_PATH'),
    CORE_CONTENT_TYPE: parseEtsConst(aimEtsSrc, 'CORE_CONTENT_TYPE'),
    APP_CONTENT_TYPE: parseEtsConst(aimEtsSrc, 'APP_CONTENT_TYPE'),
    CORE_REL_TYPE: parseEtsConst(aimEtsSrc, 'CORE_REL_TYPE'),
    APP_REL_TYPE: parseEtsConst(aimEtsSrc, 'APP_REL_TYPE')
  };
} catch (e) {
  console.error('\n✗ ' + e.message);
  process.exit(1);
}

check('鸿蒙/Windows 两侧 CORE_PATH 一致（' + etsConsts.CORE_PATH + '）', etsConsts.CORE_PATH === AIM.CORE_PATH);
check('鸿蒙/Windows 两侧 APP_PATH 一致（' + etsConsts.APP_PATH + '）', etsConsts.APP_PATH === AIM.APP_PATH);
check('鸿蒙/Windows 两侧 CORE_CONTENT_TYPE 一致', etsConsts.CORE_CONTENT_TYPE === AIM.CORE_CONTENT_TYPE);
check('鸿蒙/Windows 两侧 APP_CONTENT_TYPE 一致', etsConsts.APP_CONTENT_TYPE === AIM.APP_CONTENT_TYPE);
check('鸿蒙/Windows 两侧 CORE_REL_TYPE 一致', etsConsts.CORE_REL_TYPE === AIM.CORE_REL_TYPE);
check('鸿蒙/Windows 两侧 APP_REL_TYPE 一致', etsConsts.APP_REL_TYPE === AIM.APP_REL_TYPE);

/* —— 源码事实核对：三个注册点必须都改建包逻辑 —— */
section('[2] 源码事实核对：docx 三个注册点必须同时改');

check('DocxExporter.ets 写入了 docProps/core.xml 部件',
  /OoxmlAiMetadata\.CORE_PATH/.test(docxEtsSrc) && /zip\.file\(/.test(docxEtsSrc));
check('DocxExporter.ets 写入了 docProps/app.xml 部件', /OoxmlAiMetadata\.APP_PATH/.test(docxEtsSrc));
check('DocxExporter.ets 在 [Content_Types].xml 注入了 Override',
  /contentTypeOverrides\(\)/.test(docxEtsSrc), '缺少注册点②会导致 Word 报文件损坏');
check('DocxExporter.ets 在 _rels/.rels 注入了 Relationship',
  /relationshipXml\(/.test(docxEtsSrc), '缺少注册点③会导致 Word 报文件损坏');
check('DocxExporter.ets 的元数据文案走 I18n（未硬编码中文）',
  /I18n\.t\('meta\.ai\./.test(docxEtsSrc) && !/creator:\s*'[^']*AI 生成/.test(docxEtsSrc));
check('PptxExporter.ets 覆盖了 core.xml 部件', /OoxmlAiMetadata\.CORE_PATH/.test(pptxEtsSrc));
check('PptxExporter.ets 覆盖了 app.xml 部件', /OoxmlAiMetadata\.APP_PATH/.test(pptxEtsSrc));
check('PptxExporter.ets 元数据文案走 I18n', /I18n\.t\('meta\.ai\./.test(pptxEtsSrc));
check('PptxExporter.ets 未重复注册 docProps（模板已注册，重复会产生非法重复 Override）',
  !/contentTypeOverrides\(\)/.test(pptxEtsSrc));
check('OoxmlAiMetadata.ets 是纯函数（无 UI / 无文件选择器 / 无 IO）',
  !/@kit\.CoreFileKit|picker|promptAction|fs\./.test(aimEtsSrc));

/* —— 正文尾注不能被删掉（元数据是第二层标识，两者都要） —— */
section('[3] 原有正文尾注「（AI生成，仅供参考）」必须仍在');

const AI_SVC = fs.readFileSync(path.join(ROOT, 'entry', 'src', 'main', 'ets', 'common', 'AiService.ets'), 'utf8');
check('AiService.withAiNote 仍用 I18n.t(\'ai.note\') 追加正文尾注', /I18n\.t\('ai\.note'\)/.test(AI_SVC));
check('I18n.ets 仍保留 ai.note 键（zh）', /'ai\.note'\s*,\s*'（AI生成，仅供参考）'/.test(i18nSrc));
check('Windows i18n-data.js 仍保留 ai.note 键（zh）',
  I18N_DATA.zh['ai.note'] === '（AI生成，仅供参考）', '实得: ' + I18N_DATA.zh['ai.note']);

/* ============================================================================
 * 4. 真实产物：生成真正的 .docx
 * ==========================================================================*/
section('[4] 真实产物：用真实 office.js + 真实 jszip 生成 .docx 并解包');

if (!fs.existsSync(OUT_DIR)) fs.mkdirSync(OUT_DIR, { recursive: true });

const DOCX_MD = [
  '# 八年级物理《浮力》教案',
  '',
  '**教学目标**：理解阿基米德原理，能进行简单计算。',
  '',
  '- 知道浮力的方向是竖直向上',
  '- 会用 `F=ρgV` 计算浮力',
  '',
  '| 环节 | 时长 |',
  '| --- | --- |',
  '| 导入 | 5min |',
  '',
  '（AI生成，仅供参考）'
].join('\n');

function assertXmlBalanced(xml) {
  // 简易标签配平：忽略声明/注释/CDATA，自闭合与空元素不参与配对
  const stack = [];
  const stripped = xml.replace(/<\?[\s\S]*?\?>/g, '').replace(/<!--[\s\S]*?-->/g, '').replace(/<!\[CDATA\[[\s\S]*?\]\]>/g, '');
  const re = /<(\/?)([A-Za-z_][\w.:-]*)((?:"[^"]*"|'[^']*'|[^>"'])*?)(\/?)>/g;
  let m;
  while ((m = re.exec(stripped)) !== null) {
    const closing = m[1] === '/';
    const name = m[2];
    const selfClose = m[4] === '/';
    if (closing) {
      const top = stack.pop();
      if (top !== name) return '期望 </' + top + '> 但遇到 </' + name + '>（位置 ' + m.index + '）';
    } else if (!selfClose) {
      stack.push(name);
    }
  }
  if (stack.length > 0) return '未闭合标签: ' + stack.join(' > ');
  return null;
}

function dumpEvidence(label, entries) {
  const lines = ['# ' + label, ''];
  entries.forEach((e) => lines.push('- ' + e.name + '  (method=' + e.method + ', ' + e.uncompressedSize + ' bytes)'));
  return lines.join('\n');
}

const evidence = [];
let docxBuf = null;
let docxEntries = null;

(async () => {
  const docxResult = await RTM_OFFICE.docxFromMarkdown(DOCX_MD, '八年级物理浮力教案');
  check('docxFromMarkdown 返回 {name, data}', !!(docxResult && docxResult.name && docxResult.data));
  check('docx 文件名正确（.docx 后缀）', /\.docx$/.test(docxResult.name), docxResult.name);

  docxBuf = Buffer.from(docxResult.data);
  fs.writeFileSync(path.join(OUT_DIR, 'ai-metadata-real.docx'), docxBuf);
  console.log('  已写出真实产物: server/tools/out/ai-metadata-real.docx (' + docxBuf.length + ' bytes)');

  docxEntries = zipmini.readZip(docxBuf);
  console.log('\n  ZIP 条目清单：');
  docxEntries.forEach((e) => console.log('    · ' + e.name + '  (' + e.uncompressedSize + ' bytes, method=' + e.method + ')'));
  evidence.push(dumpEvidence('docx ZIP 条目清单', docxEntries));

  const names = docxEntries.map((e) => e.name);
  check('docx 解包后存在 docProps/core.xml', names.indexOf('docProps/core.xml') >= 0, names.join(', '));
  check('docx 解包后存在 docProps/app.xml', names.indexOf('docProps/app.xml') >= 0, names.join(', '));
  check('docx 仍含 word/document.xml（正文未损坏）', names.indexOf('word/document.xml') >= 0);
  check('docx 仍含 [Content_Types].xml 与 _rels/.rels',
    names.indexOf('[Content_Types].xml') >= 0 && names.indexOf('_rels/.rels') >= 0);

  /* —— CRC 校验：证明是真字节、真能解包 —— */
  let crcAllOk = true;
  docxEntries.forEach((e) => {
    try { e.read(); } catch (err) { crcAllOk = false; console.log('    ! ' + e.name + ': ' + err.message); }
  });
  check('docx 全部条目 CRC-32 校验通过（真实可解包，非伪造字节）', crcAllOk);

  const docxCore = zipmini.findEntry(docxEntries, 'docProps/core.xml').read().toString('utf8');
  const docxApp = zipmini.findEntry(docxEntries, 'docProps/app.xml').read().toString('utf8');
  const docxCt = zipmini.findEntry(docxEntries, '[Content_Types].xml').read().toString('utf8');
  const docxRels = zipmini.findEntry(docxEntries, '_rels/.rels').read().toString('utf8');
  fs.writeFileSync(path.join(OUT_DIR, 'docx-docProps-core.xml'), docxCore);
  fs.writeFileSync(path.join(OUT_DIR, 'docx-docProps-app.xml'), docxApp);
  fs.writeFileSync(path.join(OUT_DIR, 'docx-Content_Types.xml'), docxCt);
  fs.writeFileSync(path.join(OUT_DIR, 'docx-rels.rels'), docxRels);

  /* —— A. AI 标识内容 —— */
  section('[5] docx docProps 内容断言');
  console.log('\n  ---- docProps/core.xml ----\n' + docxCore + '\n');
  console.log('  ---- docProps/app.xml ----\n' + docxApp + '\n');

  check('core.xml 含 dc:creator', /<dc:creator>/.test(docxCore));
  check('core.xml 含「AI 生成」标识', docxCore.indexOf('AI 生成') >= 0);
  check('core.xml 的 dc:creator 含「AI 生成」',
    /<dc:creator>[^<]*AI 生成[^<]*<\/dc:creator>/.test(docxCore));
  check('core.xml 的 cp:lastModifiedBy 含「AI 生成」',
    /<cp:lastModifiedBy>[^<]*AI 生成[^<]*<\/cp:lastModifiedBy>/.test(docxCore));
  check('core.xml 的 dc:description 含 AI 生成说明',
    /<dc:description>[^<]*AI 生成[^<]*<\/dc:description>/.test(docxCore));
  check('core.xml 的 dc:title 取自导出文件名', docxCore.indexOf('八年级物理浮力教案') >= 0,
    '实得 title: ' + (docxCore.match(/<dc:title>([^<]*)<\/dc:title>/) || [])[1]);
  check('core.xml 含 cp:revision', /<cp:revision>\s*1\s*<\/cp:revision>/.test(docxCore));
  check('app.xml 含 <Application>', /<Application>[^<]+<\/Application>/.test(docxApp));
  check('app.xml 含 AI 生成标识', docxApp.indexOf('AI 生成') >= 0);
  check('app.xml 的 <Company> 含 AI 生成标识',
    /<Company>[^<]*AI 生成[^<]*<\/Company>/.test(docxApp));

  /* —— 时间戳 W3CDTF UTC —— */
  section('[6] 时间戳必须是 W3CDTF UTC');
  const created = (docxCore.match(/<dcterms:created[^>]*>([^<]*)<\/dcterms:created>/) || [])[1];
  const modified = (docxCore.match(/<dcterms:modified[^>]*>([^<]*)<\/dcterms:modified>/) || [])[1];
  const W3C = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/;
  console.log('  dcterms:created  = ' + created);
  console.log('  dcterms:modified = ' + modified);
  check('dcterms:created 是 W3CDTF UTC（YYYY-MM-DDThh:mm:ssZ，无毫秒）', W3C.test(created || ''), created);
  check('dcterms:modified 是 W3CDTF UTC', W3C.test(modified || ''), modified);
  check('created/modified 数值合法（Date.parse 可解析且与写入时刻同分钟）',
    !isNaN(Date.parse(created)) && Math.abs(Date.parse(created) - Date.now()) < 10 * 60 * 1000,
    created);
  check('两个时间戳都带 xsi:type="dcterms:W3CDTF"',
    /<dcterms:created xsi:type="dcterms:W3CDTF">/.test(docxCore) &&
    /<dcterms:modified xsi:type="dcterms:W3CDTF">/.test(docxCore));
  check('w3cdtf() 对固定时刻逐字可预测',
    AIM.w3cdtf(new Date(Date.UTC(2026, 9, 8, 12, 34, 56))) === '2026-10-08T12:34:56Z',
    AIM.w3cdtf(new Date(Date.UTC(2026, 9, 8, 12, 34, 56))));

  /* —— B. 三个注册点 —— */
  section('[7] docx 三个注册点（漏一个 Word 就报文件损坏）');

  check('注册点①：docProps/core.xml 部件已写入包内', names.indexOf('docProps/core.xml') >= 0);
  check('注册点①：docProps/app.xml 部件已写入包内', names.indexOf('docProps/app.xml') >= 0);

  check('[Content_Types].xml 有 core.xml 的 Override（内容类型正确）',
    docxCt.indexOf('PartName="/docProps/core.xml"') >= 0 &&
    docxCt.indexOf('application/vnd.openxmlformats-package.core-properties+xml') >= 0);
  check('[Content_Types].xml 有 app.xml 的 Override（内容类型正确）',
    docxCt.indexOf('PartName="/docProps/app.xml"') >= 0 &&
    docxCt.indexOf('application/vnd.openxmlformats-officedocument.extended-properties+xml') >= 0);
  check('[Content_Types].xml 每个 PartName 只出现一次（无非法重复 Override）',
    docxCt.split('PartName="/docProps/').length - 1 === 2,
    '[Content_Types].xml: ' + docxCt);
  check('docProps 的 Override 写在 </Types> 之前（未落在根元素外）',
    docxCt.indexOf('/docProps/core.xml') < docxCt.indexOf('</Types>'));

  check('_rels/.rels 有指向 docProps/core.xml 的 Relationship',
    /<Relationship[^>]*Type="[^"]*core-properties"[^>]*Target="docProps\/core\.xml"[^>]*\/>/.test(docxRels));
  check('_rels/.rels 有指向 docProps/app.xml 的 Relationship',
    /<Relationship[^>]*Type="[^"]*extended-properties"[^>]*Target="docProps\/app\.xml"[^>]*\/>/.test(docxRels));
  check('_rels/.rels 仍保留 officeDocument 关系（正文入口未丢）',
    /officeDocument[^>]*Target="word\/document\.xml"/.test(docxRels));
  check('_rels/.rels 的 Relationship Id 互不重复',
    (() => {
      const ids = (docxRels.match(/Relationship Id="([^"]+)"/g) || []).map((s) => s.replace(/.*"([^"]+)".*/, '$1'));
      return ids.length === new Set(ids).size && ids.length >= 3;
    })(), docxRels);
  check('docx 包级关系 Id 与实现常量一致（rId4/rId5，不撞 rId1）',
    /Relationship Id="rId4"/.test(docxRels) && /Relationship Id="rId5"/.test(docxRels));

  /* —— C. XML 结构合法 —— */
  section('[8] XML 结构合法性（标签配平 + 命名空间）');
  const xmlTargets = [
    ['docProps/core.xml', docxCore], ['docProps/app.xml', docxApp],
    ['[Content_Types].xml', docxCt], ['_rels/.rels', docxRels],
    ['word/document.xml', zipmini.findEntry(docxEntries, 'word/document.xml').read().toString('utf8')]
  ];
  xmlTargets.forEach(([nm, xml]) => {
    const err = assertXmlBalanced(xml);
    check(nm + ' 标签配平', err === null, err || '');
    check(nm + ' 有 XML 声明', /^<\?xml version="1\.0" encoding="UTF-8" standalone="yes"\?>/.test(xml));
  });
  check('core.xml 声明了 cp/dc/dcterms/dcmitype/xsi 五个命名空间',
    ['xmlns:cp=', 'xmlns:dc=', 'xmlns:dcterms=', 'xmlns:dcmitype=', 'xmlns:xsi=']
      .every((ns) => docxCore.indexOf(ns) >= 0));

  /* —— D. 反向断言 —— */
  section('[9] 反向断言：无残留、无未替换占位符');
  const allDocxXml = docxCore + docxApp + docxCt + docxRels;
  check('docx 元数据中不含 "PptxGenJS"', allDocxXml.indexOf('PptxGenJS') < 0);
  check('docx 元数据中不含未替换占位符 {{...}}', !/\{\{[^}]*\}\}/.test(allDocxXml));
  check('docx 元数据中不含未替换占位符 ${...}', !/\$\{[^}]*\}/.test(allDocxXml));
  check('docx 元数据中不含 printf 占位符 %s / {0}',
    !/%s|%d|\{0\}|\{n\}/.test(allDocxXml.replace(/\{n\}/g, '')), allDocxXml);
  check('docx 元数据中不含未转义的裸 & / <（转义正确性）',
    !/&(?!amp;|lt;|gt;|quot;|apos;|#)/.test(allDocxXml));
  check('docx 元数据中不含 I18n 键名原文（如 meta.ai.mark 泄漏）',
    allDocxXml.indexOf('meta.ai.') < 0, '说明 I18n.t 未命中而回退成了键名');
  check('app.xml 不含绝对路径泄漏（C:\\ 或 /Users/）',
    !/[A-Za-z]:\\|\/Users\//.test(docxApp));

  /* —— XML 特殊字符转义 ——
   * 说明：导出文件名先经 sanitizeName 清洗（Windows 文件名不允许 < > " 等字符，
   * 会被替换成 _），因此真正需要验证的是「清洗后仍可能出现的 XML 敏感字符」
   * 在写入 XML 时被正确转义。这里直接对纯函数喂入含全部敏感字符的字段，
   * 绕开文件名清洗，才能测到转义本身。 */
  section('[10] XML 特殊字符转义（字段含 & < " \' 时必须安全）');
  const NASTY = 'A&B <C> "D" \'E\'';
  const nastyCore = AIM.coreXml({
    title: NASTY, creator: NASTY, lastModifiedBy: NASTY, description: NASTY,
    subject: NASTY, appName: NASTY, company: NASTY, keywords: NASTY
  }, new Date(Date.UTC(2026, 9, 8, 12, 34, 56)));
  const nastyApp = AIM.appXml({ title: NASTY, creator: NASTY, lastModifiedBy: NASTY, description: NASTY, subject: NASTY, appName: NASTY, company: NASTY, keywords: NASTY });
  check('core.xml 中的 & < > " \' 全部被转义',
    nastyCore.indexOf('A&amp;B &lt;C&gt; &quot;D&quot; &apos;E&apos;') >= 0,
    (nastyCore.match(/<dc:title>([\s\S]*?)<\/dc:title>/) || [])[1]);
  check('core.xml 转义后不含裸 & （除实体引用外）',
    !/&(?!amp;|lt;|gt;|quot;|apos;|#)/.test(nastyCore));
  check('core.xml 转义后仍标签配平', assertXmlBalanced(nastyCore) === null, assertXmlBalanced(nastyCore) || '');
  check('app.xml 中的 & < > 全部被转义', nastyApp.indexOf('A&amp;B &lt;C&gt; &quot;D&quot;') >= 0);
  check('app.xml 转义后仍标签配平', assertXmlBalanced(nastyApp) === null, assertXmlBalanced(nastyApp) || '');

  /* 真实链路：文件名含 & 时不得把包弄坏 */
  const ampDocx = await RTM_OFFICE.docxFromMarkdown('# t', '教案&报告');
  const ampEntries = zipmini.readZip(Buffer.from(ampDocx.data));
  const ampCore = zipmini.findEntry(ampEntries, 'docProps/core.xml').read().toString('utf8');
  check('真实链路：文件名含 & 时 core.xml 仍合法且已转义',
    assertXmlBalanced(ampCore) === null && ampCore.indexOf('教案&amp;报告') >= 0,
    (ampCore.match(/<dc:title>([\s\S]*?)<\/dc:title>/) || [])[1]);
  const nastyNameDocx = await RTM_OFFICE.docxFromMarkdown('# t', 'A&B <C> "D"');
  const nnCore = zipmini.findEntry(zipmini.readZip(Buffer.from(nastyNameDocx.data)), 'docProps/core.xml')
    .read().toString('utf8');
  check('真实链路：文件名含 <> " 时被清洗且 XML 仍合法',
    assertXmlBalanced(nnCore) === null && nnCore.indexOf('&amp;B') >= 0 && nnCore.indexOf('&lt;') < 0,
    (nnCore.match(/<dc:title>([\s\S]*?)<\/dc:title>/) || [])[1]);

  /* —— I. 幂等 —— */
  section('[11] 幂等性：重复调用不产生重复注册');
  {
    const z = new JSZip();
    z.file('[Content_Types].xml', '<?xml version="1.0"?><Types></Types>');
    z.file('_rels/.rels', '<?xml version="1.0"?><Relationships></Relationships>');
    await RTM_OFFICE._internals.addAiMetadata(z, 'rId4', 'rId5', 'x');
    await RTM_OFFICE._internals.addAiMetadata(z, 'rId4', 'rId5', 'x');
    const ct2 = await z.file('[Content_Types].xml').async('string');
    const rl2 = await z.file('_rels/.rels').async('string');
    check('重复加元数据：Override 不重复', ct2.split('PartName="/docProps/').length - 1 === 2, ct2);
    check('重复加元数据：Relationship 不重复', rl2.split('Target="docProps/').length - 1 === 2, rl2);
  }

  /* ============================================================================
   * 5. 真实产物：pptx（骨架里 PptxGenJS 元数据必须被覆盖）
   * ==========================================================================*/
  section('[12] 真实产物：.pptx 骨架的 PptxGenJS 元数据必须被覆盖');

  const SKEL = path.join(ROOT, 'entry', 'src', 'main', 'resources', 'rawfile', 'pptskel.pptx');
  const skelBuf = fs.readFileSync(SKEL);
  const skelEntries = zipmini.readZip(skelBuf);
  const skelNames = skelEntries.map((e) => e.name);
  check('骨架 pptskel.pptx 自带 docProps/core.xml（这是要覆盖的对象）', skelNames.indexOf('docProps/core.xml') >= 0);

  const skelCore = zipmini.findEntry(skelEntries, 'docProps/core.xml').read().toString('utf8');
  check('（前置事实）骨架 core.xml 确实含误导性的 "PptxGenJS"',
    skelCore.indexOf('PptxGenJS') >= 0, '骨架已不含 PptxGenJS，前置条件变了');

  /* 用真实骨架 + 真实 office.js 的 pptx 链路（stub 掉 rtmNative.skeleton） */
  const pptxJson = JSON.stringify({
    title: '七年级生物《细胞的结构》课件',
    pages: [
      { title: '导入：显微镜下的世界', points: ['细胞是生命活动的基本单位', '观察洋葱表皮细胞'] },
      { title: '讲解：细胞壁与细胞膜', points: ['细胞壁起支持作用', '细胞膜控制物质进出'] }
    ]
  });

  let pptxBuf = null;
  {
    const src = fs.readFileSync(OFFICE_JS_PATH, 'utf8');
    const sandbox = {
      window: {
        JSZip: JSZip,
        I18N_DATA: I18N_DATA,
        rtmI18n: { t: (k) => (I18N_DATA.zh[k] !== undefined ? I18N_DATA.zh[k] : k) },
        rtmNative: { skeleton: () => Promise.resolve(skelBuf) }
      },
      console: console
    };
    sandbox.window.window = sandbox.window;
    new Function('window', 'console', 'require', src)(sandbox.window, console, winRequire);
    const office2 = sandbox.window.RTM_OFFICE;
    const r = await office2.pptxFromCourseware(pptxJson, '七年级生物细胞的结构课件');
    pptxBuf = Buffer.from(r.data);
    check('pptx 文件名正确（.pptx 后缀）', /\.pptx$/.test(r.name), r.name);
  }
  fs.writeFileSync(path.join(OUT_DIR, 'ai-metadata-real.pptx'), pptxBuf);
  console.log('  已写出真实产物: server/tools/out/ai-metadata-real.pptx (' + pptxBuf.length + ' bytes)');

  const pptxEntries = zipmini.readZip(pptxBuf);
  const pptxNames = pptxEntries.map((e) => e.name);
  console.log('\n  ZIP 条目清单（' + pptxEntries.length + ' 项）：');
  pptxEntries.forEach((e) => console.log('    · ' + e.name));
  evidence.push(dumpEvidence('pptx ZIP 条目清单', pptxEntries));

  let pptxCrcOk = true;
  pptxEntries.forEach((e) => { try { e.read(); } catch (err) { pptxCrcOk = false; console.log('    ! ' + e.name + ': ' + err.message); } });
  check('pptx 全部条目 CRC-32 校验通过', pptxCrcOk);

  const pptxCore = zipmini.findEntry(pptxEntries, 'docProps/core.xml').read().toString('utf8');
  const pptxApp = zipmini.findEntry(pptxEntries, 'docProps/app.xml').read().toString('utf8');
  const pptxCt = zipmini.findEntry(pptxEntries, '[Content_Types].xml').read().toString('utf8');
  const pptxRels = zipmini.findEntry(pptxEntries, '_rels/.rels').read().toString('utf8');
  fs.writeFileSync(path.join(OUT_DIR, 'pptx-docProps-core.xml'), pptxCore);
  fs.writeFileSync(path.join(OUT_DIR, 'pptx-docProps-app.xml'), pptxApp);

  console.log('\n  ---- pptx docProps/core.xml（覆盖后） ----\n' + pptxCore + '\n');

  check('pptx core.xml 的 dc:creator **不再是** "PptxGenJS"',
    !/<dc:creator>PptxGenJS<\/dc:creator>/.test(pptxCore));
  check('pptx core.xml 整体不含 "PptxGenJS"', pptxCore.indexOf('PptxGenJS') < 0,
    (pptxCore.match(/[^<>]*PptxGenJS[^<>]*/g) || []).join(' | '));
  check('pptx core.xml 的 dc:title **不再是** "PptxGenJS Presentation"',
    pptxCore.indexOf('PptxGenJS Presentation') < 0);
  check('pptx core.xml 的 dc:subject **不再是** "PptxGenJS Presentation"',
    !/<dc:subject>PptxGenJS Presentation<\/dc:subject>/.test(pptxCore));
  check('pptx core.xml 的 dc:creator 含「AI 生成」',
    /<dc:creator>[^<]*AI 生成[^<]*<\/dc:creator>/.test(pptxCore));
  check('pptx core.xml 的 cp:lastModifiedBy 含「AI 生成」',
    /<cp:lastModifiedBy>[^<]*AI 生成[^<]*<\/cp:lastModifiedBy>/.test(pptxCore));
  check('pptx core.xml 的 dc:title 取自导出文件名', pptxCore.indexOf('七年级生物细胞的结构课件') >= 0);
  check('pptx core.xml 时间戳为 W3CDTF UTC',
    /<dcterms:created xsi:type="dcterms:W3CDTF">\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z<\/dcterms:created>/.test(pptxCore));
  check('pptx app.xml 不含 PptxGenJS 残留', pptxApp.indexOf('PptxGenJS') < 0,
    (pptxApp.match(/[^<>]*PptxGenJS[^<>]*/g) || []).join(' | '));
  check('pptx app.xml 的 <Company> 已改为 AI 生成标识',
    /<Company>[^<]*AI 生成[^<]*<\/Company>/.test(pptxApp),
    (pptxApp.match(/<Company>([^<]*)<\/Company>/) || [])[1]);

  /* pptx 整包不得再有 PptxGenJS 文本（骨架里 ppt 部件也不该有） */
  let pptxAnyPptxGenJS = [];
  pptxEntries.forEach((e) => {
    if (/\.xml$|\.rels$/.test(e.name)) {
      const t = e.read().toString('utf8');
      if (t.indexOf('PptxGenJS') >= 0) pptxAnyPptxGenJS.push(e.name);
    }
  });
  check('pptx 全包所有 XML 部件均无 "PptxGenJS" 残留', pptxAnyPptxGenJS.length === 0,
    pptxAnyPptxGenJS.join(', '));

  check('pptx 仍含 ppt/presentation.xml / [Content_Types].xml / _rels/.rels（包结构未坏）',
    pptxNames.indexOf('ppt/presentation.xml') >= 0 && pptxNames.indexOf('[Content_Types].xml') >= 0 &&
    pptxNames.indexOf('_rels/.rels') >= 0);
  check('pptx 模板部件数量未因加元数据而减少',
    pptxNames.length >= skelNames.length, '骨架 ' + skelNames.length + ' → 产物 ' + pptxNames.length);
  check('pptx [Content_Types].xml 每个 PartName 唯一（覆盖未造成重复 Override）',
    (() => {
      const pns = (pptxCt.match(/PartName="([^"]+)"/g) || []);
      return pns.length === new Set(pns).size;
    })());
  check('pptx [Content_Types].xml 仍注册 docProps 两个部件',
    pptxCt.indexOf('PartName="/docProps/core.xml"') >= 0 && pptxCt.indexOf('PartName="/docProps/app.xml"') >= 0);
  check('pptx _rels/.rels 仍指向 docProps/core.xml 与 ppt/presentation.xml',
    /Target="docProps\/core\.xml"/.test(pptxRels) && /Target="ppt\/presentation\.xml"/.test(pptxRels));
  check('pptx _rels/.rels 的 Relationship Id 互不重复',
    (() => {
      const ids = (pptxRels.match(/Relationship Id="([^"]+)"/g) || []).map((s) => s.replace(/.*"([^"]+)".*/, '$1'));
      return ids.length === new Set(ids).size;
    })(), pptxRels);
  ['docProps/core.xml', 'docProps/app.xml', '[Content_Types].xml', '_rels/.rels'].forEach((nm) => {
    const xml = zipmini.findEntry(pptxEntries, nm).read().toString('utf8');
    const err = assertXmlBalanced(xml);
    check('pptx ' + nm + ' 标签配平', err === null, err || '');
  });
  const pptxAll = pptxCore + pptxApp + pptxCt + pptxRels;
  check('pptx 元数据中不含未替换占位符', !/\{\{|\$\{|%s/.test(pptxAll));

  /* ============================================================================
   * 6. 跨端一致性
   * ==========================================================================*/
  section('[13] 跨端一致性：鸿蒙 I18n.ets ↔ Windows i18n-data.js');

  META_KEYS.forEach((k) => {
    check('Windows zh 词典有 ' + k, typeof I18N_DATA.zh[k] === 'string' && I18N_DATA.zh[k] !== '');
    check('Windows en 词典有 ' + k, typeof I18N_DATA.en[k] === 'string' && I18N_DATA.en[k] !== '');
    check('zh ' + k + ' 两端一致', I18N_DATA.zh[k] === etaZh[k],
      '鸿蒙=' + JSON.stringify(etaZh[k]) + ' Windows=' + JSON.stringify(I18N_DATA.zh[k]));
    check('en ' + k + ' 两端一致', I18N_DATA.en[k] === etaEn[k],
      '鸿蒙=' + JSON.stringify(etaEn[k]) + ' Windows=' + JSON.stringify(I18N_DATA.en[k]));
  });
  check('Windows zh 的 meta.ai.mark 含中文标识', I18N_DATA.zh['meta.ai.mark'].indexOf(AI_MARK_ZH) >= 0);
  check('Windows en 的 meta.ai.mark 含中文标识（切英文不丢中文）',
    I18N_DATA.en['meta.ai.mark'].indexOf(AI_MARK_ZH) >= 0, I18N_DATA.en['meta.ai.mark']);

  /* —— 元数据模块自身的 DEFAULTS 也必须干净 ——
   * 变异测试发现过这个覆盖漏洞：产物断言只能看到"实际用到的字段"（title 由调用方覆盖），
   * 若 DEFAULTS 里被塞回 PptxGenJS 之类的脏值，产物断言抓不到。
   * 这里直接断言模块自带的默认值集合本身：既不得含 PptxGenJS，也不得含未替换占位符。 */
  section('[13b] 元数据模块 DEFAULTS 自身必须干净（堵住"仅断言产物"的覆盖漏洞）');
  const defaultsBlob = Object.keys(AIM.DEFAULTS).map((k) => k + '=' + AIM.DEFAULTS[k]).join('\n');
  console.log(defaultsBlob.split('\n').map((s) => '  ' + s).join('\n'));
  check('AIM.DEFAULTS 不含 "PptxGenJS"', defaultsBlob.indexOf('PptxGenJS') < 0, defaultsBlob);
  check('AIM.DEFAULTS 不含未替换占位符 {{...}} / ${...} / %s',
    !/\{\{|\$\{|%s|\{0\}/.test(defaultsBlob), defaultsBlob);
  check('AIM.DEFAULTS 每个字段都非空（缺字段不会产出空的属性项）',
    Object.keys(AIM.DEFAULTS).every((k) => k !== 'title' ? String(AIM.DEFAULTS[k]).length > 0 : true),
    Object.keys(AIM.DEFAULTS).filter((k) => k !== 'title' && !AIM.DEFAULTS[k]).join(','));
  check('AIM.DEFAULTS 的关键标识字段含中文「AI 生成」',
    ['creator', 'lastModifiedBy', 'description', 'subject', 'company']
      .every((k) => AIM.DEFAULTS[k].indexOf('AI 生成') >= 0),
    ['creator', 'lastModifiedBy', 'description', 'subject', 'company']
      .filter((k) => AIM.DEFAULTS[k].indexOf('AI 生成') < 0).join(','));
  check('DEFAULTS 生成的 core.xml 里不得出现 PptxGenJS（纯函数默认路径）',
    AIM.coreXml(AIM.DEFAULTS, new Date()).indexOf('PptxGenJS') < 0);
  check('DEFAULTS 生成的 app.xml 里不得出现 PptxGenJS（纯函数默认路径）',
    AIM.appXml(AIM.DEFAULTS).indexOf('PptxGenJS') < 0);

  /* 同样堵住鸿蒙侧：从 OoxmlAiMetadata.ets 源码里不得出现 PptxGenJS / 占位符 */
  check('鸿蒙 OoxmlAiMetadata.ets 源码不含 PptxGenJS / 占位符',
    aimEtsSrc.indexOf('PptxGenJS') < 0 && !/\{\{|\$\{|%s/.test(aimEtsSrc));
  check('Windows ooxml-ai-metadata.js 源码不含 PptxGenJS',
    fs.readFileSync(AIM_JS_PATH, 'utf8').indexOf('PptxGenJS') < 0);

  /* 两侧 core.xml 字段集合必须同构（防止只改一端漏字段） */
  const etsCoreFields = (() => {
    const m = aimEtsSrc.match(/static coreXml\([\s\S]*?<\/cp:coreProperties>';/);
    if (!m) throw new Error('OoxmlAiMetadata.ets 中解析不到 coreXml 函数体');
    const tags = [];
    const re = /<(cp|dc|dcterms):([A-Za-z]+)/g;
    let x;
    while ((x = re.exec(m[0])) !== null) tags.push(x[1] + ':' + x[2]);
    return tags.sort().join(',');
  })();
  const jsCoreFields = (() => {
    const xml = AIM.coreXml(AIM.DEFAULTS, new Date());
    const tags = [];
    const re = /<(cp|dc|dcterms):([A-Za-z]+)/g;
    let x;
    while ((x = re.exec(xml)) !== null) tags.push(x[1] + ':' + x[2]);
    return tags.filter((t) => t !== 'cp:coreProperties').sort().join(',');
  })();
  const etsCoreFieldsNoRoot = etsCoreFields.split(',').filter((t) => t !== 'cp:coreProperties').join(',');
  console.log('  鸿蒙 core.xml 字段: ' + etsCoreFieldsNoRoot);
  console.log('  Windows core.xml 字段: ' + jsCoreFields);
  check('两侧 core.xml 字段集合逐字同构', etsCoreFieldsNoRoot === jsCoreFields,
    '鸿蒙=[' + etsCoreFieldsNoRoot + '] Windows=[' + jsCoreFields + ']');

  /* 两侧导出器都把 docProps 注册点补齐 */
  const officeSrcNow = fs.readFileSync(OFFICE_JS_PATH, 'utf8');
  check('office.js docx 链路调用 addAiMetadata（两处：Markdown 与 HTML 富文本）',
    (officeSrcNow.match(/addAiMetadata\(zip, DOCX_CORE_RID/g) || []).length === 2,
    '实得 ' + (officeSrcNow.match(/addAiMetadata\(zip, DOCX_CORE_RID/g) || []).length + ' 处');
  check('office.js pptx 链路调用 addAiMetadata（覆盖骨架 PptxGenJS 元数据）',
    /addAiMetadata\(zip, PPTX_CORE_RID/.test(officeSrcNow));
  check('office.js 的 pptx 关系 Id 从 rId4 起（骨架已占用 rId1-rId3，撞号会产生非法重复 Id）',
    /PPTX_CORE_RID = 'rId4'/.test(officeSrcNow) && /PPTX_APP_RID = 'rId5'/.test(officeSrcNow),
    (officeSrcNow.match(/PPTX_(CORE|APP)_RID = '[^']*'/g) || []).join(' '));
  check('renderer/index.html 在 office.js 之前加载 ooxml-ai-metadata.js（否则元数据缺失）',
    (() => {
      const html = fs.readFileSync(path.join(WIN, 'renderer', 'index.html'), 'utf8');
      // 只在 <script src="..."> 标签里找，避免注释中出现的文件名造成误判
      const scripts = (html.match(/<script\s+src="([^"]+)"/g) || [])
        .map((s) => s.replace(/.*src="([^"]+)".*/, '$1'));
      const a = scripts.indexOf('js/ooxml-ai-metadata.js');
      const b = scripts.indexOf('js/office.js');
      return a >= 0 && b >= 0 && a < b;
    })());

  /* ============================================================================
   * 7. 证据落盘
   * ==========================================================================*/
  section('[14] 证据落盘');
  evidence.push('# docx docProps/core.xml\n\n```xml\n' + docxCore + '\n```\n');
  evidence.push('# docx docProps/app.xml\n\n```xml\n' + docxApp + '\n```\n');
  evidence.push('# docx [Content_Types].xml\n\n```xml\n' + docxCt + '\n```\n');
  evidence.push('# docx _rels/.rels\n\n```xml\n' + docxRels + '\n```\n');
  evidence.push('# pptx docProps/core.xml（覆盖 PptxGenJS 后）\n\n```xml\n' + pptxCore + '\n```\n');
  evidence.push('# pptx docProps/app.xml（覆盖后）\n\n```xml\n' + pptxApp + '\n```\n');
  evidence.push('# 覆盖前：pptskel.pptx 自带的 docProps/core.xml\n\n```xml\n' + skelCore + '\n```\n');
  fs.writeFileSync(path.join(OUT_DIR, 'EVIDENCE.md'), evidence.join('\n'));
  fs.writeFileSync(path.join(OUT_DIR, 'pptskel-before-core.xml'), skelCore);
  console.log('  证据: server/tools/out/EVIDENCE.md');
  console.log('  产物: server/tools/out/ai-metadata-real.docx');
  console.log('  产物: server/tools/out/ai-metadata-real.pptx');

  /* ---------------- 汇总 ---------------- */
  console.log('\n' + '='.repeat(78));
  if (failures.length > 0) {
    console.log('失败项（' + failures.length + '）：');
    failures.forEach((f, i) => console.log('  ' + (i + 1) + '. ' + f));
  }
  console.log('结果: 通过 ' + pass + ' / 共 ' + (pass + failures.length) + ' 项' +
    (failures.length ? '，失败 ' + failures.length : ''));
  console.log('='.repeat(78));
  process.exit(failures.length === 0 ? 0 : 1);
})().catch((e) => {
  console.error('\n✗ 未捕获异常: ' + (e && e.stack ? e.stack : e));
  process.exit(1);
});
