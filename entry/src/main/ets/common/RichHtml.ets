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
