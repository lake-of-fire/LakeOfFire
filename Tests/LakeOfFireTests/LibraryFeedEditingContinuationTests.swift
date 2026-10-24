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
        let original = try await Realm(configuration: originalConfiguration, actor: MainActor.shared)
        let replacement = try await Realm(configuration: replacementConfiguration, actor: MainActor.shared)
        let feed = try installFeed(in: original)
        let other = try installFeed(id: feed.id, in: replacement)
        let model = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false)
        let started = expectation(description: "Captured writer suspended")
        let gate = LibraryFeedContinuationGate()
        let writer = model.writeFeedAsync(field: .title, beforeWrite: {
            await gate.wait(onFirstWait: { started.fulfill() })
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
        let realm = try await Realm(configuration: configuration(), actor: MainActor.shared)
        let feed = try installFeed(in: realm)
        let oldEditor = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false)
        let started = expectation(description: "Older editor suspended")
        let gate = LibraryFeedContinuationGate()
        let older = oldEditor.writeFeedAsync(field: .title, beforeWrite: {
            await gate.wait(onFirstWait: { started.fulfill() })
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
        try await newEditor.finishEditing().value
        realm.refresh()
        XCTAssertEqual(feed.title, "Original")
        XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
    }

    func testDelayedWriterRejectsReplacementFeedIncarnation() async throws {
        let realm = try await Realm(configuration: configuration(), actor: MainActor.shared)
        let feed = try installFeed(in: realm)
        let id = feed.id
        let categoryID = feed.categoryID
        let createdAt = feed.createdAt
        let model = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false)
        let started = expectation(description: "Writer suspended before record replacement")
        let gate = LibraryFeedContinuationGate()
        let writer = model.writeFeedAsync(field: .title, beforeWrite: {
            await gate.wait(onFirstWait: { started.fulfill() })
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
    }

    func testDelayedWriterRejectsManagedOrReplacedCategory() async throws {
        for replaceCategory in [false, true] {
            let realm = try await Realm(configuration: configuration(), actor: MainActor.shared)
            let feed = try installFeed(in: realm)
            let category = try XCTUnwrap(feed.getCategory())
            let model = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false)
            let started = expectation(description: "Writer suspended before category change")
            let gate = LibraryFeedContinuationGate()
            let writer = model.writeFeedAsync(field: .title, beforeWrite: {
                await gate.wait(onFirstWait: { started.fulfill() })
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
        let realm = try await Realm(configuration: configuration(), actor: MainActor.shared)
        let feed = try installFeed(in: realm, title: "")
        let model = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false)
        let source = feed.rssUrl
        let generation = UUID()
        model.beginMetadataRefresh(rssURL: source, identifier: generation)
        let started = expectation(description: "Metadata fetch suspended")
        let gate = LibraryFeedContinuationGate()
        let metadata = Task { @MainActor in
            await model.refreshFromOpenGraph(expectedRSSURL: source, expectedGeneration: generation) { _ in
                await gate.wait(onFirstWait: { started.fulfill() })
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
        let realm = try await Realm(configuration: configuration(), actor: MainActor.shared)
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
                beforeWrite: { await gate.wait(onFirstWait: { started.fulfill() }) }
            ) { _ in
                LibraryFeedOpenGraphMetadata(url: source.domainURL, title: nil, description: "Automatic")
            }
        }
        defer { metadata.cancel(); Task { await gate.release() } }
        await fulfillment(of: [started], timeout: 5)
        model.feedDescription = ""
        await gate.release()
        await metadata.value
        try await model.finishEditing().value
        realm.refresh()
        XCTAssertEqual(feed.markdownDescription, "")
        XCTAssertEqual(model.feedDescription, "")
    }

    func testHydrationDoesNotPublishNewMutations() async throws {
        let realm = try await Realm(configuration: configuration(), actor: MainActor.shared)
        let feed = try installFeed(in: realm)
        let model = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false)
        model.refresh()
        try await model.finishEditing().value
        realm.refresh()
        XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
        XCTAssertEqual(model.feedTitle, "Original")
    }

    func testLateMetadataCannotOutrankAnotherEditorsEmptyInput() async throws {
        let realm = try await Realm(configuration: configuration(), actor: MainActor.shared)
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
        try await newEditor.finishEditing().value
        await gate.release()
        await metadata.value
        realm.refresh()
        XCTAssertEqual(feed.title, "")
        XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
    }

    func testRetirementDoesNotReplayCancelledMetadata() async throws {
        let realm = try await Realm(configuration: configuration(), actor: MainActor.shared)
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
                beforeWrite: { await gate.wait(onFirstWait: { started.fulfill() }) }
            ) { _ in
                LibraryFeedOpenGraphMetadata(url: source.domainURL, title: nil, description: "Cancelled")
            }
        }
        defer { metadata.cancel(); Task { await gate.release() } }
        await fulfillment(of: [started], timeout: 5)
        metadata.cancel()
        try await model.finishEditing().value
        await gate.release()
        await metadata.value
        realm.refresh()
        XCTAssertNil(feed.markdownDescription)
        XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
    }

    private enum InjectedFailure: Error { case admission }

    func testBufferedFailureRetainsDraftAndFinishRetriesWithoutDuplicateActiveWrites() async throws {
        let realm = try await Realm(configuration: configuration(), actor: MainActor.shared)
        let feed = try installFeed(in: realm)
        let started = expectation(description: "Buffered attempt suspended")
        let gate = LibraryFeedContinuationGate()
        defer { Task { await gate.release() } }
        let attempts = LibraryFeedWriteAttempts()
        let model = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false, beforeFieldWrite: {
            if await attempts.record() == 1 {
                await gate.wait(onFirstWait: { started.fulfill() })
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
        let realm = try await Realm(configuration: configuration(), actor: MainActor.shared)
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
        let realm = try await Realm(configuration: configuration(), actor: MainActor.shared)
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
        let realm = try await Realm(configuration: configuration(), actor: MainActor.shared)
        let feed = try installFeed(in: realm)
        let model = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false)
        let started = expectation(description: "Cancellable writer suspended")
        let gate = LibraryFeedContinuationGate()
        let writer = model.writeFeedAsync(field: .title, beforeWrite: {
            await gate.wait(onFirstWait: { started.fulfill() })
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
        let realm = try await Realm(configuration: configuration(), actor: MainActor.shared)
        let feed = try installFeed(in: realm)
        let model = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false)
        let started = expectation(description: "Title attempt suspended")
        let gate = LibraryFeedContinuationGate()
        let title = model.writeFeedAsync(field: .title, beforeWrite: {
            await gate.wait(onFirstWait: { started.fulfill() })
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
        let realm = try await Realm(configuration: configuration(), actor: MainActor.shared)
        let feed = try installFeed(in: realm)
        let model = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false)
        let failedStarted = expectation(description: "Earlier title attempt suspended")
        let successfulStarted = expectation(description: "Newer description attempt suspended")
        let failedGate = LibraryFeedContinuationGate()
        let successfulGate = LibraryFeedContinuationGate()
        let failed = model.writeFeedAsync(field: .title, beforeWrite: {
            await failedGate.wait(onFirstWait: { failedStarted.fulfill() })
            throw InjectedFailure.admission
        }) { $0.title = "Retained mixed-finish draft"; return true }
        defer { failed.cancel(); Task { await failedGate.release() } }
        await fulfillment(of: [failedStarted], timeout: 5)
        let successful = model.writeFeedAsync(field: .description, beforeWrite: {
            await successfulGate.wait(onFirstWait: { successfulStarted.fulfill() })
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
        let realm = try await Realm(configuration: configuration(), actor: MainActor.shared)
        let feed = try installFeed(in: realm)
        let model = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false)
        let olderStarted = expectation(description: "Older failing writer suspended")
        let newerStarted = expectation(description: "Newer writer suspended")
        let olderGate = LibraryFeedContinuationGate()
        let newerGate = LibraryFeedContinuationGate()
        let older = model.writeFeedAsync(field: .title, beforeWrite: {
            await olderGate.wait(onFirstWait: { olderStarted.fulfill() })
            throw InjectedFailure.admission
        }) { $0.title = "Obsolete"; return true }
        defer { older.cancel(); Task { await olderGate.release() } }
        await fulfillment(of: [olderStarted], timeout: 5)
        let newer = model.writeFeedAsync(field: .title, beforeWrite: {
            await newerGate.wait(onFirstWait: { newerStarted.fulfill() })
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
        let realm = try await Realm(configuration: configuration(), actor: MainActor.shared)
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
        let realm = try await Realm(configuration: configuration(), actor: MainActor.shared)
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

    func testPasteCompletionPreservesNewerInputReturningToTheSameURL() async throws {
        let realm = try await Realm(configuration: configuration(), actor: MainActor.shared)
        let feed = try installFeed(in: realm)
        let originalURL = feed.rssUrl
        try realm.write {
            feed.lastFetchedETag = "\"old-resource\""
            feed.lastFetchedModifiedAt = Date(timeIntervalSince1970: 100)
            feed.lastRefreshedEntriesAt = Date(timeIntervalSince1970: 200)
        }
        let pastedURL = "https://pasted.example/feed.xml"
        let olderStarted = expectation(description: "Pasted URL command registered")
        let newerStarted = expectation(description: "Newer URL command registered")
        let olderGate = LibraryFeedContinuationGate()
        let newerGate = LibraryFeedContinuationGate()
        let attempts = LibraryFeedWriteAttempts()
        let model = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false, beforeFieldWrite: {
            switch await attempts.record() {
            case 1: await olderGate.wait(onFirstWait: { olderStarted.fulfill() })
            case 2: await newerGate.wait(onFirstWait: { newerStarted.fulfill() })
            default: XCTFail("Paste published a duplicate command")
            }
        })
        let paste = model.pasteRSSURL(strings: [pastedURL])
        addTeardownBlock {
            paste.cancel()
            await olderGate.release()
            await newerGate.release()
            _ = try? await paste.value
            _ = try? await model.finishEditing().value
        }
        await fulfillment(of: [olderStarted], timeout: 5)
        let initialAttempts = await attempts.count
        XCTAssertEqual(initialAttempts, 1)

        // The final displayed string equals the paste, but belongs to a newer
        // input revision. An equality-only completion cannot distinguish them.
        model.feedURL = "https://intermediate.example/feed.xml"
        model.feedURL = pastedURL
        let finish = model.finishEditing()
        await fulfillment(of: [newerStarted], timeout: 5)
        await olderGate.release()
        try await paste.value
        realm.refresh()
        XCTAssertEqual(model.feedURL, pastedURL)
        XCTAssertEqual(feed.rssUrl, originalURL)
        XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)

        await newerGate.release()
        try await finish.value
        realm.refresh()
        XCTAssertEqual(feed.rssUrl.absoluteString, pastedURL)
        XCTAssertEqual(model.feedURL, pastedURL)
        XCTAssertNil(feed.lastFetchedETag)
        XCTAssertNil(feed.lastFetchedModifiedAt)
        XCTAssertNil(feed.lastRefreshedEntriesAt)
        XCTAssertFalse(realm.objects(BigSyncPendingMutation.self).isEmpty)
        let finalAttempts = await attempts.count
        XCTAssertEqual(finalAttempts, 2)
    }

    func testEndingMetadataGenerationRejectsItsSuspendedWrite() async throws {
        let realm = try await Realm(configuration: configuration(), actor: MainActor.shared)
        let feed = try installFeed(in: realm, title: "")
        let model = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false)
        let source = feed.rssUrl
        let generation = UUID()
        model.beginMetadataRefresh(rssURL: source, identifier: generation)
        let started = expectation(description: "Retiring metadata writer registered")
        let gate = LibraryFeedContinuationGate()
        let metadata = Task { @MainActor in
            await model.refreshFromOpenGraph(
                expectedRSSURL: source, expectedGeneration: generation,
                beforeWrite: { await gate.wait(onFirstWait: { started.fulfill() }) }
            ) { _ in
                LibraryFeedOpenGraphMetadata(url: source.domainURL, title: "Retired title", description: nil)
            }
        }
        addTeardownBlock {
            metadata.cancel()
            await gate.release()
            await metadata.value
        }
        await fulfillment(of: [started], timeout: 5)
        // Model the form disappearing while an uncancelled fetch/write remains
        // in flight: final native admission must revoke that generation itself.
        model.endMetadataRefresh(identifier: generation)
        await gate.release()
        await metadata.value
        try await model.finishEditing().value
        realm.refresh()
        XCTAssertEqual(feed.title, "")
        XCTAssertEqual(model.feedTitle, "")
        XCTAssertNil(feed.markdownDescription)
        XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
    }

    func testCancelledOldMetadataTaskCannotRevokeSuccessorGeneration() async throws {
        let realm = try await Realm(configuration: configuration(), actor: MainActor.shared)
        let feed = try installFeed(in: realm, title: "")
        let model = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false)
        let source = feed.rssUrl
        let olderGeneration = UUID()
        model.beginMetadataRefresh(rssURL: source, identifier: olderGeneration)
        let started = expectation(description: "Older metadata delay registered")
        let gate = LibraryFeedContinuationGate()
        let older = Task { @MainActor in
            await model.refreshMetadataAfterDelay(
                expectedRSSURL: source, expectedGeneration: olderGeneration,
                delay: { await gate.wait(onFirstWait: { started.fulfill() }) },
                performRefresh: { XCTFail("Cancelled metadata task reached refresh") }
            )
        }
        addTeardownBlock {
            older.cancel()
            await gate.release()
            await older.value
        }
        await fulfillment(of: [started], timeout: 5)
        let newerGeneration = UUID()
        model.beginMetadataRefresh(rssURL: source, identifier: newerGeneration)
        older.cancel()
        model.endMetadataRefresh(identifier: olderGeneration)
        await model.refreshFromOpenGraph(expectedRSSURL: source, expectedGeneration: newerGeneration) { _ in
            LibraryFeedOpenGraphMetadata(url: source.domainURL, title: "Current title", description: nil)
        }
        await gate.release()
        await older.value
        realm.refresh()
        XCTAssertEqual(feed.title, "Current title")
        XCTAssertEqual(model.feedTitle, "Current title")
        XCTAssertFalse(realm.objects(BigSyncPendingMutation.self).isEmpty)
    }

    func testDeinitJoinsFailingActiveAttemptBeforeRetryingCapturedDraft() async throws {
        let realm = try await Realm(configuration: configuration(), actor: MainActor.shared)
        let feed = try installFeed(in: realm)
        let started = expectation(description: "Active writer registered before retirement")
        let retired = expectation(description: "Retirement batch durably settled")
        let gate = LibraryFeedContinuationGate()
        var model: LibraryFeedFormSectionsViewModel? = LibraryFeedFormSectionsViewModel(
            feed: feed, observesRealm: false,
            beforeFieldWrite: {
                await gate.wait(onFirstWait: { started.fulfill() })
                throw InjectedFailure.admission
            },
            retirementDidFinish: { retired.fulfill() }
        )
        weak var retiringModel = model
        model?.feedTitle = "Retired captured draft"
        await fulfillment(of: [started], timeout: 5)
        let finish = try XCTUnwrap(model).finishEditing()
        model = nil
        XCTAssertNil(retiringModel, "An in-flight command must not retain its editor")
        await gate.release()
        do { try await finish.value; XCTFail("Injected first attempt succeeded") }
        catch InjectedFailure.admission {}
        await fulfillment(of: [retired], timeout: 5)
        realm.refresh()
        XCTAssertEqual(feed.title, "Retired captured draft")
        XCTAssertFalse(realm.objects(BigSyncPendingMutation.self).isEmpty)
    }

    func testRetirementFlushesTrailingURLInputBeforeOlderPasteCompletes() async throws {
        let realm = try await Realm(configuration: configuration(), actor: MainActor.shared)
        let feed = try installFeed(in: realm)
        try realm.write { feed.lastFetchedETag = "\"original\"" }
        let started = expectation(description: "Older paste registered before retirement")
        let retired = expectation(description: "Trailing URL command durably settled")
        let gate = LibraryFeedContinuationGate()
        var model: LibraryFeedFormSectionsViewModel? = LibraryFeedFormSectionsViewModel(
            feed: feed, observesRealm: false,
            beforeFieldWrite: { await gate.wait(onFirstWait: { started.fulfill() }) },
            retirementDidFinish: { retired.fulfill() }
        )
        let paste = try XCTUnwrap(model).pasteRSSURL(strings: ["https://older.example/feed.xml"])
        addTeardownBlock {
            paste.cancel()
            await gate.release()
            _ = try? await paste.value
        }
        await fulfillment(of: [started], timeout: 5)
        model?.feedURL = "https://latest.example/feed.xml"
        weak var retiringModel = model
        model = nil
        XCTAssertNil(retiringModel)
        // No finish call or trailing timer emission is needed to capture this
        // last input. Retirement can settle it while the obsolete paste waits.
        await fulfillment(of: [retired], timeout: 5)
        realm.refresh()
        XCTAssertEqual(feed.rssUrl.absoluteString, "https://latest.example/feed.xml")
        XCTAssertNil(feed.lastFetchedETag)
        let generations = Dictionary(uniqueKeysWithValues:
            realm.objects(BigSyncPendingMutation.self).map { ($0.recordName, $0.generation) }
        )
        XCTAssertFalse(generations.isEmpty)
        await gate.release()
        try await paste.value
        realm.refresh()
        XCTAssertEqual(feed.rssUrl.absoluteString, "https://latest.example/feed.xml")
        XCTAssertEqual(Dictionary(uniqueKeysWithValues:
            realm.objects(BigSyncPendingMutation.self).map { ($0.recordName, $0.generation) }
        ), generations)
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
        await withCheckedContinuation {
            continuation = $0
            onFirstWait?()
        }
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
