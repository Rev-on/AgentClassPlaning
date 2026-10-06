#!/usr/bin/env bash
# 只读诊断：全面检查证书情况，为"IP 上也能绿锁"寻找可行方案
echo "===== 1. 当前 server.pem 全部细节 ====="
openssl x509 -in /etc/ssl/rev-on.site/server.pem -noout -text 2>/dev/null | sed -n '1,40p'

echo
echo "===== 2. SAN 与 CN ====="
openssl x509 -in /etc/ssl/rev-on.site/server.pem -noout -subject
openssl x509 -in /etc/ssl/rev-on.site/server.pem -noout -ext subjectAltName

echo
echo "===== 3. 证书链（2 张 = 服务器证书 + 中间证书）====="
awk '/BEGIN CERTIFICATE/{n++} {print > "/tmp/cert_part_"n".pem"}' /etc/ssl/rev-on.site/server.pem
for f in /tmp/cert_part_*.pem; do
  echo "--- $f ---"
  openssl x509 -in "$f" -noout -subject -issuer 2>/dev/null
done
rm -f /tmp/cert_part_*.pem

echo
echo "===== 4. 系统里是否还有其它可用证书（含 IP 的）====="
find /etc/ssl /root /opt /home /var/www -maxdepth 5 \( -name '*.pem' -o -name '*.crt' -o -name '*.cer' \) 2>/dev/null | while read f; do
  if openssl x509 -in "$f" -noout 2>/dev/null; then
    SAN=$(openssl x509 -in "$f" -noout -ext subjectAltName 2>/dev/null | tail -1 | tr -d ' ')
    SUBJ=$(openssl x509 -in "$f" -noout -subject 2>/dev/null)
    echo "$f"
    echo "    $SUBJ"
    echo "    SAN: $SAN"
  fi
done

echo
echo "===== 5. 是否装了 certbot / acme.sh ====="
command -v certbot && certbot --version 2>/dev/null || echo "  certbot: 未安装"
ls -d /root/.acme.sh 2>/dev/null && echo "  acme.sh: 存在" || echo "  acme.sh: 未安装"

echo
echo "===== 6. openssl 版本（能否自签含 IP SAN 的证书）====="
openssl version

echo
echo "===== 7. 服务器公网 IP 自省（确认就是 123.60.130.45）====="
ip -4 addr show | grep -oP 'inet \K[\d.]+' | grep -v '^127\.'
