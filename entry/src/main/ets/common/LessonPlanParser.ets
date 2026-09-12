/**
 * 教案环节解析：从教案富文本(HTML/纯文本)中解析出"第几分钟 → 什么环节 + 简短提示"的环节列表，
 * 供手机推送到手表端开展"分环节上课计时"。
 * 教案由 AI 按"五、教学过程"分环节、标注时间与师生活动生成，格式不固定，
 * 因此采用容错启发式解析；解析不到有效环节时回退到默认四段式，保证手表端始终有课可上。
 */

/** 手表端上课的一个环节 */
export interface LessonStage {
  /** 环节序号（1 起） */
  n: number;
  /** 起始分钟（相对上课开始，0 起） */
  startMin: number;
  /** 结束分钟（相对上课开始） */
  endMin: number;
  /** 环节名，如"导入" */
  name: string;
  /** 简短提示，如"引入生活中的例子" */
  hint: string;
}

const STAGE_KEYWORDS: string[] = [
  '课堂导入', '情境导入', '复习导入', '课题导入', '导入', '导课', '热身', '开课',
  '新授课', '新授', '讲授新课', '讲授', '讲解', '精讲', '探究', '演示', '示范', '例题',
  '巩固练习', '课堂练习', '随堂练习', '当堂训练', '变式训练', '练习', '巩固', '强化', '应用', '拓展', '迁移',
  '小结', '总结', '回顾', '课堂小结', '梳理', '归纳',
  '作业', '布置作业', '堂测', '测评', '检测', '验收',
  '环节一', '环节二', '环节三', '环节四', '环节五', '第一环节', '第二环节', '第三环节', '第四环节'
];

/** 教案中一处时间标注的解析结果 */
interface TimeInfo {
  start: number;
  end: number;
  hint: string;
  /** 时间标注结束索引，用于从行首剥离 */
  endIdx: number;
}

export class LessonPlanParser {
  /** 解析失败时的默认四段式（约 40 分钟一节课） */
  static readonly DEFAULT_STAGES: LessonStage[] = [
    { n: 1, startMin: 0, endMin: 5, name: '导入', hint: '引入课题，创设情境，激发兴趣' },
    { n: 2, startMin: 5, endMin: 20, name: '新授', hint: '讲解重难点，结合生活实例，师生互动' },
    { n: 3, startMin: 20, endMin: 35, name: '练习', hint: '当堂练习，巩固提升，及时反馈' },
    { n: 4, startMin: 35, endMin: 40, name: '小结', hint: '总结回顾，梳理要点，布置作业' }
  ];

  /** 教案对象是否为"教案"类型（供流转时判断是否走手表上课流程） */
  static isPlanType(type: string): boolean {
    const t: string = (type === undefined ? '' : type).toLowerCase();
    return t === 'plan' || t === 'lesson' || t === 'lessonplan' || t === 'teaching' ||
      t.indexOf('教案') >= 0 || t.indexOf('lesson') >= 0;
  }

  /** 解析教案富文本 → 环节列表；失败/无有效环节时回退默认四段式 */
  static parse(html: string): LessonStage[] {
    const text: string = LessonPlanParser.toPlainText(html);
    const body: string = LessonPlanParser.processSection(text);
    if (body === '') {
      return LessonPlanParser.DEFAULT_STAGES;
    }
    const lines: string[] = body.split('\n');
    const stages: LessonStage[] = [];
    let curMin: number = 0;
    let pendingHint: string = '';
    for (let i: number = 0; i < lines.length; i++) {
      const raw: string = lines[i].trim();
      if (raw === '' || LessonPlanParser.isLabel(raw)) {
        continue;
      }
      const time: TimeInfo | null = LessonPlanParser.matchTime(raw);
      if (time !== null) {
        const minutes: number = time.end - time.start;
        const clean: string = LessonPlanParser.stripTime(raw, time);
        const name: string = LessonPlanParser.extractName(clean);
        let hint: string = time.hint !== '' ? time.hint : LessonPlanParser.extractHint(clean);
        if (pendingHint !== '') {
          hint = (hint !== '' ? hint + '；' : '') + pendingHint;
          pendingHint = '';
        }
        const st: LessonStage = {
          n: stages.length + 1,
          startMin: curMin,
          endMin: curMin + minutes,
          name: name,
          hint: LessonPlanParser.truncate(hint, 40)
        };
        stages.push(st);
        curMin += minutes;
      } else if (stages.length > 0) {
        // 无时间标注的文字并入上一环节的提示
        pendingHint = LessonPlanParser.mergeHint(pendingHint, raw);
      }
    }
    if (stages.length === 0) {
      return LessonPlanParser.DEFAULT_STAGES;
    }
    return stages;
  }

