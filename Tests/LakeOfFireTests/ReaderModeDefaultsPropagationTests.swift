import BigSyncKit
import RealmSwift
import XCTest
@testable import LakeOfFireContent
@testable import RealmSwiftGaps

private actor ReaderModePropagationProviderGate {
    private var arrived = false
    private var released = false
    private var arrivalWaiters = [CheckedContinuation<Void, Never>]()
    private var releaseWaiters = [CheckedContinuation<Void, Never>]()

    func pause() async {
        arrived = true
        let waiters = arrivalWaiters
        arrivalWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if !released { await withCheckedContinuation { releaseWaiters.append($0) } }
    }

    func waitForArrival() async -> Bool {
        if !arrived && !released { await withCheckedContinuation { arrivalWaiters.append($0) } }
        return arrived
    }

    func release() {
        released = true
        let waiters = releaseWaiters + arrivalWaiters
        releaseWaiters.removeAll()
        arrivalWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func hasArrived() -> Bool { arrived }
}

final class ReaderModeDefaultsPropagationTests: XCTestCase {
    private let html = "<article><p>Captured reader content.</p></article>"

    private struct JournalState: Equatable {
        let generation: String
        let changedAt: Date
        let modifiedAt: Date
        let explicitlyModifiedAt: Date?
    }

    private func makeConfiguration() -> Realm.Configuration {
        var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        configuration.objectTypes = [Bookmark.self, HistoryRecord.self, ContentFile.self, Feed.self, FeedEntry.self]
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        let captured = configuration
        addTeardownBlock { _ = await RealmBackgroundActor.shared.removeCachedRealm(for: captured) }
        return configuration
    }

    private func diskConfiguration() throws -> Realm.Configuration {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("reader-mode-propagation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var configuration = Realm.Configuration(fileURL: directory.appendingPathComponent("current.realm"))
        configuration.objectTypes = [Bookmark.self, HistoryRecord.self, ContentFile.self, Feed.self, FeedEntry.self]
        // Journal registration must use the final file route, not an earlier
        // in-memory configuration with a different storage identity.
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        let fileURL = try XCTUnwrap(configuration.fileURL)
        addTeardownBlock {
            let released = await Self.releaseFixtureRealms(owner: RealmBackgroundActor.shared, fileURL: fileURL)
            if released { try FileManager.default.removeItem(at: directory) }
        }
        return configuration
    }

    private static func releaseFixtureRealms(owner: isolated RealmBackgroundActor, fileURL: URL) -> Bool {
        // The path may now name a replacement inode. Evict the cached
        // incarnations of this unique fixture path, including the old
        // one that removeCachedRealm(for:) can no longer address.
        let cached = owner.cachedRealms.filter {
            $0.value.configuration.fileURL?.standardizedFileURL == fileURL.standardizedFileURL
        }
        guard cached.values.allSatisfy({ !$0.isInWriteTransaction }) else {
            XCTFail("Disk fixture cleanup must not interrupt an active transaction")
            return false
        }
        for key in cached.keys {
            owner.cachedRealms.removeValue(forKey: key)?.invalidate()
        }
        return true
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

    private func install(_ configuration: Realm.Configuration) -> () -> Void {
        let bookmark = ReaderContentLoader.bookmarkRealmConfiguration
        let history = ReaderContentLoader.historyRealmConfiguration
        let feed = ReaderContentLoader.feedEntryRealmConfiguration
        let providers = ReaderContentLoader.additionalContentProviders
        ReaderContentLoader.bookmarkRealmConfiguration = configuration
        ReaderContentLoader.historyRealmConfiguration = configuration
        ReaderContentLoader.feedEntryRealmConfiguration = configuration
        ReaderContentLoader.additionalContentProviders = []
        return {
            ReaderContentLoader.bookmarkRealmConfiguration = bookmark
            ReaderContentLoader.historyRealmConfiguration = history
            ReaderContentLoader.feedEntryRealmConfiguration = feed
            ReaderContentLoader.additionalContentProviders = providers
        }
    }

    private func configured<T: Bookmark>(_ record: T, url: URL, title: String = "") -> T {
        record.url = url
        record.title = title
        record.createdAt = Date(timeIntervalSinceReferenceDate: 90_000)
        record.isReaderModeAvailable = true
        record.updateCompoundKey()
        return record
    }

    @RealmBackgroundActor
    private func seed(_ records: [Bookmark], in realm: Realm) async throws {
        try await realm.asyncWrite {
            for record in records {
                realm.add(record)
                record.refreshChangeMetadata(explicitlyModified: true)
            }
        }
    }

    private func journalState(for record: Object & ChangeMetadataRecordable, in realm: Realm) throws -> JournalState {
        let primaryKey = try XCTUnwrap(record.objectSchema.primaryKeyProperty?.name)
        let identifier = String(describing: try XCTUnwrap(record[primaryKey]))
        let pending = try XCTUnwrap(realm.object(ofType: BigSyncPendingMutation.self,
            forPrimaryKey: record.objectSchema.className + "." + identifier))
        XCTAssertFalse(pending.generation.isEmpty)
        XCTAssertEqual(pending.changedAt, record.modifiedAt)
        XCTAssertEqual(pending.changedAt, record.explicitlyModifiedAt)
        return JournalState(generation: pending.generation, changedAt: pending.changedAt,
            modifiedAt: record.modifiedAt, explicitlyModifiedAt: record.explicitlyModifiedAt)
    }

    private func awaitProvider(
        _ gate: ReaderModePropagationProviderGate, task: Task<Int, Error>
    ) async -> Bool {
        let entered = expectation(description: "production discovery reached its captured provider")
        let arrival = Task { if await gate.waitForArrival() { entered.fulfill() } }
        addTeardownBlock {
            task.cancel()
            await gate.release()
            _ = await task.result
            await arrival.value
        }
        await fulfillment(of: [entered], timeout: 2)
        return await gate.hasArrived()
    }

    @RealmBackgroundActor
    func testSameKeyRepresentationsPropagateOnceWithoutChangingPrimaryJournal() async throws {
        let configuration = makeConfiguration()
        let restore = install(configuration)
        defer { restore() }
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        let url = URL(string: "https://example.com/reader-defaults/\(UUID().uuidString)")!
        let primary = configured(HistoryRecord(), url: url, title: "Primary")
        let related = configured(Bookmark(), url: url)
        try await seed([primary, related], in: realm)
        XCTAssertEqual(primary.compoundKey, related.compoundKey)
        XCTAssertEqual(primary.createdAt, related.createdAt)
        let primarySeeded = try journalState(for: primary, in: realm)
        let relatedSeeded = try journalState(for: related, in: realm)
        let context = ReaderContentLoader.ReaderModePropagationContext(primaryContent: primary)

        let changedCount = try await ReaderContentLoader.propagateReaderModeDefaults(
            for: url, context: context, readabilityHTML: html, resolvedTitle: "Resolved title"
        )
        XCTAssertEqual(changedCount, 1)
        XCTAssertTrue(related.isReaderModeByDefault)
        XCTAssertFalse(related.isReaderModeAvailable)
        XCTAssertTrue(related.rssContainsFullContent)
        XCTAssertEqual(related.html, html)
        XCTAssertEqual(related.title, "Resolved title")
        XCTAssertFalse(primary.isReaderModeByDefault)
        XCTAssertTrue(primary.isReaderModeAvailable)
        XCTAssertNil(primary.html)
        XCTAssertEqual(try journalState(for: primary, in: realm), primarySeeded)
        let changed = try journalState(for: related, in: realm)
        XCTAssertNotEqual(changed.generation, relatedSeeded.generation)

        let repeatedCount = try await ReaderContentLoader.propagateReaderModeDefaults(
            for: url, context: context, readabilityHTML: html, resolvedTitle: "Resolved title"
        )
        XCTAssertEqual(repeatedCount, 0)
        XCTAssertEqual(try journalState(for: related, in: realm), changed)
        XCTAssertEqual(try journalState(for: primary, in: realm), primarySeeded)

        let laterCount = try await ReaderContentLoader.propagateReaderModeDefaults(
            for: url, context: context,
            readabilityHTML: "<article><p>A later render must not replace saved content.</p></article>",
            resolvedTitle: "Later title"
        )
        XCTAssertEqual(laterCount, 0)
        XCTAssertEqual(related.html, html)
        XCTAssertEqual(related.title, "Resolved title")
        XCTAssertEqual(try journalState(for: related, in: realm), changed)
        XCTAssertEqual(try journalState(for: primary, in: realm), primarySeeded)
    }

    @RealmBackgroundActor
    func testAutomaticSchemaAndMaterializedViewKeepTheSamePrimaryExcluded() async throws {
        // Install the fixture-model journal policy before opening the store.
        // The automatic opening configuration must keep its nil schema rather
        // than replacing it with the explicit mutation-tracking allowlist.
        var automaticConfiguration = makeConfiguration()
        automaticConfiguration.objectTypes = nil
        let capturedAutomaticConfiguration = automaticConfiguration
        addTeardownBlock {
            _ = await RealmBackgroundActor.shared.removeCachedRealm(for: capturedAutomaticConfiguration)
        }
        let restore = install(automaticConfiguration)
        defer { restore() }
        XCTAssertNil(automaticConfiguration.objectTypes)
        let automaticRealm = try await RealmBackgroundActor.shared.cachedRealm(for: automaticConfiguration)
        let materializedConfiguration = automaticRealm.configuration
        let materializedTypes = try XCTUnwrap(materializedConfiguration.objectTypes)
        XCTAssertTrue(materializedTypes.contains { $0.className() == BigSyncPendingMutation.className() })
        XCTAssertTrue(materializedTypes.contains { $0.className() == Bookmark.className() })
        XCTAssertTrue(materializedTypes.contains { $0.className() == HistoryRecord.className() })
        addTeardownBlock {
            _ = await RealmBackgroundActor.shared.removeCachedRealm(for: materializedConfiguration)
        }

        let url = URL(string: "https://example.com/automatic-reader-schema/\(UUID().uuidString)")!
        let seededPrimary = configured(HistoryRecord(), url: url, title: "Primary")
        let related = configured(Bookmark(), url: url)
        try await seed([seededPrimary, related], in: automaticRealm)
        let materializedRealm = try await RealmBackgroundActor.shared.cachedRealm(for: materializedConfiguration)
        await materializedRealm.asyncRefresh()
        let primary = try XCTUnwrap(materializedRealm.object(
            ofType: HistoryRecord.self, forPrimaryKey: seededPrimary.compoundKey
        ))
        XCTAssertFalse(primary.isReaderModeByDefault)
        XCTAssertTrue(primary.isReaderModeAvailable)
        XCTAssertNil(primary.html)
        let primarySeeded = try journalState(for: primary, in: materializedRealm)
        let relatedSeeded = try journalState(for: related, in: automaticRealm)
        // Primary capture uses the materialized configuration, while builtin
        // discovery retains the original automatic configuration of this store.
        let context = ReaderContentLoader.ReaderModePropagationContext(primaryContent: primary)

        let changedCount = try await ReaderContentLoader.propagateReaderModeDefaults(
            for: url, context: context, readabilityHTML: html, resolvedTitle: "Automatic-schema title"
        )
        await automaticRealm.asyncRefresh()
        await materializedRealm.asyncRefresh()

        XCTAssertEqual(changedCount, 1)
        XCTAssertTrue(related.isReaderModeByDefault)
        XCTAssertEqual(related.html, html)
        XCTAssertNotEqual(try journalState(for: related, in: automaticRealm).generation, relatedSeeded.generation)
        XCTAssertFalse(primary.isReaderModeByDefault)
        XCTAssertTrue(primary.isReaderModeAvailable)
        XCTAssertNil(primary.html)
        XCTAssertEqual(primary.title, "Primary")
        XCTAssertEqual(try journalState(for: primary, in: materializedRealm), primarySeeded)
    }

    @RealmBackgroundActor
    func testCapturedStoresAndProviderListPreserveSameTypePeerInAnotherStore() async throws {
        let capturedConfiguration = makeConfiguration()
        let providerConfiguration = makeConfiguration()
        let replacementConfiguration = makeConfiguration()
        let restore = install(capturedConfiguration)
        defer { restore() }
        let capturedRealm = try await RealmBackgroundActor.shared.cachedRealm(for: capturedConfiguration)
        let providerRealm = try await RealmBackgroundActor.shared.cachedRealm(for: providerConfiguration)
        let replacementRealm = try await RealmBackgroundActor.shared.cachedRealm(for: replacementConfiguration)
        let url = URL(string: "https://example.com/captured-reader-stores/\(UUID().uuidString)")!
        let primary = configured(Bookmark(), url: url, title: "Primary")
        let history = configured(HistoryRecord(), url: url)
        let providerRecord = configured(Bookmark(), url: url)
        let replacementRecord = configured(Bookmark(), url: url, title: "Replacement store")
        try await seed([primary, history], in: capturedRealm)
        try await seed([providerRecord], in: providerRealm)
        try await seed([replacementRecord], in: replacementRealm)
        XCTAssertEqual(primary.compoundKey, providerRecord.compoundKey)
        XCTAssertEqual(primary.createdAt, providerRecord.createdAt)
        let providerReference = try XCTUnwrap(ReaderContentLoader.ContentReference(content: providerRecord))
        ReaderContentLoader.additionalContentProviders = [.init(id: "captured-provider") { _ in
            [providerReference]
        }]
        let context = ReaderContentLoader.ReaderModePropagationContext(primaryContent: primary)
        let primarySeeded = try journalState(for: primary, in: capturedRealm)
        let historySeeded = try journalState(for: history, in: capturedRealm)
        let providerSeeded = try journalState(for: providerRecord, in: providerRealm)
        let replacementSeeded = try journalState(for: replacementRecord, in: replacementRealm)

        ReaderContentLoader.bookmarkRealmConfiguration = replacementConfiguration
        ReaderContentLoader.historyRealmConfiguration = replacementConfiguration
        ReaderContentLoader.feedEntryRealmConfiguration = replacementConfiguration
        ReaderContentLoader.additionalContentProviders = [.init(id: "replacement-provider") { _ in
            XCTFail("An existing propagation must retain its captured provider registration")
            return []
        }]
        let changedCount = try await ReaderContentLoader.propagateReaderModeDefaults(
            for: url, context: context, readabilityHTML: html, resolvedTitle: "Captured title"
        )

        XCTAssertEqual(changedCount, 2)
        XCTAssertEqual(history.html, html)
        XCTAssertEqual(providerRecord.html, html)
        XCTAssertNotEqual(try journalState(for: history, in: capturedRealm).generation, historySeeded.generation)
        XCTAssertNotEqual(try journalState(for: providerRecord, in: providerRealm).generation, providerSeeded.generation)
        XCTAssertEqual(try journalState(for: primary, in: capturedRealm), primarySeeded)
        XCTAssertFalse(replacementRecord.isReaderModeByDefault)
        XCTAssertNil(replacementRecord.html)
        XCTAssertEqual(try journalState(for: replacementRecord, in: replacementRealm), replacementSeeded)
    }

    @RealmBackgroundActor
    private func assertCapturedProviderRejectsChangedRow(
        change: (Realm, Bookmark) throws -> Bookmark
    ) async throws {
        let mainConfiguration = makeConfiguration()
        let providerConfiguration = makeConfiguration()
        let restore = install(mainConfiguration)
        defer { restore() }
        let mainRealm = try await RealmBackgroundActor.shared.cachedRealm(for: mainConfiguration)
        let providerRealm = try await RealmBackgroundActor.shared.cachedRealm(for: providerConfiguration)
        let url = URL(string: "https://example.com/provider-row-identity/\(UUID().uuidString)")!
        let primary = configured(HistoryRecord(), url: url, title: "Primary")
        let provided = configured(Bookmark(), url: url)
        try await seed([primary], in: mainRealm)
        try await seed([provided], in: providerRealm)
        let capturedReference = try XCTUnwrap(ReaderContentLoader.ContentReference(content: provided))
        let gate = ReaderModePropagationProviderGate()
        ReaderContentLoader.additionalContentProviders = [.init(id: "suspended-provider") { _ in
            await gate.pause()
            return [capturedReference]
        }]
        let context = ReaderContentLoader.ReaderModePropagationContext(primaryContent: primary)
        let capturedHTML = html
        let propagation = Task { @RealmBackgroundActor in
            try await ReaderContentLoader.propagateReaderModeDefaults(
                for: url, context: context, readabilityHTML: capturedHTML, resolvedTitle: "Obsolete title"
            )
        }
        guard await awaitProvider(gate, task: propagation) else { return }
        let changedRecord = try await providerRealm.asyncWrite {
            let record = try change(providerRealm, provided)
            record.refreshChangeMetadata(explicitlyModified: true)
            return record
        }
        let title = changedRecord.title
        let currentURL = changedRecord.url
        let createdAt = changedRecord.createdAt
        let changedState = try journalState(for: changedRecord, in: providerRealm)
        await gate.release()

        let changedCount = try await propagation.value

        XCTAssertEqual(changedCount, 0)
        XCTAssertEqual(changedRecord.title, title)
        XCTAssertEqual(changedRecord.url, currentURL)
        XCTAssertEqual(changedRecord.createdAt, createdAt)
        XCTAssertFalse(changedRecord.isReaderModeByDefault)
        XCTAssertNil(changedRecord.html)
        XCTAssertEqual(try journalState(for: changedRecord, in: providerRealm), changedState)
    }

    @RealmBackgroundActor
    func testProviderCannotReturnARecreatedRowUnderItsEarlierReference() async throws {
        try await assertCapturedProviderRejectsChangedRow { realm, original in
            let replacement = self.configured(Bookmark(), url: original.url, title: "Replacement")
            replacement.createdAt = original.createdAt.addingTimeInterval(1)
            XCTAssertEqual(replacement.compoundKey, original.compoundKey)
            // Model acknowledged cleanup followed by a different creation.
            realm.delete(original)
            realm.add(replacement)
            return replacement
        }
    }

    @RealmBackgroundActor
    func testProviderCannotRetargetCapturedContentByChangingItsURL() async throws {
        try await assertCapturedProviderRejectsChangedRow { _, record in
            // URL edits can retain a stable record key; the captured URL still
            // owns which reader document may supply this record's HTML.
            record.url = URL(string: "https://example.com/retargeted/\(UUID().uuidString)")!
            return record
        }
    }

    @RealmBackgroundActor
    func testSamePathStoreReplacementAfterDiscoveryPreservesBothStores() async throws {
        let configuration = try diskConfiguration()
        let restore = install(configuration)
        defer { restore() }
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        let url = URL(string: "https://example.com/replaced-reader-store/\(UUID().uuidString)")!
        let primary = configured(HistoryRecord(), url: url, title: "Primary")
        let related = configured(Bookmark(), url: url)
        try await seed([primary, related], in: realm)
        let primarySeeded = try journalState(for: primary, in: realm)
        let relatedSeeded = try journalState(for: related, in: realm)
        let gate = ReaderModePropagationProviderGate()
        ReaderContentLoader.additionalContentProviders = [.init(id: "replace-after-discovery") { _ in
            await gate.pause()
            return []
        }]
        let context = ReaderContentLoader.ReaderModePropagationContext(primaryContent: primary)
        let capturedHTML = html
        let propagation = Task { @RealmBackgroundActor in
            try await ReaderContentLoader.propagateReaderModeDefaults(
                for: url, context: context, readabilityHTML: capturedHTML, resolvedTitle: "Obsolete title"
            )
        }
        // This registers cancellation, gate release, and task joining after the
        // disk fixture's cleanup, so they run first during reverse-order teardown.
        guard await awaitProvider(gate, task: propagation) else { return }
        let replacementBytes = try replaceFileWithCopy(configuration)
        await gate.release()

        do {
            _ = try await propagation.value
            XCTFail("Captured propagation must reject a different file at its original path")
        } catch RealmBackgroundActorError.realmFileChangedDuringOpen {
            // A storage incarnation mismatch must reject before either store is written.
        } catch {
            XCTFail("Unexpected storage rejection: \(error)")
        }

        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(configuration.fileURL)), replacementBytes)
        // These objects still belong to the actor's original open Realm.
        XCTAssertFalse(related.isReaderModeByDefault)
        XCTAssertTrue(related.isReaderModeAvailable)
        XCTAssertNil(related.html)
        XCTAssertEqual(related.title, "")
        XCTAssertEqual(try journalState(for: related, in: realm), relatedSeeded)
        XCTAssertFalse(primary.isReaderModeByDefault)
        XCTAssertTrue(primary.isReaderModeAvailable)
        XCTAssertNil(primary.html)
        XCTAssertEqual(primary.title, "Primary")
        XCTAssertEqual(try journalState(for: primary, in: realm), primarySeeded)
    }

    @RealmBackgroundActor
    func testQueuedWriterRejectsARecreatedCandidateAfterDiscovery() async throws {
        let configuration = makeConfiguration()
        let restore = install(configuration)
        defer { restore() }
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        let url = URL(string: "https://example.com/queued-reader-identity/\(UUID().uuidString)")!
        let primary = configured(HistoryRecord(), url: url, title: "Primary")
        let related = configured(Bookmark(), url: url)
        try await seed([primary, related], in: realm)
        let gate = ReaderModePropagationProviderGate()
        ReaderContentLoader.additionalContentProviders = [.init(id: "pause-after-discovery") { _ in
            await gate.pause()
            return []
        }]
        let context = ReaderContentLoader.ReaderModePropagationContext(primaryContent: primary)
        let submitted = expectation(description: "propagation submitted its own SDK write ticket")
        submitted.assertForOverFulfill = false
        let capturedHTML = html
        let propagation = Task { @RealmBackgroundActor in
            try await RealmWriteSubmissionObservation.$willSubmit.withValue({ submitted.fulfill() }) {
                try await ReaderContentLoader.propagateReaderModeDefaults(
                    for: url, context: context, readabilityHTML: capturedHTML, resolvedTitle: "Obsolete title"
                )
            }
        }
        guard await awaitProvider(gate, task: propagation) else { return }
        try realm.beginWrite()
        defer { if realm.isInWriteTransaction { realm.cancelWrite() } }
        await gate.release()
        await fulfillment(of: [submitted], timeout: 2)
        XCTAssertTrue(realm.isInWriteTransaction)
        guard realm.isInWriteTransaction else { return }
        let replacement = configured(Bookmark(), url: url, title: "Replacement")
        replacement.createdAt = related.createdAt.addingTimeInterval(1)
        XCTAssertEqual(replacement.compoundKey, related.compoundKey)
        realm.delete(related)
        realm.add(replacement)
        replacement.refreshChangeMetadata(explicitlyModified: true)
        let seeded = try journalState(for: replacement, in: realm)
        try realm.commitWrite()

        let changedCount = try await propagation.value

        XCTAssertEqual(changedCount, 0)
        XCTAssertEqual(replacement.title, "Replacement")
        XCTAssertFalse(replacement.isReaderModeByDefault)
        XCTAssertNil(replacement.html)
        XCTAssertEqual(try journalState(for: replacement, in: realm), seeded)
    }

    @RealmBackgroundActor
    func testCancellationOfQueuedPropagationPreservesTheOtherOwnersTransaction() async throws {
        let configuration = makeConfiguration()
        let restore = install(configuration)
        defer { restore() }
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        let url = URL(string: "https://example.com/queued-reader-cancel/\(UUID().uuidString)")!
        let primary = configured(HistoryRecord(), url: url, title: "Primary")
        let related = configured(Bookmark(), url: url)
        try await seed([primary, related], in: realm)
        let seeded = try journalState(for: related, in: realm)
        let gate = ReaderModePropagationProviderGate()
        ReaderContentLoader.additionalContentProviders = [.init(id: "pause-after-discovery") { _ in
            await gate.pause()
            return []
        }]
        let context = ReaderContentLoader.ReaderModePropagationContext(primaryContent: primary)
        let submitted = expectation(description: "cancelled propagation submitted its own SDK write ticket")
        submitted.assertForOverFulfill = false
        let capturedHTML = html
        let propagation = Task { @RealmBackgroundActor in
            try await RealmWriteSubmissionObservation.$willSubmit.withValue({ submitted.fulfill() }) {
                try await ReaderContentLoader.propagateReaderModeDefaults(
                    for: url, context: context, readabilityHTML: capturedHTML, resolvedTitle: "Cancelled title"
                )
            }
        }
        guard await awaitProvider(gate, task: propagation) else { return }
        try realm.beginWrite()
        defer { if realm.isInWriteTransaction { realm.cancelWrite() } }
        primary.title = "Another owner's pending edit"
        await gate.release()
        await fulfillment(of: [submitted], timeout: 2)
        propagation.cancel()
        do {
            _ = try await propagation.value
            XCTFail("Cancellation before owned admission must reject propagation")
        } catch is CancellationError { }

        XCTAssertTrue(realm.isInWriteTransaction)
        XCTAssertEqual(primary.title, "Another owner's pending edit")
        XCTAssertFalse(related.isReaderModeByDefault)
        XCTAssertNil(related.html)
        XCTAssertEqual(try journalState(for: related, in: realm), seeded)
        guard realm.isInWriteTransaction else { return }
        primary.refreshChangeMetadata(explicitlyModified: true)
        try realm.commitWrite()
        XCTAssertEqual(primary.title, "Another owner's pending edit")
    }

    @RealmBackgroundActor
    func testFeedPropagationJournalsOnlyChangedOwnersAndPreservesPreferences() async throws {
        // Adapt the real owner-journal regressions from LakeOfFire #262.
        for defaultMode in [false, true] {
            for entryHasContent in [false, true] {
                for feedHasFullContent in [false, true] {
                    let configuration = makeConfiguration()
                    let restore = install(configuration)
                    defer { restore() }
                    let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
                    let url = URL(string: "https://example.com/feed-owner-journal/\(UUID().uuidString)")!
                    let primary = configured(HistoryRecord(), url: url, title: "Primary")
                    let feed = Feed()
                    feed.rssUrl = url.appendingPathExtension("rss")
                    feed.isReaderModeByDefault = defaultMode
                    feed.rssContainsFullContent = feedHasFullContent
                    let entry = FeedEntry()
                    entry.feedID = feed.id
                    entry.url = url
                    entry.title = entryHasContent ? "Existing entry title" : ""
                    let existingHTML = "<p>Existing complete feed article.</p>"
                    if entryHasContent { entry.html = existingHTML }
                    entry.updateCompoundKey()
                    let seedDate = Date(timeIntervalSince1970: 1_700_000_000)
                    try await realm.asyncWritePreservingOwnership {
                        realm.add(primary)
                        primary.refreshChangeMetadata(explicitlyModified: true, at: seedDate)
                        realm.add(feed)
                        feed.refreshChangeMetadata(explicitlyModified: true, at: seedDate)
                        realm.add(entry)
                        entry.refreshChangeMetadata(explicitlyModified: true, at: seedDate)
                    }
                    let context = ReaderContentLoader.ReaderModePropagationContext(primaryContent: primary)
                    let primarySeeded = try journalState(for: primary, in: realm)
                    let feedSeeded = try journalState(for: feed, in: realm)
                    let entrySeeded = try journalState(for: entry, in: realm)

                    let changedCount = try await ReaderContentLoader.propagateReaderModeDefaults(
                        for: url, context: context, readabilityHTML: html, resolvedTitle: "Inferred entry title"
                    )

                    XCTAssertEqual(changedCount, entryHasContent && feedHasFullContent ? 0 : 1,
                                   "One related candidate may change its own fields, its Feed, or both")
                    XCTAssertEqual(feed.isReaderModeByDefault, defaultMode)
                    XCTAssertEqual(entry.isReaderModeByDefault, defaultMode)
                    XCTAssertEqual(entry.isReaderModeAvailable, defaultMode)
                    XCTAssertEqual(entry.html, entryHasContent ? existingHTML : html)
                    XCTAssertEqual(entry.title, entryHasContent ? "Existing entry title" : "Inferred entry title")
                    XCTAssertTrue(feed.rssContainsFullContent)
                    XCTAssertEqual(try journalState(for: primary, in: realm), primarySeeded)
                    let feedChanged = try journalState(for: feed, in: realm)
                    let entryChanged = try journalState(for: entry, in: realm)
                    if feedHasFullContent {
                        XCTAssertEqual(feedChanged, feedSeeded)
                    } else {
                        XCTAssertNotEqual(feedChanged.generation, feedSeeded.generation)
                    }
                    if entryHasContent {
                        XCTAssertEqual(entryChanged, entrySeeded)
                    } else {
                        XCTAssertNotEqual(entryChanged.generation, entrySeeded.generation)
                    }
                    if !feedHasFullContent && !entryHasContent {
                        XCTAssertEqual(entryChanged.changedAt, feedChanged.changedAt,
                                       "Both changed owners must use the same admitted batch timestamp")
                    }

                    let repeatedCount = try await ReaderContentLoader.propagateReaderModeDefaults(
                        for: url, context: context, readabilityHTML: html, resolvedTitle: "Inferred entry title"
                    )
                    XCTAssertEqual(repeatedCount, 0)
                    XCTAssertEqual(try journalState(for: entry, in: realm), entryChanged)
                    XCTAssertEqual(try journalState(for: feed, in: realm), feedChanged)
                    XCTAssertEqual(try journalState(for: primary, in: realm), primarySeeded)
                }
            }
        }
    }

    @RealmBackgroundActor
    func testFeedPropagationPreservesMissingAndDeletedParents() async throws {
        for hasDeletedFeed in [false, true] {
            let configuration = makeConfiguration()
            let restore = install(configuration)
            defer { restore() }
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            let url = URL(string: "https://example.com/missing-feed-owner/\(UUID().uuidString)")!
            let primary = configured(HistoryRecord(), url: url, title: "Primary")
            let feed = Feed()
            feed.rssUrl = url.appendingPathExtension("rss")
            feed.isReaderModeByDefault = false
            feed.isDeleted = true
            let entry = FeedEntry()
            entry.feedID = feed.id
            entry.url = url
            entry.title = "Existing entry title"
            entry.html = "<p>Existing complete article.</p>"
            entry.updateCompoundKey()
            try await realm.asyncWritePreservingOwnership {
                realm.add(primary)
                primary.refreshChangeMetadata(explicitlyModified: true)
                if hasDeletedFeed {
                    realm.add(feed)
                    feed.refreshChangeMetadata(explicitlyModified: true)
                }
                realm.add(entry)
                entry.refreshChangeMetadata(explicitlyModified: true)
            }
            let context = ReaderContentLoader.ReaderModePropagationContext(primaryContent: primary)
            let primarySeeded = try journalState(for: primary, in: realm)
            let entrySeeded = try journalState(for: entry, in: realm)
            let feedSeeded: JournalState?
            if hasDeletedFeed {
                feedSeeded = try journalState(for: feed, in: realm)
            } else {
                feedSeeded = nil
            }

            let changedCount = try await ReaderContentLoader.propagateReaderModeDefaults(
                for: url, context: context, readabilityHTML: html, resolvedTitle: "Later title"
            )

            XCTAssertEqual(changedCount, 0)
            XCTAssertEqual(entry.html, "<p>Existing complete article.</p>")
            XCTAssertEqual(entry.title, "Existing entry title")
            XCTAssertEqual(try journalState(for: entry, in: realm), entrySeeded)
            XCTAssertEqual(try journalState(for: primary, in: realm), primarySeeded)
            if let feedSeeded {
                XCTAssertTrue(feed.isDeleted)
                XCTAssertFalse(feed.rssContainsFullContent)
                XCTAssertFalse(feed.isReaderModeByDefault)
                XCTAssertEqual(try journalState(for: feed, in: realm), feedSeeded)
            } else {
                XCTAssertNil(entry.getFeed())
                XCTAssertTrue(realm.objects(Feed.self).isEmpty)
            }
        }
    }

    @RealmBackgroundActor
    func testCanonicalHistoryAndHTTPFeedFallbackReceiveHTML() async throws {
        let configuration = makeConfiguration()
        let restore = install(configuration)
        defer { restore() }
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        let url = URL(string: "https://example.com/canonical-reader/\(UUID().uuidString)")!
        let loaderURL = try XCTUnwrap(ReaderContentLoader.readerLoaderURL(for: url))
        let primary = configured(Bookmark(), url: url, title: "Primary")
        let legacyHistory = configured(HistoryRecord(), url: loaderURL)
        try await seed([primary, legacyHistory], in: realm)
        let feed = Feed()
        feed.title = "Publisher"
        feed.rssUrl = URL(string: "https://example.com/rss")!
        feed.iconUrl = URL(string: "https://example.com/icon.png")!
        // Keep this case focused on canonical discovery; owner-journal cases
        // above separately exercise changing the parent full-content policy.
        feed.rssContainsFullContent = true
        let entry = FeedEntry()
        entry.feedID = feed.id
        var components = URLComponents(url: url, resolvingAgainstBaseURL: true)!
        components.scheme = "http"
        entry.url = try XCTUnwrap(components.url)
        entry.updateCompoundKey()
        try await realm.asyncWrite {
            realm.add(feed)
            feed.refreshChangeMetadata(explicitlyModified: true)
            realm.add(entry)
            entry.refreshChangeMetadata(explicitlyModified: true)
        }
        let context = ReaderContentLoader.ReaderModePropagationContext(primaryContent: primary)
        let primarySeeded = try journalState(for: primary, in: realm)

        let changedCount = try await ReaderContentLoader.propagateReaderModeDefaults(
            for: url, context: context, readabilityHTML: html, resolvedTitle: "Canonical title"
        )

        XCTAssertEqual(changedCount, 2)
        XCTAssertEqual(legacyHistory.url, loaderURL)
        XCTAssertEqual(legacyHistory.html, html)
        XCTAssertEqual(legacyHistory.title, "Canonical title")
        XCTAssertEqual(entry.url.scheme, "http")
        XCTAssertEqual(entry.html, html)
        XCTAssertEqual(entry.title, "Canonical title")
        XCTAssertEqual(try journalState(for: primary, in: realm), primarySeeded)
    }
}
