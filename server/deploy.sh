#!/usr/bin/env bash
# ============================================================================
# Rev TechingMaster AI 中转代理 —— 云端 Docker 一键部署/更新脚本（在服务器上执行）
#
# 前置：
#   1) 本目录已就位：server/{src, rag, package.json, .env, Dockerfile, docker-compose.yml}
#   2) 已安装 docker + docker compose 插件
#   3) .env 已配置 DEEPSEEK_API_KEY（及 PROXY_TOKEN 等）
#   4) TLS 证书已在 /etc/ssl/rev-on.site/{server.pem,private_key.pem}
#
# 迁移注意：现有部署用 PM2 占用了 3000 端口，切换到 Docker 前必须先停掉 PM2，
#   见 云端部署.md 第 3 节。默认脚本不自动停 PM2（避免误伤），由你确认后执行。
# ============================================================================
set -euo pipefail

SERVER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SERVER_DIR"

echo "==> [1/4] 校验 .env 存在 =="
if [ ! -f .env ]; then
  echo "错误：未找到 .env，请先 cp .env.example .env 并填写 DEEPSEEK_API_KEY" >&2
  exit 1
fi

echo "==> [2/4] 构建镜像 =="
docker compose build

echo "==> [3/4] 拉起/更新容器 =="
docker compose up -d

echo "==> [4/4] 健康检查（等待容器就绪）=="
for i in $(seq 1 30); do
  if curl -sS -o /dev/null -w "%{http_code}" --max-time 5 \
      "https://127.0.0.1:3000/health" 2>/dev/null | grep -q "200"; then
    echo "✔ 部署成功：https://<域名>:3000/health 返回 200"
    docker compose ps
    exit 0
  fi
  sleep 2
done

echo ""
echo "✖ 30 秒内健康检查未通过，请排查容器状态："
echo "    docker compose logs --tail=50 rev-techingmaster-ai"
exit 1