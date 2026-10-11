#!/usr/bin/env bash
# Compile actual production snapshot/fingerprint code without the app UI.
set -euo pipefail
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'CryptoKit fingerprint tests require macOS; not executed.' >&2
  exit 1
fi
root="$(cd "$(dirname "$0")/.." && pwd)"
evidence_root="${MANABI_EPUB_EVIDENCE_ROOT:-$HOME/Code/manabi/QualificationEvidence}"
[[ "$evidence_root" == /* ]] || { echo 'Evidence root must be absolute.' >&2; exit 1; }
mkdir -p "$evidence_root"
evidence_root="$(cd "$evidence_root" && pwd -P)"
work="$(mktemp -d "$evidence_root/epub-portable-XXXXXXXX")"
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
  if [[ -d "$work/.build" && ! -L "$work/.build" ]]; then
    mkdir -p "$HOME/.Trash" || status=1
    local trash
    trash="$(mktemp -d "$HOME/.Trash/epub-fingerprint-build-XXXXXXXX")" || { exit 1; }
    mv "$work/.build" "$trash/build" || status=1
  fi
  printf '%s\n' "$status" > "$work/runner-exit-status.txt"
  echo "Fingerprint EPUB evidence: $work (exit $status)" >&2
  exit "$status"
}
trap finish EXIT
mkdir -p "$work/Sources" "$work/Tests"
cp "$root/Tools/EBookFingerprintTests/Package.swift" "$work/Package.swift"
for source in ReaderEBookPackageFingerprint ReaderEBookZIPDirectory ReaderEBookPackageNamespace ReaderEBookPackageSnapshot ReaderEBookSnapshotFingerprint ReaderEBookDirectorySnapshotArchive ReaderEBookServingSession ReaderEBookLocalAvailability ReaderEBookRenditionSelection ReaderEBookInitialRestorePolicy; do
  cp "$root/Sources/LakeOfFireContent/Files/$source.swift" "$work/Sources/"
done
for suite in ReaderEBookPackageFingerprint ReaderEBookFingerprintValidation ReaderEBookZIPDirectory ReaderEBookPackageNamespace ReaderEBookNamespaceIntegration ReaderEBookPackageSnapshot ReaderEBookCoordinatedSnapshot ReaderEBookZIPPathMetadata ReaderEBookZIPPathFingerprint ReaderEBookServingSession ReaderEBookLocalAvailability ReaderEBookRenditionSelection ReaderEBookInitialRestorePolicy; do
  cp "$root/Tests/LakeOfFireTests/${suite}Tests.swift" "$work/Tests/"
done
# Compile the actual package reader declaration, not an API double. The cache
# following it depends on the full app/file-manager graph and is outside this
# isolated target. Neither removed import is used by this exact source prefix.
awk '/^public actor ReaderPackageEntrySourceCache/ { exit } !/^import (LakeOfFire(Core|Adblock)|SwiftUIWebView)$/ { print }' \
  "$root/Sources/LakeOfFireContent/Files/Archive+Data.swift" > "$work/Sources/ReaderPackageEntrySource.swift"
command -v xcsift >/dev/null || { echo 'xcsift is required for build output.' >&2; exit 1; }
version="$(swift --version)"
printf '%s\n' "$version" > "$work/toolchain.txt"
options=(--package-path "$work")
if [[ "$version" =~ Swift\ version\ ([0-9]+)\.([0-9]+) ]]; then
  major="${BASH_REMATCH[1]}"; minor="${BASH_REMATCH[2]}"
  if (( major > 6 || (major == 6 && minor >= 3) )); then
    options+=(--disable-experimental-prebuilts)
  fi
else
  echo 'Cannot establish Swift toolchain version.' >&2; exit 1
fi
set +e
swift test "${options[@]}" "$@" 2>&1 | tee "$work/test.log" | xcsift
statuses=("${PIPESTATUS[@]}")
set -e
printf 'swift=%s\ntee=%s\nxcsift=%s\n' "${statuses[@]}" > "$work/test-status.txt"
for status in "${statuses[@]}"; do
  (( status == 0 )) || exit "$status"
done
