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
        beforeObservation: (@RealmBackgroundActor @Sendable () async throws -> Void)? = nil,
        beforeFieldWrite: (@RealmBackgroundActor @Sendable () async throws -> Void)? = nil
    ) {
        let retired = XCTestExpectation(description: "Captured editor retirement settled")
        self.retired = retired
        model = LibraryFeedFormSectionsViewModel(
            feed: feed, formCapture: formCapture, observesRealm: observesRealm, beforeObservation: beforeObservation,
            beforeFieldWrite: beforeFieldWrite,
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

private enum FeedEditorPhysicalReplacement: CaseIterable, Equatable, Sendable {
    case feed, category
}

private enum FeedEditorControlledFailure: Error {
    case firstAttempt
}

private actor FeedEditorPhysicalWriteAttempts {
    private(set) var count = 0
    func record() -> Int { count += 1; return count }
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
        _ fixture: DiskFixture, observesRealm: Bool = false, frozen: Bool = false,
        beforeObservation: (@RealmBackgroundActor @Sendable () async throws -> Void)? = nil,
        beforeFieldWrite: (@RealmBackgroundActor @Sendable () async throws -> Void)? = nil
    ) async throws -> FeedEditorStorageLifetime {
        let realm = try await Realm(configuration: fixture.configuration, actor: MainActor.shared)
        let feed = try XCTUnwrap(realm.object(ofType: Feed.self, forPrimaryKey: fixture.feedID))
        let lifetime = FeedEditorStorageLifetime(
            feed: frozen ? feed.freeze() : feed, observesRealm: observesRealm,
            beforeObservation: beforeObservation, beforeFieldWrite: beforeFieldWrite
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

    @RealmBackgroundActor
    private static func physicalIdentity(
        configuration: Realm.Configuration, admission: RealmStorageAdmission, feedID: UUID
    ) async throws -> LibraryFeedPhysicalIdentity {
        let realm = try await RealmBackgroundActor.shared.cachedRealm(
            for: configuration, storageAdmission: admission
        )
        let feed = try XCTUnwrap(realm.object(ofType: Feed.self, forPrimaryKey: feedID))
        return LibraryFeedPhysicalIdentity(feed: feed)
    }

    @RealmBackgroundActor
    private static func entryObservationCount(_ model: LibraryFeedFormSectionsViewModel) -> Int {
        model.realmCancellables.count
    }

    @discardableResult
    private func replacePhysicalRow(
        _ replacement: FeedEditorPhysicalReplacement, fixture: DiskFixture, in realm: Realm
    ) throws -> Feed {
        let feed = try XCTUnwrap(realm.object(ofType: Feed.self, forPrimaryKey: fixture.feedID))
        let identity = LibraryFeedPhysicalIdentity(feed: feed)
        let feedCreatedAt = feed.createdAt
        let category = try XCTUnwrap(feed.getCategory())
        let categoryCreatedAt = category.createdAt
        switch replacement {
        case .feed:
            let successor = Feed()
            for property in feed.objectSchema.properties {
                successor[property.name] = feed[property.name]
            }
            // Separate committed delete/create phases preserve every persisted
            // field, as a synchronized recreation can, but replace the ObjKey.
            try realm.write { realm.delete(feed) }
            try realm.write {
                realm.add(successor)
                successor.refreshChangeMetadata(explicitlyModified: true)
            }
        case .category:
            let successor = FeedCategory()
            for property in category.objectSchema.properties {
                successor[property.name] = category[property.name]
            }
            try realm.write { realm.delete(category) }
            try realm.write {
                realm.add(successor)
                successor.refreshChangeMetadata(explicitlyModified: true)
            }
        }
        let successor = try XCTUnwrap(realm.object(ofType: Feed.self, forPrimaryKey: fixture.feedID))
        XCTAssertEqual(successor.createdAt, feedCreatedAt)
        XCTAssertEqual(successor.categoryID, fixture.categoryID)
        XCTAssertEqual(successor.getCategory()?.createdAt, categoryCreatedAt)
        XCTAssertNotEqual(LibraryFeedPhysicalIdentity(feed: successor), identity)
        return successor
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
        let physicalIdentity = try await Self.physicalIdentity(
            configuration: fixture.configuration, admission: admission, feedID: fixture.feedID
        )
        let ordering = LibraryFeedWriteOrdering.shared(
            configuration: fixture.configuration, storageAdmission: admission,
            feedID: fixture.feedID, createdAt: createdAt,
            categoryID: fixture.categoryID, categoryCreatedAt: createdAt, physicalIdentity: physicalIdentity
        )
        let sequence = ordering.issueSequence(field: .title)
        let command = LibraryFeedFieldCommand(
            feedID: fixture.feedID, feedCreatedAt: createdAt,
            categoryID: fixture.categoryID, categoryCreatedAt: createdAt,
            physicalIdentity: physicalIdentity,
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

    func testBufferedInputRejectsEqualFieldsPhysicalFeedAfterOpening() async throws {
        for frozen in [false, true] {
            let fixture = try await makeFixture()
            let gate = FeedEditorStorageGate()
            let entered = expectation(description: "Buffered command opened the original physical Feed")
            let editor = try await editor(fixture, frozen: frozen, beforeFieldWrite: {
                await gate.wait(entered: { entered.fulfill() })
            })
            addTeardownBlock { await gate.release() }
            let realm = try XCTUnwrap(editor.model!.feed.realm)
            editor.model!.feedTitle = "Retired draft"
            await fulfillment(of: [entered], timeout: 5)
            try replacePhysicalRow(.feed, fixture: fixture, in: realm)
            let replacement = try await Self.snapshot(fixture.configuration, feedID: fixture.feedID)
            await gate.release()
            try await editor.model!.finishEditing().value
            await editor.retire()
            let settled = try await Self.snapshot(fixture.configuration, feedID: fixture.feedID)
            XCTAssertEqual(settled, replacement)
        }
    }

    func testImmediateInputRejectsEqualFieldsCategoryAndFreshFormCanEdit() async throws {
        let fixture = try await makeFixture()
        let gate = FeedEditorStorageGate()
        let entered = expectation(description: "Immediate command opened the original category")
        let editor = try await editor(fixture, beforeFieldWrite: {
            await gate.wait(entered: { entered.fulfill() })
        })
        addTeardownBlock { await gate.release() }
        let feed = editor.model!.feed
        let realm = try XCTUnwrap(feed.realm)
        let capture = editor.model!.formCapture
        editor.model!.feedIsReaderModeByDefault = !fixture.original.readerMode
        await fulfillment(of: [entered], timeout: 5)
        try replacePhysicalRow(.category, fixture: fixture, in: realm)
        let replacement = try await Self.snapshot(fixture.configuration, feedID: fixture.feedID)
        let refreshed = try XCTUnwrap(capture.refreshingRowIdentity(for: feed))
        XCTAssertNotEqual(refreshed.identity, capture.identity)
        XCTAssertTrue(refreshed.storageAdmission === capture.storageAdmission)
        XCTAssertFalse(capture.admits(feed))
        XCTAssertTrue(refreshed.admits(feed))
        await gate.release()
        try await editor.model!.finishEditing().value
        let settled = try await Self.snapshot(fixture.configuration, feedID: fixture.feedID)
        XCTAssertEqual(settled, replacement)

        let successor = FeedEditorStorageLifetime(feed: feed, formCapture: refreshed)
        addTeardownBlock { await successor.retire() }
        successor.model!.feedTitle = "Current category owner"
        try await successor.model!.finishEditing().value
        realm.refresh()
        XCTAssertEqual(feed.title, "Current category owner")
        await successor.retire()
        await editor.retire()
    }

    func testFailedDraftRetryCannotAdoptEqualFieldsPhysicalSuccessor() async throws {
        for replacementKind in FeedEditorPhysicalReplacement.allCases {
            let fixture = try await makeFixture()
            let attempts = FeedEditorPhysicalWriteAttempts()
            let editor = try await editor(fixture, beforeFieldWrite: {
                if await attempts.record() == 1 { throw FeedEditorControlledFailure.firstAttempt }
            })
            let realm = try XCTUnwrap(editor.model!.feed.realm)
            let firstAttempt = editor.model!.writeFeedAsync(field: .title) { feed in
                guard feed.title != "Retained failed draft" else { return false }
                feed.title = "Retained failed draft"
                return true
            }
            do {
                try await firstAttempt.value
                XCTFail("The first production command must fail before application")
            } catch FeedEditorControlledFailure.firstAttempt {}
            try replacePhysicalRow(replacementKind, fixture: fixture, in: realm)
            let replacement = try await Self.snapshot(fixture.configuration, feedID: fixture.feedID)
            try await editor.model!.finishEditing().value
            let attemptCount = await attempts.count
            XCTAssertEqual(attemptCount, 2)
            await editor.retire()
            let settled = try await Self.snapshot(fixture.configuration, feedID: fixture.feedID)
            XCTAssertEqual(settled, replacement)
        }
    }

    func testRetiredInputCannotSuppressEqualFieldsPhysicalSuccessorsIntent() async throws {
        for replacementKind in FeedEditorPhysicalReplacement.allCases {
            let fixture = try await makeFixture()
            let original = try await editor(fixture)
            let realm = try XCTUnwrap(original.model!.feed.realm)
            let feed = try replacePhysicalRow(replacementKind, fixture: fixture, in: realm)
            let successor = FeedEditorStorageLifetime(feed: feed)
            addTeardownBlock { await successor.retire() }
            let gate = FeedEditorStorageGate()
            let entered = expectation(description: "Physical successor reserved its title input")
            let write = successor.model!.writeFeedAsync(field: .title, beforeWrite: {
                await gate.wait(entered: { entered.fulfill() })
            }) { feed in
                guard feed.title != "Current physical owner" else { return false }
                feed.title = "Current physical owner"
                return true
            }
            addTeardownBlock { write.cancel(); await gate.release(); _ = await write.result }
            await fulfillment(of: [entered], timeout: 5)
            let replacement = try await Self.snapshot(fixture.configuration, feedID: fixture.feedID)
            original.model!.feedTitle = "Later retired input"
            try await original.model!.finishEditing().value
            let afterRetiredInput = try await Self.snapshot(fixture.configuration, feedID: fixture.feedID)
            XCTAssertEqual(afterRetiredInput, replacement)
            await gate.release()
            try await write.value
            realm.refresh()
            XCTAssertEqual(feed.title, "Current physical owner")
            await successor.retire()
            await original.retire()
        }
    }

    func testOpenedMetadataCommandRejectsEqualFieldsPhysicalReplacement() async throws {
        for replacementKind in FeedEditorPhysicalReplacement.allCases {
            let fixture = try await makeFixture()
            let editor = try await editor(fixture)
            let realm = try XCTUnwrap(editor.model!.feed.realm)
            let generation = UUID()
            let rssURL = rssURL
            editor.model!.beginMetadataRefresh(rssURL: rssURL, identifier: generation)
            let gate = FeedEditorStorageGate()
            let entered = expectation(description: "Metadata command opened its original physical rows")
            let task = Task { @MainActor [model = editor.model!] in
                await model.refreshIcon(
                    expectedRSSURL: rssURL, expectedGeneration: generation,
                    beforeWrite: { await gate.wait(entered: { entered.fulfill() }) },
                    fetch: { _ in URL(string: "https://example.com/obsolete.png")! }
                )
            }
            addTeardownBlock { task.cancel(); await gate.release(); await task.value }
            await fulfillment(of: [entered], timeout: 5)
            try replacePhysicalRow(replacementKind, fixture: fixture, in: realm)
            let replacement = try await Self.snapshot(fixture.configuration, feedID: fixture.feedID)
            await gate.release()
            await task.value
            XCTAssertEqual(editor.model!.feedIconURL, "")
            XCTAssertNil(editor.model!.currentRSSURL)
            await editor.retire()
            let settled = try await Self.snapshot(fixture.configuration, feedID: fixture.feedID)
            XCTAssertEqual(settled, replacement)
        }
    }

    func testObserverStartupRejectsEqualFieldsSuccessorsAndKeepsCurrentOwner() async throws {
        let replacements: [FeedEditorPhysicalReplacement?] = [nil, .feed, .category]
        for replacementKind in replacements {
            let fixture = try await makeFixture()
            let gate = FeedEditorStorageGate()
            let entered = expectation(description: "Observer waits before resolving its captured rows")
            let editor = try await editor(fixture, observesRealm: true, beforeObservation: {
                await gate.wait(entered: { entered.fulfill() })
            })
            let task = try XCTUnwrap(editor.model!.observationTask)
            addTeardownBlock { task.cancel(); await gate.release(); _ = await task.result }
            await fulfillment(of: [entered], timeout: 5)
            if let replacementKind {
                let realm = try XCTUnwrap(editor.model!.feed.realm)
                try replacePhysicalRow(replacementKind, fixture: fixture, in: realm)
            }
            await gate.release()
            try await task.value
            let count = await Self.entryObservationCount(editor.model!)
            XCTAssertEqual(count, replacementKind == nil ? 1 : 0)
            if replacementKind != nil { XCTAssertNil(editor.model!.feedEntries) }
            await editor.retire()
        }
    }

    func testEntryPublicationRejectsEqualFieldsPhysicalReplacementAfterAwait() async throws {
        for replacementKind in FeedEditorPhysicalReplacement.allCases {
            let fixture = try await makeFixture()
            let editor = try await editor(fixture)
            let realm = try XCTUnwrap(editor.model!.feed.realm)
            try await editor.model!.refreshFeedEntries()
            XCTAssertEqual(editor.model!.feedEntries?.map(\.title), ["Original"])
            let gate = FeedEditorStorageGate()
            let entered = expectation(description: "Entry publication waits before current-row admission")
            let task = Task { @MainActor [model = editor.model!] in
                try await model.refreshFeedEntries(beforePublication: {
                    await gate.wait(entered: { entered.fulfill() })
                })
            }
            addTeardownBlock { task.cancel(); await gate.release(); _ = await task.result }
            await fulfillment(of: [entered], timeout: 5)
            try replacePhysicalRow(replacementKind, fixture: fixture, in: realm)
            let replacement = try await Self.snapshot(fixture.configuration, feedID: fixture.feedID)
            await gate.release()
            try await task.value
            XCTAssertNil(editor.model!.feedEntries)
            await editor.retire()
            let settled = try await Self.snapshot(fixture.configuration, feedID: fixture.feedID)
            XCTAssertEqual(settled, replacement)
        }
    }

    func testPhysicalIdentityAgreesAcrossLiveFrozenAndActorAccessors() async throws {
        let fixture = try await makeFixture()
        let realm = try await Realm(configuration: fixture.configuration, actor: MainActor.shared)
        let feed = try XCTUnwrap(realm.object(ofType: Feed.self, forPrimaryKey: fixture.feedID))
        let frozen = feed.freeze()
        let identity = LibraryFeedPhysicalIdentity(feed: feed)
        XCTAssertNotNil(identity.feedRowID)
        XCTAssertNotNil(identity.categoryRowID)
        XCTAssertEqual(identity, LibraryFeedPhysicalIdentity(feed: frozen))
        let admission = RealmBackgroundActor.shared.captureStorageAdmission(for: fixture.configuration)
        let actorIdentity = try await Self.physicalIdentity(
            configuration: fixture.configuration, admission: admission, feedID: fixture.feedID
        )
        XCTAssertEqual(identity, actorIdentity)
        let editor = FeedEditorStorageLifetime(feed: frozen)
        addTeardownBlock { await editor.retire() }
        XCTAssertFalse(editor.model!.feed.isFrozen)
        editor.model!.feedTitle = "Current frozen capture"
        try await editor.model!.finishEditing().value
        realm.refresh()
        XCTAssertEqual(feed.title, "Current frozen capture")
        XCTAssertEqual(editor.model!.feedTitle, "Current frozen capture")

        let successor = try replacePhysicalRow(.feed, fixture: fixture, in: realm)
        XCTAssertFalse(identity.matches(feed))
        XCTAssertNil(LibraryFeedPhysicalIdentity(feed: feed).feedRowID)
        XCTAssertFalse(identity.matches(successor))
        XCTAssertNotEqual(identity, LibraryFeedPhysicalIdentity(feed: successor))
        XCTAssertEqual(identity, LibraryFeedPhysicalIdentity(feed: frozen))
        let feedSuccessorIdentity = LibraryFeedPhysicalIdentity(feed: successor)
        try replacePhysicalRow(.category, fixture: fixture, in: realm)
        let categorySuccessorIdentity = LibraryFeedPhysicalIdentity(feed: successor)
        XCTAssertEqual(feedSuccessorIdentity.feedRowID, categorySuccessorIdentity.feedRowID)
        XCTAssertNotEqual(feedSuccessorIdentity.categoryRowID, categorySuccessorIdentity.categoryRowID)
        let unmanaged = Feed()
        unmanaged.id = fixture.feedID
        XCTAssertFalse(identity.matches(unmanaged))
        XCTAssertNil(LibraryFeedPhysicalIdentity(feed: unmanaged).feedRowID)
        await editor.retire()
    }

    func testCurrentRowsPreserveNoOpMetadataAndURLValidatorInvalidation() async throws {
        let fixture = try await makeFixture()
        let gate = FeedEditorStorageGate()
        let entered = expectation(description: "Current-row no-op waits behind authoritative metadata")
        let editor = try await editor(fixture, beforeFieldWrite: {
            await gate.wait(entered: { entered.fulfill() })
        })
        addTeardownBlock { await gate.release() }
        let feed = editor.model!.feed
        let realm = try XCTUnwrap(feed.realm)
        editor.model!.feedTitle = ""
        await fulfillment(of: [entered], timeout: 5)
        try realm.write {
            feed.markdownDescription = "Intervening description"
            feed.refreshChangeMetadata(explicitlyModified: true)
        }
        let beforeNoOp = try await Self.snapshot(fixture.configuration, feedID: fixture.feedID)
        await gate.release()
        try await editor.model!.finishEditing().value
        let afterNoOp = try await Self.snapshot(fixture.configuration, feedID: fixture.feedID)
        XCTAssertEqual(afterNoOp, beforeNoOp)
        XCTAssertEqual(editor.model!.feedDescription, "Intervening description")

        let nextURL = URL(string: "https://example.com/current.xml")!
        try await editor.model!.pasteRSSURL(strings: [nextURL.absoluteString]).value
        let changed = try await Self.snapshot(fixture.configuration, feedID: fixture.feedID)
        XCTAssertEqual(changed.rssURL, nextURL)
        XCTAssertNil(changed.eTag)
        XCTAssertNil(changed.modifiedHeader)
        XCTAssertNil(changed.refreshedAt)
        XCTAssertEqual(changed.description, "Intervening description")
        XCTAssertNotEqual(changed.generations, beforeNoOp.generations)
        await editor.retire()
    }

    func testQueuedCommandRechecksPhysicalCategoryAfterPeersOwnedTransaction() async throws {
        let fixture = try await makeFixture()
        let editor = try await editor(fixture)
        let configuration = fixture.configuration
        let categoryID = fixture.categoryID
        let writerGate = FeedEditorStorageGate()
        let peerGate = FeedEditorStorageGate()
        let opened = expectation(description: "Command opened its captured store")
        let peerEntered = expectation(description: "Peer owns an unchanged-category transaction")
        let submitted = expectation(description: "Editor queues its separate owned SDK admission")
        let task = RealmWriteSubmissionObservation.$willSubmit.withValue({ submitted.fulfill() }) {
            editor.model!.writeFeedAsync(field: .title, beforeWrite: {
                await writerGate.wait(entered: { opened.fulfill() })
            }) { feed in
                feed.title = "Retired queued title"
                return true
            }
        }
        addTeardownBlock {
            task.cancel()
            await writerGate.release()
            await peerGate.release()
            _ = await task.result
        }
        await fulfillment(of: [opened], timeout: 5)
        let peer = Task { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            try realm.beginWrite()
            do {
                let category = try XCTUnwrap(realm.object(ofType: FeedCategory.self, forPrimaryKey: categoryID))
                await peerGate.wait(entered: { peerEntered.fulfill() })
                XCTAssertTrue(realm.isInWriteTransaction)
                let successor = FeedCategory()
                for property in category.objectSchema.properties {
                    successor[property.name] = category[property.name]
                }
                successor.title = "Peer category"
                realm.delete(category)
                realm.add(successor)
                successor.refreshChangeMetadata(explicitlyModified: true)
                try realm.commitWrite()
            } catch {
                if realm.isInWriteTransaction { realm.cancelWrite() }
                throw error
            }
            return Dictionary(uniqueKeysWithValues: realm.objects(BigSyncPendingMutation.self).map {
                ($0.recordName, $0.generation)
            })
        }
        addTeardownBlock { await peerGate.release(); _ = await peer.result }
        await fulfillment(of: [peerEntered], timeout: 5)
        await writerGate.release()
        await fulfillment(of: [submitted], timeout: 5)
        await peerGate.release()
        let peerGenerations = try await peer.value
        try await task.value
        await editor.retire()
        let settled = try await Self.snapshot(fixture.configuration, feedID: fixture.feedID)
        XCTAssertEqual(settled.title, fixture.original.title)
        XCTAssertEqual(settled.categoryTitle, "Peer category")
        XCTAssertEqual(settled.categoryCreatedAt, fixture.original.categoryCreatedAt)
        XCTAssertEqual(settled.generations, peerGenerations)
    }
}
