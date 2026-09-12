/**
 * Agent 编排引擎：把用户的自然语言需求拆解为可执行的"备课产物"清单并逐份生成。
 * 特性：
 *   - AI 自主规划：先由一次调度调用判断用户要做哪几份产物（可选：教案/课件/习题/
 *     教研辅助/学情分析/学情报告/沟通话术），同一类可多份、产物份数不限；
 *     用户未指定产物类型时默认生成三份（教案→课件→习题）；
 *   - 每份产物完成后做质量自检（内容长度 / 结构完整），不合格自动重生成（最多 2 次）；
 *   - 通过 onEvent 向 UI 逐条回调进度气泡（思考/完成/重试/错误）。
 * 提示词优先级：用户提示词内的详细要求优先，任教信息仅补足用户未指明的字段；
 * 用户原始提示词会被完整传递给 AI。
 */
import common from '@ohos.app.ability.common';
import { AiService } from './AiService';
import { Prompts } from './Prompts';
import { TeachingProfile, TeachingContext } from './TeachingProfile';

/** 受支持的产物类型（对应首页 7 个生成功能卡） */
export type ProductKey = 'plan' | 'courseware' | 'quiz' | 'research' | 'analysis' | 'report' | 'talk';

/** 编排规划的每一份产物 */
interface PlannedProduct {
  type: ProductKey;
  /** 展示名，为空时按类型取默认名 */
  label: string;
  /** 用户对本份产物的额外要求 */
  hint: string;
}

/** 编排每一步的产物 */
export interface AgentArtifact {
  key: string;
  label: string;
  content: string;
}

/** 进度回调消息 */
export interface AgentEvent {
  kind: 'info' | 'thinking' | 'step' | 'retry' | 'done' | 'error';
  text: string;
  /** kind=step 时指向对应产物 */
  artifact?: AgentArtifact;
}

/** 编排结果 */
export interface AgentResult {
  ok: boolean;
  artifacts: AgentArtifact[];
  error: string;
}

/** 一条历史对话（多轮续聊用）；speaker=user 为用户消息，agent 为助手消息 */
export interface AgentHistoryItem {
  speaker: 'user' | 'agent';
  text: string;
}

export class AgentEngine {
  private static readonly MAX_RETRY: number = 2;
  /** 单次编排产物的最大份数，防止失控 */
  private static readonly MAX_PRODUCTS: number = 8;
  /** 多轮对话最多记入上下文的回合数（超出部分先滚动掉，再靠压缩保证可追溯性） */
  private static readonly MAX_HISTORY_ROUNDS: number = 24;
  /** 历史原文总长度超过该字符数即触发上下文压缩 */
  private static readonly MAX_RAW_HISTORY: number = 3000;
  /** Agent 人设：幽默的资深教研员。仅作用于 Agent 编排模式的系统提示词前缀。 */
  private static readonly PERSONA: string =
    '你是一位教研经验丰富、说话幽默风趣的资深教研员。你的表达轻松俏皮、常带恰当的比喻与自嘲，' +
    '让备课交流不再枯燥；但给出的教学设计必须专业严谨、紧贴课标与实际学情，做到"有趣又有料"。';
  /** 用户未指定产物类型时的默认三份 */
  private static readonly DEFAULT_PRODUCTS: PlannedProduct[] = [
    { type: 'plan', label: '', hint: '' },
    { type: 'courseware', label: '', hint: '' },
    { type: 'quiz', label: '', hint: '' }
  ];

