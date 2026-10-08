# 获取设备 Push Token

> 鸿蒙 Push Token（设备推送令牌）的获取方式说明与配套脚本。
> 适用：需要手工验证推送、排查"推送发不出去/收不到"、接管实况窗补推调试时。

---

## 1. 先说结论：Token 不能"凭空申请"，只能"读回来"

**Push Token 由 `@kit.PushKit` 的 `pushService.getToken()` 在「应用进程内」申请**，
它绑定应用自己的 `client_id`、**签名证书**与 AGC 应用身份。

这意味着：

- ❌ **任何外部脚本（Node / Python / curl）都无法直接申请它** —— 没有对应权限与身份；
- ❌ **shell 也取不到** —— 它不是文件、不是环境变量、不在系统属性里；
- ✅ 唯一已经拿到 Token 的地方，是 **App 启动时自己申请并上报到服务端**的那一份。

App 的调用链（`entry/src/main/ets/common/PushToken.ets`）：

```
EntryAbility.onCreate
  └─ PushToken.ensure()
       ├─ pushService.getToken()                 ← 申请（只能在 App 进程内）
       └─ POST /api/push/register {deviceId, token}
                                                  ← 服务端存进 data/devices.json
```

所以"在电脑上拿 Token" = **把服务端已经存下的那份读回来**。

---

## 2. 三个脚本 / 三条通道

| 脚本 | 通道 | 前提 | 能否拿到完整 Token |
|---|---|---|---|
| `tools/get_device_token.js --server <URL>` | ① 服务端接口读回 | 服务端已部署 `GET /api/push/devices` | ✅ 需加 `--full` |
| `tools/get_device_token.js --local` | ② 本地文件 | App 上报到的是**这台机器上的**服务端 | ✅ |
| `tools/get_token_from_device.js` | ③ 真机日志 | 连了真机 + hdc | ⚠ **取决于机型**（多数拿不到，见第 5 节） |

> 另有 `tools/get_device_token.js --log` 是通道③的早期简化版，保留但建议用
> `get_token_from_device.js`（它会主动重启 App 触发重新申请，结论也更明确）。

### 通道 ①：从服务端读回（推荐）

```powershell
cd server

# 从你在 ApiConfig.ets 里配置的服务器读（默认会读该文件拿地址与 PROXY_TOKEN）
node tools/get_device_token.js

# 显式指定服务器与代理口令
node tools/get_device_token.js --server https://your-host:3000 --token <PROXY_TOKEN>

# 显示 Token 明文（默认打码）
node tools/get_device_token.js --server https://your-host:3000 --full

# 只看某台设备
node tools/get_device_token.js --deviceId 40a538b7-c76d-db01-bb7d-99ac3f58279d
```

**为什么服务端原来没有这个接口**：`server.js` 原本只有
`POST /api/push/register`（写），**没有读接口** —— 这是有意的，
Token 是敏感凭据，谁能读走谁就能冒充服务端给该设备推消息。

本次配套新增了 `GET /api/push/devices`，并做了三重收敛：

1. 走 `checkToken`（需 `x-proxy-token`），与其它管理接口一致，**不对外开放**；
2. **默认打码**，只返回前后各 6 位与长度；要明文必须显式 `?full=1`；
3. 只读，不写不删。

> 若你不希望服务端暴露该接口，删除该路由即可，改用通道 ②。

### 通道 ②：直接读本地数据文件

```powershell
node tools/get_device_token.js --local
```

读 `server/data/devices.json`。**只适用于 App 上报到的是本机服务端**的情况。
本机该文件当前是 `[]`（空），因为 App 实际配置的是生产服务器（见下）。

---

## 3. 本项目当前的实际配置（重要）

`entry/src/main/ets/common/ApiConfig.ets`：

```
SERVER_BASE_URL = 'https://rev-on.site:3000/api'
PROXY_TOKEN    = ''            ← 服务器未启用代理令牌
```

也就是说 **App 把 Token 上报到了远程服务器 `rev-on.site:3000`**，
而不是本机 `server/data/`。因此：

- `--local` 在本机读到的是空数组（正常现象）；
- 要拿 Token 应该走通道 ①，**但需要先把新版 `server.js` 部署到那台服务器**。
  在部署之前，请求该接口会返回 **404**（脚本已明确提示这一点，不会误报成"没有 Token"）。

---

## 4. 一次真实排查记录（可作为模板）

在真机 `6XE0226106018583` 上实测，App 侧日志证明 Token 申请**是成功的**：

```
Ability onCreate
Ability onForeground
通知权限当前状态: 已开启
PushToken: getToken 成功: MASILgcXJ6ED...            ← 只打前 12 位
PushToken: Token 上报成功 deviceId=40a538b7-c76d-db01-bb7d-99ac3f58279d
```

