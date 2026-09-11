# Rev TechingMaster AI 中转代理（服务端）

App 客户端不再内置 DeepSeek API Key，改为请求本服务；本服务持有密钥并向 DeepSeek 转发请求。这样密钥只存在于你自己的云服务器环境变量中，不会随 App 安装包分发。

## 目录结构

```
server/
├── src/server.js           代理服务（Express）
├── src/rag.js              新课标 RAG 检索（学科索引路由 + 内容索引 BM25）
├── src/tasks.js            后台生成任务（存储 / 队列 / 持久化）
├── src/push.js             Push 通知（客户端已停用，默认关闭）
├── rag/                    新课标索引（构建产物，随仓库提交）
│   ├── subjects.json         学科索引
│   ├── chunks.json           内容索引
│   └── meta.json             构建元信息
├── tools/ocr_std.py        课标 PDF 批量 OCR（扫描件无文本层）
├── tools/build_rag_index.py 索引构建
├── package.json            依赖与启动脚本
├── .env.example            配置模板（复制为 .env）
└── .gitignore              忽略 .env / node_modules / data / .ocr_cache
```

## 接口

| 接口 | 说明 |
| --- | --- |
| `GET /health` | 健康检查 |
| `POST /v1/chat/completions` | 与 App 现有调用完全兼容的透传接口（OpenAI 请求体） |
| `POST /api/chat` | 简化接口：`{ system?, user }` |
| `POST /api/task` | 提交后台生成任务，立即返回 `taskId`；`{ type, label, system, user, deviceId, attachments?, subject?, grade?, thinking? }` |
| `GET /api/task/:id` | 查询任务状态与结果（含 `rag` 检索记录、`reasoning` 思考过程） |
| `GET /api/task/:id/feed` | SSE 实时增量（`open`/`think`/`chunk`/`done`/`error`/`cancelled`） |
| `POST /api/task/:id/cancel` | 取消正在生成的任务 |
| `GET /api/tasks?deviceId=` | 按设备列出最近任务 |
| `GET /api/rag/stats` | 索引概况（学科数、块数、结构化抽取命中情况） |
| `GET /api/rag/search?q=&subject=&grade=` | 只看检索命中的课标条目（不调用模型，便于调参） |
| `GET /api/rag/block?q=` | 预览最终注入模型的「课标依据」块全文 |

- 设置了 `PROXY_TOKEN` 时，以上接口要求请求头携带 `x-proxy-token: 你的令牌`（与 App 端 `ApiConfig.PROXY_TOKEN` 一致）。
- 默认非流式透传；客户端请求体带 `stream: true` 时按 SSE 逐块透传。

## 新课标 RAG 索引

把 `teching/` 目录下的 14 份《义务教育课程方案和课程标准（2022 年版）》做成检索索引（含道德与法治、语文、数学、英语、历史、地理、科学、物理、化学、生物学、信息科技、艺术、劳动 13 个学科课标 + 课程方案），在生成教案/练习/课件时自动检索并注入课标原文，让教学设计有据可依。

### 两个索引

| 索引 | 文件 | 作用 |
| --- | --- | --- |
| 学科索引 | `rag/subjects.json` | 每个学科的别名、学段、核心素养、课程目标、学段目标、学业质量、章节大纲；用于**把请求路由到对应课标**，并给出该学科的结构化要点 |
| 内容索引 | `rag/chunks.json` | 1428 个条目化原文块（学科 + 章节路径 + 页码 + 原文 + 前言等辅助块标记）；用于**检索与课题直接相关的课标条目原文** |

课标 PDF 是扫描件（无文本层），索引由 `tools/` 下的脚本离线构建：

```bash
pip install pypdfium2 pytesseract      # 另需系统安装 tesseract 及 chi_sim 语言包
export TESSERACT_CMD=/usr/bin/tesseract   # Windows 上需指向 tesseract.exe

python tools/ocr_std.py 8              # 1) OCR 1428 页扫描件，约 15 分钟（可断点续跑，已缓存的会跳过）
python tools/build_rag_index.py        # 2) 切块 + 构建两个索引 → server/rag/
```

