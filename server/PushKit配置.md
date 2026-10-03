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
