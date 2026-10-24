import Foundation
import RealmSwift
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireContentUI

/// Controls only the real model's eligibility-I/O boundary. Deliberately permits
/// successful completion after cancellation, like coordinated file access.
private actor ReaderDeleteEligibilityProbe {
    private var requestedURLs: [URL] = []
    private var reads: [Int: CheckedContinuation<ReaderFileDeleteEligibility, Never>] = [:]
    private var observers: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var completedCancellation: [Int: Bool] = [:]

    func read(_ url: URL) async -> ReaderFileDeleteEligibility {
        let index = requestedURLs.count
        requestedURLs.append(url)
        defer { completedCancellation[index] = Task.isCancelled }
        return await withCheckedContinuation { continuation in
            reads[index] = continuation
            for observer in observers.removeValue(forKey: index) ?? [] {
                observer.resume()
            }
        }
    }

    func waitForRequest(_ index: Int) async {
        if requestedURLs.count > index { return }
        await withCheckedContinuation { continuation in
            observers[index, default: []].append(continuation)
        }
    }

    func complete(_ index: Int, with eligibility: ReaderFileDeleteEligibility) {
        reads.removeValue(forKey: index)?.resume(returning: eligibility)
    }

    func urls() -> [URL] { requestedURLs }
    func wasCancelled(_ index: Int) -> Bool? { completedCancellation[index] }
}

@MainActor
private final class ReaderDeleteEligibilityFixture {
    let realm: Realm
    let file: ContentFile

    init(
        url: URL = URL(string: "reader-file://file/load/local/eligibility.epub")!,
        createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) throws {
        let realm = try Realm(configuration: Realm.Configuration(
            inMemoryIdentifier: "ReaderDeleteEligibility-\(UUID().uuidString)",
            objectTypes: [ContentFile.self, Bookmark.self]
        ))
        let file = ContentFile()
        file.url = url
        file.createdAt = createdAt
        file.updateCompoundKey()
        try realm.write { realm.add(file) }
        self.realm = realm
        self.file = file
    }

    func addFile(named name: String) throws -> ContentFile {
        let file = ContentFile()
        file.url = URL(string: "reader-file://file/load/local/\(name).epub")!
        file.updateCompoundKey()
        try realm.write { realm.add(file) }
        return file
    }
}

@MainActor
final class ReaderContentDeleteEligibilityModelTests: XCTestCase {
    private func makeModel(probe: ReaderDeleteEligibilityProbe) -> ReaderContentDeleteEligibilityModel {
        ReaderContentDeleteEligibilityModel(readEligibility: { await probe.read($0) })
    }

    func testInvalidatedInitialSelectionSkipsManagedFieldsAndIO() async throws {
        let fixture = try ReaderDeleteEligibilityFixture()
        let keys: Set<String> = [fixture.file.compoundKey]
        try fixture.realm.write { fixture.realm.delete(fixture.file) }
        let probe = ReaderDeleteEligibilityProbe()
        let model = makeModel(probe: probe)

        let task = model.refresh(contents: [fixture.file], selectedKeys: keys)
        let selected = readerContentSelectedForDeletion(contents: [fixture.file], selectedKeys: keys)

        XCTAssertNil(task)
        XCTAssertTrue(selected.isEmpty)
        XCTAssertTrue(model.isDeletionDisabled(contents: [fixture.file], selectedKeys: keys))
        let urls = await probe.urls()
        XCTAssertEqual(urls, [])
    }

