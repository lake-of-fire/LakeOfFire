import BigSyncKit
import Foundation
import RealmSwift
import XCTest
@testable import LakeOfFireContent
@testable import RealmSwiftGaps

private actor LoaderMutationProviderGate {
    private var arrived = false
    private var released = false
    private var arrivals = [CheckedContinuation<Bool, Never>]()
    private var releases = [CheckedContinuation<Void, Never>]()

    func pause() async {
        arrived = true
        let waiting = arrivals
        arrivals.removeAll()
        waiting.forEach { $0.resume(returning: true) }
        guard !released else { return }
        await withCheckedContinuation { releases.append($0) }
    }

    func waitForArrival() async -> Bool {
        if arrived { return true }
        if released { return false }
        return await withCheckedContinuation { arrivals.append($0) }
    }

    func hasArrived() -> Bool { arrived }

    func release() {
        released = true
        let waiting = releases
        releases.removeAll()
        waiting.forEach { $0.resume() }
        let pending = arrivals
        arrivals.removeAll()
        pending.forEach { $0.resume(returning: arrived) }
    }
}

final class ReaderContentLoaderMutationTests: XCTestCase {
    private static let seedDate = Date(timeIntervalSinceReferenceDate: 80_000)

    private enum FixtureError: Error {
        case providerDidNotArrive
        case missingHeldTransaction
        case queuedCancellationDidNotSettle
    }

    private enum Retirement: CaseIterable {
        case tombstone
        case physicalRemoval
        case recreation
        case retargeting
    }

    private struct MutationState: Equatable {
        let key: String
        let url: URL
        let createdAt: Date
        let title: String
        let isDeleted: Bool
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

    private func configuration(excludedClassNames: [String] = []) -> Realm.Configuration {
        let identifier = "LoaderMutation-\(UUID().uuidString)"
        var configuration = Realm.Configuration(inMemoryIdentifier: identifier)
        configuration.objectTypes = [
            Bookmark.self, HistoryRecord.self, ContentFile.self, Feed.self, FeedEntry.self,
            BigSyncPendingMutation.self,
        ]
        BigSyncMutationTracking.install(
            configurations: [configuration], excludedClassNames: excludedClassNames
        )
        addTeardownBlock {
            await Self.releaseFixtureRealms(owner: .shared, identifier: identifier)
        }
        return configuration
    }

    private static func releaseFixtureRealms(
        owner: isolated RealmBackgroundActor,
        identifier: String
    ) {
        let cached = owner.cachedRealms.filter {
            $0.value.configuration.inMemoryIdentifier == identifier
        }
        guard cached.values.allSatisfy({ !$0.isInWriteTransaction }) else {
            XCTFail("Join the writer and retire its fixture-owned transaction before cleanup")
            return
        }
        for key in cached.keys {
            owner.cachedRealms.removeValue(forKey: key)?.invalidate()
        }
    }

    private static func cancelHeldFixtureWrite(
        owner: isolated RealmBackgroundActor,
        identifier: String
    ) {
        for realm in owner.cachedRealms.values
        where realm.configuration.inMemoryIdentifier == identifier && realm.isInWriteTransaction {
            realm.cancelWrite()
        }
    }

    @RealmBackgroundActor
    private func install(_ configuration: Realm.Configuration) async {
        let bookmark = ReaderContentLoader.bookmarkRealmConfiguration
        let history = ReaderContentLoader.historyRealmConfiguration
        let feed = ReaderContentLoader.feedEntryRealmConfiguration
        let providers = ReaderContentLoader.additionalContentProviders
        addTeardownBlock {
            await ReaderContentLoader.resetTransientCachesForTesting()
            ReaderContentLoader.bookmarkRealmConfiguration = bookmark
            ReaderContentLoader.historyRealmConfiguration = history
            ReaderContentLoader.feedEntryRealmConfiguration = feed
            ReaderContentLoader.additionalContentProviders = providers
        }
        select(configuration)
        ReaderContentLoader.additionalContentProviders = []
        await ReaderContentLoader.resetTransientCachesForTesting()
    }

    private func select(_ configuration: Realm.Configuration) {
        ReaderContentLoader.bookmarkRealmConfiguration = configuration
        ReaderContentLoader.historyRealmConfiguration = configuration
        ReaderContentLoader.feedEntryRealmConfiguration = configuration
    }

    @RealmBackgroundActor
    private func seed<T: Bookmark>(
        _ record: T,
        url: URL,
        title: String = "Original",
        in realm: Realm
    ) throws -> T {
        record.url = url
        record.title = title
        record.createdAt = Self.seedDate
        record.updateCompoundKey()
        try realm.write {
            realm.add(record)
            record.refreshChangeMetadata(explicitlyModified: true, at: Self.seedDate)
        }
        return record
    }

