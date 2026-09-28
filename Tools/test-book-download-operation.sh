#!/usr/bin/env bash
# Executes complete production owner/test files without Apple-only dependencies.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/book-download-operation.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/Sources/LakeOfFireReader" "$work/Tests/LakeOfFireTests"
cp "$root/Sources/LakeOfFireReader/Reader/Books/BookDownloadOperation.swift" "$work/Sources/LakeOfFireReader/"
cp "$root/Tests/LakeOfFireTests/BookDownloadOperationTests.swift" "$work/Tests/LakeOfFireTests/"
cat > "$work/Package.swift" <<'MANIFEST'
// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "BookDownloadOperationPort", targets: [
    .target(name: "LakeOfFireReader"),
    .testTarget(name: "LakeOfFireTests", dependencies: ["LakeOfFireReader"])
], swiftLanguageModes: [.v6])
MANIFEST
swift --version
for configuration in debug release; do
    swift test --package-path "$work" -c "$configuration" -Xswiftc -warnings-as-errors
done
