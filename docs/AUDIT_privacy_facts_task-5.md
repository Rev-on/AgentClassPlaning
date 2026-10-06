# 事实底稿：隐私协议 / 下载页审计（task-5）

审计员：privacy-auditor（只读，未修改任何文件、未部署、未联网访问 rev-on.site）
被审对象：`rev-on.site/privacy.html`、`rev-on.site/download.html`（Lead 将编写）
权威来源：应用源码 `C:\Users\laoyu\Desktop\Rev_Techingmaster`

---

## 0. 结论摘要

- App 确实向自建服务器 `https://rev-on.site:3000` 传输数据，且服务器会把数据**持久化到磁盘文件**。
- 因此"不上传任何数据""不收集任何信息""数据仅存在本地""不涉及第三方"四句话**全部不成立**，禁止出现在隐私协议中。
- 可安全主张的是："不注册账号、不采集通讯录/位置、不上传音频原始录音、不投放广告、密钥不在 App 内"——但每条都要加限定语（见第 10 节）。

---

## 1. 真实申请的权限清单与用途原文

证据：`entry/src/main/module.json5:13-47`（requestPermissions 数组，共 4 项）

| # | 权限 | 用途原文（reason） | 证据 |
|---|------|-------------------|------|
| 1 | ohos.permission.INTERNET | **无 reason**（普通权限，系统不弹窗） | module.json5:14-16 |
| 2 | ohos.permission.DISTRIBUTED_DATASYNC | "用于把生成结果流转到平板/2in1继续编辑" | module.json5:17-26 + string.json:20-22 |
| 3 | ohos.permission.MICROPHONE | "用于把语音转成备注文字" | module.json5:27-36 + string.json:16-18 |
| 4 | ohos.permission.VIBRATE | "手表端上课环节到点时震动提醒" | module.json5:37-46 + string.json:23-26 |

- 权限用途原文（权威）：`entry/src/main/resources/base/element/string.json:16-26`，仅 3 条 reason，逐字如上。
- 注意：INTERNET 实际上是最关键的权限（所有数据出网都靠它），但它**没有**面向用户的 reason 文案——协议里必须自己说明。
- 全项目仅此一个 module.json5（`entry/src/main/module.json5`），AppScope 下无额外权限声明；未申请任何"读取相册/通讯录/位置/日历/剪切板"类权限。
- 附带行为（非 module.json5 权限）：`EntryAbility.ets:70,123-144` 启动后申请**通知权限**（`notificationManager.requestEnableNotification`），不在 requestPermissions 列表里，属运行时系统授权。协议若列"权限清单"应把通知权限单列。
- 设备类型声明：`module.json5:7-12` = phone / tablet / 2in1 / wearable（含手表端，故 VIBRATE 合理）。

---

## 2. 上报到服务器的数据：PushToken.ets

证据：`entry/src/main/ets/common/PushToken.ets`

- 服务端接口：`POST {SERVER_BASE_URL}/push/register`，请求体 `{ deviceId, token }` — PushToken.ets:10（注释）、:52-54（实际 `JSON.stringify({ deviceId, token })`）。
- 上报时机：`EntryAbility.onCreate` 调 `PushToken.ensure()`（EntryAbility.ets:22-24），失败静默；幂等靠 AppStorage 键 `pushTokenDone`（PushToken.ets:22,27-29,40）。
- token 来源：`pushService.getToken()`（@kit.PushKit 华为推送），PushToken.ets:31。
- `deviceId()` 实际实现（PushToken.ets:89-99）：
  - 优先 `deviceInfo.ODID`（系统级设备标识，同设备同应用稳定）— :91-94
  - 退化路径：`deviceInfo.brand + '-' + deviceInfo.productModel` — **:98**
- ★★ **已确认注释/代码不一致**：PushToken.ets:87 注释写"退化到'品牌-型号-系统版本'组合"，但 :98 代码只用了 brand + productModel，**没有任何系统版本字段**。协议/文档若照抄注释即为不实。正确表述："设备品牌与型号"。
- :88 注释自称"不采集用户隐私信息"——这是**开发者自述**，不是事实认定。ODID 属设备标识符，是否算个人信息依各地法律而定，协议里不宜直接引用该自述作为免责依据。
- 另有一条**独立的 deviceId**（与 PushToken 的不同！）：`GenTask.ets:141-165`，纯本地随机串 `'d'+Date.now().toString(36)+随机`，存于 `ai_lesson_store` 的 `ai_device_id` 键。它随每次生成任务上报（GenTask.ets:218,225 → `body.deviceId`）。
  ⇒ **App 存在两个 deviceId**：PushToken 用系统 ODID/品牌型号；GenTask 用本地随机串。协议里若只说一个会不完整。
- 日志泄露面：PushToken.ets:37 打印 token 前 12 字符；:70 打印完整 deviceId。属日志行为，非传输。

---

## 3. 本地存储清单（存储名 + 键）

Preferences 存储（`preferences.getPreferences`）：

| 存储名 (STORE) | 键 | 内容 | 证据 |
|---|---|---|---|
| app_settings | appLang / appTheme / appLangManual / disclaimerAgreed / autoSaveHist / duoLayout / fontScale / deepThink | 语言、主题、免责同意、自动存史、字号、深度思考 | AppSettings.ets:16-28；读写 :47-53,:84-96,:139-170,:203-205 |
| ai_lesson_store | ai_lesson_records | 历史生成记录 JSON 数组（type/title/content/time，上限 50 条） | HistoryStore.ets:20-22,:27-28,:50-52；MAX=50 :22,:47-49 |
| ai_lesson_store | ai_pending_task | 未完成任务 {type,label,taskId} | GenTask.ets:83-84,:277-285 |
| ai_lesson_store | ai_device_id | 本地随机设备标识 | GenTask.ets:85,:155-160 |
| app_classes | classes | 班级与学生名单（id/name/students[no,name,height,note]） | ClassStore.ets:28-29,:34-35,:51-52 |
| app_accept | disclaimer_accepted | 免责声明已同意标记 | AcceptStore.ets:10-11,:16-17,:27-29 |
| **rev_teaching_watch**（distributedKVStore，**非 Preferences**） | lesson_status / lesson_bundle / watch_hello | 教案环节跨设备同步（分布式 KV） | WatchLink.ets:40-48,:69,:98-99 |

