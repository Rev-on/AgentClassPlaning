/**
 * 2in1 形态检测（HarmonyOS 真实现）
 *  - supported(): 仅华为 2in1（可拆磁吸键盘的大屏设备）启用上下分屏
 *  - keyboardDocked(): 磁吸/外接字母键盘是否处于连接（docked=键盘模式，使用平板界面；否则=全屏模式）
 *  - hasLowerHalf(): 折叠电脑半折叠双屏形态下，物理下半屏（displayId=999）是否存在
 *    （键盘吸回或展开成单屏时下半屏消失 → 无需跨轴铺窗；键盘拆下进入双屏形态 → 需把结果铺到下半屏）
 *  - attach()/detach(): 监听输入设备热插拔（键盘吸附/拆下即时重判布局）
 */
import deviceInfo from '@ohos.deviceInfo';
import inputDevice from '@ohos.multimodalInput.inputDevice';
import display from '@ohos.display';

export class DuoDetect {
  private static cb: (() => void) | null = null;

  /** 折叠电脑半折叠双屏形态下的物理下半屏 displayId（官方约定值） */
  private static readonly LOWER_DISPLAY_ID: number = 999;

  /** 支持上下分屏的设备类型（华为 2in1 / 折叠 PC 等） */
  static supported(): boolean {
    try {
      const t: string = deviceInfo.deviceType;
      return t === '2in1' || t === 'pc';
    } catch (e) {
      return false;
    }
  }

  /** 物理下半屏（displayId=999）当前是否存在：存在即处于半折叠双屏形态（磁吸键盘已拆下） */
  static hasLowerHalf(): boolean {
    if (!DuoDetect.supported()) {
      return false;
    }
    try {
      const d: display.Display = display.getDisplayByIdSync(DuoDetect.LOWER_DISPLAY_ID);
      return d !== undefined && d.id === DuoDetect.LOWER_DISPLAY_ID;
    } catch (e) {
      // displayId 不存在（单屏形态）或查询失败按无下半屏处理
      return false;
    }
  }

  /** 设置页手动强开"下半屏结果"：鸿蒙允许（wideLayout 已限制为平板级横屏尺寸，手机不会误开） */
  static manualAllowed(): boolean {
    return true;
  }

  /** 是否存在字母全键盘（KeyboardType.ALPHABETIC_KEYBOARD == 2） */
  static async keyboardDocked(): Promise<boolean> {
    try {
      const ids: number[] = await inputDevice.getDeviceList();
      for (let i = 0; i < ids.length; i++) {
        try {
          if (inputDevice.getKeyboardTypeSync(ids[i]) === 2) {
            return true;
          }
        } catch (e) {
          // 单个设备查询失败跳过
        }
      }
    } catch (e) {
      // 无权限等场景按无键盘处理
    }
    return false;
  }

  /** 键盘接入/移除回调（每次 change 都回调，由调用方自行刷新形态） */
  static attach(cb: () => void): void {
    DuoDetect.detach();
    DuoDetect.cb = cb;
    try {
      inputDevice.on('change', () => {
        if (DuoDetect.cb !== null) {
          DuoDetect.cb();
        }
      });
    } catch (e) {
      // 注册失败时静默（窗口尺寸变化仍可触发重判）
    }
  }

  /** 移除键盘事件监听 */
  static detach(): void {
    if (DuoDetect.cb === null) {
      return;
    }
    DuoDetect.cb = null;
    try {
      inputDevice.off('change');
    } catch (e) {
      // ignore
    }
  }
}
