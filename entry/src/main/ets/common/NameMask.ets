/**
 * 学生姓名脱敏（Tokenization）通用层
 * =====================================================================
 * 安全目标：**学生真实姓名绝不能进入发往 AI / 服务端的任何文本**。
 *
 *   张三  →  S001   （发给 AI 的 prompt 里只有编号）
 *   S001  →  张三   （AI 返回后还原，用于展示 / 导出 / 存历史）
 *
 * 设计三条硬要求（下面逐条给出理由）：
 *   1) 映射表只存内存，用完即丢；
 *   2) 只在"最终完整文本"上还原，绝不在流式增量上还原；
 *   3) fail-closed：脱敏环节出任何问题，宁可抛错也不放行原文。
 *
 * ---------------------------------------------------------------------
 * 【为什么映射表只放内存】
 *   映射表本身就是"编号 ↔ 真实姓名"的对照表，一旦落盘（preferences/文件）
 *   或上传，泄露面反而比脱敏前更大：脱敏的目的就是不留下可还原的姓名副本。
 *   因此本类**不 import** preferences / fileIo / http / HistoryStore / PageDraft，
 *   不写任何持久化，也不向 hilog 打印姓名或原文。
 *   生命周期由页面持有：一次生成开始时 new 一个会话，生成结束（成功/失败/停止）
 *   随对象一起被 GC 丢弃。页面若忘记丢弃，最坏也只是内存里多存一份短命对照表，
 *   不会形成持久化泄漏。
 *
 * ---------------------------------------------------------------------
 * 【为什么只在最终完整文本上还原（流式还原的坑）】
 *   SSE 的正文是**按 token 分片**到达的，客户端回调拿到的是"累计全文"，
 *   但**任意前缀都可能在编号中间被切断**：
 *       … 张三（S001）表现 …    →  分片到达序列可能是
 *         片1 "…张三（S0"   片2 "01）表现…"
 *   若在片1 就做还原，"S0" 不是合法编号（正则只认 S + 3 位数字），
 *   这一片保持原样；等片2 到达时再对**整体**还原其实也还来得及 ——
 *   真正致命的是另一种做法：**对每个增量片段单独还原再拼接**。
 *   那样 "S0" 与 "01" 分属两片，两片都匹配不上编号，拼接结果永远是 "S001"，
 *   用户在整段生成过程中看到的都是编号，而不是姓名（体验问题）；
 *   更糟的是若模型把编号写成 "S001" 与后续数字粘连（如 "S00123"），
 *   逐片还原还会错位。
 *   因此本层的约定是：
 *     · 流式期间**不做任何还原**，直接把累计文本交给流式节流器展示
 *       （展示编号是允许的，编号不含隐私信息）；
 *     · 生成结束后对**服务端返回的最终完整文本**调用一次 restore()
 *       （restoreAll 还会把已提交到 UI 的流式文本也整体还原，见该方法注释）。
 *   这样编号的完整性由"最终全文"保证，不存在半个编号还原失败的问题。
 *   `restore()` 还刻意**不要求编号连续**：模型可能只提到 S003，
 *   编号表里没有 S002 也无妨，逐个编号独立替换即可。
 *
 * ---------------------------------------------------------------------
 * 【为什么 Excel 场景必须按列识别姓名列】
 *   对整张表做无差别字符串替换是错的：
 *     · "优 / 良 / 及格" 这类成绩等级、学号数字、班级名都可能与姓名子串撞车；
 *     · 一旦把非姓名列的内容替换成编号，AI 拿到的数据就是错的（生成结果失真），
 *       而且还原后原文与输出对不上。
 *   所以表格入口 maskTable() 先**按表头识别姓名列**（支持中/英/多写法），
 *   只替换这些列，其余列（语文/数学/总分/学号…）逐字节保持原样。
 *   识别不出姓名列时返回 masked=false，由调用方决定如何处理（见 maskTable 注释）。
 *
 * ---------------------------------------------------------------------
 * 【为什么自由文本不做"中文姓名自动识别"】
 *   从自由文本里用启发式规则猜姓名（2-4 个连续汉字等）必然大面积误伤：
 *   "成绩下滑""家长会""单元测试"都会被当成姓名替换掉，AI 拿到的语义就废了。
 *   本层采取"有据可依"的策略：
 *     · 表格：按列名识别（可靠，见上）；
 *     · 自由文本：只替换**已知姓名**（来自姓名列 / 结构化字段时间），
 *       或调用方**显式声明**的姓名（如 Report 页"学生姓名"输入框里的那个名字）。
 *   于是契约很清晰：**页面必须把"这个字段是学生姓名"这件事告诉本层**，
 *   本层负责把它从所有要外发的文本里抹掉。
 *
 * ---------------------------------------------------------------------
 * 【fail-closed 边界，务必分清】
 *   必须抛错（阻断发送）的情况：
 *     · restore() / applyToFlow() 在**已明确知道学生姓名**（knownNames 非空或
 *       表格里已识别出姓名列）的会话上被调用 —— 说明页面忘了先 mask，
 *       此时一旦放行就是原文外发，故抛 MaskError('restore-on-unmasked')。
 *     · 调用方显式要求"必须有姓名列"（requireNameColumn=true）却没识别到。
 *   必须抛错之外的情况（不能抛）：
 *     · 表格里**本来就没有姓名列**（例如只有"题号/得分"的统计表）——
 *       这是合法输入，不是脱敏失败。抛错会让功能不可用。此时返回
 *       masked=false + 空的列名，由调用方按 I18n 提示"未识别到姓名列"（见 ExcelParser）。
 *
 * 本文件为纯逻辑（除 MaskError 外无任何系统 API 依赖），可被 Node 脚本按源码
 * 断言式回归测试覆盖（server/tools/test_name_tokenization.js）。
 */