- ★ `ClassStore.ets:3` 注释自称"所有数据仅保存在本机，不上云"——**该注释就 ClassStore 数据本身而言成立**（班级名单确实只进 Preferences，未见于任何上报路径）。但它是**逐模块**结论，绝不能被升格为"App 全部数据仅存本地"。
- ★ WatchLink 用的是 `distributedKVStore` + DISTRIBUTED_DATASYNC，会把教案环节数据**跨设备同步**到同账号的手表端（WatchLink.ets:92-111 pushPlan、:102 sync、:184-191 options）。配置：`bundleName` 写死 `'com.rev.myapplication'`（:179）、`securityLevel S1`、**`encrypt: false`**（:187）。这是"数据离开本机"的真实路径（同一华为账号设备间），协议必须披露，尤其 `encrypt:false`。
- 文件存储（非 Preferences）：
  - `PageDraft.ets:14-16` → `filesDir + '/draft_' + key + '.html'`，按页面 key 存富文本草稿（save/load/clear :19-69）。注释 :7 说明用文件而非 Preferences 是因 Preferences 字符串有 8KB 上限。
  - `ShareService.ets:112-115` → 分享时在 filesDir 生成 zip；:140-160 finally 中删除临时产物与 zip（**用完即删，是"不留存"的有力证据**）。
  - DocxExporter/PptxExporter 导出到沙箱 filesDir（ShareService.ets:50,53,105,107）。
  - 历史记录上限 50 条（HistoryStore.ets:22,47-49），有 clearRecords（:71-75）与 removeRecords（:83-101）——协议可写"用户可自行删除/清空"。
- 应用沙箱外：无。App 不写公共存储目录（系统分享面板目标由用户选择）。

---

## 4. 附件如何产生与去向

- 上限：`AttachService.MAX = 10`（AttachService.ets:16，注释 :15 称"与服务端 MAX_ATTACH 一致"）；服务端 `MAX_ATTACH = 10`（server.js:316）。客户端截断逻辑 AttachService.ets:49-52,61-70，超限提示 `attach.limit`（:71-73）。
- 三个入口（AttachPicker.ets）：
  - 相册多选：`picker.PhotoViewPicker`，IMAGE_TYPE，`maxSelectNumber` = 剩余槽位（AttachPicker.ets:38-52；AttachService.ets:19-26）
  - 文档多选：`picker.DocumentViewPicker`，`maxSelectNumber`（AttachPicker.ets:54-64；AttachService.ets:29-36）
  - 拍照：`cameraPicker.pick` 调系统相机，后置（AttachPicker.ets:66-76；AttachService.ets:39-46）
- 处理（AttachCodec / AttachDoc）：
  - 图片 → **压缩为 JPEG dataURL**：长边 ≤1600（AttachCodec.ets:93,96-101），打包格式 `'image/jpeg'`、`quality: 78`（:105），前缀 `'data:image/jpeg;base64,'`（:122）；失败回退原图 dataURL（:123-126）。
  - 文档 → **提取纯文本**（AttachService.ets:90-97 调 `AttachDoc.extract`）；提取结果空则 `kind='file'`（:94）。
  - 不可解析 → `kind='file'`，只带文件名（AttachService.ets:99-103）。
- 提交结构 `AttachService.toTask`（:121-138，注释称与 server `normalizeAttachments` 对齐）：
  - `kind='image'` → `{ kind:'image', name, data:dataURL }`
  - `kind='text'` → `{ kind:'text', name, text }`
  - 其他 → `{ kind:'file', name }`（**仅文件名，无内容**）
- 去向（两条路径都会出网）：
  1. **后台任务路径**：GenTask.ets:236-238 → `body.attachments = AttachService.toTask(...)` → `POST /api/task`（:239）。服务端存**内存 Map** `taskAttachments`（server.js:313-314），生成结束 finally 中 `delete`（server.js:633-634）——即附件内容**不单独写入 tasks.json 磁盘文件**。
  2. **直连回退路径**：AiService.ets:575-577 `req.attachments = toTask(...)`，POST 到 `ApiConfig.activeBaseUrl()`（:502）。
- 服务端拼装（server.js）：
  - `normalizeAttachments` 校验裁剪：`raw.slice(0, MAX_ATTACH)`（:324）、图片补 dataURL 前缀（:335-337）、文本 **`text.slice(0, 60000)`** 截断（:344）。
  - `buildUserContent`（:359-403）：有图片则构造 OpenAI 多模态数组 `{type:'image_url', image_url:{url: im.data, detail:'high'}}`（:397-401）——**图片以 base64 data URL 直接进入发给 DeepSeek 的请求体**；文档文本以"【附件：文件名】"拼入文本（:383-389）。
  - 请求体上限放宽到 `64mb`（server.js:119）。

---

## 5. 语音输入真实行为（关键）

证据：`entry/src/main/ets/common/VoiceInput.ets`

- 使用 `@kit.CoreSpeechKit` 的 `speechRecognizer`（:9），短语音模式 `recognizerMode:'short'`（:85）。
- ★★ **关键：createEngine 时传 `online: 1`（VoiceInput.ets:84）**。这明确表示使用**在线（云端）语音识别**。因此"语音完全在本机处理、不出设备"**不成立**。
- 引擎自行录音（`recognitionMode: 0`，注释 :4；参数 :171-174），App **不自行采集/保存 PCM 音频流**，音频由系统语音识别服务负责；App 侧**没有**把音频字节打包上传到自建服务器的代码。
- 参数：audioType `'pcm'`、16000Hz、单声道、16bit（:164-169）；vadBegin 2000 / vadEnd 2500 / maxAudioDuration 60000（:172-174）。
- 结果流向：onResult 中间结果 → onPreview 回显（:106-116）；onComplete → onFinal 最终文本（:117-126）；松手 `finish`（:188-201）；上滑 `cancel` 丢弃（:203-217）；释放 `shutdown`（:220-240）。
- 文本用途：`VoiceRemarkBox.ets:192-214` 把识别文本写入备注框，与手工输入文字合并；注释 :5 明确"作为普通文字随请求一起发给模型"——即**识别后的文字会随生成请求发往自建服务器→DeepSeek**。
- 麦克风权限：仅在使用语音时申请（VoiceRemarkBox.ets:82,142 调 `VoiceInput.ensurePermission`；VoiceInput.ets:42-66 先 `checkAccessToken` 再 `requestPermissionsFromUser`）。
- ★ 可安全主张："不保存、不上传音频原始录音到本方服务器"；**不可**主张"语音识别不联网/不涉及第三方"，因为 `online:1` 意味着音频交由系统在线识别服务处理。
- ★ 另注：VoiceInput.ets:7 注释称"Android 侧为同名文件（ArkUI-X 无 CoreSpeechKit，available() 返回 false）"，且 :37-39 `available()` 在**本文件**直接 `return true`。全仓库 glob **仅存在 1 个** VoiceInput.ets，未见任何 Android/平台覆盖实现或 `#if` 分支。故该注释在当前工作树中无法被证实；对 Android 版语音行为的描述需谨慎（只能说"以实际构建物为准"）。

---

## 6. 生成内容去向（完整链路）