    private func state(
        _ content: any ReaderContentProtocol,
        in realm: Realm
    ) throws -> MutationState {
        let name = content.objectSchema.className + "." + content.compoundKey
        let journal = try XCTUnwrap(realm.object(
            ofType: BigSyncPendingMutation.self, forPrimaryKey: name
        ))
        XCTAssertFalse(journal.generation.isEmpty)
        XCTAssertEqual(journal.changedAt, content.modifiedAt)
        XCTAssertEqual(journal.changedAt, content.explicitlyModifiedAt)
        return MutationState(
            key: content.compoundKey, url: content.url, createdAt: content.createdAt,
            title: content.title, isDeleted: content.isDeleted,
            modifiedAt: content.modifiedAt, explicitlyModifiedAt: content.explicitlyModifiedAt,
            recordName: journal.recordName, entityType: journal.entityType,
            objectIdentifier: journal.objectIdentifier, generation: journal.generation,
            changedAt: journal.changedAt, accountScopeIdentifier: journal.accountScopeIdentifier,
            replicaBindingGenerationIdentifier: journal.replicaBindingGenerationIdentifier,
            requiresReplicaBindingRecovery: journal.requiresReplicaBindingRecovery
        )
    }

    private func waitForProvider(
        _ gate: LoaderMutationProviderGate,
        task: Task<Void, Error>,
        configuration: Realm.Configuration
    ) async throws {
        let arrived = expectation(description: "actual additional provider pauses discovery")
        let monitor = Task { if await gate.waitForArrival() { arrived.fulfill() } }
        let identifier = try XCTUnwrap(configuration.inMemoryIdentifier)
        addTeardownBlock {
            task.cancel()
            await gate.release()
            // Failure cleanup must not wait on a queued writer while this
            // fixture still holds the transaction that prevents its admission.
            await Self.cancelHeldFixtureWrite(owner: .shared, identifier: identifier)
            _ = await task.result
            await monitor.value
        }
        await fulfillment(of: [arrived], timeout: 2)
        guard await gate.hasArrived() else { throw FixtureError.providerDidNotArrive }
    }

    @RealmBackgroundActor
    func testEarlierMutationCannotAuthorizeRetiredLaterCandidate() async throws {
        for retirement in Retirement.allCases {
            // Physical removal is an accessor-lifetime control, not a user
            // deletion. Only its unique fixture opts these rows out of sync.
            let excluded = retirement == .physicalRemoval
                ? [Bookmark.className(), HistoryRecord.className()] : []
            let configuration = configuration(excludedClassNames: excluded)
            await install(configuration)
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            let url = URL(string: "https://example.com/later-candidate/\(UUID().uuidString)")!
            _ = try seed(Bookmark(), url: url, in: realm)
            _ = try seed(HistoryRecord(), url: url, in: realm)
            var callbacks = 0
            var retiredType: Bookmark.Type?
            var retiredKey: String?
            var retiredState: MutationState?

            try await ReaderContentLoader.updateContent(url: url) { current in
                callbacks += 1
                guard callbacks == 1 else {
                    XCTFail("Captured discovery must not authorize the retired candidate")
                    return false
                }
                XCTAssertTrue(realm.isInWriteTransaction)
                let otherType: Bookmark.Type = current is HistoryRecord ? Bookmark.self : HistoryRecord.self
                guard let other = realm.objects(otherType).first else {
                    XCTFail("The other representation must exist before the first mutation")
                    return false
                }
                retiredType = otherType
                retiredKey = other.compoundKey
                switch retirement {
                case .physicalRemoval:
                    realm.delete(other)
                case .tombstone:
                    other.isDeleted = true
                    other.refreshChangeMetadata(explicitlyModified: true)
                    retiredState = try? state(other, in: realm)
                case .retargeting:
                    other.url = URL(string: "https://example.com/retargeted/\(UUID().uuidString)")!
                    other.refreshChangeMetadata(explicitlyModified: true)
                    retiredState = try? state(other, in: realm)
                case .recreation:
                    let replacement: Bookmark = current is HistoryRecord ? Bookmark() : HistoryRecord()
                    replacement.url = url
                    replacement.title = "Replacement"
                    replacement.createdAt = Self.seedDate.addingTimeInterval(1)
                    replacement.updateCompoundKey()
                    XCTAssertEqual(replacement.compoundKey, other.compoundKey)
                    realm.delete(other)
                    realm.add(replacement)
                    replacement.refreshChangeMetadata(explicitlyModified: true)
                    retiredState = try? state(replacement, in: realm)
                }
                current.title = "Updated"
                return true
            }

            XCTAssertEqual(callbacks, 1)
            let type = try XCTUnwrap(retiredType)
            let key = try XCTUnwrap(retiredKey)
            if retirement == .physicalRemoval {
                XCTAssertNil(realm.object(ofType: type, forPrimaryKey: key))
            } else {
                let retired = try XCTUnwrap(realm.object(ofType: type, forPrimaryKey: key))
                XCTAssertEqual(try state(retired, in: realm), try XCTUnwrap(retiredState))
            }
            let updated = realm.objects(Bookmark.self).where { $0.title == "Updated" }.count
                + realm.objects(HistoryRecord.self).where { $0.title == "Updated" }.count
            XCTAssertEqual(updated, 1, "A current discovered row must still commit")
        }
    }

