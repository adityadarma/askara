#!/bin/zsh
# Creates a self-signed code signing certificate for Askara and imports it into the login keychain.
#
# Why: ad-hoc signatures change on every build, so macOS treats each build as a new app and asks
# again for Downloads, camera, microphone, and Keychain access. A fixed certificate keeps the app's
# identity (designated requirement) the same across builds and updates.
#
# It does NOT remove the Gatekeeper warning on first launch; that needs Developer ID + notarization.
#
# Output (outside the repo, never commit it): ~/.askara-signing/
#   askara-signing.p12           certificate + private key (for the GitHub secret)
#   askara-signing.p12.password  password of the .p12
# Run once. Running again keeps the existing certificate.
set -euo pipefail

NAME="Askara Self-Signed"
DIR="$HOME/.askara-signing"
P12="$DIR/askara-signing.p12"
PASSFILE="$DIR/askara-signing.p12.password"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
OPENSSL="$(command -v openssl)"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "Certificate \"$NAME\" already exists in the login keychain; nothing to do."
    exit 0
fi

mkdir -p "$DIR"
chmod 700 "$DIR"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF

# 20 years: the identity must outlive every release that should keep its permissions.
"$OPENSSL" req -x509 -newkey rsa:3072 -sha256 -days 7300 -nodes \
    -config "$WORK/cert.cnf" -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null

PASS="$("$OPENSSL" rand -base64 24)"
print -rn -- "$PASS" > "$PASSFILE"
chmod 600 "$PASSFILE"
# Legacy PKCS#12 algorithms: macOS `security import` does not read the OpenSSL 3 defaults.
"$OPENSSL" pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
    -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 \
    -passout file:"$PASSFILE" -out "$P12"
chmod 600 "$P12"

# -T lets codesign use the key without asking each time.
security import "$P12" -k "$KEYCHAIN" -f pkcs12 -P "$PASS" -T /usr/bin/codesign >/dev/null

echo "Imported \"$NAME\" into the login keychain."
echo "Files for the GitHub secrets (keep them private): $DIR"
