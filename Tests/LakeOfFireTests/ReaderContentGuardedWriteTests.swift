import BigSyncKit
import Foundation
import RealmSwift
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireReader
@testable import RealmSwiftGaps
@testable import SwiftUIWebView

final class ReaderContentGuardedWriteTests: XCTestCase {
    private static let seedDate = Date(timeIntervalSince1970: 1_700_000_000)
    private static let mutationDate = Date(timeIntervalSince1970: 1_700_000_100)

    private enum FixtureError: Error {
        case missingHeldTransaction
        case unexpectedOpenTransaction
    }

    private struct MutationState: Equatable, Sendable {
        let key: String
        let url: URL
        let createdAt: Date
        let title: String
        let author: String
        let modifiedAt: Date
        let explicitlyModifiedAt: Date?
        let recordName: String
        let entityType: String
        let objectIdentifier: String
        let generation: String
        let changedAt: Date
        let accountScopeIdentifier: String?
        let replicaBindingGenerationIdentifier: String?
        let requiresReplicaBindingRecovery: Bool
    }

    @MainActor
    private func fixture(physicalRemovalControl: Bool = false) throws -> (Realm, HistoryRecord) {
        let identifier = "GuardedContentWrite-\(UUID().uuidString)"
        var configuration = Realm.Configuration(inMemoryIdentifier: identifier)
        configuration.objectTypes = [
            Bookmark.self, HistoryRecord.self, ContentFile.self, Feed.self, FeedEntry.self,
            BigSyncPendingMutation.self,
        ]
        // Physical removal exercises retired Realm accessors, not synchronized
        // deletion. Exclude only this fixture's History rows from synchronization;
        // all ordinary mutation fixtures register and assert their journal.
        BigSyncMutationTracking.install(
            configurations: [configuration],
            excludedClassNames: physicalRemovalControl ? [HistoryRecord.className()] : []
        )
        addTeardownBlock {
            // Also covers a fixture setup failure before a queued task exists.
            // Registered task teardowns run first and join any actual writer.
            await Self.cancelFixtureWrite(owner: .shared, identifier: identifier)
            await Self.releaseCachedRealms(owner: .shared, identifier: identifier)
        }
        let realm = try Realm(configuration: configuration)
        let record = HistoryRecord()
        record.url = URL(string: "https://example.com/guarded-write/\(UUID().uuidString)")!
        record.createdAt = Self.seedDate
        record.title = "Original"
        record.author = "Original author"
        record.rssContainsFullContent = true
        record.updateCompoundKey()
        try realm.write {
            realm.add(record)
            record.refreshChangeMetadata(explicitlyModified: true, at: Self.seedDate)
        }
        if physicalRemovalControl {
            XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
        }
        return (realm, record)
    }

    private static func mutationState(for record: HistoryRecord, in realm: Realm) throws -> MutationState {
        let pending = try XCTUnwrap(realm.object(ofType: BigSyncPendingMutation.self,
            forPrimaryKey: record.objectSchema.className + "." + record.compoundKey))
        XCTAssertFalse(pending.generation.isEmpty)
        XCTAssertEqual(pending.changedAt, record.modifiedAt)
        XCTAssertEqual(pending.changedAt, record.explicitlyModifiedAt)
        return MutationState(key: record.compoundKey, url: record.url, createdAt: record.createdAt,
            title: record.title, author: record.author,
            modifiedAt: record.modifiedAt, explicitlyModifiedAt: record.explicitlyModifiedAt,
            recordName: pending.recordName, entityType: pending.entityType,
            objectIdentifier: pending.objectIdentifier,
            generation: pending.generation, changedAt: pending.changedAt,
            accountScopeIdentifier: pending.accountScopeIdentifier,
            replicaBindingGenerationIdentifier: pending.replicaBindingGenerationIdentifier,
            requiresReplicaBindingRecovery: pending.requiresReplicaBindingRecovery)
    }

