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
        .package(path: "../BigSyncKit"),
        .package(path: "../SwiftUIDownloads"),
        .package(path: "../JapaneseLanguageTools"),
        .package(path: "../SwiftUtilities"),
        .package(path: "../LakeImage"),
        .package(url: "https://github.com/realm/realm-swift.git", from: "10.28.1"),
        .package(url: "https://github.com/lake-of-fire/AsyncView.git", branch: "main"),
        .package(url: "https://github.com/techprimate/TPPDF.git", branch: "master"),
        .package(url: "https://github.com/lake-of-fire/GRDB.swift.git", branch: "master"), // FTS5 fork
        .package(url: "https://github.com/apple/swift-collections.git", branch: "main"),
        .package(url: "https://github.com/lake-of-fire/opml", branch: "master"),
        .package(url: "https://github.com/nmdias/FeedKit.git", branch: "master"),
        .package(url: "https://github.com/satoshi-takano/OpenGraph.git", branch: "main"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", branch: "master"),
        .package(url: "https://github.com/lake-of-fire/FilePicker.git", branch: "main"),
        .package(url: "https://github.com/witekbobrowski/EPUBKit.git", branch: "main"),
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
                .product(name: "AsyncView", package: "AsyncView"),
                .product(name: "Collections", package: "swift-collections"),
                .product(name: "OpenGraph", package: "OpenGraph"),
                .product(name: "OPML", package: "OPML"),
                .product(name: "BigSyncKit", package: "BigSyncKit"),
                .product(name: "SwiftSoup", package: "SwiftSoup"),
                .product(name: "FilePicker", package: "FilePicker"),
                .product(name: "FeedKit", package: "FeedKit"),
                .product(name: "SwiftUIDownloads", package: "SwiftUIDownloads"),
                .product(name: "EPUBKit", package: "EPUBKit"),
                .product(name: "JapaneseLanguageTools", package: "JapaneseLanguageTools"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "SwiftUtilities", package: "SwiftUtilities"),
                .product(name: "LakeImage", package: "LakeImage"),
            ]),
//        .testTarget(
//            name: "LakeOfFireTests",
//            dependencies: ["LakeOfFire"]),
    ]
)
