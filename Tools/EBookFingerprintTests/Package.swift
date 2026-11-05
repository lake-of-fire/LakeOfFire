// swift-tools-version: 5.10
import Foundation
import PackageDescription

// Do not follow a moving branch in evidence runs. Lake's package manifest uses
// development; keep its Package.resolved snapshot alongside the frozen v1 baseline.
let reference = ProcessInfo.processInfo.environment["ZIPFOUNDATION_TEST_REFERENCE"] ?? "released"
let zip: Package.Dependency
switch reference {
case "released":
    zip = .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20")
case "locked-development":
    zip = .package(url: "https://github.com/weichsel/ZIPFoundation.git",
                   revision: "d6e0da4509c22274b2775b0e8c741518194acba1")
default:
    fatalError("Unknown ZIPFOUNDATION_TEST_REFERENCE: " + reference)
}
let package = Package(name: "EBookFingerprint", platforms: [.macOS("15.0")],
    dependencies: [zip],
    targets: [
        .target(name: "LakeOfFireContent", dependencies: ["ZIPFoundation"], path: "Sources"),
        .testTarget(name: "EBookFingerprintTests", dependencies: ["LakeOfFireContent", "ZIPFoundation"], path: "Tests")
    ])
