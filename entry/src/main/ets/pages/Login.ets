/**
 * 登录 / 注册页（首次使用门控）
 *  - 登录：用户名 + 密码（圆点隐藏，不提供明文切换）
 *  - 注册：用户名 + 密码 + 确认密码，注册成功自动登录
 *  - 华为账号登录：WebView 拉起 Account Kit OAuth 授权，授权码交服务端换取会话
 */
import { router } from '@kit.ArkUI';
import { promptAction } from '@kit.ArkUI';
import webview from '@ohos.web.webview';
import common from '@ohos.app.ability.common';
import { AppTheme } from '../common/AppTheme';
import { AccountApi, SessionResult } from '../common/AccountApi';
import { AccountStore } from '../common/AccountStore';
import { AccountText } from '../common/AccountText';
import { ApiConfig } from '../common/ApiConfig';

@Entry
@Component
struct Login {
  @StorageProp('appLang') appLang: string = 'zh';
  @StorageProp('appResolvedTheme') resolvedTheme: string = 'light';
  /** 当前模式：login | register */
  @State mode: string = 'login';
  @State username: string = '';
  @State password: string = '';
  @State password2: string = '';
  @State busy: boolean = false;
  @State webShow: boolean = false;
  /** 授权页地址（作为 Web 初始 src 直接加载，避免空页） */
  @State webSrc: string = 'about:blank';
  private webController: webview.WebviewController = new webview.WebviewController();

  private t(key: string): string {
    void this.appLang;
    return AccountText.t(key);
  }

  private col(key: string): string {
    void this.resolvedTheme;
    return AppTheme.color(key, this.resolvedTheme);
  }

  private switchMode(m: string): void {
    if (this.busy) {
      return;
    }
    this.mode = m;
    this.password = '';
    this.password2 = '';
  }

  /** 提交登录或注册 */
  private submit(): void {
    const u: string = this.username.trim();
    const p: string = this.password;
    if (u === '') {
      this.toast(this.t('err.user'));
      return;
    }
    if (p === '') {
      this.toast(this.t('err.pwd'));
      return;
    }
    if (this.mode === 'register') {
      if (this.password2 === '') {
        this.toast(this.t('err.pwd2'));
        return;
      }
      if (p !== this.password2) {
        this.toast(this.t('err.mismatch'));
        return;
      }
    }
    this.busy = true;
    const ctx = getContext(this) as common.UIAbilityContext;
    const task: Promise<SessionResult> =
      this.mode === 'register' ? AccountApi.register(u, p) : AccountApi.login(u, p);
    task.then((s: SessionResult) => {
      return AccountStore.save(ctx, s.token, s.user.username, s.user.kind, s.user.nickname, s.user.avatar).then(() => {
        this.busy = false;
        this.toast(this.mode === 'register' ? this.t('toast.regOk') : this.t('toast.loginOk'));
        router.replaceUrl({ url: 'pages/Index' }).catch(() => {
          // 跳转失败保持本页
        });
      });
    }).catch((e: Error) => {
      this.busy = false;
      this.toast(e.message);
    });
  }

  /** 拉起华为账号授权页（授权码模式，服务端换 token） */
  private startHuaweiLogin(): void {
    if (this.busy) {
      return;
    }
    this.busy = true;
    // 用本页承载授权流程：成功或失败都会退出；失败回退为普通登录
    const redirect: string = encodeURIComponent(this.huaweiRedirect());
    const authUrl: string = 'https://oauth-login.cloud.huawei.com/oauth2/v3/authorize' +
      '?client_id=' + this.huaweiAppId() +
      '&response_type=code' +
      '&redirect_uri=' + redirect +
      '&scope=openid' +
      '&state=rtm_login';
    try {
      this.webSrc = authUrl;
      this.webShow = true;
    } catch (e) {
      this.busy = false;
      this.toast('华为授权页打开失败，请改用账号密码登录');
    }
  }

  private huaweiAppId(): string {
    return ApiConfig.HUAWEI_CLIENT_ID;
  }

  private huaweiRedirect(): string {
    return ApiConfig.HUAWEI_REDIRECT;
  }

