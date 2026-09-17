# Rev TechingMaster 初中教学备课智能体

面向初中教师的 AI 教学助手，2026 年无锡市“人工智能 + 教育”创新应用技能大赛参赛作品。AI 生成初稿、教师修改使用，把教案、课件、练习、学情、排座、家校沟通等日常事务集成到一个应用。

## 核心功能

- **智能备课**：AI 生成教案、逐页课件大纲（结构化 JSON，可导出 PPT）、分层练习、教研文章。
- **学情与班级**：Excel 导入成绩做学情分析并生成 Word 报告；班级名单管理；身高蛇形算法智能排座，支持点击互换。
- **家校沟通**：AI 生成家长沟通话术。
- **责任机制**：所有 AI 内容统一标注“（AI生成，仅供参考）”，首次启动 5 秒倒计时免责声明。
- **多语言**：中、英、维吾尔、藏、蒙古五语言界面，内置对应少数民族字体，数据本地优先、不上云。

## 技术架构

鸿蒙原生 ArkTS（Stage 模型）开发，同步产出 Android（ArkUI-X）与 Windows（Electron）版本。AI 经自建 Node.js 中转代理（`server/`）访问 DeepSeek，SSE 流式输出并带轮询兜底，App 重启自动恢复未完成任务；API Key 只存服务端。支持自研 OOXML 导出 Word/PPT、ExcelJS 读写名单。

## 快速构建

- 鸿蒙：DevEco Studio 打开工程，`ohpm install` 后运行 entry。
- Windows：`cd Windows && npm run dist` 产出 NSIS 安装包。
- 服务端：配置见 `server/AI部署手册.md`，Docker Compose 一键部署。

## 开源许可

基于 [AGPL-3.0](LICENSE) 开源。
