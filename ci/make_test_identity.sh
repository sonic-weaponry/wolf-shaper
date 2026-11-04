#!/usr/bin/env bash
# Makes two throwaway, self-signed signing identities for the signing rehearsal on a CI runner: "Wolf Shaper CI
# rehearsal Application (not trusted)" for the bundle and "Wolf Shaper CI rehearsal Installer (not trusted)" for the
# installer. Valid for 2 days, trusted by no Mac, never uploaded. With them every push runs the same keychain, signing
# and install code that the release job runs with the real Developer ID certificates (ci/README.md, "Signing").
# The installer identity is imported and looked up like the real one, but productbuild won't sign with it: it signs
# only with an installer certificate the Mac trusts, and the rehearsal doesn't change the runner's trust settings. So
# the rehearsal's installer stays unsigned, and the release job is the first to sign one.
#
# Usage: ci/make_test_identity.sh <folder>
# Writes application.p12 and installer.p12 into the folder, each protected by the password in $REHEARSAL_P12_PASSWORD,
# in the same format as the real ones (3DES, SHA-1: what macOS's keychain imports). Run it on macOS.
set -euo pipefail

dir=$1
: "${REHEARSAL_P12_PASSWORD:?set REHEARSAL_P12_PASSWORD}"
# macOS's own LibreSSL: a Homebrew OpenSSL 3 earlier in PATH would write a .p12 the keychain can't read.
openssl=/usr/bin/openssl
mkdir -p "$dir"

# identity <file name> <common name> <extended key usage>
identity() {
    local file=$1 name=$2 usage=$3
    cat >"$dir/$file.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $name
O = Wolf Shaper CI rehearsal
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,$usage
subjectKeyIdentifier = hash
EOF
    "$openssl" req -x509 -newkey rsa:2048 -nodes -days 2 -config "$dir/$file.cnf" \
        -keyout "$dir/$file.key" -out "$dir/$file.crt" 2>/dev/null
    "$openssl" pkcs12 -export -inkey "$dir/$file.key" -in "$dir/$file.crt" -name "$name" \
        -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -passout env:REHEARSAL_P12_PASSWORD -out "$dir/$file.p12"
    rm -f "$dir/$file.key" "$dir/$file.cnf"
    "$openssl" x509 -in "$dir/$file.crt" -noout -subject -enddate
}

"$openssl" version
identity application "Wolf Shaper CI rehearsal Application (not trusted)" codeSigning
# 1.2.840.113635.100.4.13 is the extended key usage of Apple's installer (package) signing certificates.
identity installer "Wolf Shaper CI rehearsal Installer (not trusted)" "1.2.840.113635.100.4.13"
