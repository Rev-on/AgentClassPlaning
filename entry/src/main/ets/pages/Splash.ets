/**
 * 启动屏（描边版）：
 *  1) 将品牌线稿的骨架折线按“一笔一笔画出来”的方式在 Canvas 上逐段描画
 *  2) 绘制完成后品牌名/标语/版本行淡入
 *  3) 短暂停留后跳转主界面（含失败重试与超时兜底）
 *
 * 描边数据：common/SplashStrokes.ets（由 AppScope/media/foreground1.png 骨架化离线生成）
 */
import { router } from '@kit.ArkUI';
import display from '@ohos.display';
import { AppTheme } from '../common/AppTheme';
import { I18n } from '../common/I18n';
import { AppFonts } from '../common/AppFonts';
import { VerticalMongolianText } from '../common/components/VerticalMongolianText';
import { SPLASH_STROKES } from '../common/SplashStrokes';

/** 描画动画总时长（毫秒） */
const DRAW_MS: number = 1500;
/** 线条相对宽度（相对画布） */
const PEN_W: number = 0.02;

@Entry
@Component
struct Splash {
  @StorageProp('appLang') appLang: string = 'zh';
  @StorageProp('appResolvedTheme') resolvedTheme: string = 'light';
  /** 文字是否已淡入（线稿画完后） */
  @State textShown: boolean = false;
  @State mainSize: number = 32;
  @State subSize: number = 13;
  @State canvasSize: number = 260;

  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private ready: boolean = false;
  private prepared: boolean = false;
  /** 每段折线各顶点累计长度 */
  private cum: number[][] = [];
  /** 每段折线总长 */
  private strokeTotal: number[] = [];
  /** 全部折线总长 */
  private grandTotal: number = 0;
  /** 动画状态 */
  private drawStart: number = 0;
  private finished: boolean = false;
  private headX: number = -1;
  private headY: number = -1;

  private drawTimer: number = -1;
  private textTimer: number = -1;
  private jumpTimer: number = -1;
  private fallbackTimer: number = -1;

  aboutToAppear(): void {
    this.ensureFonts();
    // 响应式字号与画布尺寸
    try {
      const disp = display.getDefaultDisplaySync();
      const w: number = px2vp(disp.width);
      this.mainSize = Math.max(26, Math.min(40, w * 0.042));
      this.subSize = Math.max(12, Math.min(16, w * 0.017));
      this.canvasSize = Math.max(200, Math.min(320, w * 0.58));
    } catch (e) {
      // 使用默认值
    }
    // 预计算描边累计长度
    this.prepareStrokes();
    // 描画循环
    this.drawStart = Date.now() + 120;
    this.drawTimer = setInterval(() => {
      this.renderFrame();
    }, 16);
    // 兜底：任何异常也不超过 3.2s
    this.fallbackTimer = setTimeout(() => {
      this.goIndex();
    }, 3200);
  }

  aboutToDisappear(): void {
    if (this.drawTimer !== -1) {
      clearInterval(this.drawTimer);
      this.drawTimer = -1;
    }
    if (this.textTimer !== -1) {
      clearTimeout(this.textTimer);
      this.textTimer = -1;
    }
    if (this.jumpTimer !== -1) {
      clearTimeout(this.jumpTimer);
      this.jumpTimer = -1;
    }
    if (this.fallbackTimer !== -1) {
      clearTimeout(this.fallbackTimer);
      this.fallbackTimer = -1;
    }
  }

  /** 注册内置少数民族字体（进程内仅执行一次；失败不阻塞界面，文字可回退系统字体） */
  private ensureFonts(): void {
    if (AppStorage.get<boolean>('revFontsReg') === true) {
      return;
    }
    try {
      this.getUIContext().getFont().registerFont({
        familyName: AppFonts.TIBETAN,
        familySrc: $rawfile('fonts/ctrc-uchen.ttf')
      });
      this.getUIContext().getFont().registerFont({
        familyName: AppFonts.UYGHUR,
        familySrc: $rawfile('fonts/UKIJMejT.ttf')
      });
      this.getUIContext().getFont().registerFont({
        familyName: AppFonts.MONGOLIAN,
        familySrc: $rawfile('fonts/c8abb3845e34a252fcf04f0cd4e74a00.ttf')
      });
    } catch (e) {
      // 注册失败时回退系统字体，不影响启动
    }
    AppStorage.setOrCreate('revFontsReg', true);
  }

