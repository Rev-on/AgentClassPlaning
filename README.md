# Rev TechingMaster 初中教学备课智能体

面向初中教师的 AI 教学助手，2026 年无锡市“人工智能 + 教育”创新应用技能大赛参赛作品。AI 生成初稿、教师修改使用，把教案、课件、练习、学情、排座、家校沟通等日常事务集成到一个应用。

## 核心功能

- **智能备课**：AI 逐页生成整份 HTML 课件（统一 CSS 样式，16:9 预览不溢出，可导出 PPTX）、教案、分层练习、教研文章。
- **学情与班级**：Excel 导入成绩做学情分析并生成 Word 报告；班级名单管理；身高蛇形算法智能排座，支持点击互换。
- **家校沟通**：AI 生成家长沟通话术。
- **新课标 RAG**：14 份《义务教育课程方案和课程标准（2022 年版）》原文、1428 个条目块，纯内存 BM25 注入；未收录学科不拿其它学科顶替。
- **责任机制**：所有 AI 内容统一标注“（AI生成，仅供参考）”，首次启动 5 秒倒计时免责声明。
- **多语言**：中、英、维吾尔、藏、蒙古五语言界面（中英各 378 条键，维/藏/蒙各 372 条，少数缺项自动回退中文），内置藏文乌金体与维吾尔 UKIJMejT 字体（蒙古语为西里尔文，用系统字体），数据本地优先、不上云。

## 技术架构

鸿蒙原生 ArkTS（Stage 模型）开发，同步产出 Android（ArkUI-X）与 Windows（Electron）版本。AI 经自建 Node.js 中转代理（`server/`）访问 DeepSeek，SSE 流式输出并带轮询兜底，App 重启自动恢复未完成任务；API Key 只存服务端。支持自研 OOXML 导出 Word/PPT、ExcelJS 读写名单。

```
App（ArkTS / Electron）
  │ ① POST /api/task            提交后台任务，立即返回 taskId
  │ ② GET  /api/task/:id/feed   SSE 流式增量（open/think/chunk/done）
  │ ③ GET  /api/task/:id        轮询兜底
  ▼
server/（Node 18 + Express，持有 DeepSeek Key）
  │ ├─ RAG：14 份 2022 版新课标 → 1428 个条目块 → 纯内存 BM25 注入
  │ └─ 任务队列（并发 2）+ JSON 持久化
  ▼
DeepSeek（deepseek-flash）
```

- **生成与页面解耦**：任务提交到服务端后台执行，杀进程后仍在服务器继续；重进页面经 `GenSession` 恢复“生成中/结果”，冷启动由 `GenTask.recover()` 静默接管。
- **新课标 RAG**：教案/练习/课件任务自动检索课标原文注入提示词。库中未收录的学科（如体育、日语）**不拿其它学科顶替**，改为注入“严禁编造课标条文”的硬约束。
- **多端**：手机 / 平板 / 2in1（上下分屏）/ 手表（分环节计时）；`Duo2in1`、`WatchLink`、`ContinuationService` 等平台专属能力集中在单一接缝文件中。

## 目录结构

```
entry/            鸿蒙主模块（ArkTS，68 文件 / 约 1.9 万行）
  src/main/ets/
    pages/        16 个页面（Splash / Index / Plan / Courseware / Seats ...）
    common/       服务与工具层（AiService / GenTask / I18n / DocxExporter / PptxExporter ...）
AppScope/         应用级资源与图标（分层图标 layered_image）
server/           AI 中转代理 + 新课标 RAG 索引
Windows/          Electron 桌面版
teching/          14 份《义务教育课程方案和课程标准（2022 年版）》PDF
docs/             课件大纲 JSON 使用教程、实况窗接入方案图、实况窗后台进度功能说明
```

## 实况窗：后台实时显示生成进度

7 大 AI 功能生成中，用户**退到后台**后桌面实况窗（Live View Kit）
持续实时显示进度，完成/失败/进程被杀均正确收尾。

- **根因修复**：原进度链路为进程内回调驱动，退后台后进程被挂起 → 进度冻结。
  改为 `max(阶段锚点, 时间滑轨)`：滑轨只依赖 `Date.now()`，重新被调度即按真实
  流逝时间补齐。
- **后台保持**：看门狗定时器（与页面解耦，2s）+ 短时任务
  `requestSuspendDelay`（**无需权限**，`@since 9`）；`EntryAbility.onBackground`
  只保持、**绝不结束**实况窗。
- **进程被杀兜底**：服务端任务继续跑完 → push-type 7 结束实况窗 →
  `GenTask.recover` 补结果入历史。
- **跨端一致性**：服务端补推与客户端看门狗交替更新同一实况窗，两端公式
  逐点一致（0pp），由三层断言锁死（数值/行为/根因）。