    @RealmBackgroundActor
    func testActualMutationsOwnTheirWriteAndNoOpPreservesFullJournal() async throws {
        let configuration = configuration()
        await install(configuration)
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        let url = URL(string: "https://example.com/no-op/\(UUID().uuidString)")!
        let record = try seed(Bookmark(), url: url, in: realm)
        let seeded = try state(record, in: realm)
        var callbacks = 0
        try await ReaderContentLoader.updateContent(url: url) { _ in
            XCTAssertTrue(realm.isInWriteTransaction)
            callbacks += 1
            return false
        }
        XCTAssertEqual(callbacks, 1)
        XCTAssertEqual(try state(record, in: realm), seeded)

        var mutationTime: Date?
        try await ReaderContentLoader.updateContent(url: url) { current in
            XCTAssertTrue(realm.isInWriteTransaction)
            current.title = "Edited"
            mutationTime = Date()
            return true
        }
        let changed = try state(record, in: realm)
        XCTAssertEqual(changed.title, "Edited")
        XCTAssertNotEqual(changed.generation, seeded.generation)
        XCTAssertGreaterThanOrEqual(changed.changedAt, try XCTUnwrap(mutationTime))
        try await ReaderContentLoader.updateContent(url: url) { _ in false }
        XCTAssertEqual(try state(record, in: realm), changed)
    }

    @RealmBackgroundActor
    func testMutationDiscoveryDoesNotReuseCompletedCacheFromAnotherStore() async throws {
        let first = configuration()
        let second = configuration()
        await install(first)
        let firstRealm = try await RealmBackgroundActor.shared.cachedRealm(for: first)
        let secondRealm = try await RealmBackgroundActor.shared.cachedRealm(for: second)
        let url = URL(string: "https://example.com/cache-store/\(UUID().uuidString)")!
        let old = try seed(Bookmark(), url: url, title: "Store A", in: firstRealm)
        let current = try seed(Bookmark(), url: url, title: "Store B", in: secondRealm)
        let oldState = try state(old, in: firstRealm)
        let currentState = try state(current, in: secondRealm)
        _ = try await ReaderContentLoader.loadAll(url: url)
        select(second)
        let cached = try await ReaderContentLoader.loadAll(url: url)
        XCTAssertEqual(cached.map(\.title), ["Store A"], "Establish the real completed-cache control")

        try await ReaderContentLoader.updateContent(url: url) { content in
            content.title = "Current mutation"
            return true
        }

        XCTAssertEqual(try state(old, in: firstRealm), oldState)
        XCTAssertEqual(current.title, "Current mutation")
        XCTAssertNotEqual(try state(current, in: secondRealm).generation, currentState.generation)
    }

    @RealmBackgroundActor
    func testProviderSuspensionKeepsCapturedStoresAndRegistrations() async throws {
        let first = configuration()
        let second = configuration()
        let providerStore = configuration()
        let replacementProviderStore = configuration()
        await install(first)
        let firstRealm = try await RealmBackgroundActor.shared.cachedRealm(for: first)
        let secondRealm = try await RealmBackgroundActor.shared.cachedRealm(for: second)
        let providerRealm = try await RealmBackgroundActor.shared.cachedRealm(for: providerStore)
        let replacementProviderRealm = try await RealmBackgroundActor.shared.cachedRealm(for: replacementProviderStore)
        let url = URL(string: "https://example.com/provider-owner/\(UUID().uuidString)")!
        let firstRow = try seed(Bookmark(), url: url, title: "Store A", in: firstRealm)
        let secondRow = try seed(Bookmark(), url: url, title: "Store B", in: secondRealm)
        let providerRow = try seed(Bookmark(), url: url, title: "Provider A", in: providerRealm)
        let replacementProviderRow = try seed(Bookmark(), url: url, title: "Provider B", in: replacementProviderRealm)
        let secondState = try state(secondRow, in: secondRealm)
        let replacementProviderState = try state(replacementProviderRow, in: replacementProviderRealm)
        let firstReference = try XCTUnwrap(ReaderContentLoader.ContentReference(content: providerRow))
        let replacementReference = try XCTUnwrap(ReaderContentLoader.ContentReference(content: replacementProviderRow))
        let gate = LoaderMutationProviderGate()
        ReaderContentLoader.additionalContentProviders = [.init(id: "captured") { _ in
            await gate.pause()
            return [firstReference]
        }]
        let task = Task { @RealmBackgroundActor in
            try await ReaderContentLoader.updateContent(url: url) { content in
                content.title = "Captured mutation"
                return true
            }
        }
        try await waitForProvider(gate, task: task, configuration: first)
        select(second)
        ReaderContentLoader.additionalContentProviders = [.init(id: "replacement") { _ in
            [replacementReference]
        }]
        await gate.release()
        try await task.value

        XCTAssertEqual(firstRow.title, "Captured mutation")
        XCTAssertEqual(providerRow.title, "Captured mutation")
        XCTAssertEqual(try state(secondRow, in: secondRealm), secondState)
        XCTAssertEqual(try state(replacementProviderRow, in: replacementProviderRealm), replacementProviderState)
    }

