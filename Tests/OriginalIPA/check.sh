#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
task_tmp=$(mktemp -d)
trap 'rm -rf "$task_tmp"' EXIT
cp Tests/OriginalIPA/Package.swift "$task_tmp/Package.swift"
mkdir -p "$task_tmp/Sources"
cp Tests/OriginalIPA/Sources/*.swift Feather/Backend/OriginalIPA/OriginalIPAMetadata.swift \
  Feather/Backend/HostedIPA/{HostedIPAArchive,HostedIPAMultipart,UploadProviderCatalog}.swift \
  Feather/Backend/Server/InstallationTransport.swift "$task_tmp/Sources/"
swift run --jobs 4 --package-path "$task_tmp" OriginalIPAChecks "$PWD/upload-providers.json"
