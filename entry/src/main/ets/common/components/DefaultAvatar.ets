/**
 * 默认头像组件：圆形底 + 人形剪影（未设置头像/未登录时展示）
 *  - 颜色为中性灰蓝，明暗主题下均可读
 *  - size 控制整体边长（vp），内部图形按比例缩放
 */
@Component
export struct DefaultAvatar {
  /** 边长（vp） */
  @Prop side: number = 96;
  /** 底色（默认灰蓝，可按需覆盖） */
  @Prop bg: string = '#A9BDD1';

  private headSize(): number {
    return this.side * 0.34;
  }

  private bodyW(): number {
    return this.side * 0.62;
  }

  private bodyH(): number {
    return this.side * 0.38;
  }

  private white(): string {
    return 'rgba(255,255,255,0.95)';
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      // 底圆
      Column()
        .width(this.side)
        .height(this.side)
        .borderRadius(this.side / 2)
        .backgroundColor(this.bg)
      // 人形：头 + 肩
      Column({ space: this.side * 0.06 }) {
        Row()
          .width(this.headSize())
          .height(this.headSize())
          .borderRadius(this.headSize() / 2)
          .backgroundColor(this.white())
        Row()
          .width(this.bodyW())
          .height(this.bodyH())
          .borderRadius({ topLeft: this.bodyW() / 2, topRight: this.bodyW() / 2 })
          .backgroundColor(this.white())
      }
      .offset({ y: -this.side * 0.03 })
    }
    .width(this.side)
    .height(this.side)
  }
}