  /** 时间信息：起止分钟 + 提示片段（TimeInfo 声明于模块顶层） */
  private static matchTime(line: string): TimeInfo | null {
    // 形如 "导入(1-3分钟)" / "3~5分钟" / "约5分钟" / "第1-3分钟"
    const range: RegExp = /(\d{1,2})\s*(?:[-~至到]|、)\s*(\d{1,2})\s*(?:分钟|分|min|Min)/i;
    const single: RegExp = /(?:约|第)?\s*(\d{1,2})\s*(?:分钟|分|min|Min)/i;
    let m: RegExpMatchArray | null = line.match(range);
    let start: number = 1;
    let end: number = 1;
    let endIdx: number = 0;
    if (m !== null) {
      start = parseInt(m[1], 10);
      end = parseInt(m[2], 10);
      if (end <= start) {
        end = start + 3;
      }
      endIdx = line.indexOf(m[0]) + m[0].length;
    } else {
      m = line.match(single);
      if (m === null) {
        return null;
      }
      start = parseFloat(m[1]) > 0 ? Math.round(parseFloat(m[1])) : 1;
      end = start + 1;
      endIdx = line.indexOf(m[0]) + m[0].length;
    }
    // 时间标注后若紧跟逗号/冒号与文字，取作提示（提到"环节提示/师生活动"则省略）
    let hint: string = '';
    const rest: string = line.substring(endIdx).trim().replace(/^[：:，,]/, '').trim();
    if (rest !== '' && !/^(师生活动|设计意图|说明|环节提示)/.test(rest)) {
      hint = rest;
    }
    return { start: start, end: end, hint: hint, endIdx: endIdx };
  }

  /** 去掉时间标注，留下"环节名/前文"用于取名 */
  private static stripTime(line: string, t: TimeInfo): string {
    let head: string = line.substring(0, t.endIdx).trim();
    // 去掉音尾括号/分隔符再取首段
    head = head.replace(/[（(].*?[)）]/g, ' ');
    head = head.replace(/[\-\s]/g, '');
    return LessonPlanParser.markerless(head);
  }

  /** 去掉行首编号与列表符号 */
  private static markerless(s: string): string {
    let out: string = s.trim();
    out = out.replace(/^\d{1,2}\s*[.、．:：]/g, '');
    out = out.replace(/^[一二三四五六七八九十]+\s*[.、．]/g, '');
    out = out.replace(/^[（(]\s*[一二三四五六]+\s*[)）]/g, '');
    out = out.replace(/^[、·\-—\s]+/g, '');
    out = out.replace(/[。；;，\s'"\"'']+$/g, '');
    return out.trim();
  }

  /** 从清洗后的文本中抽取环节名（优先命中已知关键词） */
  private static extractName(clean: string): string {
    for (let i: number = 0; i < STAGE_KEYWORDS.length; i++) {
      const kw: string = STAGE_KEYWORDS[i];
      if (clean.indexOf(kw) >= 0) {
        return kw;
      }
    }
    return LessonPlanParser.truncate(clean, 5) === '' ? '教学活动' : LessonPlanParser.truncate(clean, 5);
  }

  /** 提示片段：优先用时间后文字，其次用行末说明 */
  private static extractHint(clean: string): string {
    const s: string = clean.replace(/^[^：:]*[：:]/, '').trim();
    return LessonPlanParser.truncate(s, 40);
  }

  private static mergeHint(a: string, b: string): string {
    const t: string = b.replace(/^[、.,。；;，\-\s]+/g, '').trim();
    if (t === '' || LessonPlanParser.isLabel(b)) {
      return a;
    }
    if (a === '') {
      return LessonPlanParser.truncate(t, 40);
    }
    if (a.length + t.length > 48) {
      return a;
    }
    return a + '；' + t;
  }

  /** 是否是无信息量的段落标题（六、板书 / 七、分层作业 等） */
  private static isLabel(s: string): boolean {
    return /^[一二三四五六七八九十]+\s*[、.、（(]*(板书|分层作业|作业设计|教学反思|板书设计)\s*[)）]?/.test(s);
  }

  /** 仅截取"五、教学过程"段落，去掉前后的章节标题 */
  private static processSection(text: string): string {
    const idx: number = text.lastIndexOf('教学过程');
    if (idx < 0) {
      return text;
    }
    let end: number = text.length;
    const nexts: string[] = ['板书', '作业设计', '教学反思', '分层作业'];
    for (let i: number = 0; i < nexts.length; i++) {
      const p: number = text.indexOf(nexts[i], idx + 4);
      if (p >= 0 && p < end) {
        end = p;
      }
    }
    return text.substring(idx, end);
  }

  private static truncate(s: string, max: number): string {
    return s.length > max ? s.substring(0, max) : s;
  }

  /** HTML 富文本 → 纯文本（按块换行） */
  private static toPlainText(html: string): string {
    let t: string = html;
    t = t.replace(/<br\s*\/?>/gi, '\n');
    t = t.replace(/<\/(p|div|li|h1|h2|h3|h4|ol|ul)>/gi, '\n');
    t = t.replace(/<[^>]+>/g, '');
    t = t.replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>');
    t = t.replace(/\r/g, '\n').replace(/\u00A0/g, ' ');
    t = t.replace(/[ \t]+/g, ' ');
    return t;
  }

  /** 秒 → "mm:ss" 或 "xh" 便于手表端展示 */
  static formatClock(totalSec: number): string {
    const s: number = Math.max(0, Math.floor(totalSec));
    const m: number = Math.floor(s / 60);
    const r: number = s % 60;
    return (m < 10 ? '0' + m : m.toString()) + ':' + (r < 10 ? '0' + r : r.toString());
  }
}