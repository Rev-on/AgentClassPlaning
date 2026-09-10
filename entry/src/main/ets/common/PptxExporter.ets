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

  /** 导出课件大纲 JSON 为 .pptx 粗稿（选择保存位置） */
  static async exportPptx(context: common.UIAbilityContext, json: string, fileName: string): Promise<void> {
    const slides: CourseSlide[] | null = PptxExporter.parseSlides(json);
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
    // 6. 打包并保存
    const buffer: ArrayBuffer = (await zip.generateAsync({
      type: 'arraybuffer',
      compression: 'DEFLATE'
    })) as ArrayBuffer;
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
    lines: string[], bold: boolean, sz: number, color: string, prefix: boolean): string {
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
    return '<p:sp><p:nvSpPr><p:cNvPr id="' + id + '" name="Shape ' + id + '"/><p:cNvSpPr txBox="1"/><p:nvPr/>' +
      '</p:nvSpPr><p:spPr><a:xfrm><a:off x="' + x + '" y="' + y + '"/><a:ext cx="' + cx + '" cy="' + cy + '"/>' +
      '</a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/><a:ln><a:noFill/></a:ln></p:spPr>' +
      '<p:txBody><a:bodyPr wrap="square" anchor="t"><a:normAutofit/></a:bodyPr><a:lstStyle/>' +
      paras.join('') + '</p:txBody></p:sp>';
  }

  /** 单页幻灯片 XML */
  private static slideXml(slide: CourseSlide, index: number, total: number): string {
    const W: number = 12192000;
    const H: number = 6858000;
    const left: number = 548640;
    const contentW: number = W - 548640 * 2;
    // 角标行（页号·类型）
    const caption: string = I18n.t('cw.pageOf')
      .replace('{i}', index.toString()).replace('{t}', total.toString()) +
      (slide.type !== '' ? '  ·  ' + slide.type : '');
    // 标题
    const title: string = slide.title !== '' ? slide.title : I18n.t('cw.page').replace('{n}', index.toString());
    // 要点与底部配图方向
    const pts: string[] = slide.points.length > 0 ? slide.points.slice(0, 8) : [I18n.t('cw.noPointsDraft')];
    const visual: string = slide.visual !== '' ? I18n.t('cw.visual') + slide.visual : '';
    const shapes: string[] = [];
    shapes.push(PptxExporter.shapeXml(2, left, 182880, contentW, 228600, [caption], false, 1200, '7F7F7F', false));
    shapes.push(PptxExporter.shapeXml(3, left, 457200, contentW, 900000, [title], true, 3000, '000000', false));
    shapes.push(PptxExporter.shapeXml(4, left, 1463040, contentW, 4480560, pts, false, 2000, '000000', true));
    if (visual !== '') {
      shapes.push(PptxExporter.shapeXml(5, left, 6020000, contentW, 500000, [visual], false, 1400, '595959', false));
    }
    return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n' +
      '<p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" ' +
      'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" ' +
      'xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">' +
      '<p:cSld name="Slide ' + index + '"><p:bg><p:bgPr><a:solidFill><a:srgbClr val="FFFFFF"/>' +
      '</a:solidFill></p:bgPr></p:bg><p:spTree>' +
      '<p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>' +
      '<p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/>' +
      '<a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>' +
      shapes.join('') + '</p:spTree></p:cSld>' +
      '<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>';
  }
}
