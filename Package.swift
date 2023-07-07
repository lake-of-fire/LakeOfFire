// swift-tools-version: 5.8
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "LakeOfFire",
    platforms: [.macOS(.v12), .iOS(.v15)],
    products: [
        .library(
            name: "LakeOfFire",
            targets: ["LakeOfFire"]),
    ],
    dependencies: [
        .package(path: "../swiftui-webview"),
        .package(path: "../RealmSwiftGaps"),
        .package(url: "https://github.com/realm/realm-swift.git", from: "10.28.1"),
        .package(url: "https://github.com/techprimate/TPPDF.git", branch: "master"),
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages this package depends on.
        .target(
            name: "LakeOfFire",
            dependencies: [
                .product(name: "SwiftUIWebView", package: "swiftui-webview"),
                .product(name: "Realm", package: "realm-swift"),
                .product(name: "RealmSwift", package: "realm-swift"),
                .product(name: "RealmSwiftGaps", package: "RealmSwiftGaps"),
            ]),
//        .testTarget(
//            name: "LakeOfFireTests",
//            dependencies: ["LakeOfFire"]),
    ]
)
