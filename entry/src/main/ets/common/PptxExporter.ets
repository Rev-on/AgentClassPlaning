/**
 * PPTX 导出器：把课件大纲 JSON 解析为"逐页 PPT 粗稿"并导出 .pptx
 * 每页含：页号/类型角标、页面标题、要点逐行、底部配图方向提示（白底黑字，16:9）
 * 实现：以内置单页模板（含完整 master/layout/theme）为基础，按页数复制展开并注入新页
 */
import { picker, fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import promptAction from '@ohos.promptAction';
import JSZip from '@ohos/jszip';
import { I18n } from './I18n';
import { OoxmlAiMetadata, AiMetadataFields } from './OoxmlAiMetadata';

/** 课件大纲的一页 */
export interface CourseSlide {
  page: number;
  type: string;
  title: string;
  points: string[];
  visual: string;
}

export class PptxExporter {

  /** 从生成结果中解析页面数组；解析失败返回 null */
  static parseSlides(json: string): CourseSlide[] | null {
    let text: string = json.trim();
    const fenceStart: number = text.indexOf('```');
    if (fenceStart >= 0) {
      const fenceEnd: number = text.lastIndexOf('```');
      if (fenceEnd > fenceStart) {
        text = text.substring(fenceStart + 3, fenceEnd).trim();
      }
    }
    const s: number = text.indexOf('[');
    const e: number = text.lastIndexOf(']');
    if (s < 0 || e <= s) {
      return null;
    }
    text = text.substring(s, e + 1);
    let obj: object | null = null;
    try {
      obj = JSON.parse(text) as object;
    } catch (err) {
      return null;
    }
    if (obj === null || !Array.isArray(obj)) {
      return null;
    }
    const slides: CourseSlide[] = [];
    for (let i: number = 0; i < (obj as object[]).length; i++) {
      const it = (obj as object[])[i] as Record<string, Object>;
      const page: number = typeof it['page'] === 'number' ? it['page'] as number : (i + 1);
      const type: string = it['type'] !== undefined ? String(it['type']) : '';
      const title: string = it['title'] !== undefined ? String(it['title']) : '';
      const visual: string = it['visual'] !== undefined ? String(it['visual']) : '';
      const points: string[] = [];
      const pts = it['points'];
      if (Array.isArray(pts)) {
        for (let k: number = 0; k < (pts as object[]).length; k++) {
          const v = (pts as object[])[k];
          if (typeof v === 'string') {
            points.push(v);
          }
        }
      }
      slides.push({ page: page, type: type, title: title, points: points, visual: visual });
    }
    return slides;
  }

  /** 提取标签属性值（形如 name="value"，兼容单双引号）；未找到返回空串 */
  private static htmlAttr(tag: string, name: string): string {
    const key: string = name + '="';
    const ks: number = tag.indexOf(key);
    if (ks >= 0) {
      const v0: number = ks + key.length;
      const v1: number = tag.indexOf('"', v0);
      if (v1 >= 0) {
        return tag.substring(v0, v1);
      }
    }
    const key1: string = name + '=\'';
    const ks1: number = tag.indexOf(key1);
    if (ks1 >= 0) {
      const v0: number = ks1 + key1.length;
      const v1: number = tag.indexOf('\'', v0);
      if (v1 >= 0) {
        return tag.substring(v0, v1);
      }
    }
    return '';
  }

  /** 提取标签名（<h1>、<p>、<section …> 等） */
  private static htmlTagName(open: string): string {
    let e: number = 1;
    while (e < open.length && open[e] !== ' ' && open[e] !== '>' && open[e] !== '/') {
      e++;
    }
    return open.substring(1, e).toLowerCase();
  }

  /** 剥离一段文本中的全部标签 */
  private static htmlStrip(s: string): string {
    return s.replace(/<[^>]*>/g, '');
  }

  /** 提取 slide 内部 h1/h2/h3/p 的文本作为要点（按出现顺序收集） */
  private static htmlTexts(inner: string): string[] {
    const out: string[] = [];
    let i: number = 0;
    while (i < inner.length) {
      const lt: number = inner.indexOf('<', i);
      if (lt < 0) {
        break;
      }
      const gt: number = inner.indexOf('>', lt);
      if (gt < 0) {
        break;
      }
      const name: string = PptxExporter.htmlTagName(inner.substring(lt, gt + 1));
      const close: string = (name === 'p' || name === 'h1' || name === 'h2' || name === 'h3' || name === 'li' || name === 'td' || name === 'th')
        ? '</' + name + '>'
        : '';
      if (close === '') {
        i = gt + 1;
        continue;
      }
      const ce: number = inner.indexOf(close, gt + 1);
      if (ce < 0) {
        i = gt + 1;
        continue;
      }
      const text: string = PptxExporter.htmlStrip(inner.substring(gt + 1, ce)).trim();
      if (text !== '') {
        out.push(text);
      }
      i = ce + close.length;
    }
    return out;
  }

  /**
   * 从 AI 直出的逐页 OOXML 片段中解析幻灯片。
   * 约定输出格式：页面用一行 ===== 分隔；每页内为若干 field=value 行，
   * 可含 type=、title=、notes=、body=（多条要点用 ｜ 分隔），body 同时接受连续多行"• …"。
   * 未解析到任何页时返回 null。
   */
  static parseOoxmlFragments(text: string): CourseSlide[] | null {
    const slides: CourseSlide[] = [];
    const pages: string[] = text.split('=====');
    for (let i: number = 0; i < pages.length; i++) {
      const page: string = pages[i].trim();
      if (page === '') {
        continue;
      }
      let type: string = '';
      let title: string = '';
      let notes: string = '';
      const pts: string[] = [];
      const lines: string[] = page.split('\n');
      let bodySeen: boolean = false;
      for (let k: number = 0; k < lines.length; k++) {
        const line: string = lines[k].trim();
        if (line === '') {
          continue;
        }
        const eq: number = line.indexOf('=');
        if (eq > 0) {
          const key: string = line.substring(0, eq).trim().toLowerCase();
          const val: string = line.substring(eq + 1).trim();
          if (key === 'type') {
            type = val;
          } else if (key === 'title') {
            title = val;
          } else if (key === 'notes') {
            notes = val;
          } else if (key === 'body') {
            bodySeen = true;
            const bullets: string[] = val.split('｜');
            for (let b: number = 0; b < bullets.length; b++) {
              const t: string = bullets[b].trim();
              if (t !== '') {
                pts.push(t);
              }
            }
          }
        } else {
          // 裸行：若前面已出现 body 字段，视为补充要点（支持 • 前缀）
          if (bodySeen || pts.length > 0) {
            let t: string = line;
            if (t.startsWith('•') || t.startsWith('-') || t.startsWith('*')) {
              t = t.substring(1).trim();
            }
            if (t !== '') {
              pts.push(t);
            }
          }
        }
      }
      if (title === '' && pts.length === 0) {
        continue;
      }
      if (title === '') {
        title = I18n.t('cw.page').replace('{n}', (slides.length + 1).toString());
      }
      slides.push({ page: slides.length + 1, type: type, title: title, points: pts, visual: notes });
    }
    return slides.length > 0 ? slides : null;
  }

  /** 临时页目录名（cacheDir 下），多页 OOXML 片段拆成 slideN.xml 供预览/后续复用 */
  private static pagesDir(context: common.UIAbilityContext): string {
    return context.cacheDir + '/courseware_pages';
  }

  /** 把 AI 直出的逐页片段写成临时多文件（cacheDir/courseware_pages/*.xml）；仅写本此解析出的页 */
  static async writeCoursewarePages(context: common.UIAbilityContext, text: string): Promise<void> {
    try {
      const dir: string = PptxExporter.pagesDir(context);
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir);
      }
      // 先清空旧页文件，避免残留
      PptxExporter.clearCoursewarePages(context);
      const slides: CourseSlide[] | null = PptxExporter.parseOoxmlFragments(text);
      if (slides === null || slides.length === 0) {
        return;
      }
      for (let i: number = 0; i < slides.length; i++) {
        const file: string = dir + '/slide' + (i + 1) + '.xml';
        const content: string = 'type=' + slides[i].type + '\ntitle=' + slides[i].title +
          '\nnotes=' + slides[i].visual + '\nbody=' + slides[i].points.join('｜');
        const f = fs.openSync(file, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
        fs.writeSync(f.fd, content);
        fs.closeSync(f);
      }
    } catch (e) {
      // 临时文件非关键路径，失败静默（不影响主预览/导出）
    }
  }

  /** 清空临时页目录（下一次生成前调用，自动删除上一轮多文件） */
  static clearCoursewarePages(context: common.UIAbilityContext): void {
    try {
      const dir: string = PptxExporter.pagesDir(context);
      if (!fs.accessSync(dir)) {
        return;
      }
      const list: string[] = fs.listFileSync(dir);
      for (let i: number = 0; i < list.length; i++) {
        try {
          fs.unlinkSync(dir + '/' + list[i]);
        } catch (e) {
          // 忽略单个文件删除失败
        }
      }
      try {
        fs.rmdirSync(dir);
      } catch (e) {
        // 目录非空或占用时忽略
      }
    } catch (e) {
      // 清理失败非关键
    }
  }

  /**
   * 从 HTML 课件文档中解析逐页幻灯片（统一 CSS + 逐页 <section class="slide">）。
   * 每页以 data-title/data-type/data-visual 属性与内部 h1/h2/h3/p 文本构成 CourseSlide；
   * 未找到任何 slide 时返回 null。
   */
  static parseHtmlCourseware(html: string): CourseSlide[] | null {
    const slides: CourseSlide[] = [];
    const openTag: string = '<section';
    const closeTag: string = '</section>';
    let idx: number = 0;
    while (idx < html.length) {
      const s: number = html.indexOf(openTag, idx);
      if (s < 0) {
        break;
      }
      const gt: number = html.indexOf('>', s);
      if (gt < 0) {
        break;
      }
      const tag: string = html.substring(s, gt + 1);
      // 仅收集 class 含 slide 的 <section>，跳过普通 section
      if (tag.indexOf('class="slide"') < 0 && tag.indexOf('class="slide ') < 0) {
        idx = gt + 1;
        continue;
      }
      const cs: number = gt + 1;
      const e: number = html.indexOf(closeTag, cs);
      if (e < 0) {
        break;
      }
      const inner: string = html.substring(cs, e);
      const title: string = PptxExporter.htmlAttr(tag, 'data-title');
      const type: string = PptxExporter.htmlAttr(tag, 'data-type');
      const visual: string = PptxExporter.htmlAttr(tag, 'data-visual');
      const points: string[] = PptxExporter.htmlTexts(inner);
      slides.push({
        page: slides.length + 1,
        type: type,
        title: title,
        points: points,
        visual: visual
      });
      idx = e + closeTag.length;
    }
    if (slides.length === 0) {
      return null;
    }
    return slides;
  }

  /** 导出课件为 .pptx 粗稿（兼容 AI 直出 OOXML 片段、HTML 课件、旧 JSON 大纲三种形态；选择保存位置） */
  static async exportPptx(context: common.UIAbilityContext, json: string, fileName: string): Promise<void> {
    const buffer: ArrayBuffer = await PptxExporter.buildPptxBuffer(context, json, fileName);
    const savePicker = new picker.DocumentViewPicker(context);
    const saveOptions = new picker.DocumentSaveOptions();
    saveOptions.newFileNames = [fileName];
    // ArkUI-X 跨端：不设置 fileSuffixChoices（Android 侧不支持，后缀由系统按文件名扩展名处理）
    const saveResult = await savePicker.save(saveOptions);
    if (saveResult.length === 0) {
      return;
    }
    const uri: string = saveResult[0];
    const file = fs.openSync(uri, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    fs.writeSync(file.fd, buffer);
    fs.closeSync(file);
    promptAction.showToast({ message: I18n.t('toast.exportedTo') + fileName });
  }

  /** 导出课件 .pptx 到应用沙箱 filesDir（供 ShareKit 系统分享面板读取），返回文件路径 */
  static async exportPptxToFile(context: common.UIAbilityContext, json: string, fileName: string): Promise<string> {
    const buffer: ArrayBuffer = await PptxExporter.buildPptxBuffer(context, json, fileName);
    const path: string = context.filesDir + '/share_' + Date.now() + '_' + fileName;
    const file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    fs.writeSync(file.fd, buffer);
    fs.closeSync(file);
    return path;
  }

  /** 组装 .pptx 包字节（兼容 OOXML 片段/HTML 课件/JSON 大纲三种形态，基于内置模板逐页注入） */
  private static async buildPptxBuffer(context: common.UIAbilityContext, json: string, fileName: string): Promise<ArrayBuffer> {
    let slides: CourseSlide[] | null = PptxExporter.parseOoxmlFragments(json);
    if (slides === null || slides.length === 0) {
      slides = PptxExporter.parseHtmlCourseware(json);
    }
    if (slides === null) {
      slides = PptxExporter.parseSlides(json);
    }
    if (slides === null || slides.length === 0) {
      throw new Error(I18n.t('err.pptxJson'));
    }
    // 1. 读取内置模板并解包
    const raw: Uint8Array = await context.resourceManager.getRawFileContent('pptskel.pptx');
    const zip = await JSZip.loadAsync(raw);
    // 2. 逐页生成幻灯片部件并覆盖/新增
    const n: number = slides.length;
    const slidePaths: string[] = [];
    for (let i: number = 0; i < n; i++) {
      const slideIndex: number = i + 1;
      const path: string = 'ppt/slides/slide' + slideIndex + '.xml';
      slidePaths.push(path);
      zip.file(path, PptxExporter.slideXml(slides[i], slideIndex, n));
      // 新页 rels 仅保留到版式的引用（第 1 页沿用模板自带 rels 即可）
      if (i > 0) {
        zip.file('ppt/slides/_rels/slide' + slideIndex + '.xml.rels', PptxExporter.slideRelsXml());
      }
    }
    // 3. 注册新页到 [Content_Types].xml
    const typesName: string = '[Content_Types].xml';
    const tf = zip.file(typesName);
    if (tf === null) {
      throw new Error(I18n.t('err.pptxTpl') + ' [Content_Types].xml');
    }
    let types: string = await tf.async('string');
    for (let i: number = 1; i < n; i++) {
      const over: string = '<Override PartName="/ppt/slides/slide' + (i + 1) +
        '.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>';
      types = types.replace('</Types>', over + '</Types>');
    }
    zip.file(typesName, types);
    // 4. 注册新页关系到 presentation.xml.rels
    const presRelsName: string = 'ppt/_rels/presentation.xml.rels';
    const rf = zip.file(presRelsName);
    if (rf === null) {
      throw new Error(I18n.t('err.pptxTpl') + ' presentation.xml.rels');
    }
    let presRels: string = await rf.async('string');
    let relsExtra: string = '';
    for (let i: number = 0; i < n; i++) {
      relsExtra += '<Relationship Id="rId20' + (i + 1) + '" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide' + (i + 1) + '.xml"/>';
    }
    presRels = presRels.replace('</Relationships>', relsExtra + '</Relationships>');
    zip.file(presRelsName, presRels);
    // 5. presentation.xml 的 sldIdLst 全部指向上面的 rId20x
    const presName: string = 'ppt/presentation.xml';
    const pf = zip.file(presName);
    if (pf === null) {
      throw new Error(I18n.t('err.pptxTpl') + ' presentation.xml');
    }
    let pres: string = await pf.async('string');
    const startTag: string = '<p:sldIdLst>';
    const endTag: string = '</p:sldIdLst>';
    const si: number = pres.indexOf(startTag);
    const ei: number = pres.indexOf(endTag);
    if (si >= 0 && ei > si) {
      let inner: string = '';
      for (let i: number = 0; i < n; i++) {
        inner += '<p:sldId id="' + (256 + i) + '" r:id="rId20' + (i + 1) + '"/>';
      }
      pres = pres.substring(0, si + startTag.length) + inner + pres.substring(ei);
    }
    zip.file(presName, pres);
    // 7. 覆盖模板自带的 docProps
    //    模板 pptskel.pptx 由 PptxGenJS 生成，其 docProps/core.xml 里
    //    dc:creator / cp:lastModifiedBy = "PptxGenJS"、dc:title = "PptxGenJS Presentation"，
    //    作为对外交付物是误导性信息，必须整体覆盖为「AI 生成」标识。
    //    模板的 [Content_Types].xml 与 _rels/.rels 已注册好 docProps 两个部件，
    //    故此处只需覆盖部件本体，不重复注册（重复注册会产生非法重复 Override）。
    const fields: AiMetadataFields = PptxExporter.aiMetadataFields(fileName);
    zip.file(OoxmlAiMetadata.CORE_PATH, OoxmlAiMetadata.coreXml(fields, new Date()));
    zip.file(OoxmlAiMetadata.APP_PATH, OoxmlAiMetadata.appXml(fields));
    // 8. 打包
    return (await zip.generateAsync({
      type: 'arraybuffer',
      compression: 'DEFLATE'
    })) as ArrayBuffer;
  }

  /**
   * 组装元数据字段。文案走 I18n（新增 meta.ai.* 键），**不在此硬编码中文**；
   * 但 meta.ai.mark 本身是"中文在前、英文在后"的双语串，故界面切英文也不会丢中文标识。
   */
  private static aiMetadataFields(fileName: string): AiMetadataFields {
    let title: string = fileName;
    const dot: number = title.lastIndexOf('.');
    if (dot > 0) {
      title = title.substring(0, dot);
    }
    title = title.trim();
    const mark: string = I18n.t('meta.ai.mark');
    return {
      title: title !== '' ? title : I18n.t('meta.ai.app'),
      creator: I18n.t('meta.ai.creator'),
      lastModifiedBy: I18n.t('meta.ai.creator'),
      // 注意：meta.ai.desc 本身已以"仅供参考。"收尾，**不要再拼 mark** ——
      // 否则 description 里同一句话会出现两遍（与 DocxExporter 同因，已一并修正）。
      description: I18n.t('meta.ai.desc'),
      subject: mark,
      appName: I18n.t('meta.ai.app'),
      company: mark,
      keywords: I18n.t('meta.ai.keywords')
    };
  }

  // ============ 幻灯片部件 XML ============

  private static escapeXml(text: string): string {
    return text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;').replace(/'/g, '&apos;');
  }

  /** 新页 rels：仅引用默认版式 */
  private static slideRelsXml(): string {
    return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n' +
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
      '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>' +
      '</Relationships>';
  }

  /** 文本形状（白底黑字；可含多段要点） */
  private static shapeXml(id: number, x: number, y: number, cx: number, cy: number,
    lines: string[], bold: boolean, sz: number, color: string, prefix: boolean, fillClr: string): string {
    const paras: string[] = [];
    for (let i: number = 0; i < lines.length; i++) {
      const text: string = prefix ? '•  ' + lines[i] : lines[i];
      const pPr: string = prefix
        ? '<a:pPr marL="274320" indent="-274320"><a:spcBef><a:spcPts val="600"/></a:spcBef><a:buNone/></a:pPr>'
        : '<a:pPr marL="0" indent="0"><a:buNone/></a:pPr>';
      paras.push('<a:p>' + pPr +
        '<a:r><a:rPr lang="' + I18n.bcp47() + '" sz="' + sz + '" b="' + (bold ? '1' : '0') + '" dirty="0">' +
        '<a:solidFill><a:srgbClr val="' + color + '"/></a:solidFill></a:rPr>' +
        '<a:t>' + PptxExporter.escapeXml(text) + '</a:t></a:r></a:p>');
    }
    const fill: string = fillClr !== ''
      ? '<a:solidFill><a:srgbClr val="' + fillClr + '"/></a:solidFill>'
      : '<a:noFill/>';
    return '<p:sp><p:nvSpPr><p:cNvPr id="' + id + '" name="Shape ' + id + '"/><p:cNvSpPr txBox="1"/><p:nvPr/>' +
      '</p:nvSpPr><p:spPr><a:xfrm><a:off x="' + x + '" y="' + y + '"/><a:ext cx="' + cx + '" cy="' + cy + '"/>' +
      '</a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom>' + fill + '<a:ln><a:noFill/></a:ln></p:spPr>' +
      '<p:txBody><a:bodyPr wrap="square" anchor="t"><a:normAutofit/></a:bodyPr><a:lstStyle/>' +
      paras.join('') + '</p:txBody></p:sp>';
  }

  /** 纯填充矩形（无文字）：顶部装饰条 */
  private static rectXml(id: number, x: number, y: number, cx: number, cy: number, fillClr: string): string {
    return '<p:sp><p:nvSpPr><p:cNvPr id="' + id + '" name="Bar ' + id + '"/><p:cNvSpPr/><p:nvPr/>' +
      '</p:nvSpPr><p:spPr><a:xfrm><a:off x="' + x + '" y="' + y + '"/><a:ext cx="' + cx + '" cy="' + cy + '"/>' +
      '</a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom>' +
      '<a:solidFill><a:srgbClr val="' + fillClr + '"/></a:solidFill><a:ln><a:noFill/></a:ln></p:spPr></p:sp>';
  }

  /** 填充矩形+居中文字：页型徽章 */
  private static badgeXml(id: number, x: number, y: number, text: string, bgClr: string, txtClr: string, sz: number): string {
    return '<p:sp><p:nvSpPr><p:cNvPr id="' + id + '" name="Badge ' + id + '"/><p:cNvSpPr txBox="1"/><p:nvPr/>' +
      '</p:nvSpPr><p:spPr><a:xfrm><a:off x="' + x + '" y="' + y + '"/><a:ext cx="340000" cy="260000"/>' +
      '</a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom>' +
      '<a:solidFill><a:srgbClr val="' + bgClr + '"/></a:solidFill><a:ln><a:noFill/></a:ln></p:spPr>' +
      '<p:txBody><a:bodyPr wrap="square" anchor="ctr"><a:normAutofit/></a:bodyPr><a:lstStyle/>' +
      '<a:p><a:pPr algn="ctr"/><a:r><a:rPr lang="' + I18n.bcp47() + '" sz="' + sz + '" b="1" dirty="0">' +
      '<a:solidFill><a:srgbClr val="' + txtClr + '"/></a:solidFill></a:rPr>' +
      '<a:t>' + PptxExporter.escapeXml(text) + '</a:t></a:r></a:p></p:txBody></p:sp>';
  }

  /** 单页幻灯片 XML */
  private static slideXml(slide: CourseSlide, index: number, total: number): string {
    const W: number = 12192000;
    const left: number = 548640;
    const contentW: number = W - 548640 * 2;
    let bgClr: string = 'FFFFFF';
    let titleClr: string = '1F2937';
    let accentClr: string = '4A90D9';
    let bodyClr: string = '333333';
    let badgeBg: string = 'E8F1FB';
    let badgeText: string = '2B4C7E';
    const tp: string = slide.type;
    if (tp === '封面') {
      bgClr = '1A365D'; titleClr = 'FFFFFF'; accentClr = '4A90D9'; bodyClr = 'E0E7EF'; badgeBg = '4A90D9'; badgeText = 'FFFFFF';
    } else if (tp === '导入') {
      bgClr = 'FFF8E1'; titleClr = 'E65100'; accentClr = 'FF9800'; bodyClr = '5D4037'; badgeBg = 'FFE0B2'; badgeText = 'E65100';
    } else if (tp === '讲解') {
      bgClr = 'F0F4FA'; titleClr = '1A365D'; accentClr = '4A90D9'; bodyClr = '374151'; badgeBg = 'E8F1FB'; badgeText = '2B4C7E';
    } else if (tp === '例题') {
      bgClr = 'FFF3E0'; titleClr = 'E65100'; accentClr = 'FF6F00'; bodyClr = '4E342E'; badgeBg = 'FFE0B2'; badgeText = 'E65100';
    } else if (tp === '练习') {
      bgClr = 'E8F5E9'; titleClr = '1B5E20'; accentClr = '2E7D32'; bodyClr = '2E7D32'; badgeBg = 'C8E6C9'; badgeText = '1B5E20';
    } else if (tp === '小结') {
      bgClr = 'F3E5F5'; titleClr = '4A148C'; accentClr = '7B1FA2'; bodyClr = '4A148C'; badgeBg = 'E1BEE7'; badgeText = '4A148C';
    } else if (tp === '作业') {
      bgClr = 'E3F2FD'; titleClr = '0D47A1'; accentClr = '1976D2'; bodyClr = '1565C0'; badgeBg = 'BBDEFB'; badgeText = '0D47A1';
    }
    const caption: string = I18n.t('cw.pageOf')
      .replace('{i}', index.toString()).replace('{t}', total.toString());
    const title: string = slide.title !== '' ? slide.title : I18n.t('cw.page').replace('{n}', index.toString());
    const pts: string[] = slide.points.length > 0 ? slide.points.slice(0, 8) : [I18n.t('cw.noPointsDraft')];
    const visual: string = slide.visual !== '' ? I18n.t('cw.visual') + slide.visual : '';
    const shapes: string[] = [];
    shapes.push(PptxExporter.rectXml(2, 0, 0, W, 55000, accentClr));
    if (slide.type !== '') {
      shapes.push(PptxExporter.badgeXml(3, left, 182880, slide.type, badgeBg, badgeText, 1200));
    }
    const captionX: number = slide.type !== '' ? left + 380000 : left;
    shapes.push(PptxExporter.shapeXml(4, captionX, 182880, contentW - 380000, 228600, [caption], false, 1200, '7F7F7F', false, ''));
    shapes.push(PptxExporter.shapeXml(5, left, 480060, contentW, 900000, [title], true, 3000, titleClr, false, ''));
    shapes.push(PptxExporter.shapeXml(6, left, 1463040, contentW, 4480560, pts, false, 2000, bodyClr, true, ''));
    if (visual !== '') {
      shapes.push(PptxExporter.shapeXml(7, left, 6020000, contentW, 500000, [visual], false, 1400, '595959', false, ''));
    }
    return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n' +
      '<p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" ' +
      'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" ' +
      'xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">' +
      '<p:cSld name="Slide ' + index + '"><p:bg><p:bgPr><a:solidFill><a:srgbClr val="' + bgClr + '"/>' +
      '</a:solidFill></p:bgPr></p:bg><p:spTree>' +
      '<p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvSpPr/><p:nvPr/></p:nvGrpSpPr>' +
      '<p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/>' +
      '<a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>' +
      shapes.join('') + '</p:spTree></p:cSld>' +
      '<p:transition spd="med"><p:fade/></p:transition>' +
      '<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>';
  }
}
