/**
 * Excel 数据解析器（零第三方依赖）
 * 用户在 Excel 中复制数据区域（Ctrl+C）后粘贴到 App（Ctrl+V / 长按粘贴），
 * 粘贴内容为 Tab 分隔文本，此处解析为结构化表格，并转为 AI 可读的 JSON。
 * 【隐私】转 JSON 有两条路径：toJson（原文，仅本地用途）与
 * toJsonMasked（按列脱敏姓名列，**发给 AI 的唯一路径**，见下方注释）。
 */
import { NameMask, NameMaskSession, TableMaskResult } from './NameMask';

export class ExcelParser {
  /**
   * 解析 Tab 分隔文本为二维表格
   * 第一行为表头，其余为数据行；自动忽略空行
   */
  static parse(text: string): string[][] {
    const rows: string[][] = [];
    const lines: string[] = text.split(/\r?\n/);
    for (const line of lines) {
      const cells: string[] = line.split('\t').map((c: string) => c.trim());
      const joined: string = cells.join('');
      if (joined !== '') {
        rows.push(cells);
      }
    }
    return rows;
  }

  /** 转为 AI 分析用 JSON（表头 + 学生记录数组） */
  static toJson(rows: string[][]): string {
    if (rows.length === 0) {
      return '{}';
    }
    const headers: string[] = rows[0];
    const students: Record<string, string>[] = [];
    for (let i: number = 1; i < rows.length; i++) {
      const obj: Record<string, string> = {};
      for (let j: number = 0; j < headers.length; j++) {
        obj[headers[j]] = rows[i][j] !== undefined ? rows[i][j] : '';
      }
      students.push(obj);
    }
    return JSON.stringify({ headers: headers, students: students });
  }

  /** 按列脱敏后的表格 JSON（发往 AI 的唯一路径；语义与 toJson 完全一致，只是姓名列被换成编号） */
  static toJsonOf(rows: string[][]): string {
    if (rows.length === 0) {
      return '{}';
    }
    const headers: string[] = rows[0];
    const students: Record<string, string>[] = [];
    for (let i: number = 1; i < rows.length; i++) {
      const obj: Record<string, string> = {};
      for (let j: number = 0; j < headers.length; j++) {
        obj[headers[j]] = rows[i][j] !== undefined ? rows[i][j] : '';
      }
      students.push(obj);
    }
    return JSON.stringify({ headers: headers, students: students });
  }

  /**
   * 【隐私安全】把成绩表格转为"已脱敏"的 AI 可读 JSON。
   *
   * 为什么必须在这里按列处理，而不是页面里对 JSON 串做整体替换：
   *   ① 姓名列是**列语义**，只有拿到表头才能可靠识别。对整串做无差别替换会把
   *      "优/良/及格"这类成绩等级、学号数字一起改掉，AI 收到错数据、还原后
   *      也与原文对不上；
   *   ② 姓名一旦被替换，**表头里"姓名"这个键名要保留**：AI 需要知道这一列
   *      代表学生（值为编号 S001），否则会困惑于"数据里没有学生标识"。
   *
   * 与原 toJson 的**唯一差异**：姓名列的单元格值由真实姓名变为编号（S001…）。
   * 其余列逐字节保持原样（含列顺序、表头文字、数值格式）。
   *
   * @param sess 本次生成的脱敏会话（映射表只在内存，见 NameMask 文件头）
   * @param rows 表格（rows[0] 为表头）
   * @param requireNameColumn true 时未识别到姓名列即抛错（fail-closed）；
   *        默认 false —— 无姓名列的统计表是合法输入，此时 masked=false，
   *        由页面用 I18n 提示老师"未识别到姓名列"（见 Analysis.generate）。
   */
  static toJsonMasked(sess: NameMaskSession, rows: string[][],
    requireNameColumn: boolean = false): TableMaskResult {
    const res: TableMaskResult = NameMask.maskTable(sess, rows,
      { requireNameColumn: requireNameColumn });
    const out: TableMaskResult = {
      rows: res.rows,
      nameColumns: res.nameColumns,
      masked: res.masked
    };
    return out;
  }

  /**
   * 【隐私安全】脱敏 + 序列化一步到位：返回可直接拼进 prompt 的 JSON 字符串。
   *
   * 这是 Analysis 页面**唯一**允许把表格交给 AI 的入口：
   * 调用方拿到字符串后不应再做任何"还原成原文"的操作。
   *
   * @param maskedOut 出参：写出本次实际使用的表格脱敏结果（供诊断/还原）
   */
  static toJsonMaskedText(sess: NameMaskSession, rows: string[][],
    maskedOut: TableMaskResult, requireNameColumn: boolean = false): string {
    const res: TableMaskResult = ExcelParser.toJsonMasked(sess, rows, requireNameColumn);
    maskedOut.rows = res.rows;
    maskedOut.nameColumns = res.nameColumns;
    maskedOut.masked = res.masked;
    return ExcelParser.toJsonOf(res.rows);
  }
}