    func testRetiredBookmarkAndEmptySelectionDoNotReadKeysBeforeFileFiltering() async throws {
        let fixture = try ReaderDeleteEligibilityFixture()
        let bookmark = Bookmark()
        bookmark.url = URL(string: "https://example.com/retired")!
        bookmark.updateCompoundKey()
        let keys: Set<String> = [bookmark.compoundKey]
        try fixture.realm.write { fixture.realm.add(bookmark) }
        try fixture.realm.write { fixture.realm.delete(bookmark) }
        let probe = ReaderDeleteEligibilityProbe()
        let model = makeModel(probe: probe)

        XCTAssertNil(model.refresh(contents: [bookmark], selectedKeys: []))
        XCTAssertNil(model.refresh(contents: [bookmark], selectedKeys: keys))
        XCTAssertTrue(readerContentSelectedForDeletion(contents: [bookmark], selectedKeys: keys).isEmpty)
        XCTAssertTrue(model.isDeletionDisabled(contents: [bookmark], selectedKeys: keys))
        let urls = await probe.urls()
        XCTAssertEqual(urls, [])
    }

    func testDeletionBeforeQueuedRefreshSkipsCapturedRowIO() async throws {
        let fixture = try ReaderDeleteEligibilityFixture()
        let keys: Set<String> = [fixture.file.compoundKey]
        let probe = ReaderDeleteEligibilityProbe()
        let model = makeModel(probe: probe)
        let task = try XCTUnwrap(model.refresh(contents: [fixture.file], selectedKeys: keys))
        try fixture.realm.write { fixture.realm.delete(fixture.file) }

        await task.value

        XCTAssertTrue(model.isDeletionDisabled(contents: [fixture.file], selectedKeys: keys))
        let urls = await probe.urls()
        XCTAssertEqual(urls, [])
    }

    func testDeletionDuringNoncooperativeReadDoesNotPublishOrReadRetiredKey() async throws {
        let fixture = try ReaderDeleteEligibilityFixture()
        let keys: Set<String> = [fixture.file.compoundKey]
        let probe = ReaderDeleteEligibilityProbe()
        let model = makeModel(probe: probe)
        let task = try XCTUnwrap(model.refresh(contents: [fixture.file], selectedKeys: keys))
        await probe.waitForRequest(0)
        try fixture.realm.write { fixture.realm.delete(fixture.file) }

        await probe.complete(0, with: .allowed)
        await task.value

        XCTAssertTrue(model.isDeletionDisabled(contents: [fixture.file], selectedKeys: keys))
    }

    func testChangedURLCannotAdoptPreviousEligibilityAndCanRetry() async throws {
        let fixture = try ReaderDeleteEligibilityFixture()
        let keys: Set<String> = [fixture.file.compoundKey]
        let originalURL = fixture.file.url
        let replacementURL = URL(string: "reader-file://file/load/local/replacement.epub")!
        let probe = ReaderDeleteEligibilityProbe()
        let model = makeModel(probe: probe)
        let original = try XCTUnwrap(model.refresh(contents: [fixture.file], selectedKeys: keys))
        await probe.waitForRequest(0)
        try fixture.realm.write { fixture.file.url = replacementURL }

        await probe.complete(0, with: .allowed)
        await original.value
        XCTAssertTrue(model.isDeletionDisabled(contents: [fixture.file], selectedKeys: keys))

        let retry = try XCTUnwrap(model.refresh(contents: [fixture.file], selectedKeys: keys))
        await probe.waitForRequest(1)
        await probe.complete(1, with: .allowed)
        await retry.value

        XCTAssertFalse(model.isDeletionDisabled(contents: [fixture.file], selectedKeys: keys))
        let urls = await probe.urls()
        XCTAssertEqual(urls, [originalURL, replacementURL])
    }

    func testChangedCreationIdentityRetiresPendingEligibility() async throws {
        let fixture = try ReaderDeleteEligibilityFixture()
        let keys: Set<String> = [fixture.file.compoundKey]
        let probe = ReaderDeleteEligibilityProbe()
        let model = makeModel(probe: probe)
        let task = try XCTUnwrap(model.refresh(contents: [fixture.file], selectedKeys: keys))
        await probe.waitForRequest(0)
        try fixture.realm.write {
            fixture.file.createdAt = fixture.file.createdAt.addingTimeInterval(1)
        }

        await probe.complete(0, with: .allowed)
        await task.value

        XCTAssertTrue(model.isDeletionDisabled(contents: [fixture.file], selectedKeys: keys))
    }