  /** 预计算每条折线的累计长度 */
  private prepareStrokes(): void {
    if (this.prepared) {
      return;
    }
    this.prepared = true;
    this.cum = [];
    this.strokeTotal = [];
    this.grandTotal = 0;
    for (let s = 0; s < SPLASH_STROKES.length; s++) {
      const flat: number[] = SPLASH_STROKES[s];
      const n: number = Math.floor(flat.length / 2);
      const c: number[] = [0];
      let total: number = 0;
      for (let i = 1; i < n; i++) {
        const x0: number = flat[(i - 1) * 2];
        const y0: number = flat[(i - 1) * 2 + 1];
        const x1: number = flat[i * 2];
        const y1: number = flat[i * 2 + 1];
        const dx: number = x1 - x0;
        const dy: number = y1 - y0;
        total += Math.sqrt(dx * dx + dy * dy);
        c.push(total);
      }
      this.cum.push(c);
      this.strokeTotal.push(total);
      this.grandTotal += total;
    }
  }

  private goIndex(): void {
    router.replaceUrl({ url: 'pages/Index' }).catch(() => {
      setTimeout(() => {
        router.replaceUrl({ url: 'pages/Index' }).catch(() => {
          // 再次失败则停留在当前页
        });
      }, 500);
    });
  }

  /** 描画进度 0..1（先匀速，最后 15% 减速，收笔更自然） */
  private progressOf(now: number): number {
    const t: number = Math.max(0, Math.min(1, (now - this.drawStart) / DRAW_MS));
    if (t <= 0) {
      return 0;
    }
    if (t >= 0.85) {
      const tail: number = (t - 0.85) / 0.15;
      return 0.85 + 0.15 * (1 - Math.pow(1 - tail, 3));
    }
    return t;
  }

  /** 在画布上按当前进度描画所有折线 */
  private renderFrame(): void {
    const now: number = Date.now();
    if (!this.finished && this.drawStart > 0 && now >= this.drawStart) {
      const p: number = this.progressOf(now);
      if (p >= 1) {
        this.finished = true;
        if (this.drawTimer !== -1) {
          clearInterval(this.drawTimer);
          this.drawTimer = -1;
        }
        this.textTimer = setTimeout(() => {
          this.textShown = true;
        }, 120);
        this.jumpTimer = setTimeout(() => {
          this.goIndex();
        }, 950);
      }
      this.drawProgress(p);
    }
  }

