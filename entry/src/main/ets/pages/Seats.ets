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
import { AppFonts } from '../common/AppFonts';
import { HistoryStore } from '../common/HistoryStore';
import { DocxExporter } from '../common/DocxExporter';
import { ClassStore, ClassItem, StudentItem } from '../common/ClassStore';
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

@Component
export struct SeatsContent {
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
  /** 名单联动：0=关闭，1=导入班级名单，2=保存到班级名单 */
  @State rosterMode: number = 0;
  @State classes: ClassItem[] = [];
  /** 选中班级下标：保存模式等于 classes.length 表示新建班级 */
  @State pickIdx: number = -1;
  @State newClassName: string = '';
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

  // ============ 班级名单联动 ============

  /** 从当前输入文本解析（供保存名单使用） */
  private parseStudents(): SeatStudent[] {
    return SeatsAlgorithm.parse(this.studentText);
  }

  private async reloadClasses(): Promise<void> {
    const ctx = getContext(this) as common.UIAbilityContext;
    this.classes = await ClassStore.loadAll(ctx);
  }

  /** 打开导入面板 */
  private async openImport(): Promise<void> {
    this.rosterMode = 1;
    this.pickIdx = -1;
    await this.reloadClasses();
    if (this.classes.length === 0) {
      this.rosterMode = 0;
      promptAction.showToast({ message: this.t('seats.noClass') });
    }
  }

  /** 打开保存面板 */
  private async openSave(): Promise<void> {
    this.rosterMode = 2;
    this.pickIdx = -1;
    this.newClassName = '';
    await this.reloadClasses();
    if (this.classes.length === 0) {
      // 无班级时直接退化为“新建班级”模式
      this.pickIdx = 0;
    }
  }

  private closeRoster(): void {
    this.rosterMode = 0;
    this.pickIdx = -1;
  }

  /** 班级选择项（导入模式不含新建项） */
  private classOptions(): SelectOption[] {
    const opts: SelectOption[] = [];
    for (let i = 0; i < this.classes.length; i++) {
      const opt: SelectOption = { value: this.classes[i].name };
      opts.push(opt);
    }
    if (this.rosterMode === 2) {
      const opt: SelectOption = { value: this.t('seats.newClass') };
      opts.push(opt);
    }
    return opts;
  }

  /** 当前选择显示文案 */
  private pickLabel(): string {
    if (this.pickIdx >= 0 && this.pickIdx < this.classes.length) {
      return this.classes[this.pickIdx].name;
    }
    if (this.pickIdx === this.classes.length && this.rosterMode === 2) {
      return this.t('seats.newClass');
    }
    return this.classOptions().length > 0 ? (this.classOptions()[0].value as string) : '';
  }

  /** 是否处于“保存到新建班级” */
  private isNewTarget(): boolean {
    return this.rosterMode === 2 && this.classes.length === 0 ||
      (this.rosterMode === 2 && this.pickIdx === this.classes.length);
  }

  /** 一键导入：所选班级学生（有身高）填入名单框 */
  private doImport(): void {
    if (this.pickIdx < 0 || this.pickIdx >= this.classes.length) {
      promptAction.showToast({ message: this.t('seats.classNeed') });
      return;
    }
    const item: ClassItem = this.classes[this.pickIdx];
    const lines: string[] = [];
    let skip: number = 0;
    for (let i = 0; i < item.students.length; i++) {
      const st: StudentItem = item.students[i];
      const h: number = parseInt(st.height);
      if (!isNaN(h) && h > 0) {
        lines.push(st.name.trim() + ' ' + h);
      } else {
        skip++;
      }
    }
    this.studentText = lines.join('\n');
    let msg: string = this.t('seats.imported')
      .replace('{n}', lines.length.toString())
      .replace('{extra}', '');
    if (skip > 0) {
      msg += this.t('seats.skipH').replace('{n}', skip.toString());
    }
    this.closeRoster();
    promptAction.showToast({ message: msg });
  }