/** 脱敏/还原过程本身的错误（fail-closed 时抛出，绝不放行原文） */
export class MaskError extends Error {
  /** 机器可读的错误码，便于页面/测试区分失败原因 */
  readonly code: string;

  constructor(code: string, message: string) {
    super(message);
    this.name = 'MaskError';
    this.code = code;
  }
}

/** 一次脱敏会话（对应一次生成），内部持有"编号 → 真实姓名"的对照表 */
export class NameMaskSession {
  /** 编号 → 真实姓名 */
  private readonly idToName: Map<string, string> = new Map<string, string>();
  /** 真实姓名 → 编号（去重：同一姓名始终得到同一编号） */
  private readonly nameToId: Map<string, string> = new Map<string, string>();
  /** 真实姓名集合，供 knownNames / maskFreeText 使用 */
  private readonly names: Set<string> = new Set<string>();
  /** 已发放的编号个数 */
  private seq: number = 0;
  /** 本次会话是否已经处理过结构化姓名数据（决定 restore 的 fail-closed 判定） */
  private structured: boolean = false;

  /** 编号是否已发放过 */
  has(id: string): boolean {
    return this.idToName.has(id);
  }

  /** 姓名是否已在本次会话登记 */
  knows(name: string): boolean {
    return this.nameToId.has(name);
  }

  /** 姓名 → 编号（不存在返回空串） */
  idOf(name: string): string {
    const id: string | undefined = this.nameToId.get(name);
    return id !== undefined ? id : '';
  }

  /** 编号 → 姓名（不存在返回空串） */
  nameOf(id: string): string {
    const n: string | undefined = this.idToName.get(id);
    return n !== undefined ? n : '';
  }

  /** 编号个数（用于诊断输出；只打印数量，不打印任何姓名） */
  size(): number {
    return this.idToName.size;
  }

  /** 已登记的真实姓名（供 maskFreeText 确保自由文本里的姓名也被抹掉） */
  knownNames(): string[] {
    const out: string[] = [];
    this.nameToId.forEach((_id: string, name: string): void => {
      out.push(name);
    });
    return out;
  }

