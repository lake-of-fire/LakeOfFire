import Combine
import RealmSwift
import RealmSwiftGaps
import XCTest
@testable import LakeOfFireContent

/// Private in-memory storage only. Physical removal simulates acknowledged cleanup;
/// production deletion continues to use its existing synchronized tombstone boundary.
@MainActor
final class ReaderContentInvalidatedRowTests: XCTestCase, @unchecked Sendable {
    private func makeConfiguration() -> Realm.Configuration {
        var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        configuration.objectTypes = [HistoryRecord.self]
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        let capturedConfiguration = configuration
        addTeardownBlock {
            await RealmBackgroundActor.shared.removeCachedRealm(for: capturedConfiguration)
        }
        return configuration
    }

    @RealmBackgroundActor
    private static func insertRecord(
        configuration: Realm.Configuration, url: URL, title: String
    ) async throws -> String {
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        let record = HistoryRecord()
        record.url = url
        record.title = title
        record.updateCompoundKey()
        try await realm.asyncWrite {
            realm.add(record)
            record.refreshChangeMetadata(explicitlyModified: true)
        }
        return record.compoundKey
    }

    @RealmBackgroundActor
    private static func removeRecord(
        configuration: Realm.Configuration, key: String
    ) async throws {
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        try await realm.asyncWrite {
            if let record = realm.object(ofType: HistoryRecord.self, forPrimaryKey: key) {
                realm.delete(record)
            }
        }
    }

    @RealmBackgroundActor
    private static func updateTitle(
        configuration: Realm.Configuration, key: String, title: String
    ) async throws {
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        try await realm.asyncWrite {
            guard let record = realm.object(ofType: HistoryRecord.self, forPrimaryKey: key),
                  record.title != title else { return }
            record.title = title
            record.refreshChangeMetadata(explicitlyModified: true)
        }
    }

    private func record(
        in realm: Realm, configuration: Realm.Configuration, url: URL, title: String
    ) async throws -> HistoryRecord {
        let key = try await Self.insertRecord(configuration: configuration, url: url, title: title)
        realm.refresh()
        return try XCTUnwrap(realm.object(ofType: HistoryRecord.self, forPrimaryKey: key))
    }

    private func remove(
        _ record: HistoryRecord, in realm: Realm, configuration: Realm.Configuration
    ) async throws {
        let key = record.compoundKey
        try await Self.removeRecord(configuration: configuration, key: key)
        realm.refresh()
        XCTAssertTrue(record.isInvalidated)
    }

    private func unmanagedRecord(url: URL, title: String) -> HistoryRecord {
        let record = HistoryRecord()
        record.url = url
        record.title = title
        record.updateCompoundKey()
        return record
    }

    func testReloadAfterPhysicalDeletionResolvesFreshContentForBothDisplayStates() async throws {
        let originalResolver = ReaderContent.contentResolver
        defer { ReaderContent.contentResolver = originalResolver }
        for displayStillMatches in [true, false] {
            let configuration = makeConfiguration()
            let realm = try await Realm(configuration: configuration, actor: MainActor.shared)
            let url = URL(string: "https://example.com/deleted-display/\(UUID().uuidString)")!
            let original = try await record(in: realm, configuration: configuration, url: url, title: "Original")
            let reader = ReaderContent()
            ReaderContent.contentResolver = { _, _, _ in original }
            try await reader.load(url: url)
            reader.currentSectionIndex = 7
            if !displayStillMatches { reader.pageURL = URL(string: "https://example.com/other")! }
            try await remove(original, in: realm, configuration: configuration)
            let replacement = try await record(
                in: realm, configuration: configuration, url: url, title: "Replacement"
            )
            var resolutionCount = 0
            ReaderContent.contentResolver = { requestedURL, _, _ in
                XCTAssertEqual(requestedURL, url)
                resolutionCount += 1
                return replacement
            }
            try await reader.load(url: url)
            XCTAssertEqual(resolutionCount, 1)
            XCTAssertTrue(reader.content === replacement)
            XCTAssertEqual(reader.pageURL, url)
            XCTAssertEqual(reader.contentTitle, "Replacement")
            XCTAssertNil(reader.currentSectionIndex)
        }
    }

    func testDeletedPreloadResolvesAgainWhetherRemovedBeforeOrAfterPreloading() async throws {
        let originalResolver = ReaderContent.contentResolver
        defer { ReaderContent.contentResolver = originalResolver }
        for deletedBeforePreloading in [true, false] {
            let configuration = makeConfiguration()
            let realm = try await Realm(configuration: configuration, actor: MainActor.shared)
            let url = URL(string: "https://example.com/deleted-preload/\(UUID().uuidString)")!
            let original = try await record(in: realm, configuration: configuration, url: url, title: "Original")
            let reader = ReaderContent()
            if deletedBeforePreloading {
                try await remove(original, in: realm, configuration: configuration)
                reader.preloadResolvedContent(original, for: url)
            } else {
                reader.preloadResolvedContent(original, for: url)
                try await remove(original, in: realm, configuration: configuration)
            }
            let replacement = unmanagedRecord(url: url, title: "Replacement")
            var resolutionCount = 0
            ReaderContent.contentResolver = { _, _, _ in resolutionCount += 1; return replacement }
            try await reader.load(url: url)
            XCTAssertEqual(resolutionCount, 1)
            XCTAssertTrue(reader.content === replacement)
            XCTAssertEqual(reader.contentTitle, "Replacement")
        }
    }

