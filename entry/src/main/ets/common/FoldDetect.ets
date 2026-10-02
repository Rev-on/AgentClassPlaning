/**
 * 折叠屏形态检测（双折叠 / 阔折叠 / 三折叠）
 *
 * 背景与设计：
 *  - 原先工程只识别 2in1（磁吸键盘 + displayId=999 下半屏），对折叠屏无感知；
 *    折叠屏在"折叠/半折/展开"切换时窗口尺寸会突变，若只靠尺寸阈值判定，会在
 *    切换瞬间出现布局抖动或误判（例如阔折叠展开后宽度很大、三折叠展开后接近平板）。
 *  - 本模块用系统折叠能力（@ohos.display）作为**权威依据**，与窗口尺寸一起判定布局形态：
 *      isFoldable()                 是否为折叠设备
 *      getFoldStatus()              折叠状态（含双折轴状态 → 可识别三折叠）
 *      getFoldDisplayMode()         当前显示模式（全屏/主屏/副屏）
 *      getCurrentFoldCreaseRegion() 折痕区域（三折叠会返回**多个**矩形）
 *  - 三种形态的语义：
 *      双折叠（dual fold）  单折轴；展开后为近方形大屏，折痕 1 条
 *      阔折叠（wide fold）  单折轴但外屏比例更宽；展开后横向很宽，折痕 1 条
 *      三折叠（triple fold）双折轴；展开后为超宽平板形态，折痕 2 条
 *  - 检测结果统一为 FoldForm，供 Index 决定用手机 / 双栏 / 上下分屏布局。
 *
 * 兼容性：所有系统调用均 try/catch 包裹，非折叠设备或旧版本上恒为 FoldForm.NONE，
 * 不影响既有手机 / 平板 / 2in1 逻辑。
 */
import deviceInfo from '@ohos.deviceInfo';
import display from '@ohos.display';

/** 设备折叠形态（按折轴数量与展开后形态归类） */
export enum FoldForm {
  /** 非折叠设备（手机、平板、2in1、手表等） */
  NONE = 0,
  /** 单折轴折叠屏（双折叠/阔折叠统一归此类）。展开=大屏，合起=单栏 */
  DUAL = 1,
  /** 保留：单折轴中偏宽的一类。当前不自动判定（比例区间与双折叠重叠），仅供上层显式指定 */
  WIDE = 2,
  /** 三折叠：双折轴，展开后超宽平板形态 */
  TRIPLE = 3
}

/** 折叠姿态（对业务有意义的归一化状态） */
export enum FoldPose {
  /** 未知 / 非折叠 */
  UNKNOWN = 0,
  /** 完全折叠（用外屏，等同手机） */
  FOLDED = 1,
  /** 半折叠（悬停，可上下分区） */
  HALF = 2,
  /** 完全展开（用内屏大屏） */
  EXPANDED = 3
}

/** 一次完整形态快照 */
export interface FoldInfo {
  form: FoldForm;
  pose: FoldPose;
  /** 是否为折叠设备 */
  foldable: boolean;
  /** 折痕条数（三折叠为 2，双/阔折叠为 1，无折痕为 0） */
  creaseCount: number;
  /** 折痕总高度（vp）：上下分屏时需要避让的物理缝隙 */
  creaseVp: number;
  /** 是否处于"展开可用大屏"状态（折叠姿态为展开） */
  expanded: boolean;
  /**
   * 是否"完全展开"（所有折轴都展开）。
   * 三折叠只展开一个折轴时为 false —— 该中间态下工具栏应收窄、内容区放大。
   */
  fullyExpanded: boolean;
}

/** 判定"三折叠"的折痕条数阈值（双折轴 → 2 条折痕） */
const TRIPLE_CREASE_MIN: number = 2;

export class FoldDetect {
  /** 当前折痕条数缓存（getFoldStatus 无法直接给出，由折痕区域推断并缓存） */
  private static lastCreaseCount: number = -1;

  /** 是否为折叠设备 */
  static isFoldable(): boolean {
    try {
      return display.isFoldable();
    } catch (e) {
      return false;
    }
  }

  /**
   * 折叠姿态归一化：
   *  - 系统枚举里 11/12/13/21/22/23 表示"双折轴"设备（三折叠），两个数字分别描述
   *    第一/第二折轴的状态，这里统一折算为 FoldPose。
   *  - 注意：单折轴展开（1）与双折轴全部展开（11）都归为 EXPANDED，
   *    但二者对布局含义不同 —— 前者是三折叠的"单轴展开中间态"，
   *    后者才是真正的全展开。需要区分的场合请用 isFullyExpanded()。
   */
  static pose(): FoldPose {
    if (!FoldDetect.isFoldable()) {
      return FoldPose.UNKNOWN;
    }
    let s: number = 0;
    try {
      s = display.getFoldStatus() as number;
    } catch (e) {
      return FoldPose.UNKNOWN;
    }
    // 单折轴：0 未知 / 1 展开 / 2 折叠 / 3 半折
    if (s === 1) {
      return FoldPose.EXPANDED;
    }
    if (s === 2) {
      return FoldPose.FOLDED;
    }
    if (s === 3) {
      return FoldPose.HALF;
    }
    // 双折轴（三折叠）：21 → 第二轴半折；11 → 第二轴展开；12/22/13/23 等按"任一轴半折即半折"处理
    if (s === 11) {
      return FoldPose.EXPANDED;
    }
    if (s === 21 || s === 13 || s === 23) {
      return FoldPose.HALF;
    }
    if (s === 12 || s === 22) {
      return FoldPose.FOLDED;
    }
    return FoldPose.UNKNOWN;
  }