新增或替换课标 PDF 后重跑这两步，再 `pm2 restart` 即可生效；已知 PDF 未变时脚本会跳过 OCR。

### 检索与注入流程

1. **学科路由**：显式 `subject` 字段 → 请求文本里的「学科：X」→ 全文学科别名匹配；命中后把检索范围限定在该学科的块内。
2. **打分**：中文 bigram + 拉丁词的 BM25，叠加章节标题命中、学段匹配、课题在标题/正文中的命中加权；前言/修订原则/主要变化等各科雷同的辅助块降权到 0.3。
3. **组装依据块**：学科核心素养 + 学段目标（按年级选学段）+ 学业质量 + Top-8 相关条目原文（每条按命中位置居中截取 620 字）+ 五条「落实要求」。总量约 4.3K 字。
4. **注入位置**：依据块追加在 user 消息末尾（最终指令靠后，模型遵循度更高），同时在 system 消息追加一句「必须以该课标为依据」。

### 注入闸门（避免污染无关结果）

- 教案 / 分层练习 / 课件等教学设计任务：注入该学科课标依据。
- 客户端声明的学科不在课标库中（如体育与健康、日语、俄语）：**不注入任何学科课标条文**（绝不拿别的学科顶替），改为注入一段约 900 字的说明：唯一可引用依据是《课程方案》，并硬性禁止编造该学科课标条文。这样既不会串学科，也能挡住模型凭记忆虚构课标。
- 学科只是被顺带提到（如学情报告里的各科成绩）：**不注入**。
- 未识别学科但请求明确提到课标/课程标准/课程方案：退回《课程方案》作为依据。

### 学段对齐

各课标的学段划分并不一致（语文/道德与法治/劳动/科学等为 1-2 / 3-4 / 5-6 / 7-9，而艺术为 1-2 / 3-5 / 6-7 / 8-9），因此构建索引时会从章节标题实测每个学科的学段区间（`subjects.json` 的 `stageMap`），检索时按该划分对齐：小节标题写明了学段的，与目标学段一致加权 1.8 倍、不一致降权到 0.2 倍，避免跨学段取条文导致教学深度写错。

### 调试

```bash
curl -sk 'https://rev-on.site:3000/api/rag/stats' | jq
curl -sk 'https://rev-on.site:3000/api/rag/search?q=学科：物理 年级：八年级 课题：电和磁' | jq '.hits[].sec'
curl -sk 'https://rev-on.site:3000/api/rag/block?q=学科：语文 年级：七年级 课题：论语十二章' | jq -r .block
```

每次生成任务的检索记录会写进任务对象（`GET /api/task/:id` 的 `rag` 字段），包含命中的学科、学段、条目块 id/章节/页码与得分，便于回溯「这段教案依据了哪几条课标」。

### 相关环境变量

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `RAG_ENABLED` | 开启 | 设为 `0` 可整体关闭检索注入 |
| `RAG_DIR` | `server/rag` | 索引目录 |
| `RAG_TOP_K` | `8` | 注入的课标条目数 |
| `RAG_MAX_CHARS` | `4200` | 依据块正文总量上限（不含标题与落实要求） |

## 深度思考（思维链）

App 各生成页有「深度思考」开关（默认关闭）。开关状态随任务提交到服务端：

| 客户端字段 | 服务端行为 |
| --- | --- |
| `thinking: false` / 缺省 | 上游请求带 `thinking: { type: 'disabled' }`，跳过思维链直接作答（快速模式，默认） |
| `thinking: true` | 上游请求带 `thinking: { type: 'enabled' }` + `reasoning_effort`（`THINKING_EFFORT`，默认 `high`） |

思考过程与正文在服务端分流：

