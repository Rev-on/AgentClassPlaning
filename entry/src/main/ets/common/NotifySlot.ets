/**
 * 通知渠道（Notification Slot）注册 —— 让"生成完成"通知响铃并弹出横幅。
 *
 * 【为什么需要】
 *   华为推送报文里的 `notification.slotType` **只是声明"请按这个级别投递"**；
 *   真正决定"是否响铃、是否弹横幅"的是**客户端本地已注册的通知渠道**。
 *   若客户端从未调用 addSlot 注册渠道，系统会回退到默认渠道（级别低），
 *   表现为：**通知能收到（状态栏有图标），但不响铃、不弹横幅**。
 *
 * 【SDK 实际签名 —— 必须按此写，否则编译报 10505001】
 *   本机 DevEco SDK（.../sdk/default/openharmony/ets/api/@ohos.notificationManager.d.ts）
 *   中 addSlot 只有两个重载，**只接受 SlotType 枚举**：
 *       function addSlot(type: SlotType, callback: AsyncCallback<void>): void;
 *       function addSlot(type: SlotType): Promise<void>;
 *
 *   ⚠️ 常见的错误写法：传一个 NotificationSlot 对象进去
 *         await notificationManager.addSlot(slot)   // ✗ 编译失败
 *       ArkTS 会报：
 *         Argument of type 'NotificationSlot' is not assignable to
 *         parameter of type 'SlotType'.
 *      网上不少示例是"对象版"API（较新的 SDK 才有），本 SDK 不支持。
 *      **要改渠道级别/描述，本 SDK 无对应入参，只能依赖类型默认值。**
 *
 * 【为什么用 SOCIAL_COMMUNICATION 就够】
 *   SDK 头文件明确注明（@ohos.notificationManager.d.ts 第 852-860 行）：
 *       SOCIAL_COMMUNICATION = 1
 *       "This type corresponds to SlotLevel being **LEVEL_HIGH**."
 *   而 LEVEL_HIGH 的定义即"有横幅 + 有提示音"：
 *       LEVEL_DEFAULT = 3  有提示音，**无横幅**
 *       LEVEL_HIGH    = 4  有横幅 + 有提示音   ← 就是我们要的
 *   因此**只要注册 SOCIAL_COMMUNICATION，就自动是 LEVEL_HIGH**，
 *   无需（也无法）再手动指定 level。
 *
 * 与服务端的配合：
 *   服务端 push.js 的 `slotType` 默认 1，即 SOCIAL_COMMUNICATION，两边一致。
 *
 * 容错：任何失败只写日志，绝不抛出 —— 渠道是增强项，不能影响应用启动。
 */
import { notificationManager } from '@kit.NotificationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import common from '@ohos.app.ability.common';

const DOMAIN = 0x0000;
const TAG = 'NotifySlot';

/**
 * 本应用使用的渠道类型：社交通信。
 *
 * 选它的唯一理由：它是 SDK 中**默认级别为 LEVEL_HIGH（横幅 + 提示音）**的类型，
 * 见 @ohos.notificationManager.d.ts 中 SOCIAL_COMMUNICATION 的注释。
 * 对比：CONTENT_INFORMATION 默认 LEVEL_MIN（静默），
 *       UNKNOWN_TYPE 默认 LEVEL_MIN，均不会有横幅。
 *
 * 数值为 1，与服务端 push.js 的 `AGC_PUSH_SLOT_TYPE` 默认值一致。
 */
const SLOT_TYPE: notificationManager.SlotType = notificationManager.SlotType.SOCIAL_COMMUNICATION;

/** 是否已确认渠道注册成功（避免同一进程内重复调用 addSlot） */
let ensured: boolean = false;

export class NotifySlot {
  /**
   * 确保"生成完成"通知渠道已注册（响铃 + 横幅）。
   *
   * 幂等：已成功过则直接返回。
   * 非阻塞：失败静默（由 ensureRetryable 负责后续重试）。
   *
   * 调用时机很重要：必须在**通知权限就绪之后**。
   * 权限未开时 addSlot 会失败，导致渠道缺失；而渠道一旦缺失，
   * 即使后来用户手动开了通知，也仍然不会响铃、没有横幅。
   */
  static ensure(ctx: common.UIAbilityContext): void {
    if (ensured) {
      return;
    }
    NotifySlot.addSlot().then(() => {
      ensured = true;
      void ctx;
    }).catch((e: Error) => {
      hilog.warn(DOMAIN, TAG, 'ensure 异常（等待下次前台重试）: %{public}s', e.message);
    });
  }

  /**
   * 可重试版：失败时不置位，保证下次进入前台会再试。
   *
   * 场景：用户首次拒绝通知权限 → addSlot 失败 → 用户后来在系统设置里手动开启。
   * 此时必须允许重试，否则渠道永远建不上，通知就一直不响铃、无横幅。
   */
  static ensureRetryable(ctx: common.UIAbilityContext): void {
    if (ensured) {
      return;
    }
    NotifySlot.addSlot().then(() => {
      ensured = true;
      void ctx;
    }).catch((e: Error) => {
      // 不置位 ensured，下次 onForeground 会重新尝试
      hilog.warn(DOMAIN, TAG, 'ensureRetryable 失败，下次进入前台将重试: %{public}s', e.message);
    });
  }

  /**
   * 注册通知渠道。
   *
   * 按本 SDK 的签名，**只能传 SlotType 枚举**，级别由类型默认值决定
   * （SOCIAL_COMMUNICATION → LEVEL_HIGH → 横幅 + 提示音）。
   *
   * 说明：渠道按类型唯一 —— 同类型再次 addSlot 即"确保存在"，
   * 不会重复创建，因此重复调用是安全的。
   */
  private static async addSlot(): Promise<void> {
    try {
      await notificationManager.addSlot(SLOT_TYPE);
      hilog.info(DOMAIN, TAG,
        '通知渠道已注册 type=SOCIAL_COMMUNICATION(1) → 默认 LEVEL_HIGH，具备横幅+提示音');
    } catch (e) {
      const err = e as BusinessError;
      // 常见失败：
      //   1600004 通知总开关未开（等权限就绪后重试）
      //   401     参数校验失败
      hilog.warn(DOMAIN, TAG, 'addSlot 失败 code=%{public}d %{public}s',
        err.code === undefined ? -1 : err.code,
        err.message === undefined ? String(e) : err.message);
      throw e instanceof Error ? e : new Error('addSlot failed');
    }
  }
}