关键信息：

| 项 | 值 |
|---|---|
| deviceId | `40a538b7-c76d-db01-bb7d-99ac3f58279d`（来自 `deviceInfo.ODID`） |
| Token 前缀 | `MASILgcXJ6ED...` |
| 上报目标 | `https://rev-on.site:3000/api/push/register` |

排查手法（当"推送没反应"时按此顺序）：

```powershell
$hdc = 'D:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe'

# 1) App 是否在跑
& $hdc shell "ps -ef | grep myapplication"

# 2) 清日志 → 重启 App → 看它有没有申请成功
& $hdc shell "hilog -r"
& $hdc shell "aa force-stop com.rev.myapplication"
& $hdc shell "aa start -a EntryAbility -b com.rev.myapplication"
& $hdc shell "hilog -x | grep -iE 'testTag|PushToken'"
```

**注意别被无关日志误导**：直接 `grep PushToken` 会命中
`com.huawei.hmos.parentcontrol`（华为「健康使用手机」系统应用）的
`PushTokenUploader` 日志，那是**别的应用**的 Token，不是你的。务必带上包名过滤：

```powershell
& $hdc shell "hilog -x | grep myapplication"
```

---

## 5. 为什么真机日志通常拿不到完整 Token

华为推送服务的系统进程（`C05300/push_manager_service`）在申请 Token 时，
日志只记录**动作与长度**，不记录明文：

```
C05300/com.rev.myapplication/: Proxy GetToken begin
C05300/push_manager_service/70000058: GetToken begin com.rev.myapplication 100   ← 100 是长度
A00000/com.rev.myapplication/PushToken: getToken 成功: MASILgcXJ6ED...           ← 应用自己只打 12 位
```

这是**合理的安全设计**（Token 明文入日志等于凭据泄露）。
所以 `get_token_from_device.js` 在多数机型上会**如实报告"未找到全文"并以 exit=2 退出**，
而不是假装成功 —— 这是刻意的，避免你拿着半截 Token 去排查别的问题。

**该退出的语义**：

| exit code | 含义 |
|---|---|
| 0 | 找到完整 Token |
| 2 | 未找到全文（机型限制），脚本会给出降级建议 |
| 1 | 环境问题（无 hdc / 无设备） |

---

## 6. 如果确实需要 Token 明文：临时改日志

仅用于本地调试，**用完务必改回**：

`entry/src/main/ets/common/PushToken.ets` 约第 37 行：

```diff
- hilog.info(DOMAIN, TAG, 'getToken 成功: %{public}s...', token.substring(0, 12));
+ hilog.info(DOMAIN, TAG, 'getToken 成功: %{public}s...', token);
```

重新装包并启动一次，然后：

```powershell
node tools/get_token_from_device.js --no-restart
```

> 注意：`%{public}s` 是 hilog 的**明文**占位符。若改成 `%{private}s`，
> 日志会被系统打码，看不到内容 —— 这也是个常见坑。

**更推荐的做法**（不碰源码、不留调试代码）：
把 `server.js` 部署到 `rev-on.site:3000`，之后直接
`node tools/get_device_token.js --server https://rev-on.site:3000 --full`。
App 每次启动都会自动上报，服务端一直持有最新 Token。

---

## 7. 服务端接口速查

```
POST /api/push/register          上报（App 调用）
  body: { deviceId, token }
  header: x-proxy-token（若服务端配了 PROXY_TOKEN）

GET  /api/push/devices           读回（本脚本调用）
  header: x-proxy-token
  参数: ?full=1（返回明文，默认打码）
        ?deviceId=xxx（只查一台）
  返回: { ok, count, masked, devices:[{id, token, tokenLen, updatedAt}] }
```

Token 格式校验（`server/src/tasks.js`）：

- 长度 ≥ **40**（`TOKEN_MIN_LEN`）
- 字符集 `[A-Za-z0-9_-]`（Base64Url）

不满足的上报会被**静默忽略**，日志打印
`[tasks] 忽略非法 token 上报 deviceId=... tokenLen=...`。
如果你在服务端看到这行，说明 App 上报的 token 不合法（通常是拿到了空串或占位值）。

---

## 8. 相关文件

| 文件 | 说明 |
|---|---|
| `server/tools/get_device_token.js` | 通道①②③ 合一（推荐入口） |
| `server/tools/get_token_from_device.js` | 通道③ 专项：重启 App + 抓真机日志 |
| `server/src/server.js` | `GET /api/push/devices` 读回接口 |
| `server/src/tasks.js` | `registerDevice` / `listDevices` / `tokenOf`、Token 校验 |
| `entry/src/main/ets/common/PushToken.ets` | App 侧申请与上报 |
| `server/data/devices.json` | 本机服务端的设备表（`[{id, token, updatedAt}]`） |
