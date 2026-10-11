// swift-tools-version: 5.10
import PackageDescription
let package = Package(
    name: "NativeRestoreTests",
    platforms: [.macOS("15.0"), .iOS(.v15)],
    products: [.executable(name: "export-native-restore-fixtures", targets: ["FixtureExport"])],
    targets: [
        .target(name: "LakeOfFireContent"),
        .target(name: "LakeOfFireReader", dependencies: ["LakeOfFireContent"]),
        .executableTarget(name: "FixtureExport", dependencies: ["LakeOfFireContent", "LakeOfFireReader"]),
        .testTarget(name: "NativeRestoreTests", dependencies: ["LakeOfFireContent", "LakeOfFireReader"]),
    ]
)
