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
mkdir -p "$task_tmp/package/Sources"
cp Tests/Installation/Integration/Package.swift "$task_tmp/package/Package.swift"
cp Feather.xcworkspace/xcshareddata/swiftpm/Package.resolved "$task_tmp/package/Package.resolved"
cp Tests/Installation/Integration/main.swift Feather/Backend/Server/InstallationHTTPServer.swift Feather/Backend/Server/InstallationTransport.swift "$task_tmp/package/Sources/"
swift run --jobs 4 --package-path "$task_tmp/package" InstallationIntegration "$task_tmp"