    func testPhysicalReplacementWithSameKeyURLAndDateCannotAdoptPendingResult() async throws {
        let fixture = try ReaderDeleteEligibilityFixture()
        let keys: Set<String> = [fixture.file.compoundKey]
        let replacement = ContentFile()
        replacement.url = fixture.file.url
        replacement.createdAt = fixture.file.createdAt
        replacement.updateCompoundKey()
        let probe = ReaderDeleteEligibilityProbe()
        let model = makeModel(probe: probe)
        let task = try XCTUnwrap(model.refresh(contents: [fixture.file], selectedKeys: keys))
        await probe.waitForRequest(0)
        try fixture.realm.write {
            fixture.realm.delete(fixture.file)
            fixture.realm.add(replacement)
        }

        await probe.complete(0, with: .allowed)
        await task.value

        XCTAssertTrue(fixture.file.isInvalidated)
        XCTAssertTrue(model.isDeletionDisabled(contents: [replacement], selectedKeys: keys))
    }

    func testCachedResultRejectsAnotherRealmWithMatchingValues() async throws {
        let fixture = try ReaderDeleteEligibilityFixture()
        let replacement = try ReaderDeleteEligibilityFixture(url: fixture.file.url, createdAt: fixture.file.createdAt)
        let keys: Set<String> = [fixture.file.compoundKey]
        let probe = ReaderDeleteEligibilityProbe()
        let model = makeModel(probe: probe)
        let task = try XCTUnwrap(model.refresh(contents: [fixture.file], selectedKeys: keys))
        await probe.waitForRequest(0)
        await probe.complete(0, with: .allowed)
        await task.value

        XCTAssertFalse(fixture.file.isInvalidated)
        XCTAssertFalse(model.isDeletionDisabled(contents: [fixture.file], selectedKeys: keys))
        XCTAssertTrue(model.isDeletionDisabled(contents: [replacement.file], selectedKeys: keys))
        let sameRow = try XCTUnwrap(fixture.realm.object(ofType: ContentFile.self, forPrimaryKey: fixture.file.compoundKey))
        XCTAssertFalse(model.isDeletionDisabled(contents: [sameRow], selectedKeys: keys))
    }

    func testCachedResultRechecksURLCreationAndTombstoneAtConsumption() async throws {
        for mutation in ["url", "creation", "tombstone"] {
            let fixture = try ReaderDeleteEligibilityFixture()
            let keys: Set<String> = [fixture.file.compoundKey]
            let probe = ReaderDeleteEligibilityProbe()
            let model = makeModel(probe: probe)
            let task = try XCTUnwrap(model.refresh(contents: [fixture.file], selectedKeys: keys))
            await probe.waitForRequest(0)
            await probe.complete(0, with: .allowed)
            await task.value
            XCTAssertFalse(model.isDeletionDisabled(contents: [fixture.file], selectedKeys: keys))

            try fixture.realm.write {
                switch mutation {
                case "url":
                    fixture.file.url = URL(string: "reader-file://file/load/local/changed.epub")!
                case "creation":
                    fixture.file.createdAt = fixture.file.createdAt.addingTimeInterval(1)
                default:
                    fixture.file.isDeleted = true
                }
            }

            XCTAssertTrue(model.isDeletionDisabled(contents: [fixture.file], selectedKeys: keys), mutation)
        }
    }

