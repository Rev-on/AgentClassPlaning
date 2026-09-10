/**
 * 语音识别（HarmonyOS 实现）
 * 使用 @kit.CoreSpeechKit 的 speechRecognizer 短语音模式，实现"按住说话"的语音转文字：
 *  - 引擎自行录音（recognitionMode: 0），无需自己采集 PCM 音频流
 *  - onResult 持续回调实时中间结果，onComplete 回调一句话的最终结果
 *  - finish(sessionId) 松手结束并取回最终结果；cancel(sessionId) 上滑取消并丢弃结果
 * Android 侧为同名文件（ArkUI-X 无 CoreSpeechKit，available() 返回 false），公开 API 完全一致。
 */
import { speechRecognizer } from '@kit.CoreSpeechKit';
import { abilityAccessCtrl, bundleManager, common, Permissions } from '@kit.AbilityKit';

/** 创建引擎的参数（extraParams 需要 Record 形状） */
interface CreateExtraParams extends Record<string, Object> {
  locate: string;
  recognizerMode: string;
}

/** 启动识别的参数（extraParams 需要 Record 形状） */
interface StartExtraParams extends Record<string, Object> {
  recognitionMode: number;
  vadBegin: number;
  vadEnd: number;
  maxAudioDuration: number;
}

/** 实时中间结果回调 */
export type VoiceTextCallback = (text: string) => void;
/** 出错回调（参数为提示文案 key，由界面层翻译） */
export type VoiceErrorCallback = (messageKey: string) => void;

export class VoiceInput {
  private static seq: number = 0;
  /** 本应用 accessTokenId 缓存，避免每次录音前重复查询（省一次 IPC 往返） */
  private static tokenId: number = -1;

  /** 当前平台是否支持语音识别 */
  static available(): boolean {
    return true;
  }

