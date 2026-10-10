// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "LegacyDocumentsTests",
    platforms: [.macOS(.v15), .iOS(.v15)],
    targets: [
        .target(name: "LakeOfFireContent"),
        .testTarget(name: "LegacyDocumentsTests", dependencies: ["LakeOfFireContent"]),
    ],
    swiftLanguageModes: [.v6]
)
