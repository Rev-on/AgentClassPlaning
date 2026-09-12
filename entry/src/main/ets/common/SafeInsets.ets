/**
 * 顶部安全区工具：读取系统状态栏/刘海避让高度，供"整页滚动"页面预留顶部安全区
 * （沉浸式/全屏形态下内容不再顶到状态栏）
 */
import common from '@ohos.app.ability.common';
import window from '@ohos.window';

export class SafeInsets {
  /**
   * 读取状态栏顶部避让高度（vp）。成功返回 >0 的避让高度；异常/未初始化返回 0。
   * 页面在 aboutToAppear 中调用并用结果填充 @State topInset。
   */
  static topInset(ctx: common.UIAbilityContext): Promise<number> {
    return new Promise<number>((resolve) => {
      try {
        window.getLastWindow(ctx).then((w: window.Window): void => {
          try {
            const area = w.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
            const px: number = area.topRect.height;
            resolve(px > 0 ? px2vp(px) : 0);
          } catch (e) {
            resolve(0);
          }
        }).catch(() => {
          resolve(0);
        });
      } catch (e) {
        resolve(0);
      }
    });
  }
}