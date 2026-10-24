import Foundation
import BigSyncKit
import RealmSwift
@testable import RealmSwiftGaps
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireContentUI

/// Exercises the real public bookmark commands. A separate synchronous Realm
/// writer holds admission; no test copy of the add/remove decision is involved.
@MainActor
final class BookmarkToggleOwnedWriteTests: XCTestCase {
    func testOverlappingTogglesFromUnsavedStateLeaveOneJournaledTombstone() async throws {
        try await assertOverlappingToggles(initiallySaved: false)
    }

    func testOverlappingTogglesFromSavedStateResurrectTheSameBookmark() async throws {
        try await assertOverlappingToggles(initiallySaved: true)
    }

    func testCancellationWhileQueuedDoesNotMutateOrJournalAndPreservesOtherWriter() async throws {
        let fixture = try await makeFixture()
        defer { fixture.restoreGlobals() }
        let source = makeHistory(url: "https://example.com/cancelled-queued-toggle")
        let other = makeHistory(url: "https://example.com/other-writer")
        let otherKey = other.compoundKey
        try fixture.realm.write { fixture.realm.add(other) }

        let barrier = BookmarkToggleWriterBarrier()
        let owner = Task {
            try await barrier.hold(configuration: fixture.configuration) { realm in
                let current = try XCTUnwrap(realm.object(ofType: HistoryRecord.self, forPrimaryKey: otherKey))
                current.title = "Other writer committed"
            }
        }
        defer { barrier.release() }
        await fulfillment(of: [barrier.entered], timeout: 5)
        let submitted = expectation(description: "Toggle queued behind the other writer")
        submitted.assertForOverFulfill = false
        let settled = expectation(description: "Cancelled queued toggle settled before the other writer released")
        let toggle = Task { @MainActor in
            defer { settled.fulfill() }
            return try await RealmWriteSubmissionObservation.$willSubmit.withValue({ submitted.fulfill() }) {
                try await source.toggleBookmark(realmConfiguration: fixture.configuration)
            }
        }
        addTeardownBlock {
            barrier.release()
            _ = await toggle.result
            _ = await owner.result
        }

        await fulfillment(of: [submitted], timeout: 5)
        toggle.cancel()
        // Bound the settlement assertion while the unrelated write stays open.
        // Even a regression releases that owner after the expectation fails.
        await fulfillment(of: [settled], timeout: 5)
        barrier.release()
        try await owner.value
        do {
            _ = try await toggle.value
            XCTFail("A cancelled queued toggle must not acquire mutation authority")
        } catch is CancellationError { }
        await fixture.realm.asyncRefresh()
        XCTAssertEqual(other.title, "Other writer committed")
        XCTAssertTrue(fixture.realm.objects(Bookmark.self).isEmpty)
        XCTAssertTrue(fixture.realm.objects(BigSyncPendingMutation.self).isEmpty)
    }

    func testQueuedToggleRejectsReplacementOfConfiguredBookmarkStore() async throws {
        let fixture = try await makeFixture()
        defer { fixture.restoreGlobals() }
        var replacementConfiguration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        replacementConfiguration.objectTypes = [Bookmark.self, HistoryRecord.self]
        configureLakeOfFireMutationTrackingForTesting(&replacementConfiguration)
        BigSyncMutationTracking.install(
            configurations: [fixture.configuration, replacementConfiguration],
            excludedClassNames: []
        )
        let replacementRealm = try await Realm(configuration: replacementConfiguration, actor: MainActor.shared)
        let source = makeHistory(url: "https://example.com/replaced-configured-store")
        let other = makeHistory(url: "https://example.com/configured-store-other-writer")
        let otherKey = other.compoundKey
        try fixture.realm.write { fixture.realm.add(other) }

        let barrier = BookmarkToggleWriterBarrier()
        let owner = Task {
            try await barrier.hold(configuration: fixture.configuration) { realm in
                let current = try XCTUnwrap(realm.object(ofType: HistoryRecord.self, forPrimaryKey: otherKey))
                current.title = "Other writer committed after store replacement"
            }
        }
        defer { barrier.release() }
        await fulfillment(of: [barrier.entered], timeout: 5)
        let submitted = expectation(description: "Toggle captured the configured store before replacement")
        submitted.assertForOverFulfill = false
        let toggle = Task { @MainActor in
            try await RealmWriteSubmissionObservation.$willSubmit.withValue({ submitted.fulfill() }) {
                try await source.toggleBookmark(realmConfiguration: fixture.configuration)
            }
        }
        addTeardownBlock {
            barrier.release()
            _ = await toggle.result
            _ = await owner.result
        }
        await fulfillment(of: [submitted], timeout: 5)
        ReaderContentLoader.bookmarkRealmConfiguration = replacementConfiguration
        barrier.release()
        try await owner.value
        do {
            _ = try await toggle.value
            XCTFail("A queued command must not write after its configured store is replaced")
        } catch is CancellationError { }
        await fixture.realm.asyncRefresh()
        await replacementRealm.asyncRefresh()
        XCTAssertEqual(other.title, "Other writer committed after store replacement")
        XCTAssertTrue(fixture.realm.objects(Bookmark.self).isEmpty)
        XCTAssertTrue(fixture.realm.objects(BigSyncPendingMutation.self).isEmpty)
        XCTAssertTrue(replacementRealm.objects(Bookmark.self).isEmpty)
        XCTAssertTrue(replacementRealm.objects(BigSyncPendingMutation.self).isEmpty)
    }

    func testQueuedToggleRejectsSourceDeletedBeforeAdmission() async throws {
        try await assertQueuedToggleRejectsReplacedSource(recreate: false)
    }

    func testQueuedToggleCannotAdoptRecreatedSourceWithSameKeyAndCreationDate() async throws {
        try await assertQueuedToggleRejectsReplacedSource(recreate: true)
    }

