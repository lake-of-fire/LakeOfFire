// swift-tools-version: 5.9
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
        .package(url: "https://github.com/lake-of-fire/swiftui-webview.git", branch: "main"),
//        .package(path: "../swiftui-webview"),
        .package(url: "https://github.com/lake-of-fire/RealmSwiftGaps.git", branch: "main"),
        .package(url: "https://github.com/lake-of-fire/BigSyncKit.git", branch: "main"),
        .package(url: "https://github.com/lake-of-fire/SwiftUIDownloads.git", branch: "main"),
        .package(url: "https://github.com/lake-of-fire/JapaneseLanguageTools.git", branch: "main"),
        .package(url: "https://github.com/lake-of-fire/SwiftUtilities.git", branch: "main"),
        .package(url: "https://github.com/lake-of-fire/LakeImage.git", branch: "main"),
        .package(url: "https://github.com/lake-of-fire/RealmBinary.git", branch: "main"),
//        .package(url: "https://github.com/realm/realm-swift.git", branch: "master"),
        .package(url: "https://github.com/lake-of-fire/AsyncView.git", branch: "main"),
//        .package(url: "https://github.com/techprimate/TPPDF.git", branch: "main"),
        .package(url: "https://github.com/lake-of-fire/GRDB.swift.git", branch: "master"), // FTS5 fork
        .package(url: "https://github.com/Tunous/DebouncedOnChange.git", branch: "main"),
        .package(url: "https://github.com/apple/swift-collections.git", branch: "main"),
        .package(url: "https://github.com/lake-of-fire/opml", branch: "master"),
        .package(url: "https://github.com/nmdias/FeedKit.git", branch: "master"),
        .package(url: "https://github.com/satoshi-takano/OpenGraph.git", branch: "main"),
        .package(url: "https://github.com/lake-of-fire/FaviconFinder.git", branch: "main"),
//        .package(url: "https://github.com/scinfu/SwiftSoup.git", branch: "master"),
        .package(url: "https://github.com/lake-of-fire/SwiftSoup.git", branch: "master"),
        .package(url: "https://github.com/objecthub/swift-markdownkit", branch: "master"),
        .package(url: "https://github.com/lake-of-fire/FilePicker.git", branch: "main"),
        .package(url: "https://github.com/shaps80/SwiftUIBackports.git", branch: "main"),
        .package(url: "https://github.com/drewmccormack/SwiftCloudDrive.git", branch: "main"),
        .package(url: "https://github.com/dagronf/DSFStepperView.git", branch: "main"),
//        .package(url: "https://github.com/ksemianov/WrappingHStack.git", branch: "main"),
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages this package depends on.
        .target(
            name: "LakeOfFire",
            dependencies: [
                .product(name: "SwiftUIWebView", package: "swiftui-webview"),
                .product(name: "Realm", package: "RealmBinary"),
                .product(name: "RealmSwift", package: "RealmBinary"),
//                .product(name: "Realm", package: "realm-swift"),
//                .product(name: "RealmSwift", package: "realm-swift"),
                .product(name: "RealmSwiftGaps", package: "RealmSwiftGaps"),
                .product(name: "AsyncView", package: "AsyncView"),
                .product(name: "Collections", package: "swift-collections"),
                .product(name: "SwiftUIBackports", package: "SwiftUIBackports"),
                .product(name: "OpenGraph", package: "OpenGraph"),
                .product(name: "OPML", package: "OPML"),
                .product(name: "BigSyncKit", package: "BigSyncKit"),
                .product(name: "SwiftSoup", package: "SwiftSoup"),
                .product(name: "FilePicker", package: "FilePicker"),
                .product(name: "FeedKit", package: "FeedKit"),
                .product(name: "SwiftUIDownloads", package: "SwiftUIDownloads"),
                .product(name: "FaviconFinder", package: "FaviconFinder"),
                .product(name: "DebouncedOnChange", package: "DebouncedOnChange"),
                .product(name: "JapaneseLanguageTools", package: "JapaneseLanguageTools"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "SwiftUtilities", package: "SwiftUtilities"),
                .product(name: "LakeImage", package: "LakeImage"),
                .product(name: "SwiftCloudDrive", package: "SwiftCloudDrive"),
                .product(name: "MarkdownKit", package: "swift-markdownkit"),
                .product(name: "DSFStepperView", package: "DSFStepperView"),
//                .product(name: "WrappingHStack", package: "WrappingHStack"),
                ]),
//        .testTarget(
//            name: "LakeOfFireTests",
//            dependencies: ["LakeOfFire"]),
    ]
)
