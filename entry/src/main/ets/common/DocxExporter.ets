/**
 * Word 导出器：把 AI 生成的 Markdown 结果导出为 docx 文档
 * 原理：Markdown 转 OOXML(WordprocessingML)，再由 jszip 打包为标准 docx
 * 支持标题、段落、列表、代码块（灰底等宽）、表格
 */
import { picker, fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import promptAction from '@ohos.promptAction';
import JSZip from '@ohos/jszip';

/** 块级元素（与渲染组件一致的简化结构） */
interface DocxBlock {
  kind: string;          // heading | paragraph | list | code | table
  level?: number;
  text?: string;
  ordered?: boolean;
  items?: string[];
  tableHeaders?: string[];
  tableRows?: string[][];
}

export class DocxExporter {

  /** 主入口：导出 Markdown 内容为 .docx（弹出保存位置选择） */
  static async exportDocx(context: common.UIAbilityContext, markdown: string, fileName: string): Promise<void> {
    // 1. Markdown → document.xml
    const documentXml: string = DocxExporter.buildDocumentXml(markdown);
    // 2. 组装 docx 包
    const zip = new JSZip();
    zip.file('[Content_Types].xml', DocxExporter.contentTypesXml());
    zip.file('_rels/.rels', DocxExporter.relsXml());
    zip.folder('word');
    zip.file('word/document.xml', documentXml);
    const buffer: ArrayBuffer = (await zip.generateAsync({
      type: 'arraybuffer',
      compression: 'DEFLATE'
    })) as ArrayBuffer;
    // 3. 选择保存位置并写入
    const savePicker = new picker.DocumentViewPicker(context);
    const saveOptions = new picker.DocumentSaveOptions();
    saveOptions.newFileNames = [fileName];
    saveOptions.fileSuffixChoices = ['.docx'];
    const saveResult = await savePicker.save(saveOptions);
    if (saveResult.length === 0) {
      return;
    }
    const uri: string = saveResult[0];
    const file = fs.openSync(uri, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    fs.writeSync(file.fd, buffer);
    fs.closeSync(file);
    promptAction.showToast({ message: '已导出：' + fileName });
  }

  /** 导出文本为 .json 文件：剥离 ```json 围栏与前后杂文，仅保留 JSON；合法则格式化缩进 */
  static async exportJson(context: common.UIAbilityContext, content: string, fileName: string): Promise<void> {
    let text: string = content.trim();
    // 去掉 ```json ... ``` 代码块围栏
    const fenceStart: number = text.indexOf('```');
    if (fenceStart >= 0) {
      const fenceEnd: number = text.lastIndexOf('```');
      if (fenceEnd > fenceStart) {
        text = text.substring(fenceStart + 3, fenceEnd).trim();
      }
    }
    // 只保留第一个 [ 到最后一个 ] 的 JSON 主体
    const s: number = text.indexOf('[');
    const e: number = text.lastIndexOf(']');
    if (s >= 0 && e > s) {
      text = text.substring(s, e + 1);
    }
    // 合法 JSON 则格式化（2 空格缩进），否则原样保存
    let pretty: string = text;
    try {
      pretty = JSON.stringify(JSON.parse(text), null, 2);
    } catch (err) {
      pretty = text;
    }
    const u8: Uint8Array = new util.TextEncoder().encodeInto(pretty);
    const buffer: ArrayBuffer = u8.buffer as ArrayBuffer;
    const savePicker = new picker.DocumentViewPicker(context);
    const saveOptions = new picker.DocumentSaveOptions();
    saveOptions.newFileNames = [fileName];
    // ArkUI-X 跨端：不设置 fileSuffixChoices（Android 侧不支持）
    const saveResult = await savePicker.save(saveOptions);
    if (saveResult.length === 0) {
      return;
    }
    const uri: string = saveResult[0];
    const file = fs.openSync(uri, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    fs.writeSync(file.fd, buffer);
    fs.closeSync(file);
    promptAction.showToast({ message: '已导出：' + fileName });
  }

  // ============ docx 固定结构 ============

  private static contentTypesXml(): string {
    return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n' +
      '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
      '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
      '<Default Extension="xml" ContentType="application/xml"/>' +
      '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>' +
      '</Types>';
  }

  private static relsXml(): string {
    return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n' +
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
      '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>' +
      '</Relationships>';
  }

  // ============ Markdown → document.xml ============

  private static buildDocumentXml(markdown: string): string {
    const bodyParts: string[] = [];
    for (const block of DocxExporter.parseBlocks(markdown)) {
      if (block.kind === 'heading') {
        bodyParts.push(DocxExporter.headingXml(block.level !== undefined ? block.level : 2,
          block.text !== undefined ? block.text : ''));
      } else if (block.kind === 'paragraph') {
        bodyParts.push(DocxExporter.paragraphXml(block.text !== undefined ? block.text : ''));
      } else if (block.kind === 'code') {
        bodyParts.push(DocxExporter.codeXml(block.text !== undefined ? block.text : ''));
      } else if (block.kind === 'list') {
        bodyParts.push(DocxExporter.listXml(
          block.items !== undefined ? block.items : [],
          block.ordered !== undefined ? block.ordered : false));
      } else if (block.kind === 'table') {
        bodyParts.push(DocxExporter.tableXml(
          block.tableHeaders !== undefined ? block.tableHeaders : [],
          block.tableRows !== undefined ? block.tableRows : []));
      }
    }
    bodyParts.push('<w:sectPr><w:pgSz w:w="11906" w:h="16838"/>' +
      '<w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440"/></w:sectPr>');
    return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n' +
      '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
      '<w:body>' + bodyParts.join('') + '</w:body></w:document>';
  }

  /** 块级解析（标题/段落/列表/代码块/表格） */
  private static parseBlocks(md: string): DocxBlock[] {
    const lines: string[] = md.split('\n');
    const blocks: DocxBlock[] = [];
    let i: number = 0;
    while (i < lines.length) {
      const line: string = lines[i].trimEnd();
      if (line.trim() === '') {
        i++;
        continue;
      }
      const h = line.match(/^(#{1,6})\s+(.*)$/);
      if (h !== null) {
        blocks.push({ kind: 'heading', level: h[1].length, text: DocxExporter.inline(h[2]) });
        i++;
        continue;
      }
      if (line.trim().startsWith('```')) {
        let code: string = '';
        i++;
        while (i < lines.length && !lines[i].trim().startsWith('```')) {
          code += lines[i] + '\n';
          i++;
        }
        i++;
        blocks.push({ kind: 'code', text: code.trimEnd() });
        continue;
      }
      if (DocxExporter.isTableRow(line)) {
        const tableLines: string[] = [line];
        i++;
        while (i < lines.length && DocxExporter.isTableRow(lines[i])) {
          tableLines.push(lines[i].trim());
          i++;
        }
        blocks.push(DocxExporter.buildTable(tableLines));
        continue;
      }
      const li = line.trim().match(/^([-*]|\d+\.)\s+(.*)$/);
      if (li !== null) {
        const ordered: boolean = li[1].indexOf('.') > 0;
        const items: string[] = [];
        while (i < lines.length) {
          const t: string = lines[i].trim();
          if (t === '') {
            i++;
            break;
          }
          const m = t.match(/^([-*]|\d+\.)\s+(.*)$/);
          if (m !== null) {
            items.push(DocxExporter.inline(m[2]));
            i++;
          } else {
            break;
          }
        }
        blocks.push({ kind: 'list', ordered: ordered, items: items });
        continue;
      }
      let para: string = line;
      i++;
      while (i < lines.length && lines[i].trim() !== '') {
        para += '\n' + lines[i];
        i++;
      }
      blocks.push({ kind: 'paragraph', text: DocxExporter.inline(para) });
    }
    return blocks;
  }

  /** 剥离行内标记 */
  private static inline(text: string): string {
    return text.replace(/\*\*([^*]+)\*\*/g, '$1').replace(/`([^`]+)`/g, '$1');
  }

  private static isTableRow(line: string): boolean {
    const t: string = line.trim();
    return t.startsWith('|') && t.includes('|');
  }

  private static buildTable(lines: string[]): DocxBlock {
    const split = (s: string): string[] =>
      s.trim().replace(/^\|/, '').replace(/\|$/, '').split('|').map((x: string) => x.trim());
    const headers: string[] = split(lines[0]);
    const rows: string[][] = [];
    for (let k: number = 1; k < lines.length; k++) {
      const t: string = lines[k].trim();
      if (t.indexOf('-') >= 0 && t.replace(/[|\s:\-]/g, '') === '') {
        continue;
      }
      rows.push(split(t));
    }
    return { kind: 'table', tableHeaders: headers, tableRows: rows };
  }

  // ============ XML 片段生成 ============

  private static escapeXml(text: string): string {
    return text
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }

  private static headingXml(level: number, text: string): string {
    const size: number = level <= 1 ? 36 : (level === 2 ? 32 : (level === 3 ? 28 : 24));
    return '<w:p><w:pPr><w:spacing w:before="240" w:after="120"/></w:pPr>' +
      '<w:r><w:rPr><w:b/><w:sz w:val="' + size + '"/><w:szCs w:val="' + size + '"/></w:rPr>' +
      '<w:t>' + DocxExporter.escapeXml(text) + '</w:t></w:r></w:p>';
  }

  private static paragraphXml(text: string): string {
    const lines: string[] = text.split('\n');
    const parts: string[] = [];
    for (const ln of lines) {
      parts.push('<w:p><w:pPr><w:spacing w:line="360" w:lineRule="auto"/></w:pPr>' +
        '<w:r><w:t>' + DocxExporter.escapeXml(ln) + '</w:t></w:r></w:p>');
    }
    return parts.join('');
  }

  private static codeXml(text: string): string {
    const lines: string[] = text.split('\n');
    const parts: string[] = [];
    for (const ln of lines) {
      parts.push('<w:p><w:pPr><w:shd w:val="clear" w:color="auto" w:fill="F2F2F2"/></w:pPr>' +
        '<w:r><w:rPr><w:rFonts w:ascii="Consolas" w:hAnsi="Consolas" w:eastAsia="宋体"/></w:rPr>' +
        '<w:t>' + DocxExporter.escapeXml(ln) + '</w:t></w:r></w:p>');
    }
    return parts.join('');
  }

  private static listXml(items: string[], ordered: boolean): string {
    const parts: string[] = [];
    for (let i: number = 0; i < items.length; i++) {
      const prefix: string = ordered ? ((i + 1) + '. ') : '• ';
      parts.push('<w:p><w:pPr><w:ind w:left="420"/><w:spacing w:line="320" w:lineRule="auto"/></w:pPr>' +
        '<w:r><w:t>' + DocxExporter.escapeXml(prefix + items[i]) + '</w:t></w:r></w:p>');
    }
    return parts.join('');
  }

  private static tableXml(headers: string[], rows: string[][]): string {
    const border: string = '<w:tblBorders>' +
      '<w:top w:val="single" w:sz="4" w:color="999999"/>' +
      '<w:left w:val="single" w:sz="4" w:color="999999"/>' +
      '<w:bottom w:val="single" w:sz="4" w:color="999999"/>' +
      '<w:right w:val="single" w:sz="4" w:color="999999"/>' +
      '<w:insideH w:val="single" w:sz="4" w:color="999999"/>' +
      '<w:insideV w:val="single" w:sz="4" w:color="999999"/>' +
      '</w:tblBorders>';
    const parts: string[] = ['<w:tbl><w:tblPr>' + border + '</w:tblPr>'];
    // 表头
    parts.push('<w:tr>');
    for (const h of headers) {
      parts.push('<w:tc><w:tcPr><w:shd w:val="clear" w:color="auto" w:fill="EDF2F9"/></w:tcPr>' +
        '<w:p><w:r><w:rPr><w:b/></w:rPr><w:t>' + DocxExporter.escapeXml(h) + '</w:t></w:r></w:p></w:tc>');
    }
    parts.push('</w:tr>');
    // 数据行
    for (const row of rows) {
      parts.push('<w:tr>');
      for (let c: number = 0; c < headers.length; c++) {
        const cellText: string = c < row.length ? row[c] : '';
        parts.push('<w:tc><w:p><w:r><w:t>' + DocxExporter.escapeXml(cellText) + '</w:t></w:r></w:p></w:tc>');
      }
      parts.push('</w:tr>');
    }
    parts.push('</w:tbl>');
    // 表格后加空段落
    parts.push('<w:p/>');
    return parts.join('');
  }
}
