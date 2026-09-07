/**
 * 首页问候语服务
 *
 * 进入首页时按「系统时间 + 是否工作日/休息日」返回问候语文案 key：
 *  - 时段划分：3-6 夜猫 / 6-11 早 / 11-13 午 / 13-17 下午 / 17-22 晚 / 22-3 深夜
 *  - 大字（早上好/中午好…）在工作日与休息日一致；小字俏皮话按日型区分
 *  - 休息日判定：周末 + 当年法定节假日（含调休补班安排）；
 *    节假日表内置自国务院办公厅当年《部分节假日安排通知》
 *    （2026 年：国办发明电〔2025〕7 号），超出内置年份时按“周末休息、平日上班”兜底。
 */
export interface GreetingText {
  bigKey: string;
  smallKey: string;
}

export class Greeting {
  /** 法定放假日期（休息日），格式 YYYY-MM-DD */
  private static readonly OFF_DATES: string[] = [
    // 2026 元旦：1月1日-3日
    '2026-01-01', '2026-01-02', '2026-01-03',
    // 2026 春节：2月15日-23日
    '2026-02-15', '2026-02-16', '2026-02-17', '2026-02-18', '2026-02-19',
    '2026-02-20', '2026-02-21', '2026-02-22', '2026-02-23',
    // 2026 清明：4月4日-6日
    '2026-04-04', '2026-04-05', '2026-04-06',
    // 2026 劳动节：5月1日-5日
    '2026-05-01', '2026-05-02', '2026-05-03', '2026-05-04', '2026-05-05',
    // 2026 端午：6月19日-21日
    '2026-06-19', '2026-06-20', '2026-06-21',
    // 2026 中秋：9月25日-27日
    '2026-09-25', '2026-09-26', '2026-09-27',
    // 2026 国庆：10月1日-7日
    '2026-10-01', '2026-10-02', '2026-10-03', '2026-10-04', '2026-10-05',
    '2026-10-06', '2026-10-07'
  ];

  /** 周末调休上班日期（工作日），格式 YYYY-MM-DD */
  private static readonly WORK_DATES: string[] = [
    // 2026 元旦调休：1月4日（周日）
    '2026-01-04',
    // 2026 春节调休：2月14日（周六）、2月28日（周六）
    '2026-02-14', '2026-02-28',
    // 2026 劳动节调休：5月9日（周六）
    '2026-05-09',
    // 2026 国庆调休：9月20日（周日）、10月10日（周六）
    '2026-09-20', '2026-10-10'
  ];

  /** 所在时段：owl=3-6 夜猫 / morning / noon / afternoon / evening / late=22-3 深夜 */
  private static slotOf(hour: number): string {
    if (hour >= 3 && hour < 6) {
      return 'owl';
    }
    if (hour >= 6 && hour < 11) {
      return 'morning';
    }
    if (hour >= 11 && hour < 13) {
      return 'noon';
    }
    if (hour >= 13 && hour < 17) {
      return 'afternoon';
    }
    if (hour >= 17 && hour < 22) {
      return 'evening';
    }
    return 'late';
  }

  private static pad(n: number): string {
    return n < 10 ? '0' + n.toString() : n.toString();
  }

  /** 当天是否为休息日（周末 + 法定节假日，扣除调休上班日） */
  static isRestDay(now: Date): boolean {
    const key: string = Greeting.pad(now.getFullYear()) + '-' + Greeting.pad(now.getMonth() + 1) + '-' +
      Greeting.pad(now.getDate());
    if (Greeting.WORK_DATES.includes(key)) {
      return false;
    }
    if (Greeting.OFF_DATES.includes(key)) {
      return true;
    }
    const week: number = now.getDay(); // 0=周日
    return week === 0 || week === 6;
  }

  /** 按当前系统时间返回问候语文案 key（i18n 词典渲染） */
  static forNow(): GreetingText {
    const now: Date = new Date();
    const slot: string = Greeting.slotOf(now.getHours());
    const rest: boolean = Greeting.isRestDay(now);
    return {
      bigKey: 'greet.big.' + slot,
      smallKey: (rest ? 'greet.rest.' : 'greet.work.') + slot
    };
  }
}
