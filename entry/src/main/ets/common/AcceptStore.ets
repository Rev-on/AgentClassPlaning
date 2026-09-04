/**
 * 免责声明同意状态存储：基于 Preferences 本地持久化
 *  - 首次启动显示免责弹窗，点击"同意"后写入标记，此后不再弹出
 *  - 点击"不同意"退出应用且不写入标记，下次启动仍会显示
 */
import preferences from '@ohos.data.preferences';
import common from '@ohos.app.ability.common';

export class AcceptStore {
  private static readonly STORE_NAME: string = 'app_accept';
  private static readonly KEY_ACCEPTED: string = 'disclaimer_accepted';

  /** 是否已同意免责声明 */
  static async getAccepted(context: common.UIAbilityContext): Promise<boolean> {
    try {
      const store = await preferences.getPreferences(context, AcceptStore.STORE_NAME);
      const v = await store.get(AcceptStore.KEY_ACCEPTED, false);
      return v === true;
    } catch (e) {
      return false;
    }
  }

  /** 记录已同意 */
  static async setAccepted(context: common.UIAbilityContext): Promise<void> {
    try {
      const store = await preferences.getPreferences(context, AcceptStore.STORE_NAME);
      await store.put(AcceptStore.KEY_ACCEPTED, true);
      await store.flush();
    } catch (e) {
      // 忽略写入失败
    }
  }
}
