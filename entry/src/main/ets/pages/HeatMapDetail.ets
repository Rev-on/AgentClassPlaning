/**
 * 成绩热力图详情页。
 *
 * 展示完整矩阵：横轴 = 科目，纵轴 = 学生，单元格深浅 = 成绩相对水平。
 * 支持横向滚动（科目多时）与纵向滚动（学生多时），并带图例说明色阶含义。
 *
 * 数据来源：AnalysisStore 持久化的"最近一次导入的成绩 Excel"。
 * 全部在本机渲染，不外发；姓名仅在本地显示。
 */
import router from '@ohos.router';
import common from '@ohos.app.ability.common';
import { AnalysisStore, ScoreSnapshot } from '../common/AnalysisStore';
import { HeatMap, HeatMapData, HeatRow, HeatSubject } from '../common/HeatMap';
import { I18n } from '../common/I18n';
import { AppTheme } from '../common/AppTheme';
import { AppFonts } from '../common/AppFonts';
import { PageHeader } from '../common/components/PageHeader';
import { SafeInsets } from '../common/SafeInsets';

/** 单元格尺寸 */
const CELL_W: number = 46;
const CELL_H: number = 30;
/** 学生名列宽 */
const NAME_W: number = 66;

interface HeatCellLike {
  raw: string;
  value: number;
  level: number;
}

@Entry
@Component
struct HeatMapDetail {
  @State data: HeatMapData = { subjects: [], rows: [], valid: false, nameCol: -1, time: '' };
  @State loading: boolean = true;
  /** 状态栏安全区高度（vp）：异步取到后重排，避免顶部被状态栏压住 */
  @State topInset: number = 0;
  @StorageProp('appLang') appLang: string = 'zh';
  @StorageProp('appResolvedTheme') resolvedTheme: string = 'light';

  aboutToAppear(): void {
    SafeInsets.topInset(getContext(this) as common.UIAbilityContext).then((v: number): void => {
      this.topInset = v;
    }).catch(() => {
      this.topInset = 0;
    });
    this.load();
  }

  private async load(): Promise<void> {
    this.loading = true;
    try {
      const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const snap: ScoreSnapshot | null = await AnalysisStore.loadScores(ctx);
      if (snap === null) {
        this.data = { subjects: [], rows: [], valid: false, nameCol: -1, time: '' };
      } else {
        this.data = HeatMap.build(snap.headers, snap.rows, snap.time);
      }
    } catch (e) {
      this.data = { subjects: [], rows: [], valid: false, nameCol: -1, time: '' };
    }
    this.loading = false;
  }

  private t(key: string): string {
    void this.appLang;
    return I18n.t(key);
  }

  private col(key: string): string {
    void this.resolvedTheme;
    return AppTheme.color(key, this.resolvedTheme);
  }

  /** 概览统计：用于顶部摘要 */
  private averageLevel(): string {
    if (!this.data.valid) {
      return '';
    }
    let sum: number = 0;
    let cnt: number = 0;
    for (let i: number = 0; i < this.data.rows.length; i++) {
      const cells = this.data.rows[i].cells;
      for (let j: number = 0; j < cells.length; j++) {
        if (cells[j].level >= 0) {
          sum += cells[j].level;
          cnt++;
        }
      }
    }
    if (cnt === 0) {
      return '';
    }
    return Math.round((sum / cnt) * 100).toString() + '%';
  }

  /** 图例：浅 -> 深 五档 */
  @Builder
  legend() {
    Row({ space: 6 }) {
      Text(this.t('heat.low'))
        .fontFamily(AppFonts.family())
        .fontSize(11)
        .fontColor(this.col('hint'))
      ForEach([0.0, 0.25, 0.5, 0.75, 1.0], (lv: number) => {
        Row()
          .width(22)
          .height(12)
          .backgroundColor(HeatMap.colorOf(lv))
          .borderRadius(2)
      }, (lv: number) => 'lg_' + lv.toString())
      Text(this.t('heat.high'))
        .fontFamily(AppFonts.family())
        .fontSize(11)
        .fontColor(this.col('hint'))
      // 缺失值说明
      Row()
        .width(22)
        .height(12)
        .backgroundColor(HeatMap.colorOf(-1))
        .borderRadius(2)
      Text(this.t('heat.missing'))
        .fontFamily(AppFonts.family())
        .fontSize(11)
        .fontColor(this.col('hint'))
    }
    .width('100%')
  }

