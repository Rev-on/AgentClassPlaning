/**
 * 富文本工具：AI 生成内容以受限 HTML 子集存储与传输
 * 支持标签：<h2>/<h3>（分节标题）、<p>（段落）、<br>（换行）、
 *          <b>/<strong>、<i>/<em>、<u>、<s>/<del>、<font color="#xxxxxx">
 * 提供：旧内容兼容（非 HTML 视为纯文本）、纯文本提取（复制用）、
 *      编辑器加载（HTML → 样式片段）与保存（样式片段 → HTML）
 */
export interface RichRun {
  /** 文本片段（可能含换行符 \n） */
  text: string;
  bold: boolean;
  italic: boolean;
  underline: boolean;
  strike: boolean;
  /** 十六进制颜色（无 #，'' 表示未指定） */
  color: string;
  /** 标题级数 0=正文 2/3 来自 <h2>/<h3>（编辑器按加粗+字号近似） */
  heading: number;
  /** 编辑器读回时的大字号（h2=19 h3=17），用于识别标题 */
  size: number;
}

/** 按 \n 切分后的段内子片段（编辑器保存用） */
interface HtmlSeg {
  text: string;
  bold: boolean;
  italic: boolean;
  underline: boolean;
  strike: boolean;
  color: string;
  size: number;
}

/**
 * 编辑器样式操作（保存时确定性回写用）：
 * 用户在编辑器里对某段选区做的加粗/斜体/下划线/删除线/颜色操作，
 * 按"纯文本偏移量 + 开关 + 颜色"记录，保存时直接改写原文 HTML，
 * 从而不依赖 RichEditor 的样式读回（部分设备读回不稳定，会把内联标签整篇丢掉）。
 */
export interface StyleOp {
  /** bold | italic | underline | strike | color */
  kind: string;
  /** 是否为"开启"（关闭则移除该样式） */
  on: boolean;
  /** color 操作用：十六进制颜色（无 #；空串表示清除自定义颜色） */
  color: string;
  /** 选区起止（纯文本偏移） */
  start: number;
  end: number;
}

const ALLOWED: string[] = ['h1', 'h2', 'h3', 'h4', 'p', 'br', 'b', 'strong', 'i', 'em', 'u', 's', 'del', 'font'];

export class RichHtml {

  /** 是否疑似 HTML（白名单标签出现即视为富文本内容） */
  static looksLikeHtml(raw: string): boolean {
    const lower: string = raw.toLowerCase();
    for (let i: number = 0; i < ALLOWED.length; i++) {
      const tag: string = ALLOWED[i];
      if (lower.indexOf('<' + tag + '>') >= 0 || lower.indexOf('<' + tag + ' ') >= 0 ||
        lower.indexOf('<' + tag + '/') >= 0) {
        return true;
      }
    }
    return false;
  }

  /** 转义 HTML 文本 */
  static escape(text: string): string {
    return text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
  }

  /** 展示用基础字号（HTML size 属性，4 ≈ 大一号正文） */
  private static readonly VIEW_SIZE: string = '4';

  /**
   * 展示前规范化（会放大正文）：
   *  - 已是 HTML：解析为规范片段后重建，正文统一带 <font size="4"> 放大，标题保留 <h2>/<h3>
   *  - 旧内容（历史里的纯文本/Markdown 字符）：按纯文本转义并放大，换行转为 <br>
   */
  static toDisplay(raw: string): string {
    if (raw.trim() === '') {
      return '';
    }
    if (RichHtml.looksLikeHtml(raw)) {
      return RichHtml.runsToHtmlEx(RichHtml.htmlToRuns(raw), RichHtml.VIEW_SIZE);
    }
    const lines: string[] = raw.replace(/\r\n/g, '\n').split('\n');
    return '<p><font size="' + RichHtml.VIEW_SIZE + '">' + lines.join('<br>') + '</font></p>';
  }

  /** 流式预览清洗：截掉末尾尚未闭合的标签片段（如 "<h3>一、教" 中的 "<h3>" 残段），避免把残缺标签当文本显示 */
  static liveSafe(html: string): string {
    const lt: number = html.lastIndexOf('<');
    const gt: number = html.lastIndexOf('>');
    if (lt > gt) {
      return html.substring(0, lt);
    }
    return html;
  }

