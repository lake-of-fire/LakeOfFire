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
        .package(path: "../swiftui-webview"),
        .package(path: "../swift-brave"),
        .package(url: "https://github.com/apple/swift-log.git", revision: "d5dbc04d530c510eb4e9072c4958c511e612b2b1"),
        .package(url: "https://github.com/lake-of-fire/RealmSwiftGaps.git", revision: "f2f5e54628b3474f281ae3d70fc3aaed471a9ecd"),
        .package(url: "https://github.com/lake-of-fire/BigSyncKit.git", revision: "cc8fe4ae9346f568cb9a337a670a5a5712ad2735"),
        .package(url: "https://github.com/lake-of-fire/SwiftUIDownloads.git", revision: "03706f88e149d0e07e9a27ade6da8a8985a5ca9f"),
        .package(url: "https://github.com/lake-of-fire/JapaneseLanguageTools.git", revision: "594caf74a6f2304300ee90458a05b5c6f17c6ce8"),
        .package(url: "https://github.com/lake-of-fire/SwiftUtilities.git", revision: "15f8313b36c066dedffd662809b52de965efa6b6"),
        .package(url: "https://github.com/lake-of-fire/LakeImage.git", revision: "beb6dc915860cef92db6ea9e3c6bfef494c8b707"),
        .package(url: "https://github.com/realm/realm-swift.git", from: "20.0.3"),
        .package(url: "https://github.com/lake-of-fire/AsyncView.git", revision: "4f73cccaae9ba768eccee63579cd84f1fe128d44"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", branch: "development"),
        .package(url: "https://github.com/Tunous/DebouncedOnChange.git", revision: "2583a30a8d277c3475c1b3a10b0f902a7be34f3b"),
        .package(url: "https://github.com/apple/swift-collections.git", revision: "6741fb960b770d26e416a472e32c23077ed181e7"),
        .package(url: "https://github.com/lake-of-fire/opml.git", branch: "master"),
        .package(url: "https://github.com/nmdias/FeedKit.git", from: "9.1.2"),
        .package(url: "https://github.com/objecthub/swift-markdownkit.git", branch: "master"),
        .package(url: "https://github.com/satoshi-takano/OpenGraph.git", from: "1.6.0"),
        .package(url: "https://github.com/lake-of-fire/FaviconFinder.git", revision: "9c52cbc77fb4288cc2fac5c8d74ec1f433e31b46"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", branch: "master"),
        .package(url: "https://github.com/lake-of-fire/swift-readability.git", revision: "d4f0824f5f4496791d01a83493ffccf3dd89c4cf"),
        .package(url: "https://github.com/lake-of-fire/swift-dompurify.git", revision: "c4715ebb7ac053ffa9e163d93ac5592b8c6e86bc"),
        .package(url: "https://github.com/lake-of-fire/FilePicker.git", revision: "4e445870eb07ae9c1e1aeedbb9b1098eaaabfb69"),
        .package(url: "https://github.com/shaps80/SwiftUIBackports.git", revision: "2beebc6960375b3af3655447586e768a5271a5c2"),
        .package(url: "https://github.com/lake-of-fire/SwiftCloudDrive.git", revision: "0a84ea27d394fe0ed92e9b7809d84cfaa1942442"),
        .package(url: "https://github.com/lake-of-fire/readium-swift-toolkit.git", branch: "develop"),
        .package(url: "https://github.com/EmergeTools/Pow.git", revision: "f650bd26c71084a49a99185f4b3e9c05a4a3ac8d"),
        .package(url: "https://github.com/lake-of-fire/LakeKit.git", revision: "973339d637722b5b7c8743afe8417a8a958aba9f"),
        .package(url: "https://github.com/nicklockwood/LRUCache.git", revision: "cb5b2bd0da83ad29c0bec762d39f41c8ad0eaf3e"),
        .package(url: "https://github.com/ivan-magda/swiftui-expandable-text.git", revision: "10f0bcd7687a1fd7f705f734153fadb5710ec51e"),
    ],
    targets: [
        .target(
            name: "LakeOfFireShareSupport",
            dependencies: [
                "LakeOfFireContent",
                .product(name: "SwiftSoup", package: "SwiftSoup"),
                .product(name: "SwiftUtilities", package: "SwiftUtilities"),
            ]
        ),
        .target(
            name: "LakeOfFireCore",
            dependencies: [
                .product(name: "AsyncView", package: "AsyncView"),
                .product(name: "LakeKit", package: "LakeKit"),
                .product(name: "Realm", package: "realm-swift"),
                .product(name: "RealmSwift", package: "realm-swift"),
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
                .product(name: "MarkdownKit", package: "Swift-MarkdownKit"),
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
                .product(name: "AsyncView", package: "AsyncView"),
                .product(name: "BigSyncKit", package: "BigSyncKit"),
                .product(name: "Collections", package: "swift-collections"),
                .product(name: "DebouncedOnChange", package: "DebouncedOnChange"),
                .product(name: "ExpandableText", package: "swiftui-expandable-text"),
                .product(name: "FeedKit", package: "FeedKit"),
                .product(name: "FaviconFinder", package: "FaviconFinder"),
                .product(name: "FilePicker", package: "FilePicker"),
                .product(name: "JapaneseLanguageTools", package: "JapaneseLanguageTools"),
                .product(name: "LRUCache", package: "LRUCache"),
                .product(name: "LakeImage", package: "LakeImage"),
                .product(name: "LakeKit", package: "LakeKit"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "MarkdownKit", package: "Swift-MarkdownKit"),
                .product(name: "OPML", package: "OPML"),
                .product(name: "OpenGraph", package: "OpenGraph"),
                .product(name: "OrderedCollections", package: "swift-collections"),
                .product(name: "Pow", package: "Pow"),
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
