#!/usr/bin/env bash
set -euo pipefail
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'Legacy document migration requires Apple file coordination and exclusive rename; no tests ran.' >&2
  exit 1
fi
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
finish() {
  local status=$?
  if [[ -n "${LEGACY_DOCUMENTS_EVIDENCE_DIRECTORY:-}" ]]; then
    mkdir -p "$LEGACY_DOCUMENTS_EVIDENCE_DIRECTORY" || status=1
    tar -czf "$LEGACY_DOCUMENTS_EVIDENCE_DIRECTORY/executed-source.tar.gz" -C "$work" Package.swift Sources Tests || status=1
  fi
  rm -rf "$work" || status=1
  exit "$status"
}
trap finish EXIT
mkdir -p "$work/Sources/LakeOfFireContent" "$work/Tests/LegacyDocumentsTests"
cp "$root/Tools/LegacyDocumentsTests/Package.swift" "$work/Package.swift"
cp "$root/Sources/LakeOfFireContent/Files/ReaderLegacyDocumentsMigration.swift" "$work/Sources/LakeOfFireContent/"
cp "$root/Tests/LakeOfFireTests/ReaderLegacyDocumentsMigrationTests.swift" "$work/Tests/LegacyDocumentsTests/"
swift test --package-path "$work" -Xswiftc -warnings-as-errors "$@"
