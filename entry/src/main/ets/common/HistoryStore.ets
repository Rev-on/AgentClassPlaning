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

  /** 新增一条记录（超过 50 条自动裁掉最旧的）
   * 去重：与最新一条同标题同内容时不再重复入库（自动保存后手动再点保存不会产生重复）
   * @returns 是否真正写入（false=重复跳过）
   */
  static async addRecord(context: common.UIAbilityContext, record: HistoryRecord): Promise<boolean> {
    const records = await HistoryStore.getRecords(context);
    const latest: HistoryRecord | undefined = records.length > 0 ? records[0] : undefined;
    if (latest !== undefined && latest.title === record.title && latest.content === record.content) {
      return false;
    }
    records.unshift(record);
    if (records.length > HistoryStore.MAX) {
      records.splice(HistoryStore.MAX, records.length - HistoryStore.MAX);
    }
    const store = await preferences.getPreferences(context, HistoryStore.STORE_NAME);
    await store.put(HistoryStore.KEY, JSON.stringify(records));
    await store.flush();
    return true;
  }

  /** “自动保存到历史”开关是否开启（AppStorage 缓存，默认开） */
  static autoSaveEnabled(): boolean {
    const v: boolean = AppStorage.get<boolean>('autoSaveHist') as boolean;
    return v !== false;
  }

  /** 生成完成后自动保存（仅开关开启时生效；静默，无 toast；重复内容自动跳过） */
  static async autoAdd(context: common.UIAbilityContext, record: HistoryRecord): Promise<void> {
    if (!HistoryStore.autoSaveEnabled()) {
      return;
    }
    await HistoryStore.addRecord(context, record);
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
