/**
 * 分布式软总线·跨设备结果流转
 *
 * 源端（手机）：在 ResultPanel 点击「流转」→ 当前生成结果（富文本 HTML）暂存到共享区，
 *   经 continuationManager 拉起系统设备选择器；用户选中平板/2in1 后，框架自动回调
 *   EntryAbility.onContinue，这里把暂存内容的富文本与元数据写入 Want，返回 AGREE 完成流转。
 * 目标端（平板/2in1）：EntryAbility.onCreate/onNewWant 收到带流转载荷的 Want，写入 AppStorage
 *   收件箱；Splash 启动时检测到收件箱 → 打开「流转接收」页继续编辑/导出。
 *
 * 跨平台（ArkUI-X）：分布式软总线为鸿蒙专有能力，安卓/iOS 无对应实现。
 *   这里用 //#if OHOS 把 continuationManager 的引用在安卓侧编译期移除，并通过
 *   supported() 让各端判断是否展示「流转」入口（安卓/其它平台自动隐藏，仅保留其它功能）。
 */
//#if OHOS
import continuationManager from '@ohos.continuation.continuationManager';
//#endif
import promptAction from '@ohos.promptAction';
import { Want, AbilityConstant } from '@kit.AbilityKit';
import { I18n } from './I18n';

/** 跨设备流转的载荷结构 */
export interface ContinuePayload {
  /** 生成结果的富文本 HTML */
  html: string;
  /** 标题（用于导出文件名/保存历史） */
  title: string;
  /** 功能类型（保存历史用） */
  type: string;
  /** 导出模式：'word' | 'json' | 'pptx' */
  exportMode: string;
  /** 课件幻灯片预览（课件页流转时保持逐页渲染） */
  slideMode: boolean;
}

export class ContinuationService {
  /** AppStorage 收件箱键：待消费的流转载荷（JSON 字符串） */
  static readonly AR_INBOX: string = 'continueInbox';
  /** AppStorage 消费标记键：接收页消费后置 true，避免反复弹接收页 */
  static readonly AR_CONSUMED: string = 'continueConsumed';
  /** Want 参数键 */
  static readonly KEY_HTML: string = 'continueHtml';
  static readonly KEY_TITLE: string = 'continueTitle';
  static readonly KEY_TYPE: string = 'continueType';
  static readonly KEY_EXPORT: string = 'continueExport';
  static readonly KEY_SLIDE: string = 'continueSlide';

  /** 源端：点按「流转」前把当前结果暂存到共享区，供 onContinue 打包瞬间读取 */
  static stash(html: string, title: string, type: string, exportMode: string, slideMode: boolean): void {
    const p: ContinuePayload = {
      html: html, title: title, type: type, exportMode: exportMode, slideMode: slideMode
    };
    AppStorage.setOrCreate(ContinuationService.AR_INBOX, JSON.stringify(p));
  }

  /** 是否支持分布式软总线流转（仅鸿蒙为 true；安卓/其它平台编译期剔除后为 false） */
  static supported(): boolean {
    let ok: boolean = false;
    //#if OHOS
    ok = true;
    //#endif
    return ok;
  }

  /** 源端：注册流转服务并拉起系统设备选择器（用户选择目标设备后框架自动回调 onContinue） */
  static async startContinuation(): Promise<void> {
    //#if OHOS
    try {
      const token: number = await continuationManager.registerContinuation();
      // 设备被选中后由系统回调 onContinue 完成数据打包，这里仅订阅保持连接态即可
      continuationManager.on('deviceSelected', token, () => {
        // 无需额外操作
      });
      await continuationManager.startContinuationDeviceManager(token);
    } catch (e) {
      promptAction.showToast({ message: I18n.t('err.continuationFail') });
    }
    //#endif
  }

  /** 源端：把共享区内容写入 Want 并返回流转结果（由 EntryAbility.onContinue 调用） */
  static buildWant(wantParam: Record<string, Object>): AbilityConstant.OnContinueResult {
    const raw: string | undefined = AppStorage.get<string>(ContinuationService.AR_INBOX);
    if (raw === undefined || raw.trim() === '') {
      return AbilityConstant.OnContinueResult.REJECT;
    }
    let p: ContinuePayload;
    try {
      p = JSON.parse(raw) as ContinuePayload;
    } catch (e) {
      return AbilityConstant.OnContinueResult.REJECT;
    }
    if (p.html === undefined || p.html === '') {
      return AbilityConstant.OnContinueResult.REJECT;
    }
    wantParam[ContinuationService.KEY_HTML] = p.html;
    wantParam[ContinuationService.KEY_TITLE] = p.title;
    wantParam[ContinuationService.KEY_TYPE] = p.type;
    wantParam[ContinuationService.KEY_EXPORT] = p.exportMode;
    wantParam[ContinuationService.KEY_SLIDE] = p.slideMode;
    return AbilityConstant.OnContinueResult.AGREE;
  }

  /** 目标端：从 Want 提取流转载荷并写入收件箱（由 onCreate/onNewWant 调用） */
  static inboxFromWant(want: Want): void {
    if (want === undefined || want.parameters === undefined) {
      return;
    }
    const params: Record<string, Object> = want.parameters as Record<string, Object>;
    const html: Object | undefined = params[ContinuationService.KEY_HTML];
    if (typeof html !== 'string' || html === '') {
      return;
    }
    const titleObj: Object | undefined = params[ContinuationService.KEY_TITLE];
    const typeObj: Object | undefined = params[ContinuationService.KEY_TYPE];
    const expObj: Object | undefined = params[ContinuationService.KEY_EXPORT];
    const p: ContinuePayload = {
      html: html as string,
      title: typeof titleObj === 'string' ? titleObj as string : '',
      type: typeof typeObj === 'string' ? typeObj as string : '',
      exportMode: typeof expObj === 'string' ? expObj as string : 'word',
      slideMode: params[ContinuationService.KEY_SLIDE] === true
    };
    AppStorage.setOrCreate(ContinuationService.AR_INBOX, JSON.stringify(p));
    AppStorage.setOrCreate(ContinuationService.AR_CONSUMED, false);
  }

  /** 是否存在待消费的流转载荷 */
  static hasInbox(): boolean {
    const raw: string | undefined = AppStorage.get<string>(ContinuationService.AR_INBOX);
    if (raw === undefined || raw.trim() === '') {
      AppStorage.setOrCreate(ContinuationService.AR_CONSUMED, true);
      return false;
    }
    if (AppStorage.get<boolean>(ContinuationService.AR_CONSUMED) === true) {
      return false;
    }
    return true;
  }

  /** 消费收件箱：读取并清除（接收页加载后调用），返回 null 表示无内容 */
  static takeInbox(): ContinuePayload | null {
    const raw: string | undefined = AppStorage.get<string>(ContinuationService.AR_INBOX);
    if (raw === undefined || raw.trim() === '') {
      return null;
    }
    try {
      const p: ContinuePayload = JSON.parse(raw) as ContinuePayload;
      AppStorage.setOrCreate(ContinuationService.AR_INBOX, '');
      AppStorage.setOrCreate(ContinuationService.AR_CONSUMED, true);
      return p;
    } catch (e) {
      return null;
    }
  }
}