#!/usr/bin/env bash
# Runs the actual Foundation-only namespace validator. No archive, CryptoKit,
# Realm or app behavior is simulated by this portable subset.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/Sources" "$work/Tests"
cp "$root/Tools/EBookNamespaceTests/Package.swift" "$work/Package.swift"
cp "$root/Sources/LakeOfFireContent/Files/ReaderEBookPackageNamespace.swift" "$work/Sources/"
cp "$root/Tests/LakeOfFireTests/ReaderEBookPackageNamespaceTests.swift" "$work/Tests/"
swift test --package-path "$work" "$@"
