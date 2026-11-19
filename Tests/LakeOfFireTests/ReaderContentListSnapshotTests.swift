import Combine
import XCTest
import RealmSwift
@testable import LakeOfFireContent
@testable import LakeOfFireReader

@objc(LakeOfFireTestsDeleteCommandContent)
private final class DeleteCommandContent: Bookmark, DeletableReaderContent {
    var deleteCalls = 0
    var deletion: (@MainActor () async throws -> Void)?
    var deleteActionTitle: String { "Delete" }

    override class func shouldIncludeInDefaultSchema() -> Bool { false }

    @MainActor
    func delete() async throws {
        deleteCalls += 1
        try await deletion?()
    }
}

@MainActor
final class ReaderContentListSnapshotTests: XCTestCase {
    func testDeleteConfirmationCancelPerformsZeroDeletes() {
        let item = DeleteCommandContent()
        let model = ReaderContentListModalsModel()
        model.presentDeleteConfirmation(for: [item])
        model.clearDeleteDialog()
        XCTAssertEqual(item.deleteCalls, 0)
        XCTAssertNil(model.deleteDialog)
    }

    func testDeleteConfirmationCommandDeletesExactlyOnce() async {
        let item = DeleteCommandContent()
        let model = ReaderContentListModalsModel()
        model.presentDeleteConfirmation(for: [item])
        await model.deleteConfirmedItems([item])
        XCTAssertEqual(item.deleteCalls, 1)
        XCTAssertNil(model.deleteDialog)
    }

    func testDeleteConfirmationCommandRetainsError() async {
        let item = DeleteCommandContent()
        item.deletion = { throw ReaderFileDeleteError.blockedCloudOnly }
        let model = ReaderContentListModalsModel()
        model.presentDeleteConfirmation(for: [item])
        await model.deleteConfirmedItems([item])
        XCTAssertEqual(item.deleteCalls, 1)
        guard case .error? = model.deleteDialog else {
            return XCTFail("The command error must remain available to the alert presenter")
        }
    }

    func testOlderDeleteCompletionDoesNotClearNewerConfirmation() async {
        await checkOlderDeletePreservesNewerConfirmation(sameItem: false, fails: false)
    }

    func testConfirmedCommandRetainsErrorAfterAlertBindingDismissal() async {
        let item = DeleteCommandContent()
        item.deletion = { throw ReaderFileDeleteError.blockedCloudOnly }
        let model = ReaderContentListModalsModel()
        model.presentDeleteConfirmation(for: [item])
        let generation = model.deleteDialogGeneration
        // SwiftUI dismisses the alert through its binding when a button is
        // tapped; this is not a new user request or an explicit cancellation.
        model.deleteDialog = nil
        await model.deleteConfirmedItems([item], generation: generation)
        XCTAssertEqual(item.deleteCalls, 1)
        guard case .error? = model.deleteDialog else {
            return XCTFail("Alert dismissal must not suppress the confirmed command's error")
        }
    }

    func testOlderDeleteCompletionDoesNotClearNewerSameItemConfirmation() async {
        await checkOlderDeletePreservesNewerConfirmation(sameItem: true, fails: false)
    }

    func testOlderDeleteErrorDoesNotReplaceNewerConfirmation() async {
        await checkOlderDeletePreservesNewerConfirmation(sameItem: false, fails: true)
    }

    func testOlderDeleteErrorDoesNotReplaceNewerSameItemConfirmation() async {
        await checkOlderDeletePreservesNewerConfirmation(sameItem: true, fails: true)
    }

    private func checkOlderDeletePreservesNewerConfirmation(sameItem: Bool, fails: Bool) async {
        let oldItem = DeleteCommandContent()
        oldItem.compoundKey = "old"
        let newItem = sameItem ? oldItem : DeleteCommandContent()
        if !sameItem { newItem.compoundKey = "new" }
        let model = ReaderContentListModalsModel()
        model.presentDeleteConfirmation(for: [oldItem])
        let oldGeneration = model.deleteDialogGeneration
        defer { oldItem.deletion = nil }
        oldItem.deletion = {
            // Resume only after the replacement request is installed; this
            // does not depend on a delay or a particular Task.yield schedule.
            await withCheckedContinuation { continuation in
                Task { @MainActor in
                    model.presentDeleteConfirmation(for: [newItem])
                    continuation.resume()
                }
            }
            if fails { throw ReaderFileDeleteError.blockedCloudOnly }
        }
        await model.deleteConfirmedItems([oldItem], generation: oldGeneration)
        XCTAssertEqual(oldItem.deleteCalls, 1)
        XCTAssertEqual(newItem.deleteCalls, sameItem ? 1 : 0)
        XCTAssertNotEqual(model.deleteDialogGeneration, oldGeneration)
        guard case .confirm(let items, _, _, _)? = model.deleteDialog else {
            return XCTFail("An older completion must preserve the newer confirmation")
        }
        XCTAssertEqual(items.map(\.compoundKey), [newItem.compoundKey])
    }

