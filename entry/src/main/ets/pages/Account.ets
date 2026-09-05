/**
 * 账户页：头像（可设置）、昵称、退出登录
 *  - 已登录（含华为账号）：显示真实头像/昵称，可修改并同步云端，可退出
 *  - 未登录（游客，经登录页“跳过登录”进入）：昵称显示“未登录”，头像为默认头像，
 *    提供“去登录”入口；头像/昵称编辑与退出仅登录态可见
 */
import { router } from '@kit.ArkUI';
import { promptAction } from '@kit.ArkUI';
import common from '@ohos.app.ability.common';
import { picker, fileIo as fs } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { AppTheme } from '../common/AppTheme';
import { AppFonts } from '../common/AppFonts';
import { AccountStore } from '../common/AccountStore';
import { AccountApi } from '../common/AccountApi';
import { AccountText } from '../common/AccountText';
import { PageHeader } from '../common/components/PageHeader';
import { VerticalMongolianText } from '../common/components/VerticalMongolianText';
import { DefaultAvatar } from '../common/components/DefaultAvatar';

@Entry
@Component
struct Account {
  @StorageProp('appLang') appLang: string = 'zh';
  @StorageProp('appResolvedTheme') resolvedTheme: string = 'light';
  /** 是否已登录（false = 游客） */
  @State signed: boolean = false;
  /** 登录用户名与方式 */
  @State username: string = '';
  @State kind: string = 'account';
  /** 已保存昵称 */
  @State nickname: string = '';
  /** 昵称输入草稿 */
  @State draft: string = '';
  /** 头像：http(s) 华为头像地址 或 本机文件路径 或 空 */
  @State avatarPath: string = '';
  /** 本机头像解码结果（本地文件直接以 PixelMap 显示） */
  @State avatarPm: image.PixelMap | undefined = undefined;
  /** 远程头像加载失败标记（回退首字母头像） */
  @State avatarFail: boolean = false;
  @State busy: boolean = false;

  aboutToAppear(): void {
    this.ensureFonts();
    this.reload();
  }