  /** 由当前名单文本生成 StudentItem[]：已有班级同名学生更新身高，新学生追加并自动补学号 */
  private buildRoster(list: SeatStudent[], old: StudentItem[]): StudentItem[] {
    const out: StudentItem[] = [];
    // 保留原有顺序，同名更新身高
    for (let i = 0; i < old.length; i++) {
      let hit: boolean = false;
      for (let j = 0; j < list.length; j++) {
        if (old[i].name.trim() === list[j].name.trim()) {
          out.push({
            no: old[i].no,
            name: old[i].name,
            height: list[j].height.toString(),
            note: old[i].note
          });
          hit = true;
          break;
        }
      }
      if (!hit) {
        out.push(old[i]);
      }
    }
    // 新学生追加
    for (let j = 0; j < list.length; j++) {
      let exists: boolean = false;
      for (let i = 0; i < old.length; i++) {
        if (old[i].name.trim() === list[j].name.trim()) {
          exists = true;
          break;
        }
      }
      if (!exists) {
        out.push({ no: '', name: list[j].name.trim(), height: list[j].height.toString(), note: '' });
      }
    }
    // 空缺学号按顺序自动补号（从现有最大号 +1 开始）
    let maxNo: number = 0;
    for (let i = 0; i < out.length; i++) {
      const n: number = parseInt(out[i].no);
      if (!isNaN(n) && n > maxNo) {
        maxNo = n;
      }
    }
    let next: number = maxNo + 1;
    for (let i = 0; i < out.length; i++) {
      if (out[i].no.trim() === '') {
        out[i] = { no: next.toString(), name: out[i].name, height: out[i].height, note: out[i].note };
        next++;
      }
    }
    return out;
  }

