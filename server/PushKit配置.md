# 华为 Push Kit 配置说明（含消息回执回调）

> 服务器：`123.60.130.45`　公网入口：`https://rev-on.site:3000`
> 本文给出 AGC 后台需要填写的四项回执参数，以及服务端对应的部署与验证步骤。

---

## 一、AGC 后台需要填写的四项

在 **AppGallery Connect → 我的项目 → 项目设置 → 消息回执** 中填写：

| AGC 字段 | 建议填写值 | 说明 |
|---|---|---|
| **回调名称** | `RevTechingMaster-回执` | 仅用于在 AGC 列表里标识这条回调，任意可辨识名称即可，不影响功能 |
| **回调地址** | `https://rev-on.site:3000/api/push/receipt` | 华为推送服务器回调的地址。**必须是 HTTPS 公网可达**，且路径末段要与服务端 `PUSH_CALLBACK_PATH` 一致 |
| **回调用户名** | `revtech` | 与服务端 `.env` 的 `PUSH_CALLBACK_USER` 保持一致 |
| **回调密钥** | 自行生成一段随机字符串（≥32 位） | 与服务端 `.env` 的 `PUSH_CALLBACK_SECRET` 保持一致。**不要提交到仓库** |

> 若你的 AGC 项目尚未绑定域名，也可先用 IP 形式：
> `https://123.60.130.45:3000/api/push/receipt`
> 但证书是签发给 `rev-on.site` 的，用 IP 访问会有证书不匹配风险，**推荐用域名**。

### 生成回调密钥

```powershell
# 生成 48 位随机密钥（Base64），复制输出值填入 AGC 与服务端 .env
$b = New-Object byte[] 36
[System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
[Convert]::ToBase64String($b)
```

---

## 二、鉴权原理（为什么必须两边一致）

当 **回调用户名与回调密钥都已配置**时，华为会在每个回执请求的请求头带上：

```
X-HUAWEI-CALLBACK-ID: timestamp=<unix秒>; nonce=<uuid>; value=<Base64>
```

其中 `value` 的算法是：

```
value = Base64( HmacSHA256( timestamp + nonce + 回调用户名, 回调密钥 ) )
```

服务端 `src/pushReceipt.js` 会用同样的方式重算 `value` 并做**常量时间比较**，
同时校验 `timestamp` 与当前时间相差不超过 **5 分钟**（防重放）。
校验不通过则返回 `{"code":"1"}`，华为侧会认为回执投递失败。

> 注意：两项只要有一项没配置，该请求头就不会下发，服务端也会跳过校验。
> 生产环境**建议两项都配置**。

---

## 三、服务端配置与部署

### 1. 修改服务器上的 `.env`（`/opt/rev-server/.env`）

```bash
ssh -i c:\Users\laoyu\.ssh\rev_deploy root@123.60.130.45
vi /opt/rev-server/.env
```

追加：

```ini
PUSH_CALLBACK_USER=revtech
PUSH_CALLBACK_SECRET=这里填与 AGC 完全一致的密钥
PUSH_CALLBACK_PATH=/api/push/receipt
```

### 2. 上传新增/改动的服务端文件

本次新增 `src/pushReceipt.js`，并改动 `src/server.js`：

```powershell
# 备份远端
ssh -i 'c:\Users\laoyu\.ssh\rev_deploy' root@123.60.130.45 "mkdir -p /opt/rev-server/src.bak.$(date +%Y%m%d%H%M%S) && cp /opt/rev-server/src/*.js /opt/rev-server/src.bak.$(date +%Y%m%d%H%M%S)/"

# 上传两个文件
scp -i 'c:\Users\laoyu\.ssh\rev_deploy' `
  'C:\Users\laoyu\Desktop\Rev_Techingmaster\server\src\pushReceipt.js' `
  'C:\Users\laoyu\Desktop\Rev_Techingmaster\server\src\server.js' `
  root@123.60.130.45:/opt/rev-server/src/