    private static func releaseCachedRealms(owner: isolated RealmBackgroundActor, identifier: String) {
        let cached = owner.cachedRealms.filter { $0.value.configuration.inMemoryIdentifier == identifier }
        guard cached.values.allSatisfy({ !$0.isInWriteTransaction }) else {
            XCTFail("Join the queued writer and retire the fixture's transaction before cleanup")
            return
        }
        for key in cached.keys {
            owner.cachedRealms.removeValue(forKey: key)?.invalidate()
        }
    }

    private static func cancelFixtureWrite(owner: isolated RealmBackgroundActor, identifier: String) {
        // This unique locator belongs only to this fixture. The queued writer
        // has already settled before its separate held transaction is released.
        for realm in owner.cachedRealms.values where realm.configuration.inMemoryIdentifier == identifier {
            if realm.isInWriteTransaction { realm.cancelWrite() }
        }
    }

    private func track<Result: Sendable>(_ task: Task<Result, Error>, configuration: Realm.Configuration) {
        let identifier = configuration.inMemoryIdentifier!
        addTeardownBlock {
            task.cancel()
            _ = await task.result
            await Self.cancelFixtureWrite(owner: .shared, identifier: identifier)
        }
    }

    @RealmBackgroundActor
    private static func beginFixtureWrite(_ configuration: Realm.Configuration) async throws {
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        guard !realm.isInWriteTransaction else { throw FixtureError.unexpectedOpenTransaction }
        try realm.beginWrite()
    }

    private static func beginCachedFixtureWrite(
        owner: isolated RealmBackgroundActor, configuration: Realm.Configuration
    ) throws {
        let realm = try XCTUnwrap(owner.cachedRealms[owner.realmCacheKey(for: configuration)])
        guard !realm.isInWriteTransaction else { throw FixtureError.unexpectedOpenTransaction }
        try realm.beginWrite()
    }

    @MainActor
    private func queuedWrite(
        _ record: HistoryRecord,
        submitted: XCTestExpectation,
        _ operation: @escaping @RealmBackgroundActor (Realm, any ReaderContentProtocol) -> Void
    ) -> Task<Void, Error> {
        Task { @MainActor in
            try await RealmWriteSubmissionObservation.$willSubmit.withValue({ submitted.fulfill() }) {
                try await record.asyncWrite(operation)
            }
        }
    }

    @MainActor
    func testLiveManagedContentWritesInsideOwnedTransaction() async throws {
        let (realm, record) = try fixture()
        let seeded = try Self.mutationState(for: record, in: realm)
        try await record.asyncWrite { targetRealm, content in
            XCTAssertTrue(targetRealm.isInWriteTransaction)
            content.title = "Edited"
            content.refreshChangeMetadata(explicitlyModified: true, at: Self.mutationDate)
        }
        XCTAssertEqual(record.title, "Edited", "The source Realm is refreshed before success returns")
        let settled = try Self.mutationState(for: record, in: realm)
        XCTAssertNotEqual(settled.generation, seeded.generation)
        XCTAssertEqual(settled.changedAt, Self.mutationDate)
    }

    @MainActor
    func testFrozenLiveRowWritesWithoutRefreshingFrozenRealm() async throws {
        let (realm, record) = try fixture()
        let frozen = record.freeze()
        let seeded = try Self.mutationState(for: record, in: realm)
        try await frozen.asyncWrite { targetRealm, content in
            XCTAssertTrue(targetRealm.isInWriteTransaction)
            content.title = "Edited"
            content.refreshChangeMetadata(explicitlyModified: true, at: Self.mutationDate)
        }
        await realm.asyncRefresh()
        XCTAssertEqual(record.title, "Edited")
        XCTAssertEqual(frozen.title, "Original")
        XCTAssertEqual(frozen.modifiedAt, seeded.modifiedAt)
        let settled = try Self.mutationState(for: record, in: realm)
        XCTAssertNotEqual(settled.generation, seeded.generation)
        XCTAssertEqual(settled.changedAt, Self.mutationDate)
    }

