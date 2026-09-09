# Rev TechingMaster

面向初中教师的鸿蒙原生教学备课智能体（同步产出安卓版 APK 与 Windows 桌面版），将教案撰写、课件大纲、分层练习、学情分析、排座位、家校沟通等日常事务集成到一个应用中，由 AI 协助完成初稿，教师改动后使用。

本项目为 2026 年无锡市“人工智能 + 教育”创新应用技能大赛参赛作品（智能体开发方向），使用 HarmonyOS 原生 ArkTS 开发，Windows 桌面版基于 Electron 复刻，核心代码遵循 AGPL-3.0 协议开源。

## 功能特性

应用采用三个底部页签组织功能：备课助手、家校沟通、我的。

| 模块 | 功能 | 说明 |
| --- | --- | --- |
| 教案 | AI 生成教学设计 | 支持学科、年级、课题、课型及备注输入，备注会随请求传给 AI |
| 课件大纲 | AI 生成逐页 PPT 大纲 | 输出结构化 JSON（豁免 AI 尾注，保证可直接解析） |
| 分层练习 | AI 生成分层练习 | 覆盖不同能力层级的学生 |
| 教研科研 | AI 辅助教研写作 | 页面底部带学术诚信警示水印 |
| 学情分析 | AI 分析班级学情 | 支持 Excel 数据粘贴与文件导入 |
| 排座位 | 智能排座 | 按身高贪心蛇形算法排座、点击互换、左右护法位；可一键导入班级名单，也可把当前身高名单保存（合并更新）回班级 |
| 沟通话术 | AI 生成家校沟通话术 | 面向家长沟通场景 |
| 学情报告 | AI 生成学生报告 | 可导出为 Word |
| 历史记录 | 查看历史生成 | 按模块分类保存，可重新查看、复制或导出 |
| 班级管理 | 班级与名单管理 | 新建/重命名班级、Excel/Word 名单导入并自动解析学号/姓名/身高 |
| 设置 | 语言与主题 | 五语言界面（中/英/维吾尔/藏/蒙古）；浅色/深色/跟随系统；开源仓库入口 |

### 统一的责任提示机制

所有 AI 生成内容都会在服务层统一追加标注“（AI生成，仅供参考）”，教案、研究报告、分层练习、沟通话术等全部生效，唯一例外是课件大纲的 JSON 输出。首次启动弹窗免责声明，5 秒倒计时后可“同意并继续”，“不同意”即退出；同意后本地记忆不再提示。

### 少数民族语言适配

中英之外内置维吾尔语、藏语、蒙古语三套完整界面词典（各 205 键），并随包携带对应字体（藏文乌金体、维吾尔 UKIJMejT、Noto Sans Mongolian）在启动时注册，界面文字不依赖设备系统字体；切换语言即时生效，缺词自动回退中文。

### 数据本地优先

班级名单、历史记录、设置项全部保存在手机本地，不上传任何云端；“我的”页面与班级详情页内置“数据在本地、不上云”水印。

## 页面路由

```
pages/Splash        启动动画页（粒子汇聚 + 华为云支持品牌行）
pages/Index         主界面（三页签）
pages/Plan          教案
pages/Courseware    课件大纲
pages/Quiz          分层练习
pages/Research      教研科研
pages/Analysis      学情分析
pages/Talk          沟通话术
pages/Report        学情报告
pages/Seats         排座位（班级名单联动）
pages/ClassManager  班级管理
pages/ClassDetail   班级详情
pages/History       历史记录
pages/Settings      设置
```

## 技术架构

| 层面 | 选型 |
| --- | --- |
| 开发语言 | ArkTS（声明式 UI），Stage 模型 |
| 系统版本 | HarmonyOS，targetSdk / compatibleSdkVersion 6.0.0(20) |
| AI 接入 | 自建中转代理（`server/`）→ DeepSeek 开放接口（SSE 流式 + 轮询兜底），默认模型 deepseek-v4-flash |
| 本地存储 | Preferences（设置、历史、班级名单、免责声明状态） |
| 文档能力 | 自研 OOXML 导出（Word、PPT 骨架模板）、ExcelJS 读写（xlsx）、jszip 解析（docx） |
| 多语言 | I18n 五词典（zh/en/ug/bo/mn）＋按语言切换的内置字体 |
| 第三方依赖 | @archermind/exceljs、@ohos/jszip |

