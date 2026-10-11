#!/usr/bin/env bash
# Execute the complete Foundation payload implementations, without WebView/Realm
# doubles. WebView envelope adapters and native persistence require app tests.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
finish() {
  local status=$?
  if [[ -n "${POSITION_PAYLOAD_EVIDENCE_DIRECTORY:-}" ]]; then
    mkdir -p "$POSITION_PAYLOAD_EVIDENCE_DIRECTORY" || status=1
    cp "$work/Package.swift" "$POSITION_PAYLOAD_EVIDENCE_DIRECTORY/test-Package.swift" || status=1
    tar -czf "$POSITION_PAYLOAD_EVIDENCE_DIRECTORY/position-source.tar.gz" -C "$work" Sources Tests || status=1
  fi
  rm -rf "$work" || status=1
  exit "$status"
}
trap finish EXIT
mkdir -p "$work/Sources/LakeOfFireReader" "$work/Tests/PositionPayloadTests"
cp "$root/Tools/PositionPayloadTests/Package.swift" "$work/Package.swift"
cp "$root/Sources/LakeOfFireReader/Reader/ReaderPositionMessagePayloads.swift" "$work/Sources/LakeOfFireReader/"
cp "$root/Tests/LakeOfFireTests/ReaderPositionPayloadPortTests.swift" "$work/Tests/PositionPayloadTests/"
cp "$root/Tests/LakeOfFireTests/ReaderContentEbookInitialRestoreResultTests.swift" "$work/Tests/PositionPayloadTests/"
swift test --package-path "$work" "$@"
