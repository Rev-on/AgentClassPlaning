/**
 * 启动屏（粒子版）：
 *  1) 读取主题对应的前景图（foreground/foreground1），采样像素并拆解为彩色粒子
 *  2) 启动时粒子自屏幕外随机飞入，缓动汇聚成中央图案（肉眼无感拼接）
 *  3) 图案成形后，品牌名/标语/版本号整体淡入
 *  4) 停留后跳转主界面（含失败重试与超时兜底）
 */
import { router } from '@kit.ArkUI';
import display from '@ohos.display';
import { image } from '@kit.ImageKit';
import common from '@ohos.app.ability.common';
import { AppTheme } from '../common/AppTheme';

/** 单个粒子 */
interface Particle {
  sx: number;
  sy: number;
  tx: number;
  ty: number;
  delay: number;
  dur: number;
  /** 是否绘制光晕（深色模式） */
  glow: boolean;
  /** 随机相位（用于光晕脉动） */
  seed: number;
}

/** 同色粒子桶（减少 fillStyle 切换） */
interface ParticleBucket {
  color: string;
  pts: Particle[];
}

@Entry
@Component
struct Splash {
  @StorageProp('appLang') appLang: string = 'zh';
  @StorageProp('appResolvedTheme') resolvedTheme: string = 'light';
  /** 文字是否已淡入 */
  @State textShown: boolean = false;
  /** 画布尺寸（vp） */
  @State vpW: number = 360;
  @State vpH: number = 780;
  @State mainSize: number = 32;
  @State subSize: number = 13;

  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private buckets: ParticleBucket[] = [];
  private ptTotal: number = 0;
  /** 图案目标区域中心与尺寸（vp） */
  private gcx: number = 180;
  private gcy: number = 480;
  private gW: number = 160;
  private gH: number = 210;
  private startAt: number = 0;
  private finishAt: number = 0;
  private jumpAt: number = 0;
  private forceAt: number = 0;
  /** 光晕开始消退的时间点（图案全部成形后） */
  private glowFadeAt: number = 0;
  private textDone: boolean = false;
  private jumped: boolean = false;
  private darkMode: boolean = false;
  private tickTimer: number = -1;
  private initTimer: number = -1;

  aboutToAppear(): void {
    // 响应式字号与画布
    try {
      const disp = display.getDefaultDisplaySync();
      const w = px2vp(disp.width);
      const h = px2vp(disp.height);
      this.vpW = w;
      this.vpH = h;
      this.mainSize = Math.max(26, Math.min(40, w * 0.042));
      this.subSize = Math.max(12, Math.min(16, w * 0.017));
    } catch (e) {
      this.vpW = 360;
      this.vpH = 780;
    }
    // 图案目标区：水平居中，尺寸放大；垂直中心由布局中的占位容器动态捕获
    this.gW = Math.max(150, Math.min(232, this.vpW * 0.56));
    this.gH = this.gW * 1.32;
    this.gcx = this.vpW / 2;
    this.gcy = this.vpH * 0.5;
    // 略延迟启动粒子构建，等待主题设置就绪后读取正确的图片
    this.initTimer = setTimeout(() => {
      this.startInit();
    }, 200);
    // 兜底：无论动画是否成功，最多 7 秒后进入主界面
    this.forceAt = Date.now() + 7000;
    this.tickTimer = setInterval(() => {
      this.animateFrame();
    }, 16);
  }

  aboutToDisappear(): void {
    if (this.tickTimer !== -1) {
      clearInterval(this.tickTimer);
      this.tickTimer = -1;
    }
    if (this.initTimer !== -1) {
      clearTimeout(this.initTimer);
      this.initTimer = -1;
    }
  }

