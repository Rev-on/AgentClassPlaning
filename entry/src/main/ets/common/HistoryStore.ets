/**
 * 历史记录存储：基于 Preferences 本地持久化
 * 保存各功能生成的结果，供"我的报告"页回看
 */
import preferences from '@ohos.data.preferences';
import common from '@ohos.app.ability.common';

export interface HistoryRecord {
  /** 功能类型（如：教案、课件大纲、分层练习...） */
  type: string;
  /** 标题（如：教案-光的反射） */
  title: string;
  /** 生成内容 */
  content: string;
  /** 生成时间（yyyy-MM-dd HH:mm） */
  time: string;
}

export class HistoryStore {
  private static readonly STORE_NAME: string = 'ai_lesson_store';
  private static readonly KEY: string = 'ai_lesson_records';
  private static readonly MAX: number = 50;

  /** 读取全部历史记录（新记录在前） */
  static async getRecords(context: common.UIAbilityContext): Promise<HistoryRecord[]> {
    try {
      const store = await preferences.getPreferences(context, HistoryStore.STORE_NAME);
      const value = await store.get(HistoryStore.KEY, '[]');
      const records = JSON.parse(value as string) as HistoryRecord[];
      return records;
    } catch (e) {
      return [];
    }
  }

  /** 新增一条记录（超过 50 条自动裁掉最旧的） */
  static async addRecord(context: common.UIAbilityContext, record: HistoryRecord): Promise<void> {
    const records = await HistoryStore.getRecords(context);
    records.unshift(record);
    if (records.length > HistoryStore.MAX) {
      records.splice(HistoryStore.MAX, records.length - HistoryStore.MAX);
    }
    const store = await preferences.getPreferences(context, HistoryStore.STORE_NAME);
    await store.put(HistoryStore.KEY, JSON.stringify(records));
    await store.flush();
  }

  /** 清空全部历史记录 */
  static async clearRecords(context: common.UIAbilityContext): Promise<void> {
    const store = await preferences.getPreferences(context, HistoryStore.STORE_NAME);
    await store.put(HistoryStore.KEY, '[]');
    await store.flush();
  }

  /** 当前时间字符串（yyyy-MM-dd HH:mm） */
  static formatNow(): string {
    const d = new Date();
    const p = (n: number): string => (n < 10 ? '0' + n : '' + n);
    return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate()) + ' ' +
      p(d.getHours()) + ':' + p(d.getMinutes());
  }
}