证据：`entry/src/main/ets/common/ApiConfig.ets`

- `PROXY_BASE_URL = 'https://rev-on.site:3000/v1/chat/completions'`（:13）
- `SERVER_BASE_URL = 'https://rev-on.site:3000/api'`（:15）
- `PROXY_TOKEN = ''`（:17，当前为空串）
- `MODEL = 'deepseek-flash'`（:19）；`CONNECT_TIMEOUT 10000`（:21）；`READ_TIMEOUT 600000`（:23）；`TEMPERATURE 0.9`（:25）；`MAX_TOKENS 8192`（:27）
- `activeBaseUrl()` 恒返回代理地址（:30-32）
- ★ 密钥安全事实：App **不含任何 DeepSeek API Key**，注释 :5-6 与 AiService.ets:551 均确认"密钥保存在服务端"；鉴权头仅在服务端注入（server.js:184 `'Bearer ' + API_KEY`）。这是可安全主张的正面事实。
- **全项目出网地址扫描**（`*.ets` 内 http(s)/ws 匹配）：
  - `ApiConfig.ets:13,15` — 两个业务地址（唯一的业务出网口）
  - `Settings.ets:15` — `REPO_URL = 'https://gitcode.com/RTX6090/Techingmaster'`（仅展示/跳转）
  - `Settings.ets:435` — AGPL 协议链接
  - `DocxExporter.ets` / `PptxExporter.ets` — OOXML XML 命名空间字符串（非请求）
  ⇒ **App 只与 rev-on.site:3000 通信**（外加系统语音识别服务与华为推送服务）。
- 服务器上游（`server/src/server.js`）：
  - `UPSTREAM = 'https://api.deepseek.com/chat/completions'`（:102，可被环境变量 `UPSTREAM_URL` 覆盖）；`MODEL` 默认 `'deepseek-flash'`（:103）；`API_KEY` 取自 `DEEPSEEK_API_KEY`（:106）。
  - 转发实现 `relay`（:153-234）：透传客户端 messages，注入 Authorization Bearer（:184）；支持流式 SSE 透传（:190-219）。
  - 后台任务用 `fetchDeepSeekStreamed`（:487-636）：POST UPSTREAM（:552-560），`stream:true`（:545），thinking 开关（:547,549-551）。
  - 任务接口 `POST /api/task`（:787-827）：要求 `user` 与 `deviceId` 非空（:791-798），创建任务后 `runTask`（:825），202 返回。
- ★ 结论：用户的提示词、备注、附件（图片 base64 / 文档文本）**全部经自建服务器转发至 DeepSeek 云端**。
- ★ 另有 RAG：`/api/rag/*` 调试接口（:944-988）与 `ragFor` 注入（:420-442,:521-540），会用用户题目文本检索本地课标库并在 prompt 中注入课标片段。

---

## 7. 服务器持久化字段（字段级）

证据：`server/src/tasks.js`

- 文件路径：`DATA_DIR` 默认 `server/data`（:9）；`TASKS_FILE = data/tasks.json`（:10）；`DEVICES_FILE = data/devices.json`（:11）；启动即 `mkdirSync`（:13）。
- 持久化机制：`persist()` 防抖 400ms 后 **`writeFileSync` 全量写入两个文件**（:30-42）；`loadFromFile` 启动加载（:44-45）。⇒ **数据落磁盘，不是纯内存**。

**tasks.json** 每条任务字段（tasks.js:56-80）：
```
id, deviceId, type, label, system, user,
notifySeed, notifyTitle, notifyBody, notifyFailTitle, notifyFailBody,
subject, grade, thinking, reasoning, status,
createdAt, finishedAt, content, error, rag
```
- ★ 其中 `system`（系统提示词）、`user`（**用户完整提示词/备注/文档附件拼装文本**）、`content`（生成结果全文）、`reasoning`（思维链全文）、`deviceId` 都会写入磁盘。server.js:657-663 在完成时 patch 写入 content/reasoning/finishedAt/error；:523 patch 写入 rag 命中信息。
- **保留策略（极易写错）**：`listByDevice` 只**过滤查询结果**——已完成且超过 24 小时的**不再返回给客户端**（tasks.js:98-100），但**记录本身仍留在 tasks.json 磁盘上，代码中并无删除逻辑**。⇒ 协议**不可**写"24 小时后自动删除"；只能写"完成后 24 小时内可再次拉取，超期不再提供"。

**devices.json** 每条字段（tasks.js:154）：`{ id: deviceId, token, updatedAt }`
- 注册校验：deviceId 非空且 ≤200 字符（:145-147）；token 长度 ≥40 且仅 `[A-Za-z0-9_-]`（:131-137,148-152）。
- 失效清理：`forgetInvalidTokens` 依华为返回的 `illegalTokens` 精确删除（:195-215）。

- ★ **当前仓库状态**：`server/data/` 目录**不存在**，`server/.env` **不存在**（实测），仅有 `.env.example`（4727 字节）。⇒ 本地无真实用户数据文件可查；但代码路径确凿。
- 其他内存结构：`tasks`（:15）、`devices`（:16）、`taskAttachments`（server.js:314）、`taskReasoning`（server.js:449）、`taskAborters`/`feedSubs`（server.js:445-447）；限流按 IP 每分钟 120 次，内存 Map `hits`，不持久化（server.js:109,121-134）。

---

## 8. 第三方清单（逐项）

| 第三方 | 用途 | 传输内容 | 证据 |
|---|---|---|---|
| **DeepSeek**（api.deepseek.com） | 文本生成 + 图片视觉理解（多模态 image_url） | system/user 提示词、文档纯文本、**图片 JPEG base64 dataURL** | server.js:102,180-188,277-285,552-560；buildUserContent :397-401 |
| **华为 Push Kit / AGC** | 生成完成/失败的**系统通知**（可退后台送达） | 推送 token、设备标识、通知标题/正文、data{taskId,type,status} | PushToken.ets:12,31；server.js:49-90 `pushToDevice`、:670-706（PUSH_ENABLED 时）；.env.example:22-51 |
| **华为推送消息回执** | 推送送达状态回调 | 由**华为服务器**回调我方 `/api/push/receipt`（非 App 调用），带 `X-HUAWEI-CALLBACK-ID`，HMAC-SHA256 校验 | server.js:884-934；.env.example:77-86 |
| **华为 CoreSpeechKit 语音识别** | 语音转文字 | 音频（**`online:1` = 在线识别**） | VoiceInput.ets:9,84 |
| **华为分布式软总线 / distributedKVStore** | 教案环节跨设备同步到手表 | lesson_bundle / lesson_status / watch_hello，**`encrypt:false`**, securityLevel S1 | WatchLink.ets:16,184-191 |
| **华为 Share Kit** | 系统分享面板分发 docx/pptx/zip | 生成的产物文件（用户主动触发，目标由用户选择） | ShareService.ets:13,43-135 |
| **华为云**（服务器托管） | 托管自建代理服务（TLS 证书路径 `/etc/ssl/rev-on.site/`） | 全部经代理的数据 | server.js:95-99；ApiConfig.ets:13,15 的 `rev-on.site:3000` |
| **GitCode** | 源码托管（仅网页链接，App 内不请求） | 无 | Settings.ets:15；download.html:339 |

