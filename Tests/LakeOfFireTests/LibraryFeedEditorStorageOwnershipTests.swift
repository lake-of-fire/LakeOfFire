import BigSyncKit
import Foundation
import RealmSwift
@testable import RealmSwiftGaps
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireLibrary

private actor FeedEditorStorageGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait(entered: @Sendable () -> Void) async {
        guard !released else { return }
        await withCheckedContinuation {
            continuation = $0
            entered()
        }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class FeedEditorStorageLifetime {
    var model: LibraryFeedFormSectionsViewModel?
    let retired: XCTestExpectation
    private var hasRetired = false

    init(
        feed: Feed, formCapture: LibraryFeedFormCapture? = nil, observesRealm: Bool = false,
        beforeObservation: (@RealmBackgroundActor @Sendable () async throws -> Void)? = nil
    ) {
        let retired = XCTestExpectation(description: "Captured editor retirement settled")
        self.retired = retired
        model = LibraryFeedFormSectionsViewModel(
            feed: feed, formCapture: formCapture, observesRealm: observesRealm, beforeObservation: beforeObservation,
            retirementDidFinish: { retired.fulfill() }
        )
    }

    func retire() async {
        guard !hasRetired else { return }
        hasRetired = true
        model = nil
        let result = await XCTWaiter.fulfillment(of: [retired], timeout: 5)
        XCTAssertEqual(result, .completed)
    }
}

private struct FeedEditorStorageSnapshot: Equatable, Sendable {
    let createdAt: Date
    let title: String
    let description: String?
    let rssURL: URL
    let iconURL: URL
    let readerMode: Bool
    let eTag: String?
    let modifiedHeader: Date?
    let refreshedAt: Date?
    let modifiedAt: Date
    let explicitlyModifiedAt: Date?
    let categoryTitle: String
    let categoryCreatedAt: Date
    let entryTitles: [String]
    let generations: [String: String]
}

@MainActor
final class LibraryFeedEditorStorageOwnershipTests: XCTestCase, @unchecked Sendable {
    private struct DiskFixture: Sendable {
        let configuration: Realm.Configuration
        let replacementConfiguration: Realm.Configuration
        let retiredConfiguration: Realm.Configuration
        let feedID: UUID
        let categoryID: UUID
        let original: FeedEditorStorageSnapshot
        let replacement: FeedEditorStorageSnapshot
    }

    private let rssURL = URL(string: "https://example.com/feed.xml")!
    private let createdAt = Date(timeIntervalSinceReferenceDate: 100)

    private func makeFixture() async throws -> DiskFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("feed-editor-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var configuration = Realm.Configuration(fileURL: directory.appendingPathComponent("current.realm"))
        configuration.objectTypes = [
            LibraryConfiguration.self, FeedCategory.self, Feed.self, FeedEntry.self,
            FeedDirectory.self, UserScript.self, UserScriptAllowedDomain.self,
        ]
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        var replacement = configuration
        replacement.fileURL = directory.appendingPathComponent("replacement.realm")
        var retired = configuration
        retired.fileURL = directory.appendingPathComponent("retired.realm")
        // Both independently seeded files must participate in the mutation journal.
        BigSyncMutationTracking.install(configurations: [configuration, replacement], excludedClassNames: [])
        let capturedConfigurations = [configuration, replacement, retired]
        addTeardownBlock {
            for configuration in capturedConfigurations { await Self.releaseDiskCache(configuration) }
            try? FileManager.default.removeItem(at: directory)
        }
        let feedID = UUID()
        let categoryID = UUID()
        for (store, label) in [(configuration, "Original"), (replacement, "Replacement")] {
            try autoreleasepool {
                let realm = try Realm(configuration: store)
                defer { realm.invalidate() }
                try realm.write {
                    let category = FeedCategory()
                    category.id = categoryID
                    category.createdAt = createdAt
                    category.title = label
                    realm.add(category)
                    category.refreshChangeMetadata(explicitlyModified: true)
                    let feed = Feed()
                    feed.id = feedID
                    feed.createdAt = createdAt
                    feed.categoryID = categoryID
                    feed.title = ""
                    feed.rssUrl = rssURL
                    feed.iconUrl = URL(string: "about:blank")!
                    feed.lastFetchedETag = "\"seed\""
                    feed.lastFetchedModifiedAt = createdAt
                    feed.lastRefreshedEntriesAt = createdAt
                    realm.add(feed)
                    feed.refreshChangeMetadata(explicitlyModified: true)
                    let entry = FeedEntry()
                    entry.feedID = feedID
                    entry.url = URL(string: "https://example.com/entry")!
                    entry.title = label
                    entry.updateCompoundKey()
                    realm.add(entry)
                    entry.refreshChangeMetadata(explicitlyModified: true)
                }
            }
        }
        let original = try await Self.snapshot(configuration, feedID: feedID)
        let replacementState = try await Self.snapshot(replacement, feedID: feedID)
        XCTAssertEqual(original.generations.count, 3)
        XCTAssertEqual(replacementState.generations.count, 3)
        return DiskFixture(
            configuration: configuration, replacementConfiguration: replacement,
            retiredConfiguration: retired, feedID: feedID, categoryID: categoryID,
            original: original, replacement: replacementState
        )
    }

    private func editor(
        _ fixture: DiskFixture, observesRealm: Bool = false,
        beforeObservation: (@RealmBackgroundActor @Sendable () async throws -> Void)? = nil
    ) async throws -> FeedEditorStorageLifetime {
        let realm = try await Realm(configuration: fixture.configuration, actor: MainActor.shared)
        let feed = try XCTUnwrap(realm.object(ofType: Feed.self, forPrimaryKey: fixture.feedID))
        let lifetime = FeedEditorStorageLifetime(
            feed: feed, observesRealm: observesRealm, beforeObservation: beforeObservation
        )
        addTeardownBlock { await lifetime.retire() }
        return lifetime
    }

    nonisolated private static func replaceFiles(
        current: URL, replacement: URL, retired: URL
    ) throws {
        try FileManager.default.moveItem(at: current, to: retired)
        do { try FileManager.default.moveItem(at: replacement, to: current) }
        catch {
            try? FileManager.default.moveItem(at: retired, to: current)
            throw error
        }
    }

    private func replaceFile(_ fixture: DiskFixture) throws {
        try Self.replaceFiles(
            current: try XCTUnwrap(fixture.configuration.fileURL),
            replacement: try XCTUnwrap(fixture.replacementConfiguration.fileURL),
            retired: try XCTUnwrap(fixture.retiredConfiguration.fileURL)
        )
    }

    @RealmBackgroundActor
    private static func releaseDiskCache(_ configuration: Realm.Configuration) {
        let actor = RealmBackgroundActor.shared
        let keys = actor.cachedRealms.keys.filter {
            actor.cachedRealms[$0]?.configuration.fileURL == configuration.fileURL
        }
        for key in keys {
            guard let realm = actor.cachedRealms[key], !realm.isInWriteTransaction else { continue }
            actor.cachedRealms.removeValue(forKey: key)
            realm.invalidate()
        }
    }

    nonisolated private static func snapshot(
        _ configuration: Realm.Configuration, feedID: UUID
    ) async throws -> FeedEditorStorageSnapshot {
        // Use an independent synchronous Realm scheduler. An old MainActor
        // accessor deliberately remains alive while its pathname is replaced.
        try await Task.detached {
            try autoreleasepool {
                let realm = try Realm(configuration: configuration)
                defer { realm.invalidate() }
                let feed = try XCTUnwrap(realm.object(ofType: Feed.self, forPrimaryKey: feedID))
                let category = try XCTUnwrap(feed.getCategory())
                return FeedEditorStorageSnapshot(
                    createdAt: feed.createdAt, title: feed.title, description: feed.markdownDescription,
                    rssURL: feed.rssUrl, iconURL: feed.iconUrl, readerMode: feed.isReaderModeByDefault,
                    eTag: feed.lastFetchedETag, modifiedHeader: feed.lastFetchedModifiedAt,
                    refreshedAt: feed.lastRefreshedEntriesAt, modifiedAt: feed.modifiedAt,
                    explicitlyModifiedAt: feed.explicitlyModifiedAt, categoryTitle: category.title,
                    categoryCreatedAt: category.createdAt,
                    entryTitles: realm.objects(FeedEntry.self).map(\.title).sorted(),
                    generations: Dictionary(uniqueKeysWithValues: realm.objects(BigSyncPendingMutation.self).map {
                        ($0.recordName, $0.generation)
                    })
                )
            }
        }.value
    }

    private func assertStoresUnchanged(_ fixture: DiskFixture) async throws {
        await Self.releaseDiskCache(fixture.configuration)
        let current = try await Self.snapshot(fixture.configuration, feedID: fixture.feedID)
        let retired = try await Self.snapshot(fixture.retiredConfiguration, feedID: fixture.feedID)
        XCTAssertEqual(current, fixture.replacement)
        XCTAssertEqual(retired, fixture.original)
    }

    func testBufferedAndImmediateInputCannotAdoptReplacementBeforeOpening() async throws {
        for buffered in [true, false] {
            let fixture = try await makeFixture()
            let editor = try await editor(fixture)
            try replaceFile(fixture)
            if buffered {
                editor.model!.feedTitle = "Old editor draft"
            } else {
                editor.model!.feedIsReaderModeByDefault = !fixture.original.readerMode
            }
            do {
                try await editor.model!.finishEditing().value
                XCTFail("A retained editor cannot open the replacement file")
            } catch RealmBackgroundActorError.realmFileChangedDuringOpen {}
            await editor.retire()
            try await assertStoresUnchanged(fixture)
        }
    }

    func testOpenedWriterRechecksPhysicalOwnerInsideItsOwnedTransaction() async throws {
        let fixture = try await makeFixture()
        let editor = try await editor(fixture)
        let gate = FeedEditorStorageGate()
        let entered = expectation(description: "Writer opened original file")
        let task = editor.model!.writeFeedAsync(field: .url, beforeWrite: {
            await gate.wait(entered: { entered.fulfill() })
        }) { feed in
            feed.rssUrl = URL(string: "https://example.com/changed.xml")!
            return true
        }
        addTeardownBlock { task.cancel(); await gate.release(); _ = await task.result }
        await fulfillment(of: [entered], timeout: 5)
        try replaceFile(fixture)
        await gate.release()
        do {
            try await task.value
            XCTFail("An already-open writer cannot mutate its retired file")
        } catch RealmBackgroundActorError.realmFileChangedDuringOpen {}
        // Preserve #252 retry/retirement behavior while rejecting the same old owner.
        do {
            try await editor.model!.finishEditing().value
            XCTFail("Retry must retain the original physical admission")
        } catch RealmBackgroundActorError.realmFileChangedDuringOpen {}
        await editor.retire()
        try await assertStoresUnchanged(fixture)
    }

    func testMetadataFetchResultsCannotAdoptAReplacementFile() async throws {
        for icon in [false, true] {
            let fixture = try await makeFixture()
            let editor = try await editor(fixture)
            let generation = UUID()
            let rssURL = rssURL
            editor.model!.beginMetadataRefresh(rssURL: rssURL, identifier: generation)
            let gate = FeedEditorStorageGate()
            let entered = expectation(description: "Metadata transport suspended")
            let task = Task { @MainActor [model = editor.model!] in
                if icon {
                    await model.refreshIcon(expectedRSSURL: rssURL, expectedGeneration: generation) { _ in
                        await gate.wait(entered: { entered.fulfill() })
                        return URL(string: "https://example.com/icon.png")!
                    }
                } else {
                    await model.refreshFromOpenGraph(expectedRSSURL: rssURL, expectedGeneration: generation) { _ in
                        await gate.wait(entered: { entered.fulfill() })
                        return LibraryFeedOpenGraphMetadata(url: rssURL, title: "Autofill", description: "Description")
                    }
                }
            }
            addTeardownBlock { task.cancel(); await gate.release(); await task.value }
            await fulfillment(of: [entered], timeout: 5)
            try replaceFile(fixture)
            await gate.release()
            await task.value
            XCTAssertEqual(editor.model!.feedTitle, "")
            XCTAssertEqual(editor.model!.feedDescription, "")
            XCTAssertEqual(editor.model!.feedIconURL, "")
            await editor.retire()
            try await assertStoresUnchanged(fixture)
        }
    }

    func testOpenedMetadataWriterRejectsReplacementBeforeCommit() async throws {
        let fixture = try await makeFixture()
        let editor = try await editor(fixture)
        let generation = UUID()
        let rssURL = rssURL
        editor.model!.beginMetadataRefresh(rssURL: rssURL, identifier: generation)
        let gate = FeedEditorStorageGate()
        let entered = expectation(description: "Metadata writer opened original file")
        let task = Task { @MainActor [model = editor.model!] in
            await model.refreshIcon(
                expectedRSSURL: rssURL, expectedGeneration: generation,
                beforeWrite: { await gate.wait(entered: { entered.fulfill() }) },
                fetch: { _ in URL(string: "https://example.com/icon.png")! }
            )
        }
        addTeardownBlock { task.cancel(); await gate.release(); await task.value }
        await fulfillment(of: [entered], timeout: 5)
        try replaceFile(fixture)
        await gate.release()
        await task.value
        XCTAssertEqual(editor.model!.feedIconURL, "")
        await editor.retire()
        try await assertStoresUnchanged(fixture)
    }

    func testCommittedMetadataRemainsDurableWithoutHydratingTheRetiredForm() async throws {
        let fixture = try await makeFixture()
        let editor = try await editor(fixture)
        let generation = UUID()
        let rssURL = rssURL
        let iconURL = URL(string: "https://example.com/committed.png")!
        editor.model!.beginMetadataRefresh(rssURL: rssURL, identifier: generation)
        let current = try XCTUnwrap(fixture.configuration.fileURL)
        let replacement = try XCTUnwrap(fixture.replacementConfiguration.fileURL)
        let retired = try XCTUnwrap(fixture.retiredConfiguration.fileURL)
        let replaced = expectation(description: "File replaced after actual commit submission")
        let task = RealmWriteCommitObservation.$didSubmit.withValue({
            do { try Self.replaceFiles(current: current, replacement: replacement, retired: retired) }
            catch { XCTFail("Failed to replace the committed file: \(error)") }
            replaced.fulfill()
        }) {
            Task { @MainActor [model = editor.model!] in
                await model.refreshIcon(
                    expectedRSSURL: rssURL, expectedGeneration: generation,
                    fetch: { _ in iconURL }
                )
            }
        }
        addTeardownBlock { task.cancel(); await task.value }
        await task.value
        await fulfillment(of: [replaced], timeout: 5)
        XCTAssertFalse(editor.model!.formCapture.isCurrentStorage)
        XCTAssertEqual(editor.model!.feedIconURL, "")
        editor.model!.refresh()
        XCTAssertEqual(editor.model!.feedIconURL, "")
        await editor.retire()
        await Self.releaseDiskCache(fixture.configuration)
        let replacementState = try await Self.snapshot(fixture.configuration, feedID: fixture.feedID)
        let committed = try await Self.snapshot(fixture.retiredConfiguration, feedID: fixture.feedID)
        XCTAssertEqual(replacementState, fixture.replacement)
        XCTAssertEqual(committed.iconURL, iconURL)
        XCTAssertNotEqual(committed.generations, fixture.original.generations)
        XCTAssertEqual(committed.title, fixture.original.title)
    }

    func testFormTaskCaptureRetainsTheAlreadyBoundAccessorOwner() async throws {
        let fixture = try await makeFixture()
        let editor = try await editor(fixture)
        let capture = editor.model!.formCapture
        XCTAssertTrue(capture.admits(editor.model!.feed))
        try replaceFile(fixture)
        let rerender = try XCTUnwrap(capture.refreshingRowIdentity(for: editor.model!.feed))
        XCTAssertEqual(rerender.identity, capture.identity)
        XCTAssertTrue(rerender.storageAdmission === capture.storageAdmission)
        XCTAssertFalse(rerender.admits(editor.model!.feed))
        let replacementAdmission = RealmBackgroundActor.shared.captureStorageAdmission(for: fixture.configuration)
        XCTAssertNotEqual(capture.identity.storage, replacementAdmission.scopeIdentity)
        XCTAssertNil(editor.model!.currentRSSURL)
        await editor.retire()
        try await assertStoresUnchanged(fixture)
    }

    func testSameStoreRowIncarnationRefreshKeepsAdmissionAndRestartsFieldOwnership() async throws {
        enum Transition { case feedCreation, categoryCreation, categoryMove }
        for transition in [Transition.feedCreation, .categoryCreation, .categoryMove] {
            let fixture = try await makeFixture()
            let original = try await editor(fixture)
            let feed = original.model!.feed
            let realm = try XCTUnwrap(feed.realm)
            let category = try XCTUnwrap(feed.getCategory())
            let capture = original.model!.formCapture
            try realm.write {
                switch transition {
                case .feedCreation:
                    feed.createdAt = feed.createdAt.addingTimeInterval(1)
                    feed.refreshChangeMetadata(explicitlyModified: true)
                case .categoryCreation:
                    category.createdAt = category.createdAt.addingTimeInterval(1)
                    category.refreshChangeMetadata(explicitlyModified: true)
                case .categoryMove:
                    let successorCategory = FeedCategory()
                    successorCategory.createdAt = createdAt.addingTimeInterval(1)
                    realm.add(successorCategory)
                    successorCategory.refreshChangeMetadata(explicitlyModified: true)
                    feed.categoryID = successorCategory.id
                    feed.refreshChangeMetadata(explicitlyModified: true)
                }
            }
            let refreshed = try XCTUnwrap(capture.refreshingRowIdentity(for: feed))
            XCTAssertNotEqual(refreshed.identity, capture.identity)
            XCTAssertTrue(refreshed.storageAdmission === capture.storageAdmission)
            XCTAssertFalse(capture.admits(feed))
            XCTAssertTrue(refreshed.admits(feed))
            let successor = FeedEditorStorageLifetime(feed: feed, formCapture: refreshed)
            addTeardownBlock { await successor.retire() }
            let gate = FeedEditorStorageGate()
            let entered = expectation(description: "Successor waits after capturing its title intent")
            let successorWrite = successor.model!.writeFeedAsync(field: .title, beforeWrite: {
                await gate.wait(entered: { entered.fulfill() })
            }) { feed in
                feed.title = "Current incarnation"
                return true
            }
            addTeardownBlock { successorWrite.cancel(); await gate.release(); _ = await successorWrite.result }
            await fulfillment(of: [entered], timeout: 5)
            // This later input is rejected by the captured row/category guard.
            // It must also be unable to suppress the suspended valid intent.
            try await original.model!.writeFeedAsync(field: .title) { feed in
                feed.title = "Retired incarnation"
                return true
            }.value
            realm.refresh()
            XCTAssertEqual(feed.title, fixture.original.title)
            await gate.release()
            try await successorWrite.value
            realm.refresh()
            XCTAssertEqual(feed.title, "Current incarnation")
            await successor.retire()
            await original.retire()
        }
    }

    func testObservationStartupUsesTheCapturedAdmission() async throws {
        let fixture = try await makeFixture()
        let gate = FeedEditorStorageGate()
        let entered = expectation(description: "Observer waits before opening")
        let editor = try await editor(fixture, observesRealm: true, beforeObservation: {
            await gate.wait(entered: { entered.fulfill() })
        })
        let task = try XCTUnwrap(editor.model!.observationTask)
        addTeardownBlock { task.cancel(); await gate.release(); _ = await task.result }
        await fulfillment(of: [entered], timeout: 5)
        try replaceFile(fixture)
        await gate.release()
        do {
            try await task.value
            XCTFail("The old editor must not observe a matching row in the replacement")
        } catch RealmBackgroundActorError.realmFileChangedDuringOpen {}
        XCTAssertNil(editor.model!.feedEntries)
        await editor.retire()
        try await assertStoresUnchanged(fixture)
    }

    func testEntryPublicationChecksPhysicalOwnerBeforeOpeningAndAfterSuspension() async throws {
        for afterOpening in [false, true] {
            let fixture = try await makeFixture()
            let editor = try await editor(fixture)
            let gate = FeedEditorStorageGate()
            let entered = expectation(description: "Entry publication suspended")
            if !afterOpening { try replaceFile(fixture) }
            let task = Task { @MainActor [model = editor.model!] in
                try await model.refreshFeedEntries(beforePublication: {
                    if afterOpening { await gate.wait(entered: { entered.fulfill() }) }
                })
            }
            addTeardownBlock { task.cancel(); await gate.release(); _ = await task.result }
            if afterOpening {
                await fulfillment(of: [entered], timeout: 5)
                try replaceFile(fixture)
                await gate.release()
            }
            do {
                try await task.value
                XCTFail("A retired editor cannot publish entries after replacement")
            } catch RealmBackgroundActorError.realmFileChangedDuringOpen {}
            XCTAssertNil(editor.model!.feedEntries)
            await editor.retire()
            try await assertStoresUnchanged(fixture)
        }
    }

    func testUnchangedPhysicalOwnerStillPublishesEntriesAndEdits() async throws {
        let fixture = try await makeFixture()
        let editor = try await editor(fixture)
        try await editor.model!.refreshFeedEntries()
        XCTAssertEqual(editor.model!.feedEntries?.map(\.title), ["Original"])
        try await editor.model!.writeFeedAsync(field: .title) { feed in
            feed.title = "Accepted"
            return true
        }.value
        try await editor.model!.finishEditing().value
        XCTAssertEqual(editor.model!.feedTitle, "Accepted")
        await editor.retire()
        await Self.releaseDiskCache(fixture.configuration)
        let current = try await Self.snapshot(fixture.configuration, feedID: fixture.feedID)
        let replacement = try await Self.snapshot(fixture.replacementConfiguration, feedID: fixture.feedID)
        XCTAssertEqual(current.title, "Accepted")
        XCTAssertNotEqual(current.generations, fixture.original.generations)
        XCTAssertEqual(replacement, fixture.replacement)
    }

    func testCancelledEntryPublicationDoesNotPublishTheCurrentStoresRows() async throws {
        let fixture = try await makeFixture()
        let editor = try await editor(fixture)
        let gate = FeedEditorStorageGate()
        let entered = expectation(description: "Entry publication waits before delivery")
        let task = Task { @MainActor [model = editor.model!] in
            try await model.refreshFeedEntries(beforePublication: {
                await gate.wait(entered: { entered.fulfill() })
            })
        }
        addTeardownBlock { task.cancel(); await gate.release(); _ = await task.result }
        await fulfillment(of: [entered], timeout: 5)
        task.cancel()
        await gate.release()
        do {
            try await task.value
            XCTFail("Cancelled entry delivery must remain cancelled")
        } catch is CancellationError {}
        XCTAssertNil(editor.model!.feedEntries)
        await editor.retire()
        let current = try await Self.snapshot(fixture.configuration, feedID: fixture.feedID)
        XCTAssertEqual(current, fixture.original)
    }

    func testRetiredEditorsInputCannotSuppressNewPhysicalOwnersIntent() async throws {
        let fixture = try await makeFixture()
        let oldEditor = try await editor(fixture)
        try replaceFile(fixture)
        let admission = RealmBackgroundActor.shared.captureStorageAdmission(for: fixture.configuration)
        let ordering = LibraryFeedWriteOrdering.shared(
            configuration: fixture.configuration, storageAdmission: admission,
            feedID: fixture.feedID, createdAt: createdAt,
            categoryID: fixture.categoryID, categoryCreatedAt: createdAt
        )
        let sequence = ordering.issueSequence(field: .title)
        let command = LibraryFeedFieldCommand(
            feedID: fixture.feedID, feedCreatedAt: createdAt,
            categoryID: fixture.categoryID, categoryCreatedAt: createdAt,
            realmConfiguration: fixture.configuration, storageAdmission: admission,
            field: .title, sequence: sequence, metadataIntent: nil, writeOrdering: ordering
        ) { feed in
            feed.title = "Replacement owner's input"
            return true
        }
        // A later input from the retained original model must use another scope.
        let oldWrite = oldEditor.model!.writeFeedAsync(field: .title) { feed in
            feed.title = "Retired input"
            return true
        }
        do {
            try await oldWrite.value
            XCTFail("The old owner cannot write after replacement")
        } catch RealmBackgroundActorError.realmFileChangedDuringOpen {}
        let write = Task { @RealmBackgroundActor in try await command.write() }
        addTeardownBlock { write.cancel(); _ = await write.result }
        try await write.value
        await oldEditor.retire()
        await Self.releaseDiskCache(fixture.configuration)
        let current = try await Self.snapshot(fixture.configuration, feedID: fixture.feedID)
        let retired = try await Self.snapshot(fixture.retiredConfiguration, feedID: fixture.feedID)
        XCTAssertEqual(current.title, "Replacement owner's input")
        XCTAssertNotEqual(current.generations, fixture.replacement.generations)
        XCTAssertEqual(retired, fixture.original)
    }
}
