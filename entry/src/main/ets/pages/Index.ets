/**
 * 主界面：底部三 Tab（支持中英双语与深浅主题）
 *  备课助手 / 家校沟通 / 我的（历史记录、设置等入口）
 */
import router from '@ohos.router';
import common from '@ohos.app.ability.common';
import { I18n } from '../common/I18n';
import { AppTheme } from '../common/AppTheme';
import { AcceptStore } from '../common/AcceptStore';

/** 免责声明弹窗：首次启动显示，倒计时 5 秒后方可同意；同意后永久不再显示 */
@CustomDialog
struct DisclaimerDialog {
  controller: CustomDialogController = new CustomDialogController({ builder: undefined });
  @State remain: number = 5;
  private timer: number = -1;
  @StorageProp('appLang') appLang: string = 'zh';
  @StorageProp('appResolvedTheme') resolvedTheme: string = 'light';

  aboutToAppear(): void {
    this.timer = setInterval(() => {
      if (this.remain > 0) {
        this.remain--;
        if (this.remain === 0 && this.timer !== -1) {
          clearInterval(this.timer);
          this.timer = -1;
        }
      }
    }, 1000);
  }

  aboutToDisappear(): void {
    if (this.timer !== -1) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  private t(key: string): string {
    void this.appLang;
    return I18n.t(key);
  }

  private col(key: string): string {
    void this.resolvedTheme;
    return AppTheme.color(key, this.resolvedTheme);
  }

  /** 同意：写入标记后关闭，此后不再显示 */
  private onAgree(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    AcceptStore.setAccepted(ctx).then(() => {
      this.controller.close();
    }).catch(() => {
      this.controller.close();
    });
  }

  /** 不同意：直接退出应用（不写标记，下次进入仍显示） */
  private onDisagree(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    ctx.terminateSelf().catch(() => {
      // 退出失败则关闭弹窗兜底
      this.controller.close();
    });
  }

  build() {
    Column({ space: 14 }) {
      Text(this.t('dlg.title'))
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.col('title'))
        .width('100%')
      Text(this.t('dlg.body'))
        .fontSize(14)
        .fontColor(this.col('text'))
        .lineHeight(23)
        .width('100%')
      if (this.remain > 0) {
        Text(this.t('dlg.count').replace('{n}', this.remain.toString()))
          .fontSize(12)
          .fontColor(this.col('hint'))
          .width('100%')
      }
      Row({ space: 10 }) {
        Button(this.t('dlg.agree'))
          .fontSize(14)
          .height(40)
          .layoutWeight(1)
          .backgroundColor('#4A90D9')
          .enabled(this.remain === 0)
          .opacity(this.remain === 0 ? 1 : 0.45)
          .onClick(() => this.onAgree())
        Button(this.t('dlg.disagree'))
          .fontSize(14)
          .height(40)
          .layoutWeight(1)
          .backgroundColor('#C0392B')
          .onClick(() => this.onDisagree())
      }
      .width('100%')
    }
    .width('88%')
    .padding(20)
    .backgroundColor(this.col('card'))
    .borderRadius(18)
  }
}

/** 功能入口卡片（@Prop 单向同步，保证语言切换后标题描述即时更新） */
@Component
struct FunCard {
  icon: string = '';
  @Prop title: string = '';
  @Prop desc: string = '';
  bgColor: string = '#E8F1FB';
  onTap: () => void = () => {};
  @StorageProp('appResolvedTheme') resolvedTheme: string = 'light';
  @StorageProp('appLang') appLang: string = 'zh';

  private t(key: string): string {
    void this.appLang;
    return I18n.t(key);
  }

  private col(key: string): string {
    void this.resolvedTheme;
    return AppTheme.color(key, this.resolvedTheme);
  }

  build() {
    Column({ space: 8 }) {
      Text(this.icon)
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor('#2B4C7E')
        .width(46)
        .height(46)
        .textAlign(TextAlign.Center)
        .backgroundColor(this.bgColor)
        .borderRadius(12)
      Text(this.title)
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.col('title'))
      Text(this.desc)
        .fontSize(12)
        .fontColor(this.col('hint'))
        .textAlign(TextAlign.Center)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding(14)
    .backgroundColor(this.col('card'))
    .borderRadius(14)
    .shadow({ radius: 8, color: 'rgba(0,0,0,0.06)', offsetY: 3 })
    .onClick(() => this.onTap())
  }
}

@Entry
@Component
struct Index {
  @StorageProp('appLang') appLang: string = 'zh';
  @StorageProp('appResolvedTheme') resolvedTheme: string = 'light';
  private dialogController: CustomDialogController = new CustomDialogController({
    builder: DisclaimerDialog(),
    autoCancel: false
  });

  aboutToAppear(): void {
    // 首次进入（未同意过免责声明）时弹出使用须知
    const ctx = getContext(this) as common.UIAbilityContext;
    AcceptStore.getAccepted(ctx).then((acc: boolean) => {
      if (!acc) {
        this.dialogController.open();
      }
    }).catch(() => {
    });
  }

  private t(key: string): string {
    void this.appLang;
    return I18n.t(key);
  }

  private col(key: string): string {
    void this.resolvedTheme;
    return AppTheme.color(key, this.resolvedTheme);
  }