  /**
   * 执行一次完整编排（支持多轮续聊）。
   * @param ctx UI 上下文（读任教信息）
   * @param userReq 用户自然语言需求
   * @param history 历史对话（多轮续聊用）；上下文过长时自动压缩为要点，保证稳定
   * @param onEvent 进度回调
   */
  static async run(ctx: common.UIAbilityContext, userReq: string, history: AgentHistoryItem[],
    onEvent: (e: AgentEvent) => void): Promise<AgentResult> {
    const teach: TeachingContext = await TeachingProfile.current(ctx);
    const artifacts: AgentArtifact[] = [];

    try {
      // 0) 多轮对话上下文：原样记录或（过长时）压缩为要点，供规划与逐份生成共用
      const historyBlock: string = await AgentEngine.historyBlock(ctx, history, onEvent);

      // 1) AI 自主规划要生成的产物清单（含默认三份兜底）
      const planned: PlannedProduct[] = await AgentEngine.planProducts(ctx, teach, userReq, historyBlock);
      onEvent({
        kind: 'info',
        text: '已识别出 ' + planned.length + ' 份产物，开始逐份生成…'
      });

      // 2) 逐份生成（含质量自检 + 自动重生成）
      for (let i: number = 0; i < planned.length; i++) {
        const p: PlannedProduct = planned[i];
        const label: string = p.label !== '' ? p.label : AgentEngine.titleOf(p.type);
        // 同一份产物的个性化编号展示（多份同类型时区分"第N份"）
        const shown: string = AgentEngine.serializeLabel(p, label, planned, i);
        const art: AgentArtifact = await AgentEngine.genWithRetry(p.type, shown, ctx, () => {
          let user: string = '请基于用户需求生成内容。\n';
          const ctxBlock: string = AgentEngine.contextOf(teach, userReq);
          if (ctxBlock !== '') {
            user += ctxBlock;
          }
          if (historyBlock !== '') {
            user += '\n' + historyBlock;
          }
          user += '\n本次用户需求：' + userReq + '\n';
          if (p.hint !== '') {
            user += '\n本份额外要求：' + p.hint + '\n';
          }
          return user;
        }, AgentEngine.checkOf(p.type), onEvent);
        artifacts.push(art);
      }

      onEvent({ kind: 'done', text: '全部完成，共生成 ' + artifacts.length + ' 份产物' });
      const res: AgentResult = { ok: true, artifacts: artifacts, error: '' };
      return res;
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : '编排失败';
      onEvent({ kind: 'error', text: msg });
      const res2: AgentResult = { ok: false, artifacts: artifacts, error: msg };
      return res2;
    }
  }

  /** 产物类型 → 默认展示名 */
  static titleOf(type: ProductKey): string {
    switch (type) {
      case 'plan':
        return '教案';
      case 'courseware':
        return '课件';
      case 'quiz':
        return '分层练习';
      case 'research':
        return '教研辅助';
      case 'analysis':
        return '学情分析';
      case 'report':
        return '学情报告';
      case 'talk':
        return '沟通话术';
    }
  }

  /** 同一类型出现多份时，追加"·第N份"编号；单份不编号 */
  private static serializeLabel(p: PlannedProduct, label: string, planned: PlannedProduct[],
    idx: number): string {
    let same: number = 0;
    for (let i: number = 0; i < planned.length; i++) {
      if (planned[i].type === p.type) {
        same++;
      }
    }
    if (same <= 1) {
      return label;
    }
    let before: number = 0;
    for (let i: number = 0; i < idx; i++) {
      if (planned[i].type === p.type) {
        before++;
      }
    }
    return label + '(第' + (before + 1) + '份)';
  }

  /** 产物类型 → 默认展示名（供分享等场景去除编号） */
  static plainOf(type: ProductKey): string {
    return AgentEngine.titleOf(type);
  }

  /**
   * AI 自主规划：一次调度调用，解析用户需求应生成哪几份产物。
   * 返回空清单（解析失败/无有效类型）时回退默认三份。
   */
  private static async planProducts(ctx: common.UIAbilityContext, teach: TeachingContext,
    userReq: string, historyBlock: string): Promise<PlannedProduct[]> {
    void ctx;
    try {
      const sys: string = AgentEngine.personaPrefix(AgentEngine.plannerSystem());
      const usr: string = '用户需求：' + userReq + '\n' +
        (historyBlock !== '' ? historyBlock + '\n' : '') +
        AgentEngine.contextOf(teach, userReq);
      const raw: string = await AiService.chat(sys, usr, () => {
        // 规划结果无需增量展示
      }, true);
      const list: PlannedProduct[] = AgentEngine.parsePlan(raw);
      if (list.length === 0) {
        return AgentEngine.DEFAULT_PRODUCTS;
      }
      return list.slice(0, AgentEngine.MAX_PRODUCTS);
    } catch (e) {
      return AgentEngine.DEFAULT_PRODUCTS;
    }
  }

