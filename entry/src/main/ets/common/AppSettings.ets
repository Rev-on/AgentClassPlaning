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
  /** 应用内字号倍率（作用于全部 fp 文字；默认 1.0=标准） */
  private static readonly KEY_FONT_SCALE: string = 'fontScale';
  /** 深度思考开关（启用后生成走思考模式，思考过程实时展示；默认关闭＝快速模式） */
  static readonly KEY_THINK: string = 'deepThink';
  /** 任教科目（如 物理）/UserSubject */
  static readonly KEY_TEACH_SUBJECT: string = 'teachSubject';
  /** 任教年级（1-9；九年一贯，小学 1-6、初中 7-9） */
  static readonly KEY_TEACH_GRADE: string = 'teachGrade';
  /** 起始册次基准：用户设定的"某年级某学期"作为推算起点，格式 YYYY-MM（学年起始月） */
  static readonly KEY_TEACH_ANCHOR: string = 'teachAnchor';
  /** 学生基础水平：strong=基础强 / normal=均衡 / weak=基础弱 */
  static readonly KEY_TEACH_LEVEL: string = 'teachLevel';
  /** Agent 记录的上次已生成课题（用于目录自动推进下一课） */
  static readonly KEY_TEACH_LAST_TOPIC: string = 'teachLastTopic';

  /** 字号档位倍率（对应设置页：小 / 标准 / 大 / 特大） */
  static readonly FONT_PRESETS: number[] = [0.9, 1.0, 1.15, 1.3];
  /** 字号倍率允许范围 */
  static readonly FONT_MIN: number = 0.85;
  static readonly FONT_MAX: number = 1.3;

  /** 启动时加载持久化设置并应用（默认：主题跟随系统、语言跟随系统语言） */
  static async load(context: common.UIAbilityContext): Promise<void> {
    let lang: string = 'zh';
    let theme: string = 'system';
    let autoSave: boolean = true;
    let manual: boolean = false;
    let duo: string = 'auto';
    let fontScale: number = 1.0;
    let think: boolean = false;
    try {
      const store = await preferences.getPreferences(context, AppSettings.STORE);
      const hasLang: boolean = await store.has(AppSettings.KEY_LANG);
      const lv = await store.get(AppSettings.KEY_LANG, 'zh');
      const tv = await store.get(AppSettings.KEY_THEME, 'system');
      const av = await store.get(AppSettings.KEY_AUTOSAVE, true);
      const fv = await store.get(AppSettings.KEY_FONT_SCALE, 1.0);
      const thv = await store.get(AppSettings.KEY_THINK, false);
      // 语言：用户手动选过（存在保存值）用保存值；否则跟随系统语言
      manual = hasLang;
      lang = manual ? AppSettings.normalizeLang(lv as string) : AppSettings.systemLang();
      theme = AppSettings.normalizeTheme(tv as string);
      autoSave = (av as boolean) !== false;
      // 结果屏布局已改为全自动：不再读取历史保存的覆盖值，避免旧值（强开/关闭）遗留后无法修改
      duo = 'auto';
      fontScale = AppSettings.normalizeFontScale(fv as number);
      think = (thv as boolean) === true;
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
    AppStorage.setOrCreate(AppSettings.KEY_FONT_SCALE, fontScale);
    AppStorage.setOrCreate(AppSettings.KEY_THINK, think);
    AppSettings.applyColorMode(context, theme);
    AppSettings.applyFontScale(context, fontScale);
    await AppSettings.loadTeach(context);
  }

  /** 任教信息存取：默认物理/八年级/基础均衡；anchor 为空时按"当前学年学期"推算册次 */
  private static async loadTeach(context: common.UIAbilityContext): Promise<void> {
    let subject: string = '物理';
    let grade: number = 8;
    let level: string = 'normal';
    let anchor: string = '';
    let lastTopic: string = '';
    try {
      const store = await preferences.getPreferences(context, AppSettings.STORE);
      const sv = await store.get(AppSettings.KEY_TEACH_SUBJECT, '物理');
      const gv = await store.get(AppSettings.KEY_TEACH_GRADE, 8);
      const lv = await store.get(AppSettings.KEY_TEACH_LEVEL, 'normal');
      const av = await store.get(AppSettings.KEY_TEACH_ANCHOR, '');
      const tv = await store.get(AppSettings.KEY_TEACH_LAST_TOPIC, '');
      if (sv !== null && String(sv) !== '') {
        subject = String(sv);
      }
      const gNum: number = Number(gv);
      if (gNum >= 1 && gNum <= 9) {
        grade = gNum;
      }
      if (String(lv) === 'strong' || String(lv) === 'normal' || String(lv) === 'weak') {
        level = String(lv);
      }
      if (av !== null) {
        anchor = String(av);
      }
      if (tv !== null) {
        lastTopic = String(tv);
      }
    } catch (e) {
      // 使用默认值
    }
    AppStorage.setOrCreate(AppSettings.KEY_TEACH_SUBJECT, subject);
    AppStorage.setOrCreate(AppSettings.KEY_TEACH_GRADE, grade);
    AppStorage.setOrCreate(AppSettings.KEY_TEACH_LEVEL, level);
    AppStorage.setOrCreate(AppSettings.KEY_TEACH_ANCHOR, anchor);
    AppStorage.setOrCreate(AppSettings.KEY_TEACH_LAST_TOPIC, lastTopic);
  }

  /** 保存任教科目并立即生效 */
  static async saveTeachSubject(context: common.UIAbilityContext, subject: string): Promise<void> {
    const store = await preferences.getPreferences(context, AppSettings.STORE);
    await store.put(AppSettings.KEY_TEACH_SUBJECT, subject);
    await store.flush();
    AppStorage.setOrCreate(AppSettings.KEY_TEACH_SUBJECT, subject);
  }

  /** 保存任教年级（1-9）并立即生效；同时把当前册次重置为新年级上册 */
  static async saveTeachGrade(context: common.UIAbilityContext, grade: number): Promise<void> {
    const store = await preferences.getPreferences(context, AppSettings.STORE);
    await store.put(AppSettings.KEY_TEACH_GRADE, grade);
    await store.put(AppSettings.KEY_TEACH_ANCHOR, '');
    await store.flush();
    AppStorage.setOrCreate(AppSettings.KEY_TEACH_GRADE, grade);
    AppStorage.setOrCreate(AppSettings.KEY_TEACH_ANCHOR, '');
  }

  /** 保存学生基础水平（strong/normal/weak）并立即生效 */
  static async saveTeachLevel(context: common.UIAbilityContext, level: string): Promise<void> {
    const store = await preferences.getPreferences(context, AppSettings.STORE);
    await store.put(AppSettings.KEY_TEACH_LEVEL, level);
    await store.flush();
    AppStorage.setOrCreate(AppSettings.KEY_TEACH_LEVEL, level);
  }

  /**
   * 保存"起始基准"并立即生效：以打印"起始学年·起始年级"为推算起点，
   * 后续年级/册次由 TeachingProfile 随学季自动推进。格式 YYYY-GRADE（如 2026-7）。
   */
  static async saveTeachAnchor(context: common.UIAbilityContext, year: number, grade: number): Promise<void> {
    const anchor: string = year + '-' + grade;
    const store = await preferences.getPreferences(context, AppSettings.STORE);
    await store.put(AppSettings.KEY_TEACH_ANCHOR, anchor);
    await store.put(AppSettings.KEY_TEACH_GRADE, grade);
    await store.flush();
    AppStorage.setOrCreate(AppSettings.KEY_TEACH_ANCHOR, anchor);
    AppStorage.setOrCreate(AppSettings.KEY_TEACH_GRADE, grade);
  }

  /** 保存 Agent 上次生成的课题（目录自动推进下一课用） */
  static async saveTeachLastTopic(context: common.UIAbilityContext, topic: string): Promise<void> {
    try {
      const store = await preferences.getPreferences(context, AppSettings.STORE);
      await store.put(AppSettings.KEY_TEACH_LAST_TOPIC, topic);
      await store.flush();
    } catch (e) {
      // 非关键
    }
    AppStorage.setOrCreate(AppSettings.KEY_TEACH_LAST_TOPIC, topic);
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

  /** 保存"深度思考"开关并立即生效（下次进入保持） */
  static async saveThink(context: common.UIAbilityContext, on: boolean): Promise<void> {
    AppStorage.setOrCreate(AppSettings.KEY_THINK, on);
    try {
      const store = await preferences.getPreferences(context, AppSettings.STORE);
      await store.put(AppSettings.KEY_THINK, on);
      await store.flush();
    } catch (e) {
      // 持久化失败不阻塞应用（本次会话内仍生效）
    }
  }

  /** 字号倍率白名单校验（非法值/越界值收敛到允许范围） */
  private static normalizeFontScale(scale: number): number {
    if (!(scale > 0) || Number.isNaN(scale)) {
      return 1.0;
    }
    const v: number = Math.min(AppSettings.FONT_MAX, Math.max(AppSettings.FONT_MIN, scale));
    return Math.round(v * 100) / 100;
  }

  /**
   * 应用应用内字号倍率（作用于全部 fp 文字，全局即时生效）。
   * @returns true=设置成功；false=当前系统/设备不支持（如系统版本低于 API 21）
   */
  static applyFontScale(context: common.UIAbilityContext, scale: number): boolean {
    try {
      const s: number = AppSettings.normalizeFontScale(scale);
      context.getApplicationContext().setFontSizeScale(s);
      return true;
    } catch (e) {
      return false;
    }
  }

  /** 保存字号倍率并立即应用；返回是否应用成功（设备不支持时持久化值仍保留，重启后可再试） */
  static async saveFontScale(context: common.UIAbilityContext, scale: number): Promise<boolean> {
    const s: number = AppSettings.normalizeFontScale(scale);
    try {
      const store = await preferences.getPreferences(context, AppSettings.STORE);
      await store.put(AppSettings.KEY_FONT_SCALE, s);
      await store.flush();
    } catch (e) {
      // 持久化失败不阻塞应用
    }
    AppStorage.setOrCreate(AppSettings.KEY_FONT_SCALE, s);
    return AppSettings.applyFontScale(context, s);
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
