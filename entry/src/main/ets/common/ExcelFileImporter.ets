/**
 * Excel 文件导入器：选择 .xlsx 文件并解析为二维表格
 * 依赖 @archermind/exceljs（已在项目 oh-package.json5 中声明）
 */
import { picker, fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import ExcelJS from '@archermind/exceljs';

export class ExcelFileImporter {
  /**
   * 弹出文件选择器，选择并解析一个 .xlsx 文件
   * @returns 二维表格（第一行为表头）；取消选择或解析无数据时返回空数组
   */
  static async pickAndParse(context: common.UIAbilityContext): Promise<string[][]> {
    // 1. 选择文件（select 返回选中文件的 uri 列表）
    const documentPicker = new picker.DocumentViewPicker(context);
    const selectResult = await documentPicker.select({ maxSelectNumber: 1 });
    if (selectResult.length === 0) {
      return [];
    }
    const uri: string = selectResult[0];

    // 2. 读取文件内容
    const file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
    const stat = fs.statSync(file.fd);
    const buffer = new ArrayBuffer(stat.size);
    fs.readSync(file.fd, buffer);
    fs.closeSync(file);

    // 3. 用 ExcelJS 解析
    const workbook = new ExcelJS.Workbook();
    await workbook.xlsx.read(buffer);
    const sheet = workbook.getWorksheet(1);
    const rows: string[][] = [];
    if (sheet === undefined) {
      return rows;
    }
    sheet.eachRow((row, rowNumber: number) => {
      const cells: string[] = [];
      const values = row.values;
      if (Array.isArray(values)) {
        for (let i: number = 1; i < values.length; i++) {
          const v = values[i];
          if (v === null || v === undefined) {
            cells.push('');
          } else {
            cells.push(String(v));
          }
        }
      }
      rows.push(cells);
    });
    return rows;
  }

  /** 二维表格 → Tab 分隔文本（用于回显到输入框） */
  static toTabText(rows: string[][]): string {
    const lines: string[] = [];
    for (const row of rows) {
      lines.push(row.join('\t'));
    }
    return lines.join('\n');
  }
}
