/**
 * 自适应布局策略：把「设备形态 + 窗口尺寸 + 输入设备」折算为唯一布局决策。
 *
 * 布局档位（LayoutMode）：
 *   PHONE  单栏（手机、折叠屏合起用外屏、手表以外的小窗）
 *   WIDE   左右双栏（平板横屏、折叠屏展开后的大屏、三折叠展开）
 *   DUO    上下分屏（半折叠悬停、2in1 拆下磁吸键盘的上下双屏）
 *
 * 设计要点：
 *  - **展开态折叠屏即使尺寸未达平板阈值，也应按大屏布局**：折叠屏展开瞬间窗口尺寸
 *    会先经历一个中间值，若只按尺寸判定会短暂闪回单栏；这里用 FoldDetect 的形态信息
 *    作为优先依据，尺寸仅作兜底。
 *  - **三折叠展开后非常宽**，双栏能容纳更宽的侧栏，故侧栏宽度单独放大。
 *  - **半折叠（悬停）**优先上下分屏：与 2in1 双屏共用 DUO 档位，避免两套并行逻辑。
 *  - 所有阈值集中在此文件，便于按真机实测调整。
 */
import { FoldDetect, FoldForm, FoldPose } from './FoldDetect';
import { DuoDetect } from './DuoDetect';

/** 布局档位 */
export enum LayoutMode {
  PHONE = 0,
  WIDE = 1,
  DUO = 2
}

/** 布局决策结果（供 Index / 子页面消费） */
export interface LayoutDecision {
  mode: LayoutMode;
  /** 是否启用左右双栏（对应 AppStorage 'appWideLayout'） */
  wide: boolean;
  /** 是否启用上下分屏（对应 AppStorage 'appDuo'） */
  duo: boolean;
  /** 是否跨轴双屏（对应 AppStorage 'appTwoScreen'，决定手工分区还是 FoldSplitContainer） */
  twoScreen: boolean;
  form: FoldForm;
  pose: FoldPose;
  /** 折痕总高度（vp），DUO 下用于上下区间隔避免内容压在折痕上 */
  creaseVp: number;
  /** 左侧栏/工具区宽度（vp），随形态放大 */
  sidebarVp: number;
}

/** —— 阈值（集中管理，便于真机调参）—— */
/** 通用宽屏门槛：宽 > 高且宽度达到该值 */
const WIDE_MIN_W: number = 900;
/** 通用宽屏门槛：高度需达到该值（避免横屏矮窗误判） */
const WIDE_MIN_H: number = 520;
/** DUO（2in1 键盘模式）额外门槛：需更大尺寸才值得上下分屏 */
const DUO_MIN_W: number = 1000;
const DUO_MIN_H: number = 760;
/** 折叠屏展开态：宽度达到该值即按大屏处理（低于平板阈值也生效） */
const FOLD_EXPAND_W: number = 600;
/** 侧栏（工具栏）宽度：基础值，以及折叠展开态下的收窄值 */
const SIDEBAR_BASE: number = 400;
/** 三折叠：全展开时空间充裕，用偏宽值 */
const SIDEBAR_TRIPLE: number = 470;
/** 三折叠「单轴展开」中间态：此时横向内容区需要更多空间，工具栏明显收窄 */
const SIDEBAR_TRIPLE_HALF_OPEN: number = 340;
/** 单折轴折叠屏（双折叠/阔折叠）展开：明显收窄，把宽度让给内容区 */
const SIDEBAR_DUAL_EXPANDED: number = 300;

export class LayoutPolicy {

  /**
   * 侧栏宽度（仅"展开态"按形态调整，合起/半折沿用 400）：
   *  - 三折叠全展开（两折轴都开）→ 470
   *  - 三折叠单轴展开（中间态）→ 340（明显收窄）
   *  - 单折轴折叠屏展开（双折叠/阔折叠）→ 300（明显收窄）
   *  - 其余（手机/平板/2in1/合起/半折）→ 400
   */
  private static sidebar(form: FoldForm, pose: FoldPose, expanded: boolean): number {
    // 仅"展开态"才按形态调整宽度；合起（用外屏）/半折悬停沿用基础宽度，
    // 避免收窄规则外溢到小窗形态导致工具栏过窄。
    if (pose !== FoldPose.EXPANDED) {
      return SIDEBAR_BASE;
    }
    if (form === FoldForm.TRIPLE) {
      // 双折轴设备：仅"两个折轴都展开"才算全展开，否则为单轴展开中间态
      return expanded ? SIDEBAR_TRIPLE : SIDEBAR_TRIPLE_HALF_OPEN;
    }
    if (form === FoldForm.DUAL) {
      return SIDEBAR_DUAL_EXPANDED;
    }
    return SIDEBAR_BASE;
  }