  /** 保存当前名单到班级（选已有班级则合并更新，否则新建班级） */
  private async doSave(): Promise<void> {
    const list: SeatStudent[] = this.parseStudents();
    if (list.length === 0) {
      promptAction.showToast({ message: this.t('seats.listEmpty') });
      return;
    }
    const ctx = getContext(this) as common.UIAbilityContext;
    let roster: StudentItem[] = [];
    let targetName: string = '';
    if (this.pickIdx >= 0 && this.pickIdx < this.classes.length) {
      const item: ClassItem = this.classes[this.pickIdx];
      roster = this.buildRoster(list, item.students);
      const updated: ClassItem = { id: item.id, name: item.name, students: roster };
      await ClassStore.updateClass(ctx, updated);
      targetName = item.name;
    } else if (this.isNewTarget()) {
      const name: string = this.newClassName.trim();
      if (name === '') {
        promptAction.showToast({ message: this.t('seats.classNeed') });
        return;
      }
      const empty: StudentItem[] = [];
      roster = this.buildRoster(list, empty);
      await ClassStore.addClass(ctx, name, roster);
      targetName = name;
    } else {
      promptAction.showToast({ message: this.t('seats.classNeed') });
      return;
    }
    this.closeRoster();
    await this.reloadClasses();
    promptAction.showToast({
      message: this.t('seats.saved')
        .replace('{n}', list.length.toString())
        .replace('{name}', targetName)
    });
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
      promptAction.showToast({ message: I18n.t('err.copyFail') });
    });
  }

  private exportWord(): void {
    if (!this.hasGrid()) {
      return;
    }
    const ctx = getContext(this) as common.UIAbilityContext;
    DocxExporter.exportDocx(ctx, this.resultText(), this.t('seats.copyName') + '-' + this.rows() + 'x' + this.cols() + '.docx')
      .catch((err: Error) => {
        promptAction.showToast({ message: I18n.t('err.exportFail') + err.message });
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
        .fontFamily(AppFonts.family())
        .fontSize(11)
        .fontWeight(this.cellSelected(r, c) ? FontWeight.Bold : FontWeight.Medium)
        .fontColor(this.cellSelected(r, c) ? '#FFFFFF' : this.col('title'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(this.cellHeight(r, c) === '' ? '' : this.cellHeight(r, c) + 'cm')
        .fontFamily(AppFonts.family())
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
          .fontFamily(AppFonts.family())
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
            .fontFamily(AppFonts.family())
            .fontSize(12)
            .fontColor(this.col('hint'))
            .width('100%')
            .lineHeight(18)

          // 布局设置
          Column({ space: 10 }) {
            Row({ space: 10 }) {
              Text(this.t('seats.rows')).fontSize(15).fontColor(this.col('title')).width(92)
                .fontFamily(AppFonts.family())
              TextInput({ text: this.rowsText, placeholder: '8' })
                .fontFamily(AppFonts.family())
                .type(InputType.Number)
                .layoutWeight(1)
                .onChange((v: string) => { this.rowsText = v; })
            }
            Row({ space: 10 }) {
              Text(this.t('seats.cols')).fontSize(15).fontColor(this.col('title')).width(92)
                .fontFamily(AppFonts.family())
              TextInput({ text: this.colsText, placeholder: '6' })
                .fontFamily(AppFonts.family())
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
                .fontFamily(AppFonts.family())
                .fontSize(14)
                .fontColor(this.col('title'))
            }
            .width('100%')

            if (this.sideOn) {
              Row({ space: 10 }) {
                Text(this.t('seats.sideL')).fontSize(14).fontColor(this.col('title')).width(88)
                  .fontFamily(AppFonts.family())
                TextInput({ text: this.sideLName, placeholder: this.t('seats.phSide') })
                  .fontFamily(AppFonts.family())
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
                  .fontFamily(AppFonts.family())
                TextInput({ text: this.sideRName, placeholder: this.t('seats.phSide') })
                  .fontFamily(AppFonts.family())
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
              .fontFamily(AppFonts.family())
            TextArea({ text: this.studentText, placeholder: this.t('seats.phStudents') })
              .fontFamily(AppFonts.family())
              .width('100%')
              .height(140)
              .backgroundColor(this.col('inputBg'))
              .fontColor(this.col('text'))
              .placeholderColor(this.col('hint'))
              .onChange((v: string) => { this.studentText = v; })
            Button(this.t('seats.gen'))
              .fontFamily(AppFonts.family())
              .width('100%')
              .height(42)
              .backgroundColor('#D97706')
              .onClick(() => this.generateSeats())

            Row({ space: 8 }) {
              Button(this.t('seats.importRoster'))
                .fontFamily(AppFonts.family())
                .fontSize(13)
                .height(38)
                .layoutWeight(1)
                .backgroundColor('#4A90D9')
                .onClick(() => {
                  this.openImport();
                })
              Button(this.t('seats.saveRoster'))
                .fontFamily(AppFonts.family())
                .fontSize(13)
                .height(38)
                .layoutWeight(1)
                .backgroundColor('#5BA8A0')
                .onClick(() => {
                  this.openSave();
                })
            }
            .width('100%')

            // 名单联动面板：导入（选班级）或保存（选已有/新建）
            if (this.rosterMode !== 0) {
              Column({ space: 8 }) {
                Row({ space: 8 }) {
                  Text(this.rosterMode === 1 ? this.t('seats.pickClass') : this.t('seats.saveTarget'))
                    .fontSize(13)
                    .fontColor(this.col('sub'))
                    .width(96)
                    .fontFamily(AppFonts.family())
                  Select(this.classOptions())
                    .selected(this.pickIdx < 0 ? 0 : this.pickIdx)
                    .value(this.pickLabel())
                    .fontColor(this.col('text'))
                    .layoutWeight(1)
                    .onSelect((index: number) => {
                      this.pickIdx = index;
                      if (!this.isNewTarget()) {
                        this.newClassName = '';
                      }
                    })
                }
                .width('100%')
                if (this.isNewTarget()) {
                  TextInput({ text: this.newClassName, placeholder: this.t('seats.classNamePh') })
                    .fontFamily(AppFonts.family())
                    .width('100%')
                    .height(40)
                    .onChange((v: string) => { this.newClassName = v; })
                }
                Row({ space: 8 }) {
                  Button(this.t('btn.close'))
                    .fontFamily(AppFonts.family())
                    .fontSize(13)
                    .height(36)
                    .layoutWeight(1)
                    .backgroundColor(this.col('line'))
                    .fontColor(this.col('text'))
                    .onClick(() => this.closeRoster())
                  Button(this.rosterMode === 1 ? this.t('seats.doImport') : this.t('cls.saveName'))
                    .fontFamily(AppFonts.family())
                    .fontSize(13)
                    .height(36)
                    .layoutWeight(1)
                    .backgroundColor(this.rosterMode === 1 ? '#4A90D9' : '#5BA8A0')
                    .onClick(() => {
                      if (this.rosterMode === 1) {
                        this.doImport();
                      } else {
                        this.doSave();
                      }
                    })
                }
                .width('100%')
              }
              .width('100%')
              .padding(10)
              .backgroundColor(this.col('codeBg'))
              .borderRadius(10)
            }
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
                  .fontFamily(AppFonts.family())
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
                .fontFamily(AppFonts.family())
                .fontSize(12)
                .fontColor(this.col('hint'))
                .width('100%')

              // 结果操作
              Row({ space: 8 }) {
                Button(this.t('btn.copy'))
                  .fontFamily(AppFonts.family())
                  .fontSize(13)
                  .height(32)
                  .layoutWeight(1)
                  .backgroundColor('#4A90D9')
                  .onClick(() => this.copyResult())
                Button(this.t('btn.exportWord'))
                  .fontFamily(AppFonts.family())
                  .fontSize(13)
                  .height(32)
                  .layoutWeight(1)
                  .backgroundColor('#2F6DB5')
                  .onClick(() => this.exportWord())
                Button(this.t('btn.saveHist'))
                  .fontFamily(AppFonts.family())
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


@Entry
@Component
struct SeatsEntry {
  build() {
    Column() {
      SeatsContent()
    }
    .width('100%')
    .height('100%')
  }

  pageTransition() {
    PageTransitionEnter({ duration: 300, curve: Curve.EaseInOut })
      .slide(SlideEffect.Right)
    PageTransitionExit({ duration: 260, curve: Curve.EaseInOut })
      .slide(SlideEffect.Left)
  }
}