AI 请求采用服务端 SSE 流式输出（客户端自研 `SseClient.ets` 处理；流程：提交任务 → 订阅 feed 接收 open/chunk/done 事件），失败时自动回退到任务轮询兜底（每 2 秒轮询一次、最多 450 次），App 被杀后重启会自动恢复未完成任务；对“HTTP 200 但内容异常 / 长度截断”给出明确错误提示。界面内置自研 Markdown 渲染组件，支持标题、列表、表格、代码块等块级语法。

## 目录结构

```
Rev_Techingmaster/
├── AppScope/                     # 应用级配置（图标、启动图等）
├── entry/                        # 鸿蒙主模块
│   └── src/main/
│       ├── ets/
│       │   ├── entryability/     # 应用入口 Ability
│       │   ├── pages/            # 各功能页面
│       │   └── common/           # AI 服务、代理配置、字体、主题、五语言词典、存储、通用组件
│       └── resources/            # 资源与路由配置（rawfile/fonts 内置字体）
├── server/                       # AI 中转代理（Node.js，密钥只存这里）
├── fonts/                        # 少数民族字体源文件与《字体清单》
├── keys/                         # 签名证书（请勿提交到公开仓库）
├── oh-package.json5              # 工程与依赖声明
├── build-profile.json5           # 构建与签名配置
└── LICENSE                       # AGPL-3.0
```

核心逻辑集中在 `entry/src/main/ets/common/`：`AiService.ets`（请求 + 统一 AI 尾注）、`ApiConfig.ets`（代理地址与共享令牌，无密钥明文）、`AppFonts.ets`（按语言选字体）、`I18n.ets` 与 `*Dict.ets`（五语言词典）、`ClassStore.ets`/`HistoryStore.ets`/`AcceptStore.ets`（本地数据）。

## 环境与构建（HarmonyOS）

1. 安装 DevEco Studio（含 HarmonyOS SDK 26）。
2. 打开工程根目录，等待依赖同步完成（必要时执行 `ohpm install`）。
3. 连接已开启开发者模式的 HarmonyOS 设备，选择 entry 运行；或命令行构建：

```powershell
$env:DEVECO_SDK_HOME='<DevEco Studio 安装目录>\sdk'
& '<DevEco Studio 安装目录>\tools\node\node.exe' '<DevEco Studio 安装目录>\tools\hvigor\bin\hvigorw.js' --mode module -p module=entry@default -p product=default -p requiredDeviceType=phone assembleHap --analyze=normal --parallel
```

## 环境与构建（Android，基于 ArkUI-X）

安卓构建在独立副本 `Desktop\RevTechingX_Android` 中进行（原鸿蒙工程不受影响），产物 `RevTechingMaster-Android.apk` 位于项目根目录。依赖：`D:\ArkUI-X`（ArkUI-X SDK 26）、`D:\ADB`（Android SDK）、已配置的 `ace` 工具链。

```powershell
cd C:\Users\laoyu\Desktop\RevTechingX_Android
ace build apk      # 增量约 30 秒；产物在 .arkui-x\android\app\build\outputs\apk\release\
```

跨端适配说明：工程经 `ace modify` 转换；已移除鸿蒙专用的备份扩展；跳转改用 UIContext 路由；安卓清单允许对 AI 代理的明文 HTTP 请求。图标与鸿蒙一致（由同一 background/foreground 合成）。

## AI 服务配置与安全

- DeepSeek API Key 只存在于 `server/.env` 的 `DEEPSEEK_API_KEY`，前端源码无任何密钥明文；部署与配置见 `server/README.md`。
- 前端请求地址统一为 `ApiConfig.PROXY_BASE_URL`（默认 `http://123.60.130.45:3000/v1/chat/completions`）。
- 强烈建议在服务器 `.env` 设置 `PROXY_TOKEN`，并同步填写到 `ApiConfig.PROXY_TOKEN`，防止代理被滥用；正式演示前为服务器配置 HTTPS，并把前端地址改为 `https://`。
- 曾随早期安装包分发的直连密钥应已在 DeepSeek 开放平台重置；`keys/` 目录的签名证书勿提交公开仓库。

## 开源许可

本项目基于 GNU Affero General Public License v3.0 开源，完整条款见 [LICENSE](LICENSE) 与 <https://www.gnu.org/licenses/agpl-3.0.html>。
