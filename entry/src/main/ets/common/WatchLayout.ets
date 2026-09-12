/**
 * 手表端布局工具：判断当前是否运行在手表设备上，并区分圆屏/方屏做内容避让。
 * - 方屏：内容按屏幕矩形铺开，仅避开系统状态栏/胶囊。
 * - 圆屏：内容建议落在"内切正方形"内（四角裁圆），用 TYPE_CUTOUT 的裁剪避让区估算内切边距。
 * 跨平台：非鸿蒙平台统一回退为方屏布局（isRound=false），保证编译与运行安全。
 */
import common from '@ohos.app.ability.common';
import { deviceInfo } from '@kit.BasicServicesKit';
import window from '@ohos.window';

/** 避让读数（px）：圆屏内切边距近似值 + 四边安全区 */
export interface WatchAvoid {
  /** 是否为圆屏 */
  round: boolean;
  /** 内容统一内缩边距（px），方屏为 0，圆屏为内切正方形二分之一余量 */
  inset: number;
  top: number;
  bottom: number;
  left: number;
  right: number;
}

export class WatchLayout {
  /** 当前是否运行在手表/可穿戴设备上 */
  static isWatch(): boolean {
    let t: string = '';
    try {
      t = deviceInfo.deviceType;
    } catch (e) {
      t = '';
    }
    return t === 'watch' || t === 'wearable';
  }

  /** 圆屏判定：窗口裁剪避让区四角对称且明显（内切正方形的弓形余量） */
  static async isRound(ctx: common.UIAbilityContext): Promise<boolean> {
    try {
      const w = await window.getLastWindow(ctx);
      const props = w.getWindowProperties();
      const rect = props.windowRect;
      const area = w.getWindowAvoidArea(window.AvoidAreaType.TYPE_CUTOUT);
      const left: number = area.leftRect.width;
      const right: number = area.rightRect.width;
      const top: number = area.topRect.height;
      const bottom: number = area.bottomRect.height;
      const insets: number[] = [left, right, top, bottom].sort((a: number, b: number): number => a - b);
      const minInset: number = insets[0];
      const short: number = Math.min(rect.width, rect.height);
      // 圆屏弓形余量约占短边 8% 以上；方屏四角避让几乎为 0
      return minInset > 2 && minInset * 10 > short;
    } catch (e) {
      return false;
    }
  }

  /** 读取避让读数：统一提供安全区 + 圆屏内切边距 */
  static async avoid(ctx: common.UIAbilityContext): Promise<WatchAvoid> {
    const round: boolean = await WatchLayout.isRound(ctx);
    try {
      const w = await window.getLastWindow(ctx);
      const area = w.getWindowAvoidArea(window.AvoidAreaType.TYPE_CUTOUT);
      const props = w.getWindowProperties();
      const rect = props.windowRect;
      const left: number = area.leftRect.width;
      const right: number = area.rightRect.width;
      const top: number = area.topRect.height;
      const bottom: number = area.bottomRect.height;
      let inset: number = 0;
      if (round) {
        // 内切正方形：四边避让 + 弓形余量，取统一内缩
        const cs: number = Math.max(left, right, top, bottom);
        inset = cs > 0 ? cs : Math.round(Math.min(rect.width, rect.height) * 0.05);
      }
      return { round: round, inset: inset, top: top, bottom: bottom, left: left, right: right };
    } catch (e) {
      return { round: round, inset: round ? 16 : 0, top: 0, bottom: 0, left: 0, right: 0 };
    }
  }
}