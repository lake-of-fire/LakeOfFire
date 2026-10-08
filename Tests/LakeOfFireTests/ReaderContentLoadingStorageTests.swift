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

    func arrivalCount() -> Int { arrivals }

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
    private let storageObjectTypes: [Object.Type] = [
        Bookmark.self, ContentFile.self, HistoryRecord.self, FeedEntry.self,
    ]

    private func makeConfiguration(objectTypes: [Object.Type]? = nil) -> Realm.Configuration {
        var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        configuration.objectTypes = objectTypes ?? storageObjectTypes
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
            try assertPendingMutation(for: bookmark, in: realm)
            try assertPendingMutation(for: history, in: realm)
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
        let firstHistory = try XCTUnwrap(first as? HistoryRecord)
        try assertPendingMutation(for: firstHistory, in: try XCTUnwrap(firstHistory.realm))
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
        try assertPendingMutation(for: revived, in: try XCTUnwrap(revived.realm))
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
            try assertPendingMutation(for: record, in: realm)
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
            try assertPendingMutation(for: bookmark, in: bookmark.realm!)
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
            try assertPendingMutation(for: source, in: source.realm!)
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
            try self.assertPendingMutation(for: record, in: historyRealm)
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
        try assertPendingMutation(for: record, in: realm)
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
    func testURLImportFindsContentFileInHistoryRealmWithSeparateSchemas() async throws {
        var bookmarks = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        bookmarks.objectTypes = [Bookmark.self]
        configureLakeOfFireMutationTrackingForTesting(&bookmarks)
        var history = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        history.objectTypes = [HistoryRecord.self, ContentFile.self]
        configureLakeOfFireMutationTrackingForTesting(&history)
        var feeds = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        feeds.objectTypes = [FeedEntry.self]
        configureLakeOfFireMutationTrackingForTesting(&feeds)
        addTeardownBlock {
            _ = await RealmBackgroundActor.shared.removeCachedRealm(for: bookmarks)
            _ = await RealmBackgroundActor.shared.removeCachedRealm(for: history)
            _ = await RealmBackgroundActor.shared.removeCachedRealm(for: feeds)
        }
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: history)
        let url = URL(string: "https://example.com/imported-file/\(UUID().uuidString)")!
        try await realm.asyncWrite {
            let file = ContentFile()
            file.url = url
            file.title = "File metadata from History storage"
            file.rssContainsFullContent = true
            file.content = Data("Stored file body".utf8)
            file.updateCompoundKey()
            realm.add(file)
            file.refreshChangeMetadata(explicitlyModified: true)
            try assertPendingMutation(for: file, in: realm)
        }
        let storage = ReaderContentLoader.ImportStorage(bookmarks: bookmarks, history: history, feeds: feeds)
        let result = try await ReaderContentLoader.importContent(.url(url), storage: storage, permitsCommit: { true })
        let reference = try XCTUnwrap(result)
        let record = try XCTUnwrap(realm.object(ofType: HistoryRecord.self, forPrimaryKey: reference.contentKey))
        try assertPendingMutation(for: record, in: realm)
        XCTAssertEqual(record.title, "File metadata from History storage")
        XCTAssertEqual(record.content, Data("Stored file body".utf8))
        XCTAssertEqual(reference.realmConfiguration.inMemoryIdentifier, history.inMemoryIdentifier)
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
    func testReaderImportCancellationAfterCommitSubmissionStillReturnsDurableIdentity() async throws {
        let configuration = makeConfiguration()
        addTeardownBlock { _ = await RealmBackgroundActor.shared.removeCachedRealm(for: configuration) }
        let storage = ReaderContentLoader.ImportStorage(bookmarks: configuration,
            history: configuration, feeds: configuration)
        let task = Task { @RealmBackgroundActor in
            try await RealmWriteCommitObservation.$didSubmit.withValue({
                withUnsafeCurrentTask { $0?.cancel() }
            }) {
                try await ReaderContentLoader.importContent(.html("<p>Durable import</p>", fromClipboard: false),
                    storage: storage, permitsCommit: { true })
            }
        }
        let reference = try await task.value
        let admitted = try XCTUnwrap(reference)
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        let record = try XCTUnwrap(realm.object(ofType: HistoryRecord.self, forPrimaryKey: admitted.contentKey))
        XCTAssertFalse(record.isDeleted)
        try assertPendingMutation(for: record, in: realm)
        XCTAssertEqual(record.title, "Durable import")
        XCTAssertEqual(realm.objects(HistoryRecord.self).count, 1)
    }


    private func diskConfiguration() throws -> Realm.Configuration {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("reader-storage-admission-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Install only after the final file route exists. Registering an
        // in-memory policy first does not register this file's journal.
        var configuration = Realm.Configuration(fileURL: directory.appendingPathComponent("current.realm"))
        configuration.objectTypes = storageObjectTypes
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        // Retain fixtures in their unique directory for diagnosis; no shared paths.
        addTeardownBlock { _ = await RealmBackgroundActor.shared.removeCachedRealm(for: configuration) }
        return configuration
    }

    @RealmBackgroundActor
    private func replaceFileWithCopy(_ configuration: Realm.Configuration) throws -> Data {
        let realm = try Realm(configuration: configuration)
        let current = try XCTUnwrap(configuration.fileURL)
        let directory = current.deletingLastPathComponent()
        let replacement = directory.appendingPathComponent("replacement-\(UUID().uuidString).realm")
        try realm.writeCopy(toFile: replacement)
        let bytes = try Data(contentsOf: replacement)
        try FileManager.default.moveItem(at: current,
            to: directory.appendingPathComponent("retired-\(UUID().uuidString).realm"))
        try FileManager.default.moveItem(at: replacement, to: current)
        return bytes
    }

    private func assertFileReplacementRejected<T>(_ action: () async throws -> T) async {
        do {
            _ = try await action()
            XCTFail("Captured work must reject a replacement file")
        } catch RealmBackgroundActorError.realmFileChangedDuringOpen {
            // Expected incarnation mismatch, not a generic open failure.
        } catch {
            XCTFail("Unexpected rejection: \(error)")
        }
    }

    @MainActor
    func testSamePathReplacementBeforeDiscoveryOpenRejectsWithoutWritingReplacement() async throws {
        let configuration = try diskConfiguration()
        let reference = try await seededHistory(in: configuration)
        let oldBookmark = ReaderContentLoader.bookmarkRealmConfiguration
        let oldHistory = ReaderContentLoader.historyRealmConfiguration
        let oldFeed = ReaderContentLoader.feedEntryRealmConfiguration
        defer {
            ReaderContentLoader.bookmarkRealmConfiguration = oldBookmark
            ReaderContentLoader.historyRealmConfiguration = oldHistory
            ReaderContentLoader.feedEntryRealmConfiguration = oldFeed
        }
        ReaderContentLoader.bookmarkRealmConfiguration = configuration
        ReaderContentLoader.historyRealmConfiguration = configuration
        ReaderContentLoader.feedEntryRealmConfiguration = configuration
        let gate = ReaderContentLoadingDiscoveryGate()
        await { @RealmBackgroundActor in
            ReaderContentLoader.loadAllDiscoveryGateForTesting = { await gate.pause() }
        }()
        let task = Task { @MainActor in
            try await ReaderContentLoader.load(url: URL(string: "https://example.com/replaced-discovery")!, countsAsHistoryVisit: true)
        }
        addTeardownBlock {
            await gate.releaseAll()
            _ = await task.result
            await ReaderContentLoader.resetTransientCachesForTesting()
        }
        let entered = expectation(description: "discovery captured admission")
        let arrival = Task { _ = await gate.waitForArrivals(1); entered.fulfill() }
        await fulfillment(of: [entered], timeout: 2)
        let replacementBytes = try await replaceFileWithCopy(configuration)
        await gate.releaseAll()
        await arrival.value
        await assertFileReplacementRejected { try await task.value }
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(configuration.fileURL)), replacementBytes)
        await assertFileReplacementRejected { try await reference.resolveOnMainActor() }
    }

    @RealmBackgroundActor
    func testSamePathReplacementBeforeBackgroundReferenceResolutionRejects() async throws {
        let configuration = try diskConfiguration()
        let reference = try await seededHistory(in: configuration)
        let bytes = try replaceFileWithCopy(configuration)
        await assertFileReplacementRejected { try await reference.resolveOnBackgroundActor() }
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(configuration.fileURL)), bytes)
    }

    @MainActor
    func testSamePathReplacementBeforeMainReferenceResolutionRejects() async throws {
        let configuration = try diskConfiguration()
        let reference = try await seededHistory(in: configuration)
        let bytes = try await replaceFileWithCopy(configuration)
        await assertFileReplacementRejected { try await reference.resolveOnMainActor() }
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(configuration.fileURL)), bytes)
    }

    @RealmBackgroundActor
    private func assertReplacementBeforeFinalWrite(_ operation: ReaderContentLoader.ContentWriteOperation) async throws {
        let configuration = try diskConfiguration()
        let reference = try await seededHistory(in: configuration)
        var replacementBytes: Data?
        try await withPausedWrite(operation, action: {
            await self.assertFileReplacementRejected {
                if operation == .clipboard {
                    return try await ReaderContentLoader.markSnippetFromClipboard(reference)
                }
                return try await ReaderContentLoader.finishLoadedContent(reference,
                    countsAsHistoryVisit: true, readerModeRequired: true)
            }
        }, mutation: {
            replacementBytes = try self.replaceFileWithCopy(configuration)
        })
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(configuration.fileURL)), try XCTUnwrap(replacementBytes))
        // Inspect the actor's original row too: rejection must roll back its writer.
        let cachedOldRealm = await RealmBackgroundActor.shared.getCachedRealm(key: reference.storageAdmission.scopeIdentity)
        let oldRealm = try XCTUnwrap(cachedOldRealm)
        let oldRecord = try XCTUnwrap(oldRealm.object(ofType: HistoryRecord.self, forPrimaryKey: reference.contentKey))
        XCTAssertFalse(oldRecord.isReaderModeByDefault)
        XCTAssertFalse(oldRecord.isFromClipboard)
    }

    @RealmBackgroundActor
    func testSamePathReplacementBeforeLoadedContentFinalWriteRejects() async throws {
        try await assertReplacementBeforeFinalWrite(.loadedContent)
    }

    @RealmBackgroundActor
    func testSamePathReplacementBeforeClipboardFinalWriteRejects() async throws {
        try await assertReplacementBeforeFinalWrite(.clipboard)
    }

    @MainActor
    func testOwnedFirstCreationSharesAdmissionAcrossDiscoveryRoutesAndReferenceResolution() async throws {
        let configuration = try diskConfiguration()
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(configuration.fileURL).path))
        let oldBookmark = ReaderContentLoader.bookmarkRealmConfiguration
        let oldHistory = ReaderContentLoader.historyRealmConfiguration
        let oldFeed = ReaderContentLoader.feedEntryRealmConfiguration
        defer {
            ReaderContentLoader.bookmarkRealmConfiguration = oldBookmark
            ReaderContentLoader.historyRealmConfiguration = oldHistory
            ReaderContentLoader.feedEntryRealmConfiguration = oldFeed
        }
        ReaderContentLoader.bookmarkRealmConfiguration = configuration
        ReaderContentLoader.historyRealmConfiguration = configuration
        ReaderContentLoader.feedEntryRealmConfiguration = configuration
        let loaded = try await ReaderContentLoader.load(url: URL(string: "https://example.com/owned-creation")!, countsAsHistoryVisit: true)
        let content = try XCTUnwrap(loaded)
        let reference = try XCTUnwrap(ReaderContentLoader.ContentReference(content: content))
        let resolved = try await reference.resolveOnMainActor()
        XCTAssertEqual(resolved?.compoundKey, content.compoundKey)
        XCTAssertEqual(content.realm?.objects(HistoryRecord.self).count, 1)
        try assertPendingMutation(for: try XCTUnwrap(content as? HistoryRecord), in: try XCTUnwrap(content.realm))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(configuration.fileURL).path))
    }

    @MainActor
    func testPasteboardExplicitConfigurationsRouteURLAndHTMLAwayFromGlobals() async throws {
        let global = makeConfiguration()
        let explicit = makeConfiguration()
        let oldBookmark = ReaderContentLoader.bookmarkRealmConfiguration
        let oldHistory = ReaderContentLoader.historyRealmConfiguration
        let oldFeed = ReaderContentLoader.feedEntryRealmConfiguration
        defer {
            ReaderContentLoader.bookmarkRealmConfiguration = oldBookmark
            ReaderContentLoader.historyRealmConfiguration = oldHistory
            ReaderContentLoader.feedEntryRealmConfiguration = oldFeed
        }
        ReaderContentLoader.bookmarkRealmConfiguration = global
        ReaderContentLoader.historyRealmConfiguration = global
        ReaderContentLoader.feedEntryRealmConfiguration = global
        addTeardownBlock {
            _ = await RealmBackgroundActor.shared.removeCachedRealm(for: global)
            _ = await RealmBackgroundActor.shared.removeCachedRealm(for: explicit)
        }
        let inputs: [(html: String?, text: String?)] = [
            (nil, "https://example.com/explicit-pasteboard"),
            ("<p>Explicit pasted body</p>", nil)
        ]
        for strings in inputs {
            let loaded = try await ReaderContentLoader.$pasteboardStringsForTesting.withValue(strings) {
                try await ReaderContentLoader.loadPasteboard(bookmarkRealmConfiguration: explicit,
                    historyRealmConfiguration: explicit, feedEntryRealmConfiguration: explicit)
            }
            let content = try XCTUnwrap(loaded)
            XCTAssertEqual(content.realm?.configuration.inMemoryIdentifier, explicit.inMemoryIdentifier)
            if strings.html != nil { XCTAssertTrue(content.isFromClipboard) }
        }
        let globalRealm = try await Realm(configuration: global, actor: MainActor.shared)
        let explicitRealm = try await Realm(configuration: explicit, actor: MainActor.shared)
        await globalRealm.asyncRefresh()
        await explicitRealm.asyncRefresh()
        XCTAssertTrue(globalRealm.objects(HistoryRecord.self).isEmpty)
        XCTAssertEqual(explicitRealm.objects(HistoryRecord.self).count, 2)
    }

    @RealmBackgroundActor
    func testSamePathReplacementBeforeDemotionFinalWriteRejects() async throws {
        let configuration = try diskConfiguration()
        let reference = try await seededHistory(in: configuration)
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        var replacementBytes: Data?
        try await withPausedWrite(.demotion, action: {
            let record = try XCTUnwrap(realm.object(ofType: HistoryRecord.self, forPrimaryKey: reference.contentKey))
            await self.assertFileReplacementRejected {
                try await record.refreshDemotedStatus(bookmarkRealmConfiguration: configuration)
            }
        }, mutation: {
            replacementBytes = try self.replaceFileWithCopy(configuration)
        })
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(configuration.fileURL)), try XCTUnwrap(replacementBytes))
        XCTAssertNil(realm.object(ofType: HistoryRecord.self, forPrimaryKey: reference.contentKey)?.isDemoted)
    }

    @RealmBackgroundActor
    private func assertReplacementBeforeHistoryCopy(replaceSource: Bool) async throws {
        let sourceConfiguration = try diskConfiguration()
        let historyConfiguration = try diskConfiguration()
        let sourceRealm = try await RealmBackgroundActor.shared.cachedRealm(for: sourceConfiguration)
        let historyRealm = try await RealmBackgroundActor.shared.cachedRealm(for: historyConfiguration)
        let url = URL(string: "https://example.com/replaced-history-source")!
        let key = try await sourceRealm.asyncWritePreservingOwnership {
            let source = Bookmark()
            source.url = url
            source.title = "Captured bookmark"
            source.updateCompoundKey()
            sourceRealm.add(source)
            source.refreshChangeMetadata(explicitlyModified: true)
            try assertPendingMutation(for: source, in: source.realm!)
            return source.compoundKey
        }
        let replaced = replaceSource ? sourceConfiguration : historyConfiguration
        var replacementBytes: Data?
        try await withPausedWrite(.historyCreation, action: {
            let source = try XCTUnwrap(sourceRealm.object(ofType: Bookmark.self, forPrimaryKey: key))
            await self.assertFileReplacementRejected {
                try await source.addHistoryRecord(realmConfiguration: historyConfiguration,
                    pageURL: url, bookmarkRealmConfiguration: sourceConfiguration)
            }
        }, mutation: {
            replacementBytes = try self.replaceFileWithCopy(replaced)
        })
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(replaced.fileURL)), try XCTUnwrap(replacementBytes))
        XCTAssertTrue(historyRealm.objects(HistoryRecord.self).isEmpty)
    }

    @RealmBackgroundActor
    func testSamePathSourceReplacementBeforeHistoryCreationFinalWriteRejects() async throws {
        try await assertReplacementBeforeHistoryCopy(replaceSource: true)
    }

    @RealmBackgroundActor
    func testSamePathDestinationReplacementBeforeHistoryCreationFinalWriteRejects() async throws {
        try await assertReplacementBeforeHistoryCopy(replaceSource: false)
    }

    @RealmBackgroundActor
    func testHistoryBookmarkAssociationUsesCapturedHistoryWriterAndLiveBookmarkTarget() async throws {
        let bookmarks = makeConfiguration()
        let history = makeConfiguration()
        let bookmarkRealm = try await RealmBackgroundActor.shared.cachedRealm(for: bookmarks)
        let historyRealm = try await RealmBackgroundActor.shared.cachedRealm(for: history)
        addTeardownBlock {
            _ = await RealmBackgroundActor.shared.removeCachedRealm(for: bookmarks)
            _ = await RealmBackgroundActor.shared.removeCachedRealm(for: history)
        }
        let url = URL(string: "https://example.com/history-association")!
        let key = try await bookmarkRealm.asyncWritePreservingOwnership {
            let source = Bookmark()
            source.url = url
            source.updateCompoundKey()
            bookmarkRealm.add(source)
            source.refreshChangeMetadata(explicitlyModified: true)
            try assertPendingMutation(for: source, in: source.realm!)
            return source.compoundKey
        }
        let previousKey = try await historyRealm.asyncWritePreservingOwnership {
            let prior = HistoryRecord()
            prior.url = url
            prior.compoundKey = UUID().uuidString
            historyRealm.add(prior)
            prior.refreshChangeMetadata(explicitlyModified: true)
            try assertPendingMutation(for: prior, in: prior.realm!)
            return prior.compoundKey
        }
        let source = try XCTUnwrap(bookmarkRealm.object(ofType: Bookmark.self, forPrimaryKey: key))
        let result = try await source.addHistoryRecord(realmConfiguration: history, pageURL: url,
            bookmarkRealmConfiguration: bookmarks)
        XCTAssertEqual(result.bookmarkID, key)
        try assertPendingMutation(for: result, in: historyRealm)
        try assertPendingMutation(for: try XCTUnwrap(historyRealm.object(ofType: HistoryRecord.self, forPrimaryKey: previousKey)), in: historyRealm)
        XCTAssertEqual(historyRealm.object(ofType: HistoryRecord.self, forPrimaryKey: previousKey)?.bookmarkID, key)
        XCTAssertTrue(bookmarkRealm.objects(HistoryRecord.self).isEmpty)
        XCTAssertFalse(historyRealm.isInWriteTransaction)
    }

    private func pendingMutation(for object: Object, in realm: Realm) -> BigSyncPendingMutation? {
        let primaryKey = object.objectSchema.primaryKeyProperty!.name
        let identifier = String(describing: object[primaryKey]!)
        return realm.object(ofType: BigSyncPendingMutation.self,
            forPrimaryKey: object.objectSchema.className + "." + identifier)
    }

    private func assertPendingMutation(for object: Bookmark, in realm: Realm) throws {
        let pending = try XCTUnwrap(pendingMutation(for: object, in: realm))
        XCTAssertFalse(pending.generation.isEmpty)
        XCTAssertEqual(pending.changedAt, object.explicitlyModifiedAt)
        XCTAssertEqual(pending.changedAt, object.modifiedAt)
    }

    private struct JournalState: Equatable {
        let generation: String
        let changedAt: Date
        let modifiedAt: Date
        let explicitlyModifiedAt: Date?
    }

    private func journalState(for object: Bookmark, in realm: Realm) throws -> JournalState {
        try assertPendingMutation(for: object, in: realm)
        let pending = try XCTUnwrap(pendingMutation(for: object, in: realm))
        return JournalState(generation: pending.generation, changedAt: pending.changedAt,
            modifiedAt: object.modifiedAt, explicitlyModifiedAt: object.explicitlyModifiedAt)
    }

    @MainActor
    private func assertMissingStoreOverlap(sameURL: Bool) async throws {
        let configuration = try diskConfiguration()
        let path = try XCTUnwrap(configuration.fileURL)
        let oldBookmark = ReaderContentLoader.bookmarkRealmConfiguration
        let oldHistory = ReaderContentLoader.historyRealmConfiguration
        let oldFeed = ReaderContentLoader.feedEntryRealmConfiguration
        defer {
            ReaderContentLoader.bookmarkRealmConfiguration = oldBookmark
            ReaderContentLoader.historyRealmConfiguration = oldHistory
            ReaderContentLoader.feedEntryRealmConfiguration = oldFeed
        }
        await ReaderContentLoader.resetTransientCachesForTesting()
        ReaderContentLoader.bookmarkRealmConfiguration = configuration
        ReaderContentLoader.historyRealmConfiguration = configuration
        ReaderContentLoader.feedEntryRealmConfiguration = configuration
        let gate = ReaderContentLoadingDiscoveryGate()
        await { @RealmBackgroundActor in
            ReaderContentLoader.loadAllDiscoveryGateForTesting = { await gate.pause() }
        }()
        let firstURL = URL(string: "https://example.com/missing-overlap/first")!
        let secondURL = sameURL ? firstURL : URL(string: "https://example.com/missing-overlap/second")!
        let creationOwner = RealmBackgroundActor.shared.captureStorageAdmission(for: configuration)
        let first = Task { @MainActor in try await ReaderContentLoader.getContent(forURL: firstURL) }
        let firstEntered = expectation(description: "first discovery captured missing admission")
        let firstArrival = Task { _ = await gate.waitForArrivals(1); firstEntered.fulfill() }
        addTeardownBlock {
            await gate.releaseAll()
            _ = await first.result
            await firstArrival.value
            await ReaderContentLoader.resetTransientCachesForTesting()
        }
        await fulfillment(of: [firstEntered], timeout: 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        let captured = expectation(description: "second operation captured before exclusive creation")
        let overlappingOwner = RealmBackgroundActor.shared.captureStorageAdmission(for: configuration)
        XCTAssertTrue(creationOwner === overlappingOwner)
        let joined = sameURL ? expectation(description: "same URL joined the first getContent task") : nil
        let second = Task { @MainActor in
            try await ReaderContentLoader.$getContentObservationForTesting.withValue({ event in
                switch event {
                case .capturedStorage: captured.fulfill()
                case .joinedTask: joined?.fulfill()
                }
            }) {
                try await ReaderContentLoader.getContent(forURL: secondURL)
            }
        }
        addTeardownBlock { await gate.releaseAll(); _ = await second.result }
        await fulfillment(of: [captured] + (joined.map { [$0] } ?? []), timeout: 2)
        if !sameURL {
            let bothEntered = expectation(description: "different URL discovery also captured missing admission")
            let arrival = Task { _ = await gate.waitForArrivals(2); bothEntered.fulfill() }
            addTeardownBlock { await gate.releaseAll(); await arrival.value }
            await fulfillment(of: [bothEntered], timeout: 2)
        }
        let arrivals = await gate.arrivalCount()
        XCTAssertEqual(arrivals, sameURL ? 1 : 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        await gate.releaseAll()
        let firstResult = try await first.value
        let secondResult = try await second.value
        let firstContent = try XCTUnwrap(firstResult as? HistoryRecord)
        let secondContent = try XCTUnwrap(secondResult as? HistoryRecord)
        if sameURL { XCTAssertTrue(firstContent === secondContent) }
        XCTAssertTrue(creationOwner.matchesCurrentStorageIdentity {
            RealmBackgroundActor.shared.realmCacheKey(for: configuration)
        })
        XCTAssertEqual(creationOwner.scopeIdentity, overlappingOwner.scopeIdentity)
        try await RealmBackgroundActor.shared.prepareStorage(for: configuration, storageAdmission: overlappingOwner)
        XCTAssertEqual(firstContent.url, firstURL)
        XCTAssertEqual(secondContent.url, secondURL)
        let firstReference = try XCTUnwrap(ReaderContentLoader.ContentReference(content: firstContent))
        let secondReference = try XCTUnwrap(ReaderContentLoader.ContentReference(content: secondContent))
        try firstReference.validateStorage()
        try secondReference.validateStorage()
        XCTAssertEqual(firstReference.storageAdmission.scopeIdentity, secondReference.storageAdmission.scopeIdentity)
        let realm = try await Realm(configuration: configuration, actor: MainActor.shared)
        await realm.asyncRefresh()
        XCTAssertEqual(realm.objects(HistoryRecord.self).count, sameURL ? 1 : 2)
        for record in realm.objects(HistoryRecord.self) { try assertPendingMutation(for: record, in: realm) }
    }

    @MainActor
    func testMissingStoreSameURLOverlapsShareCreationAndGetContentTask() async throws {
        try await assertMissingStoreOverlap(sameURL: true)
    }

    @MainActor
    func testMissingStoreDifferentURLOverlapsShareOnlyCreationOwner() async throws {
        try await assertMissingStoreOverlap(sameURL: false)
    }

    @MainActor
    func testMissingStoreExternalAppearanceBeforeDiscoveryOpenIsRejected() async throws {
        let configuration = try diskConfiguration()
        let path = try XCTUnwrap(configuration.fileURL)
        let oldBookmark = ReaderContentLoader.bookmarkRealmConfiguration
        let oldHistory = ReaderContentLoader.historyRealmConfiguration
        let oldFeed = ReaderContentLoader.feedEntryRealmConfiguration
        defer {
            ReaderContentLoader.bookmarkRealmConfiguration = oldBookmark
            ReaderContentLoader.historyRealmConfiguration = oldHistory
            ReaderContentLoader.feedEntryRealmConfiguration = oldFeed
        }
        await ReaderContentLoader.resetTransientCachesForTesting()
        ReaderContentLoader.bookmarkRealmConfiguration = configuration
        ReaderContentLoader.historyRealmConfiguration = configuration
        ReaderContentLoader.feedEntryRealmConfiguration = configuration
        let gate = ReaderContentLoadingDiscoveryGate()
        await { @RealmBackgroundActor in
            ReaderContentLoader.loadAllDiscoveryGateForTesting = { await gate.pause() }
        }()
        // Retain two captured owners: sharing must not license either to adopt
        // the unrelated file which appears while both are paused.
        let admissionA = RealmBackgroundActor.shared.captureStorageAdmission(for: configuration)
        let admissionB = RealmBackgroundActor.shared.captureStorageAdmission(for: configuration)
        XCTAssertTrue(admissionA === admissionB)
        let task = Task { @MainActor in
            try await ReaderContentLoader.getContent(forURL: URL(string: "https://example.com/external-appearance")!)
        }
        let entered = expectation(description: "missing admission captured before external file appears")
        let arrival = Task { _ = await gate.waitForArrivals(1); entered.fulfill() }
        addTeardownBlock {
            await gate.releaseAll(); _ = await task.result; await arrival.value
            await ReaderContentLoader.resetTransientCachesForTesting()
        }
        await fulfillment(of: [entered], timeout: 2)
        let externalBytes = Data("externally created, never admitted".utf8)
        try externalBytes.write(to: path, options: .withoutOverwriting)
        await gate.releaseAll()
        await assertFileReplacementRejected { try await task.value }
        await assertFileReplacementRejected {
            try await RealmBackgroundActor.shared.prepareStorage(for: configuration, storageAdmission: admissionB)
        }
        XCTAssertEqual(try Data(contentsOf: path), externalBytes)
    }

    func testMissingStoreCreationOwnerHasWeakLifetimeAndSeparatesConfigurations() throws {
        let configuration = try diskConfiguration()
        var first: RealmStorageAdmission? = RealmBackgroundActor.shared.captureStorageAdmission(for: configuration)
        weak var weakOwner = first
        let scope = try XCTUnwrap(first).scopeIdentity
        var second: RealmStorageAdmission? = RealmBackgroundActor.shared.captureStorageAdmission(for: configuration)
        XCTAssertTrue(first === second)
        var readOnly = configuration
        readOnly.readOnly = true
        let incompatible = RealmBackgroundActor.shared.captureStorageAdmission(for: readOnly)
        XCTAssertNotEqual(incompatible.scopeIdentity, scope)
        first = nil
        second = nil
        XCTAssertNil(weakOwner)
        let fresh = RealmBackgroundActor.shared.captureStorageAdmission(for: configuration)
        XCTAssertNotEqual(fresh.scopeIdentity, scope)
    }

    @RealmBackgroundActor
    func testCompletedCreationOwnerCannotAdmitLaterMissingIncarnation() async throws {
        let configuration = try diskConfiguration()
        let path = try XCTUnwrap(configuration.fileURL)
        let owner = RealmBackgroundActor.shared.captureStorageAdmission(for: configuration)
        try await RealmBackgroundActor.shared.prepareStorage(for: configuration, storageAdmission: owner)
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration, storageAdmission: owner)
        try FileManager.default.moveItem(at: path,
            to: path.deletingLastPathComponent().appendingPathComponent("retired-owned.realm"))
        let later = RealmBackgroundActor.shared.captureStorageAdmission(for: configuration)
        XCTAssertFalse(owner === later)
        XCTAssertNotEqual(owner.scopeIdentity, later.scopeIdentity)
        let externalBytes = Data("unowned later incarnation".utf8)
        try externalBytes.write(to: path, options: .withoutOverwriting)
        for captured in [owner, later] {
            await assertFileReplacementRejected {
                try await RealmBackgroundActor.shared.prepareStorage(for: configuration, storageAdmission: captured)
            }
        }
        XCTAssertEqual(try Data(contentsOf: path), externalBytes)
        XCTAssertTrue(realm.objects(HistoryRecord.self).isEmpty)
    }

    @RealmBackgroundActor
    private func assertDetachedFeedPayload(fullBody: Bool, explicitSubtitleRole: Bool, hasSubtitle: Bool = true) async throws {
        let sourceConfiguration = makeConfiguration(objectTypes: storageObjectTypes + [Feed.self])
        let historyConfiguration = makeConfiguration()
        addTeardownBlock {
            _ = await RealmBackgroundActor.shared.removeCachedRealm(for: sourceConfiguration)
            _ = await RealmBackgroundActor.shared.removeCachedRealm(for: historyConfiguration)
        }
        let sourceRealm = try await RealmBackgroundActor.shared.cachedRealm(for: sourceConfiguration)
        let historyRealm = try await RealmBackgroundActor.shared.cachedRealm(for: historyConfiguration)
        let pageURL = URL(string: "https://example.com/detached-feed")!
        let image = URL(string: "https://example.com/captured-image.jpg")!
        let rssURL = URL(string: "https://example.com/captured-rss.xml")!
        let frame = URL(string: "https://example.com/captured-frame")!
        let audioA = URL(string: "https://example.com/first.mp3")!
        let audioB = URL(string: "https://example.com/second.mp3")!
        let subtitle = URL(string: "https://example.com/captured.vtt")!
        let translation = URL(string: "https://example.com/captured-translation")!
        let publication = Date(timeIntervalSinceReferenceDate: 80_000)
        let bodyHTML = "<html><body><p>Captured feed body</p><img src=\"\(image.absoluteString)\"></body></html>"
        let body = try XCTUnwrap(bodyHTML.readerContentData)
        let feedID = UUID()
        let sourceKey = try await sourceRealm.asyncWritePreservingOwnership {
            let feed = Feed()
            feed.id = feedID
            feed.title = "Captured feed title"
            feed.rssUrl = rssURL
            feed.rssContainsFullContent = fullBody
            feed.meaningfulContentMinLength = 321
            feed.injectEntryImageIntoHeader = true
            feed.displayPublicationDate = false
            feed.extractImageFromContent = true
            feed.isReaderModeByDefault = false
            sourceRealm.add(feed)
            feed.refreshChangeMetadata(explicitlyModified: true)
            let entry = FeedEntry()
            entry.feedID = feedID
            entry.url = pageURL
            entry.title = "Captured entry title"
            entry.content = body
            entry.voiceFrameUrl = frame
            entry.voiceAudioURL = audioA
            // The scalar is absent from the list; existing resolution promotes
            // it once, keeping list order without inventing deduplication.
            entry.voiceAudioURLs.append(audioB)
            entry.audioSubtitlesURL = hasSubtitle ? subtitle : nil
            entry.audioSubtitlesRoleRawValue = explicitSubtitleRole ? AudioSubtitlesRole.media.rawValue : nil
            entry.autoOpenMediaPlayer = true
            entry.publicationDate = publication
            entry.redditTranslationsUrl = translation
            entry.redditTranslationsTitle = "Captured translation"
            entry.updateCompoundKey()
            sourceRealm.add(entry)
            entry.refreshChangeMetadata(explicitlyModified: true)
            return entry.compoundKey
        }
        let source = try XCTUnwrap(sourceRealm.object(ofType: FeedEntry.self, forPrimaryKey: sourceKey))
        let sourceJournal = try XCTUnwrap(pendingMutation(for: source, in: sourceRealm))
        var expectedSourceGeneration = sourceJournal.generation
        var expectedSourceModifiedAt = source.modifiedAt
        try await withPausedWrite(.historyCreation, action: {
            let record = try await source.addHistoryRecord(realmConfiguration: historyConfiguration,
                pageURL: pageURL, bookmarkRealmConfiguration: historyConfiguration)
            XCTAssertEqual(record.title, "Captured entry title")
            XCTAssertEqual(record.content, body)
            XCTAssertEqual(record.rssContainsFullContent, fullBody)
            XCTAssertEqual(record.imageUrl, image)
            XCTAssertEqual(Array(record.rssURLs), [rssURL])
            XCTAssertEqual(Array(record.rssTitles), ["Captured feed title"])
            XCTAssertTrue(record.isRSSAvailable)
            XCTAssertEqual(record.meaningfulContentMinLength, 321)
            XCTAssertTrue(record.injectEntryImageIntoHeader)
            XCTAssertFalse(record.displayPublicationDate)
            XCTAssertFalse(record.isReaderModeByDefault)
            XCTAssertFalse(record.isReaderModeAvailable)
            XCTAssertEqual(record.publicationDate, publication)
            XCTAssertEqual(record.voiceFrameUrl, frame)
            XCTAssertEqual(record.voiceAudioURL, audioA)
            XCTAssertEqual(Array(record.voiceAudioURLs), [audioA, audioB])
            XCTAssertEqual(record.audioSubtitlesURL, hasSubtitle ? subtitle : nil)
            XCTAssertEqual(record.audioSubtitlesRoleRawValue,
                explicitSubtitleRole ? AudioSubtitlesRole.media.rawValue : AudioSubtitlesRole.content.rawValue)
            XCTAssertTrue(record.autoOpenMediaPlayer)
            XCTAssertEqual(record.redditTranslationsUrl, translation)
            XCTAssertEqual(record.redditTranslationsTitle, "Captured translation")
            try self.assertPendingMutation(for: record, in: historyRealm)
        }, mutation: {
            // Neither snapshot capture nor image extraction writes the source.
            XCTAssertNil(source.imageUrl)
            XCTAssertEqual(pendingMutation(for: source, in: sourceRealm)?.generation, expectedSourceGeneration)
            XCTAssertEqual(source.modifiedAt, expectedSourceModifiedAt)
            try await sourceRealm.asyncWritePreservingOwnership {
                let feed = try XCTUnwrap(sourceRealm.object(ofType: Feed.self, forPrimaryKey: feedID))
                feed.title = "Later feed title"
                feed.rssUrl = URL(string: "https://example.com/later-rss.xml")!
                feed.rssContainsFullContent = !fullBody
                feed.meaningfulContentMinLength = 999
                feed.injectEntryImageIntoHeader = false
                feed.displayPublicationDate = true
                feed.extractImageFromContent = false
                feed.isReaderModeByDefault = true
                feed.refreshChangeMetadata(explicitlyModified: true)
                source.title = "Later entry title"
                source.html = "<p>Later entry body</p>"
                source.voiceFrameUrl = nil
                source.voiceAudioURL = nil
                source.voiceAudioURLs.removeAll()
                source.audioSubtitlesURL = nil
                source.audioSubtitlesRoleRawValue = nil
                source.autoOpenMediaPlayer = false
                source.publicationDate = nil
                source.redditTranslationsUrl = nil
                source.redditTranslationsTitle = nil
                source.refreshChangeMetadata(explicitlyModified: true)
                expectedSourceGeneration = try XCTUnwrap(pendingMutation(for: source, in: sourceRealm)).generation
                expectedSourceModifiedAt = source.modifiedAt
            }
        })
        XCTAssertNil(source.imageUrl)
        XCTAssertEqual(source.modifiedAt, expectedSourceModifiedAt)
        XCTAssertEqual(pendingMutation(for: source, in: sourceRealm)?.generation, expectedSourceGeneration)
        XCTAssertEqual(sourceRealm.objects(HistoryRecord.self).count, 0)
        XCTAssertEqual(historyRealm.objects(HistoryRecord.self).count, 1)
    }

    @RealmBackgroundActor
    func testDetachedFeedFullBodyExtractedImageRSSAndExplicitSubtitlePayload() async throws {
        try await assertDetachedFeedPayload(fullBody: true, explicitSubtitleRole: true)
    }

    @RealmBackgroundActor
    func testDetachedFeedSummaryExtractedImageRSSAndDefaultSubtitlePayload() async throws {
        try await assertDetachedFeedPayload(fullBody: false, explicitSubtitleRole: false)
        // Feed configuration defaults the role even when no subtitle URL is
        // present; cover that separate branch without changing media behavior.
        try await assertDetachedFeedPayload(fullBody: false, explicitSubtitleRole: false, hasSubtitle: false)
    }

    @RealmBackgroundActor
    func testClipboardMutationJournalsOnceAndRepeatedNoOpPreservesJournal() async throws {
        let configuration = try diskConfiguration()
        let reference = try await seededHistory(in: configuration)
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        let record = try XCTUnwrap(realm.object(ofType: HistoryRecord.self, forPrimaryKey: reference.contentKey))
        let seeded = try journalState(for: record, in: realm)
        let first = try await ReaderContentLoader.markSnippetFromClipboard(reference)
        XCTAssertNotNil(first)
        XCTAssertTrue(record.isFromClipboard)
        XCTAssertTrue(record.rssContainsFullContent)
        XCTAssertTrue(record.isReaderModeByDefault)
        let changed = try journalState(for: record, in: realm)
        XCTAssertNotEqual(changed.generation, seeded.generation)
        let repeated = try await ReaderContentLoader.markSnippetFromClipboard(reference)
        XCTAssertNotNil(repeated)
        XCTAssertEqual(try journalState(for: record, in: realm), changed)
    }

    @RealmBackgroundActor
    func testDemotionMutationAndRecomputedNoOpPreserveJournal() async throws {
        let configuration = try diskConfiguration()
        let reference = try await seededHistory(in: configuration)
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        let record = try XCTUnwrap(realm.object(ofType: HistoryRecord.self, forPrimaryKey: reference.contentKey))
        let seeded = try journalState(for: record, in: realm)
        try await record.refreshDemotedStatus(bookmarkRealmConfiguration: configuration, skipPreviouslyDemoted: false)
        XCTAssertEqual(record.isDemoted, true)
        let demoted = try journalState(for: record, in: realm)
        XCTAssertNotEqual(demoted.generation, seeded.generation)
        try await record.refreshDemotedStatus(bookmarkRealmConfiguration: configuration, skipPreviouslyDemoted: false)
        XCTAssertEqual(try journalState(for: record, in: realm), demoted)
        _ = try await ReaderContentLoader.finishLoadedContent(reference, countsAsHistoryVisit: false, readerModeRequired: true)
        let readerMode = try journalState(for: record, in: realm)
        try await record.refreshDemotedStatus(bookmarkRealmConfiguration: configuration, skipPreviouslyDemoted: false)
        XCTAssertEqual(record.isDemoted, false)
        let promoted = try journalState(for: record, in: realm)
        XCTAssertNotEqual(promoted.generation, readerMode.generation)
        // Force recomputation, so the equality guard inside the final writer
        // is exercised rather than only the previously-demoted early return.
        try await record.refreshDemotedStatus(bookmarkRealmConfiguration: configuration, skipPreviouslyDemoted: false)
        XCTAssertEqual(try journalState(for: record, in: realm), promoted)
    }

    @RealmBackgroundActor
    func testReaderModeMutationAndReadOnlyLoadsPreserveNoOpJournal() async throws {
        let configuration = try diskConfiguration()
        let reference = try await seededHistory(in: configuration)
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        let record = try XCTUnwrap(realm.object(ofType: HistoryRecord.self, forPrimaryKey: reference.contentKey))
        let seeded = try journalState(for: record, in: realm)
        let first = try await ReaderContentLoader.finishLoadedContent(reference,
            countsAsHistoryVisit: false, readerModeRequired: true)
        XCTAssertNotNil(first)
        XCTAssertTrue(record.isReaderModeByDefault)
        let changed = try journalState(for: record, in: realm)
        XCTAssertNotEqual(changed.generation, seeded.generation)
        let repeated = try await ReaderContentLoader.finishLoadedContent(reference,
            countsAsHistoryVisit: false, readerModeRequired: true)
        XCTAssertNotNil(repeated)
        XCTAssertEqual(try journalState(for: record, in: realm), changed)
        let readOnly = try await ReaderContentLoader.finishLoadedContent(reference,
            countsAsHistoryVisit: false, readerModeRequired: false)
        XCTAssertNotNil(readOnly)
        XCTAssertEqual(try journalState(for: record, in: realm), changed)
        _ = try await ReaderContentLoader.finishLoadedContent(reference,
            countsAsHistoryVisit: true, readerModeRequired: true)
        XCTAssertNotEqual(try journalState(for: record, in: realm).generation, changed.generation)
    }

}