  build() {
    Column() {
      PageHeader({ title: this.t('heat.detailTitle') })

      if (this.loading) {
        Column() {
          Text(this.t('heat.loading'))
            .fontFamily(AppFonts.family())
            .fontSize(14)
            .fontColor(this.col('hint'))
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (!this.data.valid) {
        Column({ space: 10 }) {
          Text(this.t('heat.empty'))
            .fontFamily(AppFonts.family())
            .fontSize(14)
            .fontColor(this.col('hint'))
            .textAlign(TextAlign.Center)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .padding(24)
      } else {
        Column({ space: 10 }) {
          // ---- 摘要 ----
          Row({ space: 14 }) {
            Text(I18n.t('heat.sumStudents').replace('{n}', this.data.rows.length.toString()))
              .fontFamily(AppFonts.family())
              .fontSize(12)
              .fontColor(this.col('sub'))
            Text(I18n.t('heat.sumSubjects').replace('{n}', this.data.subjects.length.toString()))
              .fontFamily(AppFonts.family())
              .fontSize(12)
              .fontColor(this.col('sub'))
            if (this.averageLevel() !== '') {
              Text(I18n.t('heat.sumAvg').replace('{v}', this.averageLevel()))
                .fontFamily(AppFonts.family())
                .fontSize(12)
                .fontColor(this.col('sub'))
            }
          }
          .width('100%')

          this.legend()

          if (this.data.time !== '') {
            Text(I18n.t('heat.source').replace('{t}', this.data.time))
              .fontFamily(AppFonts.family())
              .fontSize(11)
              .fontColor(this.col('faint'))
              .width('100%')
          }

          // ---- 矩阵（横向可滚，纵向可滚）----
          Scroll() {
            Column({ space: 3 }) {
              // 表头：科目
              Row({ space: 3 }) {
                Text(this.t('heat.studentCol'))
                  .fontFamily(AppFonts.family())
                  .fontSize(11)
                  .fontColor(this.col('sub'))
                  .width(NAME_W)
                  .maxLines(1)
                ForEach(this.data.subjects, (s: HeatSubject) => {
                  Text(s.name)
                    .fontFamily(AppFonts.family())
                    .fontSize(11)
                    .fontColor(this.col('sub'))
                    .width(CELL_W)
                    .height(CELL_H)
                    .textAlign(TextAlign.Center)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }, (s: HeatSubject) => 'dh_' + s.col.toString())
              }
              .width(NAME_W + (CELL_W + 3) * this.data.subjects.length)

              // 学生行
              List() {
                ForEach(this.data.rows, (r: HeatRow) => {
                  ListItem() {
                    Row({ space: 3 }) {
                      Text(r.student)
                        .fontFamily(AppFonts.family())
                        .fontSize(11)
                        .fontColor(this.col('text'))
                        .width(NAME_W)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                      ForEach(r.cells, (c: HeatCellLike) => {
                        Text(c.raw === '' ? '—' : c.raw)
                          .fontFamily(AppFonts.family())
                          .fontSize(11)
                          .fontColor(HeatMap.inkOf(c.level))
                          .width(CELL_W)
                          .height(CELL_H)
                          .textAlign(TextAlign.Center)
                          .maxLines(1)
                          .backgroundColor(HeatMap.colorOf(c.level))
                          .borderRadius(4)
                      }, (c: HeatCellLike, idx: number) => 'dc_' + idx.toString())
                    }
                    .width(NAME_W + (CELL_W + 3) * this.data.subjects.length)
                  }
                }, (r: HeatRow, i: number) => 'dr_' + i.toString())
              }
              .width(NAME_W + (CELL_W + 3) * this.data.subjects.length)
              .layoutWeight(1)
              .scrollBar(BarState.Auto)
            }
            .alignItems(HorizontalAlign.Start)
          }
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Auto)
          .width('100%')
          .layoutWeight(1)
          .align(Alignment.TopStart)
        }
        .width('100%')
        .layoutWeight(1)
        .padding(14)
        .alignItems(HorizontalAlign.Start)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.col('bg'))
    .padding({ top: this.topInset })
  }
}