  build() {
    Tabs({ barPosition: BarPosition.End }) {
      // ============ Tab1 备课助手 ============
      TabContent() {
        Scroll() {
          Column({ space: 14 }) {
            Row() {
              Column({ space: 4 }) {
                Text(this.t('tab.assistant'))
                  .fontSize(22)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(this.col('title'))
                Text(this.t('sub.assistant'))
                  .fontSize(12)
                  .fontColor(this.col('hint'))
              }
              .alignItems(HorizontalAlign.Start)
              Blank()
            }
            .width('100%')

            Grid() {
              GridItem() {
                FunCard({
                  icon: '教', title: this.t('card.plan'), desc: this.t('card.plan.desc'),
                  bgColor: '#E8F1FB',
                  onTap: () => router.pushUrl({ url: 'pages/Plan' })
                })
              }
              GridItem() {
                FunCard({
                  icon: '课', title: this.t('card.courseware'), desc: this.t('card.courseware.desc'),
                  bgColor: '#FFF4E5',
                  onTap: () => router.pushUrl({ url: 'pages/Courseware' })
                })
              }
              GridItem() {
                FunCard({
                  icon: '题', title: this.t('card.quiz'), desc: this.t('card.quiz.desc'),
                  bgColor: '#EAF7EF',
                  onTap: () => router.pushUrl({ url: 'pages/Quiz' })
                })
              }
              GridItem() {
                FunCard({
                  icon: '研', title: this.t('card.research'), desc: this.t('card.research.desc'),
                  bgColor: '#F3EDFB',
                  onTap: () => router.pushUrl({ url: 'pages/Research' })
                })
              }
              GridItem() {
                FunCard({
                  icon: '析', title: this.t('card.analysis'), desc: this.t('card.analysis.desc'),
                  bgColor: '#E6F4F2',
                  onTap: () => router.pushUrl({ url: 'pages/Analysis' })
                })
              }
              GridItem() {
                FunCard({
                  icon: '位', title: this.t('card.seats'), desc: this.t('card.seats.desc'),
                  bgColor: '#FFF0E6',
                  onTap: () => router.pushUrl({ url: 'pages/Seats' })
                })
              }
            }
            .columnsTemplate('1fr 1fr')
            .columnsGap(12)
            .rowsGap(12)
            .width('100%')
          }
          .width('100%')
          .padding(16)
        }
        .width('100%')
        .height('100%')
        .backgroundColor(this.col('bg'))
      }
      .tabBar(this.t('tab.assistant'))

      // ============ Tab2 家校沟通 ============
      TabContent() {
        Scroll() {
          Column({ space: 14 }) {
            Row() {
              Column({ space: 4 }) {
                Text(this.t('tab.family'))
                  .fontSize(22)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(this.col('title'))
                Text(this.t('sub.family'))
                  .fontSize(12)
                  .fontColor(this.col('hint'))
              }
              .alignItems(HorizontalAlign.Start)
              Blank()
            }
            .width('100%')

            Grid() {
              GridItem() {
                FunCard({
                  icon: '话', title: this.t('card.talk'), desc: this.t('card.talk.desc'),
                  bgColor: '#FFF0F0',
                  onTap: () => router.pushUrl({ url: 'pages/Talk' })
                })
              }
              GridItem() {
                FunCard({
                  icon: '报', title: this.t('card.report'), desc: this.t('card.report.desc'),
                  bgColor: '#E8F1FB',
                  onTap: () => router.pushUrl({ url: 'pages/Report' })
                })
              }
            }
            .columnsTemplate('1fr 1fr')
            .columnsGap(12)
            .rowsGap(12)
            .width('100%')
          }
          .width('100%')
          .padding(16)
        }
        .width('100%')
        .height('100%')
        .backgroundColor(this.col('bg'))
      }
      .tabBar(this.t('tab.family'))

      // ============ Tab3 我的 ============
      TabContent() {
        Scroll() {
          Column({ space: 14 }) {
            Row() {
              Column({ space: 4 }) {
                Text(this.t('tab.mine'))
                  .fontSize(22)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(this.col('title'))
                Text(this.t('sub.mine'))
                  .fontSize(12)
                  .fontColor(this.col('hint'))
              }
              .alignItems(HorizontalAlign.Start)
              Blank()
            }
            .width('100%')

            Grid() {
              GridItem() {
                FunCard({
                  icon: '史', title: this.t('card.history'), desc: this.t('card.history.desc'),
                  bgColor: '#FFF4E5',
                  onTap: () => router.pushUrl({ url: 'pages/History' })
                })
              }
              GridItem() {
                FunCard({
                  icon: '设', title: this.t('card.settings'), desc: this.t('card.settings.desc'),
                  bgColor: '#E6F4F2',
                  onTap: () => router.pushUrl({ url: 'pages/Settings' })
                })
              }
              GridItem() {
                FunCard({
                  icon: '班', title: this.t('card.classes'), desc: this.t('card.classes.desc'),
                  bgColor: '#F3EDFB',
                  onTap: () => router.pushUrl({ url: 'pages/ClassManager' })
                })
              }
            }
            .columnsTemplate('1fr 1fr')
            .columnsGap(12)
            .rowsGap(12)
            .width('100%')

            Text(this.t('mine.local'))
              .fontSize(11)
              .fontColor(this.col('faint'))
              .width('100%')
              .textAlign(TextAlign.Center)
              .padding({ top: 10 })
          }
          .width('100%')
          .padding(16)
        }
        .width('100%')
        .height('100%')
        .backgroundColor(this.col('bg'))
      }
      .tabBar(this.t('tab.mine'))
    }
    .width('100%')
    .height('100%')
    .barBackgroundColor(this.col('barBg'))
    .barHeight(56)
    .scrollable(false)
    .backgroundColor(this.col('bg'))
  }
}