  /** 调度系统提示词：只输出类型清单，逐行 type=xx;label=xx */
  private static plannerSystem(): string {
    return '你是备课任务调度器。根据用户的一句话需求，判定应生成哪几份备课产物并将其调度到对应功能。可选类型：\n' +
      'plan=教案；courseware=课件(PPT/幻灯片)；quiz=分层练习(习题)；' +
      'research=教研辅助(选题/论文)；analysis=学情分析(成绩数据分析)；report=学情报告(给家长)；talk=沟通话术。\n' +
      '判定规则：\n' +
      '1. 用户明确要求哪几类产物，就只生成哪几类；用户明确要多份时输出多行同一类型（如"两份教案"输出两行 type=plan）。\n' +
      '2. 用户只给模糊备课需求、没有指定具体产物类型时，输出且只输出这三行：type=plan;label=教案\ntype=courseware;label=课件\ntype=quiz;label=分层练习\n' +
      '3. 每行严格一行，格式：type=<类型码>;label=<简短中文名标签>。\n' +
      '除清单本身外，不得输出任何其它文字、编号、解释或代码围栏。';
  }

  /** 解析规划输出：逐行匹配 type=xx;label=xx，映射别名，忽略非法行 */
  private static parsePlan(raw: string): PlannedProduct[] {
    const out: PlannedProduct[] = [];
    const lines: string[] = raw.split('\n');
    for (let i: number = 0; i < lines.length; i++) {
      const line: string = lines[i].trim();
      const m: RegExpMatchArray | null = line.match(/^type\s*=\s*([^\s;]+)\s*;\s*label\s*=\s*(.+)$/i);
      if (m === null) {
        continue;
      }
      const key: ProductKey | null = AgentEngine.typeAlias(m[1]);
      if (key === null) {
        continue;
      }
      let label: string = m[2].trim().replace(/[；;]$/, '');
      if (label === '') {
        label = AgentEngine.titleOf(key);
      }
      if (out.length < AgentEngine.MAX_PRODUCTS) {
        out.push({ type: key, label: label, hint: '' });
      }
    }
    return out;
  }

  /** 类型码别名归一化（含中文名/英文名），未知返回 null */
  private static typeAlias(code: string): ProductKey | null {
    const m: string = code.trim().toLowerCase();
    if (m === 'plan' || m === 'lessonplan' || m === '教案') {
      return 'plan';
    }
    if (m === 'courseware' || m === 'ppt' || m === 'slides' || m === '课件' || m === '幻灯片') {
      return 'courseware';
    }
    if (m === 'quiz' || m === 'practice' || m === 'exercise' || m.indexOf('练习') >= 0 ||
      m.indexOf('习题') >= 0) {
      return 'quiz';
    }
    if (m === 'research' || m === 'teacherres' || m.indexOf('教研') >= 0 || m.indexOf('选题') >= 0 ||
      m.indexOf('论文') >= 0 || m.indexOf('研学') >= 0) {
      return 'research';
    }
    if (m === 'analysis' || m.indexOf('分析') >= 0) {
      return 'analysis';
    }
    if (m === 'report' || m.indexOf('学情报告') >= 0 || m.indexOf('报告') >= 0) {
      return 'report';
    }
    if (m === 'talk' || m.indexOf('话术') >= 0 || m.indexOf('沟通') >= 0 || m.indexOf('家校') >= 0) {
      return 'talk';
    }
    return null;
  }

