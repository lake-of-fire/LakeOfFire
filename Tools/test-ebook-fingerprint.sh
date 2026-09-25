#!/usr/bin/env bash
# Compile the actual production fingerprint implementation without the app UI.
set -euo pipefail
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'CryptoKit fingerprint tests require macOS; not executed.' >&2
  exit 1
fi
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/Sources" "$work/Tests"
cp "$root/Tools/EBookFingerprintTests/Package.swift" "$work/Package.swift"
cp "$root/Sources/LakeOfFireContent/Files/ReaderEBookPackageFingerprint.swift" "$work/Sources/"
cp "$root/Tests/LakeOfFireTests/ReaderEBookPackageFingerprintTests.swift" "$work/Tests/"
swift test --package-path "$work" "$@"
