// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ReaderPositionPayloadTests",
    platforms: [.macOS(.v12)],
    targets: [
        .target(name: "LakeOfFireReader"),
        .testTarget(name: "PositionPayloadTests", dependencies: ["LakeOfFireReader"]),
    ]
)