- ★ **推送实际默认关闭**：`PUSH_ENABLED = (process.env.PUSH_ENABLED === '1')`（server.js:32，:31 注释"客户端已取消通知/推送功能，默认关闭"）；`GenTask.ets:2` 标题也写"已取消消息通知功能"，:6 注释"不发布任何系统通知"，:311 注释"不产生任何系统通知"。
  **但**：`EntryAbility.ets:70,123-144` 仍会申请通知权限、NotifySlot 仍注册渠道；`PushToken.ets` 仍在启动时申请 token 并上报（EntryAbility.ets:22）。`GenTask.ets` 里 notifyTitle/notifyBody/notifySeed 仍随任务提交（:227-231）。
  ⇒ 事实状态："客户端仍申请并上报推送 token；服务端推送默认处于关闭开关之后"。协议若写"不涉及推送/华为推送"即为**不实**；若写"仅在你主动开启且服务端启用时下发完成通知"则准确。

---

## 9. 五平台构建产物独立确认

实测（按 mtime）：

| 平台 | 产物 | 路径 | 大小 | 时间 | 结论 |
|---|---|---|---|---|---|
| HarmonyOS | **signed .app** | `build/outputs/default/Rev_Techingmaster-default-signed.app` | 2,962,814 B | 2026-10-03 18:16 | **存在** |
| HarmonyOS | unsigned .app | `build/outputs/default/Rev_Techingmaster-default-unsigned.app` | 2,948,097 B | 2026-10-03 18:16 | 存在 |
| HarmonyOS | **signed .hap** | `entry/build/default/outputs/default/entry-default-signed.hap` | 12,211,944 B | 2026-10-04 21:14 | **存在** |
| HarmonyOS | unsigned .hap | `entry/build/default/outputs/default/entry-default-unsigned.hap` | 12,128,992 B | 2026-10-04 21:14 | 存在 |
| Android | **.apk** | `RevTechingMaster-Android.apk`（仓库根） | 57,182,850 B | 2026-10-06 11:10 | **存在** |
| iOS | — | 仅 `.arkui-x/ios` 脚手架（app.xcodeproj、AppDelegate.m、Info.plist、frameworks/.gitkeep 空） | — | — | **无 IPA、无任何可分发包** |
| Windows | — | `Windows/` 为 Electron 源码（main.js 2383B、renderer/、package.json） | — | — | **无 dist 安装包** |
| Linux | — | 无任何构建配置 | — | — | **无** |
| macOS | — | 无任何构建配置 | — | — | **无** |

- **HarmonyOS 签名配置齐全**：`build-profile.json5` 含 signingConfigs material（certpath / keyAlias / profile / storeFile 均指向 `C:\Users\laoyu\.ohos\config\...`，signAlg SHA256withECDSA），products `targetSdkVersion`/`compatibleSdkVersion` 26.0.0，`runtimeOS: HarmonyOS`。⇒ **已签名 .app 可分发**（应用市场或侧载）。
- ⚠️ **`build-profile.json5` 内含明文密钥口令**（keyPassword / storePassword 字段）。属仓库内敏感信息，若源码公开（GitCode）需确认是否已剔除或为调试占位。建议 Lead 不要在站点/协议中引用该文件内容，并提示仓库方核查。
- **Windows**：`Windows/package.json:10` `"dist": "electron-builder --win nsis"`；`build.win.target` 只有 **nsis / x64 一项**（:28-38）；nsis `artifactName: 'RevTechingMaster-Setup-${version}.${ext}'`（:46）；`directories.output = "dist"`（:20-22）。实测 `Windows/dist` **不存在**（全仓库搜索 dist/release/out 目录，仅命中 build 缓存、oh_modules、server/node_modules）。
  ⇒ electron-builder 配置里**只有 win/nsis 一个目标，没有 linux、没有 mac 目标**。Lead 的初步结论**正确**。
- **iOS**：`.arkui-x/arkui-x-config.json5` = `{crossplatform:false,modules:['entry']}`。`.arkui-x/ios` 下为 Xcode 工程脚手架（app.xcodeproj/project.pbxproj、AppDelegate.h/.m、main.m、EntryEntryAbilityViewController、Info.plist、Assets.xcassets、frameworks/.gitkeep 与 arkui-x/.gitkeep 均为空占位），**无 .ipa、无 .framework 实体、无 Podfile、无签名配置**。⇒ "iOS 敬请期待"**成立**。
- **Linux/Mac**：全仓库无 deb/rpm/AppImage/dmg/pkg 相关配置，无 linux/mac electron-builder target，无对应产物。⇒ "Linux/macOS 敬请期待"**成立**。
- ⚠️ **HarmonyOS 卡片结论需要 Lead 决策**：现有 `download.html:257-271` 把 HarmonyOS 标为 badge soon「敬请期待」+「暂未提供下载」，但仓库中**确实存在已签名 .app / .hap**。文案"已随项目源码提供，将随应用市场发布后在此开放下载"（:263）属**主动选择不提供直接下载**，不是"没有产物"。事实层面：**可提供下载（有产物）**；若决定不提供，文案应说明原因（如"等待应用市场上架"），而不能暗示"尚未构建/无法构建"。这与"iOS/Linux/macOS 无任何产物"性质完全不同，不应并列同一 badge。

---

## 10. 「容易被写成假话的点」逐条判定