    func testConfirmedCommandCapturedBeforeTaskStartsPreservesNewerRequest() async {
        let item = DeleteCommandContent()
        let model = ReaderContentListModalsModel()
        model.presentDeleteConfirmation(for: [item])
        let generation = model.deleteDialogGeneration
        model.presentDeleteConfirmation(for: [item])
        let newerGeneration = model.deleteDialogGeneration
        await model.deleteConfirmedItems([item], generation: generation)
        XCTAssertEqual(item.deleteCalls, 1, "Presentation fencing must not revoke confirmed deletion")
        XCTAssertEqual(model.deleteDialogGeneration, newerGeneration)
        guard case .confirm? = model.deleteDialog else {
            return XCTFail("The request made before task entry must remain presented")
        }
    }

    func testFilteredContentsAndIDsPublishAsOneAlignedSnapshot() async throws {
        let first = contentFile(path: "first.epub")
        let second = contentFile(path: "second.epub")
        let viewModel = ReaderContentListViewModel(
            initialContents: [first]
        )
        var observedCounts = [(contents: Int, ids: Int)]()
        let observation = viewModel.objectWillChange.sink {
            observedCounts.append(
                (
                    contents: viewModel.filteredContents.count,
                    ids: viewModel.filteredContentIDs.count
                )
            )
        }
        defer { observation.cancel() }

        try await viewModel.load(contents: [first, second])

        XCTAssertFalse(observedCounts.isEmpty)
        XCTAssertTrue(
            observedCounts.allSatisfy { $0.contents == $0.ids },
            "Every observable list state must pair values with the same number of stable IDs"
        )
        XCTAssertEqual(viewModel.filteredContents.count, 2)
        XCTAssertEqual(viewModel.filteredContentIDs.count, 2)
    }

    func testUnmanagedContentLimitKeepsValuesAndIDsAligned() async throws {
        let contents = (0...10_000).map { contentFile(path: "book-\($0).epub") }
        let viewModel = ReaderContentListViewModel<ContentFile>()

        try await viewModel.load(contents: contents, sortOrder: .providedOrder)

        XCTAssertEqual(viewModel.filteredContents.count, 10_000)
        XCTAssertEqual(viewModel.filteredContentIDs.count, 10_000)
        XCTAssertEqual(
            viewModel.filteredContents.map(\.compoundKey),
            viewModel.filteredContentIDs
        )
    }

    func testViewRequestIdentityIncludesFilterAndTransformPresence() {
        let item = contentFile(path: "saved.epub")
        func request(filtered: Bool, transformed: Bool) -> ReaderContentListLoadRequest<ContentFile> {
            ReaderContentListLoadRequest(
                contents: [item], sortOrder: .providedOrder,
                hasContentFilter: filtered, hasPostSortTransform: transformed
            )
        }
        XCTAssertEqual(request(filtered: false, transformed: false), request(filtered: false, transformed: false))
        XCTAssertNotEqual(request(filtered: false, transformed: false), request(filtered: true, transformed: false))
        XCTAssertNotEqual(request(filtered: false, transformed: false), request(filtered: false, transformed: true))
    }

    func testViewRequestIdentityRetainsContentsAndSnapshotsMutableMetadata() {
        let first = contentFile(path: "first.epub")
        let second = contentFile(path: "second.epub")
        func request(_ contents: [ContentFile], sort: ReaderContentSortOrder = .title) -> ReaderContentListLoadRequest<ContentFile> {
            ReaderContentListLoadRequest(contents: contents, sortOrder: sort, hasContentFilter: false)
        }
        let original = request([first, second])
        XCTAssertNotEqual(original, request([second, first]))
        XCTAssertNotEqual(original, request([first]))
        XCTAssertNotEqual(original, request([first, second], sort: .publicationDate))

        first.title = "Renamed without replacing its Realm reference"
        let renamed = request([first, second])
        XCTAssertNotEqual(original, renamed)
        first.publicationDate = Date(timeIntervalSince1970: 123)
        let republished = request([first, second])
        XCTAssertNotEqual(renamed, republished)
        first.modifiedAt = first.modifiedAt.addingTimeInterval(1)
        XCTAssertNotEqual(republished, request([first, second]))

        let replacement = ContentFile(value: first)
        XCTAssertEqual(replacement.compoundKey, first.compoundKey)
        XCTAssertNotEqual([first], [replacement], "Unmanaged replacements have different object identity")
        XCTAssertNotEqual(request([first]), request([replacement]), "Do not reduce contents to compound keys")
    }

