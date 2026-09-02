/**
 * Excel 数据解析器（零第三方依赖）
 * 用户在 Excel 中复制数据区域（Ctrl+C）后粘贴到 App（Ctrl+V / 长按粘贴），
 * 粘贴内容为 Tab 分隔文本，此处解析为结构化表格，并转为 AI 可读的 JSON。
 */
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
}