  /**
   * 登记一个真实姓名并返回其编号。
   *
   * 规则：
   *  · 同一姓名**去重** —— 同一批数据里"张三"出现两次必须都是 S001，
   *    否则 AI 会看到两个"不同学生"，分析结论直接出错；
   *  · 编号从 S001 起，三位补零；超过 999 自然增长为 S1000（不做截断）。
   *
   * 空白姓名（''、'   '）不登记，直接返回空串：空姓名不是学生，
   * 给它发编号反而会在还原时把文本里的空串替换成编号，造成污染。
   */
  register(rawName: string): string {
    const name: string = rawName.trim();
    if (name === '') {
      return '';
    }
    const exist: string | undefined = this.nameToId.get(name);
    if (exist !== undefined) {
      return exist;
    }
    this.seq = this.seq + 1;
    const id: string = 'S' + NameMaskSession.pad3(this.seq);
    this.nameToId.set(name, id);
    this.idToName.set(id, name);
    this.names.add(name);
    return id;
  }

  /** 批量登记（顺序决定编号；与 register 一致地去重） */
  registerAll(rawNames: string[]): void {
    for (let i: number = 0; i < rawNames.length; i++) {
      this.register(rawNames[i]);
    }
  }

  /** 标记：本次会话已处理过"明确是学生姓名"的结构化字段 */
  markStructured(): void {
    this.structured = true;
  }

  /** 是否处理过结构化姓名（restore 的 fail-closed 判定依据） */
  hasStructured(): boolean {
    return this.structured;
  }

  /**
   * 替换一段文本里出现的**已知编号**为其真实姓名。
   *
   * 注意：本方法是 restore 的底层实现，**只应在最终完整文本上调用**，
   * 不要在流式增量上逐段调用（见文件头"为什么只在最终完整文本上还原"）。
   *
   * 实现的三个细节：
   *  · 用一次 indexOf 顺序扫描 + 集合查找，而不是正则 —— ArkTS 的
   *    String.replace 回调重载在各 API 版本上行为不一致，且正则的
   *    V8-incompatible 语法在 ArkTS 受限运行时里容易踩坑；
   *  · 「从短到长」尝试编号长度（S001 → S0012）：即使用户用 S0012 这种
   *    四位编号（第 1002 个学生），按 idOf 逐字符探测也能正确切分，
   *    不会把 S0012 误判成 S001 + '2'；
   *  · 单次构造新串（切片拼接），避免 replaceAll 的兼容性问题。
   */
  restore(text: string): string {
    if (text === '' || this.idToName.size === 0) {
      return text;
    }
    // 编号最长长度（S + 数字位数），用于限制探测窗口
    let maxDigits: number = 3;
    this.idToName.forEach((_n: string, id: string): void => {
      const d: number = id.length - 1;
      if (d > maxDigits) {
        maxDigits = d;
      }
    });
    let out: string = '';
    let i: number = 0;
    let plainStart: number = 0;
    while (i < text.length) {
      if (text.charCodeAt(i) !== 83 /* 'S' */) {
        i = i + 1;
        continue;
      }
      // 在 S 处向后贪心匹配"尽量长的已知编号"，命中即整体替换
      const maxLen: number = Math.min(1 + maxDigits, text.length - i);
      let hitLen: number = 0;
      for (let len: number = maxLen; len >= 2; len--) {
        const cand: string = text.substring(i, i + len);
        if (this.idToName.has(cand)) {
          hitLen = len;
          break;
        }
      }
      if (hitLen === 0) {
        i = i + 1;
        continue;
      }
      const cand: string = text.substring(i, i + hitLen);
      const real: string | undefined = this.idToName.get(cand);
      out = out + text.substring(plainStart, i) + (real !== undefined ? real : cand);
      i = i + hitLen;
      plainStart = i;
    }
    if (plainStart === 0) {
      return text;
    }
    return out + text.substring(plainStart);
  }

