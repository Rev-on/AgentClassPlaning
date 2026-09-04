/**
 * 排座位表：输入学生身高与座位布局（排数 × 每排人数）
 *  可选：讲台两边有座位（+2 座：最矮两人坐讲台左、右）
 *  - 优化贪心：身高升序 → 蛇形填充（同排相邻差最小）→ 逐列前后排矫正（前排不高于后排）迭代至稳定
 *  - 生成后可点击两个座位互换两人（再次点击同一座位取消选中）
 *  - 支持复制 / 导出 Word / 保存到历史（Markdown 表格）
 */
import pasteboard from '@ohos.pasteboard';
import promptAction from '@ohos.promptAction';
import common from '@ohos.app.ability.common';
import { I18n } from '../common/I18n';
import { AppTheme } from '../common/AppTheme';
import { HistoryStore } from '../common/HistoryStore';
import { DocxExporter } from '../common/DocxExporter';
import { PageHeader } from '../common/components/PageHeader';

/** 一名学生的数据 */
interface SeatStudent {
  name: string;
  height: number;
}

/** 排座算法（优化贪心） */
class SeatsAlgorithm {
  /** 从文本解析学生列表（每行：姓名 身高cm，空白分隔） */
  static parse(text: string): SeatStudent[] {
    const list: SeatStudent[] = [];
    const lines: string[] = text.split('\n');
    for (let i = 0; i < lines.length; i++) {
      const line: string = lines[i].trim();
      if (line === '') {
        continue;
      }
      const parts: string[] = line.split(/[\s，,、]+/);
      if (parts.length < 2) {
        continue;
      }
      const h: number = parseInt(parts[parts.length - 1]);
      if (isNaN(h) || h <= 0) {
        continue;
      }
      const name: string = parts.slice(0, parts.length - 1).join(' ');
      list.push({ name: name, height: h });
    }
    return list;
  }

  /** 身高升序（同身高按姓名稳定排序） */
  static sortAsc(list: SeatStudent[]): SeatStudent[] {
    const sorted: SeatStudent[] = list.slice();
    sorted.sort((a: SeatStudent, b: SeatStudent) => {
      if (a.height !== b.height) {
        return a.height - b.height;
      }
      return a.name < b.name ? -1 : 1;
    });
    return sorted;
  }

  /** 生成最优座位表（格内容：姓名|身高；返回 rows×cols） */
  static build(list: SeatStudent[], rows: number, cols: number): string[][] {
    const grid: string[][] = [];
    for (let r = 0; r < rows; r++) {
      const row: string[] = [];
      for (let c = 0; c < cols; c++) {
        row.push('');
      }
      grid.push(row);
    }
    // 1) 身高升序
    const sorted: SeatStudent[] = SeatsAlgorithm.sortAsc(list);
    // 2) 蛇形填充：偶排左→右，奇排右→左，保证同排左右相邻身高差最小
    let idx: number = 0;
    for (let r = 0; r < rows; r++) {
      if (r % 2 === 0) {
        for (let c = 0; c < cols && idx < sorted.length; c++) {
          grid[r][c] = sorted[idx].name + '|' + sorted[idx].height;
          idx++;
        }
      } else {
        for (let c = cols - 1; c >= 0 && idx < sorted.length; c--) {
          grid[r][c] = sorted[idx].name + '|' + sorted[idx].height;
          idx++;
        }
      }
    }
    // 3) 局部矫正：逐列检查相邻两排，若前排高于后排则交换（迭代至无交换）
    const heightOf = (cell: string): number => {
      const p: string[] = cell.split('|');
      if (p.length < 2) {
        return -1;
      }
      return parseInt(p[1]);
    };
    let changed: boolean = true;
    let round: number = 0;
    while (changed && round < rows) {
      changed = false;
      for (let r = 0; r < rows - 1; r++) {
        for (let c = 0; c < cols; c++) {
          const hf: number = heightOf(grid[r][c]);
          const hb: number = heightOf(grid[r + 1][c]);
          if (hf < 0 || hb < 0) {
            continue;
          }
          if (hf > hb) {
            const tmp: string = grid[r][c];
            grid[r][c] = grid[r + 1][c];
            grid[r + 1][c] = tmp;
            changed = true;
          }
        }
      }
      round++;
    }
    return grid;
  }

