import BigSyncKit
import Combine
import Foundation
import RealmSwift
@testable import RealmSwiftGaps
import XCTest
import LakeOfFireCore
@testable import LakeOfFireContent
@testable import LakeOfFireLibrary

@MainActor
final class LibraryFeedEditingContinuationTests: XCTestCase {
    private enum InjectedFailure: Error { case admission }

    func testBufferedFailureRetainsDraftAndFinishRetriesWithoutDuplicateActiveWrites() async throws {
        let realm = try await Realm(configuration: configuration(), actor: MainActor.shared)
        let feed = try installFeed(in: realm)
        let started = expectation(description: "Buffered attempt suspended")
        let gate = LibraryFeedContinuationGate()
        let attempts = LibraryFeedWriteAttempts()
        let model = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false, observesFormInput: true, beforeFieldWrite: {
            if await attempts.record() == 1 {
                await gate.wait(onFirstWait: { started.fulfill() })
                throw InjectedFailure.admission
            }
        })
        model.feedTitle = "Retained buffered draft"
        await fulfillment(of: [started], timeout: 5)
        let finish = model.finishEditing()
        let repeatedFinish = model.finishEditing()
        addTeardownBlock {
            await gate.release()
            _ = await finish.result
            _ = await repeatedFinish.result
            _ = await model.finishEditing().result
        }
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
        let model = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false, observesFormInput: true, beforeFieldWrite: {
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
        addTeardownBlock {
            writer.cancel()
            await gate.release()
            _ = await writer.result
            _ = await model.finishEditing().result
        }
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
        addTeardownBlock {
            title.cancel()
            await gate.release()
            _ = await title.result
            _ = await model.finishEditing().result
        }
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
        await fulfillment(of: [failedStarted], timeout: 5)
        let successful = model.writeFeedAsync(field: .description, beforeWrite: {
            await successfulGate.wait(onFirstWait: { successfulStarted.fulfill() })
        }) { $0.markdownDescription = "Settled newer field"; return true }
        addTeardownBlock {
            failed.cancel()
            successful.cancel()
            await failedGate.release()
            await successfulGate.release()
            _ = await failed.result
            _ = await successful.result
            _ = await model.finishEditing().result
        }
        await fulfillment(of: [successfulStarted], timeout: 5)
        let finish = model.finishEditing()
        let finishSettled = expectation(description: "Finish awaits all captured attempts")
        finishSettled.isInverted = true
        let observedFinish = Task { @MainActor in
            do { try await finish.value; XCTFail("Mixed finish lost admission error") }
            catch InjectedFailure.admission {}
            finishSettled.fulfill()
        }
        addTeardownBlock {
            await failedGate.release()
            await successfulGate.release()
            _ = await observedFinish.result
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
        await fulfillment(of: [olderStarted], timeout: 5)
        let newer = model.writeFeedAsync(field: .title, beforeWrite: {
            await newerGate.wait(onFirstWait: { newerStarted.fulfill() })
        }) { $0.title = "Newest"; return true }
        addTeardownBlock {
            older.cancel()
            newer.cancel()
            await olderGate.release()
            await newerGate.release()
            _ = await older.result
            _ = await newer.result
            _ = await model.finishEditing().result
        }
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
        let oldEditor = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false, observesFormInput: true)
        do {
            try await oldEditor.writeFeedAsync(field: .title, beforeWrite: { throw InjectedFailure.admission }) {
                $0.title = "Obsolete retained draft"
                return true
            }.value
            XCTFail("Admission failure succeeded")
        } catch InjectedFailure.admission {}
        let newEditor = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false, observesFormInput: true)
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
        let model = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false, observesFormInput: true, beforeFieldWrite: {
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

    func testDeinitJoinsFailingActiveAttemptBeforeRetryingCapturedDraft() async throws {
        let fixtureConfiguration = configuration()
        let realm = try await Realm(configuration: fixtureConfiguration, actor: MainActor.shared)
        let feed = try installFeed(in: realm)
        let started = expectation(description: "Active writer registered before retirement")
        let retired = expectation(description: "Retirement batch durably settled")
        let gate = LibraryFeedContinuationGate()
        let retirementQueued = XCTestExpectation(description: "Captured-draft retirement queued its actual write")
        var model: LibraryFeedFormSectionsViewModel? = LibraryFeedFormSectionsViewModel(
            feed: feed, observesRealm: false, observesFormInput: true,
            beforeFieldWrite: {
                await gate.wait(onFirstWait: { started.fulfill() })
                throw InjectedFailure.admission
            },
            retirementDidFinish: { retired.fulfill() }
        )
        weak var retiringModel = model
        model?.feedTitle = "Retired captured draft"
        let finish = model?.finishEditing()
        addTeardownBlock { [weak retiringModel] in
            await gate.release()
            _ = await finish?.result
            if let retainedModel = retiringModel {
                _ = await retainedModel.finishEditing().result
                await retainedModel.stopObserving()
            }
            try await self.settleSubmittedRetirement(retirementQueued, configuration: fixtureConfiguration)
        }
        try await RealmWriteSubmissionObservation.$willSubmit.withValue({
            // This same-actor turn follows actual SDK ticket submission.
            Task { @RealmBackgroundActor in retirementQueued.fulfill() }
        }) {
            defer { model = nil }
            let joinedFinish = try XCTUnwrap(finish)
            await fulfillment(of: [started], timeout: 5)
            model = nil
            XCTAssertNil(retiringModel, "An in-flight command must not retain its editor")
            await gate.release()
            do { try await joinedFinish.value; XCTFail("Injected first attempt succeeded") }
            catch InjectedFailure.admission {}
            await fulfillment(of: [retired], timeout: 5)
            realm.refresh()
            XCTAssertEqual(feed.title, "Retired captured draft")
            XCTAssertFalse(realm.objects(BigSyncPendingMutation.self).isEmpty)
        }
    }

    func testRetirementFlushesTrailingURLInputBeforeOlderPasteCompletes() async throws {
        let fixtureConfiguration = configuration()
        let realm = try await Realm(configuration: fixtureConfiguration, actor: MainActor.shared)
        let feed = try installFeed(in: realm)
        try realm.write { feed.lastFetchedETag = "\"original\"" }
        let started = expectation(description: "Older paste registered before retirement")
        let retired = expectation(description: "Trailing URL command durably settled")
        let gate = LibraryFeedContinuationGate()
        let retirementQueued = XCTestExpectation(description: "Trailing-URL retirement queued its actual write")
        var model: LibraryFeedFormSectionsViewModel? = LibraryFeedFormSectionsViewModel(
            feed: feed, observesRealm: false, observesFormInput: true,
            beforeFieldWrite: { await gate.wait(onFirstWait: { started.fulfill() }) },
            retirementDidFinish: { retired.fulfill() }
        )
        weak var retiringModel = model
        let paste = model?.pasteRSSURL(strings: ["https://older.example/feed.xml"])
        addTeardownBlock { [weak retiringModel] in
            paste?.cancel()
            await gate.release()
            _ = await paste?.result
            if let retainedModel = retiringModel {
                _ = await retainedModel.finishEditing().result
                await retainedModel.stopObserving()
            }
            try await self.settleSubmittedRetirement(retirementQueued, configuration: fixtureConfiguration)
        }
        await fulfillment(of: [started], timeout: 5)
        model?.feedURL = "https://latest.example/feed.xml"
        try await RealmWriteSubmissionObservation.$willSubmit.withValue({
            // Foreground tasks were created before this retirement-only marker.
            Task { @RealmBackgroundActor in retirementQueued.fulfill() }
        }) {
            defer { model = nil }
            let joinedPaste = try XCTUnwrap(paste)
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
            try await joinedPaste.value
            realm.refresh()
            XCTAssertEqual(feed.rssUrl.absoluteString, "https://latest.example/feed.xml")
            XCTAssertEqual(Dictionary(uniqueKeysWithValues:
                realm.objects(BigSyncPendingMutation.self).map { ($0.recordName, $0.generation) }
            ), generations)
        }
    }

    func testURLFieldChangeInvalidatesValidatorsButNoOpPreservesThem() async throws {
        let realm = try await Realm(configuration: configuration(), actor: MainActor.shared)
        let feed = try installFeed(in: realm)
        let modifiedAt = Date(timeIntervalSince1970: 100)
        let refreshedAt = Date(timeIntervalSince1970: 200)
        try realm.write {
            feed.lastFetchedETag = "\"original-resource\""
            feed.lastFetchedModifiedAt = modifiedAt
            feed.lastRefreshedEntriesAt = refreshedAt
        }
        let model = LibraryFeedFormSectionsViewModel(
            feed: feed, observesRealm: false, observesFormInput: true
        )
        model.feedURL = feed.rssUrl.absoluteString
        try await model.finishEditing().value
        realm.refresh()
        XCTAssertEqual(feed.lastFetchedETag, "\"original-resource\"")
        XCTAssertEqual(feed.lastFetchedModifiedAt, modifiedAt)
        XCTAssertEqual(feed.lastRefreshedEntriesAt, refreshedAt)
        XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)

        model.feedURL = "https://changed.example/feed.xml"
        try await model.finishEditing().value
        realm.refresh()
        XCTAssertEqual(feed.rssUrl.absoluteString, "https://changed.example/feed.xml")
        XCTAssertNil(feed.lastFetchedETag)
        XCTAssertNil(feed.lastFetchedModifiedAt)
        XCTAssertNil(feed.lastRefreshedEntriesAt)
        let mutation = try XCTUnwrap(realm.objects(BigSyncPendingMutation.self).first)
        XCTAssertEqual(mutation.changedAt, feed.explicitlyModifiedAt)
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
        addTeardownBlock { writer.cancel(); await gate.release(); _ = await writer.result }
        await fulfillment(of: [started], timeout: 5)
        let replacement = Feed()
        replacement.id = id
        replacement.categoryID = categoryID
        replacement.createdAt = createdAt
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
            addTeardownBlock { writer.cancel(); await gate.release(); _ = await writer.result }
            await fulfillment(of: [started], timeout: 5)
            if replaceCategory {
                let replacement = FeedCategory()
                replacement.id = category.id
                replacement.createdAt = category.createdAt
                try realm.write { realm.delete(category); realm.add(replacement) }
            } else {
                try realm.write { category.opmlURL = URL(string: "https://example.com/managed.opml") }
            }
            await gate.release()
            try await writer.value
            realm.refresh()
            XCTAssertEqual(feed.title, "Original")
            XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
            if !replaceCategory {
                try realm.write { category.isDeleted = true }
                try await model.finishEditing().value
            }
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
        addTeardownBlock { metadata.cancel(); await gate.release(); await metadata.value }
        await fulfillment(of: [started], timeout: 5)
        try await model.pasteRSSURL(strings: ["https://other.example/new.xml"]).value
        await gate.release()
        await metadata.value
        realm.refresh()
        XCTAssertEqual(feed.title, "")
        XCTAssertNil(feed.markdownDescription)
        XCTAssertEqual(feed.rssUrl.absoluteString, "https://other.example/new.xml")
    }

