/**
 * OOXML 元数据部件生成器（纯函数，无 UI / 无文件选择器 / 无 IO）
 *
 * 目的：让导出的 docx / pptx 在**文件属性**里就能看到「AI 生成」标识，
 *       接收方（其他老师、家长、教务）不必打开正文即可知悉内容来源。
 *
 * 为什么单独成文件：
 *   1. 与 RichHtml.ets 同样的定位 —— 可被页面、导出器、测试直接调用；
 *   2. 元数据写法（尤其是 core.xml 的命名空间与 W3CDTF 时间格式）极易出错，
 *      集中一处便于回归测试用「从源码解析常量 + 与实际实现同构」的方式绑定验证。
 *
 * ⚠ 标识文案**本文件不硬编码中文**，由调用方（DocxExporter / PptxExporter）
 *   经 I18n 传入，且必须传入「中文在前、英文在后」的双语串 —— 元数据是给
 *   外部接收方看的，不能因为界面切到英文就把中文标识丢掉。
 */

/** 元数据字段集合（由调用方本地化后传入；中文标识必须稳定存在） */
export interface AiMetadataFields {
  title: string;        // 文档标题（取自导出文件名，不含扩展名）
  creator: string;      // 作者 / 创建者
  lastModifiedBy: string; // 最后修改者
  description: string;  // 备注（文件属性里可见）
  subject: string;      // 主题
  appName: string;      // 应用程序名
  company: string;      // 公司
  keywords: string;     // 关键词
}

export class OoxmlAiMetadata {

  /** core.xml（OPC 核心属性）固定的 PartName 与关系类型 —— 注册点必须与此一致 */
  static readonly CORE_PATH: string = 'docProps/core.xml';
  static readonly APP_PATH: string = 'docProps/app.xml';
  static readonly CORE_CONTENT_TYPE: string = 'application/vnd.openxmlformats-package.core-properties+xml';
  static readonly APP_CONTENT_TYPE: string = 'application/vnd.openxmlformats-officedocument.extended-properties+xml';
  /** OPC 包级关系命名空间下的 core-properties 关系类型（注意与 app.xml 的 officeDocument 前缀不同） */
  static readonly CORE_REL_TYPE: string = 'http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties';
  static readonly APP_REL_TYPE: string = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties';

  /** XML 文本转义（属性值同样用此函数，故一并转义引号） */
  static escapeXml(text: string): string {
    return text
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
   * 且本项目其它部件均用无毫秒的紧凑写法，保持全包一致。
   */
  static w3cdtf(date: Date): string {
    const p = (n: number): string => (n < 10 ? '0' + n : '' + n);
    return date.getUTCFullYear() + '-' + p(date.getUTCMonth() + 1) + '-' + p(date.getUTCDate()) +
      'T' + p(date.getUTCHours()) + ':' + p(date.getUTCMinutes()) + ':' + p(date.getUTCSeconds()) + 'Z';
  }

  /**
   * 生成 docProps/core.xml。
   *
   * 命名空间为 OOXML core-properties 标准五件套；dcterms 的两个时间必须带
   * xsi:type="dcterms:W3CDTF"，否则 Word 会把创建时间当作无效值丢弃。
   */
  static coreXml(f: AiMetadataFields, now: Date): string {
    const stamp: string = OoxmlAiMetadata.w3cdtf(now);
    const e = OoxmlAiMetadata.escapeXml;
    return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n' +
      '<cp:coreProperties' +
      ' xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties"' +
      ' xmlns:dc="http://purl.org/dc/elements/1.1/"' +
      ' xmlns:dcterms="http://purl.org/dc/terms/"' +
      ' xmlns:dcmitype="http://purl.org/dc/dcmitype/"' +
      ' xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">' +
      '<dc:title>' + e(f.title) + '</dc:title>' +
      '<dc:subject>' + e(f.subject) + '</dc:subject>' +
      '<dc:creator>' + e(f.creator) + '</dc:creator>' +
      '<cp:lastModifiedBy>' + e(f.lastModifiedBy) + '</cp:lastModifiedBy>' +
      '<cp:keywords>' + e(f.keywords) + '</cp:keywords>' +
      '<dc:description>' + e(f.description) + '</dc:description>' +
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
   * 最直观可见的两项；DocSecurity 与 ScaleCrop 是 OOXML 推荐值。
   * **刻意不写** Pages/Words/Slides/HeadingPairs/TitlesOfParts ——
   * 我们没有统计这些数据，写了就是假信息，且 PowerPoint 打开时会自行重算。
   */
  static appXml(f: AiMetadataFields): string {
    const e = OoxmlAiMetadata.escapeXml;
    return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n' +
      '<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"' +
      ' xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes">' +
      '<Application>' + e(f.appName) + '</Application>' +
      '<Company>' + e(f.company) + '</Company>' +
      '<DocSecurity>0</DocSecurity>' +
      '<ScaleCrop>false</ScaleCrop>' +
      '<LinksUpToDate>false</LinksUpToDate>' +
      '<SharedDoc>false</SharedDoc>' +
      '<HyperlinksChanged>false</HyperlinksChanged>' +
      '<AppVersion>16.0000</AppVersion>' +
      '</Properties>';
  }

  /** docProps/core.xml 的 Override 片段（插入 [Content_Types].xml 的 </Types> 之前） */
  static contentTypeOverrides(): string {
    return '<Override PartName="/docProps/core.xml" ContentType="' + OoxmlAiMetadata.CORE_CONTENT_TYPE + '"/>' +
      '<Override PartName="/docProps/app.xml" ContentType="' + OoxmlAiMetadata.APP_CONTENT_TYPE + '"/>';
  }

  /**
   * 两个包级关系片段（插入 _rels/.rels 的 </Relationships> 之前）。
   * 只传 Id：docx 包已有的 rId1 被 officeDocument 占用，pptx 包被 app/core/officeDocument
   * 依次占用，故调用方需给出空闲 Id（本实现统一用 rId4/rId5，两包都不会撞）。
   */
  static relationshipXml(idCore: string, idApp: string): string {
    return '<Relationship Id="' + idCore + '" Type="' + OoxmlAiMetadata.CORE_REL_TYPE +
      '" Target="docProps/core.xml"/>' +
      '<Relationship Id="' + idApp + '" Type="' + OoxmlAiMetadata.APP_REL_TYPE +
      '" Target="docProps/app.xml"/>';
  }
}
