# Rev TechingMaster AI 中转代理（服务端）

App 客户端不再内置 DeepSeek API Key，改为请求本服务；本服务持有密钥并向 DeepSeek 转发请求。这样密钥只存在于你自己的云服务器环境变量中，不会随 App 安装包分发。

自 v1.1 起服务端同时承载**账号体系**：注册/登录/退出与华为账号登录的授权码交换（用户数据保存于 `server/data/users.json`，仅本机文件存储）。

## 目录结构

```
server/
├── src/server.js      代理服务 + 账号接口（Express）
├── package.json       依赖与启动脚本
├── .env.example       配置模板（复制为 .env）
├── data/              运行时生成的用户数据（已 gitignore，勿提交）
└── .gitignore         忽略 .env / node_modules / data
```

## 账号接口

| 接口 | 说明 |
| --- | --- |
| `POST /api/register` | `{username, password}` 注册（密码 scrypt 加盐哈希存储），返回 `{token, user}` |
| `POST /api/login` | `{username, password}` 登录，返回 `{token, user}` |
| `POST /api/huawei-login` | `{code, redirectUri}` 华为授权码换会话（自动创建/匹配账号），返回同上 |
| `GET /api/me` | 请求头带 `Authorization: Bearer <token>` 校验会话 |
| `POST /api/logout` | 注销当前令牌 |

- 会话 token 有效期 30 天，保存在内存中，服务重启后需重新登录。
- `AUTH_REQUIRED=true` 时，`/v1/chat/completions` 与 `/api/chat` 也要求 `Authorization` 携带账号 token；默认 `false` 保持向后兼容。

测试：

```bash
curl -X POST http://127.0.0.1:3000/api/register -H 'Content-Type: application/json' \
  -d '{"username":"teacher1","password":"123456"}'
curl -X POST http://127.0.0.1:3000/api/login -H 'Content-Type: application/json' \
  -d '{"username":"teacher1","password":"123456"}'
```

## 华为登录（服务端配置）

App 端采用“授权码 + 服务端换 token”模式：App 内 WebView 打开华为授权页，回调地址带回 `code`，服务端用 `HUAWEI_APP_ID`/`HUAWEI_APP_SECRET` 换取用户 openid 并建立会话。

1. 在 AppGallery Connect 控制台的**认证服务（Auth Service）**页面（该应用客户端 ID `6917615335790825716`）：获取 Client Secret、确认回调地址为 `http://123.60.130.45:3000/api/huawei/cb`。
2. 服务器 `.env` 填写：
   ```ini
   HUAWEI_CLIENT_ID=6917615335790825716
   HUAWEI_APP_SECRET=获取到的 Client Secret
   ```
3. App 端 `ApiConfig.HUAWEI_REDIRECT` 需与 AGC 登记的地址一致（当前默认 `http://123.60.130.45:3000/api/huawei/cb`）。

> 若未配置 Client Secret，App 点击“华为账号登录”会提示“服务端未配置”，账号密码登录不受影响。

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
   - 阿里云控制台安全组：入方向放行 `TCP 3000`（建议只对来源收紧）
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
- 建议后续在 Nginx/Caddy 上配置 HTTPS 反向代理，App 内改用 `https://` 地址（明文 HTTP 内容与令牌都有被中间人读取的风险）。
- 若担心超长输出被限流误伤，可调大 `RATE_LIMIT_PER_MIN` 或只对公网 Nginx 层限流。
- 服务器重启后确认进程自动拉起（pm2 startup 或 systemd enable）。

## 与 App 对接

App 端已默认走代理且不再内置密钥：打开 `entry/src/main/ets/common/ApiConfig.ets`：
- 核对 `PROXY_BASE_URL`（默认已指向 `http://123.60.130.45:3000/v1/chat/completions`）
- 若服务器设置了 `PROXY_TOKEN`，把相同字符串填到 `PROXY_TOKEN`；服务器未启用令牌则保持为空

App 与代理的请求/响应结构与直连 DeepSeek 完全一致，AiService 无需改动即可工作。
