// swift-tools-version: 5.10
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "LakeOfFire",
    platforms: [.macOS(.v13), .iOS(.v15)],
    products: [
        .library(
            name: "LakeOfFire",
            type: .dynamic,
            targets: ["LakeOfFire"]),
    ],
    dependencies: [
        .package(url: "https://github.com/lake-of-fire/swiftui-webview.git", branch: "main"),
//        .package(path: "../swiftui-webview"),
        .package(url: "https://github.com/apple/swift-log.git", branch: "main"),
        .package(url: "https://github.com/lake-of-fire/RealmSwiftGaps.git", branch: "main"),
        .package(url: "https://github.com/lake-of-fire/BigSyncKit.git", branch: "main"),
        .package(url: "https://github.com/lake-of-fire/SwiftUIDownloads.git", branch: "main"),
        .package(url: "https://github.com/lake-of-fire/JapaneseLanguageTools.git", branch: "main"),
        .package(url: "https://github.com/lake-of-fire/SwiftUtilities.git", branch: "main"),
        .package(url: "https://github.com/lake-of-fire/LakeImage.git", branch: "main"),
        .package(url: "https://github.com/lake-of-fire/RealmBinary.git", branch: "main"),
//        .package(url: "https://github.com/realm/realm-swift.git", from: "10.54.4"),
        .package(url: "https://github.com/lake-of-fire/AsyncView.git", branch: "main"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", branch: "development"),
//        .package(url: "https://github.com/techprimate/TPPDF.git", branch: "main"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.5.0"),
        .package(url: "https://github.com/Tunous/DebouncedOnChange.git", branch: "main"),
        .package(url: "https://github.com/apple/swift-collections.git", branch: "main"),
        .package(url: "https://github.com/lake-of-fire/opml.git", branch: "master"),
//        .package(url: "https://github.com/nmdias/FeedKit.git", branch: "main"),
        .package(url: "https://github.com/nmdias/FeedKit.git", from: "9.1.2"),
//        .package(url: "https://github.com/satoshi-takano/OpenGraph.git", branch: "main"),
        .package(url: "https://github.com/objecthub/swift-markdownkit.git", branch: "master"),
        .package(url: "https://github.com/satoshi-takano/OpenGraph.git", from: "1.6.0"),
        .package(url: "https://github.com/lake-of-fire/Puppy.git", branch: "main"),
        .package(url: "https://github.com/lake-of-fire/FaviconFinder.git", branch: "main"),
        .package(url: "https://github.com/lake-of-fire/SwiftSoup.git", branch: "master"),
        .package(url: "https://github.com/lake-of-fire/FilePicker.git", branch: "main"),
        .package(url: "https://github.com/shaps80/SwiftUIBackports.git", branch: "main"),
        .package(url: "https://github.com/lake-of-fire/SwiftCloudDrive.git", branch: "main"),
        .package(url: "https://github.com/dagronf/DSFStepperView.git", branch: "main"),
        .package(url: "https://github.com/lake-of-fire/readium-swift-toolkit.git", branch: "develop"),
        .package(url: "https://github.com/EmergeTools/Pow.git", branch: "main"),
//        .package(url: "https://github.com/ksemianov/WrappingHStack.git", branch: "main"),
        .package(url: "https://github.com/lake-of-fire/LakeKit.git", branch: "main"),
        .package(url: "https://github.com/lake-of-fire/LRUCache.git", branch: "main"),
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages this package depends on.
        .target(
            name: "LakeOfFire",
            dependencies: [
                .product(name: "SwiftUIWebView", package: "swiftui-webview"),
                .product(name: "RealmSwift", package: "RealmBinary"),
//                .product(name: "RealmSwift", package: "realm-swift"),
                .product(name: "RealmSwiftGaps", package: "RealmSwiftGaps"),
                .product(name: "AsyncView", package: "AsyncView"),
                .product(name: "OrderedCollections", package: "swift-collections"),
                .product(name: "SwiftUIBackports", package: "SwiftUIBackports"),
                .product(name: "MarkdownKit", package: "Swift-MarkdownKit"),
                .product(name: "OpenGraph", package: "OpenGraph"),
                .product(name: "Logging", package: "swift-log"),
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
                .product(name: "Puppy", package: "Puppy"),
                .product(name: "SwiftUtilities", package: "SwiftUtilities"),
                .product(name: "ZIPFoundation", package: "ZipFoundation"),
                .product(name: "LakeImage", package: "LakeImage"),
                .product(name: "SwiftCloudDrive", package: "SwiftCloudDrive"),
                .product(name: "DSFStepperView", package: "DSFStepperView"),
                .product(name: "ReadiumOPDS", package: "readium-swift-toolkit"),
                .product(name: "Pow", package: "Pow"),
                .product(name: "LakeKit", package: "LakeKit"),
//                .product(name: "WrappingHStack", package: "WrappingHStack"),
                .product(name: "LRUCache", package: "LRUCache"),
            ],
            resources: [
                .copy("Resources/foliate-js/"), // CodeSign errors with "process"...
            ]),
//        .testTarget(
//            name: "LakeOfFireTests",
//            dependencies: ["LakeOfFire"]),
    ]
)
