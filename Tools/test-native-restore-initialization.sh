#!/usr/bin/env bash
# Real bound-stage coordinator plus the actual native saved-value/bridge.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/Sources/LakeOfFireContent" "$work/Sources/LakeOfFireReader" "$work/Tests/InitializationTests"
cat > "$work/Package.swift" <<'SWIFT'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "NativeRestoreInitializationTests",
    platforms: [.macOS("15.0"), .iOS(.v15)],
    targets: [
        .target(name: "LakeOfFireContent"),
        .target(name: "LakeOfFireReader", dependencies: ["LakeOfFireContent"]),
        .testTarget(name: "InitializationTests", dependencies: ["LakeOfFireContent", "LakeOfFireReader"]),
    ], swiftLanguageModes: [.v6])
SWIFT
cp "$root/Sources/LakeOfFireContent/Files/ReaderEBookInitialRestorePolicy.swift" "$work/Sources/LakeOfFireContent/"
cp "$root/Sources/LakeOfFireContent/Reader/ReaderContentEbookInitialRestore.swift" "$work/Sources/LakeOfFireContent/"
cp "$root/Sources/LakeOfFireReader/Reader/ReaderEBookInitialRestoreBridgeRequest.swift" "$work/Sources/LakeOfFireReader/"
cp "$root/Sources/LakeOfFireReader/Reader/Books/ReaderEBookInitialization.swift" "$work/Sources/LakeOfFireReader/"
cp "$root/Tests/LakeOfFireTests/ReaderEBookInitializationTests.swift" "$work/Tests/InitializationTests/"
cp "$root/Tests/LakeOfFireTests/ReaderEBookNativeRestoreInitializationTests.swift" "$work/Tests/InitializationTests/"
swift test --package-path "$work" -Xswiftc -warnings-as-errors "$@"