  /**
   * 把自由文本中出现的**已知姓名**替换为编号。
   *
   * 说明：本方法的存在是"防漏"而非"主力"。主力是 maskStructured()（页面指名字段）
   * 与 maskTable()（按列识别）。但老师完全可能在自由文本里手写姓名，
   * 所以已经登记过的姓名会在这里被再兜底抹一遍。
   * 未登记的姓名**不会**被猜测（见文件头"为什么自由文本不做中文姓名自动识别"）。
   *
   * @param strict true 时若替换后仍含已知姓名则抛错（fail-closed 的最终断言）
   */
  maskFreeText(text: string, strict: boolean = false): string {
    let out: string = text;
    if (this.names.size > 0) {
      this.names.forEach((name: string): void => {
        if (name !== '' && out.indexOf(name) >= 0) {
          const id: string | undefined = this.nameToId.get(name);
          if (id !== undefined) {
            out = NameMaskSession.replaceAll(out, name, id);
          }
        }
      });
    }
    if (strict && this.containsKnownName(out)) {
      // 走到这里说明替换逻辑本身有问题 —— 绝不能把这种文本发出去
      throw new MaskError('mask-leak', '自由文本脱敏后仍检测到真实姓名，已阻断外发');
    }
    return out;
  }

  /**
   * 把"明确是学生姓名"的字段值整体替换为编号。
   * 与 maskFreeText 的区别：这里把整个字段值当姓名处理（老师输入框里就是姓名），
   * 即使它没有被 register 过也会登记并替换 —— 这是 Report 页的核心入口。
   */
  maskStructuredValue(value: string): string {
    const v: string = value.trim();
    if (v === '') {
      return '';
    }
    this.markStructured();
    return this.register(v);
  }

  /**
   * fail-closed 断言：文本中不得再出现任何**已知真实姓名**。
   * 页面在把 prompt 交给 AiService 之前调用；一旦失败即抛错阻断外发。
   */
  assertNoKnownName(text: string, what: string = 'prompt'): void {
    if (this.containsKnownName(text)) {
      throw new MaskError('mask-leak', what + ' 中仍检测到真实姓名，已阻断外发');
    }
  }

  /** 文本是否含任何已知真实姓名（只做布尔判断，不打印内容） */
  containsKnownName(text: string): boolean {
    let hit: boolean = false;
    this.names.forEach((name: string): void => {
      if (!hit && name !== '' && text.indexOf(name) >= 0) {
        hit = true;
      }
    });
    return hit;
  }

  /** 三位补零（seq=1 → '001'；seq=1000 → '1000'，自然增长不截断） */
  private static pad3(n: number): string {
    const s: string = String(n);
    return s.length >= 3 ? s : '000'.substring(s.length) + s;
  }

  /** 字面量全量替换（不用正则，规避 ArkTS 正则 replace 回调的版本差异） */
  private static replaceAll(text: string, find: string, to: string): string {
    if (find === '') {
      return text;
    }
    let out: string = '';
    let from: number = 0;
    let idx: number = text.indexOf(find, from);
    while (idx >= 0) {
      out = out + text.substring(from, idx) + to;
      from = idx + find.length;
      idx = text.indexOf(find, from);
    }
    return out + text.substring(from);
  }
}

/** 表格脱敏结果 */
export interface TableMaskResult {
  /** 脱敏后的表格（二维数组，形状与输入完全一致） */
  rows: string[][];
  /** 识别出的姓名列索引（可能多个，如"姓名""家长姓名"） */
  nameColumns: number[];
  /** 是否执行了脱敏（false = 没找到姓名列，表格按原样返回） */
  masked: boolean;
}

/** 表格脱敏选项 */
export interface TableMaskOpts {
  /**
   * true：必须识别到姓名列，否则抛 MaskError。
   * 用于"这张表本来就是学生名单"的场景；
   * 默认 false：识别不到就按原样返回（统计类表格属合法输入，不能抛错导致功能不可用）。
   */
  requireNameColumn?: boolean;
}

/**
 * 姓名列表入口：把一组学生姓名登记成编号，返回"编号 → 姓名"的还原函数。
 * 典型用途：页面手上只有姓名数组（没有表头）时的批量登记。
 */
export interface NameTokenizeResult {
  /** 姓名数组（原顺序） */
  names: string[];
  /** 与 names 一一对应的编号（空姓名对应空串） */
  ids: string[];
  /** 还原函数：把文本里的编号换回姓名 */
  restore: (text: string) => string;
}

/** 通用姓名脱敏门面（无状态，所有状态都在 NameMaskSession 里） */
export class NameMask {
  /** 会话级编号上限保护：超过此数量说明输入异常（如整列被误判为姓名），直接抛错 fail-closed */
  static readonly MAX_NAMES: number = 20000;

