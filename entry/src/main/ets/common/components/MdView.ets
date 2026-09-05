/**
 * 轻量 Markdown 渲染组件（零第三方依赖）
 * 支持标题、段落、列表、代码块、表格等块级结构
 * 行内样式以纯文本呈现，提示词模板已禁止 AI 输出行内标记
 */
import { AppTheme } from '../AppTheme';
import { AppFonts } from '../AppFonts';

/** 块级元素 */
interface MdBlock {
  kind: string;          // heading | paragraph | list | code | table
  level?: number;        // 标题级别
  text?: string;         // heading / paragraph / code 文本
  ordered?: boolean;     // 列表是否有序
  items?: string[];      // 列表项
  tableHeaders?: string[];
  tableRows?: string[][];
}

/** Markdown 解析器 */
class MdParser {
  /** 解析块级结构 */
  static parse(md: string): MdBlock[] {
    const lines: string[] = md.split('\n');
    const blocks: MdBlock[] = [];
    let i: number = 0;
    while (i < lines.length) {
      const line: string = lines[i].trimEnd();
      if (line.trim() === '') {
        i++;
        continue;
      }
      // 标题
      const h = line.match(/^(#{1,6})\s+(.*)$/);
      if (h !== null) {
        blocks.push({ kind: 'heading', level: h[1].length, text: MdParser.inline(h[2]) });
        i++;
        continue;
      }
      // 代码块
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
      // 表格
      if (MdParser.isTableRow(line)) {
        const tableLines: string[] = [line];
        i++;
        while (i < lines.length && MdParser.isTableRow(lines[i])) {
          tableLines.push(lines[i].trim());
          i++;
        }
        blocks.push(MdParser.buildTable(tableLines));
        continue;
      }
      // 列表
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
            items.push(MdParser.inline(m[2]));
            i++;
          } else {
            break;
          }
        }
        blocks.push({ kind: 'list', ordered: ordered, items: items });
        continue;
      }
      // 段落：合并到空行
      let para: string = line;
      i++;
      while (i < lines.length && lines[i].trim() !== '') {
        para += '\n' + lines[i];
        i++;
      }
      blocks.push({ kind: 'paragraph', text: MdParser.inline(para) });
    }
    return blocks;
  }

  /** 剥离行内标记：**粗体** 与 `行内代码` → 纯文本 */
  static inline(text: string): string {
    return text.replace(/\*\*([^*]+)\*\*/g, '$1').replace(/`([^`]+)`/g, '$1');
  }

  private static isTableRow(line: string): boolean {
    const t: string = line.trim();
    return t.startsWith('|') && t.includes('|');
  }

  private static buildTable(lines: string[]): MdBlock {
    const split = (s: string): string[] =>
      s.trim().replace(/^\|/, '').replace(/\|$/, '').split('|').map((x: string) => x.trim());
    const headers: string[] = split(lines[0]);
    const rows: string[][] = [];
    for (let k: number = 1; k < lines.length; k++) {
      const t: string = lines[k].trim();
      // 跳过 |---| 分隔行
      if (t.indexOf('-') >= 0 && t.replace(/[|\s:\-]/g, '') === '') {
        continue;
      }
      rows.push(split(t));
    }
    return { kind: 'table', tableHeaders: headers, tableRows: rows };
  }
}

/** Markdown 渲染组件 */
@Component
export struct MdView {
  @Prop markdown: string = '';
  @StorageProp('appResolvedTheme') resolvedTheme: string = 'light';

  private col(key: string): string {
    void this.resolvedTheme;
    return AppTheme.color(key, this.resolvedTheme);
  }

  private headingSize(level: number): number {
    if (level <= 1) {
      return 20;
    }
    if (level === 2) {
      return 18;
    }
    if (level === 3) {
      return 16;
    }
    return 15;
  }

  @Builder
  tableBlock(headers: string[], rows: string[][]) {
    Column() {
      Row() {
        ForEach(headers, (h: string) => {
          Text(h)
            .fontFamily(AppFonts.family())
            .fontSize(13)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.col('title'))
            .layoutWeight(1)
            .padding(6)
            .textAlign(TextAlign.Center)
        }, (h: string) => h)
      }
      .width('100%')
      .backgroundColor(this.col('headBg'))
      .borderRadius({ topLeft: 6, topRight: 6 })
      ForEach(rows, (row: string[]) => {
        Row() {
          ForEach(row, (c: string) => {
            Text(c)
              .fontFamily(AppFonts.family())
              .fontSize(13)
              .fontColor(this.col('text'))
              .layoutWeight(1)
              .padding(6)
              .textAlign(TextAlign.Center)
          }, (c: string, idx: number) => c + idx)
        }
        .width('100%')
        .border({ width: { top: 0.5 }, color: this.col('line') })
      }, (row: string[]) => row.join(','))
    }
    .width('100%')
    .border({ width: 1, color: this.col('line') })
    .borderRadius(6)
    .margin({ top: 4, bottom: 4 })
  }

  @Builder
  listItem(text: string, ordered: boolean, index: number) {
    Row({ space: 6 }) {
      Text(ordered ? (index + 1) + '.' : '•')
        .fontFamily(AppFonts.family())
        .fontSize(14)
        .fontColor('#4A90D9')
        .width(18)
      Text(text)
        .fontFamily(AppFonts.family())
        .fontSize(14)
        .fontColor(this.col('text'))
        .lineHeight(22)
        .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
  }

  build() {
    Column({ space: 8 }) {
      ForEach(MdParser.parse(this.markdown), (block: MdBlock, index: number) => {
        if (block.kind === 'heading') {
          Text(block.text !== undefined ? block.text : '')
            .fontFamily(AppFonts.family())
            .fontSize(this.headingSize(block.level !== undefined ? block.level : 2))
            .fontWeight(FontWeight.Bold)
            .fontColor(this.col('title'))
            .width('100%')
            .margin({ top: 6 })
        } else if (block.kind === 'paragraph') {
          Text(block.text !== undefined ? block.text : '')
            .fontFamily(AppFonts.family())
            .fontSize(15)
            .fontColor(this.col('text'))
            .lineHeight(24)
            .width('100%')
            .textSelectable(TextSelectableMode.SELECTABLE_UNFOCUSABLE)
        } else if (block.kind === 'code') {
          Text(block.text !== undefined ? block.text : '')
            .fontFamily(AppFonts.family())
            .fontSize(13)
            .fontColor(this.col('codeText'))
            .fontFamily('monospace')
            .lineHeight(20)
            .width('100%')
            .padding(10)
            .backgroundColor(this.col('codeBg'))
            .borderRadius(8)
            .textSelectable(TextSelectableMode.SELECTABLE_UNFOCUSABLE)
        } else if (block.kind === 'list') {
          Column({ space: 2 }) {
            ForEach(block.items !== undefined ? block.items : [], (item: string, li: number) => {
              this.listItem(item, block.ordered !== undefined ? block.ordered : false, li)
            }, (item: string) => item)
          }
          .width('100%')
          .margin({ top: 2, bottom: 2 })
        } else if (block.kind === 'table') {
          this.tableBlock(
            block.tableHeaders !== undefined ? block.tableHeaders : [],
            block.tableRows !== undefined ? block.tableRows : []
          )
        }
      }, (block: MdBlock, index: number) => block.kind + index)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
