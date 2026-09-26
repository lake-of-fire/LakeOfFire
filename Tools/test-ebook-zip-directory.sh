#!/usr/bin/env bash
# Portable structural tests; this does not substitute for full scanner tests.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
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
swift test --package-path "$work" "$@"