  /** 判定一个单元格/表头是否是"姓名列"的表头名（小写、去空格后比对） */
  private static readonly NAME_HEADERS: string[] = [
    // 中文
    '姓名', '学生姓名', '名字', '学生', '学生名', '学员', '学员姓名', '儿童姓名', '孩子姓名',
    '幼儿姓名', '考生姓名', '姓名（学生）', '姓名(学生)',
    // 英文（统一转小写后比对，空格与下划线会被剥离）
    'name', 'studentname', 'student', 'fullname', 'pupilname', 'childname', 'kidsname'
  ];

  /** 姓名列**不得**包含的词：这些表头说明该列不是学生本人姓名 */
  private static readonly NAME_HEADER_EXCLUDE: string[] = [
    '家长', '父母', '父亲', '母亲', '监护人', '老师', '教师', '班主任', '任课',
    '家长姓名', '监护人姓名', '教师姓名', '老师姓名', '批改人', '审核人', '制表人',
    '班级', '年级', '学校', '学号', '考号', '座号', '序号'
  ];

  /** 判断表头是否为姓名列 */
  static isNameHeader(header: string): boolean {
    const h: string = NameMask.normalizeHeader(header);
    if (h === '') {
      return false;
    }
    for (let i: number = 0; i < NameMask.NAME_HEADER_EXCLUDE.length; i++) {
      if (h.indexOf(NameMask.normalizeHeader(NameMask.NAME_HEADER_EXCLUDE[i])) >= 0) {
        return false;
      }
    }
    for (let i: number = 0; i < NameMask.NAME_HEADERS.length; i++) {
      if (h === NameMask.normalizeHeader(NameMask.NAME_HEADERS[i])) {
        return true;
      }
    }
    return false;
  }

  /** 表头归一化：去空白、去全角空格、去下划线与连字符、转小写 */
  private static normalizeHeader(s: string): string {
    return s.replace(/\s+/g, '')
      .replace(/\u3000/g, '')
      .replace(/[_\-·.]/g, '')
      .toLowerCase();
  }

  /** 新建一个会话（每次生成开始时调用一次；生成结束即丢弃） */
  static session(): NameMaskSession {
    return new NameMaskSession();
  }

  /**
   * 姓名数组入口：登记全部姓名并给出编号与还原函数。
   * 同一姓名去重（同一编号），空姓名跳过。
   */
  static tokenizeNames(sess: NameMaskSession, names: string[]): NameTokenizeResult {
    const ids: string[] = [];
    for (let i: number = 0; i < names.length; i++) {
      ids.push(sess.register(names[i]));
    }
    if (sess.size() > NameMask.MAX_NAMES) {
      throw new MaskError('too-many-names',
        '本次登记的学生姓名数量异常（' + sess.size() + '），已阻断外发以防误判');
    }
    const result: NameTokenizeResult = {
      names: names,
      ids: ids,
      restore: (text: string): string => sess.restore(text)
    };
    return result;
  }

  /**
   * 结构化文本字段入口（Report 页的"学生姓名"输入框、班级等明确字段）。
   * 空值返回空串（不登记编号），非空值整体替换为编号。
   */
  static maskStructured(sess: NameMaskSession, value: string): string {
    return sess.maskStructuredValue(value);
  }

  /**
   * 自由文本入口：把**已知姓名**替换为编号（老师手写在描述里的姓名由页面先行声明）。
   *
   * @param known 页面额外声明的真实姓名（会先登记再替换）
   */
  static maskFreeText(sess: NameMaskSession, text: string, known?: string[]): string {
    if (known !== undefined && known.length > 0) {
      for (let i: number = 0; i < known.length; i++) {
        sess.register(known[i]);
      }
    }
    return sess.maskFreeText(text);
  }

