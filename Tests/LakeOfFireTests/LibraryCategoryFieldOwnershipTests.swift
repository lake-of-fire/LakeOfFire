import BigSyncKit
import RealmSwift
@testable import RealmSwiftGaps
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireLibrary

private actor CategoryFieldWriteGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait(onSuspension: @Sendable () -> Void = {}) async {
        guard !released else { return }
        await withCheckedContinuation {
            continuation = $0
            onSuspension()
        }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
final class LibraryCategoryFieldOwnershipTests: XCTestCase, @unchecked Sendable {
    private func fixture(
        id: UUID = UUID(), fileURL: URL? = nil, title: String = "Original"
    ) async throws -> (Realm, FeedCategory, LibraryConfiguration) {
        var configuration = Realm.Configuration()
        if let fileURL { configuration.fileURL = fileURL }
        else { configuration.inMemoryIdentifier = UUID().uuidString }
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
                category.title = title
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

    private func model(_ category: FeedCategory, _ library: LibraryConfiguration) -> LibraryCategoryViewModel {
        LibraryCategoryViewModel(
            category: category, libraryConfiguration: library, selectedFeed: .constant(nil), observesRealm: false
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
            await gate.wait(onSuspension: { started.fulfill() })
        })
        addTeardownBlock { await gate.release(); _ = await oldWrite.result }
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
            await gate.wait(onSuspension: { started.fulfill() })
        })
        addTeardownBlock { await gate.release(); _ = await oldWrite.result }
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
            await gate.wait(onSuspension: { started.fulfill() })
        })
        addTeardownBlock { await gate.release(); _ = await write.result }
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
        var editor: LibraryCategoryViewModel? = model(category, library)
        editor?.isEditing = true
        editor?.categoryTitle = "Leading"
        editor?.categoryTitle = "Retired final"
        editor = nil
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            realm.refresh()
            if category.title == "Retired final" { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
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
            await gate.wait(onSuspension: { started.fulfill() })
        })
        addTeardownBlock { await gate.release(); _ = await write.result }
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
            await gate.wait(onSuspension: { started.fulfill() })
        })
        addTeardownBlock { await gate.release(); _ = await write.result }
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
        let trailingFinished = expectation(description: "settled title trailing delivery completed")
        // The real Combine operator uses this main-targeted queue. Suspension holds
        // only its scheduled trailing delivery, not the leading input or Realm work.
        let scheduler = DispatchQueue(label: "category-title-debounce", target: .main)
        scheduler.suspend()
        var schedulerIsSuspended = true
        defer { if schedulerIsSuspended { scheduler.resume() } }
        let editor = LibraryCategoryViewModel(
            category: category, libraryConfiguration: library, selectedFeed: .constant(nil),
            observesRealm: false, fieldDebounceScheduler: scheduler,
            debouncedWriteDidFinish: { edit in
                if edit == .title("Final local title") { trailingFinished.fulfill() }
            }
        )
        editor.isEditing = true
        editor.categoryTitle = "Leading local title"
        editor.categoryTitle = "Final local title"
        try await editor.finishEditing().value
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
        realm.refresh()
        XCTAssertEqual(category.title, "Remote after Done")
        XCTAssertEqual(editor.categoryTitle, "Remote after Done")
        XCTAssertEqual(generations(realm), afterRemote)
    }

    func testDoneRetiresImageBeforeItsQueuedTrailingDelivery() async throws {
        let (realm, category, library) = try await fixture()
        let trailingFinished = expectation(description: "settled image trailing delivery completed")
        let finalURL = "https://local.example/final.png"
        let remoteURL = URL(string: "https://remote.example/after-done.png")!
        let scheduler = DispatchQueue(label: "category-image-debounce", target: .main)
        scheduler.suspend()
        var schedulerIsSuspended = true
        defer { if schedulerIsSuspended { scheduler.resume() } }
        let editor = LibraryCategoryViewModel(
            category: category, libraryConfiguration: library, selectedFeed: .constant(nil),
            observesRealm: false, fieldDebounceScheduler: scheduler,
            debouncedWriteDidFinish: { edit in
                if edit == .imageURL(finalURL) { trailingFinished.fulfill() }
            }
        )
        editor.isEditing = true
        editor.categoryBackgroundImageURL = "https://local.example/leading.png"
        editor.categoryBackgroundImageURL = finalURL
        try await editor.finishEditing().value
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
        realm.refresh()
        XCTAssertEqual(category.backgroundImageUrl, remoteURL)
        XCTAssertEqual(editor.categoryBackgroundImageURL, remoteURL.absoluteString)
        XCTAssertEqual(generations(realm), afterRemote)
    }

    private func fileURLs() throws -> (original: URL, replacement: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("category-storage-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return (directory.appendingPathComponent("original.realm"),
                directory.appendingPathComponent("replacement.realm"))
    }

    /// Keep both live Realm handles bound to their original inodes. The test
    /// changes only which main file occupies the captured configuration path,
    /// then restores the paths before the existing per-configuration cleanup.
    private func replaceFile(at original: URL, with replacement: URL) throws -> () throws -> Void {
        let retired = original.appendingPathExtension("retired")
        let manager = FileManager.default
        try manager.moveItem(at: original, to: retired)
        do { try manager.moveItem(at: replacement, to: original) }
        catch {
            try? manager.moveItem(at: retired, to: original)
            throw error
        }
        return {
            try manager.moveItem(at: original, to: replacement)
            try manager.moveItem(at: retired, to: original)
        }
    }

    func testCapturedCategoryCommandRejectsReplacedFileBeforeOpening() async throws {
        let paths = try fileURLs()
        let (original, category, _) = try await fixture(fileURL: paths.original)
        let (replacement, otherCategory, _) = try await fixture(
            id: category.id, fileURL: paths.replacement, title: "Replacement"
        )
        XCTAssertEqual(category.createdAt, otherCategory.createdAt)
        let owner = try XCTUnwrap(LibraryCategoryFieldOwner(category: category))
        let ordering = LibraryCategoryFieldWriteOrdering.shared(identity: LibraryCategoryFieldIdentity(owner: owner))
        let command = LibraryCategoryFieldCommand(
            owner: owner, edit: .title("Retired command"),
            intent: ordering.issueIntent(field: .title), ordering: ordering
        )
        let originalGenerations = generations(original)
        let replacementGenerations = generations(replacement)
        let restore = try replaceFile(at: paths.original, with: paths.replacement)
        defer { XCTAssertNoThrow(try restore()) }

        // A fresh capture at the new file has a distinct transient input scope,
        // even when the restored record keeps exactly the same ID and createdAt.
        let successorSnapshot = FeedCategory()
        successorSnapshot.id = category.id
        successorSnapshot.createdAt = category.createdAt
        let successorOwner = try XCTUnwrap(LibraryCategoryFieldOwner(
            category: successorSnapshot, realmConfiguration: original.configuration
        ))
        XCTAssertNotEqual(LibraryCategoryFieldIdentity(owner: owner),
                          LibraryCategoryFieldIdentity(owner: successorOwner))
        let successorOrdering = LibraryCategoryFieldWriteOrdering.shared(
            identity: LibraryCategoryFieldIdentity(owner: successorOwner)
        )
        XCTAssertFalse(ordering === successorOrdering)
        _ = successorOrdering.issueIntent(field: .title)

        do {
            try await command.write()
            XCTFail("The original admission must reject a replacement file")
        } catch RealmBackgroundActorError.realmFileChangedDuringOpen { }
        original.refresh()
        replacement.refresh()
        XCTAssertEqual(category.title, "Original")
        XCTAssertEqual(otherCategory.title, "Replacement")
        XCTAssertEqual(generations(original), originalGenerations)
        XCTAssertEqual(generations(replacement), replacementGenerations)
    }

    func testCategoryWriteRevalidatesStorageAfterAdmittedOpen() async throws {
        let paths = try fileURLs()
        let (original, category, library) = try await fixture(fileURL: paths.original)
        let (replacement, otherCategory, _) = try await fixture(
            id: category.id, fileURL: paths.replacement, title: "Replacement"
        )
        let editor = model(category, library)
        let gate = CategoryFieldWriteGate()
        let opened = expectation(description: "original Realm opened and continuation registered")
        let write = editor.writeFieldAsync(.title("Retired after open"), beforeWrite: {
            await gate.wait(onSuspension: { opened.fulfill() })
        })
        addTeardownBlock { await gate.release(); _ = await write.result }
        await fulfillment(of: [opened], timeout: 5)
        let originalGenerations = generations(original)
        let replacementGenerations = generations(replacement)
        let restore = try replaceFile(at: paths.original, with: paths.replacement)
        defer { XCTAssertNoThrow(try restore()) }

        await gate.release()
        try await write.value
        original.refresh()
        replacement.refresh()
        XCTAssertEqual(category.title, "Original")
        XCTAssertEqual(otherCategory.title, "Replacement")
        XCTAssertEqual(generations(original), originalGenerations)
        XCTAssertEqual(generations(replacement), replacementGenerations)
    }

}