    func testEarlierFileRetiresWhileLaterEligibilityIsPending() async throws {
        let fixture = try ReaderDeleteEligibilityFixture()
        let second = try fixture.addFile(named: "second")
        let contents = [fixture.file, second]
        let keys = Set(contents.map(\.compoundKey))
        let probe = ReaderDeleteEligibilityProbe()
        let model = makeModel(probe: probe)
        let task = try XCTUnwrap(model.refresh(contents: contents, selectedKeys: keys))
        await probe.waitForRequest(0)
        await probe.complete(0, with: .allowed)
        await probe.waitForRequest(1)
        try fixture.realm.write {
            fixture.file.url = URL(string: "reader-file://file/load/local/changed-first.epub")!
        }

        await probe.complete(1, with: .allowed)
        await task.value

        XCTAssertTrue(model.isDeletionDisabled(contents: contents, selectedKeys: keys))
        XCTAssertFalse(model.isDeletionDisabled(contents: [second], selectedKeys: [second.compoundKey]))
    }

    func testLateOldReadCannotReplaceNewerSelectionResult() async throws {
        let fixture = try ReaderDeleteEligibilityFixture()
        let second = try fixture.addFile(named: "second")
        let contents = [fixture.file, second]
        let firstKeys: Set<String> = [fixture.file.compoundKey]
        let secondKeys: Set<String> = [second.compoundKey]
        let probe = ReaderDeleteEligibilityProbe()
        let model = makeModel(probe: probe)
        let old = try XCTUnwrap(model.refresh(contents: contents, selectedKeys: firstKeys))
        await probe.waitForRequest(0)
        let current = try XCTUnwrap(model.refresh(contents: contents, selectedKeys: secondKeys))
        await probe.waitForRequest(1)

        await probe.complete(1, with: .blockedCloudOnly)
        await current.value
        await probe.complete(0, with: .allowed)
        await old.value

        XCTAssertTrue(model.isDeletionDisabled(contents: contents, selectedKeys: secondKeys))
        XCTAssertTrue(model.isDeletionDisabled(contents: contents, selectedKeys: firstKeys))
        let cancelled = await probe.wasCancelled(0)
        XCTAssertEqual(cancelled, true)
    }

    func testCancelledNewcomerDoesNotRevokeActiveRefresh() async throws {
        let fixture = try ReaderDeleteEligibilityFixture()
        let keys: Set<String> = [fixture.file.compoundKey]
        let probe = ReaderDeleteEligibilityProbe()
        let model = makeModel(probe: probe)
        let current = try XCTUnwrap(model.refresh(contents: [fixture.file], selectedKeys: keys))
        await probe.waitForRequest(0)
        let newcomer = Task { @MainActor in
            model.refresh(contents: [fixture.file], selectedKeys: keys)
        }
        newcomer.cancel()
        let rejected = await newcomer.value

        XCTAssertNil(rejected)
        await probe.complete(0, with: .allowed)
        await current.value

        XCTAssertFalse(model.isDeletionDisabled(contents: [fixture.file], selectedKeys: keys))
        let cancelled = await probe.wasCancelled(0)
        let urls = await probe.urls()
        XCTAssertEqual(cancelled, false)
        XCTAssertEqual(urls.count, 1)
    }

    func testOldSettlementCannotClearSuccessorsCancellationHandle() async throws {
        let fixture = try ReaderDeleteEligibilityFixture()
        let keys: Set<String> = [fixture.file.compoundKey]
        let probe = ReaderDeleteEligibilityProbe()
        let model = makeModel(probe: probe)
        let old = try XCTUnwrap(model.refresh(contents: [fixture.file], selectedKeys: keys))
        await probe.waitForRequest(0)
        let current = try XCTUnwrap(model.refresh(contents: [fixture.file], selectedKeys: keys))
        await probe.waitForRequest(1)

        await probe.complete(0, with: .allowed)
        await old.value
        model.cancelRefresh()
        await probe.complete(1, with: .allowed)
        await current.value

        XCTAssertTrue(model.isDeletionDisabled(contents: [fixture.file], selectedKeys: keys))
        let cancelled = await probe.wasCancelled(1)
        XCTAssertEqual(cancelled, true)
    }