  /** 读取主题对应图片并构建粒子 */
  private startInit(): void {
    this.darkMode = (AppStorage.get<string>('appResolvedTheme') as string) === 'dark';
    const res: Resource = this.darkMode ? $r('app.media.foreground') : $r('app.media.foreground1');
    const ctx = getContext(this) as common.UIAbilityContext;
    ctx.resourceManager.getMediaContent(res).then((data: Uint8Array) => {
      const bytes: ArrayBuffer = data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength);
      const source: image.ImageSource = image.createImageSource(bytes);
      source.createPixelMap().then((pm: image.PixelMap) => {
        pm.getImageInfo().then((info: image.ImageInfo) => {
          const iw: number = info.size.width;
          const ih: number = info.size.height;
          const buf: ArrayBuffer = new ArrayBuffer(iw * ih * 4);
          pm.readPixelsToBuffer(buf).then(() => {
            this.buildParticles(new Uint8Array(buf), iw, ih);
          }).catch(() => this.noAnimFallback());
        }).catch(() => this.noAnimFallback());
      }).catch(() => this.noAnimFallback());
    }).catch(() => this.noAnimFallback());
  }

  /** 按 2vp 网格采样图片像素 → 粒子（透明处跳过；颜色量化到 4bit 分桶） */
  private buildParticles(px: Uint8Array, iw: number, ih: number): void {
    const buckets: ParticleBucket[] = [];
    const bmap: Map<string, ParticleBucket> = new Map<string, ParticleBucket>();
    const stepVp: number = 2.2;
    const cols: number = Math.floor(this.gW / stepVp);
    const rows: number = Math.floor(this.gH / stepVp);
    const startDelay: number = Date.now();
    this.startAt = startDelay;
    let count: number = 0;
    for (let r = 0; r < rows; r++) {
      for (let c = 0; c < cols; c++) {
        // 源像素坐标（图像保持方形采样）
        const ox: number = Math.min(iw - 1, Math.floor((c + 0.5) / cols * iw));
        const oy: number = Math.min(ih - 1, Math.floor((r + 0.5) / rows * ih));
        const idx: number = (oy * iw + ox) * 4;
        const a: number = px[idx + 3];
        if (a < 40) {
          continue;
        }
        const rr: number = px[idx];
        const gg: number = px[idx + 1];
        const bb: number = px[idx + 2];
        const qr: number = (rr >> 4) * 17;
        const qg: number = (gg >> 4) * 17;
        const qb: number = (bb >> 4) * 17;
        const key: string = qr + ',' + qg + ',' + qb;
        let bk: ParticleBucket | undefined = bmap.get(key);
        if (bk === undefined) {
          bk = { color: 'rgb(' + qr + ',' + qg + ',' + qb + ')', pts: [] };
          bmap.set(key, bk);
          buckets.push(bk);
        }
        const tx: number = this.gcx - this.gW / 2 + (c + 0.5) * stepVp;
        const ty: number = this.gcy - this.gH / 2 + (r + 0.5) * stepVp;
        const edge: number = Math.floor(Math.random() * 4);
        const margin: number = 30;
        let sx: number = tx;
        let sy: number = ty;
        if (edge === 0) {
          sx = Math.random() * this.vpW;
          sy = -margin - Math.random() * this.vpH * 0.2;
        } else if (edge === 1) {
          sx = this.vpW + margin + Math.random() * this.vpH * 0.15;
          sy = Math.random() * this.vpH;
        } else if (edge === 2) {
          sx = Math.random() * this.vpW;
          sy = this.vpH + margin + Math.random() * this.vpH * 0.2;
        } else {
          sx = -margin - Math.random() * this.vpH * 0.15;
          sy = Math.random() * this.vpH;
        }
        const p: Particle = {
          sx: sx,
          sy: sy,
          tx: tx,
          ty: ty,
          delay: startDelay + Math.random() * 700,
          dur: 800 + Math.random() * 900,
          // 深色模式下约 3/10 粒子作为辉光点
          glow: this.darkMode && Math.random() < 0.3,
          seed: Math.random() * 100
        };
        bk.pts.push(p);
        count++;
      }
    }
    this.buckets = buckets;
    this.ptTotal = count;
    // 最晚粒子到位时间 + 0.3s 缓冲 → 触发文字淡入；再停 1.3s 跳转主界面
    this.finishAt = this.startAt + 700 + 1700 + 300;
    this.jumpAt = this.finishAt + 1300;
    // 图案成形（约 2.4s）后光晕在 700ms 内逐渐消退，让图案以纯净粒子呈现
    this.glowFadeAt = this.startAt + 2400;
  }

  /** 图片读取/解码失败的兜底：直接显示文字并按时跳转 */
  private noAnimFallback(): void {
    if (this.textDone) {
      return;
    }
    this.textDone = true;
    this.textShown = true;
    const now: number = Date.now();
    if (this.startAt === 0) {
      this.startAt = now;
    }
    if (this.jumpAt === 0) {
      this.jumpAt = now + 1400;
    }
  }

  /** 帧循环：推进粒子并从屏幕外汇聚成形；成形后触发文字淡入与跳转 */
  private animateFrame(): void {
    const now: number = Date.now();
    if (this.ptTotal > 0) {
      this.drawFrame(now);
    }
    if (!this.textDone && this.finishAt !== 0 && now >= this.finishAt) {
      this.textDone = true;
      this.textShown = true;
    }
    if (!this.jumped && this.jumpAt !== 0 && now >= this.jumpAt) {
      this.jumped = true;
      this.goIndex();
    }
    if (!this.jumped && this.forceAt !== 0 && now >= this.forceAt) {
      this.jumped = true;
      this.goIndex();
    }
  }

  /** 绘制一帧粒子（深色模式：先绘制辉光光晕，再绘制粒子核心） */
  private drawFrame(now: number): void {
    const c = this.ctx;
    c.clearRect(0, 0, this.vpW, this.vpH);
    if (this.darkMode) {
      // 光晕层：辉光粒子以半透明大圆绘制，半径随相位脉动；图案成形后光晕逐渐消退
      const fade: number = this.glowFadeAt === 0 ? 1 :
        Math.max(0, Math.min(1, 1 - (now - this.glowFadeAt) / 700));
      if (fade > 0) {
        c.globalAlpha = 0.26 * fade;
        for (let b = 0; b < this.buckets.length; b++) {
          const bucket: ParticleBucket = this.buckets[b];
          c.fillStyle = bucket.color;
          const pts: Particle[] = bucket.pts;
          for (let i = 0; i < pts.length; i++) {
            const p: Particle = pts[i];
            if (!p.glow) {
              continue;
            }
            const k: number = (now - p.delay) / p.dur;
            if (k <= 0) {
              continue;
            }
            const t: number = k >= 1 ? 1 : 1 - Math.pow(1 - k, 3);
            const x: number = p.sx + (p.tx - p.sx) * t;
            const y: number = p.sy + (p.ty - p.sy) * t;
            const pulse: number = 0.6 + 0.4 * Math.sin(now / 280 + p.seed);
            const r: number = 4 + 2.8 * pulse;
            c.beginPath();
            c.arc(x, y, r, 0, Math.PI * 2);
            c.fill();
          }
        }
        c.globalAlpha = 1;
      }
    }
    // 粒子核心层
    for (let b = 0; b < this.buckets.length; b++) {
      const bucket: ParticleBucket = this.buckets[b];
      c.fillStyle = bucket.color;
      const pts: Particle[] = bucket.pts;
      for (let i = 0; i < pts.length; i++) {
        const p: Particle = pts[i];
        const k: number = (now - p.delay) / p.dur;
        if (k <= 0) {
          continue;
        }
        const t: number = k >= 1 ? 1 : 1 - Math.pow(1 - k, 3);
        const x: number = p.sx + (p.tx - p.sx) * t;
        const y: number = p.sy + (p.ty - p.sy) * t;
        c.fillRect(x - 1.2, y - 1.2, 2.4, 2.4);
      }
    }
  }

  private goIndex(): void {
    router.replaceUrl({ url: 'pages/Index' }).catch(() => {
      setTimeout(() => {
        router.replaceUrl({ url: 'pages/Index' }).catch(() => {
          // 再次失败则停留在当前页
        });
      }, 800);
    });
  }

  private col(key: string): string {
    void this.resolvedTheme;
    return AppTheme.color(key, this.resolvedTheme);
  }

  private slogan1(): string {
    if (this.appLang === 'en') {
      return 'Teaching, this simple.';
    }
    return '教学如此简单，';
  }

  private slogan2(): string {
    if (this.appLang === 'en') {
      return "if only you'd known sooner.";
    }
    return '可惜你才知道';
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 文字与图案占位层：整体上移编排；文字在图案成形后淡入
      Column() {
        Column()
          .layoutWeight(0.55)
          .width('100%')
        Text('Rev TechingMaster')
          .fontSize(this.subSize + 3)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.col('hint'))
          .letterSpacing(2)
        Column({ space: 8 }) {
          Text(this.slogan1())
            .fontSize(this.mainSize)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.col('title'))
            .letterSpacing(1)
          Text(this.slogan2())
            .fontSize(this.mainSize)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.col('title'))
            .letterSpacing(1)
            .margin({ left: '13%' })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
        .padding({ top: 14 })
        // 文字与图案之间留白（拉开距离）
        Column()
          .layoutWeight(0.4)
          .width('100%')
        // 图案占位容器：仅用于在布局流中占据位置并捕获中心坐标
        Column()
          .width(this.gW)
          .height(this.gH)
          .onAreaChange((oldValue: Area, newValue: Area) => {
            const pos = newValue.globalPosition as Position;
            const px: number = Number(pos.x === undefined ? this.gcx : pos.x);
            const py: number = Number(pos.y === undefined ? this.gcy : pos.y);
            this.gcx = px + this.gW / 2;
            this.gcy = py + this.gH / 2;
          })
        Column()
          .layoutWeight(0.9)
          .width('100%')
        Text('v1.0.0 · AGPL-3.0')
          .fontSize(11)
          .fontColor(this.col('faint'))
          .padding({ bottom: 26 })
      }
      .width('100%')
      .height('100%')
      .opacity(this.textShown ? 1 : 0)
      .animation({ duration: 650, curve: Curve.EaseOut })

      // 粒子画布（全屏透明层）
      Canvas(this.ctx)
        .width(this.vpW)
        .height(this.vpH)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.col('bg'))
  }
}
