/**
 * 2in1 / 折叠电脑双屏窗口平台接缝（HarmonyOS 真实现）
 *
 * 设计说明：
 *  - 上下分屏涉及的 display/window 跨轴 API（getDisplayByIdSync / getCurrentFoldCreaseRegion /
 *    maximize(ENTER_IMMERSIVE) / restore 等）在 ArkUI-X(Android) 跨端编译时被静态拦截（11706007），
 *    因此把全部平台专属调用收敛到本文件；共享页面（Index / IndexWideDuo）只调用本类的静态方法。
 *  - Android 侧使用同名文件 Duo2in1.ets 的空实现（所有调用返回安全默认值），
 *    由 DuoDetect(Android 桩) 保证这些方法在 Android 运行时永远不可达，体验与鸿蒙手机端一致。
 */
import display from '@ohos.display';
import { window } from '@kit.ArkUI';

export class Duo2in1 {
  /** 上半屏（displayId=0）高度（vp）；双屏形态下工具区精确占满上屏 */
  static topHeightVp(): number {
    try {
      const up = display.getDisplayByIdSync(0);
      if (up === undefined) {
        return 0;
      }
      return px2vp(up.height);
    } catch (e) {
      return 0;
    }
  }

  /** 折痕区高度（vp）：上下屏之间的物理缝隙，内容需要避让 */
  static creaseVp(): number {
    try {
      const r = display.getCurrentFoldCreaseRegion();
      if (r !== undefined && r.creaseRects !== undefined && r.creaseRects.length > 0) {
        const h: number = r.creaseRects[0].height;
        if (h > 0) {
          return px2vp(h);
        }
      }
    } catch (e) {
      // ignore
    }
    return 0;
  }

  /** 主窗口是否已真正跨轴铺满上下两屏（窗口矩形高度远超单上屏即视为铺满） */
  static isAcrossSpan(mw: window.Window): boolean {
    try {
      const up = display.getDisplayByIdSync(0);
      if (up === undefined) {
        return false;
      }
      const rect = mw.getWindowProperties().windowRect;
      return rect.height > up.height + 100;
    } catch (e) {
      return false;
    }
  }

  /** 触发一次跨轴瀑布铺窗（成功返回 true，失败返回 false 由调用方按需重试） */
  static async enterFold(mw: window.Window): Promise<boolean> {
    try {
      await mw.maximize(window.MaximizePresentation.ENTER_IMMERSIVE, true);
      return true;
    } catch (e) {
      return false;
    }
  }

  /** 收回跨轴窗口（回到常规窗口状态） */
  static async collapseFold(mw: window.Window): Promise<void> {
    try {
      await mw.restore();
    } catch (e) {
      // 恢复失败时保持现状
    }
  }
}
