/**
 * 通知自检 —— 把"能不能收到通知"的关键状态读到应用界面上。
 *
 * 【为什么需要】
 *   排查"通知收不到 / 不弹横幅"时，信息都只在 hilog 里，真机上不方便看，
 *   只能靠猜。本模块把系统侧的真实状态读出来直接显示在设置页，
 *   避免反复"改代码 → 重装 → 猜结果"。
 *
 * 【读什么】
 *   1. 通知总开关        isNotificationEnabled()
 *   2. 通知提醒方式      getNotificationSetting()（API 20+）
 *      —— 含 soundEnabled / vibrationEnabled，
 *         以及 bannerEnabled / lockScreenEnabled（**API 26.0.0+ 才有，可选字段**）
 *         ⚠️ bannerEnabled 是"是否弹横幅"的权威答案；
 *            系统**默认不开横幅**，需用户手动开启或应用通过评审。
 *   3. 已注册的通知渠道  getSlots()
 *      —— 确认 SOCIAL_COMMUNICATION 渠道是否存在、level 是否为 4(LEVEL_HIGH)。
 *
 * 【ArkTS 约束】不能用 ESObject 动态访问命名空间成员
 *   （会报 10605008 arkts-no-any-unknown / 10605114 arkts-no-no-ns-as-obj）。
 *   本 SDK 的 d.ts 里 getNotificationSetting 与 NotificationSetting 都已声明，
 *   因此直接静态调用即可，无需动态访问。
 *   但 bannerEnabled / lockScreenEnabled 标注 `since 26.0.0` 且为**可选**字段，
 *   在老设备上会是 undefined —— 需按其可能缺失来处理。
 *
 * 【容错】每项独立 try/catch，单项失败不影响其它项，整体永不抛异常。
 */
import { notificationManager } from '@kit.NotificationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0000;
const TAG = 'NotifyDiag';

/** 自检结果（全部为可直接展示的字符串） */
export interface NotifyDiagResult {
  /** 通知总开关：'已开启' / '未开启' / '读取失败(code)' */
  enabled: string;
  /** 响铃 */
  sound: string;
  /** 振动 */
  vibration: string;
  /** 横幅 —— 决定是否弹窗提示 */
  banner: string;
  /** 锁屏通知 */
  lockScreen: string;
  /** 渠道清单 */
  slots: string;
  /** 汇总建议（可直接展示给用户看） */
  advice: string;
}

export class NotifyDiag {
  /** 执行完整自检（永不抛异常） */
  static async run(): Promise<NotifyDiagResult> {
    const r: NotifyDiagResult = {
      enabled: '读取失败',
      sound: '—',
      vibration: '—',
      banner: '—',
      lockScreen: '—',
      slots: '—',
      advice: ''
    };

    // ---- 1. 通知总开关 ----
    let enabled = false;
    try {
      enabled = await notificationManager.isNotificationEnabled();
      r.enabled = enabled ? '已开启' : '未开启';
    } catch (e) {
      r.enabled = '读取失败(' + NotifyDiag.code(e) + ')';
      hilog.warn(DOMAIN, TAG, 'isNotificationEnabled 失败 code=%{public}d', NotifyDiag.code(e));
    }

    // ---- 2. 通知提醒方式 ----
    try {
      const st: notificationManager.NotificationSetting = await notificationManager.getNotificationSetting();
      r.sound = st.soundEnabled ? '开' : '关';
      r.vibration = st.vibrationEnabled ? '开' : '关';
      // bannerEnabled / lockScreenEnabled 为 API 26.0.0+ 的可选字段：
      // 老设备上为 undefined，此时如实显示"系统未提供"，不要谎报为开/关。
      r.banner = NotifyDiag.opt(st.bannerEnabled);
      r.lockScreen = NotifyDiag.opt(st.lockScreenEnabled);
    } catch (e) {
      const msg = '读取失败(' + NotifyDiag.code(e) + ')';
      r.sound = msg;
      r.vibration = msg;
      r.banner = msg;
      r.lockScreen = msg;
      hilog.warn(DOMAIN, TAG, 'getNotificationSetting 失败 code=%{public}d', NotifyDiag.code(e));
    }

    // ---- 3. 已注册渠道 ----
    try {
      const slots: Array<notificationManager.NotificationSlot> = await notificationManager.getSlots();
      if (slots.length === 0) {
        r.slots = '无任何渠道（未注册）';
      } else {
        const parts: string[] = [];
        for (let i = 0; i < slots.length; i++) {
          const s = slots[i];
          // 注意：notificationType/notificationLevel 是 API 11/20 起的**新字段**，
          // 老设备可能不填充这两个字段，只填旧的 type/level。
          // 若只读新字段会得到 undefined，误判为"渠道级别丢失"。
          // 因此两个字段都读，取有值的那个。
          const t: number | undefined = NotifyDiag.firstOf(s.notificationType, s.type);
          const lv: number | undefined = NotifyDiag.firstOf(s.notificationLevel, s.level);
          parts.push('type=' + NotifyDiag.show(t)
            + ' level=' + NotifyDiag.show(lv)
            + NotifyDiag.levelName(lv)
            + ' enabled=' + NotifyDiag.show(s.enabled));
        }
        r.slots = parts.join(' | ');
      }
    } catch (e) {
      r.slots = '读取失败(' + NotifyDiag.code(e) + ')';
      hilog.warn(DOMAIN, TAG, 'getSlots 失败 code=%{public}d', NotifyDiag.code(e));
    }

    // ---- 4. 汇总建议 ----
    r.advice = NotifyDiag.buildAdvice(r, enabled);
    hilog.info(DOMAIN, TAG, '自检完成 enabled=%{public}s banner=%{public}s slots=%{public}s',
      r.enabled, r.banner, r.slots);
    return r;
  }