  /**
   * 合并"系统任教信息"与"用户提示词"。优先级规则：提示词中已含有的信息
   * （科目/年级/课题/学生基础）一律以用户为准，不做覆盖；仅补齐用户未指明的字段。
   */
  private static contextOf(teach: TeachingContext, userReq: string): string {
    let out: string = '';
    // 科目：提示词未出现任教科目名时才补充
    if (userReq.indexOf(teach.subject) < 0) {
      out += '\n科目：' + teach.subject;
    }
    // 年级：提示词未提及该年级（阿拉伯/中文数字）时才补充
    if (!AgentEngine.mentionsGrade(userReq, teach.grade)) {
      out += '\n年级：' + teach.grade + '年级';
    }
    // 课题：提示词用了书名号（已自定课题）时以用户为准，否则带出系统下一课课题
    if (teach.nextTopic !== '' && userReq.indexOf('《') < 0) {
      out += '\n课题：《' + teach.nextTopic + '》';
    }
    // 学生基础：提示词未涉及"基础"再补充
    if (userReq.indexOf('基础') < 0) {
      out += '\n学生基础：' + AgentEngine.levelZh(teach.level);
    }
    return out;
  }

  /** 用户提示词是否已提及指定年级（支持"7年级/七年级"写法）。 */
  private static mentionsGrade(userReq: string, grade: number): boolean {
    if (userReq.indexOf(grade.toString() + '年级') >= 0) {
      return true;
    }
    const cn: string[] = ['零', '一', '二', '三', '四', '五', '六', '七', '八', '九'];
    if (grade >= 1 && grade <= 9 && userReq.indexOf(cn[grade] + '年级') >= 0) {
      return true;
    }
    return false;
  }

  /** 学生基础水平映射为中文，便于提示词可读。 */
  private static levelZh(level: string): string {
    switch (level) {
      case 'strong':
        return '优';
      case 'weak':
        return '薄弱';
      default:
        return '中等';
    }
  }

  /** 产物类型 → 系统提示词（注入"幽默的资深教研员"人设） */
  private static systemOf(type: ProductKey): string {
    switch (type) {
      case 'plan':
        return AgentEngine.personaPrefix(Prompts.planSystem());
      case 'courseware':
        return AgentEngine.personaPrefix(Prompts.coursewareSystem());
      case 'quiz':
        return AgentEngine.personaPrefix(Prompts.quizSystem());
      case 'research':
        return AgentEngine.personaPrefix(Prompts.researchTopicSystem());
      case 'analysis':
        return AgentEngine.personaPrefix(Prompts.analysisSystem());
      case 'report':
        return AgentEngine.personaPrefix(Prompts.studentReportSystem());
      case 'talk':
        return AgentEngine.personaPrefix(Prompts.talkSystem());
    }
  }

  /** 在系统提示词前注入 Agent 人设 */
  private static personaPrefix(sys: string): string {
    return AgentEngine.PERSONA + '\n' + sys;
  }

  /**
   * 多轮对话上下文构建：前提对话不超阈值时原样记录；历史过长时调用 AI 压缩为要点，
   * 既保留关键信息又控制上下文长度。任何异常都回退为"仅取最近两轮"，绝不抛错，保证多轮稳定性。
   */
  private static async historyBlock(ctx: common.UIAbilityContext, history: AgentHistoryItem[],
    onEvent: (e: AgentEvent) => void): Promise<string> {
    void ctx;
    if (history.length === 0) {
      return '';
    }
    const recent: AgentHistoryItem[] = history.slice(-AgentEngine.MAX_HISTORY_ROUNDS);
    let total: number = 0;
    for (let i: number = 0; i < recent.length; i++) {
      total += recent[i].text.length;
    }
    if (total <= AgentEngine.MAX_RAW_HISTORY) {
      return '\n【此前多轮对话】\n' + AgentEngine.renderHistory(recent);
    }
    onEvent({ kind: 'info', text: '对话上下文较长，正在压缩历史要点…' });
    try {
      const summary: string = await AiService.chat(
        '你是对话摘要器。把下面的多轮对话压缩为简明中文要点（150字以内）：' +
        '保留用户核心需求、已完成事项概述、尚未完成的要求。只输出要点，不要解释。',
        AgentEngine.renderHistory(recent), (): void => {
        }, true);
      const s: string = summary.trim();
      if (s !== '') {
        return '\n【此前对话关键要点（已压缩）】\n' + s;
      }
      return '\n【此前对话（节选）】\n' + AgentEngine.renderHistory(recent.slice(-1));
    } catch (e) {
      // 压缩失败：回退最近两轮，不阻塞主流程
      return '\n【此前对话（节选）】\n' + AgentEngine.renderHistory(recent.slice(-2));
    }
  }

