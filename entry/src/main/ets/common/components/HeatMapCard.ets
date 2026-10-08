/**
 * 成绩热力图卡片。
 *
 * 横轴 = 科目，纵轴 = 学生，单元格深浅 = 该生该科成绩在本科目内的相对位置。
 * 数据来自**最近一次导入的学情分析 Excel**（AnalysisStore 持久化）。
 *
 * 本组件为「我的」页的**缩略卡片**：学生/科目较多时只显示前若干行若干列，
 * 点击整卡进入全屏详情页看完整矩阵。
 *
 * 无数据时显示引导文案（不渲染空白卡片，避免用户误以为功能损坏）。
 */
import { I18n } from '../I18n';
import { AppTheme } from '../AppTheme';
import { AppFonts } from '../AppFonts';
import { HeatMap, HeatMapData, HeatRow, HeatSubject } from '../HeatMap';

/** 缩略卡片最多显示的行/列数：超出部分用"还有 N 名/科"提示 */
const THUMB_ROWS: number = 6;
const THUMB_COLS: number = 4;

@Component
export struct HeatMapCard {
  /**
   * 热力图数据。用 @Prop 会在每次父组件重建时深拷贝整个矩阵，
   * 学生多时开销明显，故用普通成员（父组件用 @State 持有并整体替换）。
   */
  @Prop @Watch('onDataChanged') data: HeatMapData = {
    subjects: [], rows: [], valid: false, nameCol: -1, time: ''
  };
  /** 数据导入时间（无数据时空串） */
  @Prop timeText: string = '';
  /** 是否正在加载（首帧避免闪"暂无数据"） */
  @Prop loading: boolean = false;
  onOpen: () => void = () => {};
  @StorageProp('appResolvedTheme') resolvedTheme: string = 'light';
  @StorageProp('appLang') appLang: string = 'zh';

  private visibleRows: HeatRow[] = [];
  private visibleSubjects: HeatSubject[] = [];
  private moreRows: number = 0;
  private moreCols: number = 0;

  onDataChanged(): void {
    this.recompute();
  }

  aboutToAppear(): void {
    this.recompute();
  }

  /** 截取缩略矩阵（超出部分计数，用于"+N"提示） */
  private recompute(): void {
    const d: HeatMapData = this.data;
    if (d === undefined || d === null || !d.valid) {
      this.visibleRows = [];
      this.visibleSubjects = [];
      this.moreRows = 0;
      this.moreCols = 0;
      return;
    }
    const subCount: number = Math.min(d.subjects.length, THUMB_COLS);
    const rowCount: number = Math.min(d.rows.length, THUMB_ROWS);
    this.visibleSubjects = d.subjects.slice(0, subCount);
    this.visibleRows = d.rows.slice(0, rowCount);
    this.moreCols = d.subjects.length - subCount;
    this.moreRows = d.rows.length - rowCount;
  }

  private t(key: string): string {
    void this.appLang;
    return I18n.t(key);
  }

  private col(key: string): string {
    void this.resolvedTheme;
    return AppTheme.color(key, this.resolvedTheme);
  }

  /** 学生名过长时截断，避免撑破列宽 */
  private shortName(s: string): string {
    const max: number = 5;
    return s.length > max ? s.substring(0, max) + '…' : s;
  }

  build() {
    Column({ space: 10 }) {
      // ---- 标题行 ----
      Row() {
        Text(this.t('heat.title'))
          .fontFamily(AppFonts.family())
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.col('title'))
          .layoutWeight(1)
        if (this.data !== undefined && this.data !== null && this.data.valid) {
          Text(this.t('heat.detail'))
            .fontFamily(AppFonts.family())
            .fontSize(12)
            .fontColor('#4A90D9')
        }
      }
      .width('100%')

      if (this.data !== undefined && this.data !== null && this.data.valid) {
        // ---- 科目表头 ----
        Row({ space: 4 }) {
          // 左上角空位（对齐学生名列）
          Text('')
            .width(52)
          ForEach(this.visibleSubjects, (s: HeatSubject) => {
            Text(s.name)
              .fontFamily(AppFonts.family())
              .fontSize(11)
              .fontColor(this.col('sub'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
              .textAlign(TextAlign.Center)
          }, (s: HeatSubject) => 'h_' + s.col.toString())
          if (this.moreCols > 0) {
            Text('+' + this.moreCols.toString())
              .fontFamily(AppFonts.family())
              .fontSize(11)
              .fontColor(this.col('faint'))
              .width(24)
              .textAlign(TextAlign.Center)
          }
        }
        .width('100%')

        // ---- 学生行 ----
        ForEach(this.visibleRows, (r: HeatRow) => {
          Row({ space: 4 }) {
            Text(this.shortName(r.student))
              .fontFamily(AppFonts.family())
              .fontSize(11)
              .fontColor(this.col('text'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width(52)
            ForEach(r.cells.slice(0, this.visibleSubjects.length),
              (c: HeatCellLike, idx: number) => {
                Text(c.raw === '' ? '—' : c.raw)
                  .fontFamily(AppFonts.family())
                  .fontSize(10)
                  .fontColor(HeatMap.inkOf(c.level))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
                  .height(24)
                  .textAlign(TextAlign.Center)
                  .backgroundColor(HeatMap.colorOf(c.level))
                  .borderRadius(4)
              }, (c: HeatCellLike, idx: number) => 'c_' + idx.toString())
            if (this.moreCols > 0) {
              Text('')
                .width(24)
            }
          }
          .width('100%')
        }, (r: HeatRow, i: number) => 'r_' + i.toString())

        // ---- 超出提示 + 数据来源 ----
        if (this.moreRows > 0) {
          Text(I18n.t('heat.moreRows').replace('{n}', this.moreRows.toString()))
            .fontFamily(AppFonts.family())
            .fontSize(11)
            .fontColor(this.col('faint'))
            .width('100%')
        }
        if (this.timeText !== '') {
          Text(I18n.t('heat.source').replace('{t}', this.timeText))
            .fontFamily(AppFonts.family())
            .fontSize(11)
            .fontColor(this.col('faint'))
            .width('100%')
        }
      } else if (this.loading) {
        Text(this.t('heat.loading'))
          .fontFamily(AppFonts.family())
          .fontSize(13)
          .fontColor(this.col('hint'))
          .width('100%')
          .padding({ top: 10, bottom: 10 })
      } else {
        // 无数据：给出明确引导，而不是空白
        Text(this.t('heat.empty'))
          .fontFamily(AppFonts.family())
          .fontSize(13)
          .fontColor(this.col('hint'))
          .width('100%')
          .padding({ top: 10, bottom: 10 })
      }
    }
    .width('100%')
    .padding(14)
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(this.col('card'))
    .borderRadius(14)
    .shadow({ radius: 8, color: 'rgba(0,0,0,0.06)', offsetY: 3 })
    .onClick(() => {
      if (this.data !== undefined && this.data !== null && this.data.valid) {
        this.onOpen();
      }
    })
  }
}

/** 单元格的轻量视图类型（避免在 ForEach 里直接引用 HeatCell 造成泛型推断问题） */
interface HeatCellLike {
  raw: string;
  value: number;
  level: number;
}
