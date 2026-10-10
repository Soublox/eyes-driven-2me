#!/usr/bin/env bash
# Create a self-signed code-signing identity, "EyesDriven2me Local Signing",
# in the login keychain. scripts/bundle.sh picks it up automatically.
#
# Why: ad-hoc signatures ("-") change on every build, so macOS forgets the
# Accessibility and Camera permissions each time you rebuild. A stable
# certificate gives the app a stable designated requirement
# (bundle id + certificate hash), so permissions survive rebuilds.
#
# This identity is for local development only. It is not trusted by other
# Macs; public releases need a Developer ID certificate and notarization.
set -euo pipefail

NAME="EyesDriven2me Local Signing"

if security find-identity -p codesigning 2>/dev/null | grep -q "\"${NAME}\""; then
  echo "Identity \"${NAME}\" already exists:"
  security find-identity -p codesigning | grep "\"${NAME}\""
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = ${NAME}
O = Eyes Driven 2me (local development)
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/cert.cnf" 2>/dev/null
PASS="$(openssl rand -hex 16)"
openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -name "$NAME" -out "$WORK/identity.p12" -passout "pass:${PASS}"

security import "$WORK/identity.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
  -P "$PASS" -T /usr/bin/codesign

echo
echo "Created:"
security find-identity -p codesigning | grep "\"${NAME}\""
echo
echo "Rebuild with scripts/bundle.sh, then grant Accessibility once more;"
echo "from now on the permission survives rebuilds."
