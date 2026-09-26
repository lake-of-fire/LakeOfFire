#!/usr/bin/env bash
# Compile actual production snapshot/fingerprint code without the app UI.
set -euo pipefail
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'CryptoKit fingerprint tests require macOS; not executed.' >&2
  exit 1
fi
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
finish() {
  local status=$?
  if [[ -n "${EBOOK_FINGERPRINT_EVIDENCE_DIRECTORY:-}" ]]; then
    if ! mkdir -p "$EBOOK_FINGERPRINT_EVIDENCE_DIRECTORY" ||
       ! cp "$work/Package.swift" "$EBOOK_FINGERPRINT_EVIDENCE_DIRECTORY/test-Package.swift"; then
      echo 'Failed to retain fingerprint test manifest.' >&2
      [[ "$status" != 0 ]] || status=1
    fi
    if [[ -f "$work/Package.resolved" ]]; then
      if ! cp "$work/Package.resolved" "$EBOOK_FINGERPRINT_EVIDENCE_DIRECTORY/Package.resolved"; then
        echo 'Failed to retain fingerprint dependency resolution.' >&2
        [[ "$status" != 0 ]] || status=1
      fi
    fi
  fi
  if ! rm -rf "$work"; then
    [[ "$status" != 0 ]] || status=1
  fi
  exit "$status"
}
trap finish EXIT
mkdir -p "$work/Sources" "$work/Tests"
cp "$root/Tools/EBookFingerprintTests/Package.swift" "$work/Package.swift"
for source in ReaderEBookPackageFingerprint ReaderEBookZIPDirectory ReaderEBookPackageNamespace ReaderEBookPackageSnapshot ReaderEBookSnapshotFingerprint ReaderEBookDirectorySnapshotArchive ReaderEBookServingSession ReaderEBookLocalAvailability ReaderEBookRenditionSelection; do
  cp "$root/Sources/LakeOfFireContent/Files/$source.swift" "$work/Sources/"
done
for suite in ReaderEBookPackageFingerprint ReaderEBookFingerprintValidation ReaderEBookZIPDirectory ReaderEBookPackageNamespace ReaderEBookNamespaceIntegration ReaderEBookPackageSnapshot ReaderEBookCoordinatedSnapshot ReaderEBookZIPPathMetadata ReaderEBookZIPPathFingerprint ReaderEBookServingSession ReaderEBookLocalAvailability ReaderEBookRenditionSelection; do
  cp "$root/Tests/LakeOfFireTests/${suite}Tests.swift" "$work/Tests/"
done
# Compile the actual package reader declaration, not an API double. The cache
# following it depends on the full app/file-manager graph and is outside this
# isolated target. Neither removed import is used by this exact source prefix.
awk '/^public actor ReaderPackageEntrySourceCache/ { exit } !/^import LakeOfFire(Core|Adblock)$/ { print }' \
  "$root/Sources/LakeOfFireContent/Files/Archive+Data.swift" > "$work/Sources/ReaderPackageEntrySource.swift"
swift test --package-path "$work" "$@"
