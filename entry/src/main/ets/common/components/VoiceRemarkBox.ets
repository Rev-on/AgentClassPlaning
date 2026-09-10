/**
 * 备注框（带语音输入，生成页共用）
 *  - 右侧麦克风图标：点击在"文字输入"与"按住说话"之间切换
 *  - 按住说话：按住开始识别，松手提交，上滑取消（超过 60vp 进入取消区）
 *  - 识别文字实时回显，松手后写入备注框，作为普通文字随请求一起发给模型
 * 语音能力来自 @kit.CoreSpeechKit 的 speechRecognizer（见 common/VoiceInput.ets）。
 */
import common from '@ohos.app.ability.common';
import promptAction from '@ohos.promptAction';
import { I18n } from '../../common/I18n';
import { AppTheme } from '../../common/AppTheme';
import { AppFonts } from '../../common/AppFonts';
import { VoiceInput } from '../../common/VoiceInput';

/** 上滑进入"取消"区的距离阈值（vp） */
const CANCEL_DY: number = 60;
/** 框内右侧为麦克风图标预留的宽度（vp） */
const ICON_SLOT: number = 44;

@Component
export struct VoiceRemarkBox {
  /** 备注文本（双向绑定到页面状态） */
  @Link text: string;
  /** 生成中锁定：置灰且不可交互 */
  @Prop disabled: boolean = false;
  /** 标题文案（页面已翻译） */
  @Prop labelText: string = '';
  /** 占位文案（页面已翻译） */
  @Prop placeholderText: string = '';
  @StorageProp('appLang') appLang: string = 'zh';
  @StorageProp('appResolvedTheme') resolvedTheme: string = 'light';

  /** 是否处于"按住说话"模式 */
  @State voiceMode: boolean = false;
  /** 正在识别（录音中） */
  @State listening: boolean = false;
  /** 已上滑进入取消区 */
  @State cancelZone: boolean = false;
  /** 识别中间结果（实时回显在备注框内） */
  @State preview: string = '';

  private engine: VoiceInput = new VoiceInput();
  /** 手指是否仍按在"按住说话"区域 */
  private pressing: boolean = false;
  /** 松手意图：0 未松手，1 发送，2 取消（用于启动耗时内已松手的补偿） */
  private releaseIntent: number = 0;
  private holdStart: number = 0;

  private t(key: string): string {
    void this.appLang;
    return I18n.t(key);
  }

  private col(key: string): string {
    void this.resolvedTheme;
    return AppTheme.color(key, this.resolvedTheme);
  }

  private toast(msg: string): void {
    promptAction.showToast({ message: msg });
  }

  aboutToDisappear(): void {
    this.engine.release();
    this.pressing = false;
    this.listening = false;
    this.releaseIntent = 0;
  }

  /** 点击麦克风图标：文字输入 <-> 按住说话；进入语音前先拿到麦克风权限 */
  private async toggleVoiceMode(): Promise<void> {
    if (this.disabled) {
      return;
    }
    if (this.voiceMode) {
      this.voiceMode = false;
      this.cancelZone = false;
      this.preview = '';
      return;
    }
    const ctx = getContext(this) as common.UIAbilityContext;
    const granted: boolean = await VoiceInput.ensurePermission(ctx);
    if (!granted) {
      this.toast(this.t('voice.denied'));
      return;
    }
    // 提前建引擎，按下时可直接开始录音
    void this.engine.ready();
    this.voiceMode = true;
    this.preview = '';
    this.cancelZone = false;
  }

  /** 手指按下 */
  private onPressDown(): void {
    if (this.disabled || this.pressing) {
      return;
    }
    this.pressing = true;
    this.releaseIntent = 0;
    this.cancelZone = false;
    this.holdStart = Date.now();
    void this.beginVoice();
  }

  /** 上滑距离跟踪（offsetY 为负表示向上） */
  private onSlide(offsetY: number): void {
    if (!this.pressing && !this.listening) {
      return;
    }
    const inZone: boolean = offsetY < -CANCEL_DY;
    if (inZone !== this.cancelZone) {
      this.cancelZone = inZone;
    }
  }

  /** 手指抬起/cancel：确认发送或取消 */
  private onPressUp(cancel: boolean): void {
    if (!this.pressing && !this.listening) {
      return;
    }
    this.pressing = false;
    this.cancelZone = false;
    if (!this.listening) {
      // 启动还在进行中，记下松手意图，等启动完成后立即收尾
      this.releaseIntent = cancel ? 2 : 1;
      return;
    }
    this.listening = false;
    this.preview = '';
    if (cancel) {
      this.engine.abort();
      this.toast(this.t('voice.canceled'));
    } else {
      this.engine.stop();
    }
  }