    @RealmBackgroundActor
    func testQueuedWriterResolvesTombstoneAndCancellationKeepsOtherOwnersWrite() async throws {
        for cancelQueuedWriter in [false, true] {
            let configuration = configuration()
            let identifier = try XCTUnwrap(configuration.inMemoryIdentifier)
            await install(configuration)
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            let url = URL(string: "https://example.com/queued-mutation/\(UUID().uuidString)")!
            let record = try seed(Bookmark(), url: url, in: realm)
            let gate = LoaderMutationProviderGate()
            ReaderContentLoader.additionalContentProviders = [.init(id: "write-boundary") { _ in
                await gate.pause()
                return []
            }]
            let submitted = expectation(description: "generic mutation queues its own SDK write ticket")
            let task = Task { @RealmBackgroundActor in
                try await RealmWriteSubmissionObservation.$willSubmit.withValue({ submitted.fulfill() }) {
                    try await ReaderContentLoader.updateContent(url: url) { _ in
                        XCTFail("A retired or cancelled queued mutation must not run")
                        return false
                    }
                }
            }
            try await waitForProvider(gate, task: task, configuration: configuration)
            try realm.beginWrite()
            await gate.release()
            await fulfillment(of: [submitted], timeout: 2)
            guard realm.isInWriteTransaction else { throw FixtureError.missingHeldTransaction }
            record.title = "Other owner's edit"
            if !cancelQueuedWriter { record.isDeleted = true }
            record.refreshChangeMetadata(explicitlyModified: true)
            let ownedState = try state(record, in: realm)

            if cancelQueuedWriter {
                task.cancel()
                let completed = expectation(description: "queued cancellation settles without releasing its peer")
                let completionMonitor = Task {
                    let result = await task.result
                    completed.fulfill()
                    return result
                }
                let waitResult = await XCTWaiter.fulfillment(of: [completed], timeout: 2)
                guard waitResult == .completed else {
                    XCTFail("Queued cancellation did not settle while the other owner's write was open")
                    await Self.cancelHeldFixtureWrite(
                        owner: .shared, identifier: identifier
                    )
                    _ = await task.result
                    _ = await completionMonitor.value
                    throw FixtureError.queuedCancellationDidNotSettle
                }
                let cancellationResult = await completionMonitor.value
                do {
                    try cancellationResult.get()
                    XCTFail("The queued task must report cancellation")
                } catch is CancellationError {}
                guard realm.isInWriteTransaction else {
                    XCTFail("The cancelled waiter must preserve the other owner's transaction")
                    throw FixtureError.missingHeldTransaction
                }
                XCTAssertEqual(try state(record, in: realm), ownedState)
                try realm.commitWrite()
            } else {
                try realm.commitWrite()
                try await task.value
            }
            XCTAssertFalse(realm.isInWriteTransaction)
            XCTAssertEqual(try state(record, in: realm), ownedState)
        }
    }

    @RealmBackgroundActor
    func testCancellationInsideMutationRollsBackItsFieldsAndJournal() async throws {
        let configuration = configuration()
        await install(configuration)
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        let url = URL(string: "https://example.com/cancel-mutation/\(UUID().uuidString)")!
        let record = try seed(Bookmark(), url: url, in: realm)
        let seeded = try state(record, in: realm)
        let task = Task { @RealmBackgroundActor in
            try await ReaderContentLoader.updateContent(url: url) { content in
                content.title = "Must roll back"
                withUnsafeCurrentTask { $0?.cancel() }
                return true
            }
        }
        do {
            try await task.value
            XCTFail("Cancellation in the mutator must reject its owned transaction")
        } catch is CancellationError {}
        XCTAssertEqual(try state(record, in: realm), seeded)
        XCTAssertFalse(realm.isInWriteTransaction)
    }
}
