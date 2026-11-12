import Foundation
import RealmSwift
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireLibrary

@MainActor
final class LibraryFeedPreviewLoaderTests: XCTestCase {
    func testOpenFailureKeepsPublishedPreviewAndSamePathRetryPublishesRecoveredFeed() throws {
        let feedID = UUID()
        let originalConfiguration = try configuration()
        try installFeed(id: feedID, title: "Displayed preview", configuration: originalConfiguration)
        var publishedTitle: String?
        var publicationCount = 0
        LibraryFeedPreviewLoader.refresh(feedID: feedID, configuration: originalConfiguration) { feed in
            publishedTitle = feed?.title
            publicationCount += 1
        }
        XCTAssertEqual(publishedTitle, "Displayed preview")
        XCTAssertEqual(publicationCount, 1)

        var retryConfiguration = try configuration()
        let retryURL = try XCTUnwrap(retryConfiguration.fileURL)
        try Data("This is not a Realm database".utf8).write(to: retryURL)
        // The production loader performs the actual failing Realm open. It must
        // not invoke the view's publication/clear callback on that failure.
        LibraryFeedPreviewLoader.refresh(feedID: feedID, configuration: retryConfiguration) { feed in
            publishedTitle = feed?.title
            publicationCount += 1
        }
        XCTAssertEqual(publishedTitle, "Displayed preview")
        XCTAssertEqual(publicationCount, 1)

        try FileManager.default.removeItem(at: retryURL)
        configureLakeOfFireMutationTrackingForTesting(&retryConfiguration)
        try installFeed(id: feedID, title: "Recovered preview", configuration: retryConfiguration)
        LibraryFeedPreviewLoader.refresh(feedID: feedID, configuration: retryConfiguration) { feed in
            publishedTitle = feed?.title
            publicationCount += 1
        }
        XCTAssertEqual(publishedTitle, "Recovered preview")
        XCTAssertEqual(publicationCount, 2, "A later refresh must attempt the same path again")
    }

    func testSuccessfullyOpenedRealmWithMissingFeedPublishesNil() throws {
        let configuration = try configuration()
        let existingID = UUID()
        try installFeed(id: existingID, title: "Another feed", configuration: configuration)
        var publishedID: UUID? = existingID
        var publicationCount = 0
        LibraryFeedPreviewLoader.refresh(feedID: UUID(), configuration: configuration) { feed in
            publishedID = feed?.id
            publicationCount += 1
        }
        XCTAssertNil(publishedID, "A successful missing-row result retains the view's clearing path")
        XCTAssertEqual(publicationCount, 1)
    }

    func testSuccessfulRefreshPublishesRequestedLiveFeedFromSuppliedConfiguration() throws {
        let configuration = try configuration()
        let requestedID = UUID()
        try installFeed(id: UUID(), title: "Unrelated feed", configuration: configuration)
        try installFeed(id: requestedID, title: "Requested feed", configuration: configuration)
        var publicationCount = 0
        LibraryFeedPreviewLoader.refresh(feedID: requestedID, configuration: configuration) { feed in
            XCTAssertEqual(feed?.id, requestedID)
            XCTAssertEqual(feed?.title, "Requested feed")
            XCTAssertNotNil(feed?.realm, "The callback must receive the actual resolved Realm row")
            XCTAssertEqual(feed?.realm?.configuration.fileURL, configuration.fileURL)
            publicationCount += 1
        }
        XCTAssertEqual(publicationCount, 1)
    }

    private func configuration() throws -> Realm.Configuration {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryFeedPreviewLoaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        var configuration = Realm.Configuration(fileURL: directory.appendingPathComponent("preview.realm"))
        configuration.objectTypes = [Feed.self]
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        return configuration
    }

    private func installFeed(id: UUID, title: String, configuration: Realm.Configuration) throws {
        try autoreleasepool {
            let realm = try Realm(configuration: configuration)
            let feed = Feed()
            feed.id = id
            feed.title = title
            feed.rssUrl = URL(string: "https://example.com/feed.xml")!
            try realm.write { realm.add(feed) }
        }
    }
}
