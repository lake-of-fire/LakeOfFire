#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/Sources" "$work/Tests"
cp "$root/Tools/EBookEntryPathTests/Package.swift" "$work/Package.swift"
cp "$root/Sources/LakeOfFireReader/Reader/Books/EbookEntryPathTransport.swift" "$work/Sources/"
cp "$root/Tests/LakeOfFireTests/EbookEntryPathTransportTests.swift" "$work/Tests/"
swift test --package-path "$work" "$@"