    func testDeletedDisplayedContentSkipsCachedAccessAndTitleRefresh() async throws {
        let originalResolver = ReaderContent.contentResolver
        defer { ReaderContent.contentResolver = originalResolver }
        let configuration = makeConfiguration()
        let realm = try await Realm(configuration: configuration, actor: MainActor.shared)
        let url = URL(string: "https://example.com/deleted-title")!
        let original = try await record(in: realm, configuration: configuration, url: url, title: "Original")
        let reader = ReaderContent()
        ReaderContent.contentResolver = { _, _, _ in original }
        try await reader.load(url: url)
        XCTAssertEqual(reader.cachedContentURL, url)
        XCTAssertEqual(reader.cachedContentTitle, "Original")
        XCTAssertTrue(reader.validCachedContent === original)
        try await Self.updateTitle(configuration: configuration, key: original.compoundKey, title: "Current row")
        realm.refresh()
        XCTAssertEqual(reader.cachedContentTitle, "Current row")
        XCTAssertEqual(reader.contentTitle, "Original")
        var publishedTitles = [String]()
        let observation = reader.contentTitleSubject.sink { publishedTitles.append($0) }
        defer { observation.cancel() }
        try await remove(original, in: realm, configuration: configuration)
        XCTAssertNil(reader.cachedContentURL)
        XCTAssertNil(reader.cachedContentTitle)
        XCTAssertNil(reader.validCachedContent)
        reader.refreshObservedContentState()
        XCTAssertNil(reader.locationBarTitle)
        XCTAssertFalse(reader.snippetTitleIsGeneratedFromPrefix)
        XCTAssertEqual(reader.contentTitle, "Original")
        XCTAssertEqual(reader.pageURL, url)
        XCTAssertTrue(publishedTitles.isEmpty)
        let result = try await reader.getContent()
        XCTAssertNil(result)
        // Replacing the invalidated oldValue must also be safe in diagnostic builds.
        let replacement = unmanagedRecord(url: url, title: "Replacement")
        reader.replaceSelection(with: replacement)
        XCTAssertTrue(reader.validCachedContent === replacement)
        XCTAssertEqual(reader.locationBarTitle, "Replacement")
        XCTAssertEqual(publishedTitles, ["Replacement"])
    }

    func testPhysicallyDeletedResolverResultCannotPublishAndAllowsRetry() async throws {
        let originalResolver = ReaderContent.contentResolver
        defer { ReaderContent.contentResolver = originalResolver }
        let configuration = makeConfiguration()
        let realm = try await Realm(configuration: configuration, actor: MainActor.shared)
        let url = URL(string: "https://example.com/deleted-resolver")!
        let original = try await record(in: realm, configuration: configuration, url: url, title: "Deleted")
        let reader = ReaderContent()
        var publishedTitles = [String]()
        let observation = reader.contentTitleSubject.sink { publishedTitles.append($0) }
        defer { observation.cancel() }
        let resolverEntered = XCTestExpectation(description: "resolver captured managed row")
        let releaseResolver = XCTestExpectation(description: "resolver released")
        var released = false
        ReaderContent.contentResolver = { _, _, _ in
            resolverEntered.fulfill()
            let status = await XCTWaiter.fulfillment(of: [releaseResolver], timeout: 5)
            XCTAssertEqual(status, .completed)
            try await self.remove(original, in: realm, configuration: configuration)
            return original
        }
        let producer = Task { @MainActor in try await reader.load(url: url) }
        defer {
            if !released { releaseResolver.fulfill() }
            producer.cancel()
        }
        await fulfillment(of: [resolverEntered], timeout: 5)
        let accessorEntered = XCTestExpectation(description: "accessor joined pending resolver")
        let accessor = Task { @MainActor in
            accessorEntered.fulfill()
            return try await reader.getContent()
        }
        defer { accessor.cancel() }
        await fulfillment(of: [accessorEntered], timeout: 5)
        released = true
        releaseResolver.fulfill()
        try await producer.value
        let obsoleteResult = try await accessor.value
        XCTAssertNil(obsoleteResult)
        XCTAssertNil(reader.content)
        XCTAssertEqual(reader.pageURL, url)
        XCTAssertEqual(reader.contentTitle, "")
        XCTAssertNil(reader.locationBarTitle)
        XCTAssertTrue(publishedTitles.isEmpty)
        let replacement = unmanagedRecord(url: url, title: "Replacement")
        var retryCount = 0
        ReaderContent.contentResolver = { _, _, _ in retryCount += 1; return replacement }
        try await reader.load(url: url)
        XCTAssertEqual(retryCount, 1)
        XCTAssertTrue(reader.content === replacement)
        XCTAssertEqual(publishedTitles, ["Replacement"])
    }

    func testSynchronousPublicationInvalidationDoesNotReturnRemovedContent() async throws {
        let originalResolver = ReaderContent.contentResolver
        defer { ReaderContent.contentResolver = originalResolver }
        let configuration = makeConfiguration()
        let realm = try await Realm(configuration: configuration, actor: MainActor.shared)
        let url = URL(string: "https://example.com/publication-invalidation")!
        let original = try await record(in: realm, configuration: configuration, url: url, title: "Original")
        let reader = ReaderContent()
        let observation = reader.contentTitleSubject.sink { _ in realm.invalidate() }
        defer { observation.cancel() }
        ReaderContent.contentResolver = { _, _, _ in original }
        try await reader.load(url: url)
        XCTAssertTrue(original.isInvalidated)
        let result = try await reader.getContent()
        XCTAssertNil(result)
        XCTAssertNil(reader.cachedContentURL)
        XCTAssertEqual(reader.pageURL, url)
    }
}
