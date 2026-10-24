import Foundation
import RealmSwift
import RealmSwiftGaps
import XCTest
@testable import LakeOfFireContent

final class FeedOPMLRefreshMetadataTests: XCTestCase {

    func testOPMLURLReplacementInvalidatesPreviousRefreshMetadata() async throws {
        try await verifyImportedURLMetadata(
            replacementURL: "https://other.example/new.xml", shouldClear: true
        )
    }

    func testOPMLSameURLPreservesRefreshMetadata() async throws {
        try await verifyImportedURLMetadata(
            replacementURL: "https://example.org/original.xml", shouldClear: false
        )
    }

    private func verifyImportedURLMetadata(replacementURL: String, shouldClear: Bool) async throws {
        let configuration = makeConfiguration()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let feedID = UUID()
        let originalURL = directory.appendingPathComponent("original.opml")
        let updatedURL = directory.appendingPathComponent("updated.opml")
        let originalXML = """
        <opml version="2.0"><head><title>Feeds</title></head><body>
          <outline text="Original" uuid="\(feedID.uuidString)" type="rss" xmlUrl="https://example.org/original.xml" />
        </body></opml>
        """
        let updatedXML = """
        <opml version="2.0"><head><title>Feeds</title></head><body>
          <outline text="Updated title" uuid="\(feedID.uuidString)" type="rss" xmlUrl="\(replacementURL)" />
        </body></opml>
        """
        try Data(originalXML.utf8).write(to: originalURL)
        try Data(updatedXML.utf8).write(to: updatedURL)
        try await Task { @RealmBackgroundActor in
            try await LibraryDataManager.shared.importOPML(
                fileURL: originalURL, realmConfiguration: configuration
            )
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            let feed = try XCTUnwrap(realm.object(ofType: Feed.self, forPrimaryKey: feedID))
            try await realm.asyncWritePreservingOwnership {
                feed.lastFetchedRSSURL = feed.rssUrl
                feed.lastFetchedETag = "\"old-resource\""
                feed.lastFetchedModifiedAt = Date(timeIntervalSince1970: 100)
                feed.lastRefreshedEntriesAt = Date(timeIntervalSince1970: 200)
            }
            try await LibraryDataManager.shared.importOPML(
                fileURL: updatedURL, realmConfiguration: configuration
            )
            XCTAssertEqual(feed.rssUrl.absoluteString, replacementURL)
            XCTAssertEqual(feed.title, "Updated title")
            XCTAssertEqual(realm.objects(Feed.self).count, 1)
            if shouldClear {
                XCTAssertNil(feed.lastFetchedRSSURL)
                XCTAssertNil(feed.lastFetchedETag)
                XCTAssertNil(feed.lastFetchedModifiedAt)
                XCTAssertNil(feed.lastRefreshedEntriesAt)
            } else {
                XCTAssertEqual(feed.lastFetchedRSSURL?.absoluteString, "https://example.org/original.xml")
                XCTAssertEqual(feed.lastFetchedETag, "\"old-resource\"")
                XCTAssertEqual(feed.lastFetchedModifiedAt, Date(timeIntervalSince1970: 100))
                XCTAssertEqual(feed.lastRefreshedEntriesAt, Date(timeIntervalSince1970: 200))
            }
        }.value
    }

    private func makeConfiguration() -> Realm.Configuration {
        var configuration = Realm.Configuration(
            inMemoryIdentifier: UUID().uuidString
        )
        configuration.objectTypes = [
            LibraryConfiguration.self,
            FeedCategory.self,
            Feed.self,
            FeedDirectory.self,
            UserScript.self,
            UserScriptAllowedDomain.self,
        ]
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        return configuration
    }
}
