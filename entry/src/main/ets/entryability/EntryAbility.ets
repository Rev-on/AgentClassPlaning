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
import { NotifySlot } from '../common/NotifySlot';
import { LiveView } from '../common/LiveView';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
    // 实况窗 / 后台短时任务需要 UIAbilityContext：
    //   liveViewManager 是系统代理，对调用方有 UIAbility 身份校验；
    //   requestSuspendDelay（短时任务）也要求传应用上下文。
    // 这里在**最早时机**注入，之后即使生成过程中页面销毁，
    // 后台看门狗仍持有有效 context（这是"退到后台仍能更新实况窗"的前提）。
    LiveView.attach(this.context);
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

  /**
   * 进程被系统终止。
   *
   * 实况窗本身由 SDK 的 lifeCycleMode=AUTO_STOP_WHEN_APP_TERMINATE 处理，
   * 这里只负责把客户端侧的定时器/后台任务释放掉，避免任何残留资源。
   * （框架不保证一定回调，LiveView.start 内部也会先收掉上一个未结束的实例。）
   */
  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
    LiveView.stop().catch((e: Error) => {
      hilog.warn(DOMAIN, 'testTag', 'LiveView.stop 异常: %{public}s', e.message);
    });
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
   *
   * 与通知渠道的关系（重要）：
   *   渠道（NotifySlot）必须在**权限就绪之后**创建。若在权限未开时调 addSlot，
   *   会失败并返回 1600004，导致渠道缺失 —— 即使后续用户手动开了通知，
   *   也会因为"没有高位渠道"而不响铃、无横幅。
   *   因此这里在授权的每个分支（已开启 / 刚授权成功）都补一次 ensure。
   */
  private requestNotifyPermission(ctx: common.UIAbilityContext): void {
    notificationManager.isNotificationEnabled().then((enabled: boolean) => {
      hilog.info(DOMAIN, 'testTag', '通知权限当前状态: %{public}s', enabled ? '已开启' : '未开启');
      if (enabled) {
        // 权限已就绪：可安全注册渠道
        NotifySlot.ensure(ctx);
        return;
      }
      notificationManager.requestEnableNotification(ctx).then(() => {
        hilog.info(DOMAIN, 'testTag', '通知权限申请成功');
        // 刚拿到授权：此刻注册渠道才会成功
        NotifySlot.ensure(ctx);
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
    // 补偿注册通知渠道：用户可能在系统设置里**后来才**打开通知总开关，
    // 此时启动期的注册已因 1600004 失败过；用 ensureRetryable 在此补上
    // （内部失败会复位标记，保证下次进入前台仍会重试）。
    NotifySlot.ensureRetryable(this.context);
    // 实况窗：回到前台 → 立刻按已流逝时间补齐进度（把后台挂起期间"欠"的百分比
    // 补上），并把控制权交回页面回调；同时释放后台短时任务额度。
    // 内部全程静默，失败绝不影响 UI。
    LiveView.onForeground();
  }

  /**
   * 应用退到后台。
   *
   * 【为什么这里是核心接缝】
   *   用户"把应用退出到后台"正是实况窗要发挥作用的场景。v1 在此处什么都没做：
   *   实况窗虽然不会被结束，但**也没有任何人继续驱动它** —— 页面回调随进程
   *   挂起而停止，进度于是永久冻结。本版通过 LiveView.onBackground()：
   *     · 把应用标记为后台态（进度模型切到"时间滑轨主导"）；
   *     · 确保与页面解耦的进度看门狗在运行；
   *     · 申请**短时任务** requestSuspendDelay（无需权限，见 LiveView.ets 顶部
   *       论证），争取后台运行窗口，让看门狗真的能把进度推出去。
   *   **绝不在这里结束实况窗** —— 退出后台不是"生成结束"。
   */
  onBackground(): void {
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
    LiveView.onBackground();
  }
}
