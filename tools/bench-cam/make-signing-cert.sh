#!/bin/sh
# Make a self-signed code-signing certificate, so bench-cam stops losing its camera grant.
#
# Why this exists: with no signing identity, codesign -s - gives the app a designated
# requirement that is nothing but a hash of the compiled binary. TCC stores your camera
# permission against that requirement, so every rebuild is a different app to it and the
# grant lapses — exactly once per rebuild, which is why it looks intermittent. Anchoring
# the signature to a certificate makes the requirement survive recompilation.
#
# The usual advice is Keychain Access -> Certificate Assistant. That advice is dead:
# macOS 26 removed Keychain Access, and Certificate Assistant with it. So, openssl.
#
# WHAT THIS CHANGES ON YOUR MACHINE: it adds one private key and one self-signed
# certificate to your login keychain, and grants /usr/bin/codesign permission to use the
# key. Nothing is added to the system trust store, nothing needs sudo, and it signs only
# what you point it at. Undo with:
#
#     security delete-identity -c soundgraph-bench
#
# Run it yourself — it is your keychain.
set -eu
NAME=${1:-soundgraph-bench}
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning 2>/dev/null | grep -q "$NAME"; then
    echo "'$NAME' already exists. Rebuild with ./build.sh and it will be used."
    exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# codeSigning EKU is the part that matters; codesign will not use a certificate without
# it. Ten years, because a bench tool expiring mid-debug is its own small tragedy.
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -subj "/CN=$NAME" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

openssl pkcs12 -export -out "$WORK/identity.p12" \
    -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -passout pass: 2>/dev/null

# -T /usr/bin/codesign lets codesign use the key without prompting on every build.
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "" -T /usr/bin/codesign

echo
if security find-identity -p codesigning 2>/dev/null | grep -q "$NAME"; then
    echo "created '$NAME'."
    echo "now run ./build.sh — it will find it, and the camera grant will survive rebuilds."
    echo "you will be asked to allow the camera once more, and then not again."
else
    echo "the certificate did not appear. Check: security find-identity -p codesigning"
    exit 1
fi
