// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "EbookEntryPathTransport",
    platforms: [.macOS("15.0")],
    targets: [
        .target(name: "LakeOfFireReader", path: "Sources"),
        .testTarget(
            name: "EbookEntryPathTransportTests",
            dependencies: ["LakeOfFireReader"],
            path: "Tests"
        ),
    ]
)
