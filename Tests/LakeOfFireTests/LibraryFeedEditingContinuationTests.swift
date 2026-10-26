import BigSyncKit
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
        let realm = try await Realm(configuration: configuration(), actor: MainActor.shared)
        let feed = try installFeed(in: realm)
        let started = expectation(description: "Active writer registered before retirement")
        let retired = expectation(description: "Retirement batch durably settled")
        let gate = LibraryFeedContinuationGate()
        let retirementFinished = LibraryFeedContinuationGate()
        var model: LibraryFeedFormSectionsViewModel? = LibraryFeedFormSectionsViewModel(
            feed: feed, observesRealm: false, observesFormInput: true,
            beforeFieldWrite: {
                await gate.wait(onFirstWait: { started.fulfill() })
                throw InjectedFailure.admission
            },
            retirementDidFinish: {
                retired.fulfill()
                Task { await retirementFinished.release() }
            }
        )
        weak var retiringModel = model
        model?.feedTitle = "Retired captured draft"
        await fulfillment(of: [started], timeout: 5)
        let finish = try XCTUnwrap(model).finishEditing()
        addTeardownBlock {
            await gate.release()
            _ = await finish.result
            await retirementFinished.wait()
        }
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
        let retirementFinished = LibraryFeedContinuationGate()
        var model: LibraryFeedFormSectionsViewModel? = LibraryFeedFormSectionsViewModel(
            feed: feed, observesRealm: false, observesFormInput: true,
            beforeFieldWrite: { await gate.wait(onFirstWait: { started.fulfill() }) },
            retirementDidFinish: {
                retired.fulfill()
                Task { await retirementFinished.release() }
            }
        )
        let paste = try XCTUnwrap(model).pasteRSSURL(strings: ["https://older.example/feed.xml"])
        addTeardownBlock {
            paste.cancel()
            await gate.release()
            _ = try? await paste.value
            await retirementFinished.wait()
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
