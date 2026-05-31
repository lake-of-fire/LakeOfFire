import XCTest
import RealmSwift
import RealmSwiftGaps
import SwiftUIDownloads
@testable import LakeOfFireContent

final class FeedDirectoryTests: XCTestCase {
    private static let realmConfigurationSemaphore = DispatchSemaphore(value: 1)

    func testCategoryExposesRootDirectoriesAndRootFeedsSeparately() throws {
        var config = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        config.objectTypes = [FeedCategory.self, FeedDirectory.self, Feed.self]
        let realm = try Realm(configuration: config)

        let categoryID = UUID()
        let directoryID = UUID()
        let category = FeedCategory()
        category.id = categoryID
        category.title = "News"
        category.backgroundImageUrl = URL(string: "https://example.com/news.jpg")!

        let directory = FeedDirectory()
        directory.id = directoryID
        directory.categoryID = categoryID
        directory.title = "Asahi Shimbun"
        directory.ordinal = 1

        let rootFeed = Feed()
        rootFeed.id = UUID()
        rootFeed.categoryID = categoryID
        rootFeed.title = "Apple Newsroom"
        rootFeed.ordinal = 0
        rootFeed.rssUrl = URL(string: "https://example.com/root.xml")!
        rootFeed.iconUrl = URL(string: "https://example.com/root.ico")!

        let earlierRootFeed = Feed()
        earlierRootFeed.id = UUID()
        earlierRootFeed.categoryID = categoryID
        earlierRootFeed.title = "Asahi Easy News"
        earlierRootFeed.ordinal = 2
        earlierRootFeed.rssUrl = URL(string: "https://example.com/earlier-root.xml")!
        earlierRootFeed.iconUrl = URL(string: "https://example.com/earlier-root.ico")!

        let directoryFeed = Feed()
        directoryFeed.id = UUID()
        directoryFeed.categoryID = categoryID
        directoryFeed.directoryID = directoryID
        directoryFeed.title = "Directory Feed"
        directoryFeed.ordinal = 0
        directoryFeed.rssUrl = URL(string: "https://example.com/directory.xml")!
        directoryFeed.iconUrl = URL(string: "https://example.com/directory.ico")!

        try realm.write {
            realm.add([category, directory, rootFeed, earlierRootFeed, directoryFeed])
        }

        XCTAssertEqual(category.getDirectories()?.map(\.id), [directoryID])
        XCTAssertEqual(category.getFeeds()?.map(\.id), [rootFeed.id, earlierRootFeed.id])
        XCTAssertEqual(category.getFeeds()?.map(\.ordinal), [0, 2])
        XCTAssertEqual(category.getCollectionChildren()?.map(\.id), [rootFeed.id, earlierRootFeed.id, directoryID])
        XCTAssertEqual(category.getCollectionChildren()?.map(\.ordinal), [0, 2, 1])
        XCTAssertEqual(directory.getFeeds()?.map(\.id), [directoryFeed.id])
    }

    func testOPMLDirectoryImportAndManagedRootFeedMigration() async throws {
        Self.realmConfigurationSemaphore.wait()
        defer { Self.realmConfigurationSemaphore.signal() }

        try await verifyNestedOPMLImportAssignsMetadataAndSiblingOrdinals()
        try await verifyManagedOPMLImportMovesExistingRootFeedIntoNewDirectory()
    }

    private func verifyNestedOPMLImportAssignsMetadataAndSiblingOrdinals() async throws {
        let originalConfiguration = LibraryDataManager.realmConfiguration
        defer { LibraryDataManager.realmConfiguration = originalConfiguration }
        let realmURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).realm")
        defer { try? FileManager.default.removeItem(at: realmURL) }
        var config = DefaultRealmConfiguration.configuration
        config.inMemoryIdentifier = nil
        config.fileURL = realmURL
        XCTAssertNotNil(config.fileURL)
        LibraryDataManager.realmConfiguration = config

