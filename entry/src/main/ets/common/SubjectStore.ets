/**
 * 科目与满分配置存储。
 *
 * 用途：
 *   ① 首次启动的欢迎屏让老师勾选"需要分析哪几门科目"并填各自满分；
 *   ② 成绩热力图按**得分率**（得分 ÷ 该科满分）计算深浅，而非按列归一化；
 *   ③ 「我的」页提供入口随时修改。
 *
 * 为什么需要配置满分：
 *   不同科目满分不同（语文 120、物理 100、化学 80…）。若按"列内最大最小值"
 *   归一化，一个班物理普遍考 90+ 时，90 分会显示成"最低"；按得分率算才反映
 *   学生真实掌握程度，也更符合老师看成绩的直觉。
 *
 * 存储：Preferences（仅本机），AppStorage 缓存供 UI 同步读取。
 */
import preferences from '@ohos.data.preferences';
import common from '@ohos.app.ability.common';

/** 单个科目的配置 */
export interface SubjectConfig {
  /** 科目名（与 Excel 表头一致，用于匹配列） */
  name: string;
  /** 满分（>0） */
  full: number;
}

/** 默认科目（老用户与"恢复默认"用）：常见四科各 100 分 */
export const DEFAULT_SUBJECTS: SubjectConfig[] = [
  { name: '语文', full: 100 },
  { name: '数学', full: 100 },
  { name: '英语', full: 100 },
  { name: '物理', full: 100 }
];

/** 可勾选的候选科目（欢迎屏与设置页共用） */
export const CANDIDATE_SUBJECTS: string[] = [
  '语文', '数学', '英语', '物理', '化学', '政治', '历史',
  '生物', '地理', '科学', '道德与法治', '信息技术', '体育'
];

/** 各候选科目的默认满分（可被用户覆盖） */
const DEFAULT_FULL: Map<string, number> = new Map<string, number>([
  ['语文', 120], ['数学', 120], ['英语', 120], ['物理', 100],
  ['化学', 100], ['政治', 100], ['历史', 100], ['生物', 100],
  ['地理', 100], ['科学', 100], ['道德与法治', 100],
  ['信息技术', 100], ['体育', 100]
]);

export class SubjectStore {
  private static readonly STORE_NAME: string = 'subject_config';
  private static readonly KEY_SUBJECTS: string = 'subjects';
  private static readonly KEY_INITED: string = 'inited';
  /** AppStorage 键：UI 侧同步读取已配置科目 */
  static readonly AS_KEY: string = 'subjectConfig';

  /** 某科目的默认满分（无则 100） */
  static defaultFull(name: string): number {
    const v: number | undefined = DEFAULT_FULL.get(name);
    return v === undefined ? 100 : v;
  }

  /** 读取配置；未配置过返回 null（用于判断是否需要弹欢迎屏） */
  static async load(context: common.UIAbilityContext): Promise<SubjectConfig[] | null> {
    try {
      const store = await preferences.getPreferences(context, SubjectStore.STORE_NAME);
      const inited = await store.get(SubjectStore.KEY_INITED, false);
      if (inited !== true) {
        return null;
      }
      const raw = await store.get(SubjectStore.KEY_SUBJECTS, '[]');
      const arr = JSON.parse(raw as string) as SubjectConfig[];
      if (arr === null || arr.length === 0) {
        return [];
      }
      // 过滤非法项：满分必须为正数
      const out: SubjectConfig[] = [];
      for (let i: number = 0; i < arr.length; i++) {
        const s = arr[i];
        if (s !== null && s !== undefined && typeof s.name === 'string'
          && s.name !== '' && typeof s.full === 'number' && s.full > 0) {
          out.push({ name: s.name, full: s.full });
        }
      }
      return out;
    } catch (e) {
      return null;
    }
  }

  /** 是否已配置过（决定是否弹欢迎屏） */
  static async isInited(context: common.UIAbilityContext): Promise<boolean> {
    try {
      const store = await preferences.getPreferences(context, SubjectStore.STORE_NAME);
      const v = await store.get(SubjectStore.KEY_INITED, false);
      return v === true;
    } catch (e) {
      return false;
    }
  }

  /** 保存配置（并同步到 AppStorage 供 UI 使用） */
  static async save(context: common.UIAbilityContext, subjects: SubjectConfig[]): Promise<void> {
    try {
      const store = await preferences.getPreferences(context, SubjectStore.STORE_NAME);
      await store.put(SubjectStore.KEY_SUBJECTS, JSON.stringify(subjects));
      await store.put(SubjectStore.KEY_INITED, true);
      await store.flush();
    } catch (e) {
      // 写入失败仍同步内存，保证本次会话可用
    }
    AppStorage.setOrCreate(SubjectStore.AS_KEY, JSON.stringify(subjects));
  }

  /** 从 AppStorage 同步读取（UI 构建期用，避免异步） */
  static cached(): SubjectConfig[] {
    const s: string = AppStorage.get<string>(SubjectStore.AS_KEY) as string;
    if (s === undefined || s === null || s === '') {
      return [];
    }
    try {
      return JSON.parse(s) as SubjectConfig[];
    } catch (e) {
      return [];
    }
  }

  /**
   * 查某科目的满分；未配置返回 0（表示"该科目不参与热力图"）。
   * 名称匹配做**宽松处理**：去掉空格、统一大小写，并支持
   * "语文(120分)"这类带后缀的表头写法。
   */
  static fullOf(name: string): number {
    const list: SubjectConfig[] = SubjectStore.cached();
    const key: string = SubjectStore.normalize(name);
    if (key === '') {
      return 0;
    }
    for (let i: number = 0; i < list.length; i++) {
      if (SubjectStore.normalize(list[i].name) === key) {
        return list[i].full;
      }
    }
    // 再试"包含"匹配：表头常写成"语文成绩""语文(120分)"
    for (let i: number = 0; i < list.length; i++) {
      const n: string = SubjectStore.normalize(list[i].name);
      if (n !== '' && (key.indexOf(n) >= 0 || n.indexOf(key) >= 0)) {
        return list[i].full;
      }
    }
    return 0;
  }

  /** 规范化科目名：去空白、去括号内容、统一小写 */
  private static normalize(s: string): string {
    if (s === undefined || s === null) {
      return '';
    }
    let t: string = s.trim().toLowerCase();
    // 去掉括号及其中内容："语文(120分)" -> "语文"
    t = t.replace(/[（(][^）)]*[）)]/g, '');
    // 去掉常见后缀
    t = t.replace(/成绩|分数|得分/g, '');
    return t.trim();
  }

  /** 格式化得分率（0~1）为百分比文本 */
  static rateText(rate: number): string {
    if (rate < 0) {
      return '—';
    }
    return Math.round(rate * 100).toString() + '%';
  }
}