  /** 申请麦克风权限（已授权则直接返回 true） */
  static async ensurePermission(ctx: common.Context): Promise<boolean> {
    const perms: Array<Permissions> = ['ohos.permission.MICROPHONE'];
    const at: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
    try {
      if (VoiceInput.tokenId <= 0) {
        const info = await bundleManager.getBundleInfoForSelf(
          bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
        VoiceInput.tokenId = info.appInfo.accessTokenId;
      }
      const status: abilityAccessCtrl.GrantStatus =
        await at.checkAccessToken(VoiceInput.tokenId, perms[0]);
      if (status === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
        return true;
      }
    } catch (e) {
      // 查询失败时继续走申请流程
    }
    try {
      const res = await at.requestPermissionsFromUser(ctx, perms);
      const codes: Array<number> = res.authResults;
      return codes.length > 0 && codes[0] === 0;
    } catch (e) {
      return false;
    }
  }

  private engine: speechRecognizer.SpeechRecognitionEngine | undefined = undefined;
  private sessionId: string = '';
  private latest: string = '';
  private onPreview: VoiceTextCallback = (text: string): void => { void text; };
  private onFinal: VoiceTextCallback = (text: string): void => { void text; };
  private onError: VoiceErrorCallback = (key: string): void => { void key; };

  /** 创建（或复用）识别引擎；返回 false 表示引擎不可用 */
  async ready(): Promise<boolean> {
    if (this.engine !== undefined) {
      return true;
    }
    let eng: speechRecognizer.SpeechRecognitionEngine | undefined = undefined;
    try {
      const createParams: speechRecognizer.CreateEngineParams = {
        language: 'zh-CN',
        online: 1,
        extraParams: { locate: 'CN', recognizerMode: 'short' } as CreateExtraParams
      };
      eng = await speechRecognizer.createEngine(createParams);
    } catch (e) {
      this.engine = undefined;
      return false;
    }
    if (eng === undefined) {
      return false;
    }
    this.engine = eng;
    eng.setListener({
      onStart: (sessionId: string, eventMessage: string): void => {
        void sessionId;
        void eventMessage;
      },
      onEvent: (sessionId: string, eventCode: number, eventMessage: string): void => {
        void sessionId;
        void eventCode;
        void eventMessage;
      },
      onResult: (sessionId: string, result: speechRecognizer.SpeechRecognitionResult): void => {
        if (sessionId !== this.sessionId) {
          return;
        }
        const text: string = result.result.trim();
        if (text.length === 0) {
          return;
        }
        this.latest = text;
        this.onPreview(text);
      },
      onComplete: (sessionId: string, eventMessage: string): void => {
        void eventMessage;
        if (sessionId !== this.sessionId) {
          return;
        }
        const text: string = this.latest.trim();
        this.sessionId = '';
        this.latest = '';
        this.onFinal(text);
      },
      onError: (sessionId: string, errorCode: number, errorMessage: string): void => {
        void errorMessage;
        if (sessionId !== this.sessionId) {
          return;
        }
        this.sessionId = '';
        this.latest = '';
        this.onError(VoiceInput.errorKey(errorCode));
      }
    });
    return true;
  }

  /** 开始录音识别；返回 false 表示启动失败 */
  async start(preview: VoiceTextCallback, final: VoiceTextCallback, error: VoiceErrorCallback): Promise<boolean> {
    this.onPreview = preview;
    this.onFinal = final;
    this.onError = error;
    const ok: boolean = await this.ready();
    const eng: speechRecognizer.SpeechRecognitionEngine | undefined = this.engine;
    if (!ok || eng === undefined) {
      error('voice.init');
      return false;
    }
    try {
      if (eng.isBusy()) {
        error('voice.busy');
        return false;
      }
    } catch (e) {
      error('voice.init');
      return false;
    }
    this.latest = '';
    this.sessionId = VoiceInput.nextId();
    const startParams: speechRecognizer.StartParams = {
      sessionId: this.sessionId,
      audioInfo: {
        audioType: 'pcm',
        sampleRate: 16000,
        soundChannel: 1,
        sampleBit: 16
      },
      extraParams: {
        recognitionMode: 0,
        vadBegin: 2000,
        vadEnd: 2500,
        maxAudioDuration: 60000
      } as StartExtraParams
    };
    try {
      eng.startListening(startParams);
      return true;
    } catch (e) {
      this.sessionId = '';
      error('voice.fail');
      return false;
    }
  }

  /** 松手：结束录音，最终结果通过 onFinal 回调返回 */
  stop(): void {
    const eng: speechRecognizer.SpeechRecognitionEngine | undefined = this.engine;
    if (eng === undefined || this.sessionId === '') {
      return;
    }
    try {
      eng.finish(this.sessionId);
    } catch (e) {
      const cb: VoiceErrorCallback = this.onError;
      this.sessionId = '';
      this.latest = '';
      cb('voice.fail');
    }
  }

  /** 上滑取消：丢弃本次识别结果 */
  abort(): void {
    const eng: speechRecognizer.SpeechRecognitionEngine | undefined = this.engine;
    const sid: string = this.sessionId;
    this.sessionId = '';
    this.latest = '';
    if (eng === undefined || sid === '') {
      return;
    }
    try {
      eng.cancel(sid);
    } catch (e) {
      // 取消失败无需处理
    }
  }

  /** 释放引擎（组件销毁时调用） */
  release(): void {
    const eng: speechRecognizer.SpeechRecognitionEngine | undefined = this.engine;
    this.engine = undefined;
    if (eng === undefined) {
      return;
    }
    if (this.sessionId !== '') {
      try {
        eng.cancel(this.sessionId);
      } catch (e) {
        // 取消失败无需处理
      }
      this.sessionId = '';
    }
    this.latest = '';
    try {
      eng.shutdown();
    } catch (e) {
      // 释放失败无需处理
    }
  }

  private static errorKey(code: number): string {
    if (code === 1002200006) {
      return 'voice.busy';
    }
    if (code === 1002200001 || code === 1002200007 || code === 1002200008) {
      return 'voice.init';
    }
    return 'voice.fail';
  }

  private static nextId(): string {
    VoiceInput.seq = VoiceInput.seq + 1;
    return 'v' + Date.now().toString() + '_' + VoiceInput.seq.toString();
  }
}