    @MainActor
    func testFrozenDeletedRowDoesNotRunMutation() async throws {
        let (realm, record) = try fixture(physicalRemovalControl: true)
        let frozen = record.freeze()
        try realm.write { realm.delete(record) }
        XCTAssertFalse(frozen.isInvalidated, "The historical frozen row remains readable")
        try await frozen.asyncWrite { _, _ in
            XCTFail("A physically deleted row must not run the mutation")
        }
        await realm.asyncRefresh()
        XCTAssertTrue(realm.objects(HistoryRecord.self).isEmpty)
        XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
        XCTAssertEqual(frozen.title, "Original")
    }

    @MainActor
    func testAlreadyInvalidatedRowDoesNotReadIdentityOrRunMutation() async throws {
        let (realm, record) = try fixture(physicalRemovalControl: true)
        try realm.write { realm.delete(record) }
        XCTAssertTrue(record.isInvalidated)
        try await RealmWriteSubmissionObservation.$willSubmit.withValue({
            XCTFail("An invalidated input must be rejected before submitting a write")
        }) {
            try await record.asyncWrite { _, _ in XCTFail("Invalidated input must be ignored") }
        }
        XCTAssertTrue(realm.objects(HistoryRecord.self).isEmpty)
        XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
    }

    @MainActor
    func testUnmanagedContentDoesNotOpenDefaultStorage() async throws {
        let (realm, managed) = try fixture()
        let previousDefault = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = realm.configuration
        defer { Realm.Configuration.defaultConfiguration = previousDefault }
        let seeded = try Self.mutationState(for: managed, in: realm)
        let unmanaged = HistoryRecord()
        unmanaged.url = managed.url
        unmanaged.createdAt = managed.createdAt
        unmanaged.updateCompoundKey()
        XCTAssertEqual(unmanaged.compoundKey, managed.compoundKey)
        try await RealmWriteSubmissionObservation.$willSubmit.withValue({
            XCTFail("Unmanaged input cannot submit a write to default storage")
        }) {
            try await unmanaged.asyncWrite { _, content in
                XCTFail("Unmanaged input cannot nominate a same-key default-store row")
                content.title = "Unexpected default-store edit"
            }
        }
        XCTAssertNil(unmanaged.realm)
        XCTAssertEqual(try Self.mutationState(for: managed, in: realm), seeded)
        let identifier = try XCTUnwrap(realm.configuration.inMemoryIdentifier)
        await Self.assertNoCachedRealm(owner: .shared, identifier: identifier)
    }

    private static func assertNoCachedRealm(owner: isolated RealmBackgroundActor, identifier: String) {
        XCTAssertFalse(owner.cachedRealms.values.contains {
            $0.configuration.inMemoryIdentifier == identifier
        })
    }

