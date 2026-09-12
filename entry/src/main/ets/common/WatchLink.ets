/**
 * 手表端上课链路：跨设备"教案环节数据"的组网推送与接收。
 *
 * 手机端：检测到附近有手表在线（靠手表心跳在场），把解析好的环节列表写入分布式 KV 库，
 *   经分布式软总线自动同步到同一账号下的手表端同款应用。
 * 手表端：监听同一 KV 库的数据变更，收到 status=ready 的教学预案后展示"已接收教案 →
 *   开始上课"，并按环节分时计时；同时持续上报心跳，供手机端判断"有手表在场"。
 *
 * 跨平台（ArkUI-X）：分布式软总线为鸿蒙专有能力，安卓/iOS 用 //#if OHOS 编译期剔除；
 *   supported() 让各端判断是否展示手表入口，非鸿蒙平台自动隐藏。
 */
import common from '@ohos.app.ability.common';
import { LessonStage } from './LessonPlanParser';

//#if OHOS
import { distributedKVStore } from '@kit.ArkData';

/** SDK 的 KVManager/KVStore 具体类型未导出，用结构接驳（仅声明用到的成员）缓存 store 实例 */
interface WatchStore {
  put(key: string, value: string): Promise<void>;
  get(key: string, defaultValue: string): Promise<boolean | string | number | Uint8Array>;
  on(event: string, type: distributedKVStore.SubscribeType, listener: (data: object) => void): void;
  sync(deviceIds: string[], mode: distributedKVStore.SyncMode): void;
}

/** 接驳 createKVManager 的返回（SDK 隐藏了具体类型），恢复 getKVStore 的类型链路 */
interface WatchManager {
  getKVStore(storeId: string, options: distributedKVStore.Options): Promise<WatchStore>;
}
//#endif

/** 手表端收到的整份教案上课预案 */
export interface WatchLessonBundle {
  /** 'ready' 表示手机已推送教案，可开始上课 */
  status: string;
  stages: LessonStage[];
}

export class WatchLink {
  static readonly STORE_ID: string = 'rev_teaching_watch';
  static readonly KEY_STATUS: string = 'lesson_status';
  static readonly KEY_BUNDLE: string = 'lesson_bundle';
  /** 手表心跳键：手表开着课时定期写入当前时间戳，手机据此判断"有手表在场" */
  static readonly KEY_HELLO: string = 'watch_hello';
  static readonly STATUS_READY: string = 'ready';
  static readonly STATUS_EMPTY: string = '';
  /** 心跳有效期：落在该窗口内视为手表在线 */
  static readonly HELLO_FRESH_MS: number = 5 * 60 * 1000;

  //#if OHOS
  /** 缓存已有 store，保证 watchObserve 的 dataChange 监听持续生效 */
  private static store: WatchStore | undefined = undefined;
  //#endif

  /** 是否支持手表组网推送（仅鸿蒙为 true） */
  static supported(): boolean {
    let ok: boolean = false;
    //#if OHOS
    ok = true;
    //#endif
    return ok;
  }

  /** 手表端心跳上报：手机端用它判断手表是否在场 */
  static async heartbeat(ctx: common.UIAbilityContext): Promise<void> {
    //#if OHOS
    try {
      const s = await WatchLink.ensure(ctx);
      await s.put(WatchLink.KEY_HELLO, Date.now().toString());
    } catch (e) {
      // 忽略
    }
    //#endif
  }

  /** 手机端：组网内是否有手表在线（心跳在场 + 分布式库可同步）；异常则保守视为无 */
  static async hasWearable(ctx: common.UIAbilityContext): Promise<boolean> {
    let found: boolean = false;
    //#if OHOS
    try {
      const s = await WatchLink.ensure(ctx);
      const raw: string = await s.get(WatchLink.KEY_HELLO, '') as string;
      const ts: number = Number(raw);
      found = !isNaN(ts) && Date.now() - ts < WatchLink.HELLO_FRESH_MS;
    } catch (e) {
      found = false;
    }
    //#endif
    return found;
  }