  /** 真正开始录音识别 */
  private async beginVoice(): Promise<void> {
    const ctx = getContext(this) as common.UIAbilityContext;
    const granted: boolean = await VoiceInput.ensurePermission(ctx);
    if (!this.pressing) {
      return;
    }
    if (!granted) {
      this.pressing = false;
      this.toast(this.t('voice.denied'));
      return;
    }
    this.preview = '';
    const started: boolean = await this.engine.start(
      (p: string): void => {
        this.preview = p;
      },
      (f: string): void => {
        this.onRecognized(f);
      },
      (k: string): void => {
        this.listening = false;
        this.resetPress();
        this.toast(this.t(k));
      });
    if (!started) {
      this.pressing = false;
      return;
    }
    if (!this.pressing) {
      // 启动耗时内用户已松手：按松手时的意图立即收尾
      const intent: number = this.releaseIntent;
      this.releaseIntent = 0;
      this.preview = '';
      this.listening = false;
      if (intent === 2) {
        this.engine.abort();
      } else {
        this.engine.stop();
      }
      return;
    }
    this.listening = true;
  }

  private resetPress(): void {
    this.pressing = false;
    this.releaseIntent = 0;
    this.cancelZone = false;
    this.preview = '';
  }

  /** 识别完成（松手结束或 VAD 自动结束） */
  private onRecognized(raw: string): void {
    this.listening = false;
    this.pressing = false;
    this.releaseIntent = 0;
    this.preview = '';
    const text: string = raw.trim();
    if (text.length === 0) {
      if (Date.now() - this.holdStart > 600) {
        this.toast(this.t('voice.empty'));
      }
      return;
    }
    const cur: string = this.text.trim();
    let next: string = text;
    if (cur.length > 0) {
      const last: string = cur.charAt(cur.length - 1);
      const punct: string = '。！？，、；：,.!?;:';
      next = cur + (punct.indexOf(last) >= 0 ? '' : '。') + text;
    }
    this.text = next;
    // 回到文字输入状态，让识别结果直接显示在备注框内
    this.voiceMode = false;
  }

  build() {
    Column({ space: 6 }) {
      Text(this.labelText)
        .fontFamily(AppFonts.family())
        .fontSize(12)
        .fontColor(this.col('hint'))
        .width('100%')

      // 备注框：麦克风图标固定在框内右侧，与输入区同一行（不占用标题行）
      Stack({ alignContent: Alignment.End }) {
        if (this.voiceMode && VoiceInput.available()) {
          // 按住说话条：按住录音，松手发送，上滑取消
          Column() {
            Text(this.voiceBarText())
              .fontFamily(AppFonts.family())
              .fontSize(13)
              .fontColor(this.voiceBarColor())
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .padding({ left: 14, right: ICON_SLOT })
          }
          .width('100%')
          .height(42)
          .borderRadius(21)
          .borderWidth(1)
          .borderColor(this.listening ? '#4A90D9' : this.col('line'))
          .backgroundColor(this.cancelZone ? '#D9534F' : (this.listening ? '#DCE9F8' : this.col('inputBg')))
          .justifyContent(FlexAlign.Center)
          .enabled(!this.disabled)
          .accessibilityText(this.t('voice.hold'))
          .onTouch((event: TouchEvent) => {
            const type: TouchType = event.type;
            if (type === TouchType.Down) {
              this.onPressDown();
            } else if (type === TouchType.Up) {
              this.onPressUp(this.cancelZone);
            } else if (type === TouchType.Cancel) {
              // 手势被上层接管时也会收到 Cancel：按当前是否处于取消区决定发送还是取消
              this.onPressUp(this.cancelZone);
            }
          })
          .gesture(
            PanGesture({ direction: PanDirection.All, distance: 1 })
              .onActionUpdate((event: GestureEvent) => {
                this.onSlide(event.offsetY);
              })
              .onActionEnd(() => {
                this.onPressUp(this.cancelZone);
              })
              .onActionCancel(() => {
                this.onPressUp(this.cancelZone);
              })
          )
        } else {
          TextInput({ text: this.text, placeholder: this.placeholderText })
            .fontFamily(AppFonts.family())
            .width('100%')
            .height(42)
            .fontSize(13)
            .padding({ right: VoiceInput.available() ? ICON_SLOT : 16 })
            .onChange((v: string) => {
              this.text = v;
            })
        }

        if (VoiceInput.available()) {
          Stack() {
            Image($r('app.media.ic_mic'))
              .width(18)
              .height(18)
              .fillColor(this.micColor())
          }
          .width(34)
          .height(34)
          .borderRadius(17)
          .backgroundColor(Color.Transparent)
          .margin({ right: 4 })
          .enabled(!this.disabled)
          .opacity(this.disabled ? 0.5 : 1)
          .accessibilityText(this.t('voice.mic'))
          .onClick(() => {
            void this.toggleVoiceMode();
          })
        }
      }
      .width('100%')
      .height(42)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 麦克风图标颜色：语音模式下高亮，取消区反白 */
  private micColor(): string {
    if (this.voiceMode) {
      return this.cancelZone ? '#FFFFFF' : '#4A90D9';
    }
    return this.col('sub');
  }

  /** 按住说话条内的文案：识别中优先回显识别文字 */
  private voiceBarText(): string {
    if (!this.listening) {
      return this.t('voice.hold');
    }
    if (this.cancelZone) {
      return this.t('voice.releaseCancel');
    }
    return this.preview.length > 0 ? this.preview : this.t('voice.release');
  }

  private voiceBarColor(): string {
    if (!this.listening) {
      return this.col('sub');
    }
    if (this.cancelZone) {
      return '#FFFFFF';
    }
    return '#1F4E79';
  }
}
