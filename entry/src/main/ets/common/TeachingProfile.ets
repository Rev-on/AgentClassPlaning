/**
 * 任教信息：读取设置中的科目/年级/基础水平，并按时间自动推进"册次"。
 * 推进规则（以用户设置的起始册次为基准，例如 2026-09 设置七年级上册、物理）：
 *   - 每 2 月切换一次上/下册：9 月～次年 1 月＝上册，2 月～7 月＝下册；
 *   - 进入新学年的 9 月：年级 +1（七年级→八年级→九年级），并复位为上册；
 *   - 从基准学年起逐年推进年级；未设置基准或非法时回退默认（当前九年一贯制按 2026-09 为七年级）。
 */
import common from '@ohos.app.ability.common';
import { AppSettings } from './AppSettings';
import { TextbookCatalog } from './TextbookCatalog';

/** 由任教信息解析出的"当前应教的课题上下文" */
export interface TeachingContext {
  subject: string;
  grade: number;
  /** 当期册次：'A'=上册 / 'B'=下册 */
  half: string;
  /** 学生基础水平：strong/normal/weak */
  level: string;
  /** 当前应教的下一课课题（来自教材目录自动推进；无目录匹配时为空，由编排器决定课题） */
  nextTopic: string;
  /** 提示语：本次要生成的内容定位（学科+年级+册次+课题） */
  headline: string;
}

export class TeachingProfile {
  /** 学年起始月（9 月进入新学年） */
  private static readonly TERM_A_START_MONTH: number = 9;
  /** 上下册切换月（2 月切换为下册） */
  private static readonly TERM_B_START_MONTH: number = 2;
  /** 默认起始学年：2026 年 9 月＝七年级上册（用户未配置基准时） */
  private static readonly DEF_ANCHOR_YEAR: number = 2026;
  private static readonly DEF_ANCHOR_GRADE: number = 7;

  /**
   * 读取当前应教的课题上下文。
   * @param ctx UI 上下文（用于读设置）
   * @param now 当前时间（便于测试传参；默认取系统时间）
   */
  static async current(ctx: common.UIAbilityContext, now?: Date): Promise<TeachingContext> {
    const subject: string = String(AppStorage.get<string>(AppSettings.KEY_TEACH_SUBJECT) ?? '物理');
    let grade: number = Number(AppStorage.get<number>(AppSettings.KEY_TEACH_GRADE) ?? 8);
    const level: string = String(AppStorage.get<string>(AppSettings.KEY_TEACH_LEVEL) ?? 'normal');
    const anchorRaw: string = String(AppStorage.get<string>(AppSettings.KEY_TEACH_ANCHOR) ?? '');
    const lastTopic: string = String(AppStorage.get<string>(AppSettings.KEY_TEACH_LAST_TOPIC) ?? '');
    const d: Date = now !== undefined ? now : new Date();
    const month: number = d.getMonth() + 1; // 1-12
    const year: number = d.getFullYear();

    // 解析基准：anchor = "YYYY-GRADE"（起始为某学年起始，即该年 9 月该年级上册）。
    // 例："2026-7" → 2026 年 9 月起七年级上册。
    let anchorYear: number = TeachingProfile.DEF_ANCHOR_YEAR;
    let anchorGrade: number = TeachingProfile.DEF_ANCHOR_GRADE;
    const m: RegExpMatchArray | null = anchorRaw !== '' ? anchorRaw.match(/^(\d{4})-(\d{1,2})$/) : null;
    if (m !== null) {
      const ay: number = Number(m[1]);
      const ag: number = Number(m[2]);
      if (ay >= 2000 && ay <= 2100 && ag >= 1 && ag <= 9) {
        anchorYear = ay;
        anchorGrade = ag;
      }
    }

    // 学年+学期 → 相对"基准学年"的偏移。
    // 9月起算学期：某年 9 月属于该"学期上半段"；1 月仍属上一学年的上册，2月下半段算下册。
    let half: string = 'A';
    // 当前所处的"学年起始年"：9-12月属于本年份起，1-8月属于上一年份起。
    const schoolYearStart: number = month >= TeachingProfile.TERM_A_START_MONTH ? year : year - 1;
    // 相对基准学年的级差
    const gradeDiff: number = schoolYearStart - anchorYear;
    // 当前年级 = 基准年级 + 级差（封顶 9）
    const halfOfYear: boolean = month < TeachingProfile.TERM_A_START_MONTH &&
      month >= TeachingProfile.TERM_B_START_MONTH; // 2~7 月＝下册
    half = halfOfYear ? 'B' : 'A';
    let curGrade: number = anchorGrade + gradeDiff;
    if (curGrade > 9) {
      curGrade = 9;
    }
    if (curGrade < 1) {
      curGrade = 1;
    }
    // 若用户手动设置了年级（未走基准推算），则年级以其为准，册次仍按月度推进（以其当前月为上册起点）。
    // 规则：优先采用用户显式年级；册次仅在用户未显式修改年级时由 anchor 推进。
    const profileGrade: number = grade;
    grade = profileGrade; // 用户显式年级优先

    const catalogTopic: string = TeachingProfile.nextTopicOf(subject, grade, half, lastTopic);
    const headline: string = TeachingProfile.buildHeadline(subject, grade, half, level, catalogTopic);
    const tc: TeachingContext = {
      subject: subject,
      grade: grade,
      half: half,
      level: level,
      nextTopic: catalogTopic,
      headline: headline
    };
    return tc;
  }

  /** 从教材目录中取"上一课之后的一课"作为待教课题（RAG 自动推进核心） */
  private static nextTopicOf(subject: string, grade: number, half: string, lastTopic: string): string {
    const catalog: string[] = TextbookCatalog.lessonsOf(subject, grade, half);
    if (catalog.length === 0) {
      return '';
    }
    if (lastTopic === '') {
      // 尚未生成本课：默认从目录第一课开始（用户可编辑替换）
      return catalog[0];
    }
    const idx: number = catalog.indexOf(lastTopic);
    if (idx >= 0 && idx + 1 < catalog.length) {
      return catalog[idx + 1];
    }
    // 上一课不在目录或已是最后一课：回退到第一课，避免字段越界并保证始终有课题
    return catalog[0];
  }

  private static buildHeadline(subject: string, grade: number, half: string, level: string,
    topic: string): string {
    const halfZh: string = half === 'A' ? '上册' : '下册';
    const part: string = topic !== '' ? '，课题《' + topic + '》' : '';
    return subject + grade + '年级' + halfZh + part + '（学生基础：' + level + '）';
  }
}