  /** 注册内置少数民族字体（进程内仅一次；失败回退系统字体） */
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
      // 注册失败不阻塞
    }
    AppStorage.setOrCreate('revFontsReg', true);
  }

  private t(key: string): string {
    void this.appLang;
    return AccountText.t(key);
  }

  private col(key: string): string {
    void this.resolvedTheme;
    return AppTheme.color(key, this.resolvedTheme);
  }

  /** 从本地会话加载页面状态（区分登录/游客） */
  private reload(): void {
    this.signed = AccountStore.signedIn();
    this.username = AccountStore.user();
    this.kind = AccountStore.kind();
    this.nickname = AccountStore.nickname();
    this.draft = this.nickname;
    this.avatarFail = false;
    this.avatarPm = undefined;
    const av: string = AccountStore.avatar();
    this.avatarPath = av;
    if (this.signed && av !== '' && av.indexOf('http://') !== 0 && av.indexOf('https://') !== 0) {
      this.loadLocalPm(av);
    }
  }

  /** 读取本机头像文件并解码为 PixelMap（失败则显示首字母头像） */
  private async loadLocalPm(p: string): Promise<void> {
    try {
      const f = fs.openSync(p, fs.OpenMode.READ_ONLY);
      const st = fs.statSync(f.fd);
      const buf: ArrayBuffer = new ArrayBuffer(st.size);
      fs.readSync(f.fd, buf);
      fs.closeSync(f);
      const src: image.ImageSource = image.createImageSource(buf);
      const pm: image.PixelMap = await src.createPixelMap();
      if (this.avatarPath === p) {
        this.avatarPm = pm;
      }
    } catch (e) {
      this.avatarPm = undefined;
    }
  }

  /** 当前展示昵称（游客显示“未登录”） */
  private displayNick(): string {
    if (!this.signed) {
      return this.t('acct.guest');
    }
    const n: string = this.nickname.trim();
    return n !== '' ? n : this.t('acct.guest');
  }

  /** 已登录且无头像时的首字母（无昵称则回退品牌字） */
  private letter(): string {
    const n: string = this.nickname.trim();
    if (n === '') {
      return 'R';
    }
    return n.charAt(0);
  }

  /** 是否存在需要以图片覆盖展示的远程（华为）头像 */
  private hasRemoteAvatar(): boolean {
    return this.signed && !this.avatarFail &&
      (this.avatarPath.indexOf('http://') === 0 || this.avatarPath.indexOf('https://') === 0);
  }

  /** 从相册选择图片并设为头像（仅登录态可用） */
  private async pickAvatar(): Promise<void> {
    if (!this.signed || this.busy) {
      return;
    }
    this.busy = true;
    try {
      const opt = new picker.PhotoSelectOptions();
      opt.MIMEType = picker.PhotoViewMIMETypes.IMAGE_TYPE;
      opt.maxSelectNumber = 1;
      const res = await new picker.PhotoViewPicker().select(opt);
      const uris: Array<string> = res.photoUris;
      if (uris === undefined || uris.length === 0) {
        this.busy = false;
        return;
      }
      const ctx = getContext(this) as common.UIAbilityContext;
      const srcUri: string = uris[0];
      // 解码并缩放为 256px JPEG，落盘到应用沙箱（不占用相册原图权限）
      const source: image.ImageSource = image.createImageSource(srcUri);
      const decOpt: image.DecodingOptions = { desiredSize: { width: 256, height: 256 } };
      const pm: image.PixelMap = await source.createPixelMap(decOpt);
      const packer: image.ImagePacker = image.createImagePacker();
      const packOpt: image.PackingOption = { format: 'image/jpeg', quality: 88 };
      const buf: ArrayBuffer = await packer.packing(pm, packOpt);
      const dest: string = ctx.filesDir + '/avatar_' + Date.now() + '.jpg';
      const f = fs.openSync(dest, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(f.fd, buf);
      fs.closeSync(f);
      // 本地立即生效并持久化
      const old: string = this.avatarPath;
      this.avatarPath = dest;
      this.avatarFail = false;
      this.avatarPm = pm;
      await AccountStore.saveProfile(ctx, this.nickname, dest);
      // 清理旧的本地头像文件（尽力而为）
      if (old !== '' && old.indexOf('http://') !== 0 && old.indexOf('https://') !== 0) {
        try {
          fs.unlinkSync(old);
        } catch (e) {
          // 忽略清理失败
        }
      }
      // 同步云端（失败不撤销本机已生效结果）
      this.busy = false;
      try {
        await AccountApi.updateProfile(AccountStore.token(), '', dest);
        this.toast(this.t('toast.avatarSaved'));
      } catch (e) {
        this.toast(this.t('toast.avatarLocal'));
      }
    } catch (e) {
      this.busy = false;
      this.toast(e instanceof Error ? e.message : this.t('acct.fromAlbum'));
    }
  }

  /** 保存昵称 */
  private saveNick(): void {
    if (!this.signed || this.busy) {
      return;
    }
    const nick: string = this.draft.trim();
    if (nick === '' || nick.length > 24) {
      this.toast(this.t('err.nick'));
      return;
    }
    if (nick === this.nickname) {
      this.toast(this.t('toast.nickSaved'));
      return;
    }
    this.busy = true;
    const ctx = getContext(this) as common.UIAbilityContext;
    AccountApi.updateProfile(AccountStore.token(), nick, '').then(() => {
      return AccountStore.saveProfile(ctx, nick, this.avatarPath).then(() => {
        this.nickname = nick;
        this.draft = nick;
        this.busy = false;
        this.toast(this.t('toast.nickSaved'));
      });
    }).catch((e: Error) => {
      this.busy = false;
      this.toast(e.message);
    });
  }

  /** 游客：前往登录页 */
  private toLogin(): void {
    router.replaceUrl({ url: 'pages/Login' }).catch(() => {
      // 跳转失败保持本页
    });
  }

  /** 退出登录：确认后清空会话回到登录页 */
  private logout(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    promptAction.showDialog({
      title: this.t('logout.confirm'),
      buttons: [
        { text: this.t('btn.cancel'), color: '#666666' },
        { text: this.t('btn.ok'), color: '#C0392B' }
      ]
    }).then((res: promptAction.ShowDialogSuccessResponse) => {
      if (res.index === 1) {
        AccountStore.clear(ctx).then(() => {
          this.toast(this.t('logout.ok'));
          router.replaceUrl({ url: 'pages/Login' }).catch(() => {
            // 跳转失败保持本页
          });
        });
      }
    }).catch(() => {
      // 用户取消对话框
    });
  }

  private toast(msg: string): void {
    promptAction.showToast({ message: msg, duration: 2200 });
  }

  private kindLabel(): string {
    return this.kind === 'huawei' ? this.t('acct.kind.huawei') : this.t('acct.kind.account');
  }

  build() {
    Column({ space: 12 }) {
      PageHeader({ title: this.t('acct.title') })

      Scroll() {
        Column({ space: 12 }) {
          if (this.signed) {
            // ============ 已登录视图 ============
            // 头像卡片
            Column({ space: 12 }) {
              Stack({ alignContent: Alignment.Center }) {
                // 底：首字母头像（无自定义头像时的兜底）
                Text(this.letter())
                  .fontFamily(AppFonts.family())
                  .fontSize(36)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(Color.White)
                  .width(96)
                  .height(96)
                  .textAlign(TextAlign.Center)
                  .backgroundColor('#3B82C4')
                  .borderRadius(48)
                // 面：远程（华为）头像
                if (this.hasRemoteAvatar()) {
                  Image(this.avatarPath)
                    .width(96)
                    .height(96)
                    .borderRadius(48)
                    .objectFit(ImageFit.Cover)
                    .onError(() => {
                      this.avatarFail = true;
                    })
                }
                // 面：本机头像（PixelMap）
                if (this.avatarPm !== undefined && !this.hasRemoteAvatar()) {
                  Image(this.avatarPm)
                    .width(96)
                    .height(96)
                    .borderRadius(48)
                    .objectFit(ImageFit.Cover)
                }
              }
              .width(96)
              .height(96)
              .onClick(() => {
                this.pickAvatar();
              })

              VerticalMongolianText({
                content: this.displayNick(),
                textSize: 18,
                textColor: this.col('title'),
                isBold: true,
                centerText: true
              })
              VerticalMongolianText({
                content: '@' + this.username,
                textSize: 12,
                textColor: this.col('hint'),
                centerText: true
              })
              Text(this.t('acct.changeAvatar'))
                .fontFamily(AppFonts.family())
                .fontSize(13)
                .fontColor('#4A90D9')
                .decoration({ type: TextDecorationType.Underline, color: '#4A90D9' })
                .onClick(() => {
                  this.pickAvatar();
                })
            }
            .width('100%')
            .padding(20)
            .backgroundColor(this.col('card'))
            .borderRadius(14)

            // 昵称编辑卡片
            Column({ space: 10 }) {
              VerticalMongolianText({
                content: this.t('acct.nickname'),
                textSize: 13,
                textColor: this.col('sub')
              })

              Row({ space: 10 }) {
                TextInput({ text: this.draft, placeholder: this.t('acct.enterNick') })
                  .type(InputType.Normal)
                  .enabled(!this.busy)
                  .fontColor(this.col('text'))
                  .placeholderColor(this.col('hint'))
                  .backgroundColor(this.col('inputBg'))
                  .layoutWeight(1)
                  .height(44)
                  .borderRadius(10)
                  .onChange((v: string) => {
                    this.draft = v;
                  })
                Button(this.t('acct.save'))
                  .fontFamily(AppFonts.family())
                  .fontSize(14)
                  .fontColor(Color.White)
                  .backgroundColor(this.busy ? '#8FB6D8' : '#4A90D9')
                  .borderRadius(10)
                  .width(76)
                  .height(44)
                  .enabled(!this.busy)
                  .onClick(() => {
                    this.saveNick();
                  })
              }
              .width('100%')
            }
            .width('100%')
            .padding(16)
            .backgroundColor(this.col('card'))
            .borderRadius(14)
            .alignItems(HorizontalAlign.Start)

            // 账号信息卡片
            Column({ space: 10 }) {
              Row() {
                Text(this.t('acct.username'))
                  .fontFamily(AppFonts.family())
                  .fontSize(13)
                  .fontColor(this.col('sub'))
                Blank()
                Text(this.username)
                  .fontFamily(AppFonts.family())
                  .fontSize(14)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.col('title'))
              }
              .width('100%')

              Divider().color(this.col('line'))

              Row() {
                Text(this.t('acct.kind'))
                  .fontFamily(AppFonts.family())
                  .fontSize(13)
                  .fontColor(this.col('sub'))
                Blank()
                Text(this.kindLabel())
                  .fontFamily(AppFonts.family())
                  .fontSize(13)
                  .fontWeight(FontWeight.Medium)
                  .fontColor('#4A90D9')
              }
              .width('100%')

              if (this.kind === 'huawei') {
                Divider().color(this.col('line'))
                VerticalMongolianText({
                  content: this.t('acct.huaweiNote'),
                  textSize: 12,
                  textColor: this.col('hint'),
                  fillWidth: true,
                  lineHeightNum: 18
                })
              }
            }
            .width('100%')
            .padding(16)
            .backgroundColor(this.col('card'))
            .borderRadius(14)
            .alignItems(HorizontalAlign.Start)

            // 退出登录
            Button(this.t('btn.logout'))
              .fontFamily(AppFonts.family())
              .fontSize(15)
              .fontColor(Color.White)
              .backgroundColor('#C0392B')
              .borderRadius(10)
              .height(46)
              .width('100%')
              .onClick(() => {
                this.logout();
              })
          } else {
            // ============ 未登录（游客）视图 ============
            Column({ space: 12 }) {
              // 游客头像与昵称：默认头像 + “未登录”
              DefaultAvatar({ side: 96 })
              VerticalMongolianText({
                content: this.displayNick(),
                textSize: 20,
                textColor: this.col('title'),
                isBold: true,
                centerText: true
              })
              VerticalMongolianText({
                content: this.t('acct.guestTip'),
                textSize: 12,
                textColor: this.col('hint'),
                fillWidth: true,
                centerText: true,
                lineHeightNum: 18
              })
            }
            .width('100%')
            .padding(24)
            .backgroundColor(this.col('card'))
            .borderRadius(14)

            // 去登录
            Button(this.t('btn.toLogin'))
              .fontFamily(AppFonts.family())
              .fontSize(15)
              .fontColor(Color.White)
              .backgroundColor('#4A90D9')
              .borderRadius(10)
              .height(46)
              .width('100%')
              .onClick(() => {
                this.toLogin();
              })
          }
        }
        .width('100%')
        .padding(16)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
    }
    .width('100%')
    .height('100%')
    .padding(12)
    .backgroundColor(this.col('bg'))
  }
}
