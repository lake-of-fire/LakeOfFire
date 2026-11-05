#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/book-open-selection.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/Sources/LakeOfFireReader" "$work/Tests/LakeOfFireTests"
cp "$root/Sources/LakeOfFireReader/Reader/Books/BookOpenSelectionCoordinator.swift" "$work/Sources/LakeOfFireReader/"
cp "$root/Tests/LakeOfFireTests/BookOpenSelectionCoordinatorTests.swift" "$work/Tests/LakeOfFireTests/"
cat > "$work/Package.swift" <<'MANIFEST'
// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "BookOpenSelectionPort",
    platforms: [.macOS(.v15), .iOS(.v15)],
    targets: [
        .target(name: "LakeOfFireReader"),
        .testTarget(name: "LakeOfFireTests", dependencies: ["LakeOfFireReader"])
    ],
    swiftLanguageModes: [.v6]
)
MANIFEST
swift --version
for configuration in debug release; do
    swift test --package-path "$work" -c "$configuration" -Xswiftc -warnings-as-errors
done