  /** 依据自检结果给出下一步动作 */
  private static buildAdvice(r: NotifyDiagResult, enabled: boolean): string {
    if (!enabled) {
      return '通知总开关未开 → 所有通知都会被系统丢弃。'
        + '请到 系统设置 → 通知 → 备课助手 打开总开关。';
    }
    if (r.banner === '关') {
      return '横幅通知是关闭的。系统**默认不开横幅**，即使渠道级别够高也不会弹窗。'
        + '请到 系统设置 → 通知 → 备课助手 打开「横幅通知」。';
    }
    if (r.banner === '系统未提供') {
      return '本机系统未提供横幅开关状态（需 HarmonyOS 26+）。'
        + '请手动到 系统设置 → 通知 → 备课助手 确认「横幅」已打开。';
    }
    if (r.slots.indexOf('无任何渠道') >= 0) {
      return '尚未注册通知渠道 → 通知会落到默认低级别渠道。请重启 App 让其注册渠道。';
    }
    if (r.slots.indexOf('LEVEL_DEFAULT') >= 0) {
      return '渠道级别是 LEVEL_DEFAULT(3) → **有提示音但无横幅**。'
        + '说明系统把 SOCIAL_COMMUNICATION 的默认级别降到了 3。'
        + '请到 系统设置 → 通知 → 备课助手 手动打开「横幅通知」。';
    }
    if (r.slots.indexOf('LEVEL_LOW') >= 0 || r.slots.indexOf('LEVEL_MIN') >= 0
      || r.slots.indexOf('LEVEL_NONE') >= 0) {
      return '渠道级别过低（无横幅无提示音）。请重启 App 重新注册渠道；'
        + '若仍如此，请到 系统设置 → 通知 → 备课助手 手动调整提醒方式。';
    }
    if (r.slots.indexOf('level=undefined') >= 0) {
      return '渠道已注册但读不到级别（新老字段都为空）。这属系统未返回该字段，'
        + '不代表渠道有问题。请以「横幅」那一行的状态为准。';
    }
    if (r.banner === '系统未提供') {
      return '本机系统未提供横幅开关状态（需 HarmonyOS 26+）。'
        + '请手动到 系统设置 → 通知 → 备课助手 确认「横幅」已打开。';
    }
    return '各项状态正常。若仍收不到，请确认：'
      + '① App 在**前台**时系统不弹推送（属设计行为），测试需在生成中退到桌面或杀掉进程；'
      + '② 系统勿扰模式是否开启；③ 是否在"更多通知"折叠区里。';
  }

  /** 可选 boolean 字段 → 展示字符串（undefined 表示系统未提供该字段） */
  private static opt(v: boolean | undefined): string {
    if (v === true) {
      return '开';
    }
    if (v === false) {
      return '关';
    }
    return '系统未提供';
  }

  /** 取第一个有值的（兼容新老字段名） */
  private static firstOf(a: number | undefined, b: number | undefined): number | undefined {
    if (a !== undefined) {
      return a;
    }
    return b;
  }

  /** 数值/布尔 → 展示字符串 */
  private static show(v: number | boolean | undefined): string {
    if (v === undefined) {
      return 'undefined';
    }
    return String(v);
  }

  /** 级别数值 → 名称（便于一眼判断有没有横幅） */
  private static levelName(lv: number | undefined): string {
    if (lv === 4) {
      return '(LEVEL_HIGH:有横幅)';
    }
    if (lv === 3) {
      return '(LEVEL_DEFAULT:无横幅)';
    }
    if (lv === 2) {
      return '(LEVEL_LOW:无横幅)';
    }
    if (lv === 1) {
      return '(LEVEL_MIN:静默)';
    }
    if (lv === 0) {
      return '(LEVEL_NONE:关闭)';
    }
    return '';
  }

  private static code(e: Object): number {
    const err = e as BusinessError;
    return err.code === undefined ? -1 : err.code;
  }
}
