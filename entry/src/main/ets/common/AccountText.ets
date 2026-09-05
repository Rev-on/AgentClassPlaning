/**
 * 账号相关界面文案（避免为登录页大改五语言主词典）
 * 中/英双语；维吾尔语/藏语/蒙古语按需回退中文
 */
export class AccountText {
  private static readonly zh: Map<string, string> = new Map<string, string>([
    ['login.title', '欢迎使用 Rev TechingMaster'],
    ['login.subtitle', '教研备课 · 家校沟通 · 学情分析'],
    ['login.mode', '登录'],
    ['register.mode', '注册'],
    ['register.sub', '注册新账号'],
    ['label.user', '用户名'],
    ['label.pwd', '密码'],
    ['label.pwd2', '确认密码'],
    ['ph.user', '请输入用户名（2-24 位）'],
    ['ph.pwd', '请输入密码（至少 6 位）'],
    ['ph.pwd2', '请再次输入密码'],
    ['btn.submitLogin', '登 录'],
    ['btn.submitRegister', '注 册'],
    ['tip.toRegister', '还没有账号？去注册'],
    ['tip.toLogin', '已有账号？去登录'],
    ['huawei.btn', '华为账号登录'],
    ['huawei.hint', '通过华为账号快速登录（需在 AppGallery Connect 配置回调）'],
    ['toast.loginOk', '登录成功'],
    ['toast.regOk', '注册成功，已自动登录'],
    ['err.user', '请输入用户名'],
    ['err.pwd', '请输入密码'],
    ['err.pwd2', '请再次输入密码'],
    ['err.mismatch', '两次输入的密码不一致'],
    ['acct.card', '账号'],
    ['acct.user', '当前用户'],
    ['acct.kind', '登录方式'],
    ['acct.kind.account', '账号密码'],
    ['acct.kind.huawei', '华为账号'],
    ['btn.logout', '退出登录'],
    ['logout.confirm', '确定要退出当前账号吗？'],
    ['logout.ok', '已退出登录'],
    ['btn.cancel', '取消'],
    ['btn.ok', '确定'],
    ['acct.title', '账户'],
    ['acct.mine.desc', '头像 · 昵称 · 退出登录'],
    ['acct.enterNick', '请输入新的昵称'],
    ['acct.save', '保存'],
    ['acct.changeAvatar', '点击更换头像'],
    ['acct.fromAlbum', '从相册选择图片'],
    ['acct.nickname', '昵称'],
    ['acct.username', '用户名'],
    ['acct.huaweiNote', '使用华为账号登录：头像与昵称取自华为账号'],
    ['toast.nickSaved', '昵称已更新'],
    ['toast.avatarSaved', '头像已更新'],
    ['toast.avatarLocal', '头像已保存到本机'],
    ['err.nick', '昵称需为 1-24 个字符'],
    ['btn.skip', '跳过登录'],
    ['acct.guest', '未登录'],
    ['acct.guestTip', '当前为游客模式：登录后可设置头像与昵称，并同步到云端'],
    ['btn.toLogin', '去登录']
  ]);

  private static readonly en: Map<string, string> = new Map<string, string>([
    ['login.title', 'Welcome to Rev TechingMaster'],
    ['login.subtitle', 'Lesson Prep · Home-School · Learning Analytics'],
    ['login.mode', 'Sign In'],
    ['register.mode', 'Sign Up'],
    ['register.sub', 'Create a new account'],
    ['label.user', 'Username'],
    ['label.pwd', 'Password'],
    ['label.pwd2', 'Confirm password'],
    ['ph.user', 'Username (2-24 characters)'],
    ['ph.pwd', 'Password (6+ characters)'],
    ['ph.pwd2', 'Type the password again'],
    ['btn.submitLogin', 'Sign In'],
    ['btn.submitRegister', 'Sign Up'],
    ['tip.toRegister', 'No account? Create one'],
    ['tip.toLogin', 'Have an account? Sign in'],
    ['huawei.btn', 'Sign in with Huawei ID'],
    ['huawei.hint', 'Quick sign-in with your Huawei account (callback must be configured in AppGallery Connect)'],
    ['toast.loginOk', 'Signed in'],
    ['toast.regOk', 'Account created and signed in'],
    ['err.user', 'Please enter a username'],
    ['err.pwd', 'Please enter a password'],
    ['err.pwd2', 'Please confirm the password'],
    ['err.mismatch', 'Passwords do not match'],
    ['acct.card', 'Account'],
    ['acct.user', 'Current user'],
    ['acct.kind', 'Sign-in method'],
    ['acct.kind.account', 'Password'],
    ['acct.kind.huawei', 'Huawei ID'],
    ['btn.logout', 'Sign out'],
    ['logout.confirm', 'Sign out of this account?'],
    ['logout.ok', 'Signed out'],
    ['btn.cancel', 'Cancel'],
    ['btn.ok', 'OK'],
    ['acct.title', 'Account'],
    ['acct.mine.desc', 'Avatar · Nickname · Sign out'],
    ['acct.enterNick', 'Enter a new nickname'],
    ['acct.save', 'Save'],
    ['acct.changeAvatar', 'Tap to change avatar'],
    ['acct.fromAlbum', 'Choose from album'],
    ['acct.nickname', 'Nickname'],
    ['acct.username', 'Username'],
    ['acct.huaweiNote', 'Signed in with Huawei ID: avatar and nickname come from your Huawei account'],
    ['toast.nickSaved', 'Nickname updated'],
    ['toast.avatarSaved', 'Avatar updated'],
    ['toast.avatarLocal', 'Avatar saved on this device'],
    ['err.nick', 'Nickname must be 1-24 characters'],
    ['btn.skip', 'Skip for now'],
    ['acct.guest', 'Not signed in'],
    ['acct.guestTip', 'Guest mode: sign in to set an avatar and nickname, synced to the cloud'],
    ['btn.toLogin', 'Sign in']
  ]);

  static t(key: string): string {
    const lang: string = AppStorage.get<string>('appLang') as string || 'zh';
    if (lang === 'en') {
      const v = AccountText.en.get(key);
      if (v !== undefined) {
        return v;
      }
    }
    const z = AccountText.zh.get(key);
    return z !== undefined ? z : key;
  }
}