    func testQueuedToggleOfManagedBookmarkCannotDeleteRecreatedTarget() async throws {
        try await assertQueuedManagedBookmarkToggleRejectsRecreatedTarget()
    }

    func testToggleRejectsSourceInCallerOwnedWriteWithoutEndingThatWrite() async throws {
        let fixture = try await makeFixture()
        defer { fixture.restoreGlobals() }
        let source = makeHistory(url: "https://example.com/caller-owned-source-write")
        let sourceKey = source.compoundKey
        try fixture.realm.beginWrite()
        defer {
            if fixture.realm.isInWriteTransaction { fixture.realm.cancelWrite() }
        }
        fixture.realm.add(source)
        source.title = "Caller-owned source creation"
        let settled = expectation(description: "Uncommitted source rejected while caller write remains open")
        let toggle = Task { @MainActor in
            defer { settled.fulfill() }
            return try await source.toggleBookmark(realmConfiguration: fixture.configuration)
        }
        addTeardownBlock { _ = await toggle.result }
        // Release the caller's write even if a regression fails this bounded
        // rejection expectation, before awaiting the command's final result.
        await fulfillment(of: [settled], timeout: 5)
        XCTAssertTrue(fixture.realm.isInWriteTransaction)
        XCTAssertFalse(source.isInvalidated)
        if !source.isInvalidated {
            XCTAssertEqual(source.title, "Caller-owned source creation")
        }
        if fixture.realm.isInWriteTransaction { try fixture.realm.commitWrite() }
        do {
            _ = try await toggle.value
            XCTFail("A source inside the caller's uncommitted write is not an admitted command")
        } catch is CancellationError { }
        await fixture.realm.asyncRefresh()
        let committed = try XCTUnwrap(fixture.realm.object(ofType: HistoryRecord.self, forPrimaryKey: sourceKey))
        XCTAssertEqual(committed.title, "Caller-owned source creation")
        XCTAssertEqual(fixture.realm.objects(HistoryRecord.self).count, 1)
        XCTAssertTrue(fixture.realm.objects(Bookmark.self).isEmpty)
        XCTAssertTrue(fixture.realm.objects(BigSyncPendingMutation.self).isEmpty)
    }

    func testCancellationAfterCommitSubmissionReturnsDurableToggleResult() async throws {
        let fixture = try await makeFixture()
        defer { fixture.restoreGlobals() }
        let source = makeHistory(url: "https://example.com/commit-submitted-toggle")
        let task = Task { @MainActor in
            try await RealmWriteCommitObservation.$didSubmit.withValue({
                withUnsafeCurrentTask { $0?.cancel() }
            }) {
                try await source.toggleBookmark(realmConfiguration: fixture.configuration)
            }
        }
        let saved = try await task.value
        XCTAssertTrue(saved)
        XCTAssertTrue(task.isCancelled)
        await fixture.realm.asyncRefresh()
        XCTAssertEqual(fixture.realm.objects(Bookmark.self).count, 1)
        let bookmark = try XCTUnwrap(fixture.realm.objects(Bookmark.self).first)
        XCTAssertFalse(bookmark.isDeleted)
        XCTAssertEqual(bookmark.url, source.url)
        let mutation = try XCTUnwrap(pendingMutation(for: bookmark, in: fixture.realm))
        XCTAssertEqual(mutation.changedAt, bookmark.explicitlyModifiedAt)
    }

    func testToggleResurrectionPreservesMainMetadataAndCreationIdentity() async throws {
        let fixture = try await makeFixture()
        defer { fixture.restoreGlobals() }
        let source = makeHistory(url: "https://example.com/toggle-metadata")
        source.title = "Saved title"
        source.isReaderModeOfferHidden = true
        source.isReaderModeByDefault = true
        source.isReaderModeAvailable = true
        source.feedEntryCollectionKey = "collection-key"
        source.feedEntryCollectionScheme = "https://example.com/collection-scheme"
        source.feedEntryCollectionTerm = "collection-term"
        source.feedEntryCollectionTitle = "Collection title"
        source.voiceAudioURL = URL(string: "https://example.com/audio-primary.mp3")!
        source.voiceAudioURLs.append(objectsIn: [
            URL(string: "https://example.com/audio-primary.mp3")!,
            URL(string: "https://example.com/audio-alternate.mp3")!,
        ])
        source.audioSubtitlesURL = URL(string: "https://example.com/captions.vtt")!
        source.redditTranslationsTitle = "Translated text"
        source.autoOpenMediaPlayer = true
        let bookmark = makeBookmark(url: source.url)
        bookmark.createdAt = Date(timeIntervalSinceReferenceDate: 123)
        bookmark.isDeleted = true
        let key = bookmark.compoundKey
        let createdAt = bookmark.createdAt
        try fixture.realm.write { fixture.realm.add(bookmark) }

        let result = try await source.toggleBookmark(realmConfiguration: fixture.configuration)
        XCTAssertTrue(result)
        await fixture.realm.asyncRefresh()
        let saved = try XCTUnwrap(fixture.realm.object(ofType: Bookmark.self, forPrimaryKey: key))
        XCTAssertEqual(fixture.realm.objects(Bookmark.self).count, 1)
        XCTAssertEqual(saved.createdAt, createdAt)
        XCTAssertFalse(saved.isDeleted)
        XCTAssertEqual(saved.title, source.title)
        XCTAssertTrue(saved.isReaderModeOfferHidden)
        XCTAssertTrue(saved.isReaderModeByDefault)
        XCTAssertTrue(saved.isReaderModeAvailable)
        XCTAssertEqual(saved.feedEntryCollectionKey, source.feedEntryCollectionKey)
        XCTAssertEqual(saved.feedEntryCollectionScheme, source.feedEntryCollectionScheme)
        XCTAssertEqual(saved.feedEntryCollectionTerm, source.feedEntryCollectionTerm)
        XCTAssertEqual(saved.feedEntryCollectionTitle, source.feedEntryCollectionTitle)
        XCTAssertEqual(saved.voiceAudioURL, source.voiceAudioURL)
        XCTAssertEqual(Array(saved.voiceAudioURLs), Array(source.voiceAudioURLs))
        XCTAssertEqual(saved.audioSubtitlesURL, source.audioSubtitlesURL)
        XCTAssertEqual(saved.audioSubtitlesRoleRawValue, AudioSubtitlesRole.content.rawValue)
        XCTAssertEqual(saved.redditTranslationsTitle, source.redditTranslationsTitle)
        XCTAssertTrue(saved.autoOpenMediaPlayer)
        let mutation = try XCTUnwrap(pendingMutation(for: saved, in: fixture.realm))
        XCTAssertEqual(mutation.changedAt, saved.explicitlyModifiedAt)
    }

