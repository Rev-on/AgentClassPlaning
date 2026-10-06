#!/usr/bin/env bash
# 证书与环境自检（只读，不改任何配置）
echo "===== 1. 证书主体与有效期 ====="
openssl x509 -in /etc/ssl/rev-on.site/server.pem -noout -subject -issuer -dates

echo
echo "===== 2. SAN（是否包含 IP 123.60.130.45）====="
openssl x509 -in /etc/ssl/rev-on.site/server.pem -noout -ext subjectAltName

echo
echo "===== 3. 证书链包含几张证书 ====="
grep -c 'BEGIN CERTIFICATE' /etc/ssl/rev-on.site/server.pem

echo
echo "===== 4. 私钥与证书是否配对 ====="
CERT_MOD=$(openssl x509 -in /etc/ssl/rev-on.site/server.pem -noout -modulus 2>/dev/null | openssl md5)
KEY_MOD=$(openssl rsa -in /etc/ssl/rev-on.site/private_key.pem -noout -modulus 2>/dev/null | openssl md5)
echo "cert: $CERT_MOD"
echo "key : $KEY_MOD"
if [ "$CERT_MOD" = "$KEY_MOD" ]; then echo "配对结果: MATCH"; else echo "配对结果: MISMATCH"; fi

echo
echo "===== 5. 私钥权限 ====="
ls -l /etc/ssl/rev-on.site/

echo
echo "===== 6. 当前监听端口 ====="
ss -lntp | grep -E ':(80|443|8080)\b'

echo
echo "===== 7. 80 端口当前是谁在服务 ====="
grep -rn 'listen' /etc/nginx/sites-enabled/ /etc/nginx/conf.d/ 2>/dev/null

echo
echo "===== 8. 站点根目录 ====="
ls -la /var/www/rev-on.site/ | head -20