  /** 座位表转 Markdown 表格 */
  static toMarkdown(grid: string[][], rows: number, cols: number): string {
    let md: string = '| 排\\座 |';
    for (let c = 1; c <= cols; c++) {
      md += ' ' + c + ' |';
    }
    md += '\n| --- |';
    for (let c = 1; c <= cols; c++) {
      md += ' --- |';
    }
    for (let r = 0; r < rows; r++) {
      md += '\n| ' + (r + 1) + ' |';
      for (let c = 0; c < cols; c++) {
        const cell: string = grid[r][c];
        if (cell === '') {
          md += ' - |';
        } else {
          const parts: string[] = cell.split('|');
          md += ' ' + parts[0] + '（' + parts[1] + 'cm） |';
        }
      }
    }
    return md;
  }
}

@Entry
@Component
struct Seats {
  @State rowsText: string = '8';
  @State colsText: string = '6';
  @State studentText: string = '';
  @State grid: string[][] = [];
  /** 是否启用"讲台两边有座位"（额外 2 座：讲台左、右） */
  @State sideOn: boolean = false;
  /** 讲台两侧座位内容：index 0=左侧、1=右侧 */
  @State sideCells: string[] = ['', ''];
  /** 左/右护法位指定学生（空=自动安排） */
  @State sideLName: string = '';
  @State sideRName: string = '';
  /** 已选中座位（-1 表示未选中；r=-1 表示讲台侧座） */
  @State sR: number = -1;
  @State sC: number = -1;
  @StorageProp('appLang') appLang: string = 'zh';
  @StorageProp('appResolvedTheme') resolvedTheme: string = 'light';

  private t(key: string): string {
    void this.appLang;
    return I18n.t(key);
  }

  private col(key: string): string {
    void this.resolvedTheme;
    return AppTheme.color(key, this.resolvedTheme);
  }

  private rows(): number {
    return parseInt(this.rowsText);
  }

  private cols(): number {
    return parseInt(this.colsText);
  }

  /** 列下标数组（供 ForEach 使用） */
  private colIndices(): number[] {
    const n: number = this.cols();
    const arr: number[] = [];
    for (let i = 0; i < n; i++) {
      arr.push(i);
    }
    return arr;
  }

  private hasGrid(): boolean {
    return this.grid.length > 0 || this.sideCells[0] !== '' || this.sideCells[1] !== '';
  }

  /** 生成座位表：网格用身高名单按 rows×cols 排座（护法位不占名额、不参与排座）；
   *  左右护法直接显示用户输入的姓名（不查名单、不自动补位） */
  private generateSeats(): void {
    const rows: number = this.rows();
    const cols: number = this.cols();
    if (isNaN(rows) || isNaN(cols) || rows <= 0 || cols <= 0 || rows > 20 || cols > 15) {
      promptAction.showToast({ message: this.t('seats.errLayout') });
      return;
    }
    const list: SeatStudent[] = SeatsAlgorithm.parse(this.studentText);
    const total: number = rows * cols;
    // 学生多于网格座位时提示；少于时允许，多余座位（后排）留空
    if (list.length > total) {
      promptAction.showToast({
        message: this.t('seats.errCount')
          .replace('{n}', list.length.toString())
          .replace('{m}', total.toString())
      });
      return;
    }
    // 左右护法位直接采用用户输入姓名（可不在身高名单中）
    const lName: string = this.sideOn ? this.sideLName.trim() : '';
    const rName: string = this.sideOn ? this.sideRName.trim() : '';
    if (lName !== '' && lName === rName) {
      promptAction.showToast({ message: this.t('seats.errSame') });
      return;
    }
    this.sideCells = [lName, rName];
    this.grid = SeatsAlgorithm.build(list, rows, cols);
    this.sR = -1;
    this.sC = -1;
  }