    @MainActor
    func testPreCancelledWriteLeavesOriginalContentUnchanged() async throws {
        let (realm, record) = try fixture()
        let seeded = try Self.mutationState(for: record, in: realm)
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            try await RealmWriteSubmissionObservation.$willSubmit.withValue({
                XCTFail("A pre-cancelled caller must not submit a write")
            }) {
                try await record.asyncWrite { _, _ in XCTFail("Cancelled write must not mutate") }
            }
        }
        track(task, configuration: realm.configuration)
        do {
            try await task.value
            XCTFail("Pre-cancelled managed writes must report cancellation")
        } catch is CancellationError { }
        await realm.asyncRefresh()
        XCTAssertEqual(try Self.mutationState(for: record, in: realm), seeded)
    }

    @MainActor
    func testQueuedDeletionResolvesInsideTheAdmittedTransaction() async throws {
        let (realm, record) = try fixture(physicalRemovalControl: true)
        let configuration = realm.configuration
        let key = record.compoundKey
        try await Self.beginFixtureWrite(configuration)
        let submitted = expectation(description: "generic write queued its own SDK ticket")
        let task = queuedWrite(record, submitted: submitted) { _, _ in
            XCTFail("A row removed while admission waits must not run the callback")
        }
        track(task, configuration: configuration)
        await fulfillment(of: [submitted], timeout: 2)
        try await { @RealmBackgroundActor in
            let target = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            guard target.isInWriteTransaction else { throw FixtureError.missingHeldTransaction }
            target.delete(try XCTUnwrap(target.object(ofType: HistoryRecord.self, forPrimaryKey: key)))
            try target.commitWrite()
        }()
        try await task.value
        XCTAssertTrue(record.isInvalidated)
        XCTAssertTrue(realm.objects(HistoryRecord.self).isEmpty)
        XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
    }

    @MainActor
    func testQueuedWriteDoesNotAdoptARecreatedSameKeyRow() async throws {
        let (realm, record) = try fixture()
        let configuration = realm.configuration
        let key = record.compoundKey
        let url = record.url
        try await Self.beginFixtureWrite(configuration)
        let submitted = expectation(description: "old row writer queued before atomic replacement")
        let task = queuedWrite(record, submitted: submitted) { _, _ in
            XCTFail("A newly created row must not inherit the original caller's write")
        }
        track(task, configuration: configuration)
        await fulfillment(of: [submitted], timeout: 2)
        let replacementState = try await { @RealmBackgroundActor in
            let target = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            guard target.isInWriteTransaction else { throw FixtureError.missingHeldTransaction }
            target.delete(try XCTUnwrap(target.object(ofType: HistoryRecord.self, forPrimaryKey: key)))
            let replacement = HistoryRecord()
            replacement.compoundKey = key
            replacement.url = url
            replacement.createdAt = Self.seedDate.addingTimeInterval(1)
            replacement.title = "Replacement"
            replacement.author = "Replacement author"
            target.add(replacement)
            // This atomic replacement has a live final owner for the same sync
            // key. Publish that successor and its authoritative journal together.
            replacement.refreshChangeMetadata(explicitlyModified: true, at: Self.mutationDate)
            let state = try Self.mutationState(for: replacement, in: target)
            try target.commitWrite()
            return state
        }()
        try await task.value
        XCTAssertTrue(record.isInvalidated)
        let replacement = try XCTUnwrap(realm.object(ofType: HistoryRecord.self, forPrimaryKey: key))
        XCTAssertEqual(try Self.mutationState(for: replacement, in: realm), replacementState)
        XCTAssertEqual(realm.objects(HistoryRecord.self).count, 1)
        XCTAssertEqual(realm.objects(BigSyncPendingMutation.self).count, 1)
    }

    @MainActor
    func testQueuedWriteDoesNotFollowARetargetedURL() async throws {
        let (realm, record) = try fixture()
        let configuration = realm.configuration
        let key = record.compoundKey
        let retargetedURL = record.url.appendingPathComponent("retargeted")
        try await Self.beginFixtureWrite(configuration)
        let submitted = expectation(description: "old URL writer queued before retargeting")
        let task = queuedWrite(record, submitted: submitted) { _, _ in
            XCTFail("An existing row retargeted to another URL must reject the old caller")
        }
        track(task, configuration: configuration)
        await fulfillment(of: [submitted], timeout: 2)
        let retargeted = try await { @RealmBackgroundActor in
            let target = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            guard target.isInWriteTransaction else { throw FixtureError.missingHeldTransaction }
            let content = try XCTUnwrap(target.object(ofType: HistoryRecord.self, forPrimaryKey: key))
            content.url = retargetedURL
            content.refreshChangeMetadata(explicitlyModified: true, at: Self.mutationDate)
            let state = try Self.mutationState(for: content, in: target)
            try target.commitWrite()
            return state
        }()
        try await task.value
        XCTAssertFalse(record.isInvalidated)
        XCTAssertEqual(try Self.mutationState(for: record, in: realm), retargeted)
        XCTAssertEqual(record.createdAt, Self.seedDate)
        XCTAssertEqual(record.compoundKey, key)
    }

    @MainActor
    func testCancelledQueuedWritePreservesTheOtherOwnersTransactionAndJournal() async throws {
        let (realm, record) = try fixture()
        let configuration = realm.configuration
        let key = record.compoundKey
        let owned = try await { @RealmBackgroundActor in
            let target = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            try target.beginWrite()
            let content = try XCTUnwrap(target.object(ofType: HistoryRecord.self, forPrimaryKey: key))
            content.title = "Other owner's change"
            content.refreshChangeMetadata(explicitlyModified: true, at: Self.mutationDate)
            return try Self.mutationState(for: content, in: target)
        }()
        let submitted = expectation(description: "cancelled generic writer submitted its own ticket")
        let task = queuedWrite(record, submitted: submitted) { _, _ in
            XCTFail("The cancelled queued callback must never run")
        }
        track(task, configuration: configuration)
        await fulfillment(of: [submitted], timeout: 2)
        task.cancel()
        do {
            try await task.value
            XCTFail("Cancellation before admission must reject the queued writer")
        } catch is CancellationError { }
        try await { @RealmBackgroundActor in
            let target = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            guard target.isInWriteTransaction else { throw FixtureError.missingHeldTransaction }
            let content = try XCTUnwrap(target.object(ofType: HistoryRecord.self, forPrimaryKey: key))
            XCTAssertEqual(try Self.mutationState(for: content, in: target), owned)
            try target.commitWrite()
        }()
        await realm.asyncRefresh()
        XCTAssertEqual(try Self.mutationState(for: record, in: realm), owned)
    }

    @MainActor
    func testCancellationAfterCommitSubmissionStillReturnsSettledMutation() async throws {
        let (realm, record) = try fixture()
        let seeded = try Self.mutationState(for: record, in: realm)
        let task = Task { @MainActor in
            try await RealmWriteCommitObservation.$didSubmit.withValue({
                withUnsafeCurrentTask { $0?.cancel() }
            }) {
                try await record.asyncWrite { _, content in
                    content.title = "Durably committed"
                    content.refreshChangeMetadata(explicitlyModified: true, at: Self.mutationDate)
                }
            }
            return Task.isCancelled
        }
        track(task, configuration: realm.configuration)
        let wasCancelled = try await task.value
        XCTAssertTrue(wasCancelled)
        XCTAssertEqual(record.title, "Durably committed")
        let settled = try Self.mutationState(for: record, in: realm)
        XCTAssertNotEqual(settled.generation, seeded.generation)
        XCTAssertEqual(settled.changedAt, Self.mutationDate)
        let configuration = realm.configuration
        let key = record.compoundKey
        try await { @RealmBackgroundActor in
            let target = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            XCTAssertFalse(target.isInWriteTransaction)
            let content = try XCTUnwrap(target.object(ofType: HistoryRecord.self, forPrimaryKey: key))
            XCTAssertEqual(try Self.mutationState(for: content, in: target), settled)
        }()
    }

    @MainActor
    private func metadataFixture(realm: Realm, url: URL) throws -> GuardedMetadataFixture {
        let fixture = try GuardedMetadataFixture(contentConfiguration: realm.configuration, url: url)
        let released = fixture.modelReleased
        addTeardownBlock {
            await fixture.releaseModel()
            let result = await XCTWaiter.fulfillment(of: [released], timeout: 5)
            guard result == .completed else {
                XCTFail("The production model must retire before shared configuration is restored")
                return
            }
            await fixture.finishCleanup()
        }
        return fixture
    }

    @MainActor
    private func queuedMetadata(
        _ model: ReaderViewModel,
        configuration: Realm.Configuration,
        submitted: XCTestExpectation
    ) -> Task<Void, Error> {
        Task { @MainActor in
            try await RealmWriteSubmissionObservation.$willSubmit.withValue({
                // This exact Gaps hook runs synchronously on the Realm owner,
                // after discovery and immediately before its SDK begin ticket.
                // Hold only this fixture's cached Realm, so the actual caller
                // is forced to wait without suspending or replacing that hook.
                do {
                    try RealmBackgroundActor.shared.assumeIsolated { owner in
                        try Self.beginCachedFixtureWrite(owner: owner, configuration: configuration)
                    }
                } catch {
                    XCTFail("Could not hold the metadata fixture's writer: \(error)")
                }
                submitted.fulfill()
            }) {
                try await model.pageMetadataUpdated(title: "Edited", author: "New author")
            }
        }
    }

    @MainActor
    func testMetadataCallerSkipsAnInvalidatedRowAfterItsQueuedWrite() async throws {
        let (realm, record) = try fixture(physicalRemovalControl: true)
        let fixture = try metadataFixture(realm: realm, url: record.url)
        let model = try XCTUnwrap(fixture.model)
        let configuration = realm.configuration
        let key = record.compoundKey
        let submitted = expectation(description: "actual metadata callback queued after discovery")
        let task = queuedMetadata(model, configuration: configuration, submitted: submitted)
        track(task, configuration: configuration)
        await fulfillment(of: [submitted], timeout: 2)
        try await { @RealmBackgroundActor in
            let target = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            guard target.isInWriteTransaction else { throw FixtureError.missingHeldTransaction }
            target.delete(try XCTUnwrap(target.object(ofType: HistoryRecord.self, forPrimaryKey: key)))
            try target.commitWrite()
        }()
        try await task.value
        await realm.asyncRefresh()
        XCTAssertTrue(record.isInvalidated)
        XCTAssertTrue(realm.objects(HistoryRecord.self).isEmpty)
        XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
        let evaluations = await fixture.evaluations.titles
        XCTAssertTrue(evaluations.isEmpty)
    }

    @MainActor
    func testMetadataCallerDoesNotJournalValuesAlreadySuppliedWhileQueued() async throws {
        let (realm, record) = try fixture()
        let fixture = try metadataFixture(realm: realm, url: record.url)
        let model = try XCTUnwrap(fixture.model)
        let configuration = realm.configuration
        let key = record.compoundKey
        let submitted = expectation(description: "actual metadata writer waits for the competing owner")
        let task = queuedMetadata(model, configuration: configuration, submitted: submitted)
        track(task, configuration: configuration)
        await fulfillment(of: [submitted], timeout: 2)
        let supplied = try await { @RealmBackgroundActor in
            let target = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            guard target.isInWriteTransaction else { throw FixtureError.missingHeldTransaction }
            let content = try XCTUnwrap(target.object(ofType: HistoryRecord.self, forPrimaryKey: key))
            content.title = "Edited"
            content.author = "New author"
            content.refreshChangeMetadata(explicitlyModified: true, at: Self.mutationDate)
            let supplied = try Self.mutationState(for: content, in: target)
            try target.commitWrite()
            return supplied
        }()
        try await task.value
        await realm.asyncRefresh()
        XCTAssertEqual(try Self.mutationState(for: record, in: realm), supplied)
        let evaluations = await fixture.evaluations.titles
        XCTAssertEqual(evaluations, ["Edited"])
    }

    @MainActor
    func testMetadataCallerPersistsAndPublishesALiveChangedTitle() async throws {
        let (realm, record) = try fixture()
        let seeded = try Self.mutationState(for: record, in: realm)
        let fixture = try metadataFixture(realm: realm, url: record.url)
        let model = try XCTUnwrap(fixture.model)
        try await model.pageMetadataUpdated(title: "Edited", author: "New author")
        await realm.asyncRefresh()
        let settled = try Self.mutationState(for: record, in: realm)
        XCTAssertEqual(settled.title, "Edited")
        XCTAssertEqual(settled.author, "New author")
        XCTAssertNotEqual(settled.generation, seeded.generation)
        let evaluations = await fixture.evaluations.titles
        XCTAssertEqual(evaluations, ["Edited"])
        try await model.pageMetadataUpdated(title: "Edited", author: "New author")
        await realm.asyncRefresh()
        XCTAssertEqual(try Self.mutationState(for: record, in: realm), settled)
    }
}

