/**
 * 应用自定义字体管理
 *  - 藏文：fonts/ctrc-uchen.ttf（注册名 TibetanUchen）
 *  - 维吾尔文：fonts/UKIJMejT.ttf（注册名 UyghurMejT）
 *  - 蒙古文：fonts/c8abb3845e34a252fcf04f0cd4e74a00.ttf（注册名 MongolianFont）
 * 页面在关键文本上统一调用 AppFonts.family()，按界面语言返回对应字体。
 */
export class AppFonts {
  /** 藏文乌金体（已在 Splash 注册） */
  static readonly TIBETAN: string = 'TibetanUchen';
  /** 维吾尔文（已在 Splash 注册） */
  static readonly UYGHUR: string = 'UyghurMejT';
  /** 蒙古文 Noto Sans Mongolian（已在 Splash 注册） */
  static readonly MONGOLIAN: string = 'MongolianFont';
  /** 其余语言使用系统默认字体 */
  static readonly DEFAULT: string = 'HarmonyOS Sans';

  /** 按指定语言返回字体族（用于语言选择框这类多语言混排场景，逐项取各自字体） */
  static forLang(lang: string): string {
    if (lang === 'bo') {
      return AppFonts.TIBETAN;
    }
    if (lang === 'ug') {
      return AppFonts.UYGHUR;
    }
    if (lang === 'mn') {
      return AppFonts.MONGOLIAN;
    }
    return AppFonts.DEFAULT;
  }

  /** 按当前界面语言返回应使用的字体族 */
  static family(): string {
    const lang: string | undefined = AppStorage.get<string>('appLang');
    return AppFonts.forLang(lang === undefined ? 'zh' : lang);
  }

  /** 是否处于少数民族语言界面（需要内置字体） */
  static isMinority(): boolean {
    const lang: string | undefined = AppStorage.get<string>('appLang');
    return lang === 'bo' || lang === 'ug' || lang === 'mn';
  }
}