| # | 可能的说法 | 判定 | 依据 |
|---|---|---|---|
| 1 | "不上传任何数据" | **不成立** | 提示词/备注/附件/生成结果/deviceId 均出网：ApiConfig.ets:13,15；GenTask.ets:239；AiService.ets:502；server.js:180,277,552 |
| 2 | "不收集任何信息" | **不成立** | 收集 deviceId（PushToken.ets:52-54,89-99；GenTask.ets:155,218,225）、Push Token（:31,54）、用户输入的提示词与附件 |
| 3 | "数据仅存在本地" | **不成立** | server/src/tasks.js:36-37 writeFileSync 落盘；数据经代理转 DeepSeek（server.js:102,552） |
| 4 | "不涉及第三方" | **不成立** | DeepSeek（server.js:102）、华为 Push Kit/AGC（server.js:670-706）、CoreSpeechKit `online:1`（VoiceInput.ets:84）、华为云托管（server.js:95-99） |
| 5 | "语音完全在本机识别，不联网" | **不成立** | VoiceInput.ets:84 `online: 1` = 在线识别 |
| 6 | "不上传原始录音到我们服务器" | **成立** | App 无音频上传代码；音频由系统识别引擎处理（VoiceInput.ets:171-178 `recognitionMode:0`，引擎自行录音） |
| 7 | "只申请麦克风权限，不申请隐私权限" | **基本成立但需精确** | module.json5:13-47 仅 4 项，无相册读/通讯录/位置；但含 DISTRIBUTED_DATASYNC（跨设备同步）与通知权限（EntryAbility.ets:70），且相册/文档通过**系统选择器**访问（AttachPicker.ets:38-64），属"用户主动选择，App 不获取全库权限" |
| 8 | "设备标识只含品牌和型号，不含系统版本" | **成立** | PushToken.ets:98 仅 brand + productModel（注释 :87 有误，勿照抄）；但需同时披露 ODID 优先路径（:91-94）与 GenTask 本地随机 ID（GenTask.ets:155） |
| 9 | "附件用完即删、不落盘" | **就服务端任务附件成立** | taskAttachments 仅内存 Map（server.js:313-314），finally 删除（:633-634）；**但**提示词与附件文本已被拼进 `task.user` 并写入 tasks.json（tasks.js:62 + server.js:657-663）⇒ 只能说"附件原文件不单独落盘" |
| 10 | "结果 24 小时后自动删除" | **不成立（措辞需改）** | tasks.js:98-100 只是查询过滤，磁盘记录保留，无删除代码 |
| 11 | "不保存生成记录" | **不成立** | 本地 HistoryStore.ets:50-52 存 50 条；服务端 tasks.json 存 content/reasoning |
| 12 | "不投放广告、不收集设备广告标识" | **成立** | 无广告 SDK；oh-package.json5 依赖仅 `@archermind/exceljs`、`@ohos/jszip`（+dev 测试库）；无 OAID/AAID 调用 |
| 13 | "数据用于训练" | **本方未做，但需谨慎** | 代码中无训练/回流逻辑；但数据经 DeepSeek 处理，其条款不在本方控制 ⇒ 应写"我们不会将你的内容用于模型训练；第三方对其平台内数据的处理适用其自身政策" |
| 14 | "App 不含任何 API 密钥" | **成立** | ApiConfig.ets:5-6,16-17；AiService.ets:551-556；密钥仅在服务端 .env（server.js:106,184） |
| 15 | "不注册账号、不需要登录" | **成立** | 无登录/账号/手机号代码路径；身份仅靠匿名 deviceId |
| 16 | "可完全离线使用" | **不成立** | 所有生成功能均需联网（ApiConfig.ets:13,15） |
| 17 | "跨设备同步是端到端加密" | **不成立** | WatchLink.ets:187 `encrypt: false`，securityLevel S1 |
| 18 | "已取消推送，完全不会收到通知" | **不成立（易写错）** | 服务端默认关闭（server.js:32）但客户端仍申请通知权限（EntryAbility.ets:70,123-144）、仍上报 token（PushToken.ets；EntryAbility.ets:22），可被开启 |
| 19 | "分享不会留存副本" | **基本成立** | ShareService.ets:140-160 finally 清理临时 docx/pptx/zip；注释 :8 说明分享的是 URI 而非文件副本 |
| 20 | "隐私协议可随时删除你的数据" | **需承认现状** | App 侧有 clearRecords/removeRecords（HistoryStore.ets:71-101）与清除草稿（PageDraft.ets:60-69）；**服务端目前无删除接口**（server.js 无 delete 路由，tasks.js 无删除函数）⇒ 应写"可通过应用内清空历史；如需删除服务器侧数据请联系我们" |

---

## 11. 给 Lead 的落地建议（不予执行，仅建议）

- 协议必须含"我们确实会传输"的显式清单：提示词与备注、附件（图片/文档文本）、生成结果与思维链、设备标识（ODID 或品牌-型号；及本地随机 ID）、Push Token。
- 必须逐一点名第三方：DeepSeek（生成+视觉）、华为 Push Kit/AGC（通知，默认关闭）、华为在线语音识别（`online:1`）、华为云（托管）。
- **措辞禁区**：不上传任何数据 / 不收集任何信息 / 数据仅存本地 / 不涉及第三方 / 24 小时后自动删除 / 语音本地识别。
- 下载页：HarmonyOS 需重新定调（有已签名 .app 与 .hap）；Android 可下载；iOS/Linux/macOS/Windows 写"敬请期待"正确。Windows 可注明"Electron 源码位于 `Windows/`，仅配置 win/nsis 目标，可自行构建"。
- ⚠️ **站务缺陷（顺带发现，非本轮任务）**：
  - `download.html:243` 引用 `qr-android.svg`，但 rev-on.site 目录下**该文件不存在**（实测仅 app-screen.jpg / download.html / icon.png / index.html / downloads/RevTechingMaster-Android.apk）⇒ 安卓卡片二维码会显示为破图。
  - `download.html:352` 链接 `privacy.html` 亦**不存在**（本轮 Lead 正在创建）。
  - 站点内 APK 57,181,618 B 与仓库根 APK 57,182,850 B **大小不一致**（疑为两次构建），如强调版本号需统一。

---

## 12. 审计边界声明

- 只读审计，未修改任何文件、未部署、未联网访问 rev-on.site。
- 证据为源码静态分析；未运行 App，故"实际运行时是否完全按代码执行"未经动态验证。
- `VoiceInput.ets:7` 所述 Android 侧同名覆盖文件在当前工作树中不存在，Android 真机语音行为未证实。
- 站点现状（download.html 已存在、privacy.html 缺失、qr-android.svg 缺失、APK 大小差异）为文件系统实测。

---

## 附：第一轮原始任务原文

目标：对 Lead 即将编写的两个新页面做事实审计，确保隐私协议与下载页每一句都有据可依。对象：`rev-on.site/privacy.html`（隐私协议）、`download.html`（下载页，6 平台卡片）。已知关键事实（已由本轮独立复核，见正文）。本轮要求：逐条列清实际行为、数据字段、去向（本地/自建服务器/第三方），附「文件:行号」证据；特别列出容易被写成假话的点；给出字段级数据清单与本地存储清单；核实 iOS/Linux/Mac 及 HarmonyOS/Android/Windows 的构建产物。只读，不修改任何文件，不部署。Lead 写完协议后将进行第二轮逐句核对。

---

# 第二轮：逐句核对（privacy.html 14 节 + download.html 6 卡片）

审计员：privacy-auditor（只读）。核对对象版本：privacy.html 34288 B（2026-10-06 11:35:46）、download.html 18179 B（2026-10-06 11:34:36）。

