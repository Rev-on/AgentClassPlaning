/**
 * OOXML 元数据部件生成器（纯函数，无 UI / 无文件选择器 / 无 IO）
 *
 * 【跨端约定】本文件是 Windows/Electron 侧的等价实现，与鸿蒙侧
 *   entry/src/main/ets/common/OoxmlAiMetadata.ets **逐字段同构**：
 *   同名方法、同名字段、同样的注册点常量。两端必须同步修改，
 *   由 server/tools/test_export_ai_metadata.js 的跨端一致性断言锁死。
 *
 * 目的：让导出的 docx / pptx 在**文件属性**里就能看到「AI 生成」标识，
 *       接收方不必打开正文即可知悉内容来源。
 *
 * ⚠ 标识文案**本文件不硬编码中文**，由调用方（office.js）经 I18N_DATA 传入，
 *   且必须传入「中文在前、英文在后」的双语串 —— 元数据是给外部接收方看的，
 *   不能因为界面切到英文就把中文标识丢掉。
 */
(function (root, factory) {
  var api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.OOXML_AI_METADATA = api;
})(typeof globalThis !== 'undefined' ? globalThis : this, function () {
  'use strict';

  /* core.xml / app.xml 的 PartName 与关系类型 —— 注册点必须与此一致 */
  var CORE_PATH = 'docProps/core.xml';
  var APP_PATH = 'docProps/app.xml';
  var CORE_CONTENT_TYPE = 'application/vnd.openxmlformats-package.core-properties+xml';
  var APP_CONTENT_TYPE = 'application/vnd.openxmlformats-officedocument.extended-properties+xml';
  /* OPC 包级关系命名空间下的 core-properties 关系类型（与 app.xml 的 officeDocument 前缀不同） */
  var CORE_REL_TYPE = 'http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties';
  var APP_REL_TYPE = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties';

  /* 元数据字段默认值：中文标识稳定存在（先中文、后英文） */
  var DEFAULTS = {
    title: '',
    creator: 'Agent备课（AI 生成） / Lesson Prep Agent (AI-generated)',
    lastModifiedBy: 'Agent备课（AI 生成） / Lesson Prep Agent (AI-generated)',
    description: '本文件内容由 AI 生成，仅供参考。 / AI-generated content, for reference only.',
    subject: 'AI 生成，仅供参考 / AI-generated, for reference only',
    appName: 'Agent备课 (AI)',
    company: 'AI 生成，仅供参考 / AI-generated, for reference only',
    keywords: 'AI生成,仅供参考,Agent备课,AI-generated'
  };

  /** XML 文本转义（属性值同样用此函数，故一并转义引号） */
  function escapeXml(text) {
    return String(text == null ? '' : text)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&apos;');
  }

  /**
   * W3CDTF 时间串（UTC，形如 2026-10-08T12:34:56Z）。
   *
   * 为什么不直接 toISOString()：`.000` 毫秒段虽合法但并非所有解析器都友好，
   * 且鸿蒙侧同为无毫秒写法，两端产物需逐字一致。
   */
  function w3cdtf(date) {
    var d = date || new Date();
    function p(n) { return n < 10 ? '0' + n : '' + n; }
    return d.getUTCFullYear() + '-' + p(d.getUTCMonth() + 1) + '-' + p(d.getUTCDate()) +
      'T' + p(d.getUTCHours()) + ':' + p(d.getUTCMinutes()) + ':' + p(d.getUTCSeconds()) + 'Z';
  }

  /** 合并调用方字段与默认值（缺字段一律回落到双语默认串，绝不落空） */
  function fields(f) {
    var src = f || {};
    var out = {};
    Object.keys(DEFAULTS).forEach(function (k) {
      var v = src[k];
      out[k] = (v === undefined || v === null || v === '') ? DEFAULTS[k] : String(v);
    });
    return out;
  }

  /**
   * 生成 docProps/core.xml。
   *
   * 命名空间为 OOXML core-properties 标准五件套；dcterms 的两个时间必须带
   * xsi:type="dcterms:W3CDTF"，否则 Word 会把创建时间当作无效值丢弃。
   */
  function coreXml(f, now) {
    var m = fields(f);
    var stamp = w3cdtf(now);
    var e = escapeXml;
    return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n' +
      '<cp:coreProperties' +
      ' xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties"' +
      ' xmlns:dc="http://purl.org/dc/elements/1.1/"' +
      ' xmlns:dcterms="http://purl.org/dc/terms/"' +
      ' xmlns:dcmitype="http://purl.org/dc/dcmitype/"' +
      ' xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">' +
      '<dc:title>' + e(m.title) + '</dc:title>' +
      '<dc:subject>' + e(m.subject) + '</dc:subject>' +
      '<dc:creator>' + e(m.creator) + '</dc:creator>' +
      '<cp:lastModifiedBy>' + e(m.lastModifiedBy) + '</cp:lastModifiedBy>' +
      '<cp:keywords>' + e(m.keywords) + '</cp:keywords>' +
      '<dc:description>' + e(m.description) + '</dc:description>' +
      '<cp:revision>1</cp:revision>' +
      '<dcterms:created xsi:type="dcterms:W3CDTF">' + stamp + '</dcterms:created>' +
      '<dcterms:modified xsi:type="dcterms:W3CDTF">' + stamp + '</dcterms:modified>' +
      '<cp:category>AI 生成内容</cp:category>' +
      '<cp:contentStatus>AI 生成，仅供参考</cp:contentStatus>' +
      '</cp:coreProperties>';
  }

  /**
   * 生成 docProps/app.xml（扩展属性）。
   *
   * 只写最小必备集合：Application / Company 是"文件属性 → 详细信息"里
   * 最直观可见的两项。**刻意不写** Pages/Words/Slides/HeadingPairs/TitlesOfParts ——
   * 我们没有统计这些数据，写了就是假信息。
   */
  function appXml(f) {
    var m = fields(f);
    var e = escapeXml;
    return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n' +
      '<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"' +
      ' xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes">' +
      '<Application>' + e(m.appName) + '</Application>' +
      '<Company>' + e(m.company) + '</Company>' +
      '<DocSecurity>0</DocSecurity>' +
      '<ScaleCrop>false</ScaleCrop>' +
      '<LinksUpToDate>false</LinksUpToDate>' +
      '<SharedDoc>false</SharedDoc>' +
      '<HyperlinksChanged>false</HyperlinksChanged>' +
      '<AppVersion>16.0000</AppVersion>' +
      '</Properties>';
  }

  /** docProps/core.xml 与 app.xml 的 Override 片段（插入 [Content_Types].xml 的 </Types> 之前） */
  function contentTypeOverrides() {
    return '<Override PartName="/docProps/core.xml" ContentType="' + CORE_CONTENT_TYPE + '"/>' +
      '<Override PartName="/docProps/app.xml" ContentType="' + APP_CONTENT_TYPE + '"/>';
  }

  /**
   * 两个包级关系片段（插入 _rels/.rels 的 </Relationships> 之前）。
   * 只传 Id：docx 包已有的 rId1 被 officeDocument 占用，pptx 包被 app/core/officeDocument
   * 依次占用，故调用方需给出空闲 Id（本实现统一用 rId4/rId5，两包都不会撞）。
   */
  function relationshipXml(idCore, idApp) {
    return '<Relationship Id="' + idCore + '" Type="' + CORE_REL_TYPE +
      '" Target="docProps/core.xml"/>' +
      '<Relationship Id="' + idApp + '" Type="' + APP_REL_TYPE +
      '" Target="docProps/app.xml"/>';
  }

  return {
    CORE_PATH: CORE_PATH,
    APP_PATH: APP_PATH,
    CORE_CONTENT_TYPE: CORE_CONTENT_TYPE,
    APP_CONTENT_TYPE: APP_CONTENT_TYPE,
    CORE_REL_TYPE: CORE_REL_TYPE,
    APP_REL_TYPE: APP_REL_TYPE,
    DEFAULTS: DEFAULTS,
    escapeXml: escapeXml,
    w3cdtf: w3cdtf,
    coreXml: coreXml,
    appXml: appXml,
    contentTypeOverrides: contentTypeOverrides,
    relationshipXml: relationshipXml
  };
});