  /** 修改护法姓名时：若已有结果且输入合法则自动重新生成，否则清空提示 */
  private autoRegen(): void {
    if (!this.hasGrid()) {
      return;
    }
    const rows: number = this.rows();
    const cols: number = this.cols();
    const list: SeatStudent[] = SeatsAlgorithm.parse(this.studentText);
    if (!isNaN(rows) && rows > 0 && !isNaN(cols) && cols > 0 && list.length <= rows * cols) {
      this.generateSeats();
      return;
    }
    this.grid = [];
    this.sideCells = ['', ''];
    this.sR = -1;
    this.sC = -1;
    promptAction.showToast({ message: this.t('seats.regen') });
  }

  /** 统一取座位内容：r=-1 取讲台侧座（c=0 左、c=1 右），否则取网格 */
  private cellOf(r: number, c: number): string {
    if (r < 0) {
      if (c >= 0 && c < this.sideCells.length) {
        return this.sideCells[c];
      }
      return '';
    }
    if (r < this.grid.length && c < this.grid[r].length) {
      return this.grid[r][c];
    }
    return '';
  }

  /** 统一写座位内容 */
  private setCell(r: number, c: number, v: string): void {
    if (r < 0) {
      const next: string[] = [this.sideCells[0], this.sideCells[1]];
      next[c] = v;
      this.sideCells = next;
      return;
    }
    const next: string[][] = [];
    for (let i = 0; i < this.grid.length; i++) {
      const row: string[] = [];
      for (let j = 0; j < this.grid[i].length; j++) {
        row.push(this.grid[i][j]);
      }
      next.push(row);
    }
    next[r][c] = v;
    this.grid = next;
  }

  /** 点击座位：第一次选中，第二次与已选中互换（同一座位取消） */
  private onSeatTap(r: number, c: number): void {
    if (this.sR === -1 && this.sC === -1) {
      this.sR = r;
      this.sC = c;
      return;
    }
    if (this.sR === r && this.sC === c) {
      this.sR = -1;
      this.sC = -1;
      return;
    }
    // 互换两人（支持讲台侧座与网格座位互換）
    const tmp: string = this.cellOf(this.sR, this.sC);
    this.setCell(this.sR, this.sC, this.cellOf(r, c));
    this.setCell(r, c, tmp);
    this.sR = -1;
    this.sC = -1;
  }

  private clearSelect(): void {
    this.sR = -1;
    this.sC = -1;
  }

  private resultText(): string {
    let txt: string = '';
    if (this.sideOn) {
      const l: string = this.sideCells[0];
      const r: string = this.sideCells[1];
      txt += this.t('seats.sideL') + ': ' + (l === '' ? '-' : l) + '\n';
      txt += this.t('seats.sideR') + ': ' + (r === '' ? '-' : r) + '\n';
    }
    return txt + SeatsAlgorithm.toMarkdown(this.grid, this.grid.length, this.grid[0].length);
  }

