import BigSyncKit
import Foundation
import RealmSwift
@testable import RealmSwiftGaps
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireLibrary

private actor CategoryFieldWriteGate {
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

private actor CategoryFieldWriteAttempts {
    private(set) var count = 0
    func record() { count += 1 }
}

/// Observe real owned-write commit submissions without adding a writer model.
private final class CategoryFieldCommitCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func record() {
        lock.lock()
        defer { lock.unlock() }
        value += 1
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class CategoryFieldRetirementObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var mayFinish = false
    private let premature: XCTestExpectation
    private let completed: XCTestExpectation

    init(premature: XCTestExpectation, completed: XCTestExpectation) {
        self.premature = premature
        self.completed = completed
    }

    func allowFinish() {
        lock.lock()
        defer { lock.unlock() }
        mayFinish = true
    }

    func didFinish() {
        lock.lock()
        let finishedPrematurely = !mayFinish
        lock.unlock()
        if finishedPrematurely { premature.fulfill() }
        completed.fulfill()
    }
}

private struct CategoryFieldDiskSnapshot: Equatable, Sendable {
    let title: String
    let createdAt: Date
    let isDeleted: Bool
    let modifiedAt: Date
    let explicitlyModifiedAt: Date?
    let generations: [String: String]
}

private struct CategoryFieldDiskFixture: Sendable {
    let configuration: Realm.Configuration
    let replacementConfiguration: Realm.Configuration
    let retiredConfiguration: Realm.Configuration
    let owner: LibraryCategoryFieldOwner
    let original: CategoryFieldDiskSnapshot
    let replacement: CategoryFieldDiskSnapshot
}

@MainActor
final class LibraryCategoryFieldOwnershipTests: XCTestCase, @unchecked Sendable {
    private enum InjectedFailure: Error { case admission }

    private func fixture(id: UUID = UUID()) async throws -> (Realm, FeedCategory, LibraryConfiguration) {
        var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        configuration.objectTypes = [FeedCategory.self, LibraryConfiguration.self, UserScript.self]
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        let captured = configuration
        addTeardownBlock { await RealmBackgroundActor.shared.removeCachedRealm(for: captured) }
        let realm = try await Realm(configuration: captured, actor: MainActor.shared)
        try await Task { @RealmBackgroundActor in
            let writer = try await RealmBackgroundActor.shared.cachedRealm(for: captured)
            try await writer.asyncWrite {
                let category = FeedCategory()
                category.id = id
                category.createdAt = Date(timeIntervalSinceReferenceDate: 100)
                category.title = "Original"
                category.backgroundImageUrl = URL(string: "about:blank")!
                writer.add(category)
                category.refreshChangeMetadata(explicitlyModified: true)
                let library = LibraryConfiguration()
                library.categoryIDs.append(id)
                writer.add(library)
                library.refreshChangeMetadata(explicitlyModified: true)
            }
        }.value
        realm.refresh()
        return (
            realm,
            try XCTUnwrap(realm.object(ofType: FeedCategory.self, forPrimaryKey: id)),
            try XCTUnwrap(realm.objects(LibraryConfiguration.self).first)
        )
    }

    private func model(
        _ category: FeedCategory,
        _ library: LibraryConfiguration,
        beforeFieldWrite: (@RealmBackgroundActor @Sendable () async throws -> Void)? = nil,
        retirementDidFinish: (@RealmBackgroundActor @Sendable () -> Void)? = nil
    ) -> LibraryCategoryViewModel {
        LibraryCategoryViewModel(
            category: category, libraryConfiguration: library, selectedFeed: .constant(nil),
            observesRealm: false, beforeFieldWrite: beforeFieldWrite,
            retirementDidFinish: retirementDidFinish
        )
    }

    private func generations(_ realm: Realm) -> [String: String] {
        Dictionary(uniqueKeysWithValues:
            realm.objects(BigSyncPendingMutation.self).map { ($0.recordName, $0.generation) }
        )
    }

    func testImmediateDonePreservesFinalBufferedTitleAndImage() async throws {
        let (realm, category, library) = try await fixture()
        let editor = model(category, library)
        editor.isEditing = true
        editor.categoryTitle = "Leading"
        editor.categoryTitle = "Final"
        editor.categoryBackgroundImageURL = "https://leading.example/image.png"
        editor.categoryBackgroundImageURL = "https://final.example/image.png"
        let completion = editor.finishEditing()
        editor.refresh()
        XCTAssertEqual(editor.categoryTitle, "Final")
        try await completion.value
        realm.refresh()
        XCTAssertEqual(category.title, "Final")
        XCTAssertEqual(category.backgroundImageUrl.absoluteString, "https://final.example/image.png")
    }

    func testHydrationAndRepeatedInputDoNotJournal() async throws {
        let (realm, category, library) = try await fixture()
        let before = generations(realm)
        let editor = model(category, library)
        editor.refresh()
        try await editor.finishEditing().value
        try await editor.writeFieldAsync(.title("Original")).value
        try await editor.writeFieldAsync(.imageURL("")).value
        realm.refresh()
        XCTAssertEqual(generations(realm), before)
    }

    func testOlderSuspendedWriteCannotOverwriteNewerInput() async throws {
        let (realm, category, library) = try await fixture()
        let editor = model(category, library)
        let gate = CategoryFieldWriteGate()
        let started = expectation(description: "old write suspended")
        let oldWrite = editor.writeFieldAsync(.title("Old"), beforeWrite: {
            started.fulfill()
            await gate.wait()
        })
        addTeardownBlock { oldWrite.cancel(); await gate.release(); _ = await oldWrite.result }
        await fulfillment(of: [started], timeout: 5)
        try await editor.writeFieldAsync(.title("Newest")).value
        realm.refresh()
        let before = generations(realm)
        await gate.release()
        try await oldWrite.value
        realm.refresh()
        XCTAssertEqual(category.title, "Newest")
        XCTAssertEqual(editor.categoryTitle, "Newest")
        XCTAssertEqual(generations(realm), before)
    }

    func testPendingWriteStaysInOriginalRealmWithIdenticalIDs() async throws {
        let (original, category, library) = try await fixture()
        let (replacement, otherCategory, otherLibrary) = try await fixture(id: category.id)
        let editor = model(category, library)
        try await editor.writeFieldAsync(.title("Original store edit")).value
        original.refresh()
        replacement.refresh()
        XCTAssertEqual(category.title, "Original store edit")
        XCTAssertEqual(otherCategory.title, "Original")
        XCTAssertNotEqual(
            LibraryCategoryEditorIdentity(category: category, library: library),
            LibraryCategoryEditorIdentity(category: otherCategory, library: otherLibrary)
        )
    }

    func testReopenedEditorSharesOrderingWithPendingOlderCommand() async throws {
        let (realm, category, library) = try await fixture()
        let firstEditor = model(category, library)
        let gate = CategoryFieldWriteGate()
        let started = expectation(description: "first editor suspended")
        let oldWrite = firstEditor.writeFieldAsync(.title("Old"), beforeWrite: {
            started.fulfill()
            await gate.wait()
        })
        addTeardownBlock { oldWrite.cancel(); await gate.release(); _ = await oldWrite.result }
        await fulfillment(of: [started], timeout: 5)
        let secondEditor = model(category, library)
        try await secondEditor.writeFieldAsync(.title("New editor")).value
        await gate.release()
        try await oldWrite.value
        realm.refresh()
        XCTAssertEqual(category.title, "New editor")
    }

    func testQueuedWriteRejectsNewManagedEligibility() async throws {
        let (realm, category, library) = try await fixture()
        let editor = model(category, library)
        let id = category.id
        let configuration = realm.configuration
        let gate = CategoryFieldWriteGate()
        let started = expectation(description: "write suspended")
        let write = editor.writeFieldAsync(.title("Rejected"), beforeWrite: {
            started.fulfill()
            await gate.wait()
        })
        addTeardownBlock { write.cancel(); await gate.release(); _ = await write.result }
        await fulfillment(of: [started], timeout: 5)
        try await Task { @RealmBackgroundActor in
            let writer = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            try await writer.asyncWrite {
                writer.object(ofType: FeedCategory.self, forPrimaryKey: id)?.opmlURL =
                    URL(string: "https://example.com/managed.opml")
            }
        }.value
        realm.refresh()
        let before = generations(realm)
        await gate.release()
        try await write.value
        realm.refresh()
        XCTAssertEqual(category.title, "Original")
        XCTAssertEqual(editor.categoryTitle, "Original")
        XCTAssertEqual(generations(realm), before)
    }

    func testRetirementFlushesFinalBufferedDraft() async throws {
        let (realm, category, library) = try await fixture()
        let retired = expectation(description: "Final buffered category draft settled on retirement")
        var editor: LibraryCategoryViewModel? = model(
            category, library, retirementDidFinish: { retired.fulfill() }
        )
        weak var retiringEditor = editor
        editor?.isEditing = true
        editor?.categoryTitle = "Leading"
        editor?.categoryTitle = "Retired final"
        editor = nil
        XCTAssertNil(retiringEditor)
        await fulfillment(of: [retired], timeout: 5)
        realm.refresh()
        XCTAssertEqual(category.title, "Retired final")
    }

    func testEarlierUserValueCanReturnAfterHydration() async throws {
        let (realm, category, library) = try await fixture()
        let editor = model(category, library)
        try await editor.writeFieldAsync(.title("User value")).value
        let configuration = realm.configuration
        let id = category.id
        try await Task { @RealmBackgroundActor in
            let writer = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            try await writer.asyncWrite {
                writer.object(ofType: FeedCategory.self, forPrimaryKey: id)?.title = "External value"
            }
        }.value
        editor.refresh()
        XCTAssertEqual(editor.categoryTitle, "External value")
        editor.categoryTitle = "User value"
        try await editor.finishEditing().value
        realm.refresh()
        XCTAssertEqual(category.title, "User value")
    }

    func testCancellationBeforeAdmissionPreservesDraftForExplicitRetry() async throws {
        let (realm, category, library) = try await fixture()
        let before = generations(realm)
        let editor = model(category, library)
        let gate = CategoryFieldWriteGate()
        let started = expectation(description: "write waiting before admission")
        let write = editor.writeFieldAsync(.title("Retry this draft"), beforeWrite: {
            started.fulfill()
            await gate.wait()
        })
        addTeardownBlock { write.cancel(); await gate.release(); _ = await write.result }
        await fulfillment(of: [started], timeout: 5)
        write.cancel()
        await gate.release()
        do {
            try await write.value
            XCTFail("Cancelled uncommitted write must not report success")
        } catch is CancellationError {
        }
        realm.refresh()
        XCTAssertEqual(category.title, "Original")
        XCTAssertEqual(editor.categoryTitle, "Retry this draft")
        XCTAssertEqual(generations(realm), before)

        try await editor.finishEditing().value
        realm.refresh()
        XCTAssertEqual(category.title, "Retry this draft")
        XCTAssertNotEqual(generations(realm), before)
    }

    func testPostSubmissionCancellationSettlesDurableFieldWithoutRejournaling() async throws {
        let (realm, category, library) = try await fixture()
        let editor = model(category, library)
        let write = RealmWriteCommitObservation.$didSubmit.withValue({
            withUnsafeCurrentTask { $0?.cancel() }
        }) {
            editor.writeFieldAsync(.title("Durable draft"))
        }
        try await write.value
        XCTAssertTrue(write.isCancelled)
        realm.refresh()
        XCTAssertEqual(category.title, "Durable draft")
        XCTAssertEqual(editor.categoryTitle, "Durable draft")
        let afterCommit = generations(realm)
        try await editor.finishEditing().value
        realm.refresh()
        XCTAssertEqual(generations(realm), afterCommit)
    }

    func testQueuedWriteRejectsSameIDNewIncarnation() async throws {
        let (realm, category, library) = try await fixture()
        let editor = model(category, library)
        let id = category.id
        let configuration = realm.configuration
        let gate = CategoryFieldWriteGate()
        let started = expectation(description: "write suspended")
        let write = editor.writeFieldAsync(.title("Retired draft"), beforeWrite: {
            started.fulfill()
            await gate.wait()
        })
        addTeardownBlock { write.cancel(); await gate.release(); _ = await write.result }
        await fulfillment(of: [started], timeout: 5)
        try await Task { @RealmBackgroundActor in
            let writer = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            try await writer.asyncWrite {
                if let old = writer.object(ofType: FeedCategory.self, forPrimaryKey: id) { writer.delete(old) }
                let replacement = FeedCategory()
                replacement.id = id
                replacement.createdAt = Date(timeIntervalSinceReferenceDate: 200)
                replacement.title = "Replacement"
                writer.add(replacement)
            }
        }.value
        await gate.release()
        try await write.value
        realm.refresh()
        XCTAssertEqual(realm.object(ofType: FeedCategory.self, forPrimaryKey: id)?.title, "Replacement")
    }

    func testDoneRetiresTitleBeforeItsQueuedTrailingDelivery() async throws {
        let (realm, category, library) = try await fixture()
        let attempts = CategoryFieldWriteAttempts()
        let trailingFinished = expectation(description: "settled title trailing delivery completed")
        // The real Combine operator uses this main-targeted queue. Suspension holds
        // only its scheduled trailing delivery, not the leading input or Realm work.
        let scheduler = DispatchQueue(label: "category-title-debounce", target: .main)
        scheduler.suspend()
        var schedulerIsSuspended = true
        defer { if schedulerIsSuspended { scheduler.resume() } }
        let editor = LibraryCategoryViewModel(
            category: category, libraryConfiguration: library, selectedFeed: .constant(nil),
            observesRealm: false, beforeFieldWrite: { await attempts.record() },
            fieldDebounceScheduler: scheduler,
            debouncedWriteDidFinish: { edit in
                if edit == .title("Final local title") { trailingFinished.fulfill() }
            }
        )
        editor.isEditing = true
        editor.categoryTitle = "Leading local title"
        editor.categoryTitle = "Final local title"
        try await editor.finishEditing().value
        let finishedAttempts = await attempts.count
        realm.refresh()
        XCTAssertEqual(category.title, "Final local title")

        let configuration = realm.configuration
        let id = category.id
        try await Task { @RealmBackgroundActor in
            let writer = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            try await writer.asyncWritePreservingOwnership {
                let current = try XCTUnwrap(writer.object(ofType: FeedCategory.self, forPrimaryKey: id))
                current.title = "Remote after Done"
                current.refreshChangeMetadata(explicitlyModified: true)
            }
        }.value
        editor.refresh()
        realm.refresh()
        let afterRemote = generations(realm)
        XCTAssertEqual(editor.categoryTitle, "Remote after Done")

        schedulerIsSuspended = false
        scheduler.resume()
        await fulfillment(of: [trailingFinished], timeout: 5)
        let afterTrailingAttempts = await attempts.count
        XCTAssertEqual(afterTrailingAttempts, finishedAttempts)
        realm.refresh()
        XCTAssertEqual(category.title, "Remote after Done")
        XCTAssertEqual(editor.categoryTitle, "Remote after Done")
        XCTAssertEqual(generations(realm), afterRemote)
    }

    func testDoneRetiresImageBeforeItsQueuedTrailingDelivery() async throws {
        let (realm, category, library) = try await fixture()
        let attempts = CategoryFieldWriteAttempts()
        let trailingFinished = expectation(description: "settled image trailing delivery completed")
        let finalURL = "https://local.example/final.png"
        let remoteURL = URL(string: "https://remote.example/after-done.png")!
        let scheduler = DispatchQueue(label: "category-image-debounce", target: .main)
        scheduler.suspend()
        var schedulerIsSuspended = true
        defer { if schedulerIsSuspended { scheduler.resume() } }
        let editor = LibraryCategoryViewModel(
            category: category, libraryConfiguration: library, selectedFeed: .constant(nil),
            observesRealm: false, beforeFieldWrite: { await attempts.record() },
            fieldDebounceScheduler: scheduler,
            debouncedWriteDidFinish: { edit in
                if edit == .imageURL(finalURL) { trailingFinished.fulfill() }
            }
        )
        editor.isEditing = true
        editor.categoryBackgroundImageURL = "https://local.example/leading.png"
        editor.categoryBackgroundImageURL = finalURL
        try await editor.finishEditing().value
        let finishedAttempts = await attempts.count
        realm.refresh()
        XCTAssertEqual(category.backgroundImageUrl.absoluteString, finalURL)

        let configuration = realm.configuration
        let id = category.id
        try await Task { @RealmBackgroundActor in
            let writer = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            try await writer.asyncWritePreservingOwnership {
                let current = try XCTUnwrap(writer.object(ofType: FeedCategory.self, forPrimaryKey: id))
                current.backgroundImageUrl = remoteURL
                current.refreshChangeMetadata(explicitlyModified: true)
            }
        }.value
        editor.refresh()
        realm.refresh()
        let afterRemote = generations(realm)
        XCTAssertEqual(editor.categoryBackgroundImageURL, remoteURL.absoluteString)

        schedulerIsSuspended = false
        scheduler.resume()
        await fulfillment(of: [trailingFinished], timeout: 5)
        let afterTrailingAttempts = await attempts.count
        XCTAssertEqual(afterTrailingAttempts, finishedAttempts)
        realm.refresh()
        XCTAssertEqual(category.backgroundImageUrl, remoteURL)
        XCTAssertEqual(editor.categoryBackgroundImageURL, remoteURL.absoluteString)
        XCTAssertEqual(generations(realm), afterRemote)
    }

    func testRetirementJoinsSuccessfulActiveAttemptWithoutReplayingIt() async throws {
        let (realm, category, library) = try await fixture()
        let gate = CategoryFieldWriteGate()
        let started = expectation(description: "Successful category attempt is held before admission")
        let premature = expectation(description: "Retirement cannot finish before its active attempt")
        premature.isInverted = true
        let retired = expectation(description: "Retirement joined the successful attempt")
        let retirement = CategoryFieldRetirementObservation(premature: premature, completed: retired)
        let commits = CategoryFieldCommitCount()
        var editor: LibraryCategoryViewModel? = model(
            category, library,
            beforeFieldWrite: { await gate.wait(onFirstWait: { started.fulfill() }) },
            retirementDidFinish: { retirement.didFinish() }
        )
        weak var retiringEditor = editor
        let write = try RealmWriteCommitObservation.$didSubmit.withValue({ commits.record() }) {
            try XCTUnwrap(editor).writeFieldAsync(.title("Successful retired draft"))
        }
        addTeardownBlock { write.cancel(); await gate.release(); _ = await write.result }
        await fulfillment(of: [started], timeout: 5)
        RealmWriteCommitObservation.$didSubmit.withValue({ commits.record() }) { editor = nil }
        XCTAssertNil(retiringEditor, "An active field command must not retain its editor")
        await fulfillment(of: [premature], timeout: 0.1)
        XCTAssertEqual(commits.count, 0)
        retirement.allowFinish()

        await gate.release()
        try await write.value
        await fulfillment(of: [retired], timeout: 5)
        realm.refresh()
        XCTAssertEqual(category.title, "Successful retired draft")
        XCTAssertEqual(commits.count, 1, "Durable success must not get a second retirement submission")
    }

    func testRetirementJoinsFailedActiveAttemptBeforeOneCapturedRetry() async throws {
        let (realm, category, library) = try await fixture()
        let gate = CategoryFieldWriteGate()
        let started = expectation(description: "Failing category attempt is held before admission")
        let premature = expectation(description: "Retirement cannot retry before its active attempt fails")
        premature.isInverted = true
        let retired = expectation(description: "Retirement completed one captured retry")
        let retirement = CategoryFieldRetirementObservation(premature: premature, completed: retired)
        let commits = CategoryFieldCommitCount()
        let before = generations(realm)
        var editor: LibraryCategoryViewModel? = model(
            category, library,
            beforeFieldWrite: {
                await gate.wait(onFirstWait: { started.fulfill() })
                throw InjectedFailure.admission
            },
            retirementDidFinish: { retirement.didFinish() }
        )
        weak var retiringEditor = editor
        let write = try RealmWriteCommitObservation.$didSubmit.withValue({ commits.record() }) {
            try XCTUnwrap(editor).writeFieldAsync(.title("Retried retired draft"))
        }
        addTeardownBlock { write.cancel(); await gate.release(); _ = await write.result }
        await fulfillment(of: [started], timeout: 5)
        RealmWriteCommitObservation.$didSubmit.withValue({ commits.record() }) { editor = nil }
        XCTAssertNil(retiringEditor)
        await fulfillment(of: [premature], timeout: 0.1)
        XCTAssertEqual(commits.count, 0)
        retirement.allowFinish()

        await gate.release()
        do {
            try await write.value
            XCTFail("The held first attempt must fail")
        } catch InjectedFailure.admission {}
        await fulfillment(of: [retired], timeout: 5)
        realm.refresh()
        XCTAssertEqual(category.title, "Retried retired draft")
        XCTAssertNotEqual(generations(realm), before)
        XCTAssertEqual(commits.count, 1, "Only the bounded retirement retry should submit a commit")
    }

    func testQueuedFieldCannotEditOrResurrectJournaledCategoryTombstone() async throws {
        let (realm, category, library) = try await fixture()
        let editor = model(category, library)
        let gate = CategoryFieldWriteGate()
        let started = expectation(description: "Field attempt held before category deletion")
        let write = editor.writeFieldAsync(.title("Must not resurrect"), beforeWrite: {
            await gate.wait(onFirstWait: { started.fulfill() })
        })
        addTeardownBlock { write.cancel(); await gate.release(); _ = await write.result }
        await fulfillment(of: [started], timeout: 5)
        let configuration = realm.configuration
        let id = category.id
        try await Task { @RealmBackgroundActor in
            let writer = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            try await writer.asyncWritePreservingOwnership {
                let category = try XCTUnwrap(writer.object(ofType: FeedCategory.self, forPrimaryKey: id))
                category.isDeleted = true
                category.refreshChangeMetadata(explicitlyModified: true)
            }
        }.value
        realm.refresh()
        let tombstoneGenerations = generations(realm)
        await gate.release()
        try await write.value
        try await editor.finishEditing().value
        realm.refresh()
        XCTAssertTrue(category.isDeleted)
        XCTAssertEqual(category.title, "Original")
        XCTAssertEqual(generations(realm), tombstoneGenerations)
    }

    func testReopenedNoOpInputRetiresOlderFailedDraftWithoutJournaling() async throws {
        let (realm, category, library) = try await fixture()
        let before = generations(realm)
        let oldEditor = model(category, library)
        do {
            try await oldEditor.writeFieldAsync(.title("Obsolete retained draft"), beforeWrite: {
                throw InjectedFailure.admission
            }).value
            XCTFail("The injected field attempt must fail")
        } catch InjectedFailure.admission {}

        let newEditor = model(category, library)
        newEditor.categoryTitle = "Original"
        try await newEditor.finishEditing().value
        try await oldEditor.finishEditing().value
        realm.refresh()
        XCTAssertEqual(category.title, "Original")
        XCTAssertEqual(generations(realm), before)
    }

    // Reuse the physical-store fixture boundary from the script-field port:
    // capture actual production owners from real rows, close fixture accessors,
    // and preserve row IDs/creation dates when replacing only the backing file.
    private func diskOwner(_ configuration: Realm.Configuration) throws -> LibraryCategoryFieldOwner {
        try autoreleasepool {
            let realm = try Realm(configuration: configuration)
            defer { realm.invalidate() }
            let category = try XCTUnwrap(realm.objects(FeedCategory.self).first)
            return try XCTUnwrap(LibraryCategoryFieldOwner(category: category))
        }
    }

    private func diskCommand(
        owner: LibraryCategoryFieldOwner,
        title: String = "Retired category draft"
    ) -> LibraryCategoryFieldCommand {
        let ordering = LibraryCategoryFieldWriteOrdering.shared(identity: LibraryCategoryFieldIdentity(owner: owner))
        let edit = LibraryCategoryFieldEdit.title(title)
        return LibraryCategoryFieldCommand(
            owner: owner, edit: edit, intent: ordering.issueIntent(field: edit.field), ordering: ordering
        )
    }

    private func diskSnapshot(_ configuration: Realm.Configuration) throws -> CategoryFieldDiskSnapshot {
        try autoreleasepool {
            let realm = try Realm(configuration: configuration)
            defer { realm.invalidate() }
            let category = try XCTUnwrap(realm.objects(FeedCategory.self).first)
            return CategoryFieldDiskSnapshot(
                title: category.title, createdAt: category.createdAt, isDeleted: category.isDeleted,
                modifiedAt: category.modifiedAt, explicitlyModifiedAt: category.explicitlyModifiedAt,
                generations: generations(realm)
            )
        }
    }

    @RealmBackgroundActor
    private static func releaseDiskCache(_ configuration: Realm.Configuration) {
        // File replacement changes the current cache key. Retire only this
        // unique fixture path's keys, including the captured original inode.
        let actor = RealmBackgroundActor.shared
        let keys = actor.cachedRealms.keys.filter {
            actor.cachedRealms[$0]?.configuration.fileURL == configuration.fileURL
        }
        for key in keys {
            guard let realm = actor.cachedRealms[key], !realm.isInWriteTransaction else { continue }
            actor.cachedRealms.removeValue(forKey: key)
            realm.invalidate()
        }
    }

    private func diskFixture() throws -> CategoryFieldDiskFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("category-storage-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var configuration = Realm.Configuration(fileURL: directory.appendingPathComponent("current.realm"))
        configuration.objectTypes = [FeedCategory.self, LibraryConfiguration.self, UserScript.self]
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        var replacementConfiguration = configuration
        replacementConfiguration.fileURL = directory.appendingPathComponent("replacement.realm")
        var retiredConfiguration = configuration
        retiredConfiguration.fileURL = directory.appendingPathComponent("retired.realm")
        let captured = configuration
        addTeardownBlock {
            await Self.releaseDiskCache(captured)
            try? FileManager.default.removeItem(at: directory)
        }
        let categoryID = UUID()
        let libraryID = UUID()
        for (store, title) in [(configuration, "Original"), (replacementConfiguration, "Replacement")] {
            try autoreleasepool {
                let realm = try Realm(configuration: store)
                defer { realm.invalidate() }
                try realm.write {
                    let category = FeedCategory()
                    category.id = categoryID
                    category.createdAt = Date(timeIntervalSinceReferenceDate: 100)
                    category.title = title
                    category.backgroundImageUrl = URL(string: "about:blank")!
                    realm.add(category)
                    category.refreshChangeMetadata(explicitlyModified: true)
                    let library = LibraryConfiguration()
                    library.id = libraryID
                    library.createdAt = Date(timeIntervalSinceReferenceDate: 200)
                    library.categoryIDs.append(categoryID)
                    realm.add(library)
                    library.refreshChangeMetadata(explicitlyModified: true)
                }
            }
        }
        return CategoryFieldDiskFixture(
            configuration: configuration, replacementConfiguration: replacementConfiguration,
            retiredConfiguration: retiredConfiguration,
            owner: try diskOwner(configuration), original: try diskSnapshot(configuration),
            replacement: try diskSnapshot(replacementConfiguration)
        )
    }

    private func replaceDiskFile(_ fixture: CategoryFieldDiskFixture) throws {
        let current = try XCTUnwrap(fixture.configuration.fileURL)
        let replacement = try XCTUnwrap(fixture.replacementConfiguration.fileURL)
        let retired = try XCTUnwrap(fixture.retiredConfiguration.fileURL)
        try FileManager.default.moveItem(at: current, to: retired)
        try FileManager.default.moveItem(at: replacement, to: current)
    }

    func testCapturedFieldRejectsSamePathReplacementBeforeOpening() async throws {
        let fixture = try diskFixture()
        let command = diskCommand(owner: fixture.owner)
        try replaceDiskFile(fixture)
        do {
            try await command.write()
            XCTFail("The captured field command adopted the successor store")
        } catch RealmBackgroundActorError.realmFileChangedDuringOpen {}
        await Self.releaseDiskCache(fixture.configuration)
        XCTAssertEqual(try diskSnapshot(fixture.configuration), fixture.replacement)
        XCTAssertEqual(try diskSnapshot(fixture.retiredConfiguration), fixture.original)
    }

    func testCapturedFieldRejectsSamePathReplacementAfterOpening() async throws {
        let fixture = try diskFixture()
        let command = diskCommand(owner: fixture.owner)
        let gate = CategoryFieldWriteGate()
        let opened = expectation(description: "Production command opened the original store before suspension")
        let write = Task { @RealmBackgroundActor in
            try await command.write(beforeWrite: {
                await gate.wait(onFirstWait: { opened.fulfill() })
            })
        }
        addTeardownBlock { write.cancel(); await gate.release(); _ = await write.result }
        await fulfillment(of: [opened], timeout: 5)
        try replaceDiskFile(fixture)
        await gate.release()
        do {
            try await write.value
            XCTFail("The field transaction failed to revalidate captured physical storage")
        } catch RealmBackgroundActorError.realmFileChangedDuringOpen {}
        await Self.releaseDiskCache(fixture.configuration)
        XCTAssertEqual(try diskSnapshot(fixture.configuration), fixture.replacement)
        XCTAssertEqual(try diskSnapshot(fixture.retiredConfiguration), fixture.original)
    }

    func testReplacementStoreKeepsIndependentInputOrderingAndNoOpJournal() async throws {
        let fixture = try diskFixture()
        let old = diskCommand(owner: fixture.owner)
        try replaceDiskFile(fixture)
        let freshOwner = try diskOwner(fixture.configuration)
        let fresh = diskCommand(owner: freshOwner, title: "Successor input")
        XCTAssertNotEqual(LibraryCategoryFieldIdentity(owner: old.owner), LibraryCategoryFieldIdentity(owner: freshOwner))

        // Input from a retained old control must not revoke the successor
        // command merely because path, record ID and creation date match.
        _ = old.ordering.issueIntent(field: old.edit.field)
        try await fresh.write()
        await Self.releaseDiskCache(fixture.configuration)
        let after = try diskSnapshot(fixture.configuration)
        XCTAssertEqual(after.title, "Successor input")
        XCTAssertNotEqual(after.generations, fixture.replacement.generations)
        XCTAssertEqual(try diskSnapshot(fixture.retiredConfiguration), fixture.original)
        try await fresh.write()
        await Self.releaseDiskCache(fixture.configuration)
        XCTAssertEqual(try diskSnapshot(fixture.configuration), after, "Same-value delivery must not re-journal")
    }
}