# 重启
ssh -i 'c:\Users\laoyu\.ssh\rev_deploy' root@123.60.130.45 'pm2 restart rev-server && pm2 logs rev-server --lines 20 --nostream'
```

### 3. 确认端口放行

华为推送服务器需要能访问 `123.60.130.45:3000`。确认安全组/防火墙已放行该端口
（既有 AI 代理已经走这个端口，通常无需额外操作）。

---

## 四、验证

### 1. 健康检查

```powershell
curl.exe -sS https://rev-on.site:3000/health
# 期望：{"ok":true,...}
```

### 2. 回执接口连通性（无鉴权头 → 应被拒绝）

```powershell
curl.exe -sS -X POST 'https://rev-on.site:3000/api/push/receipt' `
  -H 'Content-Type: application/json' -d '{\"statuses\":[]}'
# 期望：{"code":"1","message":"auth failed: missing X-HUAWEI-CALLBACK-ID fields"}
```

能返回上面这条 JSON，说明**路由已生效**（这正是要验证的）。

### 3. 用合法签名自测（模拟华为侧调用）

```powershell
$user='revtech'; $secret='你的回调密钥'
$ts=[long][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$nonce=[guid]::NewGuid().ToString()
$h=New-Object System.Security.Cryptography.HMACSHA256
$h.Key=[Text.Encoding]::UTF8.GetBytes($secret)
$val=[Convert]::ToBase64String($h.ComputeHash([Text.Encoding]::UTF8.GetBytes("$ts$nonce$user")))
$hdr="timestamp=$ts; nonce=$nonce; value=$val"
$now=[long][DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$body='{"statuses":[{"requestId":"test-1","token":"tok-test","pushType":0,"appPackageName":"你的包名","deliveryStatus":{"result":0,"timestamp":' + $now + '}}]}'
curl.exe -sS -X POST 'https://rev-on.site:3000/api/push/receipt' `
  -H 'Content-Type: application/json' -H "X-HUAWEI-CALLBACK-ID: $hdr" -d $body