    func testEmptySelectionRetiresPendingReadAndModelRetirementCancelsIO() async throws {
        let fixture = try ReaderDeleteEligibilityFixture()
        let keys: Set<String> = [fixture.file.compoundKey]
        let probe = ReaderDeleteEligibilityProbe()
        var model: ReaderContentDeleteEligibilityModel? = makeModel(probe: probe)
        weak var retiredModel = model
        let old = try XCTUnwrap(model?.refresh(contents: [fixture.file], selectedKeys: keys))
        await probe.waitForRequest(0)

        XCTAssertNil(model?.refresh(contents: [fixture.file], selectedKeys: []))
        await probe.complete(0, with: .allowed)
        await old.value
        XCTAssertTrue(try XCTUnwrap(model).isDeletionDisabled(contents: [fixture.file], selectedKeys: keys))

        let current = try XCTUnwrap(model?.refresh(contents: [fixture.file], selectedKeys: keys))
        await probe.waitForRequest(1)
        model = nil
        XCTAssertNil(retiredModel)
        await probe.complete(1, with: .allowed)
        await current.value

        let cancelled = await probe.wasCancelled(1)
        XCTAssertEqual(cancelled, true)
    }

    func testMixedSelectionPreservesCloudLoadingAndRetryPolicy() async throws {
        let fixture = try ReaderDeleteEligibilityFixture()
        let bookmark = Bookmark()
        bookmark.url = URL(string: "https://example.com/saved")!
        bookmark.updateCompoundKey()
        try fixture.realm.write { fixture.realm.add(bookmark) }
        let contents: [Bookmark] = [bookmark, fixture.file]
        let keys = Set(contents.map(\.compoundKey))
        let probe = ReaderDeleteEligibilityProbe()
        let model = makeModel(probe: probe)

        XCTAssertTrue(model.isDeletionDisabled(contents: contents, selectedKeys: keys))
        XCTAssertFalse(model.isDeletionDisabled(contents: contents, selectedKeys: [bookmark.compoundKey]))
        XCTAssertTrue(model.isDeletionDisabled(contents: contents, selectedKeys: []))

        let outcomes: [ReaderFileDeleteEligibility] = [.blockedCloudOnly, .blockedLoadingStatus, .allowed]
        for (index, outcome) in outcomes.enumerated() {
            let task = try XCTUnwrap(model.refresh(contents: contents, selectedKeys: keys))
            await probe.waitForRequest(index)
            await probe.complete(index, with: outcome)
            await task.value
            XCTAssertEqual(model.isDeletionDisabled(contents: contents, selectedKeys: keys), outcome != .allowed)
        }

        let urls = await probe.urls()
        XCTAssertEqual(urls, Array(repeating: fixture.file.url, count: outcomes.count))
    }

    func testCanonicalBackingURLIsCapturedAndUnsupportedURLsStayBlocked() async throws {
        let fixture = try ReaderDeleteEligibilityFixture(
            url: URL(string: "ebook://ebook/load/local/eligibility.epub?subpath=chapter.xhtml#section")!
        )
        let keys: Set<String> = [fixture.file.compoundKey]
        let probe = ReaderDeleteEligibilityProbe()
        let model = makeModel(probe: probe)
        let task = try XCTUnwrap(model.refresh(contents: [fixture.file], selectedKeys: keys))
        await probe.waitForRequest(0)
        await probe.complete(0, with: .allowed)
        await task.value

        XCTAssertFalse(model.isDeletionDisabled(contents: [fixture.file], selectedKeys: keys))
        let urls = await probe.urls()
        XCTAssertEqual(urls, [URL(string: "reader-file://file/load/local/eligibility.epub")!])

        try fixture.realm.write { fixture.file.url = URL(string: "about:blank")! }
        XCTAssertNil(model.refresh(contents: [fixture.file], selectedKeys: keys))
        XCTAssertTrue(model.isDeletionDisabled(contents: [fixture.file], selectedKeys: keys))
        let finalURLs = await probe.urls()
        XCTAssertEqual(finalURLs, urls)
    }
}