    func testManagedHistoryInSeparateRealmPreservesSuppliedMediaMetadata() async throws {
        let fixture = try await makeFixture()
        defer { fixture.restoreGlobals() }
        var sourceConfiguration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        sourceConfiguration.objectTypes = [HistoryRecord.self]
        configureLakeOfFireMutationTrackingForTesting(&sourceConfiguration)
        BigSyncMutationTracking.install(
            configurations: [fixture.configuration, sourceConfiguration],
            excludedClassNames: []
        )
        let capturedSourceConfiguration = sourceConfiguration
        let sourceRealm = try await Realm(configuration: sourceConfiguration, actor: MainActor.shared)
        addTeardownBlock {
            await RealmBackgroundActor.shared.removeCachedRealm(for: capturedSourceConfiguration)
        }
        ReaderContentLoader.historyRealmConfiguration = sourceConfiguration
        let source = makeHistory(url: "https://example.com/separate-store-media")
        source.voiceFrameUrl = URL(string: "https://example.com/player")!
        source.voiceAudioURL = URL(string: "https://example.com/primary.mp3")!
        source.voiceAudioURLs.append(objectsIn: [
            URL(string: "https://example.com/primary.mp3")!,
            URL(string: "https://example.com/alternate.mp3")!,
        ])
        source.audioSubtitlesURL = URL(string: "https://example.com/transcript.vtt")!
        source.redditTranslationsUrl = URL(string: "https://example.com/translations")!
        source.redditTranslationsTitle = "Supplied translation"
        try sourceRealm.write { sourceRealm.add(source) }

        let completed = expectation(description: "Separate-store history association settled")
        let saved = try await BookmarkAssociationObservation.$completed.withValue({ succeeded in
            XCTAssertTrue(succeeded)
            completed.fulfill()
        }) {
            try await source.toggleBookmark(realmConfiguration: fixture.configuration)
        }
        XCTAssertTrue(saved)
        await fulfillment(of: [completed], timeout: 5)
        await fixture.realm.asyncRefresh()
        await sourceRealm.asyncRefresh()
        let bookmark = try XCTUnwrap(Bookmark.get(forURL: source.url, realm: fixture.realm))
        XCTAssertEqual(bookmark.voiceFrameUrl, source.voiceFrameUrl)
        XCTAssertEqual(bookmark.voiceAudioURL, source.voiceAudioURL)
        XCTAssertEqual(Array(bookmark.voiceAudioURLs), Array(source.voiceAudioURLs))
        XCTAssertEqual(bookmark.audioSubtitlesURL, source.audioSubtitlesURL)
        XCTAssertEqual(bookmark.audioSubtitlesRoleRawValue, AudioSubtitlesRole.content.rawValue)
        XCTAssertEqual(bookmark.redditTranslationsUrl, source.redditTranslationsUrl)
        XCTAssertEqual(bookmark.redditTranslationsTitle, source.redditTranslationsTitle)
        let mutation = try XCTUnwrap(pendingMutation(for: bookmark, in: fixture.realm))
        XCTAssertEqual(mutation.changedAt, bookmark.explicitlyModifiedAt)
        XCTAssertNil(source.bookmarkID)
        XCTAssertTrue(sourceRealm.objects(BigSyncPendingMutation.self).isEmpty)
    }

    func testBookmarkStatusCachePublicAccessorsIgnorePhysicallyInvalidatedSource() async throws {
        let fixture = try await makeFixture()
        defer { fixture.restoreGlobals() }
        let source = makeBookmark(url: URL(string: "https://example.com/invalidated-cache-source")!)
        let sameIdentity = makeBookmark(url: source.url)
        try fixture.realm.write { fixture.realm.add(source) }
        let cache = BookmarkStatusCache()
        cache.setIsBookmarked(true, for: source)
        XCTAssertTrue(cache.isBookmarked(source))
        try fixture.realm.write { fixture.realm.delete(source) }
        XCTAssertTrue(source.isInvalidated)

        XCTAssertFalse(cache.isBookmarked(source))
        cache.setIsBookmarked(false, for: source)
        XCTAssertTrue(cache.isBookmarked(sameIdentity), "An invalidated source cannot alter a cached key")
        cache.setIsBookmarked(false, for: sameIdentity)
        cache.setIsBookmarked(true, for: source)
        XCTAssertFalse(cache.isBookmarked(sameIdentity))
    }

