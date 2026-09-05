import { AbilityConstant, Configuration, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { AppSettings } from '../common/AppSettings';
import { AppTheme } from '../common/AppTheme';
import { AccountStore } from '../common/AccountStore';

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
    });

    // 并行加载持久化的语言与主题；完成后通过 AppStorage 自动刷新 Splash/Index（不阻塞首屏）
    AppSettings.load(this.context).catch((err: Error) => {
      hilog.error(DOMAIN, 'testTag', 'Failed to load settings. Cause: %{public}s', err.message);
    });

    // 并行加载账号会话（启动页据此决定进入登录页还是主界面）
    AccountStore.load(this.context).catch((err: Error) => {
      hilog.error(DOMAIN, 'testTag', 'Failed to load account. Cause: %{public}s', err.message);
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
