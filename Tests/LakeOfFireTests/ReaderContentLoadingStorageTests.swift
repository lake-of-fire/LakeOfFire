import BigSyncKit
import XCTest
import RealmSwift
@testable import RealmSwiftGaps
@testable import LakeOfFireContent

private actor ReaderContentLoadingDiscoveryGate {
    private var arrivals = 0
    private var isReleased = false
    private var arrivalWaiters = [CheckedContinuation<Void, Never>]()
    private var releaseWaiters = [CheckedContinuation<Void, Never>]()

    func pause() async {
        arrivals += 1
        let waiters = arrivalWaiters
        arrivalWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !isReleased else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitForArrivals(_ expectedCount: Int) async -> Bool {
        while arrivals < expectedCount && !isReleased {
            await withCheckedContinuation { arrivalWaiters.append($0) }
        }
        return arrivals >= expectedCount
    }

    func releaseAll() {
        isReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
        let pendingArrivals = arrivalWaiters
        arrivalWaiters.removeAll()
        pendingArrivals.forEach { $0.resume() }
    }
}

final class ReaderContentLoadingStorageTests: XCTestCase {
    private func makeConfiguration() -> Realm.Configuration {
        var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        configuration.objectTypes = [
            Bookmark.self,
            ContentFile.self,
            HistoryRecord.self,
            FeedEntry.self,
        ]
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        return configuration
    }

    @RealmBackgroundActor
    private func assertUpdateSkipsContentRemovedByEarlierMutation(physicallyDelete: Bool) async throws {
        let configuration = makeConfiguration()
        let previousBookmark = ReaderContentLoader.bookmarkRealmConfiguration
        let previousHistory = ReaderContentLoader.historyRealmConfiguration
        let previousFeed = ReaderContentLoader.feedEntryRealmConfiguration
        defer {
            ReaderContentLoader.bookmarkRealmConfiguration = previousBookmark
            ReaderContentLoader.historyRealmConfiguration = previousHistory
            ReaderContentLoader.feedEntryRealmConfiguration = previousFeed
        }
        ReaderContentLoader.bookmarkRealmConfiguration = configuration
        ReaderContentLoader.historyRealmConfiguration = configuration
        ReaderContentLoader.feedEntryRealmConfiguration = configuration
        addTeardownBlock {
            _ = await RealmBackgroundActor.shared.removeCachedRealm(for: configuration)
        }
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        let url = URL(string: "https://example.com/update-lifetime/\(UUID().uuidString)")!
        try await realm.asyncWrite {
            let bookmark = Bookmark()
            bookmark.url = url
            bookmark.title = "Original"
            bookmark.updateCompoundKey()
            realm.add(bookmark)
            bookmark.refreshChangeMetadata(explicitlyModified: true)
            let history = HistoryRecord()
            history.url = url
            history.title = "Original"
            history.updateCompoundKey()
            realm.add(history)
            history.refreshChangeMetadata(explicitlyModified: true)
        }

        var mutationCount = 0
        var retiredType: Object.Type?
        var retiredKey: String?
        try await ReaderContentLoader.updateContent(url: url) { object in
            mutationCount += 1
            guard mutationCount == 1 else {
                XCTFail("A removed candidate must not receive a later mutation")
                return false
            }
            let otherType: Bookmark.Type = object is HistoryRecord ? Bookmark.self : HistoryRecord.self
            guard let other = realm.objects(otherType).first else {
                XCTFail("The other live representation must exist before the first mutation")
                return false
            }
            retiredType = otherType
            retiredKey = other.compoundKey
            if physicallyDelete {
                // Simulate acknowledged cleanup invalidating a discovered object.
                realm.delete(other)
            } else {
                other.isDeleted = true
                other.refreshChangeMetadata(explicitlyModified: true)
            }
            object.title = "Updated"
            return true
        }

        XCTAssertEqual(mutationCount, 1)
        let type = try XCTUnwrap(retiredType)
        let key = try XCTUnwrap(retiredKey)
        let retired = realm.object(ofType: type, forPrimaryKey: key) as? any ReaderContentProtocol
        if physicallyDelete {
            XCTAssertNil(retired)
        } else {
            XCTAssertTrue(try XCTUnwrap(retired).isDeleted)
            XCTAssertEqual(retired?.title, "Original")
        }
        let live = try await ReaderContentLoader.loadAll(url: url)
        XCTAssertEqual(live.count, 1)
        XCTAssertEqual(live.first?.title, "Updated")
    }

    @RealmBackgroundActor
    func testUpdateContentSkipsRepresentationSoftDeletedByAnEarlierMutation() async throws {
        try await assertUpdateSkipsContentRemovedByEarlierMutation(physicallyDelete: false)
    }

    @RealmBackgroundActor
    func testUpdateContentResolvesReferencesAfterAnEarlierMutationPhysicallyDeletesACandidate() async throws {
        try await assertUpdateSkipsContentRemovedByEarlierMutation(physicallyDelete: true)
    }

    @MainActor
    func testOverlappingSameURLLoadsKeepTheirCapturedStorageAfterConfigurationReplacement() async throws {
        let firstConfiguration = makeConfiguration()
        let secondConfiguration = makeConfiguration()
        let previousBookmark = ReaderContentLoader.bookmarkRealmConfiguration
        let previousHistory = ReaderContentLoader.historyRealmConfiguration
        let previousFeed = ReaderContentLoader.feedEntryRealmConfiguration
        defer {
            ReaderContentLoader.bookmarkRealmConfiguration = previousBookmark
            ReaderContentLoader.historyRealmConfiguration = previousHistory
            ReaderContentLoader.feedEntryRealmConfiguration = previousFeed
        }

        ReaderContentLoader.bookmarkRealmConfiguration = firstConfiguration
        ReaderContentLoader.historyRealmConfiguration = firstConfiguration
        ReaderContentLoader.feedEntryRealmConfiguration = firstConfiguration
        await ReaderContentLoader.resetTransientCachesForTesting()

        let gate = ReaderContentLoadingDiscoveryGate()
        await { @RealmBackgroundActor in
            ReaderContentLoader.loadAllDiscoveryGateForTesting = {
                await gate.pause()
            }
        }()

        let url = URL(string: "https://example.com/storage-routing/\(UUID().uuidString)")!
        let firstTask = Task { @MainActor in
            try await ReaderContentLoader.getContent(forURL: url)
        }

        let firstEntered = expectation(description: "first storage discovery entered")
        let firstArrivalTask = Task { @MainActor in
            let arrived = await gate.waitForArrivals(1)
            firstEntered.fulfill()
            return arrived
        }
        addTeardownBlock {
            await gate.releaseAll()
            _ = await firstTask.result
            _ = await firstArrivalTask.result
            await ReaderContentLoader.resetTransientCachesForTesting()
            _ = await RealmBackgroundActor.shared.removeCachedRealm(for: firstConfiguration)
            _ = await RealmBackgroundActor.shared.removeCachedRealm(for: secondConfiguration)
        }
        await fulfillment(of: [firstEntered], timeout: 1)

        ReaderContentLoader.bookmarkRealmConfiguration = secondConfiguration
        ReaderContentLoader.historyRealmConfiguration = secondConfiguration
        ReaderContentLoader.feedEntryRealmConfiguration = secondConfiguration
        let secondTask = Task { @MainActor in
            try await ReaderContentLoader.getContent(forURL: url)
        }

        let bothEntered = expectation(description: "independent storage discoveries entered")
        let bothArrivalTask = Task { @MainActor in
            let arrived = await gate.waitForArrivals(2)
            bothEntered.fulfill()
            return arrived
        }
        addTeardownBlock {
            await gate.releaseAll()
            _ = await secondTask.result
            _ = await bothArrivalTask.result
        }
        await fulfillment(of: [bothEntered], timeout: 1)
        await gate.releaseAll()
        let firstArrived = await firstArrivalTask.value
        let bothArrived = await bothArrivalTask.value
        XCTAssertTrue(firstArrived)
        XCTAssertTrue(bothArrived)

        let firstResult = try await firstTask.value
        let secondResult = try await secondTask.value
        let first = try XCTUnwrap(firstResult)
        let second = try XCTUnwrap(secondResult)
        XCTAssertEqual(first.realm?.configuration.inMemoryIdentifier, firstConfiguration.inMemoryIdentifier)
        XCTAssertEqual(second.realm?.configuration.inMemoryIdentifier, secondConfiguration.inMemoryIdentifier)

        let firstRealm = try await Realm(configuration: firstConfiguration, actor: MainActor.shared)
        let secondRealm = try await Realm(configuration: secondConfiguration, actor: MainActor.shared)
        await firstRealm.asyncRefresh()
        await secondRealm.asyncRefresh()
        XCTAssertEqual(firstRealm.objects(HistoryRecord.self).count, 1)
        XCTAssertEqual(secondRealm.objects(HistoryRecord.self).count, 1)
    }

    @MainActor
    func testExplicitHTMLReimportRevivesSameKey() async throws {
        let configuration = makeConfiguration()
        let previousBookmark = ReaderContentLoader.bookmarkRealmConfiguration
        let previousHistory = ReaderContentLoader.historyRealmConfiguration
        let previousFeed = ReaderContentLoader.feedEntryRealmConfiguration
        defer {
            ReaderContentLoader.bookmarkRealmConfiguration = previousBookmark
            ReaderContentLoader.historyRealmConfiguration = previousHistory
            ReaderContentLoader.feedEntryRealmConfiguration = previousFeed
        }
        ReaderContentLoader.bookmarkRealmConfiguration = configuration
        ReaderContentLoader.historyRealmConfiguration = configuration
        ReaderContentLoader.feedEntryRealmConfiguration = configuration
        addTeardownBlock {
            _ = await RealmBackgroundActor.shared.removeCachedRealm(for: configuration)
        }

        let html = ReaderContentLoader.snippetHTML(fromRawText: "Snippet reimport \(UUID().uuidString)")
        let first = try await ReaderContentLoader.load(html: html)
        let sourceKey = try XCTUnwrap(first?.compoundKey)
        try await { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            try await realm.asyncWrite {
                let source = try XCTUnwrap(realm.object(ofType: HistoryRecord.self, forPrimaryKey: sourceKey))
                source.isDeleted = true
                source.refreshChangeMetadata(explicitlyModified: true)
            }
        }()

        let reimported = try await ReaderContentLoader.load(html: html)
        let revived = try XCTUnwrap(reimported as? HistoryRecord)
        XCTAssertEqual(revived.compoundKey, sourceKey)
        XCTAssertFalse(revived.isDeleted)
    }

    @RealmBackgroundActor
    private func withPausedWrite(
        _ operation: ReaderContentLoader.ContentWriteOperation,
        action: @escaping @RealmBackgroundActor () async throws -> Void,
        mutation: @RealmBackgroundActor () async throws -> Void
    ) async throws {
        let gate = ReaderContentLoadingDiscoveryGate()
        ReaderContentLoader.contentWriteGateForTesting = { current in
            if current == operation { await gate.pause() }
        }
        defer { ReaderContentLoader.contentWriteGateForTesting = nil }
        let task = Task { @RealmBackgroundActor in try await action() }
        let entered = expectation(description: "writer captured identity before suspension")
        let arrival = Task {
            _ = await gate.waitForArrivals(1)
            entered.fulfill()
        }
        await fulfillment(of: [entered], timeout: 2)
        do {
            try await mutation()
        } catch {
            await gate.releaseAll()
            _ = await task.result
            await arrival.value
            throw error
        }
        await gate.releaseAll()
        await arrival.value
        try await task.value
    }

    @RealmBackgroundActor
    private func seededHistory(in configuration: Realm.Configuration) async throws -> ReaderContentLoader.ContentReference {
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        return try await realm.asyncWrite {
            let record = HistoryRecord()
            record.url = ReaderContentLoader.snippetURL(key: UUID().uuidString)!
            record.title = "Original"
            record.updateCompoundKey()
            realm.add(record)
            record.refreshChangeMetadata(explicitlyModified: true)
            return ReaderContentLoader.ContentReference(content: record)!
        }
    }

    @RealmBackgroundActor
    private func assertRemovedSourceCannotCreateHistory(physicallyDelete: Bool) async throws {
        let configuration = makeConfiguration()
        addTeardownBlock { _ = await RealmBackgroundActor.shared.removeCachedRealm(for: configuration) }
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        let url = URL(string: "https://example.com/removed-history-source/\(UUID().uuidString)")!
        let key = try await realm.asyncWrite {
            let bookmark = Bookmark()
            bookmark.url = url
            bookmark.title = "Source"
            bookmark.updateCompoundKey()
            realm.add(bookmark)
            bookmark.refreshChangeMetadata(explicitlyModified: true)
            return bookmark.compoundKey
        }
        try await withPausedWrite(.historyCreation, action: {
            let source = try XCTUnwrap(realm.object(ofType: Bookmark.self, forPrimaryKey: key))
            do {
                _ = try await source.addHistoryRecord(realmConfiguration: configuration, pageURL: url,
                    bookmarkRealmConfiguration: configuration)
                XCTFail("A source removed while admission waits must not create or revive history")
            } catch is CancellationError {
                // Deletion supersedes the admitted source copy.
            }
        }, mutation: {
            try await realm.asyncWrite {
                let source = try XCTUnwrap(realm.object(ofType: Bookmark.self, forPrimaryKey: key))
                if physicallyDelete {
                    realm.delete(source)
                } else {
                    source.isDeleted = true
                    source.refreshChangeMetadata(explicitlyModified: true)
                }
            }
        })
        XCTAssertTrue(realm.objects(HistoryRecord.self).isEmpty)
    }

    @RealmBackgroundActor
    func testHistoryCreationSkipsSourceSoftDeletedWhileAdmissionWaits() async throws {
        try await assertRemovedSourceCannotCreateHistory(physicallyDelete: false)
    }

    @RealmBackgroundActor
    func testHistoryCreationSkipsSourcePhysicallyDeletedWhileAdmissionWaits() async throws {
        try await assertRemovedSourceCannotCreateHistory(physicallyDelete: true)
    }

    @RealmBackgroundActor
    func testHistoryVisitUsesDetachedSourceMetadataAndCapturedHistoryStore() async throws {
        let sourceConfiguration = makeConfiguration()
        let historyConfiguration = makeConfiguration()
        addTeardownBlock {
            _ = await RealmBackgroundActor.shared.removeCachedRealm(for: sourceConfiguration)
            _ = await RealmBackgroundActor.shared.removeCachedRealm(for: historyConfiguration)
        }
        let sourceRealm = try await RealmBackgroundActor.shared.cachedRealm(for: sourceConfiguration)
        let historyRealm = try await RealmBackgroundActor.shared.cachedRealm(for: historyConfiguration)
        let url = URL(string: "https://example.com/history-snapshot/\(UUID().uuidString)")!
        let key = try await sourceRealm.asyncWrite {
            let source = Bookmark()
            source.url = url
            source.title = "Admitted title"
            source.rssContainsFullContent = true
            source.content = Data("Admitted body".utf8)
            source.voiceAudioURLs.append(URL(string: "https://example.com/audio.mp3")!)
            source.updateCompoundKey()
            sourceRealm.add(source)
            source.refreshChangeMetadata(explicitlyModified: true)
            return source.compoundKey
        }
        try await withPausedWrite(.historyCreation, action: {
            let source = try XCTUnwrap(sourceRealm.object(ofType: Bookmark.self, forPrimaryKey: key))
            let record = try await source.addHistoryRecord(realmConfiguration: historyConfiguration,
                pageURL: url, bookmarkRealmConfiguration: sourceConfiguration)
            XCTAssertEqual(record.title, "Admitted title")
            XCTAssertEqual(record.content, Data("Admitted body".utf8))
            XCTAssertEqual(Array(record.voiceAudioURLs), [URL(string: "https://example.com/audio.mp3")!])
            XCTAssertEqual(record.bookmarkID, key)
            XCTAssertEqual(record.realm?.configuration.inMemoryIdentifier, historyConfiguration.inMemoryIdentifier)
        }, mutation: {
            try await sourceRealm.asyncWrite {
                let source = try XCTUnwrap(sourceRealm.object(ofType: Bookmark.self, forPrimaryKey: key))
                source.title = "Later source title"
                source.content = Data("Later body".utf8)
                source.voiceAudioURLs.removeAll()
                source.refreshChangeMetadata(explicitlyModified: true)
            }
        })
        XCTAssertEqual(sourceRealm.objects(HistoryRecord.self).count, 0)
        XCTAssertEqual(historyRealm.objects(HistoryRecord.self).count, 1)
    }

    @RealmBackgroundActor
    private func assertDelayedUpdateSkipsRemovedHistory(
        clipboard: Bool,
        physicallyDelete: Bool
    ) async throws {
        let configuration = makeConfiguration()
        addTeardownBlock { _ = await RealmBackgroundActor.shared.removeCachedRealm(for: configuration) }
        let reference = try await seededHistory(in: configuration)
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        try await withPausedWrite(clipboard ? .clipboard : .loadedContent, action: {
            let updated: ReaderContentLoader.ContentReference?
            if clipboard {
                updated = try await ReaderContentLoader.markSnippetFromClipboard(reference)
            } else {
                updated = try await ReaderContentLoader.finishLoadedContent(reference,
                    countsAsHistoryVisit: false, readerModeRequired: true)
            }
            XCTAssertNil(updated)
        }, mutation: {
            try await realm.asyncWrite {
                let record = try XCTUnwrap(realm.object(ofType: HistoryRecord.self, forPrimaryKey: reference.contentKey))
                if physicallyDelete {
                    realm.delete(record)
                } else {
                    record.isDeleted = true
                    record.refreshChangeMetadata(explicitlyModified: true)
                }
            }
        })
        let remaining = realm.object(ofType: HistoryRecord.self, forPrimaryKey: reference.contentKey)
        if physicallyDelete {
            XCTAssertNil(remaining)
        } else {
            XCTAssertTrue(try XCTUnwrap(remaining).isDeleted)
            XCTAssertFalse(try XCTUnwrap(remaining).isReaderModeByDefault)
            XCTAssertFalse(try XCTUnwrap(remaining).isFromClipboard)
        }
    }

    @RealmBackgroundActor
    func testBackgroundReaderModeUpdateSkipsSoftDeletedHistory() async throws {
        try await assertDelayedUpdateSkipsRemovedHistory(clipboard: false, physicallyDelete: false)
    }

    @RealmBackgroundActor
    func testReaderModeUpdateSkipsPhysicallyDeletedHistory() async throws {
        try await assertDelayedUpdateSkipsRemovedHistory(clipboard: false, physicallyDelete: true)
    }

    @RealmBackgroundActor
    func testClipboardFollowupSkipsSoftDeletedSnippet() async throws {
        try await assertDelayedUpdateSkipsRemovedHistory(clipboard: true, physicallyDelete: false)
    }

    @RealmBackgroundActor
    func testClipboardFollowupSkipsPhysicallyDeletedSnippet() async throws {
        try await assertDelayedUpdateSkipsRemovedHistory(clipboard: true, physicallyDelete: true)
    }

    @RealmBackgroundActor
    func testExplicitHistoryVisitRevivesTombstoneWithSameIdentity() async throws {
        let configuration = makeConfiguration()
        addTeardownBlock { _ = await RealmBackgroundActor.shared.removeCachedRealm(for: configuration) }
        let reference = try await seededHistory(in: configuration)
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        try await withPausedWrite(.loadedContent, action: {
            let updated = try await ReaderContentLoader.finishLoadedContent(reference,
                countsAsHistoryVisit: true, readerModeRequired: false)
            XCTAssertEqual(updated?.contentKey, reference.contentKey)
        }, mutation: {
            try await realm.asyncWrite {
                let record = try XCTUnwrap(realm.object(ofType: HistoryRecord.self, forPrimaryKey: reference.contentKey))
                record.isDeleted = true
                record.lastVisitedAt = .distantPast
                record.refreshChangeMetadata(explicitlyModified: true)
            }
        })
        let record = try XCTUnwrap(realm.object(ofType: HistoryRecord.self, forPrimaryKey: reference.contentKey))
        XCTAssertFalse(record.isDeleted)
        XCTAssertGreaterThan(record.lastVisitedAt, .distantPast)
        XCTAssertEqual(realm.objects(HistoryRecord.self).count, 1)
    }

    @RealmBackgroundActor
    func testDemotionReadsLatestMetadataAfterSuspension() async throws {
        let configuration = makeConfiguration()
        addTeardownBlock { _ = await RealmBackgroundActor.shared.removeCachedRealm(for: configuration) }
        let reference = try await seededHistory(in: configuration)
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        try await withPausedWrite(.demotion, action: {
            let record = try XCTUnwrap(realm.object(ofType: HistoryRecord.self, forPrimaryKey: reference.contentKey))
            try await record.refreshDemotedStatus(bookmarkRealmConfiguration: configuration)
        }, mutation: {
            try await realm.asyncWrite {
                let record = try XCTUnwrap(realm.object(ofType: HistoryRecord.self, forPrimaryKey: reference.contentKey))
                record.isReaderModeAvailable = true
                record.refreshChangeMetadata(explicitlyModified: true)
            }
        })
        XCTAssertEqual(realm.object(ofType: HistoryRecord.self, forPrimaryKey: reference.contentKey)?.isDemoted, false)
    }

    @RealmBackgroundActor
    func testDemotionSkipsHistoryPhysicallyDeletedDuringSuspension() async throws {
        let configuration = makeConfiguration()
        addTeardownBlock { _ = await RealmBackgroundActor.shared.removeCachedRealm(for: configuration) }
        let reference = try await seededHistory(in: configuration)
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        try await withPausedWrite(.demotion, action: {
            let record = try XCTUnwrap(realm.object(ofType: HistoryRecord.self, forPrimaryKey: reference.contentKey))
            try await record.refreshDemotedStatus(bookmarkRealmConfiguration: configuration)
        }, mutation: {
            try await realm.asyncWrite {
                let record = try XCTUnwrap(realm.object(ofType: HistoryRecord.self, forPrimaryKey: reference.contentKey))
                realm.delete(record)
            }
        })
        XCTAssertNil(realm.object(ofType: HistoryRecord.self, forPrimaryKey: reference.contentKey))
    }

    @RealmBackgroundActor
    func testCancelledQueuedReaderWriterDoesNotRollbackAnExistingTransaction() async throws {
        let configuration = makeConfiguration()
        addTeardownBlock { _ = await RealmBackgroundActor.shared.removeCachedRealm(for: configuration) }
        let reference = try await seededHistory(in: configuration)
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        let submitted = expectation(description: "reader write SDK ticket submitted")
        try realm.beginWrite()
        defer { if realm.isInWriteTransaction { realm.cancelWrite() } }
        let record = try XCTUnwrap(realm.object(ofType: HistoryRecord.self, forPrimaryKey: reference.contentKey))
        record.title = "Open transaction must survive cancellation"
        let waiter = Task { @RealmBackgroundActor in
            try await RealmWriteSubmissionObservation.$willSubmit.withValue({ submitted.fulfill() }) {
                try await ReaderContentLoader.finishLoadedContent(reference,
                    countsAsHistoryVisit: true, readerModeRequired: true)
            }
        }
        await fulfillment(of: [submitted], timeout: 2)
        waiter.cancel()
        do {
            _ = try await waiter.value
            XCTFail("The queued cancelled reader write must fail before admission")
        } catch is CancellationError { }
        XCTAssertTrue(realm.isInWriteTransaction)
        XCTAssertEqual(record.title, "Open transaction must survive cancellation")
        XCTAssertFalse(record.isReaderModeByDefault)
        record.refreshChangeMetadata(explicitlyModified: true)
        try realm.commitWrite()
        XCTAssertEqual(realm.object(ofType: HistoryRecord.self, forPrimaryKey: reference.contentKey)?.title,
            "Open transaction must survive cancellation")
    }

    @RealmBackgroundActor
    func testOwnedReaderWriteCancellationAfterCommitSubmissionReturnsCommittedResult() async throws {
        let configuration = makeConfiguration()
        addTeardownBlock { _ = await RealmBackgroundActor.shared.removeCachedRealm(for: configuration) }
        let reference = try await seededHistory(in: configuration)
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        let task = Task { @RealmBackgroundActor in
            try await RealmWriteCommitObservation.$didSubmit.withValue({
                withUnsafeCurrentTask { $0?.cancel() }
            }) {
                try await realm.asyncWritePreservingOwnership {
                    let record = try XCTUnwrap(realm.object(ofType: HistoryRecord.self, forPrimaryKey: reference.contentKey))
                    record.title = "Durable reader mutation"
                    record.refreshChangeMetadata(explicitlyModified: true)
                    return record.compoundKey
                }
            }
        }
        let committedKey = try await task.value
        XCTAssertEqual(committedKey, reference.contentKey)
        XCTAssertEqual(realm.object(ofType: HistoryRecord.self, forPrimaryKey: committedKey)?.title, "Durable reader mutation")
    }
}