  /**
   * 表格入口（Excel 场景）：**按列识别姓名列**后只脱敏姓名列。
   *
   * 为什么要按列：整表无差别替换会把"优/良/及格"、学号数字等一起改掉，
   * AI 收到的是错数据，还原后也与原文对不上（见文件头）。
   *
   * 约定：rows[0] 是表头。表头里可能同时有"姓名"与"家长姓名"两列，
   * 但后者被 NAME_HEADER_EXCLUDE 排除 —— 家长姓名不是"学生真实姓名"，
   * 且它是家校沟通的必要信息（Talk 场景要称呼家长），故不脱敏。
   */
  static maskTable(sess: NameMaskSession, rows: string[][], opts?: TableMaskOpts): TableMaskResult {
    const requireCol: boolean = opts !== undefined && opts.requireNameColumn === true;
    if (rows.length === 0) {
      if (requireCol) {
        throw new MaskError('no-name-column', '表格为空，无法识别姓名列');
      }
      return { rows: rows, nameColumns: [], masked: false };
    }
    const headers: string[] = rows[0];
    const nameCols: number[] = [];
    for (let j: number = 0; j < headers.length; j++) {
      if (NameMask.isNameHeader(headers[j])) {
        nameCols.push(j);
      }
    }
    if (nameCols.length === 0) {
      if (requireCol) {
        throw new MaskError('no-name-column', '未识别到姓名列，已阻断外发');
      }
      // 合法输入（如"题号/得分"统计表）：原样返回，由调用方给出提示
      return { rows: rows, nameColumns: [], masked: false };
    }
    // 先整体登记（顺序 = 表格出现顺序），保证"同一姓名同一编号"
    for (let i: number = 1; i < rows.length; i++) {
      for (let k: number = 0; k < nameCols.length; k++) {
        const cell: string | undefined = rows[i][nameCols[k]];
        if (cell !== undefined) {
          sess.register(cell);
        }
      }
    }
    if (sess.size() > NameMask.MAX_NAMES) {
      throw new MaskError('too-many-names',
        '本次登记的学生姓名数量异常（' + sess.size() + '），已阻断外发以防误判');
    }
    sess.markStructured();
    // 再逐行替换：只改姓名列，其余列逐字节保持原样（成绩、学号等不受影响）
    const out: string[][] = [];
    out.push(headers.slice(0));
    for (let i: number = 1; i < rows.length; i++) {
      const row: string[] = rows[i].slice(0);
      for (let k: number = 0; k < nameCols.length; k++) {
        const c: number = nameCols[k];
        const cell: string | undefined = row[c];
        if (cell !== undefined) {
          row[c] = cell.trim() === '' ? '' : sess.register(cell);
        }
      }
      out.push(row);
    }
    const res: TableMaskResult = { rows: out, nameColumns: nameCols, masked: true };
    return res;
  }

  /** 还原（只应在最终完整文本上调用一次；原因见文件头"流式还原的坑"） */
  static restore(sess: NameMaskSession, text: string): string {
    return sess.restore(text);
  }

  /**
   * 生成流程出口的统一封装（fail-closed 的落点）：
   *
   *   applyToFlow(sess, system, user, restoreTarget?)
   *     · 断言 system/user 里不含任何已知真实姓名，否则**抛错**（绝不外发）；
   *     · 若给了 restoreTarget（页面手上已提交的流式文本），一并整体还原。
   *
   * 返回还原后的流式文本（无 restoreTarget 时返回空串）。
   * 页面拿到服务端最终全文后，再单独调一次 restore() 即可 ——
   * 两处都在"完整文本"上工作，不存在流式半编号问题。
   */
  static applyToFlow(sess: NameMaskSession, system: string, user: string,
    restoreTarget?: string): string {
    // 若本次会话从未处理过结构化姓名，页面却在用 restore —— 说明它压根没脱敏过，
    // 这是"忘了调 mask"的强信号：直接抛错阻断（fail-closed）。
    if (!sess.hasStructured() && sess.size() === 0 && restoreTarget !== undefined && restoreTarget !== '') {
      throw new MaskError('restore-on-unmasked',
        '本次生成未登记任何学生姓名却请求还原，疑似未脱敏即外发，已阻断');
    }
    sess.assertNoKnownName(system, '系统提示词');
    sess.assertNoKnownName(user, '用户输入');
    if (restoreTarget !== undefined && restoreTarget !== '') {
      return sess.restore(restoreTarget);
    }
    return '';
  }
}
