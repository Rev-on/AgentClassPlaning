# 服务器部署手册（AI 会话专用）

> 用途：用户已授权 AI 会话独立完成服务器部署。本文件是后续会话执行部署时的操作规范。
> 最后更新：2026-09-09（流式 SSE 部署 + 客户端路径 bug 修复）

## 1. 关键信息

- 服务器：`123.60.130.45`（root），SSH 私钥：`c:\Users\laoyu\.ssh\rev_deploy`
- 远端代码目录：`/opt/rev-server`（`.env` 勿覆盖，内含 DEEPSEEK_API_KEY 等）
- PM2 进程名：`rev-server`（`pm2 pid rev-server` / `pm2 restart rev-server`）
- 本地权威源码：`C:\Users\laoyu\Desktop\Rev_Techingmaster\server\src\`（server.js / tasks.js / push.js）
- 协议与端口：服务端 3000 端口只监听 **HTTPS**（内置 TLS 证书）；用 `http://` 访问会得到空响应（empty reply），属正常现象，勿误判为宕机。
- 公网入口：`https://rev-on.site:3000`（域名解析到 123.60.130.45，证书为公网 CA，手机可直连）
- 客户端 API 根：`ApiConfig.SERVER_BASE_URL = 'https://rev-on.site:3000/api'`（已含 `/api` 前缀）
- 鉴权：服务端 `.env` 的 `PROXY_TOKEN` 处于注释状态，客户端 `ApiConfig.PROXY_TOKEN=''`，两侧一致，请求不会 401。

## 2. 部署步骤（改完 server/src 后执行）

```powershell
# ① 确认本地与远端哈希一致（三文件逐一比对）
Get-FileHash 'C:\Users\laoyu\Desktop\Rev_Techingmaster\server\src\server.js','C:\Users\laoyu\Desktop\Rev_Techingmaster\server\src\tasks.js','C:\Users\laoyu\Desktop\Rev_Techingmaster\server\src\push.js' -Algorithm MD5
ssh -i 'c:\Users\laoyu\.ssh\rev_deploy' root@123.60.130.45 'md5sum /opt/rev-server/src/*.js'

# ② 上传前先备份远端（时间戳目录），再 scp 三个文件，最后重启
ssh -i 'c:\Users\laoyu\.ssh\rev_deploy' root@123.60.130.45 "mkdir -p /opt/rev-server/src.bak.$(date +%Y%m%d%H%M%S) && cp /opt/rev-server/src/*.js /opt/rev-server/src.bak.$(date +%Y%m%d%H%M%S)/"
scp -i 'c:\Users\laoyu\.ssh\rev_deploy' 'C:\Users\laoyu\Desktop\Rev_Techingmaster\server\src\server.js' 'C:\Users\laoyu\Desktop\Rev_Techingmaster\server\src\tasks.js' 'C:\Users\laoyu\Desktop\Rev_Techingmaster\server\src\push.js' root@123.60.130.45:/opt/rev-server/src/
ssh -i 'c:\Users\laoyu\.ssh\rev_deploy' root@123.60.130.45 'pm2 restart rev-server'

# ③ 健康检查（必须 https）
curl.exe -sS -o NUL -w "HTTP=%{http_code}`n" https://rev-on.site:3000/health
```

## 3. SSE 冒烟（部署后必做，验证 feed 流）

POST 正文必须写成 **UTF-8 无 BOM 文件** 再提交（PowerShell 命令行直接传中文 JSON 会被控制台编码破坏，服务端 body-parser 会报 `Unexpected token` 500）。

```powershell
# 提交任务拿到 taskId
$r = & curl.exe -sS -X POST 'https://rev-on.site:3000/api/task' -H 'Content-Type: application/json' --data-binary '@本地UTF8json文件' --max-time 30
$id = ($r | ConvertFrom-Json).taskId
# 订阅 feed，应看到 event: open → 多个 event: chunk → event: done
& curl.exe -sS -N "https://rev-on.site:3000/api/task/$id/feed" --max-time 120
```

正常输出形如：`event: open` / `event: chunk data:{"d":"..."}` / `event: done data:{"c":"全文"}`。

## 4. 客户端路径约定（重要，踩过坑）

- `SERVER_BASE_URL` 已以 `/api` 结尾，所有相对路径**不得再带 `/api`**。
- `GenTask`：`api('/task')`、`api('/task/'+id)` ✔
- `SseClient`：内部拼 `SERVER_BASE_URL + path`；`AiService.feedOnce` 中传 `/task/'+taskId+'/feed'` ✔
- 曾写错为 `/api/task/.../feed`，实际请求变成 `/api/api/task/...` → 404 → 客户端静默退回轮询，表现为“服务器已支持流式但 App 仍是整段等待”。2026-09-09 已修复并重新构建。

## 5. 重新构建鸿蒙 HAP（改完 entry 源码后）

```powershell
$env:DEVECO_SDK_HOME='D:\Program Files\Huawei\DevEco Studio\sdk'
& 'D:\Program Files\Huawei\DevEco Studio\tools\node\node.exe' 'D:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js' --mode module -p product=default assembleHap --no-daemon
# 产物：entry\build\default\outputs\default\entry-default-signed.hap（自动签名，凭据在 build-profile.json5）
```

安装到真机：DevEco 连接设备部署，或 `hdc install <hap路径>`。

## 6. 踩坑备忘

- 服务器 80/8080 是 nginx、3001 是其它 node 进程（`/tmp/t3.js`），都与 rev-server 无关；改部署时不要动它们。
- 只要部署 3 个 src 文件即可，`node_modules` 与 `.env` 不随部署覆盖。
- 客户端无系统通知功能（已取消），PUSH_ENABLED 相关日志为正常跳过。