    func testInlineAnalysisFollowsDurableAdditionAndSkipsRemovalOrCancelledToggle() async throws {
        let fixture = try await makeFixture()
        defer { fixture.restoreGlobals() }
        let configuration = fixture.configuration
        let source = makeHistory(url: "https://example.com/inline-analysis-order")
        source.title = "Inline analysis title"
        source.imageUrl = URL(string: "https://example.com/image.jpg")!
        source.html = "<p>Captured inline article</p>"
        source.isDemoted = true
        let sourceKey = source.compoundKey
        let expectedHTML = try XCTUnwrap(source.html)
        try fixture.realm.write { fixture.realm.add(source) }
        let observations = BookmarkToggleAnalysisObservations()
        let previousEnqueuer = ReaderContentBackgroundAnalysisLoader.inlineHTMLAnalysisEnqueuer
        defer { ReaderContentBackgroundAnalysisLoader.inlineHTMLAnalysisEnqueuer = previousEnqueuer }
        ReaderContentBackgroundAnalysisLoader.inlineHTMLAnalysisEnqueuer = { url, imageURL, title, html in
            // Read through the MainActor's Realm after the background writer's
            // settlement. An in-flight mutation alone is not this observation.
            let receipt = await MainActor.run { () -> BookmarkToggleAnalysisReceipt in
                do {
                    let realm = try Realm(configuration: configuration)
                    realm.refresh()
                    let bookmark = Bookmark.get(forURL: url, realm: realm)
                    let history = realm.object(ofType: HistoryRecord.self, forPrimaryKey: sourceKey)
                    return BookmarkToggleAnalysisReceipt(
                        url: url, imageURL: imageURL, title: title, html: html,
                        savedBookmarkVisible: bookmark != nil,
                        savedHTML: bookmark?.html,
                        historyPromoted: history?.isDemoted == false,
                        pendingMutationCount: realm.objects(BigSyncPendingMutation.self).count,
                        error: nil
                    )
                } catch {
                    return BookmarkToggleAnalysisReceipt(
                        url: url, imageURL: imageURL, title: title, html: html,
                        savedBookmarkVisible: false, savedHTML: nil,
                        historyPromoted: false, pendingMutationCount: 0,
                        error: String(describing: error)
                    )
                }
            }
            await observations.append(receipt)
        }

        let associationCompleted = expectation(description: "Inline fixture association eventually settled")
        let saved = try await BookmarkAssociationObservation.$completed.withValue({ _ in
            associationCompleted.fulfill()
        }) {
            try await source.toggleBookmark(realmConfiguration: configuration)
        }
        XCTAssertTrue(saved)
        let afterSave = await observations.values()
        XCTAssertEqual(afterSave.count, 1)
        let receipt = try XCTUnwrap(afterSave.first)
        XCTAssertNil(receipt.error)
        XCTAssertEqual(receipt.url, source.url)
        XCTAssertEqual(receipt.imageURL, source.imageUrl)
        XCTAssertEqual(receipt.title, source.title)
        XCTAssertEqual(receipt.html, expectedHTML)
        XCTAssertTrue(receipt.savedBookmarkVisible)
        XCTAssertEqual(receipt.savedHTML, expectedHTML)
        XCTAssertTrue(receipt.historyPromoted)
        XCTAssertEqual(receipt.pendingMutationCount, 2)

        // Association has its own completion contract. Waiting here only drains
        // fixture work; neither the Bool nor the inline callback must await it.
        await fulfillment(of: [associationCompleted], timeout: 5)

        let removed = try await source.toggleBookmark(realmConfiguration: configuration)
        XCTAssertFalse(removed)
        await fixture.realm.asyncRefresh()
        let bookmark = try XCTUnwrap(fixture.realm.objects(Bookmark.self).first)
        XCTAssertTrue(bookmark.isDeleted)
        let deletionGeneration = try XCTUnwrap(pendingMutation(for: bookmark, in: fixture.realm)?.generation)
        let cancelled = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await source.toggleBookmark(realmConfiguration: configuration)
        }
        do {
            _ = try await cancelled.value
            XCTFail("A pre-cancelled toggle must not resurrect the bookmark")
        } catch is CancellationError { }
        await fixture.realm.asyncRefresh()
        XCTAssertTrue(bookmark.isDeleted)
        XCTAssertEqual(pendingMutation(for: bookmark, in: fixture.realm)?.generation, deletionGeneration)
        let finalReceipts = await observations.values()
        XCTAssertEqual(finalReceipts.count, 1,
                       "Removal and cancelled additions must not enqueue inline analysis")
    }

    func testScheduledAssociationCommitsLinkAndRepeatedAssociationDoesNotRejournal() async throws {
        let fixture = try await makeFixture()
        defer { fixture.restoreGlobals() }
        let history = makeHistory(url: "https://example.com/association-control")
        let target = makeBookmark(url: history.url)
        try fixture.realm.write {
            fixture.realm.add(history)
            fixture.realm.add(target)
        }
        let historyKey = history.compoundKey
        let targetKey = target.compoundKey
        let firstCompleted = expectation(description: "First actual association settled")
        try await scheduleAssociation(
            configuration: fixture.configuration,
            historyKey: historyKey,
            targetKey: targetKey,
            completed: firstCompleted
        )
        await fulfillment(of: [firstCompleted], timeout: 5)
        await fixture.realm.asyncRefresh()
        XCTAssertEqual(history.bookmarkID, targetKey)
        let mutation = try XCTUnwrap(pendingMutation(for: history, in: fixture.realm))
        let generation = mutation.generation
        let modifiedAt = history.modifiedAt
        let explicitlyModifiedAt = history.explicitlyModifiedAt
        XCTAssertEqual(mutation.changedAt, explicitlyModifiedAt)
        XCTAssertNil(pendingMutation(for: target, in: fixture.realm))

        let repeatedCompleted = expectation(description: "Repeated actual association settled")
        try await scheduleAssociation(
            configuration: fixture.configuration,
            historyKey: historyKey,
            targetKey: targetKey,
            completed: repeatedCompleted
        )
        await fulfillment(of: [repeatedCompleted], timeout: 5)
        await fixture.realm.asyncRefresh()
        XCTAssertEqual(history.bookmarkID, targetKey)
        XCTAssertEqual(history.modifiedAt, modifiedAt)
        XCTAssertEqual(history.explicitlyModifiedAt, explicitlyModifiedAt)
        XCTAssertEqual(pendingMutation(for: history, in: fixture.realm)?.generation, generation)
        XCTAssertEqual(fixture.realm.objects(BigSyncPendingMutation.self).count, 1)
    }

    func testScheduledAssociationSkipsTombstonedTargetWithoutChangingHistory() async throws {
        try await assertScheduledAssociationRejectsRetiredTarget(.tombstone)
    }

    func testScheduledAssociationSkipsPhysicallyRemovedTargetWithoutChangingHistory() async throws {
        try await assertScheduledAssociationRejectsRetiredTarget(.remove)
    }

    func testScheduledAssociationCannotAdoptRecreatedTargetWithSameKeyAndCreationDate() async throws {
        try await assertScheduledAssociationRejectsRetiredTarget(.recreate)
    }

    func testScheduledAssociationSkipsRolledBackTargetCreationWithoutChangingHistory() async throws {
        try await assertScheduledAssociationRejectsRolledBackTarget(resurrect: false)
    }

    func testScheduledAssociationSkipsRolledBackTargetResurrectionWithoutRejournaling() async throws {
        try await assertScheduledAssociationRejectsRolledBackTarget(resurrect: true)
    }

    func testScheduledAssociationCannotAdoptReplacementOfRolledBackNewTarget() async throws {
        try await assertScheduledAssociationRejectsRolledBackTarget(
            resurrect: false,
            replaceRolledBackTarget: true
        )
    }

    private func assertOverlappingToggles(initiallySaved: Bool) async throws {
        let fixture = try await makeFixture()
        defer { fixture.restoreGlobals() }
        let source = makeHistory(url: "https://example.com/overlapping-toggles")
        let original = makeBookmark(url: source.url)
        original.createdAt = Date(timeIntervalSinceReferenceDate: 123)
        let originalKey = original.compoundKey
        let originalCreation = original.createdAt
        if initiallySaved {
            try fixture.realm.write {
                fixture.realm.add(original)
                original.refreshChangeMetadata(explicitlyModified: true)
            }
        }
        let initialGeneration = fixture.realm.objects(BigSyncPendingMutation.self).first?.generation
        let barrier = BookmarkToggleWriterBarrier()
        let owner = Task { try await barrier.hold(configuration: fixture.configuration) }
        defer { barrier.release() }
        await fulfillment(of: [barrier.entered], timeout: 5)
        let firstSubmitted = expectation(description: "First toggle submitted")
        let secondSubmitted = expectation(description: "Second toggle submitted")
        firstSubmitted.assertForOverFulfill = false
        secondSubmitted.assertForOverFulfill = false
        let first = Task { @MainActor in
            try await RealmWriteSubmissionObservation.$willSubmit.withValue({ firstSubmitted.fulfill() }) {
                try await source.toggleBookmark(realmConfiguration: fixture.configuration)
            }
        }
        let second = Task { @MainActor in
            try await RealmWriteSubmissionObservation.$willSubmit.withValue({ secondSubmitted.fulfill() }) {
                try await source.toggleBookmark(realmConfiguration: fixture.configuration)
            }
        }
        addTeardownBlock {
            barrier.release()
            _ = await first.result
            _ = await second.result
            _ = await owner.result
        }
        // Both actual commands reached owned transaction submission while the
        // same writer still blocks admission. Neither has selected add/remove.
        await fulfillment(of: [firstSubmitted, secondSubmitted], timeout: 5)
        barrier.release()
        try await owner.value
        let firstResult = try await first.value
        let secondResult = try await second.value
        XCTAssertEqual(Set([firstResult, secondResult]), Set([false, true]))
        await fixture.realm.asyncRefresh()
        XCTAssertEqual(fixture.realm.objects(Bookmark.self).count, 1)
        let bookmark = try XCTUnwrap(fixture.realm.objects(Bookmark.self).first)
        XCTAssertEqual(bookmark.compoundKey, originalKey)
        XCTAssertEqual(bookmark.isDeleted, !initiallySaved)
        if initiallySaved { XCTAssertEqual(bookmark.createdAt, originalCreation) }
        let mutation = try XCTUnwrap(pendingMutation(for: bookmark, in: fixture.realm))
        XCTAssertEqual(mutation.changedAt, bookmark.explicitlyModifiedAt)
        XCTAssertNotEqual(mutation.generation, initialGeneration)
    }

    private func assertQueuedToggleRejectsReplacedSource(recreate: Bool) async throws {
        let fixture = try await makeFixture()
        defer { fixture.restoreGlobals() }
        let source = makeHistory(url: "https://example.com/recreated-source")
        source.createdAt = Date(timeIntervalSinceReferenceDate: 123)
        let sourceKey = source.compoundKey
        let sourceURL = source.url
        let sourceCreation = source.createdAt
        try fixture.realm.write { fixture.realm.add(source) }
        let barrier = BookmarkToggleWriterBarrier()
        let owner = Task {
            try await barrier.hold(configuration: fixture.configuration) { realm in
                let current = try XCTUnwrap(realm.object(ofType: HistoryRecord.self, forPrimaryKey: sourceKey))
                realm.delete(current)
                if recreate {
                    let replacement = HistoryRecord()
                    replacement.url = sourceURL
                    replacement.createdAt = sourceCreation
                    replacement.title = "Replacement source"
                    replacement.updateCompoundKey()
                    XCTAssertEqual(replacement.compoundKey, sourceKey)
                    realm.add(replacement)
                }
            }
        }
        defer { barrier.release() }
        await fulfillment(of: [barrier.entered], timeout: 5)
        let submitted = expectation(description: "Command queued before physical source replacement")
        submitted.assertForOverFulfill = false
        let task = Task { @MainActor in
            try await RealmWriteSubmissionObservation.$willSubmit.withValue({ submitted.fulfill() }) {
                try await source.toggleBookmark(realmConfiguration: fixture.configuration)
            }
        }
        addTeardownBlock {
            barrier.release()
            _ = await task.result
            _ = await owner.result
        }
        await fulfillment(of: [submitted], timeout: 5)
        barrier.release()
        try await owner.value
        do {
            _ = try await task.value
            XCTFail("Queued commands must not adopt a physically replaced source")
        } catch is CancellationError { }
        await fixture.realm.asyncRefresh()
        XCTAssertTrue(source.isInvalidated)
        XCTAssertEqual(fixture.realm.objects(HistoryRecord.self).count, recreate ? 1 : 0)
        if recreate {
            let replacement = try XCTUnwrap(fixture.realm.objects(HistoryRecord.self).first)
            XCTAssertEqual(replacement.title, "Replacement source")
            XCTAssertEqual(replacement.createdAt, sourceCreation)
            XCTAssertNil(replacement.bookmarkID)
        }
        XCTAssertTrue(fixture.realm.objects(Bookmark.self).isEmpty)
        XCTAssertTrue(fixture.realm.objects(BigSyncPendingMutation.self).isEmpty)
    }

    private func assertQueuedManagedBookmarkToggleRejectsRecreatedTarget() async throws {
        let fixture = try await makeFixture()
        defer { fixture.restoreGlobals() }
        let source = makeBookmark(url: URL(string: "https://example.com/recreated-bookmark")!)
        source.createdAt = Date(timeIntervalSinceReferenceDate: 123)
        let key = source.compoundKey
        let url = source.url
        let createdAt = source.createdAt
        try fixture.realm.write { fixture.realm.add(source) }
        let barrier = BookmarkToggleWriterBarrier()
        let owner = Task {
            try await barrier.hold(configuration: fixture.configuration) { realm in
                let original = try XCTUnwrap(realm.object(ofType: Bookmark.self, forPrimaryKey: key))
                realm.delete(original)
                let replacement = Bookmark()
                replacement.url = url
                replacement.createdAt = createdAt
                replacement.title = "Replacement target"
                replacement.updateCompoundKey()
                XCTAssertEqual(replacement.compoundKey, key)
                realm.add(replacement)
            }
        }
        defer { barrier.release() }
        await fulfillment(of: [barrier.entered], timeout: 5)
        let submitted = expectation(description: "Managed target command queued before replacement")
        submitted.assertForOverFulfill = false
        let task = Task { @MainActor in
            try await RealmWriteSubmissionObservation.$willSubmit.withValue({ submitted.fulfill() }) {
                try await source.toggleBookmark(realmConfiguration: fixture.configuration)
            }
        }
        addTeardownBlock {
            barrier.release()
            _ = await task.result
            _ = await owner.result
        }
        await fulfillment(of: [submitted], timeout: 5)
        barrier.release()
        try await owner.value
        do {
            _ = try await task.value
            XCTFail("A command from the old physical bookmark must not delete its replacement")
        } catch is CancellationError { }
        await fixture.realm.asyncRefresh()
        XCTAssertTrue(source.isInvalidated)
        let replacement = try XCTUnwrap(fixture.realm.object(ofType: Bookmark.self, forPrimaryKey: key))
        XCTAssertFalse(replacement.isDeleted)
        XCTAssertEqual(replacement.createdAt, createdAt)
        XCTAssertEqual(replacement.title, "Replacement target")
        XCTAssertTrue(fixture.realm.objects(BigSyncPendingMutation.self).isEmpty)
    }

    private func scheduleAssociation(
        configuration: Realm.Configuration,
        historyKey: String,
        targetKey: String,
        completed: XCTestExpectation
    ) async throws {
        try await { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            await realm.asyncRefresh()
            let history = try XCTUnwrap(realm.object(ofType: HistoryRecord.self, forPrimaryKey: historyKey))
            let target = try XCTUnwrap(realm.object(ofType: Bookmark.self, forPrimaryKey: targetKey))
            BookmarkAssociationObservation.$completed.withValue({ succeeded in
                XCTAssertTrue(succeeded, "A current association must settle successfully")
                completed.fulfill()
            }) {
                history.configureBookmark(target)
            }
        }()
    }

    private func assertScheduledAssociationRejectsRetiredTarget(
        _ disposition: BookmarkAssociationTargetDisposition
    ) async throws {
        let fixture = try await makeFixture()
        defer { fixture.restoreGlobals() }
        let configuration = fixture.configuration
        let history = makeHistory(url: "https://example.com/retired-association-target")
        let target = makeBookmark(url: history.url)
        target.createdAt = Date(timeIntervalSinceReferenceDate: 123)
        let historyKey = history.compoundKey
        let targetKey = target.compoundKey
        let targetURL = target.url
        let targetCreation = target.createdAt
        try fixture.realm.write {
            fixture.realm.add(history)
            fixture.realm.add(target)
        }
        let previousModifiedAt = history.modifiedAt
        let previousExplicitlyModifiedAt = history.explicitlyModifiedAt
        let completed = expectation(description: "Retired-target association settled")
        try await { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            await realm.asyncRefresh()
            let actorHistory = try XCTUnwrap(realm.object(ofType: HistoryRecord.self, forPrimaryKey: historyKey))
            let actorTarget = try XCTUnwrap(realm.object(ofType: Bookmark.self, forPrimaryKey: targetKey))
            // The real association Task inherits this observer. It cannot run
            // on this actor until the synchronous transaction below has retired
            // its captured target and committed the fixture change.
            try realm.write {
                BookmarkAssociationObservation.$completed.withValue({ _ in completed.fulfill() }) {
                    actorHistory.configureBookmark(actorTarget)
                    switch disposition {
                    case .tombstone:
                        actorTarget.isDeleted = true
                        actorTarget.refreshChangeMetadata(explicitlyModified: true)
                    case .remove, .recreate:
                        realm.delete(actorTarget)
                        if disposition == .recreate {
                            let replacement = Bookmark()
                            replacement.url = targetURL
                            replacement.createdAt = targetCreation
                            replacement.title = "Replacement association target"
                            replacement.updateCompoundKey()
                            XCTAssertEqual(replacement.compoundKey, targetKey)
                            realm.add(replacement)
                        }
                    }
                }
            }
        }()
        await fulfillment(of: [completed], timeout: 5)
        await fixture.realm.asyncRefresh()
        XCTAssertNil(history.bookmarkID)
        XCTAssertEqual(history.modifiedAt, previousModifiedAt)
        XCTAssertEqual(history.explicitlyModifiedAt, previousExplicitlyModifiedAt)
        XCTAssertNil(pendingMutation(for: history, in: fixture.realm))
        switch disposition {
        case .tombstone:
            XCTAssertTrue(target.isDeleted)
            let tombstoneMutation = try XCTUnwrap(pendingMutation(for: target, in: fixture.realm))
            XCTAssertEqual(tombstoneMutation.changedAt, target.explicitlyModifiedAt)
            XCTAssertEqual(fixture.realm.objects(BigSyncPendingMutation.self).count, 1)
        case .remove:
            XCTAssertTrue(target.isInvalidated)
            XCTAssertTrue(fixture.realm.objects(Bookmark.self).isEmpty)
            XCTAssertTrue(fixture.realm.objects(BigSyncPendingMutation.self).isEmpty)
        case .recreate:
            XCTAssertTrue(target.isInvalidated)
            let replacement = try XCTUnwrap(fixture.realm.object(ofType: Bookmark.self, forPrimaryKey: targetKey))
            XCTAssertFalse(replacement.isDeleted)
            XCTAssertEqual(replacement.createdAt, targetCreation)
            XCTAssertEqual(replacement.title, "Replacement association target")
            XCTAssertTrue(fixture.realm.objects(BigSyncPendingMutation.self).isEmpty)
        }
    }

    private func assertScheduledAssociationRejectsRolledBackTarget(
        resurrect: Bool,
        replaceRolledBackTarget: Bool = false
    ) async throws {
        let fixture = try await makeFixture()
        defer { fixture.restoreGlobals() }
        let configuration = fixture.configuration
        let history = makeHistory(url: "https://example.com/rolled-back-association-target")
        let target = makeBookmark(url: history.url)
        target.isDeleted = true
        let historyKey = history.compoundKey
        let targetKey = target.compoundKey
        let targetURL = target.url
        let targetCreation = target.createdAt
        try fixture.realm.write {
            fixture.realm.add(history)
            if resurrect {
                fixture.realm.add(target)
                target.refreshChangeMetadata(explicitlyModified: true)
            }
        }
        let previousHistoryModifiedAt = history.modifiedAt
        let previousHistoryExplicitlyModifiedAt = history.explicitlyModifiedAt
        let previousTargetModifiedAt = target.modifiedAt
        let previousTargetExplicitlyModifiedAt = target.explicitlyModifiedAt
        let previousGeneration = resurrect ? pendingMutation(for: target, in: fixture.realm)?.generation : nil
        let completed = expectation(description: "Rolled-back target association settled")
        try await { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            await realm.asyncRefresh()
            let actorHistory = try XCTUnwrap(realm.object(ofType: HistoryRecord.self, forPrimaryKey: historyKey))
            var rolledBackTarget: Bookmark?
            do {
                try realm.write {
                    let actorTarget: Bookmark
                    if resurrect {
                        actorTarget = try XCTUnwrap(realm.object(ofType: Bookmark.self, forPrimaryKey: targetKey))
                        actorTarget.isDeleted = false
                    } else {
                        actorTarget = Bookmark()
                        actorTarget.url = targetURL
                        actorTarget.createdAt = targetCreation
                        actorTarget.updateCompoundKey()
                        realm.add(actorTarget)
                        rolledBackTarget = actorTarget
                    }
                    actorTarget.refreshChangeMetadata(explicitlyModified: true)
                    // The actual association is scheduled while its target is
                    // visible only in this write. Throwing rolls back both the
                    // mutation and its journal before that Task can run here.
                    BookmarkAssociationObservation.$completed.withValue({ succeeded in
                        XCTAssertFalse(succeeded)
                        completed.fulfill()
                    }) {
                        actorHistory.configureBookmark(actorTarget)
                    }
                    throw BookmarkAssociationRollback.requested
                }
            } catch BookmarkAssociationRollback.requested { }
            if replaceRolledBackTarget {
                let retiredTarget = try XCTUnwrap(rolledBackTarget)
                XCTAssertTrue(retiredTarget.isInvalidated)
                // No actor suspension separates rollback and replacement. The
                // deferred association sees identical logical identity only
                // after its original physical accessor has been invalidated.
                try realm.write {
                    let replacement = Bookmark()
                    replacement.url = targetURL
                    replacement.createdAt = targetCreation
                    replacement.title = "Replacement after rollback"
                    replacement.updateCompoundKey()
                    XCTAssertEqual(replacement.compoundKey, targetKey)
                    realm.add(replacement)
                }
                XCTAssertTrue(retiredTarget.isInvalidated)
            }
        }()
        await fulfillment(of: [completed], timeout: 5)
        await fixture.realm.asyncRefresh()
        XCTAssertNil(history.bookmarkID)
        XCTAssertEqual(history.modifiedAt, previousHistoryModifiedAt)
        XCTAssertEqual(history.explicitlyModifiedAt, previousHistoryExplicitlyModifiedAt)
        XCTAssertNil(pendingMutation(for: history, in: fixture.realm))
        if resurrect {
            XCTAssertTrue(target.isDeleted)
            XCTAssertEqual(target.modifiedAt, previousTargetModifiedAt)
            XCTAssertEqual(target.explicitlyModifiedAt, previousTargetExplicitlyModifiedAt)
            XCTAssertEqual(pendingMutation(for: target, in: fixture.realm)?.generation, previousGeneration)
            XCTAssertEqual(fixture.realm.objects(BigSyncPendingMutation.self).count, 1)
        } else if replaceRolledBackTarget {
            let replacement = try XCTUnwrap(fixture.realm.object(ofType: Bookmark.self, forPrimaryKey: targetKey))
            XCTAssertFalse(replacement.isDeleted)
            XCTAssertEqual(replacement.createdAt, targetCreation)
            XCTAssertEqual(replacement.title, "Replacement after rollback")
            XCTAssertEqual(fixture.realm.objects(Bookmark.self).count, 1)
            XCTAssertTrue(fixture.realm.objects(BigSyncPendingMutation.self).isEmpty)
        } else {
            XCTAssertNil(fixture.realm.object(ofType: Bookmark.self, forPrimaryKey: targetKey))
            XCTAssertTrue(fixture.realm.objects(BigSyncPendingMutation.self).isEmpty)
        }
    }

    private func makeHistory(url: String) -> HistoryRecord {
        let source = HistoryRecord()
        source.url = URL(string: url)!
        source.title = "Original source"
        source.updateCompoundKey()
        return source
    }

    private func makeBookmark(url: URL) -> Bookmark {
        let bookmark = Bookmark()
        bookmark.url = url
        bookmark.updateCompoundKey()
        return bookmark
    }

    private func makeFixture() async throws -> BookmarkToggleFixture {
        var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        configuration.objectTypes = [Bookmark.self, HistoryRecord.self]
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        let capturedConfiguration = configuration
        let realm = try await Realm(configuration: configuration, actor: MainActor.shared)
        // A cached actor-owned handle must already exist before another writer
        // holds the lock. Otherwise opening/schema work could mask the boundary.
        try await { @RealmBackgroundActor in
            _ = try await RealmBackgroundActor.shared.cachedRealm(for: capturedConfiguration)
        }()
        addTeardownBlock {
            await RealmBackgroundActor.shared.removeCachedRealm(for: capturedConfiguration)
        }
        let fixture = BookmarkToggleFixture(
            configuration: configuration,
            realm: realm,
            previousBookmarkConfiguration: ReaderContentLoader.bookmarkRealmConfiguration,
            previousHistoryConfiguration: ReaderContentLoader.historyRealmConfiguration
        )
        ReaderContentLoader.bookmarkRealmConfiguration = configuration
        ReaderContentLoader.historyRealmConfiguration = configuration
        return fixture
    }

    private func pendingMutation(for object: Object, in realm: Realm) -> BigSyncPendingMutation? {
        let primaryKey = object.objectSchema.primaryKeyProperty!.name
        let objectIdentifier = String(describing: object[primaryKey]!)
        return realm.object(
            ofType: BigSyncPendingMutation.self,
            forPrimaryKey: object.objectSchema.className + "." + objectIdentifier
        )
    }
}

