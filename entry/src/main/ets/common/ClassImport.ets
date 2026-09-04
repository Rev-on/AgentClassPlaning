/**
 * 班级名单导入器：Excel(.xlsx) 与 Word(.docx)
 *  - Excel：@archermind/exceljs 逐行读取（自动识别表头行）
 *  - Word：@ohos/jszip 解包后从 word/document.xml 提取表格/段落文本
 *  - 行列识别：学号 | 姓名 | 身高 | 备注（学号、身高可省略；表头行自动跳过）
 */
import { picker, fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import ExcelJS from '@archermind/exceljs';
import JSZip from '@ohos/jszip';
import { StudentItem } from './ClassStore';

export class ClassImport {
  /** 选择文件并解析为学号/姓名/身高/备注 结构 */
  static async pickAndParse(context: common.UIAbilityContext): Promise<StudentItem[]> {
    const documentPicker = new picker.DocumentViewPicker(context);
    const selectResult = await documentPicker.select({ maxSelectNumber: 1 });
    if (selectResult.length === 0) {
      return [];
    }
    const uri: string = selectResult[0];
    const file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
    const stat = fs.statSync(file.fd);
    const buffer = new ArrayBuffer(stat.size);
    fs.readSync(file.fd, buffer);
    fs.closeSync(file);
    const name: string = uri.toLowerCase();
    if (name.endsWith('.xlsx') || name.endsWith('.xls')) {
      return ClassImport.parseExcel(buffer);
    }
    if (name.endsWith('.docx')) {
      return ClassImport.parseWord(buffer);
    }
    return [];
  }

  /** Excel：逐行读取单元格数组后统一按行列解析 */
  private static async parseExcel(buffer: ArrayBuffer): Promise<StudentItem[]> {
    const workbook = new ExcelJS.Workbook();
    await workbook.xlsx.read(buffer);
    const sheet = workbook.getWorksheet(1);
    const out: StudentItem[] = [];
    if (sheet === undefined) {
      return out;
    }
    sheet.eachRow((row) => {
      const cells: string[] = [];
      const values = row.values;
      if (Array.isArray(values)) {
        for (let i: number = 1; i < values.length; i++) {
          const v = values[i];
          cells.push(v === null || v === undefined ? '' : String(v).trim());
        }
      }
      const stu = ClassImport.parseCells(cells);
      if (stu !== null) {
        out.push(stu);
      }
    });
    return out;
  }

  /** Word：解包 docx 提取每行文本后解析 */
  private static async parseWord(buffer: ArrayBuffer): Promise<StudentItem[]> {
    const zip = await JSZip.loadAsync(buffer);
    const entry = zip.file('word/document.xml');
    if (entry === null) {
      return [];
    }
    const xml: string = await entry.async('string');
    // 制表符 → \t；w:t 文本取出；段落结束换行；其余标签剔除
    let text: string = xml;
    text = text.replace(/<w:tab[^>]*\/>/g, '\t');
    text = text.replace(/<w:br[^>]*\/>/g, '\n');
    text = text.replace(/<\/w:p>/g, '\n');
    text = text.replace(/<w:t[^>]*>([^<]*)<\/w:t>/g, '$1');
    text = text.replace(/<[^>]+>/g, '');
    const lines: string[] = text.split('\n');
    const out: StudentItem[] = [];
    for (let i = 0; i < lines.length; i++) {
      const line: string = lines[i].trim();
      if (line === '') {
        continue;
      }
      // 按空白/制表分隔为单元格
      const parts: string[] = line.split(/[\t ]+/);
      const stu = ClassImport.parseCells(parts);
      if (stu !== null) {
        out.push(stu);
      }
    }
    return out;
  }

  /** 判断文本是否"像学号"（数字开头或纯数字串） */
  private static isNoLike(s: string): boolean {
    if (s === '') {
      return false;
    }
    const first: string = s.charAt(0);
    return first >= '0' && first <= '9';
  }

  /** 判断是否表头行 */
  private static isHeader(cells: string[]): boolean {
    const joined: string = cells.join(' ');
    if (joined.indexOf('学号') >= 0 || joined.indexOf('姓名') >= 0 || joined.indexOf('编号') >= 0) {
      return true;
    }
    const lower: string = joined.toLowerCase();
    return lower.indexOf('name') >= 0 || lower.indexOf('no.') >= 0 || lower.indexOf('id') >= 0;
  }

  /** 单元格数组 → 学生（学号|姓名|身高|备注）；识别失败返回 null */
  private static parseCells(cells: string[]): StudentItem | null {
    const c: string[] = [];
    for (let i = 0; i < cells.length; i++) {
      const s: string = cells[i].trim();
      if (s !== '') {
        c.push(s);
      }
    }
    if (c.length === 0) {
      return null;
    }
    if (ClassImport.isHeader(c)) {
      return null;
    }
    let rest: string[] = [];
    let no: string = '';
    if (ClassImport.isNoLike(c[0])) {
      no = c[0];
      rest = c.slice(1);
    } else {
      rest = c;
    }
    if (rest.length === 0) {
      return null;
    }
    // 第一段为姓名
    const name: string = rest[0];
    if (name === '' || ClassImport.isNoLike(name)) {
      return null;
    }
    let height: string = '';
    const notes: string[] = [];
    for (let i = 1; i < rest.length; i++) {
      const token: string = rest[i];
      const v: number = parseInt(token);
      if (height === '' && !isNaN(v) && v >= 80 && v <= 230) {
        height = token;
      } else {
        notes.push(token);
      }
    }
    return { no: no, name: name, height: height, note: notes.join(' ') };
  }
}
