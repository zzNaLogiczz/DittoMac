#!/bin/zsh
# 一次性:创建自签名代码签名证书"DittoMac Dev"并导入登录钥匙串。
# 用途:让辅助功能等 TCC 授权在重新构建后仍然有效(同一证书 → 同一代码要求)。
# 之后 make-app.sh 会自动用该证书签名;已签名的应用重新构建无需重授权限。
set -euo pipefail
NAME="DittoMac Dev"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
  echo "证书 $NAME 已存在,无需创建"
  exit 0
fi

cat > "$WORK/ext.cnf" <<'CNF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = DittoMac Dev
O = DittoMac
[v3]
keyUsage = critical, digitalSignature
extendedKeyUsage = codeSigning
basicConstraints = CA:false
CNF
openssl req -x509 -newkey rsa:2048 -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
  -days 3650 -nodes -config "$WORK/ext.cnf" 2>/dev/null
openssl pkcs12 -export -out "$WORK/dittomac.p12" -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -password pass:dittomac-dev 2>/dev/null
security import "$WORK/dittomac.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
  -P dittomac-dev -T /usr/bin/codesign
# 用户级信任(若系统弹窗确认,点允许)
security add-trusted-cert -p codeSign -k "$HOME/Library/Keychains/login.keychain-db" "$WORK/cert.pem" || true

security find-identity -v -p codesigning | grep "$NAME" && echo "✅ 证书就绪,make-app.sh 将自动使用"