  /** 用预算长度 b（0..total）逐段绘制折线，并记录当前笔尖位置 */
  private drawProgress(b: number): void {
    if (!this.ready || !this.prepared) {
      return;
    }
    const c = this.ctx;
    const cs: number = this.canvasSize;
    c.clearRect(0, 0, cs, cs);
    if (this.grandTotal <= 0) {
      return;
    }
    const ink: string = this.col('title');
    c.strokeStyle = ink;
    c.lineWidth = Math.max(1.5, cs * PEN_W);
    c.lineCap = 'round';
    c.lineJoin = 'round';

    let budget: number = b;
    for (let s = 0; s < SPLASH_STROKES.length; s++) {
      const flat: number[] = SPLASH_STROKES[s];
      const n: number = Math.floor(flat.length / 2);
      if (n < 2) {
        continue;
      }
      const total: number = this.strokeTotal[s];
      if (total <= 0) {
        continue;
      }
      if (budget >= total) {
        // 整条折线一次画完
        budget -= total;
        c.beginPath();
        c.moveTo(flat[0] * cs, flat[1] * cs);
        for (let i = 1; i < n; i++) {
          c.lineTo(flat[i * 2] * cs, flat[i * 2 + 1] * cs);
        }
        c.stroke();
        this.headX = flat[(n - 1) * 2] * cs;
        this.headY = flat[(n - 1) * 2 + 1] * cs;
      } else {
        // 当前笔划只画到预算长度处
        const cc: number[] = this.cum[s];
        let i: number = 0;
        while (i + 1 < n && cc[i + 1] <= budget) {
          i++;
        }
        c.beginPath();
        c.moveTo(flat[0] * cs, flat[1] * cs);
        for (let k = 1; k <= i; k++) {
          c.lineTo(flat[k * 2] * cs, flat[k * 2 + 1] * cs);
        }
        if (i + 1 < n) {
          const segLen: number = cc[i + 1] - cc[i];
          const remain: number = segLen > 0 ? Math.max(0, Math.min(1, (budget - cc[i]) / segLen)) : 0;
          const x: number = flat[i * 2] + (flat[(i + 1) * 2] - flat[i * 2]) * remain;
          const y: number = flat[i * 2 + 1] + (flat[(i + 1) * 2 + 1] - flat[i * 2 + 1]) * remain;
          c.lineTo(x * cs, y * cs);
          this.headX = x * cs;
          this.headY = y * cs;
        }
        c.stroke();
        break;
      }
    }
    // 笔尖光点（仅动画进行中显示）
    if (this.headX >= 0 && this.headY >= 0 && !this.finished) {
      const tip: number = Math.max(3, cs * 0.012);
      c.fillStyle = '#E4572E';
      c.globalAlpha = 0.28;
      c.beginPath();
      c.arc(this.headX, this.headY, tip * 2.4, 0, Math.PI * 2);
      c.fill();
      c.globalAlpha = 1;
      c.fillStyle = '#E4572E';
      c.beginPath();
      c.arc(this.headX, this.headY, tip, 0, Math.PI * 2);
      c.fill();
    }
    this.headX = -1;
    this.headY = -1;
  }

  private col(key: string): string {
    void this.resolvedTheme;
    return AppTheme.color(key, this.resolvedTheme);
  }

  private cloudIcon(): Resource {
    return this.resolvedTheme === 'dark'
      ? $r('app.media.huaweicloud_dark')
      : $r('app.media.huaweicloud');
  }

  private slogan1(): string {
    void this.appLang;
    return I18n.t('splash.l1');
  }

  private slogan2(): string {
    void this.appLang;
    return I18n.t('splash.l2');
  }

  build() {
    Column() {
      Column()
        .layoutWeight(1)
        .width('100%')
      // 线稿逐笔描画画布
      Canvas(this.ctx)
        .width(this.canvasSize)
        .height(this.canvasSize)
        .onReady(() => {
          this.ready = true;
        })
      // 品牌文字（线稿完成后淡入）
      Column({ space: 8 }) {
        Text('Rev TechingMaster')
          .fontFamily(AppFonts.family())
          .fontSize(this.subSize + 3)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.col('hint'))
          .letterSpacing(2)
        VerticalMongolianText({
          content: this.slogan1(),
          textSize: this.mainSize,
          textColor: this.col('title'),
          isBold: true,
          letterSpacingNum: 1
        })
        VerticalMongolianText({
          content: this.slogan2(),
          textSize: this.mainSize,
          textColor: this.col('title'),
          isBold: true,
          letterSpacingNum: 1,
          marginLeftPct: 13
        })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
      .padding({ top: 16 })
      .opacity(this.textShown ? 1 : 0)
      .animation({ duration: 450, curve: Curve.EaseOut })
      Column()
        .layoutWeight(1)
        .width('100%')
      // 底部版本与云品牌行
      Column({ space: 6 }) {
        Text('v1.0.0 · AGPL-3.0')
          .fontFamily(AppFonts.family())
          .fontSize(11)
          .fontColor(this.col('faint'))
        Row({ space: 5 }) {
          Image(this.cloudIcon())
            .width(20)
            .height(20)
            .objectFit(ImageFit.Contain)
          Text('华为云™提供技术支持')
            .fontFamily(AppFonts.family())
            .fontSize(11)
            .fontColor(this.col('faint'))
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
      }
      .width('100%')
      .padding({ bottom: 26 })
      .opacity(this.textShown ? 1 : 0)
      .animation({ duration: 450, curve: Curve.EaseOut })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.col('bg'))
  }
}