    func testManagedRequestIdentitySnapshotsMetadataBeforeMutationAndInvalidation() async throws {
        var configuration = Realm.Configuration()
        configuration.inMemoryIdentifier = "ReaderListRequest-\(UUID().uuidString)"
        configuration.objectTypes = [ContentFile.self]
        let realm = try await Realm(configuration: configuration, actor: MainActor.shared)
        let item = contentFile(path: "saved.epub")
        try realm.write { realm.add(item) }
        let original = ReaderContentListLoadRequest(
            contents: [item], sortOrder: .title, hasContentFilter: false
        )

        try realm.write { item.title = "Changed on the same managed reference" }
        let renamed = ReaderContentListLoadRequest(
            contents: [item], sortOrder: .title, hasContentFilter: false
        )
        XCTAssertNotEqual(original, renamed)

        try realm.write { realm.delete(item) }
        let invalidated = ReaderContentListLoadRequest(
            contents: [item], sortOrder: .title, hasContentFilter: false
        )
        XCTAssertNotEqual(renamed, invalidated, "Identity capture must not read invalidated properties")
        withExtendedLifetime(realm) {}
    }

    func testDisappearingViewRequestSkipsAllPostLoadEffects() async {
        let entered = expectation(description: "view-owned filter is held")
        let gate = ReaderListLoadGate(entered)
        let item = contentFile(path: "saved.epub")
        let model = ReaderContentListViewModel(initialContents: [item])
        let request = ReaderContentListLoadRequest(
            contents: [item], sortOrder: .providedOrder, hasContentFilter: true
        )
        var isCurrent = true
        var completions = 0
        let caller = Task { @MainActor in
            await performReaderContentListLoad(
                viewModel: model, request: request,
                contentFilter: { @ReaderContentListActor _, _ in
                    await gate.wait()
                    return false
                },
                isCurrent: { isCurrent }, onLoaded: { completions += 1 }
            )
        }
        addTeardownBlock { @MainActor in
            gate.release()
            caller.cancel()
            await caller.value
        }
        await fulfillment(of: [entered], timeout: 3)
        isCurrent = false
        caller.cancel()
        gate.release()
        await caller.value

        XCTAssertEqual(completions, 0)
        XCTAssertEqual(model.filteredContentIDs, [item.compoundKey])
        XCTAssertTrue(gate.wasCancelledOnReturn)
    }

    func testRetiredRequestSkipsCompletionEvenWithoutCallerCancellation() async {
        let entered = expectation(description: "request awaiting filter")
        let gate = ReaderListLoadGate(entered)
        let item = contentFile(path: "saved.epub")
        let model = ReaderContentListViewModel(initialContents: [item])
        let request = ReaderContentListLoadRequest(
            contents: [item], sortOrder: .providedOrder, hasContentFilter: true
        )
        var isCurrent = true
        var completions = 0
        let caller = Task { @MainActor in
            await performReaderContentListLoad(
                viewModel: model, request: request,
                contentFilter: { @ReaderContentListActor _, _ in
                    await gate.wait()
                    return true
                },
                isCurrent: { isCurrent }, onLoaded: { completions += 1 }
            )
        }
        addTeardownBlock { @MainActor in
            gate.release()
            caller.cancel()
            await caller.value
        }
        await fulfillment(of: [entered], timeout: 3)
        isCurrent = false
        gate.release()
        await caller.value
        XCTAssertEqual(completions, 0)
        XCTAssertFalse(gate.wasCancelledOnReturn)
    }

    func testCancelledLayoutDelayDoesNotScroll() async {
        await assertRetiredLayoutDelayDoesNotScroll(cancelCaller: true)
    }

    func testReplacedLayoutDelayDoesNotScroll() async {
        await assertRetiredLayoutDelayDoesNotScroll(cancelCaller: false)
    }