## R0. 总体判定

**14 项逐句核对中 12 项成立、2 项不成立（1 项严重）。** 未发现任何"措辞禁区"字句残留，未发现任何密钥/口令泄露。两个必须修正的问题：

| 级别 | 位置 | 问题 |
|---|---|---|
| **严重** | privacy.html:463 | 「应用内自助删除：在应用设置中发起」——**App 内不存在该功能**，客户端无任何调用 `/api/data/delete` 的代码，设置页也无入口。属"承诺了做不到的事"。 |
| **中等** | privacy.html:401-403 | 「完成后 24 小时内自动删除」——服务端代码已实现（本轮新核实），但**尚未部署到线上**，且协议未做版本限定。 |

## R1. 逐条核对（Lead 列出的 8 项修正）

### 1. 语音表述 —— **成立**
- privacy.html:308-309「该识别引擎以**在线模式**运行……你的语音需要离开设备交由识别服务处理」⇒ 与 `VoiceInput.ets:84` `online: 1` 一致。
- :310「本应用自身**不保存录音文件，也不把录音上传到开发者的服务器**」⇒ 成立：全项目无音频上传代码；引擎自行录音（`VoiceInput.ets:171-178` `recognitionMode: 0`）。
- :306 提及 `speechRecognizer` 短语音模式 ⇒ 与 `VoiceInput.ets:9,85` 一致。
- :312「识别出的文字一旦随生成请求提交……会发送至开发者服务器」⇒ 与 `VoiceRemarkBox.ets:5,192-214` 一致。
- :378 第三方表单列「语音识别 / 系统语音识别服务方 / 你的语音 / （在线识别）」⇒ **成立**。用"系统语音识别服务方"而非指名厂商，是稳妥处理（App 未绑定具体厂商，由系统决定）。

### 2. 留存期限 —— **技术上成立，但存在部署时效问题**
- 「完成后 24 小时内自动删除」：**代码已实现**。`tasks.js:135` `TASK_RETENTION_HOURS` 默认 24；`:172-215` `purgeExpired()` 对已结束任务按 `finishedAt`（缺失回退 `createdAt`，`:161-164`）超期即 `tasks.delete(id)`（:182）；`:207-209` 删除后 `flushPersist()` **同步落盘**。⇒ 与我第一轮"只有查询过滤、无删除代码"的结论**已过时**，Lead 的更新属实。
- 「失败后 24 小时内」：`isFinishedStatus` 含 DONE 与 FAILED（`tasks.js:156-158`），基准取 `finishedAt` ⇒ 成立。
- 「进行中的任务……不提前删除」：`:177-179` `if (!isFinishedStatus(t.status)) continue; // pending/running 永不清理` ⇒ 成立。
- 「设备标识与推送令牌 / 连续 90 天未上报」：`tasks.js:136` `DEVICE_RETENTION_DAYS` 默认 90；`:188-194` 按 `updatedAt` 超期删除 ⇒ 成立。"未上报"= `updatedAt` 仅在 `registerDevice` 时刷新（`tasks.js:154`）⇒ 表述准确。
- 「下一个清理周期内（通常不超过 10 分钟）」：`tasks.js:140` `PURGE_INTERVAL_MS` 默认 `10*60*1000`；`:278-284` `setInterval` 周期执行；另有启动即清理 `:290-296`；`server.js:886-888` 在任务结束时也会主动 `purgeExpired()` ⇒ **成立**，"通常不超过 10 分钟"甚至偏保守（任务完成时即会触发一次清理）。
- :412「清理会同时从内存与磁盘上移除记录」：内存 `tasks.delete` + `flushPersist()` 重写文件（`tasks.js:36-37,207-209`）；旁挂 Map 由 `setTaskPurgeHook` 清理（`:142-153,196-205`；`server.js` 注册）⇒ 成立。
- :410「服务器留存的窗口与应用内可见的窗口是一致的」：`tasks.js:312` 现在用 `TASK_RETENTION_MS` 统一（注释 `:125` 明确"客户端可见性与磁盘留存同步为同一期限"）⇒ 成立。
- ⚠️ **但：本工作树未部署。** Lead 已说明线上 `123.60.130.45` 尚未更新。若线上仍是旧版 `server.js`/`tasks.js`，则线上**没有**任何删除逻辑，协议此节对线上服务而言为**超前声明**。判断与建议见 R3。

### 3. 主动删除 —— **接口成立，客户端不成立（严重）**
- 服务端接口**确实存在**：`server.js:924` `app.post('/api/data/delete', checkToken, ...)`；`tasks.js:237-275` `deleteByDevice()`；空 deviceId 保护 `:239-242`；只删完全相等 deviceId `:246`；连 devices 记录一起删 `:253-256`；同步落盘 `:270`。先中断运行中任务 `server.js:931-948` ⇒ 实现严谨。
- privacy.html:461-465 列出两种方式：①「应用内自助删除（在应用设置中发起）」②「联系我们」。
  **①不成立**：全仓库 `*.ets` 搜索 `data/delete|deleteServerData|删除服务器数据` —— **0 命中**；`Settings.ets` 仅有语言/主题/字号/关于（`Settings.ets:124-192,385-403`），**无任何删除服务器数据的入口**。
  ⇒ 该句描述了一个**当前版本 App 里不存在的按钮**。
- privacy.html:467「设备标识……可在应用设置或「关于本应用」中查看」——**同样不成立**：`Settings.ets:385-403` 的「关于」区块无展示 deviceId 的代码；`GenTask.deviceId()` 的结果仅存 Preferences（`GenTask.ets:141-165`），全项目无任何 UI 读取它展示。
- **建议替换句**（二选一）：
  - 若不动客户端：把 ① 删掉，改为「**联系我们**：通过第 14 节提供你的设备标识申请删除，我们会在收到后尽快手动删除。」并把 467 行的"应用设置中查看"改为「可在联系我们时由我们协助定位」。
  - 若要保留 ①：必须先实现客户端入口（设置页加按钮 → `POST /api/data/delete`）并重新构建 APK，否则不要再上线该句。
- ②「联系我们」**成立**：privacy.html:505-506 给出了 GitCode Issue 与仓库地址，是可用的联系方式。

