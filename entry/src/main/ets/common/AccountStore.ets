/**
 * 账号体系：本地会话持久化（Preferences）
 *  - token/用户名/登录方式/昵称/头像保存在本机 Preferences，并通过 AppStorage 广播
 *  - 冷启动时由 EntryAbility 并行加载（不阻塞启动页）
 *  - 头像取值：http(s) 华为头像 URL | 本机文件路径 | 空（显示默认头像）
 */
import preferences from '@ohos.data.preferences';
import common from '@ohos.app.ability.common';

export class AccountStore {
  private static readonly STORE_NAME: string = 'app_account';
  private static readonly TOKEN_KEY: string = 'acctToken';
  private static readonly USER_KEY: string = 'acctUser';
  private static readonly KIND_KEY: string = 'acctKind';
  private static readonly NICK_KEY: string = 'acctNickname';
  private static readonly AVATAR_KEY: string = 'acctAvatar';

  /** 从 Preferences 读取并写入 AppStorage（供启动页门控判断） */
  static async load(context: common.UIAbilityContext): Promise<void> {
    try {
      const store = await preferences.getPreferences(context, AccountStore.STORE_NAME);
      const token = (await store.get(AccountStore.TOKEN_KEY, '')) as string;
      const user = (await store.get(AccountStore.USER_KEY, '')) as string;
      const kind = (await store.get(AccountStore.KIND_KEY, 'account')) as string;
      const nick = (await store.get(AccountStore.NICK_KEY, '')) as string;
      const avatar = (await store.get(AccountStore.AVATAR_KEY, '')) as string;
      AppStorage.setOrCreate(AccountStore.TOKEN_KEY, token);
      AppStorage.setOrCreate(AccountStore.USER_KEY, user);
      AppStorage.setOrCreate(AccountStore.KIND_KEY, kind);
      AppStorage.setOrCreate(AccountStore.NICK_KEY, nick);
      AppStorage.setOrCreate(AccountStore.AVATAR_KEY, avatar);
    } catch (e) {
      AppStorage.setOrCreate(AccountStore.TOKEN_KEY, '');
      AppStorage.setOrCreate(AccountStore.USER_KEY, '');
      AppStorage.setOrCreate(AccountStore.KIND_KEY, 'account');
      AppStorage.setOrCreate(AccountStore.NICK_KEY, '');
      AppStorage.setOrCreate(AccountStore.AVATAR_KEY, '');
    }
  }

  /** 登录/注册成功后保存会话与档案 */
  static async save(context: common.UIAbilityContext, token: string, username: string, kind: string,
    nickname?: string, avatar?: string): Promise<void> {
    const store = await preferences.getPreferences(context, AccountStore.STORE_NAME);
    await store.put(AccountStore.TOKEN_KEY, token);
    await store.put(AccountStore.USER_KEY, username);
    await store.put(AccountStore.KIND_KEY, kind);
    await store.put(AccountStore.NICK_KEY, nickname !== undefined ? nickname : username);
    await store.put(AccountStore.AVATAR_KEY, avatar !== undefined ? avatar : '');
    await store.flush();
    AppStorage.setOrCreate(AccountStore.TOKEN_KEY, token);
    AppStorage.setOrCreate(AccountStore.USER_KEY, username);
    AppStorage.setOrCreate(AccountStore.KIND_KEY, kind);
    AppStorage.setOrCreate(AccountStore.NICK_KEY, nickname !== undefined ? nickname : username);
    AppStorage.setOrCreate(AccountStore.AVATAR_KEY, avatar !== undefined ? avatar : '');
  }

  /** 仅更新昵称/头像（本地），服务器同步由调用方负责 */
  static async saveProfile(context: common.UIAbilityContext, nickname: string, avatar: string): Promise<void> {
    const store = await preferences.getPreferences(context, AccountStore.STORE_NAME);
    await store.put(AccountStore.NICK_KEY, nickname);
    await store.put(AccountStore.AVATAR_KEY, avatar);
    await store.flush();
    AppStorage.setOrCreate(AccountStore.NICK_KEY, nickname);
    AppStorage.setOrCreate(AccountStore.AVATAR_KEY, avatar);
  }

  /** 退出登录：清空本地会话 */
  static async clear(context: common.UIAbilityContext): Promise<void> {
    try {
      const store = await preferences.getPreferences(context, AccountStore.STORE_NAME);
      await store.delete(AccountStore.TOKEN_KEY);
      await store.delete(AccountStore.USER_KEY);
      await store.delete(AccountStore.KIND_KEY);
      await store.delete(AccountStore.NICK_KEY);
      await store.delete(AccountStore.AVATAR_KEY);
      await store.flush();
    } catch (e) {
      // 忽略清理异常
    }
    AppStorage.setOrCreate(AccountStore.TOKEN_KEY, '');
    AppStorage.setOrCreate(AccountStore.USER_KEY, '');
    AppStorage.setOrCreate(AccountStore.KIND_KEY, 'account');
    AppStorage.setOrCreate(AccountStore.NICK_KEY, '');
    AppStorage.setOrCreate(AccountStore.AVATAR_KEY, '');
  }

  /** 当前会话 token（无则空字符串） */
  static token(): string {
    return AppStorage.get<string>(AccountStore.TOKEN_KEY) as string || '';
  }

  /** 当前登录用户名 */
  static user(): string {
    return AppStorage.get<string>(AccountStore.USER_KEY) as string || '';
  }

  /** 登录方式：account | huawei */
  static kind(): string {
    return AppStorage.get<string>(AccountStore.KIND_KEY) as string || 'account';
  }

  /** 昵称（缺省回落用户名） */
  static nickname(): string {
    const n: string = AppStorage.get<string>(AccountStore.NICK_KEY) as string || '';
    return n !== '' ? n : AccountStore.user();
  }

  /** 头像：http(s) URL 或本机文件路径或空 */
  static avatar(): string {
    return AppStorage.get<string>(AccountStore.AVATAR_KEY) as string || '';
  }

  /** 是否已登录 */
  static signedIn(): boolean {
    return AccountStore.token() !== '';
  }
}