- 上游流式返回的 `delta.reasoning_content` 累积为思考过程，经 SSE 以 `event: think` + `{ d }` 实时下发（约 150ms 一批），App 侧灰色小字滚动展示；`delta.content` 仍走原来的 `event: chunk`。
- 任务对象新增 `reasoning` 字段：生成中按全量补发给重连的 feed 订阅者，完成后随 `event: done` 的 `{ c, r }` 一并返回，也可由 `GET /api/task/:id` 轮询兜底获取。
- App 侧生成结束（完成/失败/停止）后自动折叠思考过程，用户点击标题可再展开。

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `THINKING_EFFORT` | `high` | 思考强度，可设 `high` / `max`；仅在 `thinking: true` 时生效 |

## 本地快速测试

```bash
cd server
npm install
cp .env.example .env       # 编辑 .env，填入 DEEPSEEK_API_KEY
npm start                  # 默认监听 3000 端口
```

另开终端验证：

```bash
curl http://127.0.0.1:3000/health
curl -X POST http://127.0.0.1:3000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"你好，请简单自我介绍"}],"stream":false}'
```

## 部署到云服务器

以下以本项目的服务器 `123.60.130.45` 为例，实际按你的系统调整。

1. 上传代码（任选其一）：
   - 本机执行 `scp -r server root@123.60.130.45:/opt/rev-server`
   - 或在服务器上拉取仓库后只保留 server 目录
2. 登录服务器安装依赖并配置：
   ```bash
   cd /opt/rev-server
   npm install --omit=dev
   cp .env.example .env
   vim .env          # 填写 DEEPSEEK_API_KEY；建议同时设置 PROXY_TOKEN（随机长字符串）
   chmod 600 .env
   ```
3. 保持进程常驻（二选一）：

   PM2：
   ```bash
   npm install -g pm2
   pm2 start src/server.js --name rev-ai-proxy
   pm2 save && pm2 startup
   ```

   systemd（写入 `/etc/systemd/system/rev-ai-proxy.service`）：
   ```ini
   [Unit]
   Description=Rev TechingMaster AI Proxy
   After=network.target

   [Service]
   WorkingDirectory=/opt/rev-server
   ExecStart=/usr/bin/node src/server.js
   Restart=always
   EnvironmentFile=/opt/rev-server/.env

   [Install]
   WantedBy=multi-user.target
   ```
   ```bash
   systemctl daemon-reload && systemctl enable --now rev-ai-proxy
   ```
4. 放行端口：
   - 云服务器安全组：入方向放行 `TCP 3000`（建议只对来源收紧）
   - 若使用 `ufw`：`ufw allow 3000/tcp`
5. 验证公网访问：
   ```bash
   curl http://123.60.130.45:3000/health
   curl -X POST http://123.60.130.45:3000/v1/chat/completions \
     -H 'Content-Type: application/json' \
     -d '{"messages":[{"role":"user","content":"你好"}],"stream":false}'
   ```
   如设置了 `PROXY_TOKEN`，额外携带请求头 `x-proxy-token: 你的令牌`。

## 安全建议

- 必须设置 `PROXY_TOKEN` 共享令牌，防止服务器被当作免费代理滥用。
- 建议在 Nginx/Caddy 上配置 HTTPS 反向代理，App 内改用 `https://` 地址（明文 HTTP 内容与令牌都有被中间人读取的风险）。
- 若担心超长输出被限流误伤，可调大 `RATE_LIMIT_PER_MIN` 或只对公网 Nginx 层限流。
- 服务器重启后确认进程自动拉起（pm2 startup 或 systemd enable）。

## 与 App 对接

App 端已默认走代理且不再内置密钥：打开 `entry/src/main/ets/common/ApiConfig.ets`：
- 核对 `PROXY_BASE_URL`（默认已指向 `https://rev-on.site:3000/v1/chat/completions`）
- 若服务器设置了 `PROXY_TOKEN`，把相同字符串填到 `PROXY_TOKEN`；服务器未启用令牌则保持为空

App 与代理的请求/响应结构与直连 DeepSeek 完全一致，AiService 无需改动即可工作。
