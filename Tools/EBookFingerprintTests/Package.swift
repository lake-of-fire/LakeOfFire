// swift-tools-version: 5.10
import PackageDescription
let package = Package(name: "EBookFingerprint", platforms: [.macOS(.v15)],
    dependencies: [.package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20")],
    targets: [
        .target(name: "LakeOfFireContent", dependencies: ["ZIPFoundation"], path: "Sources"),
        .testTarget(name: "EBookFingerprintTests", dependencies: ["LakeOfFireContent", "ZIPFoundation"], path: "Tests")
    ])