- **零新增权限**：不申请 `KEEP_BACKGROUND_RUNNING`、不改 `module.json5`。

详见 [`docs/实况窗后台进度功能说明.md`](docs/实况窗后台进度功能说明.md)。

回归测试：

```bash
cd server
node tools/test_liveview_contract.js     # 27 项
node tools/test_liveview_background.js   # 95 项
node tools/test_liveview_progress.js     # 193 项
```


## 快速构建

### 鸿蒙（DevEco Studio）

DevEco Studio 打开工程，`ohpm install` 后运行 entry。命令行构建：

```powershell
$env:DEVECO_SDK_HOME='D:\Program Files\Huawei\DevEco Studio\sdk'
& 'D:\Program Files\Huawei\DevEco Studio\tools\node\node.exe' `
  'D:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js' `
  --mode module -p module=entry@default -p product=default `
  -p requiredDeviceType=phone assembleHap --analyze=normal --parallel --incremental --daemon
# 产物：entry\build\default\outputs\default\entry-default-signed.hap（约 12 MB）
```

> **构建排错（踩过的坑）**
> - 报 `ENOENT ... .hvigor\project_caches\<hash>\workspace\node_modules\@ohos\hvigor\bin\hvigor.js`：删除该 `project_caches\<hash>` 目录后重跑，hvigor 会自动重装依赖。
> - 报 `11706007 can't support crossplatform application`（如 `speechRecognizer`）：说明工程被当作 ArkUI-X 跨端构建。检查 `.arkui-x/arkui-x-config.json5` 应为 `crossplatform:false`，并清掉 `.hvigor\cache`、`entry\build` 后重建（hvigor 会缓存 `isCrossplatform`，不清缓存改了也不生效）。
> - 资源命名只能用 `[a-z0-9_]`，**不能含空格**；且 `AppScope` 与 `entry` 同名 `media/` 资源会冲突，构建后仅 AppScope 版生效 —— 启动页等专属素材请使用独立名字（如 `splash_logo`）。

### Windows（Electron）

```powershell
cd Windows
npm install
npm run dist        # electron-builder 产出 NSIS 安装包
# 或 npm start 直接调试
```

应用名与图标从鸿蒙主工程同步：名称 `Agent备课`（对齐 `AppScope` 的 `app_name`），
图标由 `node build-icon.js` 从鸿蒙 1024×1024 主图 `AppScope/resources/base/media/icon.png`
重新生成 `build/icon.ico`（7 档尺寸 16–256）与 `renderer/icon.png`，脚本零依赖、可重复执行。
多语言词典由 `node tools/gen_i18n_windows.js` 从鸿蒙 `I18n.ets` 与三份少数民族语言词典生成，
用 `node tools/verify_i18n_windows.js` 校验一致性（zh/en 各 378 键，ug/bo/mn 各 372 键）。

**消息通知**：生成完成/失败时弹 Windows 系统通知，语义对齐鸿蒙 `NotifySlot.ets` + `GenTask.ets`
（逐功能固定通知 ID 7101–7107，兜底 7199，重复生成覆盖不堆叠）；点击通知会在窗口恢复并跳到对应功能页。
实现见 `renderer/js/notify-core.js`、`main.js`、`renderer/preload.js`，说明见 `Windows/通知功能说明.md`。
回归测试：`node server/tools/test_windows_notify_e2e.js`（在真实 renderer 文件上做端到端断言）。

**构建产物**（已在 `Windows/dist/` 生成）：

| 产物 | 说明 |
| --- | --- |
| `Windows/dist/AgentBeike-Setup-1.0.0.exe` | NSIS 安装包（约 75 MB），快捷方式名 `Agent备课` |
| `Windows/dist/Agent备课 1.0.0.exe` | 免安装单文件绿色版（约 68 MB） |

> 无交互式桌面会话的环境（连 `notepad` 都立即退出）下，electron-builder 的 NSIS
> 两遍构建会在"运行安装程序以提取卸载器"这步挂起，产出仅 0.22 MB 的残缺包。
> 这是环境限制而非工程缺陷；详见 `Windows/通知功能说明.md` 第 9.3 节。


### 服务端

配置见 [`server/AI部署手册.md`](server/AI部署手册.md)，也可用 `server/docker-compose.yml` 一键部署（注意与 PM2 方式二选一，不要同时跑）。

```bash
cd server && npm install && cp .env.example .env   # 填入 DEEPSEEK_API_KEY
npm start                                          # 默认 3000 端口
```

> **上线前务必设置 `PROXY_TOKEN`**（服务端 `.env` 与 App 端 `ApiConfig.PROXY_TOKEN` 保持一致）。未设置时该代理对公网**完全无鉴权**，任何人均可借其消耗你的 DeepSeek 额度；建议同时在 Nginx 配置 HTTPS 反向代理。

## 开源许可

基于 [AGPL-3.0](LICENSE) 开源。
