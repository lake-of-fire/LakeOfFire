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
cp "$root/Sources/LakeOfFireContent/Files/ReaderEBookZIPDirectory.swift" "$work/Sources/"
cp "$root/Sources/LakeOfFireContent/Files/ReaderEBookPackageNamespace.swift" "$work/Sources/"
cp "$root/Tests/LakeOfFireTests/ReaderEBookPackageFingerprintTests.swift" "$work/Tests/"
cp "$root/Tests/LakeOfFireTests/ReaderEBookFingerprintValidationTests.swift" "$work/Tests/"
cp "$root/Tests/LakeOfFireTests/ReaderEBookZIPDirectoryTests.swift" "$work/Tests/"
cp "$root/Tests/LakeOfFireTests/ReaderEBookPackageNamespaceTests.swift" "$work/Tests/"
cp "$root/Tests/LakeOfFireTests/ReaderEBookNamespaceIntegrationTests.swift" "$work/Tests/"
swift test --package-path "$work" "$@"