# 期望：{"code":"0","message":"success"}
```

### 4. 查看回执统计

```powershell
curl.exe -sS https://rev-on.site:3000/api/push/receipt/stats
# 返回 total/ok/fail 与最近 50 条回执明细（含状态码释义）
```

---

## 五、常见回执状态码

| result | 含义 |
|---|---|
| 0 | 成功 |
| 1 | Token 无效 |
| 6 | 推送凭证失效 |
| 8 | 用户已关闭通知 |
| 12 | 消息未送达 |
| 20 | 应用被卸载 |
| 22 | 设备离线 |
| 27 | 推送服务未开启 |

完整对照表见 `src/pushReceipt.js` 的 `RESULT_TEXT`。

---

## 六、与发送侧的关系

| 文件 | 职责 |
|---|---|
| `src/push.js` | **发送**：用 AGC 服务账号 JWT 调 Push Kit REST API 下发通知 / 结束实况窗 |
| `src/pushReceipt.js` | **接收**：接收华为回调的送达回执，校验签名并记录结果 |

两者配合构成闭环：`push.js` 发出 → 华为送达 → 华为回调 `pushReceipt.js` → 可查送达率。

> 发送侧还需要 AGC 服务账号凭据（`AGC_PROJECT_ID` / `AGC_JWT_KID` /
> `AGC_JWT_ISS` / `AGC_JWT_PRIVATE_KEY`），这部分见 `.env.example` 中
> 「华为 Push Kit 服务端推送」段落与 `server/README.md`。

---

## 七、7 大 AI 生成功能的「完成通知」

### 7.1 覆盖范围

| 功能 | 客户端 `type` | 页面标题 i18n 键 | 通知 ID |
|---|---|---|---|
| 教案生成 | `plan` | `page.plan` | 7101 |
| 课件生成 | `courseware` | `page.courseware` | 7102 |
| 分层练习命题 | `quiz` | `page.quiz` | 7103 |
| 教研科研辅助 | `research` | `page.research` | 7104 |
| 学情分析与报告 | `analysis` | `page.analysis` | 7105 |
| 沟通话术建议 | `talk` | `page.talk` | 7106 |
| 个性化学情报告 | `report` | `page.report` | 7107 |

通知 ID 由客户端 `GenTask.NOTIFY_IDS` 定义并随任务上报（`notifySeed`）。
**同一功能固定用同一个 ID**，因此重复生成时新通知会覆盖旧通知，通知栏不会堆积。

### 7.2 必须同时满足的 4 个条件

通知要真正弹出，以下条件**缺一不可**——排查"推送返回成功但收不到"时按此顺序逐条确认：

1. **服务端 `PUSH_ENABLED=1`**
   不设该变量时完成通知会被静默跳过（只打日志 `未配置...跳过推送` 或直接不进分支），
   生成任务本身不受影响。这是**最常见的"没通知"原因**。
2. **AGC 服务账号凭据完整**（`AGC_PROJECT_ID` + `AGC_JWT_KID` + `AGC_JWT_ISS` +
   `AGC_JWT_PRIVATE_KEY`，或 `AGC_PUSH_ACCOUNT_FILE`）。
   用 `node tools/check_push.js` 自检，它真的会向华为换取 `access_token`，
   是凭据有效的**硬证据**（只看配置项填没填是不够的）。
3. **设备 Push Token 已上报**
   客户端启动时 `PushToken.ensure()` 申请 token 并 POST `/api/push/register`。
   服务端会做格式校验（长度 ≥40 且仅含 `[A-Za-z0-9_-]`），非法 token 被丢弃，
   日志关键字：`忽略非法 token 上报`。
   注意：应用需已开通推送服务且设备已登录华为账号，否则 `getToken` 失败。
4. **系统通知权限已开启**
   客户端首启会调 `requestEnableNotification` 申请。若用户曾拒绝，系统不再弹窗，
   需引导至 **系统设置 → 通知 → 备课助手** 手动开启。
   未授权时华为**仍返回 `80000000` 成功**，但通知被系统静默丢弃。

### 7.3 通知内容

文案在**客户端本地化**后随任务上报（服务端只透传），因此通知会跟随用户
当前界面语言（中/英/维/藏/蒙）。中文示例：

```
标题：生成完成
正文：「教案生成」已生成完成，点击查看
```

失败时推送失败组文案（`生成失败` / 「教案生成」生成失败，点击重试）。
点击通知会带上 `clickAction.data = { taskId, type, status }`。

### 7.4 离线自检（不需要 AGC 凭据、不联网）

本功能配有两个自检脚本，**都不需要凭据、不联网、不需要真机**：

```powershell
# ① 客户端上报契约 + 服务端存取 + 文案完整性（83 项断言）
node server/tools/test_notify_payload.js

# ② 推送请求体契约：用临时 RSA 私钥真跑 PS256 JWT 签名，
#    并拦截 fetch 断言发给华为的报文结构（149 项断言）
node server/tools/test_notify_contract.js
```

脚本 ① 是**防漂移**设计：它直接读 `GenTask.ets` 与 `I18n.ets` 源码做静态断言，
一旦有人改了客户端映射表、漏加 i18n 键，或把 notifySeed 改成 0，脚本立即失败。

脚本 ② 覆盖纯函数与报文层：`configured()` 判定、无凭据时 `{skipped:true}` 且
**不发任何网络请求**、有凭据时 `notifyId` 为 number、`category=WORK`、
`slotType` 为 number、`foregroundShow=false`、`target.token` 为数组、
`clickAction.data` 透传正确，以及 `80300007` 失效 token 的解析与清理。

### 7.5 端到端联调（真实 HTTP，无需凭据）

验证"提交任务 → 通知字段真正入库"这一段闭环：

```powershell
# 终端 A：用临时数据目录启动服务端（不污染真实数据）
cd server
$env:DATA_DIR="$env:TEMP\notify-e2e"; $env:PORT="34519"; $env:HOST="127.0.0.1"
$env:DEEPSEEK_API_KEY="sk-fake-offline"; $env:PROXY_TOKEN="e2e-proxy-token"
node src/server.js

