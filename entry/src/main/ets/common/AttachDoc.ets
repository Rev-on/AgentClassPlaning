/**
 * 附件文本提取器：把常见文档转成纯文本，随任务一起发给模型
 *  - 纯文本类（txt/md/csv/json/xml/html/log/yaml 等）：UTF-8 直读
 *  - Word(.docx)：@ohos/jszip 解包 word/document.xml 提取段落
 *  - PPT(.pptx)：解包 ppt/slides/slideN.xml 按页提取
 *  - Excel(.xlsx/.xls)：@archermind/exceljs 逐行读取，制表符分隔
 *  - 其它二进制（pdf 等）：返回空串，由服务端按"仅文件名"提示模型
 */
import JSZip from '@ohos/jszip';
import ExcelJS from '@archermind/exceljs';
import { Utf8 } from './Utf8';

export class AttachDoc {
  /** 纯文本类扩展名 */
  private static readonly TEXT_EXT: string[] = [
    'txt', 'md', 'markdown', 'csv', 'tsv', 'json', 'xml', 'html', 'htm',
    'log', 'ini', 'cfg', 'conf', 'yml', 'yaml', 'sql'
  ];
  /** 单文档提取文本上限（避免超大文件撑爆请求体） */
  private static readonly MAX_CHARS: number = 60000;

  static extOf(name: string): string {
    const i: number = name.lastIndexOf('.');
    if (i < 0) {
      return '';
    }
    return name.substring(i + 1).toLowerCase();
  }

  static isImageExt(ext: string): boolean {
    return ext === 'png' || ext === 'jpg' || ext === 'jpeg' || ext === 'webp'
      || ext === 'bmp' || ext === 'gif' || ext === 'heic' || ext === 'heif';
  }

  static isTextExt(ext: string): boolean {
    for (let i: number = 0; i < AttachDoc.TEXT_EXT.length; i++) {
      if (AttachDoc.TEXT_EXT[i] === ext) {
        return true;
      }
    }
    return false;
  }

  static isOfficeExt(ext: string): boolean {
    return ext === 'docx' || ext === 'pptx' || ext === 'xlsx' || ext === 'xls';
  }

  /** 是否需要走"文本提取"（纯文本 / Office） */
  static isExtractable(ext: string): boolean {
    return AttachDoc.isTextExt(ext) || AttachDoc.isOfficeExt(ext);
  }

  /** 提取文档纯文本；无法解析返回空串 */
  static async extract(name: string, bytes: Uint8Array): Promise<string> {
    const ext: string = AttachDoc.extOf(name);
    try {
      let out: string = '';
      if (AttachDoc.isTextExt(ext)) {
        out = Utf8.decode(bytes);
      } else if (ext === 'docx') {
        out = await AttachDoc.fromDocx(bytes);
      } else if (ext === 'pptx') {
        out = await AttachDoc.fromPptx(bytes);
      } else if (ext === 'xlsx' || ext === 'xls') {
        out = await AttachDoc.fromExcel(bytes);
      }
      return AttachDoc.clamp(out);
    } catch (e) {
      return '';
    }
  }

  private static clamp(text: string): string {
    const t: string = text.trim();
    return t.length > AttachDoc.MAX_CHARS ? t.substring(0, AttachDoc.MAX_CHARS) : t;
  }

  /** docx -> 段落文本（保留换行与制表） */
  private static async fromDocx(bytes: Uint8Array): Promise<string> {
    const zip = await JSZip.loadAsync(bytes);
    const entry = zip.file('word/document.xml');
    if (entry === null) {
      return '';
    }
    const xml: string = await entry.async('string');
    let text: string = xml;
    text = text.replace(/<w:tab[^>]*\/>/g, '\t');
    text = text.replace(/<w:br[^>]*\/>/g, '\n');
    text = text.replace(/<\/w:p>/g, '\n');
    text = text.replace(/<w:t[^>]*>([^<]*)<\/w:t>/g, '$1');
    text = text.replace(/<[^>]+>/g, '');
    return AttachDoc.unescape(text);
  }

  /** pptx -> 按页提取文本（页间以分隔线标记） */
  private static async fromPptx(bytes: Uint8Array): Promise<string> {
    const zip = await JSZip.loadAsync(bytes);
    const slideNames: string[] = [];
    zip.forEach((path: string) => {
      if (/^ppt\/slides\/slide\d+\.xml$/.test(path)) {
        slideNames.push(path);
      }
    });
    slideNames.sort((a: string, b: string) => AttachDoc.slideIndex(a) - AttachDoc.slideIndex(b));
    const out: string[] = [];
    for (let i: number = 0; i < slideNames.length; i++) {
      const entry = zip.file(slideNames[i]);
      if (entry === null) {
        continue;
      }
      const xml: string = await entry.async('string');
      let text: string = xml;
      text = text.replace(/<\/a:p>/g, '\n');
      text = text.replace(/<a:br[^>]*\/>/g, '\n');
      text = text.replace(/<[^>]+>/g, '');
      const page: string = AttachDoc.unescape(text).trim();
      if (page !== '') {
        out.push('【第 ' + (i + 1) + ' 页】\n' + page);
      }
    }
    return out.join('\n\n');
  }

  private static slideIndex(path: string): number {
    const m = path.match(/slide(\d+)\.xml$/);
    return m === null ? 0 : Number(m[1]);
  }

  /** xlsx -> 逐行制表符分隔文本 */
  private static async fromExcel(bytes: Uint8Array): Promise<string> {
    const workbook = new ExcelJS.Workbook();
    await workbook.xlsx.read(bytes.buffer as ArrayBuffer);
    const out: string[] = [];
    workbook.eachSheet((sheet) => {
      const lines: string[] = [];
      sheet.eachRow((row) => {
        const cells: string[] = [];
        const values = row.values;
        if (Array.isArray(values)) {
          for (let i: number = 1; i < values.length; i++) {
            const v = values[i];
            cells.push(v === null || v === undefined ? '' : String(v).trim());
          }
        }
        const line: string = cells.join('\t').replace(/\t+$/, '');
        if (line.trim() !== '') {
          lines.push(line);
        }
      });
      if (lines.length > 0) {
        out.push('【工作表：' + sheet.name + '】\n' + lines.join('\n'));
      }
    });
    return out.join('\n\n');
  }

  /** 还原 XML 实体 */
  private static unescape(text: string): string {
    return text
      .replace(/&lt;/g, '<')
      .replace(/&gt;/g, '>')
      .replace(/&quot;/g, '"')
      .replace(/&apos;/g, '\'')
      .replace(/&amp;/g, '&');
  }
}
