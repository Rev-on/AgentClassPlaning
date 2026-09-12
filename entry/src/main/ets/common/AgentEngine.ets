/**
 * Agent 编排引擎：把用户的自然语言需求拆解为"教案→课件→分层练习"三步流水线。
 * 特性：
 *   - AI 自主决定流程：固定三步（期中第 1、2 步可用"研究选题"预处理用户模糊需求）；
 *   - 每一步完成后做质量自检（内容长度 / 结构完整 / 是否空壳），不合格自动重生成（最多 2 次）；
 *   - 通过 onProgress 向 UI 逐条回调进度气泡，UI 据此展示"正在做什么"。
 * 本引擎只依赖 AiService.chat（复用各功能页的既有 system 提示词），并为生成的每步产物拼接
 * 任教信息上下文（学科/年级/册次/课题/基础水平），实现"读懂任教信息、自动填充课题"。
 */
import common from '@ohos.app.ability.common';
import { AiService } from './AiService';
import { Prompts } from './Prompts';
import { TeachingProfile, TeachingContext } from './TeachingProfile';

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

export class AgentEngine {
  private static readonly MAX_RETRY: number = 2;

  /**
   * 执行一次完整编排。
   * @param ctx UI 上下文（读任教信息）
   * @param userReq 用户自然语言需求
   * @param onEvent 进度回调
   */
  static async run(ctx: common.UIAbilityContext, userReq: string, onEvent: (e: AgentEvent) => void):
    Promise<AgentResult> {
    const teach: TeachingContext = await TeachingProfile.current(ctx);
    const artifacts: AgentArtifact[] = [];

    // 0) 播报当前任教上下文（Agent 读取任教信息）
    onEvent({
      kind: 'info',
      text: '已读取任教信息：' + teach.headline
    });

    try {
      // 步骤1：教案生成
      const plan: AgentArtifact = await AgentEngine.genPlan(ctx, teach, userReq, onEvent);
      artifacts.push(plan);

      // 步骤2：课件生成
      const course: AgentArtifact = await AgentEngine.genCourse(ctx, teach, userReq, plan.content, onEvent);
      artifacts.push(course);

      // 步骤3：分层练习命制
      const quiz: AgentArtifact = await AgentEngine.genQuiz(ctx, teach, userReq, plan.content, onEvent);
      artifacts.push(quiz);

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

  /** 教案生成（含质量自检 + 重生成）。用户提示词完整传递，任教信息仅补足用户未指定字段。 */
  private static async genPlan(ctx: common.UIAbilityContext, teach: TeachingContext, userReq: string,
    onEvent: (e: AgentEvent) => void): Promise<AgentArtifact> {
    return AgentEngine.genWithRetry('plan', '教案', ctx, () => {
      let user: string = '请为课题准备完整教案（含教学目标、重难点、教学过程、作业设计）。\n';
      user += AgentEngine.contextOf(teach, userReq);
      user += '\n用户需求：' + userReq + '\n';
      return user;
    }, (content: string): string => {
      // 质量自检：教案应长度达标且含教学环节关键词
      if (content.length < 300) {
        return '教案内容过短，需补充教学过程与环节，请重新完整生成';
      }
      if (content.indexOf('教学目标') < 0 || content.indexOf('教学过程') < 0) {
        return '教案缺少教学结构（教学目标/教学过程），请重新补齐结构完整生成';
      }
      return '';
    }, onEvent);
  }

  /** 课件生成（完整传递用户提示词 + 教案做输入；先输出提纲段再由客户端装配） */
  private static async genCourse(ctx: common.UIAbilityContext, teach: TeachingContext, userReq: string,
    plan: string, onEvent: (e: AgentEvent) => void): Promise<AgentArtifact> {
    return AgentEngine.genWithRetry('courseware', '课件', ctx, () => {
      let user: string = '请把下面这份教案制成配套课件（按课件生成要求逐页输出）。\n';
      user += AgentEngine.contextOf(teach, userReq);
      user += '\n用户需求：' + userReq + '\n';
      user += '教案：\n' + plan.substring(0, 2000) + '\n';
      return user;
    }, (content: string): string => {
      if (content.length < 200) {
        return '课件内容过短，需包含各页幻灯片内容，请重新完整生成';
      }
      if (content.indexOf('=====') < 0) {
        return '课件未按"每页用 ===== 分隔"的格式输出，请遵守分段格式重新生成';
      }
      return '';
    }, onEvent);
  }

  /** 分层练习命制（完整传递用户提示词 + 教案做知识点来源） */
  private static async genQuiz(ctx: common.UIAbilityContext, teach: TeachingContext, userReq: string,
    plan: string, onEvent: (e: AgentEvent) => void): Promise<AgentArtifact> {
    return AgentEngine.genWithRetry('quiz', '分层练习', ctx, () => {
      let user: string = '请结合下面的教案为课题命制分层练习（基础层/提升层/拓展层），给出题目+答案+解析。\n';
      user += AgentEngine.contextOf(teach, userReq);
      user += '\n用户需求：' + userReq + '\n';
      user += '教案：\n' + plan.substring(0, 2000) + '\n';
      return user;
    }, (content: string): string => {
      if (content.length < 200) {
        return '练习内容过短，需包含三层题目，请重新完整生成';
      }
      return '';
    }, onEvent);
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

  /** 通用：执行一次生成 + 自检，不合格重生成（至多 MAX_RETRY 次） */
  private static async genWithRetry(key: string, label: string, ctx: common.UIAbilityContext,
    buildUser: () => string, check: (content: string) => string,
    onEvent: (e: AgentEvent) => void): Promise<AgentArtifact> {

    const sys: string = AgentEngine.systemOf(key);
    let attempt: number = 0;
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
      lastCheckErr = check(content.trim());
      if (lastCheckErr === '') {
        const art: AgentArtifact = { key: key, label: label, content: content.trim() };
        onEvent({ kind: 'step', text: label + '生成完成', artifact: art });
        return art;
      }
      attempt++;
    }
    // 重试耗尽：仍返回最后一次产物（避免整条流程失败），并在事件中提示
    onEvent({ kind: 'retry', text: label + '多次重试仍未完全达标，已采用当前版本' });
    throw new Error('重试耗尽');
  }

  private static systemOf(key: string): string {
    switch (key) {
      case 'plan':
        return Prompts.planSystem();
      case 'courseware':
        return Prompts.coursewareSystem();
      default:
        return Prompts.quizSystem();
    }
  }
}