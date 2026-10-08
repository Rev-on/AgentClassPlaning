/**
 * 成绩热力图数据模型。
 *
 * 把"最近一次导入的成绩表格"转成适合热力图渲染的矩阵：
 *   横轴 = 科目（数值型列，如 语文/数学/英语/物理…）
 *   纵轴 = 学生（数据行）
 *   单元格深浅 = 该生该科成绩在本列中的相对位置（0~1）
 *
 * 关键设计决策：
 *   · **只把数值列当科目**：像"总分/平均分/排名"这类派生列会掩盖单科表现，
 *     而且量纲差异极大（总分 500 分 vs 单科 100 分）会让热力图失真，故排除。
 *   · 排除姓名列（由 NameMask.isNameHeader 判定），避免把姓名当成绩。
 *   · 归一化**按列独立进行**（每科的满分/难度不同），用"最小-最大"归一；
 *     若某列所有值相同，则统一给中间色（0.5），避免除零。
 *   · 若单元格不是合法数字（如"缺考""—"），标记为 missing，渲染成中性灰。
 */

/** 非科目列的表头关键词（派生列/元数据列，不参与热力图） */
const DERIVED_HEADER_KEYS: string[] = [
  '总分', '总成绩', '合计', '平均', '均分', '均值', '排名', '名次', '序号', '学号',
  '班级', '年级', '考试', '日期', '备注', '等级', '总评',
  'total', 'average', 'avg', 'mean', 'rank', 'score', 'no', 'id',
  'class', 'grade', 'exam', 'date', 'remark', 'level'
];

/** 姓名列表头关键词（与 NameMask 的判定保持一致，避免相互矛盾） */
const NAME_HEADER_KEYS: string[] = [
  '姓名', '学生姓名', '名字', '学生', '同学', '名称',
  'name', 'student', 'studentname'
];

export interface HeatSubject {
  /** 列索引（对应 headers） */
  col: number;
  /** 科目名 */
  name: string;
  /** 该列数值的最小值/最大值（用于色阶映射） */
  min: number;
  max: number;
}

export interface HeatCell {
  /** 原始文本（如 "88" 或 "缺考"） */
  raw: string;
  /** 数值；非数字为 NaN（用 isNaN 判断） */
  value: number;
  /** 归一化强度 0~1；缺失为 -1 */
  level: number;
}

export interface HeatRow {
  /** 学生名（原文；仅本机渲染用） */
  student: string;
  cells: HeatCell[];
}

export interface HeatMapData {
  subjects: HeatSubject[];
  rows: HeatRow[];
  /** 是否可用（至少 1 个科目且 1 行数据） */
  valid: boolean;
  /** 表头里识别到的姓名列索引（-1 表示没有） */
  nameCol: number;
  /** 数据导入时间 */
  time: string;
}

export class HeatMap {
  /** 表头是否像"学生姓名"列 */
  private static isNameHeader(h: string): boolean {
    const s: string = h.trim().toLowerCase();
    if (s === '') {
      return false;
    }
    for (let i: number = 0; i < NAME_HEADER_KEYS.length; i++) {
      if (s.indexOf(NAME_HEADER_KEYS[i]) >= 0) {
        return true;
      }
    }
    return false;
  }

  /** 表头是否为"派生列"（总分/排名/班级…），此类列不做热力图 */
  private static isDerivedHeader(h: string): boolean {
    const s: string = h.trim().toLowerCase();
    if (s === '') {
      return false;
    }
    for (let i: number = 0; i < DERIVED_HEADER_KEYS.length; i++) {
      if (s.indexOf(DERIVED_HEADER_KEYS[i]) >= 0) {
        return true;
      }
    }
    return false;
  }

  /** 解析单元格为数字；支持 "88"、"88.5"、"88分"、"88%" → 88；无法解析返回 NaN */
  private static toNumber(raw: string): number {
    const s: string = raw.trim();
    if (s === '') {
      return NaN;
    }
    // 去掉常见单位与百分号、空白
    const cleaned: string = s.replace(/[分％%\s]/g, '');
    // 只接受纯数字（可带正负号与小数点），避免把 "90-100" 这类区间误判为数字
    if (!/^[+-]?\d+(\.\d+)?$/.test(cleaned)) {
      return NaN;
    }
    const v: number = Number(cleaned);
    return Number.isFinite(v) ? v : NaN;
  }

