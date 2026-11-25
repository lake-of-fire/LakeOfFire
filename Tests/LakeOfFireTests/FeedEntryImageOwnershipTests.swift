import BigSyncKit
import Foundation
import RealmSwift
@testable import RealmSwiftGaps
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireReader

@MainActor
final class FeedEntryImageWriterGate {
    let entered: XCTestExpectation
    private let pauseAtOpen: Int
    private var admittedOpens = 0
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ entered: XCTestExpectation, pauseAtOpen: Int = 2) {
        self.entered = entered
        self.pauseAtOpen = pauseAtOpen
    }

    func didOpenRealm() async {
        admittedOpens += 1
        // Image loads prepare read storage first, then reopen for the writer.
        guard admittedOpens == pauseAtOpen else { return }
        await withCheckedContinuation { continuation in
            if released {
                continuation.resume()
            } else {
                self.continuation = continuation
            }
            entered.fulfill()
        }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
final class FeedEntryImageOwnershipTests: XCTestCase {
    private let imageURL = URL(string: "https://example.invalid/original.png")!
    private let replacementImageURL = URL(string: "https://example.invalid/replacement.png")!
    private let legacyImageURL = URL(string: "cached/old.png")!

    func testCurrentCellLoadsAndCachesExtractedImageWithoutReplayMutation() async throws {
        let (realm, entry, _) = try await makeFixture()
        let frozen = entry.freeze()
        let cell = ReaderContentCellViewModel<FeedEntry>()
        try await cell.load(item: frozen, includeSource: true)
        XCTAssertTrue(cell.hasLoadedDisplayState)
        XCTAssertEqual(cell.title, "Feed article")
        XCTAssertEqual(cell.sourceTitle, "Fixture feed")
        XCTAssertEqual(cell.imageURL, imageURL)
        await realm.asyncRefresh()
        XCTAssertEqual(entry.imageUrl, imageURL)
        let generation = try XCTUnwrap(journalGeneration(for: entry, in: realm))
        let modifiedAt = entry.modifiedAt

        XCTAssertNil(frozen.imageUrl)
        let replay = try await frozen.imageURLToDisplay()
        XCTAssertEqual(replay, imageURL)
        await realm.asyncRefresh()
        XCTAssertEqual(journalGeneration(for: entry, in: realm), generation)
        XCTAssertEqual(entry.modifiedAt, modifiedAt)
    }

    func testCurrentCellRepairsRelativeCacheUsingArticleURLAndLaterValidBodyImage() async throws {
        let articleURL = URL(string: "https://example.invalid/news/daily/article?edition=1")!
        let expectedImage = URL(string: "https://example.invalid/news/images/body%20art.png?size=2&token=A%2FB")!
        let body = """
        <article>
          <img width="600" height="400">
          <img width="600" height="400" src="">
          <img width="600" height="400" src="../images/body%20art.png?size=2&amp;token=A%2FB">
        </article>
        """
        let (realm, entry, _) = try await makeFixture(
            articleURL: articleURL, body: body, cachedImage: legacyImageURL
        )
        let frozen = entry.freeze()
        let legacyGeneration = try XCTUnwrap(journalGeneration(for: entry, in: realm))
        let cell = ReaderContentCellViewModel<FeedEntry>()

        try await cell.load(item: frozen, includeSource: true)

        XCTAssertTrue(cell.hasLoadedDisplayState)
        XCTAssertEqual(cell.imageURL, expectedImage)
        XCTAssertEqual(frozen.imageUrl, legacyImageURL)
        await realm.asyncRefresh()
        XCTAssertEqual(entry.imageUrl, expectedImage)
        let repairedGeneration = try XCTUnwrap(journalGeneration(for: entry, in: realm))
        XCTAssertNotEqual(repairedGeneration, legacyGeneration)
        let modifiedAt = entry.modifiedAt

        let replay = try await frozen.imageURLToDisplay()
        XCTAssertEqual(replay, expectedImage)
        await realm.asyncRefresh()
        XCTAssertEqual(journalGeneration(for: entry, in: realm), repairedGeneration)
        XCTAssertEqual(entry.modifiedAt, modifiedAt)
    }

    func testCurrentCellUsesYouTubeThumbnailWhenBodyImagesHaveNoSource() async throws {
        let body = """
        <article>
          <img width="600" height="400">
          <img width="600" height="400" src="">
          <iframe src="https://www.youtube.com/embed/imageFixture123"></iframe>
        </article>
        """
        let (realm, entry, _) = try await makeFixture(body: body)
        let expectedImage = URL(string: "https://img.youtube.com/vi/imageFixture123/0.jpg")
        let cell = ReaderContentCellViewModel<FeedEntry>()

        try await cell.load(item: entry.freeze(), includeSource: true)

        XCTAssertTrue(cell.hasLoadedDisplayState)
        XCTAssertEqual(cell.imageURL, expectedImage)
        await realm.asyncRefresh()
        XCTAssertEqual(entry.imageUrl, expectedImage)
        XCTAssertNotNil(journalGeneration(for: entry, in: realm))
    }

    func testCurrentCellDoesNotUseRelativeCacheWhenBodyHasNoArtwork() async throws {
        let (realm, entry, _) = try await makeFixture(
            body: "<article><p>No artwork in the feed body.</p></article>",
            cachedImage: legacyImageURL
        )
        let frozen = entry.freeze()
        let generation = try XCTUnwrap(journalGeneration(for: entry, in: realm))
        let modifiedAt = entry.modifiedAt
        let cell = ReaderContentCellViewModel<FeedEntry>()

        XCTAssertNil(frozen.storedImageURLToDisplay)
        try await cell.load(item: frozen, includeSource: true)

        XCTAssertTrue(cell.hasLoadedDisplayState)
        XCTAssertNil(cell.imageURL)
        await realm.asyncRefresh()
        XCTAssertEqual(entry.imageUrl, legacyImageURL)
        XCTAssertEqual(journalGeneration(for: entry, in: realm), generation)
        XCTAssertEqual(entry.modifiedAt, modifiedAt)
    }

    func testExtractedImageCannotMutateRecreatedEntryWithSameKeyAndDate() async throws {
        let (realm, entry, feedID) = try await makeFixture()
        let frozen = entry.freeze()
        let replacement = makeEntry(feedID: feedID, image: replacementImageURL)
        replacement.createdAt = frozen.createdAt
        let gate = FeedEntryImageWriterGate(expectation(description: "extracted image reached its writer"))
        let task = imageLoad(for: frozen, gate: gate)
        await fulfillment(of: [gate.entered], timeout: 3)
        do {
            try realm.write {
                realm.delete(entry)
                realm.add(replacement)
                replacement.refreshChangeMetadata(explicitlyModified: true)
            }
        } catch {
            gate.release()
            _ = await task.result
            throw error
        }
        let generation = journalGeneration(for: replacement, in: realm)
        gate.release()
        XCTAssertNotNil(generation)
        try await requireCancellation(of: task)
        await realm.asyncRefresh()

        XCTAssertEqual(frozen.compoundKey, replacement.compoundKey)
        XCTAssertEqual(frozen.createdAt, replacement.createdAt)
        XCTAssertNotEqual(frozen.id, replacement.id)
        XCTAssertNil(replacement.imageUrl)
        XCTAssertEqual(journalGeneration(for: replacement, in: realm), generation)
    }

    func testCancelledExtractionDoesNotMutateCurrentEntry() async throws {
        let (realm, entry, _) = try await makeFixture()
        let gate = FeedEntryImageWriterGate(expectation(description: "extracting task reached its writer"))
        let task = imageLoad(for: entry.freeze(), gate: gate)
        await fulfillment(of: [gate.entered], timeout: 3)
        task.cancel()
        gate.release()

        try await requireCancellation(of: task)
        await realm.asyncRefresh()
        XCTAssertNil(entry.imageUrl)
        XCTAssertNil(journalGeneration(for: entry, in: realm))
    }

    func testExtractedImageDoesNotOverwriteNewerSameRowImage() async throws {
        let (realm, entry, _) = try await makeFixture()
        let gate = FeedEntryImageWriterGate(expectation(description: "extracted image reached its writer"))
        let task = imageLoad(for: entry.freeze(), gate: gate)
        await fulfillment(of: [gate.entered], timeout: 3)
        do {
            try realm.write {
                entry.imageUrl = replacementImageURL
                entry.refreshChangeMetadata(explicitlyModified: true)
            }
        } catch {
            gate.release()
            _ = await task.result
            throw error
        }
        let generation = journalGeneration(for: entry, in: realm)
        gate.release()
        XCTAssertNotNil(generation)
        let result = try await task.value
        XCTAssertEqual(result, replacementImageURL)
        await realm.asyncRefresh()
        XCTAssertEqual(entry.imageUrl, replacementImageURL)
        XCTAssertEqual(journalGeneration(for: entry, in: realm), generation)
    }

    func testRelativeCacheRepairDoesNotOverwriteNewerUsableArtwork() async throws {
        let (realm, entry, _) = try await makeFixture(cachedImage: legacyImageURL)
        let gate = FeedEntryImageWriterGate(expectation(description: "legacy image repair reached its writer"))
        let task = imageLoad(for: entry.freeze(), gate: gate)
        await fulfillment(of: [gate.entered], timeout: 3)
        do {
            try realm.write {
                entry.imageUrl = replacementImageURL
                entry.refreshChangeMetadata(explicitlyModified: true)
            }
        } catch {
            gate.release()
            _ = await task.result
            throw error
        }
        let generation = journalGeneration(for: entry, in: realm)
        let modifiedAt = entry.modifiedAt
        gate.release()

        let result = try await task.value
        XCTAssertEqual(result, replacementImageURL)
        await realm.asyncRefresh()
        XCTAssertEqual(entry.imageUrl, replacementImageURL)
        XCTAssertNotNil(generation)
        XCTAssertEqual(journalGeneration(for: entry, in: realm), generation)
        XCTAssertEqual(entry.modifiedAt, modifiedAt)
    }

    func testRelativeCacheRepairRejectsAChangedLegacyCacheAtWriterAdmission() async throws {
        let (realm, entry, _) = try await makeFixture(cachedImage: legacyImageURL)
        let changedCacheURL = URL(string: "cached/changed.png")!
        let gate = FeedEntryImageWriterGate(expectation(description: "legacy image repair reached its writer"))
        let task = imageLoad(for: entry.freeze(), gate: gate)
        await fulfillment(of: [gate.entered], timeout: 3)
        do {
            try realm.write {
                entry.imageUrl = changedCacheURL
                entry.refreshChangeMetadata(explicitlyModified: true)
            }
        } catch {
            gate.release()
            _ = await task.result
            throw error
        }
        let generation = journalGeneration(for: entry, in: realm)
        let modifiedAt = entry.modifiedAt
        gate.release()

        try await requireCancellation(of: task)
        await realm.asyncRefresh()
        XCTAssertEqual(entry.imageUrl, changedCacheURL)
        XCTAssertNotNil(generation)
        XCTAssertEqual(journalGeneration(for: entry, in: realm), generation)
        XCTAssertEqual(entry.modifiedAt, modifiedAt)
    }

    func testExtractedImageCannotMutateSameRowWithNewerBody() async throws {
        let (realm, entry, _) = try await makeFixture()
        let gate = FeedEntryImageWriterGate(expectation(description: "old body image reached its writer"))
        let task = imageLoad(for: entry.freeze(), gate: gate)
        await fulfillment(of: [gate.entered], timeout: 3)
        do {
            try realm.write {
                entry.html = imageHTML(replacementImageURL)
                entry.refreshChangeMetadata(explicitlyModified: true)
            }
        } catch {
            gate.release()
            _ = await task.result
            throw error
        }
        let generation = journalGeneration(for: entry, in: realm)
        gate.release()
        XCTAssertNotNil(generation)
        try await requireCancellation(of: task)
        await realm.asyncRefresh()
        XCTAssertNil(entry.imageUrl)
        XCTAssertEqual(journalGeneration(for: entry, in: realm), generation)
    }

    private func imageLoad(for entry: FeedEntry, gate: FeedEntryImageWriterGate) -> Task<URL?, Error> {
        Task {
            try await RealmStorageAdmissionObservation.$didOpenRealm.withValue({
                await gate.didOpenRealm()
            }) {
                try await entry.imageURLToDisplay()
            }
        }
    }

    private func requireCancellation(of task: Task<URL?, Error>, file: StaticString = #filePath,
                                     line: UInt = #line) async throws {
        do {
            _ = try await task.value
            XCTFail("Expected the retired image load to be cancelled", file: file, line: line)
        } catch is CancellationError {
        }
    }

    private func makeFixture(
        articleURL: URL? = nil, body: String? = nil, cachedImage: URL? = nil
    ) async throws -> (realm: Realm, entry: FeedEntry, feedID: UUID) {
        var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        configuration.objectTypes = [Feed.self, FeedEntry.self, BigSyncPendingMutation.self]
        BigSyncMutationTracking.install(configurations: [configuration], excludedClassNames: [])
        let realm = try await Realm.open(configuration: configuration)
        let fixtureConfiguration = configuration
        addTeardownBlock {
            _ = await RealmBackgroundActor.shared.removeCachedRealm(for: fixtureConfiguration)
        }
        let feed = Feed()
        feed.title = "Fixture feed"
        feed.rssUrl = URL(string: "https://example.invalid/feed.xml")!
        feed.extractImageFromContent = true
        let entry = makeEntry(feedID: feed.id, image: imageURL, articleURL: articleURL)
        if let body { entry.html = body }
        entry.imageUrl = cachedImage
        try realm.write {
            realm.add(feed)
            realm.add(entry)
            if cachedImage != nil { entry.refreshChangeMetadata(explicitlyModified: true) }
        }
        return (realm, entry, feed.id)
    }

    private func makeEntry(feedID: UUID, image: URL, articleURL: URL? = nil) -> FeedEntry {
        let entry = FeedEntry()
        entry.feedID = feedID
        entry.url = articleURL ?? URL(string: "https://example.invalid/article")!
        entry.title = "Feed article"
        entry.readerContentKind = .contentListing
        entry.updateCompoundKey()
        entry.html = imageHTML(image)
        return entry
    }

    private func imageHTML(_ image: URL) -> String {
        "<article><p>Image in the feed article</p><img width=\"600\" height=\"400\" src=\"\(image.absoluteString)\"></article>"
    }

    private func journalGeneration(for entry: FeedEntry, in realm: Realm) -> String? {
        realm.object(ofType: BigSyncPendingMutation.self,
                     forPrimaryKey: "FeedEntry.\(entry.compoundKey)")?.generation
    }
}