private actor GuardedMetadataEvaluations {
    private(set) var titles = [String]()
    func record(_ title: String?) { titles.append(title ?? "<missing title>") }
}

/// Keeps the production initializer, observers and script updates intact.
@MainActor
private final class GuardedMetadataViewModel: ReaderViewModel {
    private let released: XCTestExpectation

    init(configuration: Realm.Configuration, released: XCTestExpectation) {
        self.released = released
        super.init(realmConfiguration: configuration, systemScripts: [])
    }

    deinit { released.fulfill() }
}

@MainActor
private final class GuardedMetadataFixture {
    let evaluations = GuardedMetadataEvaluations()
    let modelReleased = XCTestExpectation(description: "Production metadata model released")
    private(set) var model: GuardedMetadataViewModel?
    private let bindingOwner = UUID()
    private let libraryConfiguration: Realm.Configuration
    private let previousLibraryConfiguration: Realm.Configuration
    private let previousContentResolver: ReaderContent.ContentResolver?
    private let previousBookmarkConfiguration: Realm.Configuration
    private let previousHistoryConfiguration: Realm.Configuration
    private let previousFeedConfiguration: Realm.Configuration
    private let previousProviders: [ReaderContentAdditionalProvider]
    private var libraryRealm: Realm?

    init(contentConfiguration: Realm.Configuration, url: URL) throws {
        previousLibraryConfiguration = LibraryDataManager.realmConfiguration
        previousContentResolver = ReaderContent.contentResolver
        previousBookmarkConfiguration = ReaderContentLoader.bookmarkRealmConfiguration
        previousHistoryConfiguration = ReaderContentLoader.historyRealmConfiguration
        previousFeedConfiguration = ReaderContentLoader.feedEntryRealmConfiguration
        previousProviders = ReaderContentLoader.additionalContentProviders
        var configuration = LakeOfFireContent.DefaultRealmConfiguration.configuration
        configuration.fileURL = nil
        configuration.inMemoryIdentifier = "GuardedMetadataLibrary-\(UUID().uuidString)"
        libraryConfiguration = configuration
        BigSyncMutationTracking.install(
            configurations: [configuration],
            excludedClassNames: (configuration.objectTypes ?? []).map { $0.className() }
        )
        let realm = try Realm(configuration: configuration)
        try realm.write { realm.add(LibraryConfiguration()) }
        libraryRealm = realm

        LibraryDataManager.realmConfiguration = configuration
        ReaderContentLoader.bookmarkRealmConfiguration = contentConfiguration
        ReaderContentLoader.historyRealmConfiguration = contentConfiguration
        ReaderContentLoader.feedEntryRealmConfiguration = contentConfiguration
        ReaderContentLoader.additionalContentProviders = []
        let model = GuardedMetadataViewModel(configuration: configuration, released: modelReleased)
        model.state.pageURL = url
        model.scriptCaller.installBinding(
            ownedBy: bindingOwner,
            asyncCaller: { [evaluations] _, arguments, _, _ in
                await evaluations.record(arguments?["title"] as? String)
                return .init(nil)
            },
            unsafeCaller: nil,
            snapshotCapture: nil
        )
        self.model = model
    }

