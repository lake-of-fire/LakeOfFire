// swift-tools-version: 5.10
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "LakeOfFire",
    platforms: [.macOS(.v14), .iOS(.v15)],
    products: [
        .library(
            name: "LakeOfFireShareSupport",
            targets: ["LakeOfFireShareSupport"]
        ),
        .library(
            name: "LakeOfFireCore",
            targets: ["LakeOfFireCore"]
        ),
        .library(
            name: "LakeOfFireAdblock",
            targets: ["LakeOfFireAdblock"]
        ),
        .library(
            name: "LakeOfFireContent",
            targets: ["LakeOfFireContent"]
        ),
        .library(
            name: "LakeOfFireContentUI",
            targets: ["LakeOfFireContentUI"]
        ),
        .library(
            name: "LakeOfFireFiles",
            targets: ["LakeOfFireFiles"]
        ),
        .library(
            name: "LakeOfFireWeb",
            targets: ["LakeOfFireWeb"]
        ),
        .library(
            name: "LakeOfFireLibrary",
            targets: ["LakeOfFireLibrary"]
        ),
        .library(
            name: "LakeOfFireReader",
            targets: ["LakeOfFireReader"]
        ),
        .library(
            name: "LakeOfFire",
            targets: ["LakeOfFire"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/lake-of-fire/swiftui-webview.git", branch: "main"),
        .package(url: "https://github.com/lake-of-fire/swift-brave.git", branch: "main"),
        .package(url: "https://github.com/apple/swift-log.git", branch: "main"),
        .package(url: "https://github.com/lake-of-fire/RealmSwiftGaps.git", branch: "main"),
        .package(url: "https://github.com/lake-of-fire/BigSyncKit.git", branch: "main"),
        .package(url: "https://github.com/lake-of-fire/SwiftUIDownloads.git", branch: "main"),
        .package(url: "https://github.com/lake-of-fire/JapaneseLanguageTools.git", branch: "main"),
        .package(path: "../SwiftUtilities"),
        .package(url: "https://github.com/lake-of-fire/LakeImage.git", branch: "main"),
        .package(url: "https://github.com/realm/realm-swift.git", from: "20.0.4"),
        .package(url: "https://github.com/lake-of-fire/AsyncView.git", branch: "main"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", branch: "development"),
        .package(url: "https://github.com/Tunous/DebouncedOnChange.git", branch: "main"),
        .package(url: "https://github.com/apple/swift-collections.git", branch: "main"),
        .package(url: "https://github.com/lake-of-fire/opml.git", branch: "master"),
        .package(url: "https://github.com/nmdias/FeedKit.git", from: "9.1.2"),
        .package(url: "https://github.com/objecthub/swift-markdownkit.git", branch: "master"),
        .package(url: "https://github.com/satoshi-takano/OpenGraph.git", from: "1.6.0"),
        .package(url: "https://github.com/lake-of-fire/FaviconFinder.git", branch: "main"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", branch: "master"),
        .package(url: "https://github.com/lake-of-fire/swift-readability.git", branch: "main"),
        .package(url: "https://github.com/lake-of-fire/swift-dompurify.git", branch: "main"),
        .package(url: "https://github.com/lake-of-fire/FilePicker.git", branch: "main"),
        .package(url: "https://github.com/shaps80/SwiftUIBackports.git", branch: "main"),
        .package(url: "https://github.com/lake-of-fire/SwiftCloudDrive.git", branch: "main"),
        .package(url: "https://github.com/lake-of-fire/readium-swift-toolkit.git", branch: "develop"),
        .package(url: "https://github.com/EmergeTools/Pow.git", branch: "main"),
        .package(url: "https://github.com/lake-of-fire/LakeKit.git", branch: "main"),
        .package(url: "https://github.com/nicklockwood/LRUCache.git", branch: "main"),
        .package(url: "https://github.com/ivan-magda/swiftui-expandable-text.git", branch: "main"),
    ],
    targets: [
        .target(
            name: "LakeOfFireShareSupport",
            dependencies: [
                .product(name: "SwiftUtilities", package: "SwiftUtilities"),
            ]
        ),
        .target(
            name: "LakeOfFireCore",
            dependencies: [
                .product(name: "AsyncView", package: "AsyncView"),
                .product(name: "LakeKit", package: "LakeKit"),
                .product(name: "SwiftUIWebView", package: "swiftui-webview"),
            ]
        ),
        .target(
            name: "LakeOfFireAdblock",
            dependencies: [
                .product(name: "BraveAdblock", package: "swift-brave"),
                .product(name: "OrderedCollections", package: "swift-collections"),
                .product(name: "SwiftUIWebView", package: "swiftui-webview"),
            ],
            resources: [
                .copy("Resources/User Scripts/"),
            ]
        ),
        .target(
            name: "LakeOfFireContent",
            dependencies: [
                "LakeOfFireCore",
                "LakeOfFireAdblock",
                .product(name: "BigSyncKit", package: "BigSyncKit"),
                .product(name: "Collections", package: "swift-collections"),
                .product(name: "FeedKit", package: "FeedKit"),
                .product(name: "LakeKit", package: "LakeKit"),
                .product(name: "MarkdownKit", package: "Swift-MarkdownKit"),
                .product(name: "OPML", package: "OPML"),
                .product(name: "Realm", package: "realm-swift"),
                .product(name: "RealmSwift", package: "realm-swift"),
                .product(name: "RealmSwiftGaps", package: "RealmSwiftGaps"),
                .product(name: "SwiftCloudDrive", package: "SwiftCloudDrive"),
                .product(name: "SwiftSoup", package: "SwiftSoup"),
                .product(name: "SwiftUIDownloads", package: "SwiftUIDownloads"),
                .product(name: "SwiftUIWebView", package: "swiftui-webview"),
                .product(name: "SwiftUtilities", package: "SwiftUtilities"),
                .product(name: "ZIPFoundation", package: "ZipFoundation"),
            ],
            resources: [
                .copy("Resources/CSS/"),
                .copy("Resources/User Scripts/"),
            ]
        ),
        .target(
            name: "LakeOfFireContentUI",
            dependencies: [
                "LakeOfFireContent",
                "LakeOfFireCore",
                "LakeOfFireAdblock",
                .product(name: "LakeImage", package: "LakeImage"),
                .product(name: "LakeKit", package: "LakeKit"),
                .product(name: "Pow", package: "Pow"),
                .product(name: "Realm", package: "realm-swift"),
                .product(name: "RealmSwift", package: "realm-swift"),
                .product(name: "RealmSwiftGaps", package: "RealmSwiftGaps"),
                .product(name: "SwiftUIWebView", package: "swiftui-webview"),
                .product(name: "SwiftUtilities", package: "SwiftUtilities"),
                .product(name: "ZIPFoundation", package: "ZipFoundation"),
            ]
        ),
        .target(
            name: "LakeOfFireFiles",
            dependencies: [
                "LakeOfFireContent",
                "LakeOfFireCore",
                "LakeOfFireAdblock",
                .product(name: "Realm", package: "realm-swift"),
                .product(name: "RealmSwift", package: "realm-swift"),
                .product(name: "ZIPFoundation", package: "ZipFoundation"),
            ]
        ),
        .target(
            name: "LakeOfFireWeb",
            dependencies: [
                "LakeOfFireCore",
                "LakeOfFireAdblock",
                .product(name: "SwiftUIWebView", package: "swiftui-webview"),
            ]
        ),
        .target(
            name: "LakeOfFireLibrary",
            dependencies: [
                "LakeOfFireContent",
                "LakeOfFireContentUI",
                "LakeOfFireCore",
                "LakeOfFireAdblock",
                "LakeOfFireReader",
                .product(name: "AsyncView", package: "AsyncView"),
                .product(name: "DebouncedOnChange", package: "DebouncedOnChange"),
                .product(name: "FaviconFinder", package: "FaviconFinder"),
                .product(name: "FilePicker", package: "FilePicker"),
                .product(name: "LakeImage", package: "LakeImage"),
                .product(name: "LakeKit", package: "LakeKit"),
                .product(name: "OpenGraph", package: "OpenGraph"),
                .product(name: "OPML", package: "OPML"),
                .product(name: "Realm", package: "realm-swift"),
                .product(name: "RealmSwift", package: "realm-swift"),
                .product(name: "RealmSwiftGaps", package: "RealmSwiftGaps"),
                .product(name: "SwiftUIBackports", package: "SwiftUIBackports"),
                .product(name: "SwiftUIWebView", package: "swiftui-webview"),
                .product(name: "SwiftUtilities", package: "SwiftUtilities"),
            ]
        ),
        .target(
            name: "LakeOfFireReader",
            dependencies: [
                "LakeOfFireContent",
                "LakeOfFireContentUI",
                "LakeOfFireFiles",
                "LakeOfFireCore",
                "LakeOfFireAdblock",
                .product(name: "BigSyncKit", package: "BigSyncKit"),
                .product(name: "ExpandableText", package: "swiftui-expandable-text"),
                .product(name: "JapaneseLanguageTools", package: "JapaneseLanguageTools"),
                .product(name: "LRUCache", package: "LRUCache"),
                .product(name: "LakeImage", package: "LakeImage"),
                .product(name: "LakeKit", package: "LakeKit"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "OrderedCollections", package: "swift-collections"),
                .product(name: "Pow", package: "Pow"),
                .product(name: "R2Shared", package: "readium-swift-toolkit"),
                .product(name: "ReadiumOPDS", package: "readium-swift-toolkit"),
                .product(name: "Realm", package: "realm-swift"),
                .product(name: "RealmSwift", package: "realm-swift"),
                .product(name: "RealmSwiftGaps", package: "RealmSwiftGaps"),
                .product(name: "SwiftCloudDrive", package: "SwiftCloudDrive"),
                .product(name: "SwiftDOMPurify", package: "swift-dompurify"),
                .product(name: "SwiftReadability", package: "swift-readability"),
                .product(name: "SwiftSoup", package: "SwiftSoup"),
                .product(name: "SwiftUIBackports", package: "SwiftUIBackports"),
                .product(name: "SwiftUIDownloads", package: "SwiftUIDownloads"),
                .product(name: "SwiftUIWebView", package: "swiftui-webview"),
                .product(name: "SwiftUtilities", package: "SwiftUtilities"),
                .product(name: "ZIPFoundation", package: "ZipFoundation"),
            ],
            resources: [
                .copy("Resources/foliate-js/"),
                .copy("Resources/User Scripts/"),
            ]
        ),
        .target(
            name: "LakeOfFire",
            dependencies: [
                "LakeOfFireCore",
                "LakeOfFireAdblock",
                "LakeOfFireContent",
                "LakeOfFireContentUI",
                "LakeOfFireFiles",
                "LakeOfFireWeb",
                "LakeOfFireLibrary",
                "LakeOfFireReader",
            ]
        ),
    ]
)
