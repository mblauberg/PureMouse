#!/bin/zsh
# Creates a self-signed code-signing identity named "mxd" in the login keychain, once per Mac you
# build on. Signing every build with it keeps mxd's permission grants across rebuilds. The
# certificate stays untrusted ("CSSMERR_TP_NOT_TRUSTED"); code signing does not need trust.
#
# The first build after this may ask whether codesign can use the key: choose Always Allow.
# Back up the identity (Keychain Access › Export) if you publish releases signed with it: a new
# one means everyone who installed mxd grants its permissions again.
set -euo pipefail
name=${MXD_SIGN_IDENTITY:-mxd}
keychain=${MXD_KEYCHAIN:-login.keychain-db}

if security find-identity -p codesigning $keychain | grep -q "\"$name\""; then
    echo "code-signing identity \"$name\" already exists"
    exit 0
fi
tmp=$(mktemp -d)
trap 'rm -rf $tmp' EXIT
# The system's LibreSSL writes PKCS#12 that `security import` reads; a Homebrew OpenSSL 3 may not.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$name" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -keyout $tmp/key.pem -out $tmp/cert.pem 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey $tmp/key.pem -in $tmp/cert.pem -name $name \
    -passout pass:transfer -out $tmp/identity.p12
security import $tmp/identity.p12 -k $keychain -P transfer -T /usr/bin/codesign >/dev/null
echo "created code-signing identity \"$name\" in $keychain"