  private copyResult(): void {
    if (!this.hasGrid()) {
      return;
    }
    const sysPaste = pasteboard.getSystemPasteboard();
    const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.resultText());
    sysPaste.setData(data).then(() => {
      promptAction.showToast({ message: I18n.t('toast.copied') });
    }).catch(() => {
      promptAction.showToast({ message: this.appLang === 'en' ? 'Copy failed' : '复制失败' });
    });
  }

  private exportWord(): void {
    if (!this.hasGrid()) {
      return;
    }
    const ctx = getContext(this) as common.UIAbilityContext;
    DocxExporter.exportDocx(ctx, this.resultText(), this.t('seats.copyName') + '-' + this.rows() + 'x' + this.cols() + '.docx')
      .catch((err: Error) => {
        promptAction.showToast({ message: (this.appLang === 'en' ? 'Export failed: ' : '导出失败：') + err.message });
      });
  }

  private saveHistory(): void {
    if (!this.hasGrid()) {
      return;
    }
    const ctx = getContext(this) as common.UIAbilityContext;
    const typeLabel: string = I18n.t('page.seats');
    HistoryStore.addRecord(ctx, {
      type: typeLabel,
      title: typeLabel + '-' + this.rows() + 'x' + this.cols(),
      content: this.resultText(),
      time: HistoryStore.formatNow()
    }).then(() => {
      promptAction.showToast({ message: I18n.t('toast.saved') });
    });
  }

  private cellName(r: number, c: number): string {
    const cell: string = this.cellOf(r, c);
    if (cell === '') {
      return '';
    }
    return cell.split('|')[0];
  }

  private cellHeight(r: number, c: number): string {
    const cell: string = this.cellOf(r, c);
    if (cell === '') {
      return '';
    }
    const parts: string[] = cell.split('|');
    return parts.length > 1 ? parts[1] : '';
  }

  private cellSelected(r: number, c: number): boolean {
    return this.sR === r && this.sC === c;
  }

  /** 单个座位卡片 */
  @Builder
  seatCell(r: number, c: number) {
    Column({ space: 1 }) {
      Text(this.cellName(r, c))
        .fontSize(11)
        .fontWeight(this.cellSelected(r, c) ? FontWeight.Bold : FontWeight.Medium)
        .fontColor(this.cellSelected(r, c) ? '#FFFFFF' : this.col('title'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(this.cellHeight(r, c) === '' ? '' : this.cellHeight(r, c) + 'cm')
        .fontSize(9)
        .fontColor(this.cellSelected(r, c) ? '#E6F0FF' : this.col('hint'))
    }
    .layoutWeight(1)
    .padding({ top: 5, bottom: 5, left: 2, right: 2 })
    .margin(2)
    .borderRadius(8)
    .backgroundColor(this.cellSelected(r, c) ? '#4A90D9' : this.col('card'))
    .border({ width: 1, color: this.cellSelected(r, c) ? '#4A90D9' : this.col('line') })
    .onClick(() => this.onSeatTap(r, c))
  }

  @Builder
  seatRow(r: number) {
    Row() {
      ForEach(this.colIndices(), (c: number) => {
        this.seatCell(r, c)
      }, (c: number) => c.toString())
    }
    .width('100%')
  }

  /** 讲台两侧行：左座 | 讲台 | 右座 */
  @Builder
  sideRow() {
    Row({ space: 6 }) {
      this.seatCell(-1, 0)
      Column() {
        Text(this.t('seats.podium'))
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.col('codeText'))
      }
      .layoutWeight(1.6)
      .justifyContent(FlexAlign.Center)
      .height(46)
      .borderRadius(10)
      .backgroundColor(this.col('codeBg'))
      this.seatCell(-1, 1)
    }
    .width('100%')
    .padding(6)
    .backgroundColor(this.col('card'))
    .borderRadius(14)
  }

  build() {
    Column({ space: 0 }) {
      PageHeader({ title: this.t('page.seats') })

      Scroll() {
        Column({ space: 12 }) {
          // 算法说明
          Text(this.t('seats.algo'))
            .fontSize(12)
            .fontColor(this.col('hint'))
            .width('100%')
            .lineHeight(18)

          // 布局设置
          Column({ space: 10 }) {
            Row({ space: 10 }) {
              Text(this.t('seats.rows')).fontSize(15).fontColor(this.col('title')).width(92)
              TextInput({ text: this.rowsText, placeholder: '8' })
                .type(InputType.Number)
                .layoutWeight(1)
                .onChange((v: string) => { this.rowsText = v; })
            }
            Row({ space: 10 }) {
              Text(this.t('seats.cols')).fontSize(15).fontColor(this.col('title')).width(92)
              TextInput({ text: this.colsText, placeholder: '6' })
                .type(InputType.Number)
                .layoutWeight(1)
                .onChange((v: string) => { this.colsText = v; })
            }
            Row({ space: 8 }) {
              Checkbox()
                .select(this.sideOn)
                .selectedColor('#D97706')
                .onChange((v: boolean) => {
                  this.sideOn = v;
                  this.autoRegen();
                })
              Text(this.t('seats.side'))
                .fontSize(14)
                .fontColor(this.col('title'))
            }
            .width('100%')

            if (this.sideOn) {
              Row({ space: 10 }) {
                Text(this.t('seats.sideL')).fontSize(14).fontColor(this.col('title')).width(88)
                TextInput({ text: this.sideLName, placeholder: this.t('seats.phSide') })
                  .layoutWeight(1)
                  .backgroundColor(this.col('inputBg'))
                  .fontColor(this.col('text'))
                  .placeholderColor(this.col('hint'))
                  .onChange((v: string) => {
                    this.sideLName = v;
                    this.autoRegen();
                  })
              }
              .width('100%')
              Row({ space: 10 }) {
                Text(this.t('seats.sideR')).fontSize(14).fontColor(this.col('title')).width(88)
                TextInput({ text: this.sideRName, placeholder: this.t('seats.phSide') })
                  .layoutWeight(1)
                  .backgroundColor(this.col('inputBg'))
                  .fontColor(this.col('text'))
                  .placeholderColor(this.col('hint'))
                  .onChange((v: string) => {
                    this.sideRName = v;
                    this.autoRegen();
                  })
              }
              .width('100%')
            }
            Text(this.t('seats.students')).fontSize(15).fontColor(this.col('title')).width('100%')
            TextArea({ text: this.studentText, placeholder: this.t('seats.phStudents') })
              .width('100%')
              .height(140)
              .backgroundColor(this.col('inputBg'))
              .fontColor(this.col('text'))
              .placeholderColor(this.col('hint'))
              .onChange((v: string) => { this.studentText = v; })
            Button(this.t('seats.gen'))
              .width('100%')
              .height(42)
              .backgroundColor('#D97706')
              .onClick(() => this.generateSeats())
          }
          .width('100%')
          .padding(14)
          .backgroundColor(this.col('card'))
          .borderRadius(14)
          .alignItems(HorizontalAlign.Start)

          // 座位表
          if (this.hasGrid()) {
            Column({ space: 8 }) {
              if (this.sideOn) {
                this.sideRow()
              } else {
                Text(this.t('seats.podium'))
                  .fontSize(12)
                  .fontColor(this.col('codeText'))
                  .backgroundColor(this.col('codeBg'))
                  .borderRadius(10)
                  .padding({ left: 20, right: 20, top: 4, bottom: 4 })
              }

              Column({ space: 4 }) {
                ForEach(this.grid, (row: string[], r: number) => {
                  this.seatRow(r)
                }, (row: string[], r: number) => 'r' + r)
              }
              .width('100%')
              .padding(8)
              .backgroundColor(this.col('card'))
              .borderRadius(14)

              Text(this.t('seats.tip'))
                .fontSize(12)
                .fontColor(this.col('hint'))
                .width('100%')

              // 结果操作
              Row({ space: 8 }) {
                Button(this.t('btn.copy'))
                  .fontSize(13)
                  .height(32)
                  .layoutWeight(1)
                  .backgroundColor('#4A90D9')
                  .onClick(() => this.copyResult())
                Button(this.t('btn.exportWord'))
                  .fontSize(13)
                  .height(32)
                  .layoutWeight(1)
                  .backgroundColor('#2F6DB5')
                  .onClick(() => this.exportWord())
                Button(this.t('btn.saveHist'))
                  .fontSize(13)
                  .height(32)
                  .layoutWeight(1)
                  .backgroundColor('#5BA8A0')
                  .onClick(() => this.saveHistory())
              }
              .width('100%')
            }
            .width('100%')
          }
        }
        .width('100%')
        .padding(16)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      .backgroundColor(this.col('bg'))
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.col('bg'))
  }
}