# 终端 B：跑断言（14 项）
node server/tools/test_notify_e2e.js
```

> 该脚本刻意**不自启服务端子进程**：受限沙箱下 `child_process.spawn`
> 会以 EPERM 失败（无法创建带管道的子进程），改为由调用方先启动服务端，
> 脚本只做 HTTP 断言 —— 普通环境下同样可用。

### 7.6 真机验证（本地无法替代的最后一步）

```powershell
# 1. 服务端确认开关已开
ssh -i c:\Users\laoyu\.ssh\rev_deploy root@123.60.130.45 'grep PUSH_ENABLED /opt/rev-server/.env'

# 2. 凭据自检（会真的向华为换取 access_token）
ssh -i c:\Users\laoyu\.ssh\rev_deploy root@123.60.130.45 'cd /opt/rev-server && node tools/check_push.js'

# 3. 真机操作：App 内发起一次"教案生成"，立即退到桌面或上滑杀掉进程
#    期望：数分钟内收到「生成完成 / 「教案生成」已生成完成，点击查看」

# 4. 服务端日志确认
ssh -i c:\Users\laoyu\.ssh\rev_deploy root@123.60.130.45 'pm2 logs rev-server --lines 50 --nostream'
#    期望出现：完成通知已发送（华为已受理）
```

若第 4 步出现 `发送失败 httpCode=200 code=80300007`，说明设备 token 已失效，
服务端会自动清理该 token；重新打开 App 会重新上报新 token。

### 7.7 实测诊断记录（2026-10-04，生产环境）

按 5 层逐层检查的真实结果，可作为日后回归的基线：

| 层 | 检查项 | 实测结果 |
|---|---|---|
| 1 | `PUSH_ENABLED` | `"1"` → 已开启 ✅ |
| 2 | AGC 凭据 | `configured()=true`，**PS256 JWT 签名成功**（512 字节）✅ |
| 3 | 设备 Push Token | 13 个有效 token（长度 112，`MASILgcR9N...`）✅ |
| 4 | 任务通知字段 | 最近 2 条任务带 `notifyId=7101` + 完整文案 ✅ |
| 5 | 前台展示 | `foregroundShow=false` → **前台不弹通知（预期行为）** |
| — | 服务端日志 | `[push] 完成通知已发送（华为已受理）` ✅ |

**结论：推送链路完全打通，服务端已确认华为受理。**
前台测试收不到属预期；须在"生成中退到桌面/杀进程"场景验证。

> 第 4 层的观察很有价值：240 条历史任务中，绝大多数 `notifyId=0 title="" body=""`
> —— 那是**旧版客户端**产生的（不上报通知字段）。最近 2 条带完整文案，
> 反向证明本次客户端改动已生效。若日后又看到大量空文案，说明装回了旧客户端。

**关于回执 `timestamp expired`：**

日志中反复出现 `[push-receipt] 鉴权失败: timestamp expired`，且
`/api/push/receipt/stats` 的 `total` 为 0（即**从未成功记下一条回执**）。
已排查并**排除**时钟偏差：服务器 `timedatectl` 显示
`System clock synchronized: yes`，UTC 与本地一致。

因此已增强该路由的日志（`server.js` 的 `/api/push/receipt`）：鉴权失败时打印
**原始头的 timestamp、本地时间、两者差值、原始头长度**，用于区分三种成因：

| 差值表现 | 结论 |
|---|---|
| 差值在 ±300 秒内却仍报 expired | 不是时钟问题 → 检查代理是否改写/剥离了请求头 |
| 差值达数千秒 | 上游代理缓存了旧请求，或时钟真的偏了 |
| 原始头长度异常短 | 头被截断，检查反向代理的头大小限制 |

回执只影响**送达率统计**，不影响推送本身能否送达。

### 7.8 让通知「响铃 + 弹横幅」

要让生成完成通知响铃并弹出横幅，需要**客户端与服务端各做一件事**，缺一不可。

**① 客户端：注册社交通信渠道（决定响铃/横幅）**

关键认知：服务端报文的 `slotType` **只是声明"请按这个级别投递"**；
真正决定是否响铃、是否弹横幅的是**客户端本地已注册的通知渠道**。
不注册渠道 → 系统回退到默认低级别渠道 → **能收到通知，但不响铃、无横幅**。

实现见 `entry/src/main/ets/common/NotifySlot.ets`，在通知权限就绪后调用
（`EntryAbility.requestNotifyPermission` 的每个授权分支 + `onForeground` 补偿重试）：

```typescript
// 本机 DevEco SDK 的 addSlot 只有接受 SlotType 的重载：
//   function addSlot(type: SlotType, callback: AsyncCallback<void>): void;
//   function addSlot(type: SlotType): Promise<void>;
// 级别由**类型默认值**决定，没有 level 入参。
await notificationManager.addSlot(notificationManager.SlotType.SOCIAL_COMMUNICATION);
```

**⚠️ 最容易踩的坑：不要写成"对象版"（本项目实际踩过，导致构建失败）**

网上不少示例是较新 SDK 的写法，传一个 `NotificationSlot` 对象：

```typescript
// ✗ 在本机 SDK 上编译失败（10505001 ArkTS Compiler Error）
const slot: notificationManager.NotificationSlot = {
  notificationType: notificationManager.SlotType.SOCIAL_COMMUNICATION,
  notificationLevel: notificationManager.SlotLevel.LEVEL_HIGH,
  desc: '...', badgeFlag: true, bypassDnd: false,
  lockscreenVisibility: 1, vibrationEnabled: true
};
await notificationManager.addSlot(slot);
// Error Message: Argument of type 'NotificationSlot' is not assignable
//                to parameter of type 'SlotType'.
//                At File: entry/src/main/ets/common/NotifySlot.ets:138:41
```

本机 SDK 声明（`sdk/default/openharmony/ets/api/@ohos.notificationManager.d.ts`）
中 `addSlot` **只接受 `SlotType` 枚举**，没有对象重载。对象版属于更新版本的 SDK。

**为什么只传 `SOCIAL_COMMUNICATION` 就够（无需指定 level）**

该 SDK 头文件明确注明（同文件第 852-860 行）：

```
SOCIAL_COMMUNICATION = 1
"This type corresponds to SlotLevel being **LEVEL_HIGH**."
```

而 `LEVEL_HIGH` 的定义就是"有横幅 + 有提示音"：

| 级别 | 值 | 横幅 | 提示音 |
|---|---|---|---|
| LEVEL_DEFAULT | 3 | ❌ | ✅ |
| **LEVEL_HIGH** | 4 | ✅ | ✅ |

**因此"要横幅" ⟺ "必须选 `SOCIAL_COMMUNICATION`"。**
选 `CONTENT_INFORMATION`（默认 `LEVEL_MIN`）或 `UNKNOWN_TYPE` 都会静默无横幅。

**两个最容易踩的坑：**

| 坑 | 后果 | 正确做法 |
|---|---|---|
| 传 `NotificationSlot` 对象 | **编译失败 10505001** | 只传 `SlotType` 枚举 |
| 选 `CONTENT_INFORMATION` / `UNKNOWN_TYPE` | 静默，**无横幅** | 必须选 `SOCIAL_COMMUNICATION`（默认 LEVEL_HIGH） |
| 在通知权限未就绪时 addSlot | 失败（1600004），渠道缺失 | 权限就绪后再注册，并在 `onForeground` 重试 |

**② 服务端：`AGC_PUSH_SLOT_TYPE` 与客户端渠道对应**

| 值 | SlotType | 表现 |
|---|---|---|
| 0 | UNKNOWN_TYPE | 静默 |
| **1** | **SOCIAL_COMMUNICATION** | **横幅 + 提示音** ← 本应用默认 |
| 2 | SERVICE_INFORMATION | 提示音（无横幅） |
| 3 | CONTENT_INFORMATION | 静默 |

默认值已为 `1`，与客户端注册的 `SOCIAL_COMMUNICATION` 渠道配对。
这一个数字必须与客户端渠道一致，否则通知会落到默认渠道。

**③ 已加的自动化防护**

`server/tools/test_notify_payload.js` 第四节做**跨端一致性断言**：

- `addSlot` 传入的是 `SLOT_TYPE` 枚举，**未传对象**（防 10505001 回归）
- 未构造 `NotificationSlot` 对象（本 SDK 不支持对象版）
- 客户端注册的是 `SOCIAL_COMMUNICATION`（默认 LEVEL_HIGH，有横幅）
- 未误用 `CONTENT_INFORMATION` / `UNKNOWN_TYPE`（静默，无横幅）
- 未写入只读字段 `enabled`
- 服务端 `slotType` 默认值为 `1`

任一端被单边改动，测试立即失败 —— 这是防止该问题回归的关键。
**该测试已验证过"能抓到 bug"**：把源码改回 `addSlot(slot)` 后测试立刻失败。

> **一切以本机 SDK 的 d.ts 为准**，不要照抄网上示例：
> 本项目 `addSlot` **只有 `SlotType` 重载**（对象版是更新 SDK 才有的）。
> 另：`NotificationSlot.enabled` 是 **readonly**；`sound` 是 **string**（提示音 URI）
> 而非 boolean；`lockscreenVisibility` 是 **number** 而非枚举对象。

**④ 真机验证**

```powershell
# 生成中退到桌面 → 期望：响铃 + 顶部横幅 + 通知栏条目
# 若只响铃无横幅：检查是否误用了 LEVEL_DEFAULT，或用户在系统设置里
#   把该渠道的「横幅」单独关掉了（系统设置 → 通知 → 备课助手 → AI 生成完成提醒）
```

### 7.9 两个已确认的实现细节（排查时请先看这里）

**① `PUSH_ENABLED` 未开时，日志里不会有"跳过推送"字样。**
`server.js` 的判断是 `if (PUSH_ENABLED) { ...推送... }`，未开启时**根本不进入
推送分支**，因此不会打任何推送相关日志——"日志里没提到推送"恰恰是开关没开的典型表现。
而 `push.js` 里的 `未配置 AGC 推送凭据，跳过推送` 只在**开关已开但凭据缺失**时出现。
两者含义不同，别混淆。

**② 华为回执里的 `illegalTokens` 值可能短于 40 字符，此时清理逻辑不会命中。**
`tasks.js` 的 `registerDevice` 只接受长度 ≥40 且仅含 `[A-Za-z0-9_-]` 的 token
（`TOKEN_MIN_LEN=40`），而 `forgetInvalidTokens` 是**按 token 值精确匹配**来删除记录的
（`dead.has(v.token)`）。因此：
- 华为报回的非法值是**完整真实 token** → 能匹配上 → 记录被清理 ✅
- 华为报回的是**截断/占位形态**（如 `dead-token`）→ 匹配不上 → 清理 0 条 ⚠️

后一种情况不会造成故障，只是该设备记录会滞留到下次成功上报覆盖。
已由 `server/tools/test_notify_contract.js` 的套件 3 与 7 分别覆盖这两种路径。


**① `PUSH_ENABLED` 未开时，日志里不会有"跳过推送"字样。**
`server.js` 的判断是 `if (PUSH_ENABLED) { ...推送... }`，未开启时**根本不进入
推送分支**，因此不会打任何推送相关日志——"日志里没提到推送"恰恰是开关没开的典型表现。
而 `push.js` 里的 `未配置 AGC 推送凭据，跳过推送` 只在**开关已开但凭据缺失**时出现。
两者含义不同，别混淆。

**② 华为回执里的 `illegalTokens` 值可能短于 40 字符，此时清理逻辑不会命中。**
`tasks.js` 的 `registerDevice` 只接受长度 ≥40 且仅含 `[A-Za-z0-9_-]` 的 token
（`TOKEN_MIN_LEN=40`），而 `forgetInvalidTokens` 是**按 token 值精确匹配**来删除记录的
（`dead.has(v.token)`）。因此：
- 华为报回的非法值是**完整真实 token** → 能匹配上 → 记录被清理 ✅
- 华为报回的是**截断/占位形态**（如 `dead-token`）→ 匹配不上 → 清理 0 条 ⚠️

后一种情况不会造成故障，只是该设备记录会滞留到下次成功上报覆盖。
已由 `server/tools/test_notify_contract.js` 的套件 3 与 7 分别覆盖这两种路径。

