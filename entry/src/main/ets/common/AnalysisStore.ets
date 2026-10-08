/**
 * 学情分析本地存储：最近一次导入的成绩表格 + 上一次的分析结论。
 *
 * 用途有两个：
 *   ① 【对比分析】再次做学情分析时，自动把**上一次的分析结论**附进 prompt，
 *      让 AI 输出两次的总体对比（进步/退步/趋势）。
 *   ② 【成绩热力图】「我的」页卡片按"科目 × 学生"渲染热力图，
 *      数据来自**最近一次导入的成绩 Excel**。
 *
 * 【隐私】所有数据仅存本机 Preferences，不出来、不外发；
 *        发给 AI 的成绩表格仍走 ExcelParser 的按列脱敏路径（姓名→编号）。
 */
import preferences from '@ohos.data.preferences';
import common from '@ohos.app.ability.common';

/** 最近一次导入的成绩表格（原始未脱敏，仅本机使用） */
export interface ScoreSnapshot {
  /** 表头（第 0 行为列名） */
  headers: string[];
  /** 数据行（与 headers 对齐） */
  rows: string[][];
  /** 导入时间（yyyy-MM-dd HH:mm） */
  time: string;
}

/** 上一次学情分析的结论（用于本次对比） */
export interface LastAnalysis {
  /** 完整分析报告正文 */
  content: string;
  /** 生成时间 */
  time: string;
}

export class AnalysisStore {
  private static readonly STORE: string = 'analysis_store';
  private static readonly KEY_SCORES: string = 'last_scores';
  private static readonly KEY_REPORT: string = 'last_report';
  /** 快照保留的最大数据行数：热力图不适合渲染过多学生，且避免 Preferences 过大 */
  private static readonly MAX_ROWS: number = 200;

  private static async store(context: common.UIAbilityContext): Promise<preferences.Preferences> {
    return await preferences.getPreferences(context, AnalysisStore.STORE);
  }

  /** 保存最近一次导入的成绩表格（覆盖式） */
  static async saveScores(context: common.UIAbilityContext, rows: string[][]): Promise<void> {
    try {
      if (rows.length < 2) {
        return;
      }
      const headers: string[] = rows[0].slice();
      const data: string[][] = [];
      const limit: number = Math.min(rows.length - 1, AnalysisStore.MAX_ROWS);
      for (let i: number = 1; i <= limit; i++) {
        data.push(rows[i].slice());
      }
      const snap: ScoreSnapshot = {
        headers: headers,
        rows: data,
        time: AnalysisStore.formatNow()
      };
      const store = await AnalysisStore.store(context);
      await store.put(AnalysisStore.KEY_SCORES, JSON.stringify(snap));
      await store.flush();
    } catch (e) {
      // 存储失败不影响主流程
    }
  }

  /** 读取最近一次导入的成绩表格；无则返回 null */
  static async loadScores(context: common.UIAbilityContext): Promise<ScoreSnapshot | null> {
    try {
      const store = await AnalysisStore.store(context);
      const v = await store.get(AnalysisStore.KEY_SCORES, '');
      const s: string = v as string;
      if (s === '') {
        return null;
      }
      const snap = JSON.parse(s) as ScoreSnapshot;
      if (snap === null || snap.headers === undefined || snap.rows === undefined) {
        return null;
      }
      return snap;
    } catch (e) {
      return null;
    }
  }

  /** 保存本次分析结论，供下次对比使用 */
  static async saveReport(context: common.UIAbilityContext, content: string): Promise<void> {
    try {
      if (content.trim() === '') {
        return;
      }
      const rec: LastAnalysis = { content: content, time: AnalysisStore.formatNow() };
      const store = await AnalysisStore.store(context);
      await store.put(AnalysisStore.KEY_REPORT, JSON.stringify(rec));
      await store.flush();
    } catch (e) {
      // 忽略
    }
  }

  /** 读取上一次分析结论；无则返回 null */
  static async loadReport(context: common.UIAbilityContext): Promise<LastAnalysis | null> {
    try {
      const store = await AnalysisStore.store(context);
      const v = await store.get(AnalysisStore.KEY_REPORT, '');
      const s: string = v as string;
      if (s === '') {
        return null;
      }
      const rec = JSON.parse(s) as LastAnalysis;
      if (rec === null || rec.content === undefined || rec.content.trim() === '') {
        return null;
      }
      return rec;
    } catch (e) {
      return null;
    }
  }

  /** 清空（供设置页"清除本地数据"使用） */
  static async clear(context: common.UIAbilityContext): Promise<void> {
    try {
      const store = await AnalysisStore.store(context);
      await store.delete(AnalysisStore.KEY_SCORES);
      await store.delete(AnalysisStore.KEY_REPORT);
      await store.flush();
    } catch (e) {
      // 忽略
    }
  }

  /** 当前时间（yyyy-MM-dd HH:mm） */
  static formatNow(): string {
    const d = new Date();
    const p = (n: number): string => (n < 10 ? '0' + n : '' + n);
    return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate()) + ' ' +
      p(d.getHours()) + ':' + p(d.getMinutes());
  }
}
