import BigSyncKit
import Foundation
@testable import LakeKit
@testable import LakeOfFireContent
import RealmSwift
@testable import RealmSwiftGaps
import XCTest

private actor TranscriptDeletionGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private enum TranscriptDeletionFixtureError: Error {
    case providerUnavailable
}

private actor TranscriptDeletionRetryingProvider {
    private var shouldFail = true

    func load() throws -> [ReaderContentLoader.ContentReference] {
        if shouldFail {
            shouldFail = false
            throw TranscriptDeletionFixtureError.providerUnavailable
        }
        return []
    }
}

/// Only supplies a captured account value to LakeKit's actual publication API.
/// All replacement calls occur at deterministic, suspended or synchronous hooks.
private final class TranscriptDeletionAccountFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var value: AccountSessionSnapshot

    init(_ value: AccountSessionSnapshot) { self.value = value }

    var snapshot: AccountSessionSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func replace(with replacement: AccountSessionSnapshot) {
        lock.lock()
        defer { lock.unlock() }
        value = replacement
    }

    var access: AccountSessionAccess {
        AccountSessionAccess(testSnapshotProvider: { self.snapshot })
    }
}

/// Real Realm, production cleanup and mutation-journal regressions. The account
/// fixture is deterministic; these methods do not authenticate or use CloudKit.
@MainActor
final class ReaderTranscriptDeletionAdmissionTests: XCTestCase {
    private struct Fixture: @unchecked Sendable {
        let historyConfiguration: Realm.Configuration
        let feedConfiguration: Realm.Configuration
        let transcriptConfiguration: Realm.Configuration
        let additionalConfiguration: Realm.Configuration
        let history: Realm
        let feed: Realm
        let transcripts: Realm
        let additional: Realm
    }

    private func configuration(_ types: [Object.Type]) -> Realm.Configuration {
        var result = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        result.objectTypes = types + [BigSyncPendingMutation.self]
        return result
    }