  /** 把历史对话排版为 "用户：…/助手：…" 的可读文本 */
  private static renderHistory(items: AgentHistoryItem[]): string {
    let sb: string = '';
    for (let i: number = 0; i < items.length; i++) {
      const it: AgentHistoryItem = items[i];
      sb += (it.speaker === 'user' ? '用户：' : '助手：') + it.text + '\n';
    }
    return sb;
  }

  /** 产物类型 → 质量自检函数（返回空串=通过，否则为改进建议） */
  private static checkOf(type: ProductKey): (content: string) => string {
    switch (type) {
      case 'plan':
        return (content: string): string => {
          if (content.length < 300) {
            return '教案内容过短，需补充教学过程与环节，请重新完整生成';
          }
          if (content.indexOf('教学目标') < 0 || content.indexOf('教学过程') < 0) {
            return '教案缺少教学结构（教学目标/教学过程），请重新补齐结构完整生成';
          }
          return '';
        };
      case 'courseware':
        return (content: string): string => {
          if (content.length < 200) {
            return '课件内容过短，需包含各页幻灯片内容，请重新完整生成';
          }
          if (content.indexOf('=====') < 0) {
            return '课件未按"每页用 ===== 分隔"的格式输出，请遵守分段格式重新生成';
          }
          return '';
        };
      case 'quiz':
        return (content: string): string => {
          if (content.length < 200) {
            return '练习内容过短，需包含三层题目，请重新完整生成';
          }
          return '';
        };
      default:
        return (content: string): string => {
          if (content.trim().length < 80) {
            return '内容过短，请重新完整生成';
          }
          return '';
        };
    }
  }

  /** 通用：执行一次生成 + 自检，不合格重生成（至多 MAX_RETRY 次） */
  private static async genWithRetry(key: string, label: string, ctx: common.UIAbilityContext,
    buildUser: () => string, check: (content: string) => string,
    onEvent: (e: AgentEvent) => void): Promise<AgentArtifact> {

    const sys: string = AgentEngine.systemOf(key as ProductKey);
    let attempt: number = 0;
    // 最近一次取词内容：自检全部未通过重试耗尽时，退而交付这份，避免"生成中"悬死
    let lastContent: string = '';
    // 记录最近一次自检错误，供重试时反馈
    let lastCheckErr: string = '';
    while (attempt <= AgentEngine.MAX_RETRY) {
      if (attempt > 0) {
        onEvent({ kind: 'info', text: '检测到' + label + '质量未达标，自动重新生成…' });
      }
      onEvent({ kind: 'thinking', text: '正在生成' + label + '…' });
      // 用户需求 + 任教信息 + 若为重试则附带上次不足
      let user: string = buildUser();
      if (lastCheckErr !== '') {
        user += '\n【上一稿问题】' + lastCheckErr + '。请据此改进。';
      }
      let content: string;
      try {
        content = await AiService.chat(sys, user, () => {
          // 生成中不逐步展示中间内容，由 Agent 事件做分步气泡
        }, true, { ctx: ctx, type: 'agent_' + key, label: label });
      } catch (e) {
        onEvent({ kind: 'error', text: '生成' + label + '失败：' + (e instanceof Error ? e.message : '网络错误') });
        throw e instanceof Error ? e : new Error('生成失败');
      }
      // 质量自检
      const trimmed: string = content.trim();
      lastContent = trimmed;
      lastCheckErr = check(trimmed);
      if (lastCheckErr === '') {
        const art: AgentArtifact = { key: key, label: label, content: trimmed };
        onEvent({ kind: 'step', text: label + '生成完成', artifact: art });
        return art;
      }
      attempt++;
    }
    // 重试耗尽：退而交付最近一次已生成内容，并保证发出 step 以终结"生成中"态
    onEvent({ kind: 'retry', text: label + '多次重试仍未完全达标，已尽量采用当前版本' });
    const best: AgentArtifact = { key: key, label: label, content: lastContent };
    onEvent({ kind: 'step', text: label + '生成完成', artifact: best });
    return best;
  }
}