#!/usr/bin/env bash
# Compile actual production snapshot/fingerprint code without the app UI.
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
for source in ReaderEBookPackageFingerprint ReaderEBookZIPDirectory ReaderEBookPackageNamespace ReaderEBookPackageSnapshot ReaderEBookSnapshotFingerprint ReaderEBookDirectorySnapshotArchive; do
  cp "$root/Sources/LakeOfFireContent/Files/$source.swift" "$work/Sources/"
done
for suite in ReaderEBookPackageFingerprint ReaderEBookFingerprintValidation ReaderEBookZIPDirectory ReaderEBookPackageNamespace ReaderEBookNamespaceIntegration ReaderEBookPackageSnapshot ReaderEBookCoordinatedSnapshot; do
  cp "$root/Tests/LakeOfFireTests/${suite}Tests.swift" "$work/Tests/"
done
swift test --package-path "$work" "$@"