  /**
   * 计算布局决策。
   * @param vw 窗口宽（vp）
   * @param vh 窗口高（vp）
   * @param keyboardDocked 2in1 磁吸键盘是否接入（接入=平板布局，不上下分屏）
   * @param hasLowerHalf 2in1 物理下半屏是否存在（存在=上下双屏形态）
   */
  static decide(vw: number, vh: number, keyboardDocked: boolean, hasLowerHalf: boolean): LayoutDecision {
    const fi = FoldDetect.info(vw, vh);
    const form: FoldForm = fi.form;
    const pose: FoldPose = fi.pose;

    // 几何宽屏（手机/平板/2in1 通用兜底）
    const geometryWide: boolean = vw > vh && vw >= WIDE_MIN_W && vh >= WIDE_MIN_H;

    // 折叠屏展开态：展开后即为大屏，走双栏。
    // 注意不能用 vw > vh 限制 —— 部分折叠屏展开后接近方形甚至略高（如 760x820），
    // 若要求横屏会误判为单栏。改以"宽度达阈值 + 不是合起态"为准。
    //
    // 说明：双折叠与阔折叠在系统层面无法区分（折痕同为 1 条、getFoldStatus 返回值相同，
    // 且展开宽高比区间重叠不可靠），故统一按双栏处理，不做"阔折叠走单屏"的特殊分支。
    const foldExpanded: boolean = fi.foldable
      && pose !== FoldPose.FOLDED
      && vw >= FOLD_EXPAND_W;

    // 折叠屏半折（悬停）：上下分区呈现
    const foldHalf: boolean = fi.foldable && pose === FoldPose.HALF;

    // 2in1：物理下半屏存在（拆下磁吸键盘）或大横屏且未接键盘时上下分屏。
    // 必须限定为 2in1 设备，否则平板横屏会被误判成上下分屏。
    const duo2in1: boolean = DuoDetect.supported()
      && (hasLowerHalf || (geometryWide && vw >= DUO_MIN_W && vh >= DUO_MIN_H && !keyboardDocked));

    // 三折叠全展开：横向空间充裕，用双栏比上下分区更合适
    const wideFoldExpanded: boolean = fi.foldable
      && pose === FoldPose.EXPANDED
      && vw >= WIDE_MIN_W && vw > vh;

    // DUO 优先于 WIDE：半折与双屏形态都希望上下分区呈现；
    // 但"展开且很宽"的折叠屏（三折叠全展开）例外，交给双栏。
    const duo: boolean = !wideFoldExpanded && (foldHalf || duo2in1);
    const wide: boolean = !duo && (geometryWide || foldExpanded);

    let mode: LayoutMode = LayoutMode.PHONE;
    if (duo) {
      mode = LayoutMode.DUO;
    } else if (wide) {
      mode = LayoutMode.WIDE;
    }

    const d: LayoutDecision = {
      mode: mode,
      wide: wide,
      duo: duo,
      // 跨轴双屏：2in1 拆键盘出现物理下半屏时才是"真双屏"，折叠屏半折由系统分区
      twoScreen: duo && hasLowerHalf,
      form: form,
      pose: pose,
      creaseVp: fi.creaseVp,
      sidebarVp: LayoutPolicy.sidebar(form, pose, fi.fullyExpanded)
    };
    return d;
  }

  /** 档位名（日志用） */
  static modeName(m: LayoutMode): string {
    if (m === LayoutMode.WIDE) {
      return 'wide';
    }
    if (m === LayoutMode.DUO) {
      return 'duo';
    }
    return 'phone';
  }
}
