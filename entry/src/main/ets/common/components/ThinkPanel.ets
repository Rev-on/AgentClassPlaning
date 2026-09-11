/**
 * 深度思考（DeepSeek 思维链）共用组件：
 *  - ThinkSwitch：生成页输入区内的开关。开启后本次生成走"思考模式"
 *    （服务端 thinking.type=enabled），模型先推理再作答，耗时更长、质量更高。
 *    开关状态持久化在 AppSettings.KEY_THINK（AppStorage 键 deepThink）。
 *  - ThinkPanel：思考过程展示框。生成中灰色小字实时滚动；生成完成后由页面
 *    自动折叠为一行标题，用户点击标题即可展开/收起查看完整思考过程。
 */
import common from '@ohos.app.ability.common';
import { I18n } from '../I18n';
import { AppTheme } from '../AppTheme';
import { AppFonts } from '../AppFonts';
import { AppSettings } from '../AppSettings';

/** 思考框展开时的固定高度（vp，约 6 行小字，超出内部滚动） */
const BODY_MAX_H: number = 120;
/** 折叠/展开过渡时长（ms） */
const BODY_ANIM_MS: number = 200;
/** 生成中自动滚动到底部的延迟（等一帧完成布局） */
const SCROLL_DELAY: number = 32;

@Component
export struct ThinkSwitch {
  /** 与 AppStorage 双向绑定：任一生成页修改后全局一致，并持久化到 preferences */
  @StorageLink('deepThink') on: boolean = false;
  @StorageProp('appLang') appLang: string = 'zh';
  @StorageProp('appResolvedTheme') resolvedTheme: string = 'light';

  private t(key: string): string {
    void this.appLang;
    return I18n.t(key);
  }

  private col(key: string): string {
    void this.resolvedTheme;
    return AppTheme.color(key, this.resolvedTheme);
  }

  build() {
    Row({ space: 8 }) {
      Column({ space: 2 }) {
        Text(this.t('think.title'))
          .fontFamily(AppFonts.family())
          .fontSize(14)
          .fontColor(this.col('title'))
          .width('100%')
        Text(this.t('think.hint'))
          .fontFamily(AppFonts.family())
          .fontSize(11)
          .fontColor(this.col('hint'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Toggle({ type: ToggleType.Switch, isOn: this.on })
        .selectedColor('#4A90D9')
        .onChange((isOn: boolean) => {
          this.on = isOn;
          // 持久化：下次启动/进入其它生成页保持同一开关状态
          void AppSettings.saveThink(getContext(this) as common.UIAbilityContext, isOn);
        })
    }
    .width('100%')
    .padding({ top: 2 })
  }
}

@Component
export struct ThinkPanel {
  /** 思考过程全文（生成中持续更新；服务端按"当前全文"语义回传） */
  @Prop @Watch('onTextChanged') text: string = '';
  /** 是否展开（生成中由页面置为展开，完成后自动置为折叠） */
  @Link expanded: boolean;
  /** 生成中：显示"深度思考中…"与进度指示 */
  @Prop running: boolean = false;
  @StorageProp('appLang') appLang: string = 'zh';
  @StorageProp('appResolvedTheme') resolvedTheme: string = 'light';

  private bodyScroll: Scroller = new Scroller();

  private t(key: string): string {
    void this.appLang;
    return I18n.t(key);
  }

  private col(key: string): string {
    void this.resolvedTheme;
    return AppTheme.color(key, this.resolvedTheme);
  }

  /** 思考内容更新：展开状态下自动滚到最新一行 */
  onTextChanged(): void {
    if (!this.expanded) {
      return;
    }
    setTimeout((): void => {
      try {
        this.bodyScroll.scrollEdge(Edge.Bottom);
      } catch (e) {
        // 尚未挂载时忽略
      }
    }, SCROLL_DELAY);
  }

  build() {
    Column({ space: 0 }) {
      // 标题行：点击展开/收起
      Row({ space: 6 }) {
        if (this.running) {
          LoadingProgress().width(12).height(12).color('#4A90D9')
        }
        Text(this.running ? this.t('think.running') : this.t('think.done'))
          .fontFamily(AppFonts.family())
          .fontSize(12)
          .fontColor(this.col('sub'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text(this.expanded ? this.t('think.collapse') : this.t('think.expand'))
          .fontFamily(AppFonts.family())
          .fontSize(11)
          .fontColor(this.col('hint'))
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 8, bottom: 8 })
      .onClick(() => {
        this.expanded = !this.expanded;
        if (this.expanded && !this.running) {
          // 生成完成后手动展开：从思考过程开头看起（生成中则保持在最新一行）
          setTimeout((): void => {
            try {
              this.bodyScroll.scrollEdge(Edge.Top);
            } catch (e) {
              // 尚未挂载时忽略
            }
          }, SCROLL_DELAY);
        }
      })

      // 思考正文：灰色小字，生成中实时滚动
      // 高度由 expanded 驱动：折叠时高度为 0 + 隐藏 + 剪裁，过渡平滑
      // （条件渲染会瞬间消失；固定高度配合 animation 让下方内容自然上移/下移）
      Column() {
        Scroll(this.bodyScroll) {
          Text(this.text)
            .fontFamily(AppFonts.family())
            .fontSize(12)
            .fontColor(this.col('sub'))
            .lineHeight(18)
            .width('100%')
        }
        .width('100%')
        .height(BODY_MAX_H)
        .padding({ left: 12, right: 12, bottom: 10 })
        .scrollBar(BarState.Auto)
      }
      .width('100%')
      .height(this.expanded ? BODY_MAX_H : 0)
      .opacity(this.expanded ? 1 : 0)
      .clip(true)
      .animation({ duration: BODY_ANIM_MS, curve: Curve.EaseInOut, delay: 0, iterations: 1, playMode: PlayMode.Normal })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(this.col('headBg'))
    .borderRadius(10)
  }
}
