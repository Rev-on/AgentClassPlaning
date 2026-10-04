import { AbilityConstant, Configuration, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import common from '@ohos.app.ability.common';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { KeyboardAvoidMode, window } from '@kit.ArkUI';
import { notificationManager } from '@kit.NotificationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import deviceInfo from '@ohos.deviceInfo';
import { AppSettings } from '../common/AppSettings';
import { AppTheme } from '../common/AppTheme';
import { ContinuationService } from '../common/ContinuationService';
import { PushToken } from '../common/PushToken';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
    // 分布式软总线流转接收：目标设备冷启动时从 Want 提取流转来的生成结果并写入收件箱
    ContinuationService.inboxFromWant(want);
    // 申请 Push Token 并上报服务端（失败静默，不影响启动）
    PushToken.ensure().catch((e: Error) => {
      hilog.warn(DOMAIN, 'testTag', 'PushToken.ensure 异常: %{public}s', e.message);
    });
  }

  /** 源端：用户选定目标设备后，框架回调这里把当前生成结果写入 Want 完成流转 */
  onContinue(wantParam: Record<string, Object>): AbilityConstant.OnContinueResult {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onContinue');
    return ContinuationService.buildWant(wantParam);
  }

  /** 分布式软总线流转接收：目标设备已运行（热启动）时也能接收 flow 过来的结果 */
  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onNewWant');
    ContinuationService.inboxFromWant(want);
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    // 跟随系统模式下，系统深浅色变化时刷新实际主题
    const theme: string | undefined = AppStorage.get<string>(AppTheme.THEME_KEY);
    if (theme === 'system') {
      const isDark: boolean = newConfig.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
      AppStorage.setOrCreate(AppTheme.RESOLVED_KEY, isDark ? 'dark' : 'light');
    }
    // 未手动选择语言时，系统语言变化自动跟随
    AppSettings.applySystemLangIfAuto();
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onConfigurationUpdate');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    // 立即加载启动页，不等待设置读取（避免设置加载异常导致首屏无法渲染）
    windowStage.loadContent('pages/Splash', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
      // 申请通知权限 —— Push Kit 官方要求：
      //   服务端推送返回 80000000 Success 但设备收不到通知，最常见原因就是
      //   应用从未申请通知权限，系统通知总开关对该应用为关闭，通知被静默丢弃。
      //   必须在 UI 就绪后调用，否则弹窗无处依附。
      this.requestNotifyPermission(this.context);
      // 软键盘避让设为“压缩模式”，避免键盘弹出时整页被整体上抬（默认 OFFSET 上抬模式）
      // 该模式下 Page 高度被压缩，输入框固定悬于键盘上方，聊天/表单体验更符合直觉
      try {
        windowStage.getMainWindowSync().getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
      } catch (e) {
        hilog.warn(DOMAIN, 'testTag', 'setKeyboardAvoidMode failed. Cause: %{public}s', JSON.stringify(e));
      }
      // 华为 2in1 / 折叠 PC（MateBook Fold 等）：应用启动后自动全屏（沉浸式铺满），保证下半屏结果大面板有足够高度
      try {
        const t: string = deviceInfo.deviceType;
        if (t === '2in1' || t === 'pc') {
          windowStage.getMainWindowSync().setWindowLayoutFullScreen(true).catch((e: Error) => {
            hilog.warn(DOMAIN, 'testTag', 'setWindowLayoutFullScreen failed. Cause: %{public}s', JSON.stringify(e));
          });
        }
      } catch (e) {
        hilog.warn(DOMAIN, 'testTag', 'fullscreen setup failed. Cause: %{public}s', JSON.stringify(e));
      }
    });

    // 并行加载持久化的语言与主题；完成后通过 AppStorage 自动刷新 Splash/Index（不阻塞首屏）
    AppSettings.load(this.context).catch((err: Error) => {
      hilog.error(DOMAIN, 'testTag', 'Failed to load settings. Cause: %{public}s', err.message);
    });
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  /**
   * 申请通知权限。
   *
   * 为什么必须做：
   *   Push Kit 通知消息要求应用先获得通知授权。若从未调用
   *   requestEnableNotification，系统的通知总开关对该应用保持关闭，
   *   此时**服务端推送仍返回 80000000 Success**，但通知会被系统静默丢弃，
   *   表现为"发送成功却收不到"。
   *
   * 实现要点：
   *   · 先 isNotificationEnabled 判断，已授权就不再弹窗打扰用户；
   *   · 未授权时 requestEnableNotification 拉起系统授权弹窗（只会弹一次，
   *     用户拒绝后系统不再重复弹，需引导去设置页手动开启）；
   *   · 全程失败静默，不影响应用启动。
   */
  private requestNotifyPermission(ctx: common.UIAbilityContext): void {
    notificationManager.isNotificationEnabled().then((enabled: boolean) => {
      hilog.info(DOMAIN, 'testTag', '通知权限当前状态: %{public}s', enabled ? '已开启' : '未开启');
      if (enabled) {
        return;
      }
      notificationManager.requestEnableNotification(ctx).then(() => {
        hilog.info(DOMAIN, 'testTag', '通知权限申请成功');
      }).catch((err: BusinessError) => {
        // 1600004 = 用户已拒绝过，系统不再弹窗；需引导用户到设置里手动开启
        hilog.warn(DOMAIN, 'testTag', '通知权限申请失败 code=%{public}d %{public}s',
          err.code, err.message);
      });
    }).catch((err: BusinessError) => {
      hilog.warn(DOMAIN, 'testTag', 'isNotificationEnabled 失败 code=%{public}d %{public}s',
        err.code, err.message);
    });
  }

  onForeground(): void {
    // Ability has brought to foreground
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }
}
