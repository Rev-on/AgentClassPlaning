import { AbilityConstant, Configuration, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { KeyboardAvoidMode, window } from '@kit.ArkUI';
import deviceInfo from '@ohos.deviceInfo';
import { AppSettings } from '../common/AppSettings';
import { AppTheme } from '../common/AppTheme';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
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

  onForeground(): void {
    // Ability has brought to foreground
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }
}