    func releaseModel() {
        model?.scriptCaller.clearBinding(ownedBy: bindingOwner)
        model = nil
    }

    func finishCleanup() async {
        ReaderContent.contentResolver = previousContentResolver
        LibraryDataManager.realmConfiguration = previousLibraryConfiguration
        ReaderContentLoader.bookmarkRealmConfiguration = previousBookmarkConfiguration
        ReaderContentLoader.historyRealmConfiguration = previousHistoryConfiguration
        ReaderContentLoader.feedEntryRealmConfiguration = previousFeedConfiguration
        ReaderContentLoader.additionalContentProviders = previousProviders
        libraryRealm?.invalidate()
        libraryRealm = nil
        if let identifier = libraryConfiguration.inMemoryIdentifier {
            await releaseGuardedMetadataCachedRealms(owner: .shared, identifier: identifier)
        }
    }
}

private func releaseGuardedMetadataCachedRealms(owner: isolated RealmBackgroundActor, identifier: String) {
    let cached = owner.cachedRealms.filter { $0.value.configuration.inMemoryIdentifier == identifier }
    guard cached.values.allSatisfy({ !$0.isInWriteTransaction }) else {
        XCTFail("Fixture observers must retire before library cache cleanup")
        return
    }
    for key in cached.keys {
        owner.cachedRealms.removeValue(forKey: key)?.invalidate()
    }
}