    func testMetadataRespectsCrossEditorEmptyInputURLABAAndSameEditorExplicitEmptyDescription() async throws {
        for input in ["title", "urlABA", "description"] {
            let realm = try await Realm(configuration: configuration(), actor: MainActor.shared)
            let feed = try installFeed(in: realm, title: input == "description" ? "Original" : "")
            let inputStarted = expectation(description: "Human command held before commit")
            let inputGate = LibraryFeedContinuationGate()
            let oldEditor = LibraryFeedFormSectionsViewModel(
                feed: feed, observesRealm: false, observesFormInput: true,
                beforeFieldWrite: { await inputGate.wait(onFirstWait: { inputStarted.fulfill() }) }
            )
            let source = feed.rssUrl
            let generation = UUID()
            oldEditor.beginMetadataRefresh(rssURL: source, identifier: generation)
            let started = expectation(description: "Older metadata request suspended")
            let gate = LibraryFeedContinuationGate()
            let metadata = Task { @MainActor in
                await oldEditor.refreshFromOpenGraph(expectedRSSURL: source, expectedGeneration: generation) { _ in
                    await gate.wait(onFirstWait: { started.fulfill() })
                    return LibraryFeedOpenGraphMetadata(
                        url: source.domainURL, title: "Obsolete",
                        description: input == "description" ? "Automatic description" : nil
                    )
                }
            }
            addTeardownBlock { metadata.cancel(); await gate.release(); await metadata.value }
            await fulfillment(of: [started], timeout: 5)
            let newEditor = input == "description" ? oldEditor : LibraryFeedFormSectionsViewModel(
                feed: feed, observesRealm: false, observesFormInput: true,
                beforeFieldWrite: { await inputGate.wait(onFirstWait: { inputStarted.fulfill() }) }
            )
            if input == "urlABA" {
                newEditor.feedURL = "https://other.example/temporary.xml"
                newEditor.feedURL = source.absoluteString
            } else if input == "description" {
                newEditor.feedDescription = ""
            } else {
                newEditor.feedTitle = ""
                newEditor.feedTitle = ""
            }
            let finished = newEditor.finishEditing()
            addTeardownBlock { await inputGate.release(); _ = await finished.result }
            await fulfillment(of: [inputStarted], timeout: 5)
            await gate.release()
            await metadata.value
            realm.refresh()
            XCTAssertEqual(feed.rssUrl, source)
            XCTAssertEqual(feed.title, input == "description" ? "Original" : "")
            XCTAssertNil(feed.markdownDescription)
            XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
            await inputGate.release()
            try await finished.value
            realm.refresh()
            XCTAssertEqual(feed.title, input == "description" ? "Original" : "")
            XCTAssertEqual(feed.markdownDescription, input == "description" ? "" : nil)
            XCTAssertEqual(newEditor.feedDescription, "")
            XCTAssertEqual(realm.objects(BigSyncPendingMutation.self).count, input == "description" ? 1 : 0)
            if input == "description" {
                XCTAssertEqual(realm.objects(BigSyncPendingMutation.self).first?.changedAt, feed.explicitlyModifiedAt)
            }
        }
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

    func testCapturedOriginalRowKeysCannotRebindBeforeFirstWriteAfterRecreation() async throws {
        for replaceFeed in [false, true] {
            for frozenInput in [false, true] {
                let realm = try await Realm(configuration: configuration(), actor: MainActor.shared)
                let feed = try installFeed(in: realm)
                let category = try XCTUnwrap(feed.getCategory())
                let model = LibraryFeedFormSectionsViewModel(
                    feed: frozenInput ? feed.freeze() : feed, observesRealm: false
                )
                // No writer has looked up these captured original row keys yet.
                let replacement = Feed()
                replacement.id = feed.id
                replacement.createdAt = feed.createdAt
                replacement.categoryID = category.id
                replacement.title = "Replacement"
                let replacementCategory = FeedCategory()
                replacementCategory.id = category.id
                replacementCategory.createdAt = category.createdAt
                try realm.write {
                    if replaceFeed {
                        realm.delete(feed)
                        realm.add(replacement)
                    } else {
                        realm.delete(category)
                        realm.add(replacementCategory)
                    }
                }
                XCTAssertNil(try model.previewEntries(), "Presentation cannot rebind before a deletion callback")
                XCTAssertNil(model.currentRSSURL)
                try await model.writeFeedAsync(field: .title) { feed in
                    feed.title = "Obsolete editor"
                    return true
                }.value
                realm.refresh()
                XCTAssertEqual(replaceFeed ? replacement.title : feed.title, replaceFeed ? "Replacement" : "Original")
                XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
            }
        }
    }

    func testRejectedMetadataCannotAdvanceCommittedOrderPastAnEarlierHumanCommand() async throws {
        let realm = try await Realm(configuration: configuration(), actor: MainActor.shared)
        let feed = try installFeed(in: realm, title: "")
        let oldEditor = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false)
        let source = feed.rssUrl
        let generation = UUID()
        oldEditor.beginMetadataRefresh(rssURL: source, identifier: generation)
        let metadataStarted = expectation(description: "Metadata fetch held before command allocation")
        let metadataGate = LibraryFeedContinuationGate()
        let metadata = Task { @MainActor in
            await oldEditor.refreshFromOpenGraph(expectedRSSURL: source, expectedGeneration: generation) { _ in
                await metadataGate.wait(onFirstWait: { metadataStarted.fulfill() })
                return LibraryFeedOpenGraphMetadata(url: source.domainURL, title: "Automatic", description: nil)
            }
        }
        addTeardownBlock { metadata.cancel(); await metadataGate.release(); await metadata.value }
        await fulfillment(of: [metadataStarted], timeout: 5)
        let newEditor = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false)
        let humanStarted = expectation(description: "Earlier allocated human command held before commit")
        let humanGate = LibraryFeedContinuationGate()
        let human = newEditor.writeFeedAsync(field: .title, beforeWrite: {
            await humanGate.wait(onFirstWait: { humanStarted.fulfill() })
        }) { feed in
            guard feed.title != "Human" else { return false }
            feed.title = "Human"
            return true
        }
        addTeardownBlock { human.cancel(); await humanGate.release(); _ = await human.result }
        await fulfillment(of: [humanStarted], timeout: 5)
        await metadataGate.release()
        await metadata.value
        realm.refresh()
        XCTAssertEqual(feed.title, "")
        XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
        await humanGate.release()
        try await human.value
        realm.refresh()
        XCTAssertEqual(feed.title, "Human")
        let mutation = try XCTUnwrap(realm.objects(BigSyncPendingMutation.self).first)
        XCTAssertEqual(realm.objects(BigSyncPendingMutation.self).count, 1)
        XCTAssertEqual(mutation.changedAt, feed.explicitlyModifiedAt)
    }

    func testPresentationIdentityUsesStablePhysicalRowsAcrossFrozenVersionsAndRecreation() async throws {
        let realm = try await Realm(configuration: configuration(), actor: MainActor.shared)
        let feed = try installFeed(in: realm)
        let category = try XCTUnwrap(feed.getCategory())
        let original = feed.freeze()
        let originalIdentity = try XCTUnwrap(LibraryFeedPresentationIdentity(feed: original))
        try realm.write { feed.title = "Updated same row"; category.title = "Updated category" }
        XCTAssertEqual(LibraryFeedPresentationIdentity(feed: feed.freeze()), originalIdentity)
        let replacementCategory = FeedCategory()
        replacementCategory.id = category.id
        replacementCategory.createdAt = category.createdAt
        try realm.write { realm.delete(category); realm.add(replacementCategory) }
        let categoryReplacementIdentity = try XCTUnwrap(LibraryFeedPresentationIdentity(feed: feed.freeze()))
        XCTAssertNotEqual(categoryReplacementIdentity, originalIdentity)
        XCTAssertEqual(categoryReplacementIdentity.feedRowKey, originalIdentity.feedRowKey)
        var staleCategoryObserversInstalled = false
        let staleCategoryEditor = LibraryFeedFormSectionsViewModel(
            feed: original, observesRealm: true,
            didInstallOwnershipObservers: { staleCategoryObserversInstalled = true }
        )
        XCTAssertTrue(staleCategoryEditor.ownershipRetired)
        XCTAssertFalse(staleCategoryEditor.canEdit)
        XCTAssertFalse(staleCategoryObserversInstalled, "A frozen input cannot observe a same-UUID replacement category")
        let replacement = Feed()
        replacement.id = feed.id
        replacement.createdAt = feed.createdAt
        replacement.categoryID = replacementCategory.id
        try realm.write { realm.delete(feed); realm.add(replacement) }
        let replacementIdentity = try XCTUnwrap(LibraryFeedPresentationIdentity(feed: replacement.freeze()))
        XCTAssertNotEqual(replacementIdentity.feedRowKey, originalIdentity.feedRowKey)
        XCTAssertEqual(LibraryFeedPresentationIdentity(feed: original), originalIdentity)
    }

    func testOriginalOwnerObserversRetireFrozenNavigationWithoutRetiringItsSuccessor() async throws {
        for change in ["feed", "category", "move"] {
            let realm = try await Realm(configuration: configuration(), actor: MainActor.shared)
            let feed = try installFeed(in: realm)
            let category = try XCTUnwrap(feed.getCategory())
            let navigationValue = feed.freeze()
            let ready = expectation(description: "Original physical owner observers installed")
            let model = LibraryFeedFormSectionsViewModel(
                feed: navigationValue, observesRealm: true, observesFormInput: false,
                didInstallOwnershipObservers: { ready.fulfill() }
            )
            addTeardownBlock { await model.stopObserving() }
            await fulfillment(of: [ready], timeout: 5)
            let retired = expectation(description: "Original editor retired after owner change")
            let subscription = model.$ownershipRetired.dropFirst().filter { $0 }.prefix(1).sink { _ in retired.fulfill() }
            defer { subscription.cancel() }
            let replacement = Feed()
            replacement.id = feed.id
            replacement.createdAt = feed.createdAt
            replacement.categoryID = category.id
            replacement.title = "Replacement"
            let replacementCategory = FeedCategory()
            replacementCategory.id = change == "move" ? UUID() : category.id
            replacementCategory.createdAt = category.createdAt
            try realm.write {
                if change == "feed" {
                    realm.delete(feed)
                    realm.add(replacement)
                } else if change == "category" {
                    realm.delete(category)
                    realm.add(replacementCategory)
                } else {
                    realm.add(replacementCategory)
                    feed.categoryID = replacementCategory.id
                }
            }
            // Construct the successor before old notification delivery completes.
            let currentFeed = change == "feed" ? replacement : feed
            let successor = LibraryFeedFormSectionsViewModel(feed: currentFeed.freeze(), observesRealm: false)
            await fulfillment(of: [retired], timeout: 5)
            XCTAssertTrue(model.ownershipRetired)
            XCTAssertFalse(successor.ownershipRetired)
            XCTAssertNotEqual(model.presentationIdentity, successor.presentationIdentity)
            XCTAssertEqual(LibraryFeedPresentationIdentity(feed: navigationValue), model.presentationIdentity)
            try await model.writeFeedAsync(field: .title) { feed in feed.title = "Obsolete"; return true }.value
            realm.refresh()
            XCTAssertEqual(currentFeed.title, change == "feed" ? "Replacement" : "Original")
            XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
            try await successor.writeFeedAsync(field: .title) { feed in feed.title = "Successor edit"; return true }.value
            realm.refresh()
            XCTAssertEqual(currentFeed.title, "Successor edit")
            XCTAssertFalse(successor.ownershipRetired)
            XCTAssertFalse(realm.objects(BigSyncPendingMutation.self).isEmpty)
        }
    }

    func testInvalidatedAndUnmanagedInputsFailClosedWithoutAdoptingRows() async throws {
        let realm = try await Realm(configuration: configuration(), actor: MainActor.shared)
        let feed = try installFeed(in: realm)
        let frozenNavigation = feed.freeze()
        try realm.write { realm.delete(feed) }
        XCTAssertNil(LibraryFeedPresentationIdentity(feed: feed))
        let invalid = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false)
        XCTAssertTrue(invalid.ownershipRetired)
        var installed = false
        let frozen = LibraryFeedFormSectionsViewModel(
            feed: frozenNavigation, observesRealm: true,
            didInstallOwnershipObservers: { installed = true }
        )
        XCTAssertTrue(frozen.ownershipRetired, "A failed thaw cannot register observers on an old frozen Realm")
        XCTAssertFalse(frozen.canEdit)
        XCTAssertFalse(installed)
        try await frozen.writeFeedAsync(field: .title) { feed in feed.title = "Frozen obsolete edit"; return true }.value
        try await invalid.writeFeedAsync(field: .title) { feed in feed.title = "Invalid edit"; return true }.value
        let unmanaged = Feed()
        unmanaged.title = "Unmanaged"
        XCTAssertNil(LibraryFeedPresentationIdentity(feed: unmanaged))
        let unowned = LibraryFeedFormSectionsViewModel(feed: unmanaged, observesRealm: false)
        XCTAssertTrue(unowned.ownershipRetired)
        try await unowned.writeFeedAsync(field: .title) { feed in feed.title = "Unowned edit"; return true }.value
        XCTAssertEqual(unmanaged.title, "Unmanaged")
        XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
    }

    func testManagedCategoryRemainsVisibleAndPolicyChangesPreserveItsDraftAndIdentity() async throws {
        let realm = try await Realm(configuration: configuration(), actor: MainActor.shared)
        let feed = try installFeed(in: realm)
        let category = try XCTUnwrap(feed.getCategory())
        let managedURL = URL(string: "https://example.com/managed.opml")!
        try realm.write { category.opmlURL = managedURL }
        let ready = expectation(description: "Read-only original owner observed")
        let model = LibraryFeedFormSectionsViewModel(
            feed: feed.freeze(), observesRealm: true, observesFormInput: false,
            didInstallOwnershipObservers: { ready.fulfill() }
        )
        addTeardownBlock { await model.stopObserving() }
        await fulfillment(of: [ready], timeout: 5)
        XCTAssertFalse(model.ownershipRetired)
        XCTAssertFalse(model.canEdit)
        let identity = model.presentationIdentity
        model.isEditing = true
        model.feedTitle = "Local draft"
        try await model.writeFeedAsync(field: .title) { feed in feed.title = "Forbidden"; return true }.value
        realm.refresh()
        XCTAssertEqual(feed.title, "Original")
        XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
        let editable = expectation(description: "Same category becomes editable")
        let becameEditable = model.$canEdit.dropFirst().filter { $0 }.prefix(1).sink { _ in editable.fulfill() }
        defer { becameEditable.cancel() }
        try realm.write { category.opmlURL = nil }
        await fulfillment(of: [editable], timeout: 5)
        XCTAssertFalse(model.ownershipRetired)
        XCTAssertEqual(model.presentationIdentity, identity)
        XCTAssertEqual(model.feedTitle, "Local draft")
        try await model.writeFeedAsync(field: .title) { feed in feed.title = "Admitted"; return true }.value
        realm.refresh()
        XCTAssertEqual(feed.title, "Admitted")
        let mutation = try XCTUnwrap(realm.objects(BigSyncPendingMutation.self).first)
        let generation = mutation.changedAt
        let readOnly = expectation(description: "Same category becomes read-only again")
        let becameReadOnly = model.$canEdit.dropFirst().filter { !$0 }.prefix(1).sink { _ in readOnly.fulfill() }
        defer { becameReadOnly.cancel() }
        try realm.write { category.opmlURL = managedURL }
        await fulfillment(of: [readOnly], timeout: 5)
        XCTAssertFalse(model.ownershipRetired)
        XCTAssertFalse(model.canEdit)
        XCTAssertEqual(model.presentationIdentity, identity)
        XCTAssertEqual(model.feedTitle, "Local draft")
        try await model.writeFeedAsync(field: .title) { feed in feed.title = "Forbidden again"; return true }.value
        realm.refresh()
        XCTAssertEqual(feed.title, "Admitted")
        XCTAssertEqual(mutation.changedAt, generation)
        XCTAssertEqual(realm.objects(BigSyncPendingMutation.self).count, 1)
        try realm.write { category.isDeleted = true }
        try await model.finishEditing().value
    }

    func testCapturedStorageRejectsSamePathReplacementBeforeFirstWriteAndDuringSuspendedWrite() async throws {
        for holdAfterOpen in [false, true] {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("LibraryFeedPhysicalOwner-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let originalURL = root.appendingPathComponent("original.realm")
            let retainedURL = root.appendingPathComponent("retained-original.realm")
            let replacementURL = root.appendingPathComponent("replacement.realm")
            let config = fileConfiguration(at: originalURL)
            // Restore the captured path before eviction: its resource ID is
            // part of the cache key. Writer teardowns registered below run first.
            addTeardownBlock {
                if FileManager.default.fileExists(atPath: retainedURL.path) {
                    if FileManager.default.fileExists(atPath: originalURL.path) {
                        try FileManager.default.moveItem(at: originalURL, to: root.appendingPathComponent("discarded.realm"))
                    }
                    try FileManager.default.moveItem(at: retainedURL, to: originalURL)
                }
                await RealmBackgroundActor.shared.removeCachedRealm(for: config)
                try FileManager.default.removeItem(at: root)
            }
            let realm = try await Realm(configuration: config, actor: MainActor.shared)
            let feed = try installFeed(in: realm)
            let category = try XCTUnwrap(feed.getCategory())
            let identity = try XCTUnwrap(LibraryFeedPresentationIdentity(feed: feed))
            let originalKey = RealmBackgroundActor.shared.realmCacheKey(for: config)
            let retired = expectation(description: "Captured storage editor retirement finished")
            let model = LibraryFeedFormSectionsViewModel(
                feed: feed, observesRealm: false, retirementDidFinish: { retired.fulfill() }
            )
            addTeardownBlock {
                let result = await XCTWaiter.fulfillment(of: [retired], timeout: 5)
                XCTAssertEqual(result, .completed)
            }
            let replacementConfig = fileConfiguration(at: replacementURL)
            try autoreleasepool {
                let replacementRealm = try Realm(configuration: replacementConfig)
                let replacementCategory = FeedCategory()
                replacementCategory.id = category.id
                replacementCategory.createdAt = category.createdAt
                let replacement = Feed()
                replacement.id = feed.id
                replacement.createdAt = feed.createdAt
                replacement.categoryID = replacementCategory.id
                replacement.title = "Replacement"
                replacement.rssUrl = feed.rssUrl
                try replacementRealm.write { replacementRealm.add(replacementCategory); replacementRealm.add(replacement) }
                let replacementIdentity = try XCTUnwrap(LibraryFeedPresentationIdentity(feed: replacement))
                XCTAssertEqual(replacementIdentity.feedRowKey, identity.feedRowKey)
                XCTAssertEqual(replacementIdentity.categoryRowKey, identity.categoryRowKey)
                XCTAssertTrue(replacementRealm.objects(BigSyncPendingMutation.self).isEmpty)
                replacementRealm.invalidate()
            }
            let replacementBytes = try Data(contentsOf: replacementURL)
            let started = expectation(description: "Captured store opened before write suspension")
            let gate = LibraryFeedContinuationGate()
            var writer: Task<Void, Error>?
            if holdAfterOpen {
                writer = model.writeFeedAsync(field: .title, beforeWrite: {
                    await gate.wait(onFirstWait: { started.fulfill() })
                }) { feed in feed.title = "Obsolete"; return true }
            }
            let suspendedWriter = writer
            addTeardownBlock {
                suspendedWriter?.cancel()
                await gate.release()
                _ = await suspendedWriter?.result
            }
            if holdAfterOpen { await fulfillment(of: [started], timeout: 5) }
            try FileManager.default.moveItem(at: originalURL, to: retainedURL)
            try FileManager.default.moveItem(at: replacementURL, to: originalURL)
            XCTAssertNotEqual(RealmBackgroundActor.shared.realmCacheKey(for: config), originalKey,
                "The fixture must replace the actual filesystem resource identity")
            if writer == nil {
                writer = model.writeFeedAsync(field: .title) { feed in feed.title = "Obsolete"; return true }
            }
            let attempt = try XCTUnwrap(writer)
            addTeardownBlock { attempt.cancel(); await gate.release(); _ = await attempt.result }
            await gate.release()
            do {
                try await attempt.value
                XCTFail("A captured editor must reject replacement storage")
            } catch RealmBackgroundActorError.realmFileChangedDuringOpen {
                // Expected admission failure, not a successful no-op/rebind.
            }
            realm.refresh()
            XCTAssertEqual(feed.title, "Original", "The detached original owner remains readable and unchanged")
            XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
            XCTAssertEqual(try Data(contentsOf: originalURL), replacementBytes,
                "The replacement file, including its empty journal, must remain unchanged")
        }
    }

    func testMetadataStartedAfterHumanReservationCannotOvertakeItsPendingValueOrExplicitEmptyInput() async throws {
        for humanTitle in ["Human", ""] {
            let realm = try await Realm(configuration: configuration(), actor: MainActor.shared)
            let feed = try installFeed(in: realm, title: "")
            let humanEditor = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false)
            let started = expectation(description: "Human intent reserved before metadata request starts")
            let gate = LibraryFeedContinuationGate()
            let human = humanEditor.writeFeedAsync(field: .title, beforeWrite: {
                await gate.wait(onFirstWait: { started.fulfill() })
            }) { feed in
                guard feed.title != humanTitle else { return false }
                feed.title = humanTitle
                return true
            }
            addTeardownBlock { human.cancel(); await gate.release(); _ = await human.result }
            await fulfillment(of: [started], timeout: 5)
            let metadataEditor = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false)
            let source = feed.rssUrl
            let generation = UUID()
            metadataEditor.beginMetadataRefresh(rssURL: source, identifier: generation)
            await metadataEditor.refreshFromOpenGraph(expectedRSSURL: source, expectedGeneration: generation) { _ in
                LibraryFeedOpenGraphMetadata(url: source.domainURL, title: "Automatic", description: nil)
            }
            realm.refresh()
            XCTAssertEqual(feed.title, "")
            XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
            await gate.release()
            try await human.value
            realm.refresh()
            XCTAssertEqual(feed.title, humanTitle)
            XCTAssertEqual(realm.objects(BigSyncPendingMutation.self).count, humanTitle.isEmpty ? 0 : 1)
        }
    }

    func testUntouchedOtherFeedAndReplacementOwnerMayFillMetadataWhileOldHumanInputIsPending() async throws {
        for replaceOriginal in [false, true] {
            let realm = try await Realm(configuration: configuration(), actor: MainActor.shared)
            let original = try installFeed(in: realm, title: "")
            let originalID = original.id
            let originalCategoryID = original.categoryID
            let originalDate = original.createdAt
            let originalURL = original.rssUrl
            let oldEditor = LibraryFeedFormSectionsViewModel(feed: original, observesRealm: false)
            let started = expectation(description: "Old physical owner retains its human reservation")
            let gate = LibraryFeedContinuationGate()
            let human = oldEditor.writeFeedAsync(field: .title, beforeWrite: {
                await gate.wait(onFirstWait: { started.fulfill() })
            }) { feed in feed.title = "Human"; return true }
            addTeardownBlock { human.cancel(); await gate.release(); _ = await human.result }
            await fulfillment(of: [started], timeout: 5)
            let target: Feed
            if replaceOriginal {
                target = Feed()
                target.id = originalID
                target.categoryID = originalCategoryID
                target.createdAt = originalDate
                target.title = ""
                target.rssUrl = originalURL
                try realm.write { realm.delete(original); realm.add(target) }
            } else {
                target = try installFeed(in: realm, title: "")
            }
            let metadataEditor = LibraryFeedFormSectionsViewModel(feed: target.freeze(), observesRealm: false)
            XCTAssertNotEqual(metadataEditor.presentationIdentity, oldEditor.presentationIdentity)
            let source = target.rssUrl
            let generation = UUID()
            metadataEditor.beginMetadataRefresh(rssURL: source, identifier: generation)
            await metadataEditor.refreshFromOpenGraph(expectedRSSURL: source, expectedGeneration: generation) { _ in
                LibraryFeedOpenGraphMetadata(url: source.domainURL, title: "Automatic", description: nil)
            }
            realm.refresh()
            XCTAssertEqual(target.title, "Automatic")
            XCTAssertEqual(realm.objects(BigSyncPendingMutation.self).count, 1)
            await gate.release()
            try await human.value
            realm.refresh()
            XCTAssertEqual(target.title, "Automatic", "An old owner cannot borrow the successor's physical row")
            if !replaceOriginal { XCTAssertEqual(original.title, "Human") }
            XCTAssertEqual(realm.objects(BigSyncPendingMutation.self).count, replaceOriginal ? 1 : 2)
        }
    }

    func testPresentationReadinessAndQueuedCancellationPreserveForeignWriterBeforeHumanCommit() async throws {
        for cancelQueuedEditor in [false, true] {
            let config = configuration()
            let realm = try await Realm(configuration: config, actor: MainActor.shared)
            let feed = try installFeed(in: realm)
            let feedID = feed.id
            let started = expectation(description: "Another caller owns the background Realm transaction")
            let gate = LibraryFeedContinuationGate()
            let foreign = Task { @RealmBackgroundActor in
                let writerRealm = try await RealmBackgroundActor.shared.cachedRealm(for: config)
                try writerRealm.beginWrite()
                var ownsTransaction = true
                defer { if ownsTransaction && writerRealm.isInWriteTransaction { writerRealm.cancelWrite() } }
                let original = try XCTUnwrap(writerRealm.object(ofType: Feed.self, forPrimaryKey: feedID))
                original.markdownDescription = "Foreign description"
                original.refreshChangeMetadata(explicitlyModified: true)
                await gate.wait(onFirstWait: { started.fulfill() })
                XCTAssertTrue(writerRealm.isInWriteTransaction, "The queued editor must not end the foreign transaction")
                XCTAssertEqual(original.markdownDescription, "Foreign description")
                try writerRealm.commitWrite()
                // Commit may admit the queued successor before returning. Its
                // transaction must never be cancelled by this fixture's defer.
                ownsTransaction = false
            }
            addTeardownBlock { foreign.cancel(); await gate.release(); _ = await foreign.result }
            await fulfillment(of: [started], timeout: 5)
            let ready = expectation(description: "UI presentation observers installed while background writer is held")
            let model = LibraryFeedFormSectionsViewModel(
                feed: feed.freeze(), observesRealm: true, observesFormInput: false,
                didInstallOwnershipObservers: { ready.fulfill() }
            )
            addTeardownBlock {
                await gate.release()
                _ = await foreign.result
                _ = await model.finishEditing().result
                await model.stopObserving()
            }
            await fulfillment(of: [ready], timeout: 5)
            XCTAssertFalse(model.ownershipRetired)
            XCTAssertTrue(model.canEdit)
            let queued = expectation(description: "Editor begin ticket queued behind the foreign writer")
            let editor = RealmWriteSubmissionObservation.$willSubmit.withValue({
                // The hook runs before begin submission; this actor turn can
                // run only after the caller queues its ticket and suspends.
                Task { @RealmBackgroundActor in queued.fulfill() }
            }) {
                model.writeFeedAsync(field: .title) { feed in
                    guard feed.title != "Queued human" else { return false }
                    feed.title = "Queued human"
                    return true
                }
            }
            let editorSettled = XCTestExpectation(description: "Queued editor settles before the foreign writer is released")
            let settlement = Task { @MainActor in
                let result = await editor.result
                editorSettled.fulfill()
                return result
            }
            addTeardownBlock {
                editor.cancel()
                await gate.release()
                _ = await foreign.result
                _ = await settlement.value
            }
            await fulfillment(of: [queued], timeout: 5)
            if cancelQueuedEditor {
                editor.cancel()
                let promptSettlement = await XCTWaiter.fulfillment(of: [editorSettled], timeout: 5)
                XCTAssertEqual(promptSettlement, .completed, "Queued cancellation must settle while the foreign gate remains held")
                if promptSettlement == .completed {
                    switch await settlement.value {
                    case .success:
                        XCTFail("A cancelled queued attempt must report cancellation")
                    case .failure(let error):
                        XCTAssertTrue(error is CancellationError)
                    }
                }
                let foreignState = try await { @RealmBackgroundActor in
                    let writerRealm = try await RealmBackgroundActor.shared.cachedRealm(for: config)
                    let original = try XCTUnwrap(writerRealm.object(ofType: Feed.self, forPrimaryKey: feedID))
                    return (writerRealm.isInWriteTransaction, original.title, original.markdownDescription)
                }()
                XCTAssertTrue(foreignState.0, "Cancellation must leave the foreign owner active before release")
                XCTAssertEqual(foreignState.1, "Original", "The queued editor must not mutate the held transaction")
                XCTAssertEqual(foreignState.2, "Foreign description")
            }
            // Always break the foreign-writer dependency before final joins,
            // including when the bounded prompt-cancellation assertion failed.
            await gate.release()
            try await foreign.value
            _ = await settlement.value
            if !cancelQueuedEditor { try await editor.value }
            try await model.finishEditing().value
            realm.refresh()
            XCTAssertEqual(feed.title, "Queued human")
            XCTAssertEqual(feed.markdownDescription, "Foreign description")
            XCTAssertFalse(model.ownershipRetired)
            XCTAssertEqual(realm.objects(BigSyncPendingMutation.self).count, 1)
            XCTAssertEqual(realm.objects(BigSyncPendingMutation.self).first?.changedAt, feed.explicitlyModifiedAt)
        }
    }

    func testBufferedHumanInputSurvivesTemporaryReadOnlyPolicyAndFinishRetriesExactlyOnce() async throws {
        let realm = try await Realm(configuration: configuration(), actor: MainActor.shared)
        let feed = try installFeed(in: realm)
        let category = try XCTUnwrap(feed.getCategory())
        let started = expectation(description: "Published human command held before its owned writer")
        let gate = LibraryFeedContinuationGate()
        let attempts = LibraryFeedWriteAttempts()
        let model = LibraryFeedFormSectionsViewModel(
            feed: feed.freeze(), observesRealm: true, beforeFieldWrite: {
                if await attempts.record() == 1 {
                    await gate.wait(onFirstWait: { started.fulfill() })
                }
            }
        )
        addTeardownBlock { await model.stopObserving() }
        model.isEditing = true
        model.feedTitle = "Retained human draft"
        let deferred = model.finishEditing()
        addTeardownBlock {
            await gate.release()
            _ = await deferred.result
            _ = await model.finishEditing().result
        }
        await fulfillment(of: [started], timeout: 5)
        try realm.write { category.opmlURL = URL(string: "https://example.com/managed.opml") }
        await gate.release()
        try await deferred.value
        realm.refresh()
        model.refresh()
        XCTAssertEqual(feed.title, "Original")
        XCTAssertEqual(model.feedTitle, "Retained human draft")
        XCTAssertFalse(model.ownershipRetired)
        XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
        let deferredAttempts = await attempts.count
        XCTAssertEqual(deferredAttempts, 1)
        try realm.write { category.opmlURL = nil }
        try await model.finishEditing().value
        realm.refresh()
        XCTAssertEqual(feed.title, "Retained human draft")
        XCTAssertEqual(model.feedTitle, "Retained human draft")
        XCTAssertEqual(realm.objects(BigSyncPendingMutation.self).count, 1)
        XCTAssertEqual(realm.objects(BigSyncPendingMutation.self).first?.changedAt, feed.explicitlyModifiedAt)
        try await model.finishEditing().value
        let completedAttempts = await attempts.count
        XCTAssertEqual(completedAttempts, 2)
    }

    func testDeinitRetriesAnActiveDeferredCommandOnceWhenItsOriginalCategoryBecomesEditable() async throws {
        let fixtureConfiguration = configuration()
        let realm = try await Realm(configuration: fixtureConfiguration, actor: MainActor.shared)
        let feed = try installFeed(in: realm)
        let category = try XCTUnwrap(feed.getCategory())
        let started = expectation(description: "Active human command held before policy admission")
        let retryStarted = expectation(description: "Retirement retries the joined deferred command")
        let retired = expectation(description: "Deferred retirement retry completed")
        let gate = LibraryFeedContinuationGate()
        let retryGate = LibraryFeedContinuationGate()
        let retirementQueued = XCTestExpectation(description: "Retirement's actual owned-write ticket was submitted")
        var model: LibraryFeedFormSectionsViewModel? = LibraryFeedFormSectionsViewModel(
            feed: feed, observesRealm: false, observesFormInput: true,
            beforeFieldWrite: { await gate.wait(onFirstWait: { started.fulfill() }) },
            retirementDidFinish: { retired.fulfill() }
        )
        weak var retiringModel = model
        model?.feedTitle = "Retired deferred draft"
        let finish = model?.finishEditing()
        addTeardownBlock { [weak retiringModel] in
            await gate.release()
            await retryGate.release()
            _ = await finish?.result
            // A retention regression must not strand the real active command
            // or presentation resources while the weak-reference assertion fails.
            if let retainedModel = retiringModel {
                _ = await retainedModel.finishEditing().result
                await retainedModel.stopObserving()
            }
            try await self.settleSubmittedRetirement(retirementQueued, configuration: fixtureConfiguration)
        }
        try await RealmStorageAdmissionObservation.$didOpenRealm.withValue({
            await retryGate.wait(onFirstWait: { retryStarted.fulfill() })
        }) {
            try await RealmWriteSubmissionObservation.$willSubmit.withValue({
                // Foreground tasks predate this marker. Its same-actor witness
                // follows the retirement caller's actual SDK begin submission.
                Task { @RealmBackgroundActor in retirementQueued.fulfill() }
            }) {
                defer { model = nil }
                let joinedFinish = try XCTUnwrap(finish)
                await fulfillment(of: [started], timeout: 5)
                try realm.write { category.opmlURL = URL(string: "https://example.com/managed.opml") }
                model = nil
                XCTAssertNil(retiringModel)
                await gate.release()
                try await joinedFinish.value
                await fulfillment(of: [retryStarted], timeout: 5)
                realm.refresh()
                XCTAssertEqual(feed.title, "Original")
                XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
                try realm.write { category.opmlURL = nil }
                await retryGate.release()
                await fulfillment(of: [retired], timeout: 5)
                realm.refresh()
                XCTAssertEqual(feed.title, "Retired deferred draft")
                XCTAssertEqual(realm.objects(BigSyncPendingMutation.self).count, 1)
            }
        }
    }

    private func settleSubmittedRetirement(
        _ queued: XCTestExpectation, configuration: Realm.Configuration
    ) async throws {
        let submitted = await XCTWaiter.fulfillment(of: [queued], timeout: 5)
        XCTAssertEqual(submitted, .completed, "Missing retirement submission must fail boundedly")
        guard submitted == .completed else {
            // No witnessed ticket means no claim to drain a private future task.
            return
        }
        // The same-actor witness runs only after the actual begin ticket was
        // queued. This read-only transaction settles that prior admitted write,
        // independently of the retirement callback being asserted by the test.
        try await { @RealmBackgroundActor in
            let writerRealm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            try await writerRealm.asyncWritePreservingOwnership {
                _ = writerRealm.objects(Feed.self).count
            }
        }()
    }

    private func fileConfiguration(at url: URL) -> Realm.Configuration {
        var value = Realm.Configuration(fileURL: url)
        value.objectTypes = [
            LibraryConfiguration.self, FeedCategory.self, Feed.self, FeedEntry.self,
            FeedDirectory.self, UserScript.self, UserScriptAllowedDomain.self,
        ]
        configureLakeOfFireMutationTrackingForTesting(&value)
        return value
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
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var hasWaited = false
    private var released = false
    func wait(onFirstWait: (@Sendable () -> Void)? = nil) async {
        guard !released else { return }
        await withCheckedContinuation {
            continuations.append($0)
            if !hasWaited {
                hasWaited = true
                onFirstWait?()
            }
        }
    }
    func release() {
        released = true
        let waiting = continuations
        continuations.removeAll()
        for continuation in waiting { continuation.resume() }
    }
}

private actor LibraryFeedWriteAttempts {
    private(set) var count = 0
    func record() -> Int { count += 1; return count }
}