### 4. 设备标识 —— **成立**
- privacy.html:356「系统提供的 odID；若不可用则退化为「品牌-型号」（**不含系统版本**）」⇒ 与 `PushToken.ets:91-94`（优先 ODID）、`:98`（brand + productModel）一致，**且正确避开了 :87 注释的"系统版本"错误**。这是本轮最关键的修正之一，已核实无误。
- :357「本地任务标识 / 应用在本机生成的随机字符串 / 不含设备硬件信息」⇒ 与 `GenTask.ets:155`（`'d'+Date.now().toString(36)+随机`）一致。
- :361「两者都不包含你的姓名、手机号、账号或通讯录信息……不要求注册或登录，因此服务器无法将数据对应到具体自然人，只能对应到设备」⇒ 成立；与我第一轮结论一致（无登录路径）。
- :362 列出服务器保存字段（任务内容、提示词、生成结果、思考过程、设备标识、推送令牌）⇒ 与 `tasks.js:56-80` 字段表一致（system/user/content/reasoning/deviceId + devices.json 的 token）。
- ⚠️ 提示：odID 本身在部分法域被视为设备标识符/个人信息。"不包含姓名手机号"是准确的；协议未声称"odID 不是个人信息"，措辞稳健，无需修改。

### 5. 推送 —— **成立**
- privacy.html:385「需要你在系统设置中授予通知权限；若你未授权或曾拒绝，通知不会送达，但生成功能不受影响」⇒ 与 `EntryAbility.ets:123-144` 一致（`isNotificationEnabled` → `requestEnableNotification`，失败静默不影响启动）。
- :386「开发者服务器的推送总开关默认关闭；仅当部署方启用推送且你已授权时，才会下发完成通知」⇒ 与 `server.js:32` `PUSH_ENABLED = (process.env.PUSH_ENABLED === '1')` 一致；未启用时节 `:670,699` 跳过 ⇒ 成立。
- :298 权限表单列「通知 / 首次启动后」⇒ 与 `EntryAbility.ets:70` 一致（在 `loadContent` 回调中调用）。**成立**，且正确呈现为与 module.json5 权限并列的运行时授权。
- :379 第三方表「推送服务 / 华为 Push Kit / 设备推送令牌 / 发送「生成完成」通知」⇒ 与 `PushToken.ets:12,31,52-54`、`server.js:49-90` 一致。

### 6. 流转 —— **成立**
- privacy.html:303「走系统的分布式数据同步能力（安全等级 S1），**并未额外做端到端加密**，因此请勿用于传输高度敏感的内容」⇒ 与 `WatchLink.ets:187` `encrypt: false`、`:190` `SecurityLevel.S1` 逐字一致。**"并未额外做端到端加密"的措辞比我建议的更准确**（区分了"系统通道"与"额外 E2EE"）。
- :296 权限表「多设备协同 DISTRIBUTED_DATASYNC / 首次使用「流转」时 / 把生成结果流转到平板 / 2in1 继续编辑」⇒ 用途原文与 `string.json:20-22` 完全一致。

### 7. 「我们不做什么」 —— **成立**
- 「不读取广告标识（OAID / AAID）」⇒ 成立：全项目无 OAID/AAID 调用；`oh-package.json5` 依赖仅 `@archermind/exceljs`、`@ohos/jszip`（+dev 测试库），无广告/统计 SDK。
- 「不需要注册账号：不收集手机号、邮箱、身份证」⇒ 成立（无登录代码路径）。
- 「不将你的内容用于模型训练……该方是否用于训练适用其自身政策」⇒ **成立且措辞得当**，正确加上了我第一轮要求的限定语。
- 「不保存录音文件」⇒ 成立（同 R1.1）。
- 「不采集学生个人隐私：不设学生端」⇒ 成立（App 无学生端页面；`module.json5` 无相关权限）。
- 「不扫描相册或文件」⇒ 成立（`AttachPicker.ets:38-64` 走系统选择器，非全库权限）。

### 8. 权限原文照抄 + INTERNET 说明 —— **成立**
- privacy.html:294-298 权限表：
  - 「网络 INTERNET / 安装后联网调用 AI / 调用 AI 生成、同步后台任务结果、接收完成通知」⇒ 正确，且**补上了 module.json5 缺失的 reason**（`module.json5:14-16` 确实无 reason 字段）。:289 也点明"除网络权限外，其余权限均在你实际使用对应功能时才申请"。
  - 「麦克风 MICROPHONE / 首次按住「语音输入」时 / 把语音转成备注文字」⇒ 与 `string.json:16-18` 原文逐字一致；申请时机与 `VoiceRemarkBox.ets:82,142` 一致。
  - 「多设备协同 / 振动 VIBRATE / 手表端上课计时提醒 / 上课环节到点时震动提醒」⇒ 与 `string.json:23-26` 原文一致。
  - :289「只申请以下系统权限」+ 表内 5 行（4 项 module.json5 权限 + 通知）⇒ **与 `module.json5:13-47` 精确一致，无遗漏无多报**。

## R2. Lead 另请核对的 3 项

### 2.1 措辞禁区残留扫描 —— **无残留（全部通过）**
对 privacy.html / download.html / index.html 全文 grep：
`不上传任何数据`、`不上传任何`、`不收集任何信息`、`不收集任何`、`数据仅存`、`仅存本地`、`仅保存在本地`、`不涉及第三方`、`语音完全在本机`、`24 小时后自动删除`、`完全离线`、`离线使用`、`无需联网`、`本地识别` —— **全部 0 命中**。

3 处"命中"经人工复核**均为合法用法**，非禁区：
- `privacy.html:309`「并非纯**本机识别**」——否定式，正确。
- `privacy.html:303`「并未额外做**端到端加密**」——否定式，正确。
- `privacy.html:336`「班级名单**不上传**」+ :423/:467「**不收集**手机号、邮箱、身份证」——**范围限定式**，与事实一致（班级名单确实只进 `app_classes` Preferences，见第一轮 §3）。⇒ 成立。
- 另核 `index.html:339`「名单与历史，只存本机」、`:410`「数据在本地、不上云」⇒ 均带主语限定（"名单与历史"/"班级名单、历史记录、设置项"），未升格为全量声明，**成立**。
  - 佐证：App 内水印 `I18n.ets:64` `'mine.local'`「所有数据都在你自己手机上，不上云」出现在 `ClassDetail.ets:211`、`Index.ets:783`；`hint.safety`「请勿输入真实学生隐私信息用于演示」（`I18n.ets:250`）出现在 `Analysis.ets:625`、`Report.ets:561`。⇒ privacy.html:365「应用内也提示"请勿输入真实学生隐私信息用于演示"」**成立**（逐字一致）。

### 2.2 密钥/口令泄露扫描 —— **未泄露（全部通过）**
对站点 `*.html` + `*.svg` grep：`keyPassword`、`storePassword`、`DEEPSEEK_API_KEY`、`PROXY_TOKEN`、`private_key`、`BEGIN PRIVATE KEY`、`AGC_JWT`、`certpath`、`p12`、`p7b`、`password`、`secret`、`token=`、`Bearer ` —— **全部 0 命中**。
- `sk-` 有 6 处命中，经复核**全部是 CSS 误报**：`mask-image:radial-gradient(...)` 中的 `-image` 片段（privacy.html:85-86、download.html:89-90、index.html:91-92），**不是密钥**。
- ⇒ **确认网页未泄露 `build-profile.json5` 的明文口令，也未泄露任何 API Key**。Lead 仅在线下交付说明中提示用户的做法正确。

