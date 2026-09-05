/**
 * 应用设置：语言与主题的读取、持久化与应用
 *  - appLang:  'zh' | 'en' | 'ug' | 'bo' | 'mn'   （AppStorage）
 *  - appTheme: 'light' | 'dark' | 'system'       （AppStorage）
 *  - appResolvedTheme: 'light' | 'dark'          （AppStorage，实际生效）
 */
import preferences from '@ohos.data.preferences';
import common from '@ohos.app.ability.common';
import { ConfigurationConstant } from '@kit.AbilityKit';
import { I18n } from './I18n';
import { AppTheme } from './AppTheme';

export class AppSettings {
  private static readonly STORE: string = 'app_settings';
  private static readonly KEY_LANG: string = 'appLang';
  private static readonly KEY_THEME: string = 'appTheme';
  private static readonly KEY_AGREED: string = 'disclaimerAgreed';
  private static readonly KEY_AUTOSAVE: string = 'autoSaveHist';

  /** 启动时加载持久化设置并应用（含 colorMode） */
  static async load(context: common.UIAbilityContext): Promise<void> {
    let lang: string = 'zh';
    let theme: string = 'light';
    let autoSave: boolean = true;
    try {
      const store = await preferences.getPreferences(context, AppSettings.STORE);
      const lv = await store.get(AppSettings.KEY_LANG, 'zh');
      const tv = await store.get(AppSettings.KEY_THEME, 'light');
      const av = await store.get(AppSettings.KEY_AUTOSAVE, true);
      lang = AppSettings.normalizeLang(lv as string);
      const t = tv as string;
      theme = (t === 'dark' || t === 'system') ? t : 'light';
      autoSave = (av as boolean) !== false;
    } catch (e) {
      // 默认值
    }
    AppStorage.setOrCreate(I18n.LANG_KEY, lang);
    AppStorage.setOrCreate(AppTheme.THEME_KEY, theme);
    AppStorage.setOrCreate(AppSettings.KEY_AUTOSAVE, autoSave);
    AppSettings.applyColorMode(context, theme);
  }

  /** 读取"已同意免责声明"标记（默认 false） */
  static async loadAgreed(context: common.UIAbilityContext): Promise<boolean> {
    try {
      const store = await preferences.getPreferences(context, AppSettings.STORE);
      const v = await store.get(AppSettings.KEY_AGREED, false);
      return (v as boolean) === true;
    } catch (e) {
      return false;
    }
  }

  /** 保存"已同意免责声明"（同意后永久不再提示） */
  static async saveAgreed(context: common.UIAbilityContext): Promise<void> {
    const store = await preferences.getPreferences(context, AppSettings.STORE);
    await store.put(AppSettings.KEY_AGREED, true);
    await store.flush();
  }

  /** 语言代码白名单校验（非法值回退中文） */
  private static normalizeLang(lang: string): string {
    if (lang === 'zh' || lang === 'en' || lang === 'ug' || lang === 'bo' || lang === 'mn') {
      return lang;
    }
    return 'zh';
  }

  /** 保存语言并立即生效 */
  static async saveLang(context: common.UIAbilityContext, lang: string): Promise<void> {
    const store = await preferences.getPreferences(context, AppSettings.STORE);
    await store.put(AppSettings.KEY_LANG, lang);
    await store.flush();
    AppStorage.setOrCreate(I18n.LANG_KEY, lang);
  }

  /** 保存主题并立即生效 */
  static async saveTheme(context: common.UIAbilityContext, theme: string): Promise<void> {
    const store = await preferences.getPreferences(context, AppSettings.STORE);
    await store.put(AppSettings.KEY_THEME, theme);
    await store.flush();
    AppStorage.setOrCreate(AppTheme.THEME_KEY, theme);
    AppSettings.applyColorMode(context, theme);
  }

  /** 保存“自动保存到历史”开关并立即生效 */
  static async saveAutoSave(context: common.UIAbilityContext, on: boolean): Promise<void> {
    const store = await preferences.getPreferences(context, AppSettings.STORE);
    await store.put(AppSettings.KEY_AUTOSAVE, on);
    await store.flush();
    AppStorage.setOrCreate(AppSettings.KEY_AUTOSAVE, on);
  }

  /** 应用系统颜色模式并计算实际生效主题 */
  static applyColorMode(context: common.UIAbilityContext, theme: string): void {
    const appCtx = context.getApplicationContext();
    let mode: ConfigurationConstant.ColorMode = ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
    if (theme === 'dark') {
      mode = ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    } else if (theme === 'system') {
      mode = ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
    }
    try {
      appCtx.setColorMode(mode);
    } catch (e) {
      // 忽略
    }
    const resolved: string = AppSettings.resolveTheme(context, theme);
    AppStorage.setOrCreate(AppTheme.RESOLVED_KEY, resolved);
  }

  /** 计算实际生效主题（system 模式依据系统 colorMode） */
  static resolveTheme(context: common.UIAbilityContext, theme: string): string {
    if (theme === 'dark') {
      return 'dark';
    }
    if (theme === 'light') {
      return 'light';
    }
    // 跟随系统
    try {
      const cfg = context.config;
      if (cfg !== undefined && cfg.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK) {
        return 'dark';
      }
    } catch (e) {
      // 兜底
    }
    return 'light';
  }
}
