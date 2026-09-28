// swift-tools-version: 5.10
import Foundation
import PackageDescription

let reference = ProcessInfo.processInfo.environment["PACKAGE_RESOURCE_ZIP_REFERENCE"] ?? "released"
let zip: Package.Dependency
switch reference {
case "released":
    zip = .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20")
case "locked-development":
    zip = .package(url: "https://github.com/weichsel/ZIPFoundation.git",
                   revision: "d6e0da4509c22274b2775b0e8c741518194acba1")
default:
    fatalError("Unknown PACKAGE_RESOURCE_ZIP_REFERENCE: \(reference)")
}
let package = Package(
    name: "PackageResourceTests",
    platforms: [.macOS(.v12)],
    dependencies: [zip],
    targets: [
        .target(name: "LakeOfFireContent", dependencies: [.product(name: "ZIPFoundation", package: "ZIPFoundation")]),
        .target(name: "LakeOfFireReader", dependencies: ["LakeOfFireContent"]),
        .testTarget(name: "PackageResourceTests", dependencies: ["LakeOfFireContent", "LakeOfFireReader",
            .product(name: "ZIPFoundation", package: "ZIPFoundation")])
    ]
)
