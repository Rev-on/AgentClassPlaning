# Rev TechingMaster AI 中转代理 —— 容器化部署
# 仅包含运行所需：src/（服务代码）+ rag/（教材课标 RAG 索引）+ package.json
# 构建期产物（.ocr_cache、tools、node_modules、.env）不入镜像
FROM node:18-alpine

ENV NODE_ENV=production \
    HOST=0.0.0.0 \
    PORT=3000

WORKDIR /app

# 先复制依赖清单，利用 Docker 层缓存，避免源码改动后重复装依赖
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --registry=https://registry.npmmirror.com

# 复制运行时代码与 RAG 索引
COPY src ./src
COPY rag ./rag

# 非 root 运行，降低容器逃逸风险
USER node
ENV HOME=/home/node

EXPOSE 3000

CMD ["node", "src/server.js"]