    private func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        let historyConfiguration = configuration([
            Bookmark.self, HistoryRecord.self, ContentFile.self, ContentPackageFile.self,
        ])
        let feedConfiguration = configuration([FeedEntry.self])
        let transcriptConfiguration = configuration([MediaTranscript.self])
        let additionalConfiguration = configuration([Bookmark.self])
        let configurations = [historyConfiguration, feedConfiguration,
                              transcriptConfiguration, additionalConfiguration]
        BigSyncMutationTracking.install(configurations: configurations, excludedClassNames: [])
        let fixture = Fixture(
            historyConfiguration: historyConfiguration,
            feedConfiguration: feedConfiguration,
            transcriptConfiguration: transcriptConfiguration,
            additionalConfiguration: additionalConfiguration,
            history: try await Realm(configuration: historyConfiguration, actor: MainActor.shared),
            feed: try await Realm(configuration: feedConfiguration, actor: MainActor.shared),
            transcripts: try await Realm(configuration: transcriptConfiguration, actor: MainActor.shared),
            additional: try await Realm(configuration: additionalConfiguration, actor: MainActor.shared)
        )
        let previousHistory = ReaderContentLoader.historyRealmConfiguration
        let previousFeed = ReaderContentLoader.feedEntryRealmConfiguration
        let previousTranscript = ReaderContentLoader.transcriptRealmConfiguration
        let previousProviders = ReaderContentLoader.additionalContentProviders
        ReaderContentLoader.historyRealmConfiguration = historyConfiguration
        ReaderContentLoader.feedEntryRealmConfiguration = feedConfiguration
        ReaderContentLoader.transcriptRealmConfiguration = transcriptConfiguration
        ReaderContentLoader.additionalContentProviders = []
        defer {
            ReaderContentLoader.historyRealmConfiguration = previousHistory
            ReaderContentLoader.feedEntryRealmConfiguration = previousFeed
            ReaderContentLoader.transcriptRealmConfiguration = previousTranscript
            ReaderContentLoader.additionalContentProviders = previousProviders
        }
        do { try await body(fixture) }
        catch {
            for configuration in configurations {
                await RealmBackgroundActor.shared.removeCachedRealm(for: configuration)
            }
            throw error
        }
        for configuration in configurations {
            await RealmBackgroundActor.shared.removeCachedRealm(for: configuration)
        }
    }

    private func capture(_ fixture: Fixture) -> ReaderContentLoader.TranscriptDeletionContext {
        ReaderContentLoader.TranscriptDeletionContext(
            historyRealmConfiguration: fixture.historyConfiguration,
            ownerHistoryRealmConfiguration: ReaderContentLoader.historyRealmConfiguration
        )
    }

    private func transcript(_ fixture: Fixture, name: String = "one") throws -> MediaTranscript {
        let transcript = MediaTranscript()
        transcript.contentURL = try XCTUnwrap(URL(string: "https://example.com/" + name))
        transcript.stableMediaIdentity = "settings-fixture:" + name
        transcript.updateCompoundKey()
        try fixture.transcripts.write {
            fixture.transcripts.add(transcript)
            transcript.refreshChangeMetadata(explicitlyModified: true)
        }
        return transcript
    }

    private func generation(_ realm: Realm, _ type: Object.Type, _ key: String) throws -> String {
        realm.refresh()
        return try XCTUnwrap(realm.object(ofType: BigSyncPendingMutation.self,
            forPrimaryKey: type.className() + "." + key)).generation
    }

    private func clean(
        _ urls: [URL],
        context: ReaderContentLoader.TranscriptDeletionContext,
        account: TranscriptDeletionAccountFixture,
        captured: AccountSessionSnapshot
    ) async throws {
        try await ReaderContentLoader.softDeleteTranscriptsIfNoRemainingOwners(
            contentURLs: urls, context: context,
            accountSessionAccess: account.access, accountSession: captured
        )
    }

    private func assertCancelled(_ operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected retired cleanup") }
        catch is CancellationError { }
        catch { XCTFail("Unexpected failure: \(error)") }
    }

    private func assertStorageRejected(_ operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected retired store") }
        catch RealmBackgroundActorError.realmFileChangedDuringOpen { }
        catch { XCTFail("Unexpected failure: \(error)") }
    }

    func testStableSignedOutAndAuthenticatedBatchesJournalOnceAndRetryIsNoOp() async throws {
        for identity in [AccountSessionIdentity.signedOut, .authenticated(userID: 1)] {
            try await withFixture { f in
                let first = try transcript(f, name: "a")
                let second = try transcript(f, name: "b")
                let urls = [second.contentURL, first.contentURL, first.contentURL]
                let initial = try generation(f.transcripts, MediaTranscript.self, first.compoundKey)
                let captured = AccountSessionSnapshot(identity: identity, generation: 7)
                let account = TranscriptDeletionAccountFixture(captured)
                let context = capture(f)
                try await clean(urls, context: context, account: account, captured: captured)
                f.transcripts.refresh()
                XCTAssertTrue(first.isDeleted)
                XCTAssertTrue(second.isDeleted)
                let firstGeneration = try generation(f.transcripts, MediaTranscript.self, first.compoundKey)
                let secondGeneration = try generation(f.transcripts, MediaTranscript.self, second.compoundKey)
                let firstModified = first.modifiedAt, secondModified = second.modifiedAt
                XCTAssertNotEqual(firstGeneration, initial)
                try await clean(urls, context: context, account: account, captured: captured)
                XCTAssertEqual(try generation(f.transcripts, MediaTranscript.self, first.compoundKey), firstGeneration)
                XCTAssertEqual(try generation(f.transcripts, MediaTranscript.self, second.compoundKey), secondGeneration)
                XCTAssertEqual(first.modifiedAt, firstModified)
                XCTAssertEqual(second.modifiedAt, secondModified)
            }
        }
    }

    func testTransitioningAndAlreadyReplacedAccountsCannotBeginCleanup() async throws {
        for transitioning in [false, true] {
            try await withFixture { f in
                let row = try transcript(f)
                let before = try generation(f.transcripts, MediaTranscript.self, row.compoundKey)
                let captured = AccountSessionSnapshot(
                    identity: transitioning ? .transitioning : .authenticated(userID: 1), generation: 3
                )
                let current = transitioning ? captured
                    : AccountSessionSnapshot(identity: .authenticated(userID: 1), generation: 4)
                let account = TranscriptDeletionAccountFixture(current)
                let context = capture(f)
                await assertCancelled {
                    try await clean([row.contentURL], context: context, account: account, captured: captured)
                }
                await assertCancelled {
                    try await clean([], context: context, account: account, captured: captured)
                }
                f.transcripts.refresh()
                XCTAssertFalse(row.isDeleted)
                XCTAssertEqual(try generation(f.transcripts, MediaTranscript.self, row.compoundKey), before)
            }
        }
    }

    func testAccountReplacementAndABAWhileProviderSuspendsRetireCapturedCleanup() async throws {
        let replacements = [
            AccountSessionSnapshot(identity: .authenticated(userID: 2), generation: 2),
            AccountSessionSnapshot(identity: .authenticated(userID: 1), generation: 3),
            AccountSessionSnapshot(identity: .signedOut, generation: 2),
        ]
        for replacement in replacements {
            try await withFixture { f in
                let row = try transcript(f)
                let before = try generation(f.transcripts, MediaTranscript.self, row.compoundKey)
                let captured = AccountSessionSnapshot(identity: .authenticated(userID: 1), generation: 1)
                let account = TranscriptDeletionAccountFixture(captured)
                let entered = expectation(description: "provider entered")
                let release = TranscriptDeletionGate()
                ReaderContentLoader.additionalContentProviders = [
                    ReaderContentAdditionalProvider(id: "held") { _ in
                        entered.fulfill()
                        await release.wait()
                        return []
                    },
                ]
                let context = capture(f), url = row.contentURL
                let cleanup = Task { try await clean([url], context: context, account: account, captured: captured) }
                await fulfillment(of: [entered], timeout: 2)
                account.replace(with: .init(identity: .transitioning, generation: 2))
                account.replace(with: replacement)
                await release.open()
                await assertCancelled { try await cleanup.value }
                f.transcripts.refresh()
                XCTAssertFalse(row.isDeleted)
                XCTAssertEqual(try generation(f.transcripts, MediaTranscript.self, row.compoundKey), before)
            }
        }
    }

    func testCapturedHistoryFeedAndTranscriptSelectionsCannotBeReplacedDuringProviderAwait() async throws {
        for selection in ["history", "feed", "transcript"] {
            try await withFixture { f in
                let row = try transcript(f)
                let before = try generation(f.transcripts, MediaTranscript.self, row.compoundKey)
                let captured = AccountSessionSnapshot(identity: .signedOut, generation: 0)
                let account = TranscriptDeletionAccountFixture(captured)
                let entered = expectation(description: "provider entered")
                let release = TranscriptDeletionGate()
                ReaderContentLoader.additionalContentProviders = [
                    ReaderContentAdditionalProvider(id: "held") { _ in
                        entered.fulfill()
                        await release.wait()
                        return []
                    },
                ]
                let replacementConfiguration = configuration([
                    Bookmark.self, HistoryRecord.self, ContentFile.self, ContentPackageFile.self,
                    FeedEntry.self, MediaTranscript.self,
                ])
                let replacementRealm = try await Realm(configuration: replacementConfiguration, actor: MainActor.shared)
                let replacement = MediaTranscript()
                replacement.compoundKey = row.compoundKey
                replacement.contentURL = row.contentURL
                try replacementRealm.write { replacementRealm.add(replacement) }
                let context = capture(f), url = row.contentURL
                let cleanup = Task { try await clean([url], context: context, account: account, captured: captured) }
                await fulfillment(of: [entered], timeout: 2)
                if selection == "history" { ReaderContentLoader.historyRealmConfiguration = replacementConfiguration }
                if selection == "feed" { ReaderContentLoader.feedEntryRealmConfiguration = replacementConfiguration }
                if selection == "transcript" { ReaderContentLoader.transcriptRealmConfiguration = replacementConfiguration }
                await release.open()
                await assertStorageRejected { try await cleanup.value }
                f.transcripts.refresh()
                XCTAssertFalse(row.isDeleted)
                XCTAssertFalse(replacement.isDeleted)
                XCTAssertEqual(try generation(f.transcripts, MediaTranscript.self, row.compoundKey), before)
            }
        }
    }

    func testCapturedProviderRegistrationStillPreservesItsLiveOwner() async throws {
        try await withFixture { f in
            let row = try transcript(f)
            let before = try generation(f.transcripts, MediaTranscript.self, row.compoundKey)
            let owner = Bookmark()
            owner.url = row.contentURL
            owner.updateCompoundKey()
            try f.additional.write { f.additional.add(owner) }
            let reference = try XCTUnwrap(ReaderContentLoader.ContentReference(content: owner))
            ReaderContentLoader.additionalContentProviders = [
                ReaderContentAdditionalProvider(id: "captured") { _ in [reference] },
            ]
            let context = capture(f)
            ReaderContentLoader.additionalContentProviders = []
            let captured = AccountSessionSnapshot(identity: .signedOut, generation: 0)
            try await clean([row.contentURL], context: context,
                            account: TranscriptDeletionAccountFixture(captured), captured: captured)
            f.transcripts.refresh()
            XCTAssertFalse(row.isDeleted)
            XCTAssertEqual(try generation(f.transcripts, MediaTranscript.self, row.compoundKey), before)
        }
    }

    func testExistingTranscriptFileReplacementCannotBeAdoptedByCapturedContext() async throws {
        try await withFixture { f in
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("TranscriptDeletionAdmission." + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let sourceURL = root.appendingPathComponent("source.realm")
            let replacementURL = root.appendingPathComponent("replacement.realm")
            let retiredURL = root.appendingPathComponent("retired.realm")
            var sourceConfiguration = Realm.Configuration(fileURL: sourceURL)
            sourceConfiguration.objectTypes = [MediaTranscript.self, BigSyncPendingMutation.self]
            var replacementConfiguration = sourceConfiguration
            replacementConfiguration.fileURL = replacementURL
            BigSyncMutationTracking.install(configurations: [sourceConfiguration, replacementConfiguration],
                                             excludedClassNames: [])
            let sourceRealm = try await Realm(configuration: sourceConfiguration, actor: MainActor.shared)
            let replacementRealm = try await Realm(configuration: replacementConfiguration, actor: MainActor.shared)
            let original = MediaTranscript()
            original.contentURL = try XCTUnwrap(URL(string: "https://example.com/physical-replacement"))
            original.stableMediaIdentity = "fixture"
            original.updateCompoundKey()
            let replacement = MediaTranscript()
            replacement.contentURL = original.contentURL
            replacement.compoundKey = original.compoundKey
            replacement.createdAt = original.createdAt
            try sourceRealm.write {
                sourceRealm.add(original)
                original.refreshChangeMetadata(explicitlyModified: true)
            }
            try replacementRealm.write {
                replacementRealm.add(replacement)
                replacement.refreshChangeMetadata(explicitlyModified: true)
            }
            let originalGeneration = try generation(sourceRealm, MediaTranscript.self, original.compoundKey)
            let replacementGeneration = try generation(replacementRealm, MediaTranscript.self, replacement.compoundKey)
            ReaderContentLoader.transcriptRealmConfiguration = sourceConfiguration
            let context = capture(f)
            try FileManager.default.moveItem(at: sourceURL, to: retiredURL)
            do { try FileManager.default.moveItem(at: replacementURL, to: sourceURL) }
            catch {
                try FileManager.default.moveItem(at: retiredURL, to: sourceURL)
                throw error
            }
            defer {
                try? FileManager.default.moveItem(at: sourceURL, to: replacementURL)
                try? FileManager.default.moveItem(at: retiredURL, to: sourceURL)
            }
            let captured = AccountSessionSnapshot(identity: .signedOut, generation: 0)
            await assertStorageRejected {
                try await clean([original.contentURL], context: context,
                                account: TranscriptDeletionAccountFixture(captured), captured: captured)
            }
            XCTAssertFalse(original.isDeleted)
            XCTAssertFalse(replacement.isDeleted)
            XCTAssertEqual(try generation(sourceRealm, MediaTranscript.self, original.compoundKey), originalGeneration)
            XCTAssertEqual(try generation(replacementRealm, MediaTranscript.self, replacement.compoundKey), replacementGeneration)
        }
    }

    func testCleanupFailureAndRetryPreservePreviouslyCommittedSourceTombstone() async throws {
        try await withFixture { f in
            let row = try transcript(f)
            let source = HistoryRecord()
            source.url = row.contentURL
            source.updateCompoundKey()
            try f.history.write {
                f.history.add(source)
                source.isDeleted = true
                source.refreshChangeMetadata(explicitlyModified: true)
            }
            let sourceGeneration = try generation(f.history, HistoryRecord.self, source.compoundKey)
            let sourceModified = source.modifiedAt
            let provider = TranscriptDeletionRetryingProvider()
            ReaderContentLoader.additionalContentProviders = [
                ReaderContentAdditionalProvider(id: "transient") { _ in try await provider.load() },
            ]
            let context = capture(f), captured = AccountSessionSnapshot(identity: .signedOut, generation: 0)
            let account = TranscriptDeletionAccountFixture(captured)
            do {
                try await clean([row.contentURL], context: context, account: account, captured: captured)
                XCTFail("The first provider lookup must report its failure")
            } catch TranscriptDeletionFixtureError.providerUnavailable { }
            f.history.refresh()
            f.transcripts.refresh()
            XCTAssertTrue(source.isDeleted)
            XCTAssertFalse(row.isDeleted)
            XCTAssertEqual(try generation(f.history, HistoryRecord.self, source.compoundKey), sourceGeneration)
            try await clean([row.contentURL], context: context, account: account, captured: captured)
            f.transcripts.refresh()
            XCTAssertTrue(row.isDeleted)
            let transcriptGeneration = try generation(f.transcripts, MediaTranscript.self, row.compoundKey)
            try await clean([row.contentURL], context: context, account: account, captured: captured)
            XCTAssertEqual(try generation(f.transcripts, MediaTranscript.self, row.compoundKey), transcriptGeneration)
            XCTAssertEqual(try generation(f.history, HistoryRecord.self, source.compoundKey), sourceGeneration)
            XCTAssertEqual(source.modifiedAt, sourceModified)
        }
    }

    func testMissingProviderReferenceIsRecheckedAfterQueuedWriteAdmission() async throws {
        try await withFixture { f in
            let row = try transcript(f)
            let owner = Bookmark()
            owner.url = row.contentURL
            owner.updateCompoundKey()
            try f.additional.write { f.additional.add(owner) }
            let reference = try XCTUnwrap(ReaderContentLoader.ContentReference(content: owner))
            let ownerKey = owner.compoundKey, ownerURL = owner.url
            try f.additional.write { f.additional.delete(owner) }
            ReaderContentLoader.additionalContentProviders = [
                ReaderContentAdditionalProvider(id: "missing") { _ in [reference] },
            ]
            let captured = AccountSessionSnapshot(identity: .signedOut, generation: 0)
            let account = TranscriptDeletionAccountFixture(captured)
            let context = capture(f), url = row.contentURL
            let submitted = expectation(description: "cleanup write queued")
            f.transcripts.beginWrite()
            let cleanup = Task {
                try await RealmWriteSubmissionObservation.$willSubmit.withValue({ submitted.fulfill() }) {
                    try await clean([url], context: context, account: account, captured: captured)
                }
            }
            await fulfillment(of: [submitted], timeout: 2)
            do {
                let replacement = Bookmark()
                replacement.compoundKey = ownerKey
                replacement.url = ownerURL
                try f.additional.write { f.additional.add(replacement) }
                try f.transcripts.commitWrite()
                try await cleanup.value
            } catch {
                if f.transcripts.isInWriteTransaction { f.transcripts.cancelWrite() }
                cleanup.cancel()
                _ = try? await cleanup.value
                throw error
            }
            f.transcripts.refresh()
            XCTAssertFalse(row.isDeleted)
        }
    }

    func testFinalPublicationRejectionRollsBackTranscriptMetadataAndJournal() async throws {
        try await withFixture { f in
            let row = try transcript(f)
            let before = try generation(f.transcripts, MediaTranscript.self, row.compoundKey)
            let modifiedAt = row.modifiedAt
            let captured = AccountSessionSnapshot(identity: .authenticated(userID: 1), generation: 1)
            let account = TranscriptDeletionAccountFixture(captured)
            let context = capture(f), url = row.contentURL
            await assertCancelled {
                try await ReaderContentLoader.TranscriptDeletionObservation.$beforeCommit.withValue({
                    account.replace(with: .init(identity: .authenticated(userID: 1), generation: 2))
                }) {
                    try await clean([url], context: context, account: account, captured: captured)
                }
            }
            f.transcripts.refresh()
            XCTAssertFalse(row.isDeleted)
            XCTAssertEqual(row.modifiedAt, modifiedAt)
            XCTAssertEqual(try generation(f.transcripts, MediaTranscript.self, row.compoundKey), before)
        }
    }

    func testFinalStoreSelectionReplacementRollsBackTentativeTranscript() async throws {
        for selection in ["history", "feed", "transcript"] {
            try await withFixture { f in
                let row = try transcript(f)
                let before = try generation(f.transcripts, MediaTranscript.self, row.compoundKey)
                let modifiedAt = row.modifiedAt
                let captured = AccountSessionSnapshot(identity: .signedOut, generation: 0)
                let account = TranscriptDeletionAccountFixture(captured)
                let context = capture(f), url = row.contentURL
                await assertStorageRejected {
                    try await ReaderContentLoader.TranscriptDeletionObservation.$beforeCommit.withValue({
                        if selection == "history" {
                            ReaderContentLoader.historyRealmConfiguration = f.additionalConfiguration
                        } else if selection == "feed" {
                            ReaderContentLoader.feedEntryRealmConfiguration = f.additionalConfiguration
                        } else {
                            ReaderContentLoader.transcriptRealmConfiguration = f.additionalConfiguration
                        }
                    }) {
                        try await clean([url], context: context, account: account, captured: captured)
                    }
                }
                f.transcripts.refresh()
                XCTAssertFalse(row.isDeleted)
                XCTAssertEqual(row.modifiedAt, modifiedAt)
                XCTAssertEqual(try generation(f.transcripts, MediaTranscript.self, row.compoundKey), before)
            }
        }
    }

    func testFinalPhysicalProviderReplacementCannotCommitCapturedTranscriptDeletion() async throws {
        try await withFixture { f in
            let row = try transcript(f)
            let before = try generation(f.transcripts, MediaTranscript.self, row.compoundKey)
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("TranscriptProviderAdmission." + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let sourceURL = root.appendingPathComponent("source.realm")
            let replacementURL = root.appendingPathComponent("replacement.realm")
            let retiredURL = root.appendingPathComponent("retired.realm")
            var sourceConfiguration = Realm.Configuration(fileURL: sourceURL)
            sourceConfiguration.objectTypes = [Bookmark.self, BigSyncPendingMutation.self]
            var replacementConfiguration = sourceConfiguration
            replacementConfiguration.fileURL = replacementURL
            let sourceRealm = try await Realm(configuration: sourceConfiguration, actor: MainActor.shared)
            let replacementRealm = try await Realm(configuration: replacementConfiguration, actor: MainActor.shared)
            let oldOwner = Bookmark()
            oldOwner.url = row.contentURL
            oldOwner.updateCompoundKey()
            oldOwner.isDeleted = true
            let newOwner = Bookmark()
            newOwner.url = oldOwner.url
            newOwner.compoundKey = oldOwner.compoundKey
            newOwner.createdAt = oldOwner.createdAt
            try sourceRealm.write { sourceRealm.add(oldOwner) }
            try replacementRealm.write { replacementRealm.add(newOwner) }
            let reference = try XCTUnwrap(ReaderContentLoader.ContentReference(content: oldOwner))
            ReaderContentLoader.additionalContentProviders = [
                ReaderContentAdditionalProvider(id: "physical-provider") { _ in [reference] },
            ]
            let captured = AccountSessionSnapshot(identity: .signedOut, generation: 0)
            let account = TranscriptDeletionAccountFixture(captured)
            let context = capture(f), url = row.contentURL
            func restoreProviderFiles() throws {
                guard FileManager.default.fileExists(atPath: retiredURL.path) else { return }
                try FileManager.default.moveItem(at: sourceURL, to: replacementURL)
                try FileManager.default.moveItem(at: retiredURL, to: sourceURL)
            }
            do {
                await assertStorageRejected {
                    try await ReaderContentLoader.TranscriptDeletionObservation.$beforeCommit.withValue({
                        try FileManager.default.moveItem(at: sourceURL, to: retiredURL)
                        do { try FileManager.default.moveItem(at: replacementURL, to: sourceURL) }
                        catch {
                            try FileManager.default.moveItem(at: retiredURL, to: sourceURL)
                            throw error
                        }
                    }) {
                        try await clean([url], context: context, account: account, captured: captured)
                    }
                }
                f.transcripts.refresh()
                XCTAssertFalse(row.isDeleted)
                XCTAssertFalse(newOwner.isDeleted)
                XCTAssertEqual(try generation(f.transcripts, MediaTranscript.self, row.compoundKey), before)
                try restoreProviderFiles()
            } catch {
                try? restoreProviderFiles()
                await RealmBackgroundActor.shared.removeCachedRealm(for: sourceConfiguration)
                throw error
            }
            await RealmBackgroundActor.shared.removeCachedRealm(for: sourceConfiguration)
        }
    }

    func testCancellationAtFinalPublicationRollsBackTentativeTombstone() async throws {
        try await withFixture { f in
            let row = try transcript(f)
            let before = try generation(f.transcripts, MediaTranscript.self, row.compoundKey)
            let captured = AccountSessionSnapshot(identity: .signedOut, generation: 0)
            let account = TranscriptDeletionAccountFixture(captured)
            let context = capture(f), url = row.contentURL
            let cleanup = Task {
                try await ReaderContentLoader.TranscriptDeletionObservation.$beforeCommit.withValue({
                    withUnsafeCurrentTask { $0?.cancel() }
                }) {
                    try await clean([url], context: context, account: account, captured: captured)
                }
            }
            await assertCancelled { try await cleanup.value }
            f.transcripts.refresh()
            XCTAssertFalse(row.isDeleted)
            XCTAssertEqual(try generation(f.transcripts, MediaTranscript.self, row.compoundKey), before)
        }
    }

    func testOneCommittedCleanupSucceedsDespitePostCommitRetirementOrCancellation() async throws {
        for cancel in [false, true] {
            try await withFixture { f in
                let row = try transcript(f)
                let captured = AccountSessionSnapshot(identity: .signedOut, generation: 0)
                let account = TranscriptDeletionAccountFixture(captured)
                let context = capture(f), url = row.contentURL
                let cleanup = Task {
                    try await ReaderContentLoader.TranscriptDeletionObservation.$didCommit.withValue({
                        if cancel { withUnsafeCurrentTask { $0?.cancel() } }
                        else { account.replace(with: .init(identity: .transitioning, generation: 1)) }
                    }) {
                        try await clean([url], context: context, account: account, captured: captured)
                    }
                }
                try await cleanup.value
                f.transcripts.refresh()
                XCTAssertTrue(row.isDeleted)
                _ = try generation(f.transcripts, MediaTranscript.self, row.compoundKey)
            }
        }
    }

    func testLaterRetirementReportsExactRemainingURLsWithoutUndoingEarlierCommit() async throws {
        for cancel in [false, true] {
            try await withFixture { f in
                let first = try transcript(f, name: "a")
                let second = try transcript(f, name: "b")
                let firstURL = first.contentURL, secondURL = second.contentURL
                let captured = AccountSessionSnapshot(identity: .signedOut, generation: 0)
                let account = TranscriptDeletionAccountFixture(captured)
                let context = capture(f)
                let cleanup = Task {
                    try await ReaderContentLoader.TranscriptDeletionObservation.$didCommit.withValue({
                        if cancel { withUnsafeCurrentTask { $0?.cancel() } }
                        else { account.replace(with: .init(identity: .transitioning, generation: 1)) }
                    }) {
                        try await clean([secondURL, firstURL], context: context, account: account, captured: captured)
                    }
                }
                do {
                    try await cleanup.value
                    XCTFail("The remaining URL must retain its cleanup requirement")
                } catch let error as ReaderContentLoader.TranscriptDeletionBatchError {
                    XCTAssertEqual(error.completedURLs, [firstURL])
                    XCTAssertEqual(error.remainingURLs, [secondURL])
                    XCTAssertTrue(error.underlyingError is CancellationError)
                    f.transcripts.refresh()
                    XCTAssertTrue(first.isDeleted)
                    XCTAssertFalse(second.isDeleted)
                    let firstGeneration = try generation(f.transcripts, MediaTranscript.self, first.compoundKey)
                    if cancel {
                        try await clean(error.remainingURLs, context: context, account: account, captured: captured)
                        f.transcripts.refresh()
                        XCTAssertTrue(second.isDeleted)
                    } else {
                        await assertCancelled {
                            try await clean(error.remainingURLs, context: context, account: account, captured: captured)
                        }
                    }
                    XCTAssertEqual(try generation(f.transcripts, MediaTranscript.self, first.compoundKey), firstGeneration)
                }
            }
        }
    }

    func testCancelledQueuedCleanupPreservesForeignOwnedWriteAndCanRetry() async throws {
        try await withFixture { f in
            let row = try transcript(f)
            let before = try generation(f.transcripts, MediaTranscript.self, row.compoundKey)
            let captured = AccountSessionSnapshot(identity: .signedOut, generation: 0)
            let account = TranscriptDeletionAccountFixture(captured)
            let context = capture(f), url = row.contentURL
            let configuration = f.transcriptConfiguration, key = row.compoundKey
            try await { @RealmBackgroundActor in
                let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
                let row = try XCTUnwrap(realm.object(ofType: MediaTranscript.self, forPrimaryKey: key))
                realm.beginWrite()
                row.isDeleted = true
                row.refreshChangeMetadata(explicitlyModified: true)
            }()
            let submitted = expectation(description: "cleanup begin ticket submitted")
            let settled = expectation(description: "cancelled cleanup settled")
            let cleanup = Task {
                defer { settled.fulfill() }
                try await RealmWriteSubmissionObservation.$willSubmit.withValue({ submitted.fulfill() }) {
                    try await clean([url], context: context, account: account, captured: captured)
                }
            }
            await fulfillment(of: [submitted], timeout: 2)
            cleanup.cancel()
            await fulfillment(of: [settled], timeout: 2)
            let preserved = try await { @RealmBackgroundActor in
                let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
                let row = realm.object(ofType: MediaTranscript.self, forPrimaryKey: key)
                let result = realm.isInWriteTransaction && row?.isDeleted == true
                if realm.isInWriteTransaction { realm.cancelWrite() }
                return result
            }()
            await assertCancelled { try await cleanup.value }
            XCTAssertTrue(preserved)
            f.transcripts.refresh()
            XCTAssertFalse(row.isDeleted)
            XCTAssertEqual(try generation(f.transcripts, MediaTranscript.self, row.compoundKey), before)
            try await clean([url], context: context, account: account, captured: captured)
            f.transcripts.refresh()
            XCTAssertTrue(row.isDeleted)
        }
    }
}