  /**
   * 从成绩表格构建热力图数据。
   * @param headers 表头
   * @param rows 数据行
   * @param time 导入时间（展示用）
   */
  static build(headers: string[], rows: string[][], time: string): HeatMapData {
    const empty: HeatMapData = {
      subjects: [], rows: [], valid: false, nameCol: -1, time: time
    };
    if (headers.length === 0 || rows.length === 0) {
      return empty;
    }

    // 1) 定位姓名列
    let nameCol: number = -1;
    for (let j: number = 0; j < headers.length; j++) {
      if (HeatMap.isNameHeader(headers[j])) {
        nameCol = j;
        break;
      }
    }

    // 2) 选出科目列：排除姓名列、派生列，且该列**多数单元格是数字**
    const subjects: HeatSubject[] = [];
    for (let j: number = 0; j < headers.length; j++) {
      if (j === nameCol) {
        continue;
      }
      const h: string = headers[j];
      if (h.trim() === '' || HeatMap.isDerivedHeader(h)) {
        continue;
      }
      let numCount: number = 0;
      let total: number = 0;
      for (let i: number = 0; i < rows.length; i++) {
        const raw: string = rows[i][j] !== undefined ? rows[i][j] : '';
        if (raw.trim() === '') {
          continue;
        }
        total++;
        if (!isNaN(HeatMap.toNumber(raw))) {
          numCount++;
        }
      }
      // 阈值：非空单元格中至少一半是数字，才认定该列是成绩列
      if (total > 0 && numCount * 2 >= total) {
        subjects.push({ col: j, name: h, min: NaN, max: NaN });
      }
    }
    if (subjects.length === 0) {
      return empty;
    }

    // 3) 逐科目求极值（用于色阶）
    for (let k: number = 0; k < subjects.length; k++) {
      const sub: HeatSubject = subjects[k];
      let mn: number = NaN;
      let mx: number = NaN;
      for (let i: number = 0; i < rows.length; i++) {
        const raw: string = rows[i][sub.col] !== undefined ? rows[i][sub.col] : '';
        const v: number = HeatMap.toNumber(raw);
        if (isNaN(v)) {
          continue;
        }
        if (isNaN(mn) || v < mn) {
          mn = v;
        }
        if (isNaN(mx) || v > mx) {
          mx = v;
        }
      }
      sub.min = mn;
      sub.max = mx;
    }

    // 4) 逐行构建单元格（归一化到 0~1）
    const outRows: HeatRow[] = [];
    for (let i: number = 0; i < rows.length; i++) {
      const cells: HeatCell[] = [];
      for (let k: number = 0; k < subjects.length; k++) {
        const sub: HeatSubject = subjects[k];
        const raw: string = rows[i][sub.col] !== undefined ? rows[i][sub.col] : '';
        const v: number = HeatMap.toNumber(raw);
        let level: number = -1;
        if (!isNaN(v)) {
          if (isNaN(sub.min) || isNaN(sub.max) || sub.max === sub.min) {
            // 该列所有值相同：统一中间色，避免除零
            level = 0.5;
          } else {
            level = (v - sub.min) / (sub.max - sub.min);
            if (level < 0) {
              level = 0;
            }
            if (level > 1) {
              level = 1;
            }
          }
        }
        cells.push({ raw: raw, value: v, level: level });
      }
      // 学生名：优先姓名列；无姓名列则用行号（第N位）
      let student: string = '';
      if (nameCol >= 0 && rows[i][nameCol] !== undefined) {
        student = rows[i][nameCol].trim();
      }
      if (student === '') {
        student = '#' + (i + 1);
      }
      outRows.push({ student: student, cells: cells });
    }

    return {
      subjects: subjects,
      rows: outRows,
      valid: subjects.length > 0 && outRows.length > 0,
      nameCol: nameCol,
      time: time
    };
  }

  /**
   * 色阶：把 0~1 的强度映射为颜色。
   * 采用「浅蓝 → 深蓝」单色渐变（避免红绿配色，兼顾色觉障碍用户）。
   * @param level 0~1；-1 表示缺失
   */
  static colorOf(level: number): string {
    if (level < 0) {
      return '#EEF1F5'; // 缺失：中性灰
    }
    // 起止色：浅 #EAF3FC → 深 #1B5FA8
    const r0: number = 0xEA;
    const g0: number = 0xF3;
    const b0: number = 0xFC;
    const r1: number = 0x1B;
    const g1: number = 0x5F;
    const b1: number = 0xA8;
    const t: number = level < 0 ? 0 : (level > 1 ? 1 : level);
    const r: number = Math.round(r0 + (r1 - r0) * t);
    const g: number = Math.round(g0 + (g1 - g0) * t);
    const b: number = Math.round(b0 + (b1 - b0) * t);
    return '#' + HeatMap.hex(r) + HeatMap.hex(g) + HeatMap.hex(b);
  }

  /** 该色阶下的前景色：深底用白字，浅底用深字（保证对比度） */
  static inkOf(level: number): string {
    if (level < 0) {
      return '#9AA3AE';
    }
    return level > 0.55 ? '#FFFFFF' : '#1B3A5C';
  }

  private static hex(n: number): string {
    const s: string = n.toString(16).toUpperCase();
    return s.length === 1 ? '0' + s : s;
  }
}