### 2.3 download.html 六卡片定性 —— **全部成立**
| 卡片 | 页面定性 | 事实 | 判定 |
|---|---|---|---|
| Android | badge ok「现已提供」(:242)，链接 `downloads/RevTechingMaster-Android.apk` (:249) | 站点内 APK 57,181,618 B 实测存在 | **成立** |
| HarmonyOS | badge next「即将上架」(:267)，描述「已开发完成并通过构建，正在准备上架应用市场」(:265) | signed `.app` 2,962,814 B（2026-10-03 18:16）与 signed `.hap` 12,211,944 B（2026-10-04 21:14）**实测均存在** | **成立**（见下方注） |
| iOS | badge soon「敬请期待」，「iOS 版本仍在规划中」(:281) | 全仓库 `.ipa` 计数 = **0**；仅 `.arkui-x/ios` 脚手架 | **成立** |
| Windows | badge soon「敬请期待」，「桌面版基于 Electron 开发，安装包正在打包验证中」(:296) | `Windows/dist` **不存在**；`package.json:28` 仅 `"win"` 目标（nsis/x64） | **成立** |
| Linux | badge soon「敬请期待」，「仍在规划中」(:312) | 无 linux target、无产物 | **成立** |
| macOS | badge soon「敬请期待」，「仍在规划中」(:327) | 无 mac target、无产物 | **成立** |

- 「即将上架」定性**准确且优于上一版"敬请期待"**：如实反映"包已产出、尚未上架"这一中间状态，与 iOS/Linux/macOS 的"无产物"明确区分，且 badge 样式独立（`.badge.next` 定义于 :137-138）。
- 注：描述用「已开发完成并通过构建」，未断言"已提交审核"或"已上架"⇒ 无过度承诺。建议若后续仍长期未上架，可考虑改为「已完成构建，上架筹备中」以降低时效风险，但**当前措辞本身不构成不实**。
- 页头 :217-218「1 个平台可下载 / 5 个平台开发中」⇒ 算术正确（6 卡片 = 1 可下载 + 5 未提供）。
- :229「标为「敬请期待」的平台尚未提供构建产物」⇒ 准确（该句只覆盖 badge soon 的 4 个平台，未误伤 HarmonyOS）。
- `qr-android.svg` **现已存在**（2,535 B，2026-10-06 11:12:58），且经检视是**真实二维码**（`<svg ... class="segno">` + QR path 数据）⇒ 第一轮发现的破图问题**已修复**。

## R3. 关于「线上尚未部署」的判断（Lead 明确询问）

**结论：当前表述属"技术上已实现、但对线上服务超前"，建议加一行版本/部署限定，不必删改主体。**

理由：
1. 协议末尾 :509 写「本协议自 2026 年 10 月 6 日起生效」，:496-497 又有"功能变化时更新协议"的变更条款。若线上仍是旧版服务端（无 `purgeExpired` 路径），则 24h/90d 条款在生效日为**不实陈述**。
2. 但代码已在工作树中实现、`retention-dev` 有测试覆盖、Lead 已独立复跑 116/116 与跨设备隔离 15/15 ⇒ 属"即将上线"，不是"设计中的设想"。
3. 隐私协议面向**用户实际使用的服务**，因此判断标准应是"线上行为"，而非"仓库行为"。

**建议（最小改动，二选一）：**
- **方案 A（推荐）**：在 §7 末尾加一句限定，例如：
  > 「上述自动清理与自助删除能力随服务端 v2 上线；在此之前提交的历史数据，我们会在该版本上线时一并清理，并在本协议中同步更新生效日期。」
  同时把 :463 的「应用内自助删除」按 R1.3 处理（该功能客户端确实还没有）。
- **方案 B**：先部署服务端（不含客户端改动），确认线上 `/api/data/delete` 可用且 `purgeExpired` 生效后，再上线本协议；此时仅需按 R1.3 删掉「应用内自助删除」一条。

无论哪种方案，**R1.3 的 `:463` 与 `:467` 都必须先改**——那与部署无关，是当前客户端的事实状态。

## R4. 本轮发现的其它小项（不影响定性，供参考）

1. `privacy.html:388`「14 份《义务教育课程方案和课程标准（2022 年版）》检索库（共 1428 个条目块）」⇒ **成立**：`server/rag/meta.json` `files` 数组实测 **14 项**、`totalChunks` = **1428**。逐字核对无误。
2. `privacy.html:476`「客户端与服务器之间使用 HTTPS」⇒ 成立：`ApiConfig.ets:13,15` 均为 `https://`；服务端 TLS 配置见 `server.js:94-99`（证书就绪则 HTTPS）。注：线上实际是否启用 TLS 取决于部署，我未联网验证，建议 Lead 自行确认。
3. `privacy.html:478`「中转服务支持访问令牌与频率限制」⇒ 成立：`server.js:141-150` checkToken、`:121-134` 限流。注：`ApiConfig.ets:17` `PROXY_TOKEN = ''` 目前为空 ⇒"支持"而非"已启用"，措辞准确。
4. `privacy.html:294` 把 INTERNET 申请时机写为"安装后联网调用 AI"⇒ 属描述性表述（该权限为安装即授予），无实害。
5. `privacy.html:321`「卸载应用即全部删除」⇒ 对应用私有目录成立（Preferences 与 filesDir 随卸载清除）；**但**跨设备同步到手表端的 `rev_teaching_watch` 数据在手表上，卸载手机端不会清除手表副本。若追求严谨可加"手表端副本需在手表上卸载应用清除"。当前措辞影响很小，列为可选。
6. `download.html` 站点内 APK 与仓库根 APK 仍**不一致**（57,181,618 vs 57,182,850 B）。:251 的 `apkmeta` 由 HEAD 请求动态取实际大小（`download.html:386-395`），故页面显示会与实际一致；仅当文案提到具体版本号时需留意。

## R5. 第二轮审计边界

- 只读：未修改任何文件、未部署、未联网访问 rev-on.site 或线上 123.60.130.45。
- 全部结论基于源码与站点文件的静态检查。**线上服务端实际行为未验证**（R3 的判断即以此为据，故建议加限定）。
- 未运行 App，故 `:463`/`:467` 的"客户端无此功能"结论基于全仓库 `.ets` 全文检索（0 命中）+ 设置页逐行阅读，可信度高，但不排除存在未纳入 `entry/src/main/ets` 的其它客户端代码路径。
