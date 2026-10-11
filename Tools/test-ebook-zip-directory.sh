#!/usr/bin/env bash
# Portable structural tests; this does not substitute for full scanner tests.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
evidence_root="${MANABI_EPUB_EVIDENCE_ROOT:-$HOME/Code/manabi/QualificationEvidence}"
[[ "$evidence_root" == /* ]] || { echo 'Evidence root must be absolute.' >&2; exit 1; }
mkdir -p "$evidence_root"
evidence_root="$(cd "$evidence_root" && pwd -P)"
work="$(mktemp -d "$evidence_root/epub-portable-XXXXXXXX")"
finish() {
  local status=$?
  trap - EXIT
  if [[ -d "$work/.build" && ! -L "$work/.build" ]]; then
    mkdir -p "$HOME/.Trash" || status=1
    local trash
    trash="$(mktemp -d "$HOME/.Trash/epub-runner-build-XXXXXXXX")" || { exit 1; }
    mv "$work/.build" "$trash/build" || status=1
  fi
  printf '%s\n' "$status" > "$work/runner-exit-status.txt"
  echo "Portable EPUB evidence: $work (exit $status)" >&2
  exit "$status"
}
trap finish EXIT
mkdir -p "$work/Sources/LakeOfFireContent" "$work/Tests/ZIPTests"
cat > "$work/Package.swift" <<'SWIFT'
// swift-tools-version: 5.10
import PackageDescription
let package = Package(name: "ZIPPreflight", targets: [.target(name: "LakeOfFireContent"), .testTarget(name: "ZIPTests", dependencies: ["LakeOfFireContent"])])
SWIFT
cp "$root/Sources/LakeOfFireContent/Files/ReaderEBookZIPDirectory.swift" "$work/Sources/LakeOfFireContent/"
# Copy the real production error declaration, not an alternate implementation.
awk '/public enum ReaderEBookFingerprintError/,/^}/' "$root/Sources/LakeOfFireContent/Files/ReaderEBookPackageFingerprint.swift" > "$work/Sources/LakeOfFireContent/ReaderEBookFingerprintError.swift"
for suite in ReaderEBookZIPDirectory ReaderEBookZIPPathMetadata; do
  cp "$root/Tests/LakeOfFireTests/${suite}Tests.swift" "$work/Tests/ZIPTests/"
done
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
