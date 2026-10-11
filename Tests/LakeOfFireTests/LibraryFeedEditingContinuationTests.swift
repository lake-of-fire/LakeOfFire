import BigSyncKit
import RealmSwift
@testable import RealmSwiftGaps
import XCTest
import LakeOfFireCore
@testable import LakeOfFireContent
@testable import LakeOfFireLibrary

@MainActor
final class LibraryFeedEditingContinuationTests: XCTestCase {
    func testDelayedFieldWriteKeepsCapturedStorageAfterDefaultReplacement() async throws {
        let originalConfiguration = configuration()
        let replacementConfiguration = configuration()
        let original = try await Realm(configuration: originalConfiguration)
        let replacement = try await Realm(configuration: replacementConfiguration)
        let feed = try installFeed(in: original)
        let other = try installFeed(id: feed.id, in: replacement)
        let model = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false)
        let started = expectation(description: "Captured writer suspended")
        let gate = LibraryFeedContinuationGate()
        let writer = model.writeFeedAsync(field: .title, beforeWrite: {
            started.fulfill()
            await gate.wait()
        }) { feed in
            feed.title = "Captured edit"
            return true
        }
        defer { writer.cancel(); Task { await gate.release() } }
        await fulfillment(of: [started], timeout: 5)
        let previous = LibraryDataManager.realmConfiguration
        defer { LibraryDataManager.realmConfiguration = previous }
        LibraryDataManager.realmConfiguration = replacementConfiguration
        await gate.release()
        try await writer.value
        original.refresh()
        replacement.refresh()
        XCTAssertEqual(feed.title, "Captured edit")
        XCTAssertEqual(other.title, "Original")
        XCTAssertTrue(replacement.objects(BigSyncPendingMutation.self).isEmpty)
    }

    func testOlderWriterCannotBeatNewEditorsIntentionalNoOp() async throws {
        let realm = try await Realm(configuration: configuration())
        let feed = try installFeed(in: realm)
        let oldEditor = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false)
        let started = expectation(description: "Older editor suspended")
        let gate = LibraryFeedContinuationGate()
        let older = oldEditor.writeFeedAsync(field: .title, beforeWrite: {
            started.fulfill()
            await gate.wait()
        }) { feed in
            feed.title = "Obsolete"
            return true
        }
        defer { older.cancel(); Task { await gate.release() } }
        await fulfillment(of: [started], timeout: 5)
        let newEditor = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false)
        // Exercise the form publisher itself: the second same-value input is
        // inside the debounce window but reserves its intent synchronously.
        newEditor.feedTitle = "Original"
        newEditor.feedTitle = "Original"
        await gate.release()
        try await older.value
        newEditor.finishEditing()
        try await newEditor.writeFeedAsync { _ in false }.value
        realm.refresh()
        XCTAssertEqual(feed.title, "Original")
        XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
    }

    func testDelayedWriterRejectsReplacementFeedIncarnation() async throws {
        let realm = try await Realm(configuration: configuration())
        let feed = try installFeed(in: realm)
        let id = feed.id
        let categoryID = feed.categoryID
        let createdAt = feed.createdAt
        let model = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false)
        let started = expectation(description: "Writer suspended before record replacement")
        let gate = LibraryFeedContinuationGate()
        let writer = model.writeFeedAsync(field: .title, beforeWrite: {
            started.fulfill()
            await gate.wait()
        }) { feed in
            feed.title = "Obsolete"
            return true
        }
        defer { writer.cancel(); Task { await gate.release() } }
        await fulfillment(of: [started], timeout: 5)
        let replacement = Feed()
        replacement.id = id
        replacement.categoryID = categoryID
        replacement.createdAt = createdAt.addingTimeInterval(1)
        replacement.title = "Replacement"
        try realm.write { realm.delete(feed); realm.add(replacement) }
        await gate.release()
        try await writer.value
        realm.refresh()
        XCTAssertEqual(replacement.title, "Replacement")
        XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
        XCTAssertNil(try model.previewEntries())
    }

    func testDelayedWriterRejectsManagedOrReplacedCategory() async throws {
        for replaceCategory in [false, true] {
            let realm = try await Realm(configuration: configuration())
            let feed = try installFeed(in: realm)
            let category = try XCTUnwrap(feed.getCategory())
            let model = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false)
            let started = expectation(description: "Writer suspended before category change")
            let gate = LibraryFeedContinuationGate()
            let writer = model.writeFeedAsync(field: .title, beforeWrite: {
                started.fulfill()
                await gate.wait()
            }) { feed in
                feed.title = "Obsolete"
                return true
            }
            defer { writer.cancel(); Task { await gate.release() } }
            await fulfillment(of: [started], timeout: 5)
            if replaceCategory {
                let replacement = FeedCategory()
                replacement.id = category.id
                replacement.createdAt = category.createdAt.addingTimeInterval(1)
                try realm.write { realm.delete(category); realm.add(replacement) }
            } else {
                try realm.write { category.opmlURL = URL(string: "https://example.com/managed.opml") }
            }
            await gate.release()
            try await writer.value
            realm.refresh()
            XCTAssertEqual(feed.title, "Original")
            XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
        }
    }

    func testDelayedMetadataCannotFillAfterSourceURLChanges() async throws {
        let realm = try await Realm(configuration: configuration())
        let feed = try installFeed(in: realm, title: "")
        let model = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false)
        let source = feed.rssUrl
        let generation = UUID()
        model.beginMetadataRefresh(rssURL: source, identifier: generation)
        let started = expectation(description: "Metadata fetch suspended")
        let gate = LibraryFeedContinuationGate()
        let metadata = Task { @MainActor in
            await model.refreshFromOpenGraph(expectedRSSURL: source, expectedGeneration: generation) { _ in
                started.fulfill()
                await gate.wait()
                return LibraryFeedOpenGraphMetadata(
                    url: source.domainURL, title: "Old source title", description: "Old description"
                )
            }
        }
        defer { metadata.cancel(); Task { await gate.release() } }
        await fulfillment(of: [started], timeout: 5)
        try await model.pasteRSSURL(strings: ["https://other.example/new.xml"]).value
        await gate.release()
        await metadata.value
        realm.refresh()
        XCTAssertEqual(feed.title, "")
        XCTAssertNil(feed.markdownDescription)
        XCTAssertEqual(feed.rssUrl.absoluteString, "https://other.example/new.xml")
    }

    func testMetadataCannotReplaceAnExplicitEmptyDescriptionEdit() async throws {
        let realm = try await Realm(configuration: configuration())
        let feed = try installFeed(in: realm, title: "Original")
        let model = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false)
        let source = feed.rssUrl
        let generation = UUID()
        model.beginMetadataRefresh(rssURL: source, identifier: generation)
        let started = expectation(description: "Metadata write suspended")
        let gate = LibraryFeedContinuationGate()
        let metadata = Task { @MainActor in
            await model.refreshFromOpenGraph(
                expectedRSSURL: source, expectedGeneration: generation,
                beforeWrite: { started.fulfill(); await gate.wait() }
            ) { _ in
                LibraryFeedOpenGraphMetadata(url: source.domainURL, title: nil, description: "Automatic")
            }
        }
        defer { metadata.cancel(); Task { await gate.release() } }
        await fulfillment(of: [started], timeout: 5)
        model.feedDescription = ""
        await gate.release()
        await metadata.value
        try await model.writeFeedAsync { _ in false }.value
        realm.refresh()
        XCTAssertNotEqual(feed.markdownDescription, "Automatic")
        XCTAssertEqual(model.feedDescription, "")
    }

    func testHydrationDoesNotPublishNewMutations() async throws {
        let realm = try await Realm(configuration: configuration())
        let feed = try installFeed(in: realm)
        let model = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false)
        model.refresh()
        model.finishEditing()
        try await model.writeFeedAsync { _ in false }.value
        realm.refresh()
        XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
        XCTAssertEqual(model.feedTitle, "Original")
    }

    func testLateMetadataCannotOutrankAnotherEditorsEmptyInput() async throws {
        let realm = try await Realm(configuration: configuration())
        let feed = try installFeed(in: realm, title: "")
        let oldEditor = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false)
        let source = feed.rssUrl
        let generation = UUID()
        oldEditor.beginMetadataRefresh(rssURL: source, identifier: generation)
        let started = expectation(description: "Older metadata request suspended")
        let gate = LibraryFeedContinuationGate()
        let metadata = Task { @MainActor in
            await oldEditor.refreshFromOpenGraph(expectedRSSURL: source, expectedGeneration: generation) { _ in
                await gate.wait(onFirstWait: { started.fulfill() })
                return LibraryFeedOpenGraphMetadata(url: source.domainURL, title: "Obsolete", description: nil)
            }
        }
        defer { metadata.cancel(); Task { await gate.release() } }
        await fulfillment(of: [started], timeout: 5)
        let newEditor = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false)
        newEditor.feedTitle = ""
        newEditor.finishEditing()
        try await newEditor.writeFeedAsync { _ in false }.value
        await gate.release()
        await metadata.value
        realm.refresh()
        XCTAssertEqual(feed.title, "")
        XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
    }

    func testRetirementDoesNotReplayCancelledMetadata() async throws {
        let realm = try await Realm(configuration: configuration())
        let feed = try installFeed(in: realm)
        let model = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false)
        let source = feed.rssUrl
        let generation = UUID()
        model.beginMetadataRefresh(rssURL: source, identifier: generation)
        let started = expectation(description: "Metadata attempt suspended before write")
        let gate = LibraryFeedContinuationGate()
        let metadata = Task { @MainActor in
            await model.refreshFromOpenGraph(
                expectedRSSURL: source, expectedGeneration: generation,
                beforeWrite: { started.fulfill(); await gate.wait() }
            ) { _ in
                LibraryFeedOpenGraphMetadata(url: source.domainURL, title: nil, description: "Cancelled")
            }
        }
        defer { metadata.cancel(); Task { await gate.release() } }
        await fulfillment(of: [started], timeout: 5)
        metadata.cancel()
        model.finishEditing()
        try await model.writeFeedAsync { _ in false }.value
        await gate.release()
        await metadata.value
        realm.refresh()
        XCTAssertNil(feed.markdownDescription)
        XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
    }

    // Regression sources only: execution remains on hold.
    private enum InjectedFailure: Error { case admission }

    func testBufferedFailureRetainsDraftAndFinishRetriesWithoutDuplicateActiveWrites() async throws {
        let realm = try await Realm(configuration: configuration())
        let feed = try installFeed(in: realm)
        let started = expectation(description: "Buffered attempt suspended")
        let gate = LibraryFeedContinuationGate()
        defer { Task { await gate.release() } }
        let attempts = LibraryFeedWriteAttempts()
        let model = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false, beforeFieldWrite: {
            if await attempts.record() == 1 {
                started.fulfill()
                await gate.wait()
                throw InjectedFailure.admission
            }
        })
        model.feedTitle = "Retained buffered draft"
        await fulfillment(of: [started], timeout: 5)
        let finish = model.finishEditing()
        let repeatedFinish = model.finishEditing()
        let submittedAttempts = await attempts.count
        XCTAssertEqual(submittedAttempts, 1)
        await gate.release()
        for completion in [finish, repeatedFinish] {
            do { try await completion.value; XCTFail("Admission failure succeeded") }
            catch InjectedFailure.admission {}
        }
        model.refresh()
        XCTAssertEqual(model.feedTitle, "Retained buffered draft")
        realm.refresh()
        XCTAssertEqual(feed.title, "Original")
        XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
        try await model.finishEditing().value
        realm.refresh()
        XCTAssertEqual(feed.title, "Retained buffered draft")
        let retriedAttempts = await attempts.count
        XCTAssertEqual(retriedAttempts, 2)
    }

    func testFinishDoesNotReplaySettledTrailingDebounce() async throws {
        let realm = try await Realm(configuration: configuration())
        let feed = try installFeed(in: realm)
        let attempts = LibraryFeedWriteAttempts()
        let model = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false, beforeFieldWrite: {
            _ = await attempts.record()
        })
        model.feedTitle = "Intermediate"
        model.feedTitle = "Finished draft"
        try await model.finishEditing().value
        let finishedAttempts = await attempts.count
        // Allow the publisher's trailing emission to arrive after durable settlement.
        try await Task.sleep(nanoseconds: 500_000_000)
        try await model.finishEditing().value
        let afterTrailingAttempts = await attempts.count
        XCTAssertEqual(afterTrailingAttempts, finishedAttempts)
        realm.refresh()
        XCTAssertEqual(feed.title, "Finished draft")
    }

    func testImmediateAdmissionFailureRetainsCommandForFinishRetry() async throws {
        let realm = try await Realm(configuration: configuration())
        let feed = try installFeed(in: realm)
        let model = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false)
        do {
            try await model.writeFeedAsync(field: .title, beforeWrite: { throw InjectedFailure.admission }) {
                $0.title = "Retried immediate draft"
                return true
            }.value
            XCTFail("Admission failure succeeded")
        } catch InjectedFailure.admission {}
        realm.refresh()
        XCTAssertEqual(feed.title, "Original")
        XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
        try await model.finishEditing().value
        realm.refresh()
        XCTAssertEqual(feed.title, "Retried immediate draft")
    }

    func testPreAdmissionCancellationRetainsDraftForRetry() async throws {
        let realm = try await Realm(configuration: configuration())
        let feed = try installFeed(in: realm)
        let model = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false)
        let started = expectation(description: "Cancellable writer suspended")
        let gate = LibraryFeedContinuationGate()
        let writer = model.writeFeedAsync(field: .title, beforeWrite: {
            started.fulfill()
            await gate.wait()
        }) {
            $0.title = "Retry cancelled draft"
            return true
        }
        defer { writer.cancel(); Task { await gate.release() } }
        await fulfillment(of: [started], timeout: 5)
        writer.cancel()
        await gate.release()
        do { try await writer.value; XCTFail("Cancelled attempt succeeded") }
        catch is CancellationError {}
        realm.refresh()
        XCTAssertEqual(feed.title, "Original")
        XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
        try await model.finishEditing().value
        realm.refresh()
        XCTAssertEqual(feed.title, "Retry cancelled draft")
    }

    func testCancellingOneFieldAttemptDoesNotCancelAnotherField() async throws {
        let realm = try await Realm(configuration: configuration())
        let feed = try installFeed(in: realm)
        let model = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false)
        let started = expectation(description: "Title attempt suspended")
        let gate = LibraryFeedContinuationGate()
        let title = model.writeFeedAsync(field: .title, beforeWrite: {
            started.fulfill()
            await gate.wait()
        }) { $0.title = "Retained title"; return true }
        defer { title.cancel(); Task { await gate.release() } }
        await fulfillment(of: [started], timeout: 5)
        title.cancel()
        let description = model.writeFeedAsync(field: .description) {
            $0.markdownDescription = "Independent description"
            return true
        }
        try await description.value
        await gate.release()
        do { try await title.value; XCTFail("Cancelled title attempt succeeded") }
        catch is CancellationError {}
        realm.refresh()
        XCTAssertEqual(feed.title, "Original")
        XCTAssertEqual(feed.markdownDescription, "Independent description")
        try await model.finishEditing().value
        realm.refresh()
        XCTAssertEqual(feed.title, "Retained title")
        XCTAssertEqual(feed.markdownDescription, "Independent description")
    }

    func testFinishAwaitsSuccessfulFieldAlongsideEarlierFailureAndRetainsRetry() async throws {
        let realm = try await Realm(configuration: configuration())
        let feed = try installFeed(in: realm)
        let model = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false)
        let failedStarted = expectation(description: "Earlier title attempt suspended")
        let successfulStarted = expectation(description: "Newer description attempt suspended")
        let failedGate = LibraryFeedContinuationGate()
        let successfulGate = LibraryFeedContinuationGate()
        let failed = model.writeFeedAsync(field: .title, beforeWrite: {
            failedStarted.fulfill()
            await failedGate.wait()
            throw InjectedFailure.admission
        }) { $0.title = "Retained mixed-finish draft"; return true }
        defer { failed.cancel(); Task { await failedGate.release() } }
        await fulfillment(of: [failedStarted], timeout: 5)
        let successful = model.writeFeedAsync(field: .description, beforeWrite: {
            successfulStarted.fulfill()
            await successfulGate.wait()
        }) { $0.markdownDescription = "Settled newer field"; return true }
        defer { successful.cancel(); Task { await successfulGate.release() } }
        await fulfillment(of: [successfulStarted], timeout: 5)
        let finish = model.finishEditing()
        let finishSettled = expectation(description: "Finish awaits all captured attempts")
        finishSettled.isInverted = true
        let observedFinish = Task { @MainActor in
            do { try await finish.value; XCTFail("Mixed finish lost admission error") }
            catch InjectedFailure.admission {}
            finishSettled.fulfill()
        }
        await failedGate.release()
        do { try await failed.value; XCTFail("Earlier attempt succeeded") }
        catch InjectedFailure.admission {}
        await fulfillment(of: [finishSettled], timeout: 0.1)
        finishSettled.isInverted = false
        await successfulGate.release()
        try await successful.value
        try await observedFinish.value
        realm.refresh()
        XCTAssertEqual(feed.title, "Original")
        XCTAssertEqual(feed.markdownDescription, "Settled newer field")
        try await model.finishEditing().value
        realm.refresh()
        XCTAssertEqual(feed.title, "Retained mixed-finish draft")
        XCTAssertEqual(feed.markdownDescription, "Settled newer field")
    }

    func testOlderFailureCannotClearNewerPendingInput() async throws {
        let realm = try await Realm(configuration: configuration())
        let feed = try installFeed(in: realm)
        let model = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false)
        let olderStarted = expectation(description: "Older failing writer suspended")
        let newerStarted = expectation(description: "Newer writer suspended")
        let olderGate = LibraryFeedContinuationGate()
        let newerGate = LibraryFeedContinuationGate()
        let older = model.writeFeedAsync(field: .title, beforeWrite: {
            olderStarted.fulfill()
            await olderGate.wait()
            throw InjectedFailure.admission
        }) { $0.title = "Obsolete"; return true }
        defer { older.cancel(); Task { await olderGate.release() } }
        await fulfillment(of: [olderStarted], timeout: 5)
        let newer = model.writeFeedAsync(field: .title, beforeWrite: {
            newerStarted.fulfill()
            await newerGate.wait()
        }) { $0.title = "Newest"; return true }
        defer { newer.cancel(); Task { await newerGate.release() } }
        await fulfillment(of: [newerStarted], timeout: 5)
        await olderGate.release()
        do { try await older.value; XCTFail("Older failure succeeded") }
        catch InjectedFailure.admission {}
        // Cancelling the newer attempt then finishing proves the old settlement
        // did not remove its pending command or resurrect the older command.
        newer.cancel()
        await newerGate.release()
        do { try await newer.value; XCTFail("Cancelled newer attempt succeeded") }
        catch is CancellationError {}
        try await model.finishEditing().value
        realm.refresh()
        XCTAssertEqual(feed.title, "Newest")
    }

    func testFailedOldEditorRetryCannotOutrankNewEditorsNoOpInput() async throws {
        let realm = try await Realm(configuration: configuration())
        let feed = try installFeed(in: realm)
        let oldEditor = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false)
        do {
            try await oldEditor.writeFeedAsync(field: .title, beforeWrite: { throw InjectedFailure.admission }) {
                $0.title = "Obsolete retained draft"
                return true
            }.value
            XCTFail("Admission failure succeeded")
        } catch InjectedFailure.admission {}
        let newEditor = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false)
        newEditor.feedTitle = "Original"
        try await newEditor.finishEditing().value
        try await oldEditor.finishEditing().value
        realm.refresh()
        XCTAssertEqual(feed.title, "Original")
        XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
    }

    func testPostCommitSubmissionCancellationSettlesDurableDraft() async throws {
        let realm = try await Realm(configuration: configuration())
        let feed = try installFeed(in: realm)
        let model = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false)
        let write = RealmWriteCommitObservation.$didSubmit.withValue({
            withUnsafeCurrentTask { $0?.cancel() }
        }) {
            model.writeFeedAsync(field: .title) {
                $0.title = "Durable cancelled draft"
                return true
            }
        }
        try await write.value
        XCTAssertTrue(write.isCancelled)
        realm.refresh()
        XCTAssertEqual(feed.title, "Durable cancelled draft")
        XCTAssertEqual(model.feedTitle, "Durable cancelled draft")
        let generations = Dictionary(uniqueKeysWithValues:
            realm.objects(BigSyncPendingMutation.self).map { ($0.recordName, $0.generation) }
        )
        try await model.finishEditing().value
        realm.refresh()
        XCTAssertEqual(Dictionary(uniqueKeysWithValues:
            realm.objects(BigSyncPendingMutation.self).map { ($0.recordName, $0.generation) }
        ), generations)
    }


    func testChangedEditorURLInvalidatesOldRefreshMetadata() async throws {
        for paste in [false, true] {
            let realm = try await Realm(configuration: configuration())
            let feed = try installFeed(in: realm)
            try seedRefreshMetadata(feed, in: realm)
            let model = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false)
            let replacement = "https://other.example/new.xml"
            if paste {
                try await model.pasteRSSURL(strings: [replacement]).value
            } else {
                model.feedURL = replacement
            }
            try await model.finishEditing().value
            realm.refresh()
            XCTAssertEqual(feed.rssUrl.absoluteString, replacement)
            XCTAssertNil(feed.lastFetchedETag)
            XCTAssertNil(feed.lastFetchedModifiedAt)
            XCTAssertNil(feed.lastRefreshedEntriesAt)
        }
    }

    func testSameEditorURLPreservesRefreshMetadata() async throws {
        for paste in [false, true] {
            let realm = try await Realm(configuration: configuration())
            let feed = try installFeed(in: realm)
            try seedRefreshMetadata(feed, in: realm)
            let model = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false)
            let original = feed.rssUrl.absoluteString
            if paste {
                try await model.pasteRSSURL(strings: [original]).value
            } else {
                model.feedURL = original
            }
            try await model.finishEditing().value
            realm.refresh()
            XCTAssertEqual(feed.rssUrl.absoluteString, original)
            assertSeededRefreshMetadata(feed)
        }
    }

    func testRejectedEditorURLPreservesRefreshMetadata() async throws {
        for paste in [false, true] {
            let realm = try await Realm(configuration: configuration())
            let feed = try installFeed(in: realm)
            try seedRefreshMetadata(feed, in: realm)
            let original = feed.rssUrl
            let model = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false)
            let category = try XCTUnwrap(feed.getCategory())
            try realm.write { category.opmlURL = URL(string: "https://example.com/managed.opml") }
            if paste {
                try await model.pasteRSSURL(strings: ["https://other.example/new.xml"]).value
            } else {
                model.feedURL = "https://other.example/new.xml"
            }
            try await model.finishEditing().value
            realm.refresh()
            XCTAssertEqual(feed.rssUrl, original)
            assertSeededRefreshMetadata(feed)
        }
    }

    func testSupersededURLWriterDoesNotInvalidateWinningMetadata() async throws {
        let realm = try await Realm(configuration: configuration())
        let feed = try installFeed(in: realm)
        try seedRefreshMetadata(feed, in: realm)
        let original = feed.rssUrl
        let oldEditor = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false)
        let started = expectation(description: "URL writer suspended")
        let gate = LibraryFeedContinuationGate()
        let older = oldEditor.writeFeedAsync(field: .url, beforeWrite: {
            started.fulfill()
            await gate.wait()
        }) { feed in
            feed.rssUrl = URL(string: "https://obsolete.example/feed.xml")!
            return true
        }
        defer { older.cancel(); Task { await gate.release() } }
        await fulfillment(of: [started], timeout: 5)
        let newEditor = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false)
        newEditor.feedURL = original.absoluteString
        await gate.release()
        try await older.value
        try await newEditor.finishEditing().value
        realm.refresh()
        XCTAssertEqual(feed.rssUrl, original)
        assertSeededRefreshMetadata(feed)
    }

    private func seedRefreshMetadata(_ feed: Feed, in realm: Realm) throws {
        try realm.write {
            feed.lastFetchedETag = "\"old-resource\""
            feed.lastFetchedModifiedAt = Date(timeIntervalSince1970: 100)
            feed.lastRefreshedEntriesAt = Date(timeIntervalSince1970: 200)
        }
    }

    private func assertSeededRefreshMetadata(
        _ feed: Feed, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(feed.lastFetchedETag, "\"old-resource\"", file: file, line: line)
        XCTAssertEqual(feed.lastFetchedModifiedAt, Date(timeIntervalSince1970: 100), file: file, line: line)
        XCTAssertEqual(feed.lastRefreshedEntriesAt, Date(timeIntervalSince1970: 200), file: file, line: line)
    }

    private func configuration() -> Realm.Configuration {
        var value = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        value.objectTypes = [
            LibraryConfiguration.self, FeedCategory.self, Feed.self, FeedEntry.self,
            FeedDirectory.self, UserScript.self, UserScriptAllowedDomain.self,
        ]
        configureLakeOfFireMutationTrackingForTesting(&value)
        let captured = value
        addTeardownBlock { await RealmBackgroundActor.shared.removeCachedRealm(for: captured) }
        return value
    }

    private func installFeed(id: UUID = UUID(), in realm: Realm, title: String = "Original") throws -> Feed {
        let category = FeedCategory()
        let feed = Feed()
        feed.id = id
        feed.categoryID = category.id
        feed.title = title
        feed.rssUrl = URL(string: "https://example.com/feed.xml")!
        try realm.write { realm.add(category); realm.add(feed) }
        return feed
    }
}

private actor LibraryFeedContinuationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait(onFirstWait: (@Sendable () -> Void)? = nil) async {
        guard !released else { return }
        onFirstWait?()
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private actor LibraryFeedWriteAttempts {
    private(set) var count = 0
    func record() -> Int { count += 1; return count }
}
