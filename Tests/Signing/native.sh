#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
task_tmp=$(mktemp -d)
trap 'rm -rf "$task_tmp"' EXIT
openssl_flags=()
if command -v brew >/dev/null; then
  openssl_prefix=$(brew --prefix openssl@3)
  openssl_flags=(-I"$openssl_prefix/include" -L"$openssl_prefix/lib")
fi
c++ -std=c++17 "${openssl_flags[@]}" -IZsign/swift Tests/Signing/localtls.cpp Zsign/swift/localtls.cpp -lcrypto -o "$task_tmp/localtls"
"$task_tmp/localtls" "$task_tmp"
openssl x509 -inform DER -in "$task_tmp/authority.der" -out "$task_tmp/authority.crt"
openssl verify -CAfile "$task_tmp/authority.crt" -verify_ip 127.0.0.1 -purpose sslserver "$task_tmp/server.crt"
openssl verify -CAfile "$task_tmp/authority.crt" -verify_hostname localhost -purpose sslserver "$task_tmp/server.crt"
openssl verify -CAfile "$task_tmp/authority.crt" -verify_hostname feather.localhost -purpose sslserver "$task_tmp/server.crt"
openssl verify -CAfile "$task_tmp/authority.crt" -verify_ip ::1 -purpose sslserver "$task_tmp/server.crt"
openssl req -new -x509 -key "$task_tmp/server.pem" -subj /CN=localhost \
  -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1' -out "$task_tmp/legacy.crt"
"$task_tmp/localtls" "$task_tmp" "$task_tmp/legacy.crt"
if openssl verify -CAfile "$task_tmp/authority.crt" -verify_hostname example.org "$task_tmp/server.crt" >/dev/null 2>&1; then
  echo 'Loopback certificate unexpectedly covers an external host' >&2
  exit 1
fi
c++ -std=c++17 -O1 "${openssl_flags[@]}" -IZsign/src -IZsign/src/common \
  Tests/Signing/bundle.cpp Zsign/src/archo.cpp Zsign/src/bundle.cpp Zsign/src/macho.cpp \
  Zsign/src/openssl.cpp Zsign/src/signing.cpp Zsign/src/common/fs.cpp Zsign/src/common/json.cpp \
  Zsign/src/common/log.cpp Zsign/src/common/sha.cpp Zsign/src/common/timer.cpp Zsign/src/common/util.cpp \
  -lssl -lcrypto -o "$task_tmp/bundle-test"
python3 Tests/Signing/bundle.py "$task_tmp/bundle-test"
echo 'Native signing core and local TLS checks passed'