  /** 手机端：把解析好的教案环节推送进分布式库（自动同步到组网内手表） */
  static async pushPlan(ctx: common.UIAbilityContext, stages: LessonStage[]): Promise<boolean> {
    //#if OHOS
    try {
      const s = await WatchLink.ensure(ctx);
      const bundle: WatchLessonBundle = { status: WatchLink.STATUS_READY, stages: stages };
      await s.put(WatchLink.KEY_BUNDLE, JSON.stringify(bundle));
      await s.put(WatchLink.KEY_STATUS, WatchLink.STATUS_READY);
      // 主动 PUSH，加快同步（autoSync 兜底）
      try {
        s.sync(new Array<string>(), distributedKVStore.SyncMode.PUSH_ONLY);
      } catch (e) {
        // 单点/P2P 模式下 sync 不可用则忽略
      }
      return true;
    } catch (e) {
      return false;
    }
    //#endif
  }

  /** 手表端：注册数据变更监听（收到教案后回调）；打开时先上报心跳并读一次存量 */
  static async watchObserve(ctx: common.UIAbilityContext,
    onReady: (bundle: WatchLessonBundle) => void): Promise<void> {
    //#if OHOS
    try {
      const s = await WatchLink.ensure(ctx);
      s.on('dataChange', distributedKVStore.SubscribeType.SUBSCRIBE_TYPE_ALL,
        (): void => {
          WatchLink.read(ctx).then((b: WatchLessonBundle | null): void => {
            if (b !== null && b.status === WatchLink.STATUS_READY) {
              onReady(b);
            }
          });
        });
      await WatchLink.heartbeat(ctx);
      const b = await WatchLink.read(ctx);
      if (b !== null && b.status === WatchLink.STATUS_READY) {
        onReady(b);
      }
    } catch (e) {
      // 监听失败：下一次打开再读
    }
    //#endif
  }

  /** 手表端：读取当前教案预案；无内容返回 null */
  static async read(ctx: common.UIAbilityContext): Promise<WatchLessonBundle | null> {
    //#if OHOS
    try {
      const s = await WatchLink.ensure(ctx);
      const raw: string = await s.get(WatchLink.KEY_BUNDLE, '') as string;
      const status: string = await s.get(WatchLink.KEY_STATUS, '') as string;
      if (raw === '' || status !== WatchLink.STATUS_READY) {
        return null;
      }
      const parsed = JSON.parse(raw) as WatchLessonBundle;
      if (parsed === null || parsed.stages === undefined || parsed.stages.length === 0) {
        return null;
      }
      return parsed;
    } catch (e) {
      return null;
    }
    //#endif
    return null;
  }

  /** 手表端：上课结束后清空预案，避免重新打开又弹"开始上课" */
  static async clear(ctx: common.UIAbilityContext): Promise<void> {
    //#if OHOS
    try {
      const s = await WatchLink.ensure(ctx);
      await s.put(WatchLink.KEY_STATUS, WatchLink.STATUS_EMPTY);
    } catch (e) {
      // 忽略
    }
    //#endif
  }

  //#if OHOS
  private static async ensure(ctx: common.UIAbilityContext): Promise<WatchStore> {
    if (WatchLink.store !== undefined) {
      return WatchLink.store;
    }
    // 组网同一账号下同步到手表端同款应用
    const config: distributedKVStore.KVManagerConfig = {
      bundleName: 'com.rev.myapplication',
      context: ctx
    };
    // SDK 隐藏了 createKVManager 的返回类型（推断为 unknown），在边界断言接驳
    const manager: WatchManager = await distributedKVStore.createKVManager(config) as WatchManager;
    const options: distributedKVStore.Options = {
      createIfMissing: true,
      encrypt: false,
      backup: false,
      autoSync: true,
      kvStoreType: distributedKVStore.KVStoreType.SINGLE_VERSION,
      securityLevel: distributedKVStore.SecurityLevel.S1
    };
    const s: WatchStore = await manager.getKVStore(WatchLink.STORE_ID, options);
    WatchLink.store = s;
    return s;
  }
  //#endif
}