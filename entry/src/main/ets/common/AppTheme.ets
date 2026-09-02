/**
 * 全局主题管理
 * 主题选择存于 AppStorage('appTheme')：'light' | 'dark' | 'system'
 * 实际生效主题存于 AppStorage('appResolvedTheme')：'light' | 'dark'（由 EntryAbility 维护）
 * 页面用法：
 *   @StorageProp('appResolvedTheme') resolvedTheme: string = 'light';
 *   private col(key: string): string { void this.resolvedTheme; return AppTheme.color(key, this.resolvedTheme); }
 */
export class AppTheme {
  static readonly THEME_KEY: string = 'appTheme';
  static readonly RESOLVED_KEY: string = 'appResolvedTheme';

  /** 获取某 token 当前主题色值（token 集合见下方 switch） */
  static color(token: string, resolved: string): string {
    const dark: boolean = resolved === 'dark';
    switch (token) {
      case 'bg':
        return dark ? '#11151C' : '#F5F7FB';
      case 'card':
        return dark ? '#1C222C' : '#FFFFFF';
      case 'title':
        return dark ? '#E7EAF0' : '#1F2937';
      case 'text':
        return dark ? '#C9D1DC' : '#333333';
      case 'sub':
        return dark ? '#8B95A5' : '#6B7280';
      case 'hint':
        return dark ? '#6B7686' : '#9CA3AF';
      case 'faint':
        return dark ? '#5A6575' : '#B0B7C3';
      case 'inputBg':
        return dark ? '#242B37' : '#FFFFFF';
      case 'barBg':
        return dark ? '#1C222C' : '#FFFFFF';
      case 'codeBg':
        return dark ? '#0B0E13' : '#1F2937';
      case 'codeText':
        return dark ? '#AAB4C2' : '#D1D5DB';
      case 'line':
        return dark ? '#333C4A' : '#E5E7EB';
      case 'headBg':
        return dark ? '#2A3342' : '#EDF2F9';
      default:
        return '#000000';
    }
  }
}