  /** 解析华为授权回调（code / error），code 交给服务端换会话 */
  private handleAuthRedirect(url: string): boolean {
    const base: string = ApiConfig.HUAWEI_REDIRECT;
    if (url.indexOf(base) !== 0) {
      return false;
    }
    const errIdx: number = url.indexOf('error=');
    if (errIdx >= 0) {
      let seg: string = url.substring(errIdx + 6);
      const amp: number = seg.indexOf('&');
      if (amp >= 0) {
        seg = seg.substring(0, amp);
      }
      this.webShow = false;
      this.busy = false;
      this.toast(decodeURIComponent(seg));
      return true;
    }
    const codeIdx: number = url.indexOf('code=');
    if (codeIdx >= 0) {
      let seg: string = url.substring(codeIdx + 5);
      const amp: number = seg.indexOf('&');
      if (amp >= 0) {
        seg = seg.substring(0, amp);
      }
      const code: string = decodeURIComponent(seg);
      this.webShow = false;
      this.exchangeHuaweiCode(code);
      return true;
    }
    return false;
  }

  /** 用授权码向服务端换取会话并进入主界面 */
  private exchangeHuaweiCode(code: string): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    AccountApi.huaweiLogin(code, this.huaweiRedirect()).then((s: SessionResult) => {
      return AccountStore.save(ctx, s.token, s.user.username, s.user.kind, s.user.nickname, s.user.avatar).then(() => {
        this.busy = false;
        this.toast(this.t('toast.loginOk'));
        router.replaceUrl({ url: 'pages/Index' }).catch(() => {
          // 跳转失败保持本页
        });
      });
    }).catch((e: Error) => {
      this.busy = false;
      this.toast(e.message);
    });
  }

  /** 跳过登录：游客模式直接进入主界面（不写入任何会话） */
  private skipLogin(): void {
    if (this.busy) {
      return;
    }
    router.replaceUrl({ url: 'pages/Index' }).catch(() => {
      setTimeout(() => {
        router.replaceUrl({ url: 'pages/Index' }).catch(() => {
          // 再次失败则停留本页
        });
      }, 800);
    });
  }

  private toast(msg: string): void {
    promptAction.showToast({ message: msg, duration: 2200 });
  }

  private inputBg(): string {
    return this.col('inputBg');
  }

  private lineColor(): string {
    return this.col('line');
  }

  private cardBg(): string {
    return this.col('card');
  }

  build() {
    Stack() {
      Column() {
        Column()
          .layoutWeight(1.2)
          .width('100%')
        Column({ space: 0 }) {
          // 品牌
          Row({ space: 10 }) {
            Text('R')
              .fontSize(30)
              .fontWeight(FontWeight.Bold)
              .fontColor(Color.White)
              .width(52)
              .height(52)
              .textAlign(TextAlign.Center)
              .borderRadius(14)
              .backgroundColor('#3B82C4')
            Column({ space: 3 }) {
              Text('Rev TechingMaster')
                .fontSize(22)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.col('title'))
              Text(this.t('login.subtitle'))
                .fontSize(12)
                .fontColor(this.col('sub'))
            }
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')
          .margin({ bottom: 26 })

          Text(this.mode === 'login' ? this.t('login.mode') : this.t('register.sub'))
            .fontSize(26)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.col('title'))
            .width('100%')
            .margin({ bottom: 18 })

          // 用户名
          TextInput({ text: this.username, placeholder: this.t('ph.user') })
            .type(InputType.Normal)
            .enabled(!this.busy)
            .fontColor(this.col('text'))
            .placeholderColor(this.col('hint'))
            .backgroundColor(this.inputBg())
            .height(48)
            .borderRadius(10)
            .margin({ bottom: 12 })
            .onChange((v: string) => {
              this.username = v;
            })
          // 密码
          TextInput({ text: this.password, placeholder: this.t('ph.pwd') })
            .type(InputType.Password)
            .showPasswordIcon(false)
            .enabled(!this.busy)
            .fontColor(this.col('text'))
            .placeholderColor(this.col('hint'))
            .backgroundColor(this.inputBg())
            .height(48)
            .borderRadius(10)
            .margin({ bottom: 12 })
            .onChange((v: string) => {
              this.password = v;
            })
          // 注册模式：确认密码
          if (this.mode === 'register') {
            TextInput({ text: this.password2, placeholder: this.t('ph.pwd2') })
              .type(InputType.Password)
              .showPasswordIcon(false)
              .enabled(!this.busy)
              .fontColor(this.col('text'))
              .placeholderColor(this.col('hint'))
              .backgroundColor(this.inputBg())
              .height(48)
              .borderRadius(10)
              .margin({ bottom: 12 })
              .onChange((v: string) => {
                this.password2 = v;
              })
          }

          Button(this.mode === 'login' ? this.t('btn.submitLogin') : this.t('btn.submitRegister'))
            .type(ButtonType.Normal)
            .width('100%')
            .height(50)
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor(Color.White)
            .backgroundColor(this.busy ? '#8FB6D8' : '#3B82C4')
            .borderRadius(10)
            .enabled(!this.busy)
            .margin({ top: 6, bottom: 10 })
            .onClick(() => {
              this.submit();
            })

          // 切换登录 / 注册
          Row() {
            Text(this.mode === 'login' ? this.t('tip.toRegister') : this.t('tip.toLogin'))
              .fontSize(13)
              .fontColor(this.col('sub'))
            Text(this.mode === 'login' ? this.t('register.mode') : this.t('login.mode'))
              .fontSize(13)
              .fontWeight(FontWeight.Bold)
              .fontColor('#3B82C4')
              .margin({ left: 4 })
              .onClick(() => {
                this.switchMode(this.mode === 'login' ? 'register' : 'login');
              })
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)
          .margin({ bottom: 22 })

          // 分隔线
          Row() {
            Divider()
              .vertical(false)
              .strokeWidth(1)
              .color(this.lineColor())
              .width('38%')
            Text('OR')
              .fontSize(11)
              .fontColor(this.col('hint'))
              .margin({ left: 12, right: 12 })
            Divider()
              .vertical(false)
              .strokeWidth(1)
              .color(this.lineColor())
              .width('38%')
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)
          .margin({ bottom: 18 })

          // 华为账号登录
          Button() {
            Row({ space: 10 }) {
              Image($r('app.media.huaweicloud'))
                .width(24)
                .height(24)
                .objectFit(ImageFit.Contain)
              Text(this.t('huawei.btn'))
                .fontSize(15)
                .fontColor(Color.White)
                .fontWeight(FontWeight.Medium)
            }
          }
          .type(ButtonType.Normal)
          .width('100%')
          .height(50)
          .backgroundColor('#C7000B')
          .borderRadius(10)
          .enabled(!this.busy)
          .onClick(() => {
            this.startHuaweiLogin();
          })

          Text(this.t('huawei.hint'))
            .fontSize(11)
            .fontColor(this.col('hint'))
            .margin({ top: 8 })
            .textAlign(TextAlign.Center)
            .width('100%')

          Text('（AI生成，仅供参考）')
            .fontSize(10)
            .fontColor(this.col('faint'))
            .margin({ top: 14 })

          // 跳过登录：游客模式直接进入主界面
          Text(this.t('btn.skip'))
            .fontSize(13)
            .fontColor(this.col('sub'))
            .margin({ top: 12 })
            .onClick(() => {
              this.skipLogin();
            })
        }
        .width('88%')
        .padding(24)
        .borderRadius(20)
        .backgroundColor(this.cardBg())

        Column()
          .layoutWeight(1)
          .width('100%')
      }
      .width('100%')
      .height('100%')
      .padding({ top: 40 })

      // 华为授权 WebView 层
      if (this.webShow) {
        Column() {
          Row() {
            Text('华为账号登录')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.col('title'))
            Blank()
            Button('关闭')
              .fontSize(13)
              .backgroundColor(Color.Transparent)
              .fontColor(this.col('sub'))
              .onClick(() => {
                this.webShow = false;
                this.busy = false;
              })
          }
          .width('100%')
          .height(52)
          .padding({ left: 16, right: 8 })
          .backgroundColor(this.col('headBg'))
          Web({ src: this.webSrc, controller: this.webController })
            .javaScriptAccess(true)
            .domStorageAccess(true)
            .onUrlLoadIntercept((event) => {
              if (event === undefined || event.data === undefined) {
                return false;
              }
              if (typeof event.data === 'string') {
                return this.handleAuthRedirect(event.data);
              }
              return false;
            })
            .width('100%')
            .layoutWeight(1)
        }
        .width('100%')
        .height('100%')
        .backgroundColor(this.col('bg'))
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.col('bg'))
  }
}