        let categoryID = UUID()
        let rootFeedID = UUID()
        let directoryID = UUID()
        let directoryFeedID = UUID()
        let nestedDirectoryID = UUID()
        let nestedFeedID = UUID()
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).opml")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let opmlXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0">
          <head>
            <ownerName>alex</ownerName>
          </head>
          <body>
            <outline text="News" title="News" uuid="\(categoryID.uuidString)" backgroundImageUrl="https://example.com/news.jpg">
              <outline text="Root Feed" uuid="\(rootFeedID.uuidString)" xmlUrl="https://example.com/root.xml" iconUrl="https://example.com/root.ico" />
              <outline text="Asahi Shimbun" title="Asahi Shimbun" uuid="\(directoryID.uuidString)" markdownDescription="Asahi Shimbun news feeds grouped by topic." iconUrl="https://example.com/asahi.ico">
                <outline text="Breaking News" uuid="\(directoryFeedID.uuidString)" xmlUrl="https://example.com/breaking.xml" iconUrl="https://example.com/breaking.ico" />
                <outline text="Nested Directory" uuid="\(nestedDirectoryID.uuidString)">
                  <outline text="Nested Feed" uuid="\(nestedFeedID.uuidString)" xmlUrl="https://example.com/nested.xml" iconUrl="https://example.com/nested.ico" />
                </outline>
              </outline>
            </outline>
          </body>
        </opml>
        """
        try opmlXML.write(to: fileURL, atomically: true, encoding: .utf8)

        let manager = LibraryDataManager()
        try await manager.importOPML(fileURL: fileURL, realmConfiguration: config)

        let snapshot = try await { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: config)
            let category = realm.object(ofType: FeedCategory.self, forPrimaryKey: categoryID)
            let directory = realm.object(ofType: FeedDirectory.self, forPrimaryKey: directoryID)
            let nestedDirectory = realm.object(ofType: FeedDirectory.self, forPrimaryKey: nestedDirectoryID)
            let rootFeed = realm.object(ofType: Feed.self, forPrimaryKey: rootFeedID)
            let directoryFeed = realm.object(ofType: Feed.self, forPrimaryKey: directoryFeedID)
            let nestedFeed = realm.object(ofType: Feed.self, forPrimaryKey: nestedFeedID)
            return (
                category?.title,
                directory?.categoryID,
                directory?.parentDirectoryID,
                directory?.ordinal,
                directory?.markdownDescription,
                directory?.iconUrl,
                rootFeed?.categoryID,
                rootFeed?.directoryID,
                rootFeed?.ordinal,
                directoryFeed?.directoryID,
                directoryFeed?.ordinal,
                nestedDirectory?.parentDirectoryID,
                nestedDirectory?.ordinal,
                nestedFeed?.directoryID,
                nestedFeed?.ordinal
            )
        }()

        XCTAssertEqual(snapshot.0, "News")
        XCTAssertEqual(snapshot.1, categoryID)
        XCTAssertNil(snapshot.2)
        XCTAssertEqual(snapshot.3, 1)
        XCTAssertEqual(snapshot.4, "Asahi Shimbun news feeds grouped by topic.")
        XCTAssertEqual(snapshot.5, URL(string: "https://example.com/asahi.ico"))
        XCTAssertEqual(snapshot.6, categoryID)
        XCTAssertNil(snapshot.7)
        XCTAssertEqual(snapshot.8, 0)
        XCTAssertEqual(snapshot.9, directoryID)
        XCTAssertEqual(snapshot.10, 0)
        XCTAssertEqual(snapshot.11, directoryID)
        XCTAssertEqual(snapshot.12, 1)
        XCTAssertEqual(snapshot.13, nestedDirectoryID)
        XCTAssertEqual(snapshot.14, 0)
    }

    private func verifyManagedOPMLImportMovesExistingRootFeedIntoNewDirectory() async throws {
        let originalConfiguration = LibraryDataManager.realmConfiguration
        let originalOPMLURLs = LibraryConfiguration.opmlURLs
        defer {
            LibraryDataManager.realmConfiguration = originalConfiguration
            LibraryConfiguration.opmlURLs = originalOPMLURLs
        }
        var config = DefaultRealmConfiguration.configuration
        let realmURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).realm")
        defer { try? FileManager.default.removeItem(at: realmURL) }
        config.inMemoryIdentifier = nil
        config.fileURL = realmURL
        XCTAssertNotNil(config.fileURL)
        LibraryDataManager.realmConfiguration = config

        let oldOPMLURL = URL(string: "https://reader.manabi.io/static/reader/manabi-reader-defaults.opml")!
        let newOPMLURL = URL(string: "https://reader.manabi.io/static/reader/manabi-reader-defaults.v2.opml")!
        LibraryConfiguration.opmlURLs = [newOPMLURL]

        let categoryID = UUID()
        let directoryID = UUID()
        let feedID = UUID()
        let oldFeedURL = URL(string: "https://manabi.io/media/feeds/asahi.rss")!
        let newFeedURL = URL(string: "https://www.asahi.com/rss/asahi/newsheadlines.rdf")!
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).opml")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        try await { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: config)
            let configuration = LibraryConfiguration()
            let category = FeedCategory()
            category.id = categoryID
            category.title = "News"
            category.backgroundImageUrl = URL(string: "https://example.com/news.jpg")!
            category.opmlURL = oldOPMLURL
            let feed = Feed()
            feed.id = feedID
            feed.categoryID = categoryID
            feed.title = "Asahi Shimbun"
            feed.rssUrl = oldFeedURL
            feed.iconUrl = URL(string: "https://www.asahi.com/favicon.ico")!

            try await realm.asyncWrite {
                configuration.categoryIDs.append(categoryID)
                realm.add(configuration, update: .modified)
                realm.add(category, update: .modified)
                realm.add(feed, update: .modified)
            }
        }()

        let opmlXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0">
          <body>
            <outline text="News" title="News" uuid="\(categoryID.uuidString)" backgroundImageUrl="https://example.com/news.jpg">
              <outline text="Asahi Shimbun" title="Asahi Shimbun" uuid="\(directoryID.uuidString)" markdownDescription="A leading Japanese daily." iconUrl="https://www.asahi.com/favicon.ico">
                <outline text="Asahi Shimbun Breaking News" title="Asahi Shimbun Breaking News" uuid="\(feedID.uuidString)" type="rss" xmlUrl="\(newFeedURL.absoluteString)" iconUrl="https://www.asahi.com/favicon.ico" />
              </outline>
            </outline>
          </body>
        </opml>
        """
        try opmlXML.write(to: fileURL, atomically: true, encoding: .utf8)
        let download = Downloadable(url: newOPMLURL, name: "Defaults v2", localDestination: fileURL)

        let manager = LibraryDataManager()
        try await manager.importOPML(fileURL: fileURL, fromDownload: download, realmConfiguration: config)

        let snapshot = try await { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: config)
            let category = realm.object(ofType: FeedCategory.self, forPrimaryKey: categoryID)
            let directory = realm.object(ofType: FeedDirectory.self, forPrimaryKey: directoryID)
            let feed = realm.object(ofType: Feed.self, forPrimaryKey: feedID)
            return (
                category?.opmlURL,
                category?.getFeeds()?.map(\.id),
                category?.getDirectories()?.map(\.id),
                directory?.categoryID,
                directory?.opmlURL,
                feed?.title,
                feed?.rssUrl,
                feed?.categoryID,
                feed?.directoryID
            )
        }()

        XCTAssertEqual(snapshot.0, newOPMLURL)
        XCTAssertEqual(snapshot.1, [])
        XCTAssertEqual(snapshot.2, [directoryID])
        XCTAssertEqual(snapshot.3, categoryID)
        XCTAssertEqual(snapshot.4, newOPMLURL)
        XCTAssertEqual(snapshot.5, "Asahi Shimbun Breaking News")
        XCTAssertEqual(snapshot.6, newFeedURL)
        XCTAssertEqual(snapshot.7, categoryID)
        XCTAssertEqual(snapshot.8, directoryID)
    }
}