    private func assertRetiredLayoutDelayDoesNotScroll(cancelCaller: Bool) async {
        let entered = expectation(description: "layout delay is held")
        let gate = ReaderListLoadGate(entered)
        var isCurrent = true
        var scrolls = 0
        let caller = Task { @MainActor in
            await performReaderContentListScroll(
                isCurrent: { isCurrent },
                waitForLayout: { await gate.wait() },
                scroll: { scrolls += 1 }
            )
        }
        addTeardownBlock { @MainActor in
            gate.release()
            caller.cancel()
            await caller.value
        }
        await fulfillment(of: [entered], timeout: 3)
        if cancelCaller {
            caller.cancel()
        } else {
            isCurrent = false
        }
        gate.release()
        await caller.value
        XCTAssertEqual(scrolls, 0)

        await performReaderContentListScroll(
            isCurrent: { true }, waitForLayout: {}, scroll: { scrolls += 1 }
        )
        XCTAssertEqual(scrolls, 1, "The current request can still scroll")
    }


    func testReplacementViewLoadPublishesAndCompletesOnlyCurrentRequest() async {
        let entered = expectation(description: "old view-owned filter is held")
        let gate = ReaderListLoadGate(entered)
        let oldItem = contentFile(path: "old.epub")
        let newItem = contentFile(path: "new.epub")
        let model = ReaderContentListViewModel(initialContents: [oldItem])
        var currentRequest = "old"
        var completions: [String] = []
        let caller = Task { @MainActor in
            await performReaderContentListLoad(
                viewModel: model,
                request: ReaderContentListLoadRequest(
                    contents: [oldItem], sortOrder: .providedOrder, hasContentFilter: true
                ),
                contentFilter: { @ReaderContentListActor _, _ in
                    await gate.wait()
                    return true
                },
                isCurrent: { currentRequest == "old" },
                onLoaded: { completions.append("old") }
            )
        }
        addTeardownBlock { @MainActor in
            gate.release()
            caller.cancel()
            await caller.value
        }
        await fulfillment(of: [entered], timeout: 3)
        currentRequest = "new"
        await performReaderContentListLoad(
            viewModel: model,
            request: ReaderContentListLoadRequest(
                contents: [newItem], sortOrder: .providedOrder, hasContentFilter: false
            ),
            contentFilter: nil,
            isCurrent: { currentRequest == "new" },
            onLoaded: { completions.append("new") }
        )
        gate.release()
        await caller.value

        XCTAssertEqual(model.filteredContentIDs, [newItem.compoundKey])
        XCTAssertEqual(completions, ["new"])
        XCTAssertTrue(gate.wasCancelledOnReturn)
    }

    func testFailedViewLoadDoesNotRunCompletion() async {
        let item = contentFile(path: "saved.epub")
        let model = ReaderContentListViewModel(initialContents: [item])
        var completions = 0
        await performReaderContentListLoad(
            viewModel: model,
            request: ReaderContentListLoadRequest(
                contents: [item], sortOrder: .providedOrder, hasContentFilter: true
            ),
            contentFilter: { @ReaderContentListActor _, _ in
                throw ReaderListLoadFixtureError.filterFailed
            },
            isCurrent: { true }, onLoaded: { completions += 1 }
        )
        XCTAssertEqual(completions, 0)
        XCTAssertEqual(model.filteredContentIDs, [item.compoundKey])
    }

    func testRetiredViewRequestDoesNotStartLoad() async {
        let first = contentFile(path: "first.epub")
        let replacement = contentFile(path: "replacement.epub")
        let model = ReaderContentListViewModel(initialContents: [first])
        var completions = 0
        await performReaderContentListLoad(
            viewModel: model,
            request: ReaderContentListLoadRequest(
                contents: [replacement], sortOrder: .providedOrder, hasContentFilter: false
            ),
            contentFilter: nil,
            isCurrent: { false }, onLoaded: { completions += 1 }
        )
        XCTAssertEqual(completions, 0)
        XCTAssertEqual(model.filteredContentIDs, [first.compoundKey])
    }

    private func contentFile(path: String) -> ContentFile {
        let file = ContentFile()
        file.url = URL(string: "ebook://book/\(path)")!
        file.updateCompoundKey()
        return file
    }
}

/// Controls only the asynchronous filter collaborator. Publication, cancellation
/// forwarding and loading state always run through the production list model.
@MainActor
private final class ReaderListLoadGate {
    let entered: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?
    private var isReleased = false
    private(set) var wasCancelledOnReturn = false
    private(set) var calls = 0

    init(_ entered: XCTestExpectation) {
        self.entered = entered
    }

    func wait() async {
        calls += 1
        guard calls == 1 else {
            XCTFail("This fixture expects one filter call")
            return
        }
        await withCheckedContinuation { continuation in
            if isReleased {
                continuation.resume()
            } else {
                self.continuation = continuation
            }
            // A test may replace/cancel the load only after registration.
            entered.fulfill()
        }
        wasCancelledOnReturn = Task.isCancelled
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}

private enum ReaderListLoadFixtureError: Error {
    case filterFailed
}