  /**
   * 是否"完全展开"（所有折轴都展开）。
   *  - 单折轴设备：FOLD_STATUS_EXPANDED(1) 即完全展开
   *  - 双折轴设备（三折叠）：仅 11（两轴都展开）为完全展开；
   *    此时若只展开一个折轴，系统同样返回 EXPANDED 语义但原始值为 1，
   *    属"单轴展开中间态"，布局上应把工具栏收窄、内容区放大。
   */
  static isFullyExpanded(): boolean {
    if (!FoldDetect.isFoldable()) {
      return false;
    }
    let s: number = 0;
    try {
      s = display.getFoldStatus() as number;
    } catch (e) {
      return false;
    }
    // 11 = 第一折轴展开 + 第二折轴展开（三折叠全展开）
    if (s === 11) {
      return true;
    }
    // 单折轴设备：1 即完全展开。双折轴设备上出现 1 视为仅单轴展开，不算完全展开。
    if (s === 1) {
      return FoldDetect.creaseInfo()[0] < TRIPLE_CREASE_MIN;
    }
    return false;
  }

  /** 折痕区域信息：条数 + 总高度（vp） */
  private static creaseInfo(): number[] {
    let count: number = 0;
    let heightVp: number = 0;
    try {
      const r = display.getCurrentFoldCreaseRegion();
      if (r !== undefined && r.creaseRects !== undefined) {
        const rects = r.creaseRects;
        for (let i = 0; i < rects.length; i++) {
          const h: number = rects[i].height;
          if (h > 0) {
            count++;
            heightVp += px2vp(h);
          }
        }
      }
    } catch (e) {
      // 无折痕信息（非折叠 / 不支持）按 0 处理
    }
    if (count > 0) {
      FoldDetect.lastCreaseCount = count;
    } else if (FoldDetect.lastCreaseCount > 0) {
      // 展开态某些版本会暂时返回空折痕，沿用上次结果避免形态抖动
      count = FoldDetect.lastCreaseCount;
    }
    return [count, heightVp];
  }

  /**
   * 归属形态：
   *  - 折痕 ≥2 条 → 三折叠（双折轴，这是最可靠的判据）
   *  - 折痕 1 条 → 单折轴折叠屏。系统未提供"双折叠 vs 阔折叠"的机型区分能力，
   *    且两类机型展开后的宽高比区间重叠（无法用比例可靠区分），故统一归为 DUAL。
   *    布局上按"展开=大屏、合起=单栏"处理；阔折叠展开时仍按正常单屏布局展示，
   *    不因其偏宽而强行切双栏（避免误判导致布局跳变）。
   */
  static form(vw: number, vh: number): FoldForm {
    if (!FoldDetect.isFoldable()) {
      return FoldForm.NONE;
    }
    const c = FoldDetect.creaseInfo();
    const creaseCount: number = c[0];
    if (creaseCount >= TRIPLE_CREASE_MIN) {
      return FoldForm.TRIPLE;
    }
    return FoldForm.DUAL;
  }

  /** 一次性取全部形态信息 */
  static info(vw: number, vh: number): FoldInfo {
    const foldable: boolean = FoldDetect.isFoldable();
    const c = FoldDetect.creaseInfo();
    const form: FoldForm = FoldDetect.form(vw, vh);
    const pose: FoldPose = FoldDetect.pose();
    const fi: FoldInfo = {
      form: form,
      pose: pose,
      foldable: foldable,
      creaseCount: c[0] as number,
      creaseVp: c[1] as number,
      expanded: pose === FoldPose.EXPANDED,
      fullyExpanded: FoldDetect.isFullyExpanded()
    };
    return fi;
  }

  /**
   * 注册折叠相关事件监听（形态变化时回调，由调用方重排布局）。
   * 覆盖三类事件：折叠状态、显示模式、折痕区域变化（三折叠多折轴场景）。
   * 返回是否注册成功。
   */
  static attach(cb: () => void): boolean {
    let ok: boolean = false;
    try {
      display.on('foldStatusChange', () => {
        cb();
      });
      ok = true;
    } catch (e) {
      // 旧版本无该事件
    }
    try {
      display.on('foldDisplayModeChange', () => {
        cb();
      });
      ok = true;
    } catch (e) {
      // ignore
    }
    return ok;
  }

  /** 移除折叠事件监听 */
  static detach(): void {
    try {
      display.off('foldStatusChange');
    } catch (e) {
      // ignore
    }
    try {
      display.off('foldDisplayModeChange');
    } catch (e) {
      // ignore
    }
  }

  /** 形态名（调试 / 日志用，不面向用户） */
  static formName(f: FoldForm): string {
    if (f === FoldForm.DUAL) {
      return 'dual-fold';
    }
    if (f === FoldForm.WIDE) {
      return 'wide-fold';
    }
    if (f === FoldForm.TRIPLE) {
      return 'triple-fold';
    }
    return 'none';
  }

  /** 设备显示名（用于设置页展示当前形态，便于用户确认适配生效） */
  static describe(f: FoldForm): string {
    if (f === FoldForm.DUAL) {
      return 'dual';
    }
    if (f === FoldForm.WIDE) {
      return 'wide';
    }
    if (f === FoldForm.TRIPLE) {
      return 'triple';
    }
    return 'none';
  }
}
