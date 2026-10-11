#!/usr/bin/env bash
# Complete production value decoders plus existing position tests. On macOS the
# WebKit suite additionally receives message bodies from a real WKWebView.
# This does not compile SwiftUIWebView envelope adapters or application consumers.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
finish() {
  local status=$?
  if [[ -n "${CONTENT_MESSAGE_EVIDENCE_DIRECTORY:-}" ]]; then
    mkdir -p "$CONTENT_MESSAGE_EVIDENCE_DIRECTORY" || status=1
    cp "$work/Package.swift" "$CONTENT_MESSAGE_EVIDENCE_DIRECTORY/test-Package.swift" || status=1
    tar -czf "$CONTENT_MESSAGE_EVIDENCE_DIRECTORY/executed-source.tar.gz" -C "$work" Sources Tests || status=1
  fi
  rm -rf "$work" || status=1
  exit "$status"
}
trap finish EXIT
mkdir -p "$work/Sources/LakeOfFireReader" "$work/Tests/ContentMessageTests"
cp "$root/Tools/ContentMessageTests/Package.swift" "$work/Package.swift"
for source in ReaderContentMessagePayloads ReaderPositionMessagePayloads; do
  cp "$root/Sources/LakeOfFireReader/Reader/${source}.swift" "$work/Sources/LakeOfFireReader/"
done
for suite in ReaderContentPayloadPort ReaderContentPayloadWebKit ReaderPositionPayloadPort ReaderContentEbookInitialRestoreResult; do
  cp "$root/Tests/LakeOfFireTests/${suite}Tests.swift" "$work/Tests/ContentMessageTests/"
done
swift test --package-path "$work" "$@"
