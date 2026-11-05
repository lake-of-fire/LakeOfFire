#!/usr/bin/env bash
# Executes the production MainActor initialization sequence, not WebKit doubles.
# Full ReaderMessageHandlers/WebKit integration still requires the native host.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/Sources" "$work/Tests"
cp "$root/Tools/EBookEntryPathTests/Package.swift" "$work/Package.swift"
cp "$root/Sources/LakeOfFireReader/Reader/Books/ReaderEBookInitialization.swift" "$work/Sources/"
cp "$root/Tests/LakeOfFireTests/ReaderEBookInitializationTests.swift" "$work/Tests/"
swift test --package-path "$work" "$@"
