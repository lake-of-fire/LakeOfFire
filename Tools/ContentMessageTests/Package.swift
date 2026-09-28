// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ContentMessageTests",
    platforms: [.macOS(.v12)],
    targets: [
        .target(name: "LakeOfFireReader"),
        .testTarget(name: "ContentMessageTests", dependencies: ["LakeOfFireReader"]),
    ]
)
