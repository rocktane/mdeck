#!/bin/bash
# Creates the self-signed code-signing certificate that signs mdeck.
#
# Why bother, for an app that needs no entitlements: the Accessibility grant is bound to the
# app's code identity. With an ad-hoc signature that identity is the code hash, so every
# rebuild or update is "a different app" and the grant silently stops applying. With a
# certificate — even a self-signed one — the identity is "com.yohan.mdeck signed by this cert",
# which survives rebuilds and releases alike.
#
# Usage: make-cert.sh [name] [--export path.p12]
#   name           certificate common name (default: "mdeck Signing")
#   --export       also write the PKCS#12 bundle (cert + private key) to that path, for
#                  uploading to the CI secret so releases share the identity of local builds
#
# Environment:
#   CERT_KEYCHAIN  target keychain (default: login keychain). CI passes its temporary
#                  build keychain here.
set -euo pipefail

NAME="mdeck Signing"
EXPORT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --export) EXPORT="$2"; shift 2 ;;
    *) NAME="$1"; shift ;;
  esac
done
KEYCHAIN="${CERT_KEYCHAIN:-}"
P12_PASS="${CERT_PASS:-mdeck-cert}"
# System LibreSSL: Homebrew OpenSSL 3 produces p12 files that `security import` rejects
OPENSSL=/usr/bin/openssl

if security find-certificate -c "$NAME" ${KEYCHAIN:+"$KEYCHAIN"} >/dev/null 2>&1; then
  echo "Certificate '$NAME' already exists — nothing to do."
  [[ -n "$EXPORT" ]] && echo "(--export ignored: the private key is only available at creation time)"
  exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/openssl.cnf" << EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:FALSE
EOF

"$OPENSSL" req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -config "$TMP/openssl.cnf" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null

"$OPENSSL" pkcs12 -export -name "$NAME" \
  -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -passout "pass:$P12_PASS" -out "$TMP/cert.p12"

security import "$TMP/cert.p12" ${KEYCHAIN:+-k "$KEYCHAIN"} \
  -P "$P12_PASS" -T /usr/bin/codesign >/dev/null

if [[ -n "$EXPORT" ]]; then
  cp "$TMP/cert.p12" "$EXPORT"
  chmod 600 "$EXPORT"
  echo "Exported $EXPORT (password: \$CERT_PASS, default 'mdeck-cert')."
fi

echo "Created certificate '$NAME'${KEYCHAIN:+ in $KEYCHAIN}."
