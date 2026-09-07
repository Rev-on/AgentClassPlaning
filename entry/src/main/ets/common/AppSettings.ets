/**
 * 应用设置：语言与主题的读取、持久化与应用
 *  - appLang:  'zh' | 'en' | 'ug' | 'bo' | 'mn'   （AppStorage）
 *  - appTheme: 'light' | 'dark' | 'system'       （AppStorage）
 *  - appResolvedTheme: 'light' | 'dark'          （AppStorage，实际生效）
 * 默认策略：主题跟随系统；语言跟随系统语言（用户手动选过语言后才固定使用所选语言）。
 */
import preferences from '@ohos.data.preferences';
import common from '@ohos.app.ability.common';
import { ConfigurationConstant } from '@kit.AbilityKit';
import { i18n } from '@kit.LocalizationKit';
import { I18n } from './I18n';
import { AppTheme } from './AppTheme';

export class AppSettings {
  private static readonly STORE: string = 'app_settings';
  private static readonly KEY_LANG: string = 'appLang';
  private static readonly KEY_THEME: string = 'appTheme';
  /** 是否用户手动指定过语言（false=跟随系统语言）；同时作为 AppStorage 键 */
  private static readonly KEY_LANG_MANUAL: string = 'appLangManual';
  private static readonly KEY_AGREED: string = 'disclaimerAgreed';
  private static readonly KEY_AUTOSAVE: string = 'autoSaveHist';
  /** 2in1 结果分屏布局：auto=自动检测 / on=手动强开 / off=关闭 */
  private static readonly KEY_DUO: string = 'duoLayout';

  /** 启动时加载持久化设置并应用（默认：主题跟随系统、语言跟随系统语言） */
  static async load(context: common.UIAbilityContext): Promise<void> {
    let lang: string = 'zh';
    let theme: string = 'system';
    let autoSave: boolean = true;
    let manual: boolean = false;
    let duo: string = 'auto';
    try {
      const store = await preferences.getPreferences(context, AppSettings.STORE);
      const hasLang: boolean = await store.has(AppSettings.KEY_LANG);
      const lv = await store.get(AppSettings.KEY_LANG, 'zh');
      const tv = await store.get(AppSettings.KEY_THEME, 'system');
      const av = await store.get(AppSettings.KEY_AUTOSAVE, true);
      const dv = await store.get(AppSettings.KEY_DUO, 'auto');
      // 语言：用户手动选过（存在保存值）用保存值；否则跟随系统语言
      manual = hasLang;
      lang = manual ? AppSettings.normalizeLang(lv as string) : AppSettings.systemLang();
      theme = AppSettings.normalizeTheme(tv as string);
      autoSave = (av as boolean) !== false;
      duo = AppSettings.normalizeDuo(dv as string);
    } catch (e) {
      // 默认值：主题跟随系统；语言跟随系统语言
      lang = AppSettings.systemLang();
      theme = 'system';
    }
    AppStorage.setOrCreate(I18n.LANG_KEY, lang);
    AppStorage.setOrCreate(AppTheme.THEME_KEY, theme);
    AppStorage.setOrCreate(AppSettings.KEY_LANG_MANUAL, manual);
    AppStorage.setOrCreate(AppSettings.KEY_AUTOSAVE, autoSave);
    AppStorage.setOrCreate(AppSettings.KEY_DUO, duo);
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

  /** 主题选择白名单校验（非法值默认跟随系统） */
  private static normalizeTheme(theme: string): string {
    if (theme === 'light' || theme === 'dark' || theme === 'system') {
      return theme;
    }
    return 'system';
  }

  /** 2in1 分屏布局选择白名单校验（非法值默认自动） */
  private static normalizeDuo(duo: string): string {
    if (duo === 'on' || duo === 'off' || duo === 'auto') {
      return duo;
    }
    return 'auto';
  }

  /** 保存“2in1 结果分屏布局”并立即生效（随后由 Index 重新判定布局） */
  static async saveDuoLayout(context: common.UIAbilityContext, duo: string): Promise<void> {
    const store = await preferences.getPreferences(context, AppSettings.STORE);
    await store.put(AppSettings.KEY_DUO, AppSettings.normalizeDuo(duo));
    await store.flush();
    AppStorage.setOrCreate(AppSettings.KEY_DUO, AppSettings.normalizeDuo(duo));
  }

  /** 系统语言 → 应用语言代码（支持 zh/en/ug/bo/mn；其余回退中文） */
  static systemLang(): string {
    try {
      const sys: string = i18n.System.getSystemLanguage();
      const base: string = sys.toLowerCase().split('-')[0];
      if (base === 'zh' || base === 'en' || base === 'ug' || base === 'bo' || base === 'mn') {
        return base;
      }
    } catch (e) {
      // ignore
    }
    return 'zh';
  }

  /** 未手动指定语言时，将当前语言刷新为系统语言（系统语言变化时调用） */
  static applySystemLangIfAuto(): void {
    if (AppStorage.get<boolean>(AppSettings.KEY_LANG_MANUAL) === true) {
      return;
    }
    AppStorage.setOrCreate(I18n.LANG_KEY, AppSettings.systemLang());
  }

  /** 保存语言并立即生效（保存后视为用户手动指定，不再跟随系统语言） */
  static async saveLang(context: common.UIAbilityContext, lang: string): Promise<void> {
    const store = await preferences.getPreferences(context, AppSettings.STORE);
    await store.put(AppSettings.KEY_LANG, lang);
    await store.put(AppSettings.KEY_LANG_MANUAL, true);
    await store.flush();
    AppStorage.setOrCreate(AppSettings.KEY_LANG_MANUAL, true);
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