private struct BookmarkToggleAnalysisReceipt: Sendable {
    let url: URL
    let imageURL: URL?
    let title: String?
    let html: String
    let savedBookmarkVisible: Bool
    let savedHTML: String?
    let historyPromoted: Bool
    let pendingMutationCount: Int
    let error: String?
}

private actor BookmarkToggleAnalysisObservations {
    private var receipts: [BookmarkToggleAnalysisReceipt] = []

    func append(_ receipt: BookmarkToggleAnalysisReceipt) {
        receipts.append(receipt)
    }

    func values() -> [BookmarkToggleAnalysisReceipt] {
        receipts
    }
}

private enum BookmarkAssociationTargetDisposition: Equatable, Sendable {
    case tombstone
    case remove
    case recreate
}

private enum BookmarkAssociationRollback: Error {
    case requested
}

@MainActor
private struct BookmarkToggleFixture {
    let configuration: Realm.Configuration
    let realm: Realm
    let previousBookmarkConfiguration: Realm.Configuration
    let previousHistoryConfiguration: Realm.Configuration

    func restoreGlobals() {
        ReaderContentLoader.bookmarkRealmConfiguration = previousBookmarkConfiguration
        ReaderContentLoader.historyRealmConfiguration = previousHistoryConfiguration
    }
}

/// The external transaction is confined to one synchronous queue callback.
/// The semaphore blocks only that queue, never the MainActor or Realm actor.
private final class BookmarkToggleWriterBarrier: @unchecked Sendable {
    let entered = XCTestExpectation(description: "External bookmark writer entered")
    private let queue = DispatchQueue(label: "LakeOfFireTests.bookmark-toggle-writer")
    private let releaseSemaphore = DispatchSemaphore(value: 0)

    func hold(
        configuration: Realm.Configuration,
        beforeCommit: @escaping @Sendable (Realm) throws -> Void = { _ in }
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                autoreleasepool {
                    do {
                        let realm = try Realm(configuration: configuration)
                        try realm.write {
                            self.entered.fulfill()
                            self.releaseSemaphore.wait()
                            try beforeCommit(realm)
                        }
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    func release() {
        releaseSemaphore.signal()
    }
}
