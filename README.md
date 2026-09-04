# Rev TechingMaster

面向初中教师的鸿蒙原生教学备课智能体，将教案撰写、课件大纲、分层练习、学情分析、排座位、家校沟通等日常事务集成到一个应用中，由 AI 协助完成初稿，教师改动后使用。

本项目为 2026 年无锡市“人工智能 + 教育”创新应用技能大赛参赛作品（智能体开发方向），使用 HarmonyOS 原生 ArkTS 开发，核心代码遵循 AGPL-3.0 协议开源。

## 功能特性

应用采用三个底部页签组织功能：备课助手、家校沟通、我的。

| 模块 | 功能 | 说明 |
| --- | --- | --- |
| 教案 | AI 生成教学设计 | 支持学科、年级、课题、课型及备注输入，备注会随请求传给 AI |
| 课件大纲 | AI 生成逐页 PPT 大纲 | 输出结构化 JSON，便于后续制作课件 |
| 分层练习 | AI 生成分层练习 | 覆盖不同能力层级的学生 |
| 教研科研 | AI 辅助教研写作 | 页面底部带有学术诚信警示水印 |
| 学情分析 | AI 分析班级学情 | 支持 Excel 数据粘贴与文件导入 |
| 排座位 | 智能排座 | 按身高使用贪心蛇形算法生成座位表，支持点击互换、左右护法位单独指定 |
| 沟通话术 | AI 生成家校沟通话术 | 面向家长沟通场景 |
| 学情报告 | AI 生成学生报告 | 可导出为 Word |
| 历史记录 | 查看历史生成 | 按模块分类保存，可重新查看、复制或导出 |
| 班级管理 | 班级与名单管理 | 支持新建班级、Excel/Word 名单导入并自动解析学号、姓名、身高 |
| 设置 | 语言与主题 | 中英双语界面；浅色 / 深色 / 跟随系统三种主题；关于信息 |

### 统一的责任提示机制

所有 AI 生成内容都会在服务层统一追加标注“（AI生成，仅供参考）”（英文界面为英文对应文案），教案、研究报告、分层练习、沟通话术等模块全部生效，唯一例外是课件大纲的 JSON 输出，以保证结构化数据不被破坏。首次启动时应用会弹出免责声明，需阅读 5 秒后方可同意，点击“不同意”将退出应用。

### 数据本地优先

班级名单、历史记录、设置项全部保存在手机本地，不上传任何云端；“我的”页面与班级详情页内置数据本地化水印说明。

## 页面路由

```
pages/Splash        启动动画页（粒子汇聚）
pages/Index         主界面（三页签）
pages/Plan          教案
pages/Courseware    课件大纲
pages/Quiz          分层练习
pages/Research      教研科研
pages/Analysis      学情分析
pages/Talk          沟通话术
pages/Report        学情报告
pages/Seats         排座位
pages/ClassManager  班级管理
pages/ClassDetail   班级详情
pages/History       历史记录
pages/Settings      设置
```

## 技术架构

| 层面 | 选型 |
| --- | --- |
| 开发语言 | ArkTS（声明式 UI），Stage 模型 |
| 系统版本 | HarmonyOS，targetSdk / compatibleSdkVersion 26.0.0 |
| AI 接入 | DeepSeek 开放接口（OpenAI 兼容格式），默认模型 deepseek-v4-flash |
| 本地存储 | Preferences（设置、历史、班级名单、免责声明状态） |
| 文档能力 | 自研 OOXML 导出（Word）、ExcelJS 读写（xlsx）、jszip 解析（docx） |
| 第三方依赖 | @archermind/exceljs、@ohos/jszip |

AI 请求采用非流式单次请求以保障稳定性：禁用思考链以缩短等待时间，超时自动重试最多 3 次，并对“HTTP 200 但内容异常”等情况给出明确错误提示。界面内置自研 Markdown 渲染组件，支持标题、列表、表格、代码块等块级语法。

## 目录结构

```
Rev_Techingmaster/
├── AppScope/                     # 应用级配置（bundle、图标）
├── entry/
│   └── src/main/
│       ├── ets/
│       │   ├── entryability/     # 应用入口 Ability
│       │   ├── pages/            # 各功能页面
│       │   └── common/           # AI 服务、提示词、主题、i18n、存储、通用组件
│       └── resources/            # 资源文件与路由配置
├── keys/                         # 签名证书（请勿提交到公开仓库）
├── oh-package.json5              # 工程与依赖声明
├── build-profile.json5           # 构建与签名配置
└── LICENSE                       # AGPL-3.0
```

核心逻辑集中在 `entry/src/main/ets/common/`：`AiService.ets` 负责 AI 请求与统一尾注，`Prompts.ets` 维护各模块提示词，`AppTheme.ets` 提供主题色板，`I18n.ets` 维护中英文字典，`ClassStore.ets`、`HistoryStore.ets` 等负责本地数据。

## 环境与构建

1. 安装 DevEco Studio（含 HarmonyOS SDK 26）。
2. 打开工程根目录，等待依赖同步完成（必要时在终端执行 `ohpm install`）。
3. 连接已开启开发者模式的 HarmonyOS 设备，选择 entry 模块运行；或执行命令行构建：

```powershell
$env:DEVECO_SDK_HOME='<DevEco Studio 安装目录>\sdk'
& '<DevEco Studio 安装目录>\tools\node\node.exe' '<DevEco Studio 安装目录>\tools\hvigor\bin\hvigorw.js' --mode module -p module=entry@default -p product=default -p requiredDeviceType=phone assembleHap --analyze=normal --parallel
```

## AI 服务配置与安全

AI 相关配置集中在 `entry/src/main/ets/common/ApiConfig.ets`：包括接口地址、模型名（默认 `deepseek-v4-flash`）、API Key、超时与最大输出长度。正式发布前请阅读该文件顶部的安全说明：

- 演示版本地保存了 DeepSeek API Key，仅用于参赛演示，请勿将含密钥的源码直接公开；
- 正式发布建议改为“服务端代理”方式，密钥只保存在服务器，应用仅请求代理地址；
- 可在 DeepSeek 开放平台后台随时重置密钥；`keys/` 目录下的签名证书同样不应提交到公开仓库。

## 开源许可

本项目基于 GNU Affero General Public License v3.0 开源，完整条款见 [LICENSE](LICENSE) 与 <https://www.gnu.org/licenses/agpl-3.0.html>。