  /** 提取纯文本（复制到剪贴板等场景）：剥标签 + 还原常见实体 + 换行归一 */
  static toPlain(html: string): string {
    let s: string = html;
    // 块级闭合标签补换行
    s = s.replace(/<\/(p|div|h[1-6])>/g, '\n');
    s = s.replace(/<br\s*\/?>/g, '\n');
    // 剥除全部标签
    s = s.replace(/<[^>]*>/g, '');
    s = s.replace(/&nbsp;/g, ' ').replace(/&lt;/g, '<').replace(/&gt;/g, '>')
      .replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&amp;/g, '&');
    // 压缩多余空行（保留单空行分段）
    s = s.replace(/\r\n/g, '\n');
    s = s.replace(/\n{3,}/g, '\n\n');
    return s.trim();
  }

  /**
   * 编辑器坐标空间的纯文本：= htmlToRuns 后所有片段文本的拼接。
   * 必须用它（而不是 toPlain）与编辑器读回的文本、以及样式操作偏移做比对，
   * 因为 toPlain 会压缩多余空行，与编辑器实际文本存在偏移差异。
   */
  static plainOf(html: string): string {
    const runs: RichRun[] = RichHtml.htmlToRuns(html);
    let s: string = '';
    for (let i: number = 0; i < runs.length; i++) {
      s += runs[i].text;
    }
    return s;
  }

  /**
   * 编辑器读回文本的归一化：用于与 plainOf 做「文字是否被改动」的比对。
   *
   * 背景（曾导致"点击完成后样式丢失"）：
   *   htmlToRuns 把每个块级标签（<p>/<h2>/<div>…）转成 '\n'，
   *   因此 plainOf 的结果形如 '\n光的反射\n\n一、教学目标\n'（首尾与段间都有换行）。
   *   而 RichEditor.getSpans() 拼出的文本会把首尾换行剥离、连续换行压缩为单个，
   *   得到 '光的反射\n一、教学目标'。
   *   两者永远不相等 —— 即使用户一个字都没改，也会被误判为"文字有改动"，
   *   从而落入 SDK 样式读回分支，样式在该分支被剥除。
   *
   * 归一化规则（两侧都施用，保证同一坐标系）：
   *   1. 统一换行符为 \n
   *   2. 压缩连续换行为单个 \n
   *   3. 去首尾换行
   */
  static normalizeText(s: string): string {
    let t: string = s.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
    t = t.replace(/\n{2,}/g, '\n');
    // 去首尾换行（等价 trim('\n')，ArkTS 不保证支持 trim 带参形式）
    let start: number = 0;
    let end: number = t.length;
    while (start < end && t.charAt(start) === '\n') {
      start++;
    }
    while (end > start && t.charAt(end - 1) === '\n') {
      end--;
    }
    return t.substring(start, end);
  }

  /** 归一化后比较两段文本是否等价（忽略块级换行带来的差异） */
  static sameText(a: string, b: string): boolean {
    return RichHtml.normalizeText(a) === RichHtml.normalizeText(b);
  }

  /**
   * 按编辑器记录的样式操作确定性改写 HTML（保存回写用，不依赖 SDK 样式读回）：
   * 原文解析为片段 → 在纯文本偏移处切分 → 应用样式开关 → 重建 HTML。
   */
  static applyStyleOps(html: string, ops: StyleOp[]): string {
    if (ops.length === 0) {
      return html;
    }
    const runs: RichRun[] = RichHtml.htmlToRuns(html);
    return RichHtml.runsToHtml(RichHtml.applyOpsToRuns(runs, ops));
  }

  /** 把样式操作应用到已有片段（供"文字改动后"用读回片段 + 映射后的操作重建） */
  static applyOpsToRuns(runs: RichRun[], ops: StyleOp[]): RichRun[] {
    let list: RichRun[] = runs;
    for (let i: number = 0; i < ops.length; i++) {
      list = RichHtml.applyOneOp(list, ops[i]);
    }
    return list;
  }

  /**
   * 文字被改动后，把原样式操作偏移映射到新文本偏移：
   *  - 完全落在公共前缀内：偏移不变
   *  - 完全落在公共后缀内：整体平移（delta = 新长度 - 原长度）
   *  - 跨越改动区间：无法可靠映射，丢弃该条操作
   */
  static mapOps(ops: StyleOp[], orig: string, now: string): StyleOp[] {
    const out: StyleOp[] = [];
    if (ops.length === 0 || orig === now) {
      return ops;
    }
    let cp: number = 0;
    const minLen: number = orig.length < now.length ? orig.length : now.length;
    while (cp < minLen && orig.charAt(cp) === now.charAt(cp)) {
      cp++;
    }
    let cs: number = 0;
    while (cs < (minLen - cp) && orig.charAt(orig.length - 1 - cs) === now.charAt(now.length - 1 - cs)) {
      cs++;
    }
    const delta: number = now.length - orig.length;
    for (let i: number = 0; i < ops.length; i++) {
      const op: StyleOp = ops[i];
      if (op.end <= cp) {
        out.push(op);
      } else if (op.start >= orig.length - cs) {
        const moved: StyleOp = {
          kind: op.kind, on: op.on, color: op.color,
          start: op.start + delta, end: op.end + delta
        };
        out.push(moved);
      }
    }
    return out;
  }

  /**
   * 文字被改动后，把**原文的样式**确定性地搬到新文本上。
   *
   * 为什么需要它：
   *   RichEditor 的样式读回（getSpans().textStyle）在部分设备上不稳定 ——
   *   字号读回为 0 或编辑器默认值、内联标签整篇丢失。若在"用户输入了新文字"时
   *   依赖读回来重建 HTML，标题（<h2>/<h3>）会被降级为普通段落、加粗/颜色被剥除，
   *   即"输入新文本后保存退出丢失格式"。
   *
   * 做法（与 mapOps 的"丢弃跨越改动区间的操作"不同，这里保留全部样式）：
   *   1. 求原文与新文本的公共前缀长度 cp、公共后缀长度 cs；
   *   2. 把新文本切成三段：前缀区 / 改动区 / 后缀区；
   *   3. 前缀区的样式按原样沿用（偏移不变）；
   *      后缀区的样式整体平移 delta = now.length - orig.length；
   *      改动区（用户新输入的部分）继承其**前一个字符**的样式，
   *      保证"在加粗文字后面接着打字"时新字也是加粗的，符合直觉；
   *   4. 另叠加本次编辑会话记录的样式操作（按编辑器坐标系映射后应用）。
   *
   * @param html 原始富文本 HTML
   * @param origPlain 原文纯文本（plainOf 坐标系）
   * @param nowPlain  编辑器读回的新纯文本（归一化坐标系）
   * @param ops       本次会话的样式操作（已换算到 nowPlain 坐标系）
   */
  static rebaseHtml(html: string, origPlain: string, nowPlain: string, ops: StyleOp[]): string {
    const base: RichRun[] = RichHtml.htmlToRuns(html);
    if (nowPlain === '') {
      return html;
    }
    // 原文在 base 坐标系下的纯文本（与 base 的 run.text 完全对齐）
    let basePlain: string = '';
    for (let i: number = 0; i < base.length; i++) {
      basePlain += base[i].text;
    }
    // 关键：origPlain 传进来时已被 normalizeText 处理（去掉了首尾换行），
    // 而 base 的 run.text 仍带这些换行，两者相差 lead 个偏移。
    // 这里求出前导偏移，把所有下标统一换算到 base 坐标系，避免样式整体错位一位。
    const lead: number = basePlain.indexOf(origPlain);
    const off: number = lead >= 0 ? lead : 0;

    // 1) 公共前后缀（在归一化文本坐标系上计算）
    const minLen: number = origPlain.length < nowPlain.length ? origPlain.length : nowPlain.length;
    let cp: number = 0;
    while (cp < minLen && origPlain.charAt(cp) === nowPlain.charAt(cp)) {
      cp++;
    }
    let cs: number = 0;
    while (cs < (minLen - cp) &&
      origPlain.charAt(origPlain.length - 1 - cs) === nowPlain.charAt(nowPlain.length - 1 - cs)) {
      cs++;
    }

    // 2) 取"前一个字符"的样式作为改动区继承样式（下标换算到 base 坐标系）
    const styleAtBase = (idxBase: number): RichRun | null => {
      let acc: number = 0;
      for (let i: number = 0; i < base.length; i++) {
        const r: RichRun = base[i];
        if (idxBase < acc + r.text.length) {
          return r;
        }
        acc += r.text.length;
      }
      return base.length > 0 ? base[base.length - 1] : null;
    };
    const inheritFrom: RichRun | null = cp > 0 ? styleAtBase(cp - 1 + off)
      : (base.length > 0 ? base[0] : null);

    // 3) 按三段重建：前缀沿用原样式、改动区继承前一字样式、后缀整体平移
    const out: RichRun[] = [];
    const pushRun = (text: string, src: RichRun | null): void => {
      if (text === '') {
        return;
      }
      if (src === null) {
        out.push({ text: text, bold: false, italic: false, underline: false, strike: false,
          color: '', heading: 0, size: 0 });
        return;
      }
      const last: RichRun | undefined = out.length > 0 ? out[out.length - 1] : undefined;
      if (last !== undefined && last.bold === src.bold && last.italic === src.italic &&
        last.underline === src.underline && last.strike === src.strike &&
        last.color === src.color && last.heading === src.heading && last.size === src.size) {
        last.text += text;
      } else {
        out.push({ text: text, bold: src.bold, italic: src.italic, underline: src.underline,
          strike: src.strike, color: src.color, heading: src.heading, size: src.size });
      }
    };

    // 前缀：base 文本 [off, off+cp) —— 样式逐一沿用。
    // 注意前缀里可能含"归一化时被删掉的换行"（原文连续换行），
    // 输出文本直接取自 nowPlain，避免把多余换行带回来。
    let acc: number = 0;
    let emitted: number = 0;
    for (let i: number = 0; i < base.length && emitted < cp; i++) {
      const r: RichRun = base[i];
      const rStart: number = acc;
      const rEnd: number = acc + r.text.length;
      acc = rEnd;
      const from: number = Math.max(rStart, off);
      const to: number = Math.min(rEnd, off + cp);
      if (to <= from) {
        continue;
      }
      const take: number = to - from;
      pushRun(nowPlain.substring(emitted, emitted + take), r);
      emitted += take;
    }
    // 改动区：新文本 [cp, nowLen - cs) —— 继承前一个字符的样式
    const midEnd: number = nowPlain.length - cs;
    if (midEnd > cp) {
      pushRun(nowPlain.substring(cp, midEnd), inheritFrom);
    }
    // 后缀：base 文本 [off + origLen - cs, off + origLen)
    if (cs > 0) {
      const suffixStartBase: number = off + origPlain.length - cs;
      let sacc: number = 0;
      let written: number = midEnd;
      for (let i: number = 0; i < base.length; i++) {
        const r: RichRun = base[i];
        const rStart: number = sacc;
        const rEnd: number = sacc + r.text.length;
        sacc = rEnd;
        if (rEnd <= suffixStartBase) {
          continue;
        }
        const fromBase: number = Math.max(rStart, suffixStartBase);
        if (fromBase >= rEnd) {
          continue;
        }
        const take: number = rEnd - fromBase;
        pushRun(nowPlain.substring(written, written + take), r);
        written += take;
      }
    }

    // 4) 叠加本次会话的样式操作（已在编辑器坐标系）
    const applied: RichRun[] = ops.length === 0 ? out : RichHtml.applyOpsToRuns(out, ops);
    return RichHtml.runsToHtml(applied);
  }

  /** 在指定纯文本偏移处切分片段（保证样式区间边界对齐） */
  private static splitRunsAt(runs: RichRun[], pos: number): RichRun[] {    if (pos <= 0) {
      return runs;
    }
    const out: RichRun[] = [];
    let acc: number = 0;
    for (let i: number = 0; i < runs.length; i++) {
      const r: RichRun = runs[i];
      const len: number = r.text.length;
      if (pos > acc && pos < acc + len) {
        const cut: number = pos - acc;
        const a: RichRun = {
          text: r.text.substring(0, cut), bold: r.bold, italic: r.italic, underline: r.underline,
          strike: r.strike, color: r.color, heading: r.heading, size: r.size
        };
        const b: RichRun = {
          text: r.text.substring(cut), bold: r.bold, italic: r.italic, underline: r.underline,
          strike: r.strike, color: r.color, heading: r.heading, size: r.size
        };
        out.push(a);
        out.push(b);
      } else {
        out.push(r);
      }
      acc += len;
    }
    return out;
  }

  /** 应用一条样式操作（区间内片段统一开/关） */
  private static applyOneOp(runs: RichRun[], op: StyleOp): RichRun[] {
    let list: RichRun[] = RichHtml.splitRunsAt(runs, op.start);
    list = RichHtml.splitRunsAt(list, op.end);
    const out: RichRun[] = [];
    let acc: number = 0;
    for (let i: number = 0; i < list.length; i++) {
      const r: RichRun = list[i];
      const len: number = r.text.length;
      const inRange: boolean = len > 0 && acc >= op.start && acc + len <= op.end;
      if (!inRange) {
        out.push(r);
        acc += len;
        continue;
      }
      const n: RichRun = {
        text: r.text, bold: r.bold, italic: r.italic, underline: r.underline,
        strike: r.strike, color: r.color, heading: r.heading, size: r.size
      };
      if (op.kind === 'bold') {
        n.bold = op.on;
      } else if (op.kind === 'italic') {
        n.italic = op.on;
      } else if (op.kind === 'underline') {
        n.underline = op.on;
        if (op.on) {
          n.strike = false; // 编辑器同一时刻只保留一种装饰线
        }
      } else if (op.kind === 'strike') {
        n.strike = op.on;
        if (op.on) {
          n.underline = false;
        }
      } else if (op.kind === 'color') {
        n.color = op.on ? op.color : '';
      }
      out.push(n);
      acc += len;
    }
    return out;
  }

  /**
   * 确定性富文本格式化（兜底）：
   * 部分模型（如视觉模型）只输出 <h2>/<h3>/<p> 等结构标签而忽略行内样式，
   * 导致预览与导出"看起来没格式"。本方法在检测到"完全没有行内样式标签"时，
   * 按教学文案的通用规律确定性地注入加粗/重点色；已有行内样式的内容原样返回。
   */
  static enhanceFormatting(html: string): string {
    if (html.trim() === '' || !RichHtml.looksLikeHtml(html)) {
      return html;
    }
    const lower: string = html.toLowerCase();
    if (lower.indexOf('<b>') >= 0 || lower.indexOf('<strong>') >= 0 || lower.indexOf('<i>') >= 0 ||
      lower.indexOf('<u>') >= 0 || lower.indexOf('<s>') >= 0 || lower.indexOf('<font ') >= 0) {
      return html;
    }
    // 仅处理文本节点，避免破坏标签结构
    return html.replace(/>([^<]*)</g, (m: string, t: string): string => {
      return '>' + RichHtml.fmtTextNode(t) + '<';
    });
  }

  /** 单个文本节点的确定性格式化（供 enhanceFormatting 使用） */
  private static fmtTextNode(text: string): string {
    let s: string = text;
    // Markdown 残留兜底
    s = s.replace(/\*\*([^*]+)\*\*/g, '<b>$1</b>');
    // 方括号强调（教案/试题常见）
    s = s.replace(/【([^】]+)】/g, '<b>【$1】</b>');
    // 重难点类标签：红色加粗（教学常规视觉）
    s = s.replace(/^(教学重点|教学难点|重点|难点|易错点|考点)([：:])/, '<font color="#cc0000"><b>$1$2</b></font>');
    // 常见固定字段标签：加粗
    s = s.replace(/^(学科|教材版本|版本|年级|课时|课型|教学目标|知识与技能|过程与方法|情感态度与价值观|核心素养|教学准备|教师准备|学生准备|环境准备|学情分析|设计意图|板书设计|作业布置|分层作业|教学反思|评价方式|课堂小结|小结|作业|反思|导入|情境导入)([：:])/, '<b>$1$2</b>');
    // 师生活动标签：加粗
    s = s.replace(/^(师|生|教师|学生)([：:])/, '<b>$1$2</b>');
    s = s.replace(/([。；;！!？?])(师|生)([：:])/g, '$1<b>$2$3</b>');
    // 环节标题：加粗
    s = s.replace(/^(环节[一二三四五六七八九十0-9]+[^<]{0,20})/, '<b>$1</b>');
    return s;
  }

  /** 取 <font color="..."> 里的颜色（合法十六进制才返回，否则 ''） */
  private static pickColor(attr: string): string {
    const m = attr.match(/color\s*=\s*["']?#?([0-9a-fA-F]{6}|[0-9a-fA-F]{3})["']?/);
    if (m === null) {
      return '';
    }
    let hex: string = m[1];
    if (hex.length === 3) {
      hex = hex[0] + hex[0] + hex[1] + hex[1] + hex[2] + hex[2];
    }
    return hex.toLowerCase();
  }

  /**
   * HTML → 样式片段（供 RichEditor 逐段 addTextSpan 载入）
   * 解析算法：顺序扫描文本与白名单标签，维护行内样式栈；
   * <h2>/<h3> 按标题片段处理（加粗 + 字号），<p>/<br> 归入换行语义。
   */
  static htmlToRuns(html: string): RichRun[] {
    const runs: RichRun[] = [];
    let bold: boolean = false;
    let italic: boolean = false;
    let underline: boolean = false;
    let strike: boolean = false;
    let color: string = '';
    let heading: number = 0;
    let buf: string = '';

    const flush = (): void => {
      if (buf === '') {
        return;
      }
      const last: RichRun | undefined = runs.length > 0 ? runs[runs.length - 1] : undefined;
      if (last !== undefined && last.bold === bold && last.italic === italic &&
        last.underline === underline && last.strike === strike && last.color === color &&
        last.heading === heading) {
        last.text += buf;
      } else {
        const h: number = heading > 0 ? heading : 0;
        runs.push({
          text: buf, bold: bold, italic: italic, underline: underline, strike: strike,
          color: color, heading: h, size: h === 2 ? 19 : (h === 3 ? 17 : 0)
        });
      }
      buf = '';
    };

    let i: number = 0;
    const n: number = html.length;
    while (i < n) {
      const c: string = html[i];
      if (c !== '<') {
        buf += c;
        i++;
        continue;
      }
      const end: number = html.indexOf('>', i);
      if (end < 0) {
        buf += html.substring(i);
        break;
      }
      const rawTag: string = html.substring(i + 1, end).trim();
      i = end + 1;
      const closing: boolean = rawTag.startsWith('/');
      const namePart: string = closing ? rawTag.substring(1).trim() : rawTag;
      const sp: number = namePart.indexOf(' ');
      const name: string = (sp >= 0 ? namePart.substring(0, sp) : namePart).toLowerCase();
      const attr: string = sp >= 0 ? namePart.substring(sp + 1) : '';
      if (!closing) {
        if (name === 'b' || name === 'strong') {
          flush();
          bold = true;
        } else if (name === 'i' || name === 'em') {
          flush();
          italic = true;
        } else if (name === 'u') {
          flush();
          underline = true;
        } else if (name === 's' || name === 'del') {
          flush();
          strike = true;
        } else if (name === 'font') {
          const col: string = RichHtml.pickColor(attr);
          if (col !== '') {
            flush();
            color = col;
          }
        } else if (name === 'h2' || name === 'h3' || name === 'h1' || name === 'h4') {
          flush();
          heading = name === 'h2' ? 2 : (name === 'h3' ? 3 : 0);
          bold = true;
          if (name === 'h1') {
            heading = 2;
          }
        } else if (name === 'p' || name === 'br' || name === 'div') {
          flush();
          buf += '\n';
        } else if (name === 'ul' || name === 'ol' || name === 'li' || name === 'table' ||
          name === 'tr' || name === 'td' || name === 'th') {
          // 兜底：不支持的块级一律按换行处理，避免内容粘连
          flush();
          buf += '\n';
        }
      } else {
        if (name === 'b' || name === 'strong') {
          flush();
          bold = false;
        } else if (name === 'i' || name === 'em') {
          flush();
          italic = false;
        } else if (name === 'u') {
          flush();
          underline = false;
        } else if (name === 's' || name === 'del') {
          flush();
          strike = false;
        } else if (name === 'font') {
          flush();
          color = '';
        } else if (name === 'h2' || name === 'h3' || name === 'h1' || name === 'h4') {
          flush();
          heading = 0;
          bold = false;
        } else if (name === 'p' || name === 'div') {
          flush();
          buf += '\n';
        }
      }
    }
    flush();
    return runs;
  }

  /** 片段 → 存储用 HTML（不带字号，样式仅来自用户设置；编辑器保存/回写调用） */
  static runsToHtml(runs: RichRun[]): string {
    return RichHtml.runsToHtmlEx(runs, '');
  }

  /** 片段 → 展示用 HTML（正文统一带 size 放大；RichText 渲染） */
  static runsToDisplayHtml(runs: RichRun[]): string {
    return RichHtml.runsToHtmlEx(runs, RichHtml.VIEW_SIZE);
  }

  /** 片段 → HTML（编辑器保存/回写）。段落按 \n 切分，整段加粗且源自标题则还原为 <h2> */
  private static runsToHtmlEx(runs: RichRun[], sizeStr: string): string {
    // 先按换行把片段拆成"段内子片段"，记录段边界
    const segs: HtmlSeg[] = [];
    for (let r: number = 0; r < runs.length; r++) {
      const run: RichRun = runs[r];
      const parts: string[] = run.text.split('\n');
      for (let k: number = 0; k < parts.length; k++) {
        if (parts[k] !== '') {
          segs.push({
            text: parts[k], bold: run.bold, italic: run.italic, underline: run.underline,
            strike: run.strike, color: run.color, size: run.size
          });
        }
        if (k < parts.length - 1) {
          segs.push({ text: '\n', bold: false, italic: false, underline: false, strike: false, color: '', size: 0 });
        }
      }
    }
    const out: string[] = [];
    let para: HtmlSeg[] = [];
    const flushPara = (): void => {
      if (para.length === 0) {
        return;
      }
      let headingLevel: number = 0;
      if (para.length >= 1) {
        const first: HtmlSeg = para[0];
        const sizeOk: boolean = first.size >= 17;
        let allSame: boolean = true;
        for (let q: number = 1; q < para.length; q++) {
          if (para[q].bold !== first.bold || para[q].color !== '') {
            allSame = false;
          }
        }
        if (allSame && first.bold && sizeOk) {
          headingLevel = first.size >= 19 ? 2 : 3;
        }
      }
      const buf: string[] = [];
      const segSize: string = headingLevel > 0 ? '' : sizeStr;
      for (let q: number = 0; q < para.length; q++) {
        buf.push(RichHtml.wrapInline(para[q], segSize));
      }
      const body: string = buf.join('');
      if (headingLevel > 0) {
        out.push('<h' + headingLevel + '>' + body + '</h' + headingLevel + '>');
      } else {
        out.push('<p>' + body + '</p>');
      }
      para = [];
    };
    for (let q: number = 0; q < segs.length; q++) {
      const seg: HtmlSeg = segs[q];
      if (seg.text === '\n') {
        flushPara();
      } else {
        para.push(seg);
      }
    }
    flushPara();
    return out.join('');
  }

  /** 单个段内片段 → 内联标签包裹（去空标签；sizeStr 非空时统一加 <font size>） */
  private static wrapInline(seg: HtmlSeg, sizeStr: string): string {
    let t: string = RichHtml.escape(seg.text);
    if (seg.strike) {
      t = '<s>' + t + '</s>';
    }
    if (seg.underline) {
      t = '<u>' + t + '</u>';
    }
    if (seg.italic) {
      t = '<i>' + t + '</i>';
    }
    if (seg.bold) {
      t = '<b>' + t + '</b>';
    }
    const hasColor: boolean = seg.color !== '' && /^[0-9a-fA-F]{6}$/.test(seg.color);
    if (hasColor && sizeStr !== '') {
      t = '<font size="' + sizeStr + '" color="#' + seg.color.toLowerCase() + '">' + t + '</font>';
    } else if (hasColor) {
      t = '<font color="#' + seg.color.toLowerCase() + '">' + t + '</font>';
    } else if (sizeStr !== '') {
      t = '<font size="' + sizeStr + '">' + t + '</font>';
    }
    return t;
  }
}
