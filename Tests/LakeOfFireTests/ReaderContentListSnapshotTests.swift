import Combine
import XCTest
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

    private func contentFile(path: String) -> ContentFile {
        let file = ContentFile()
        file.url = URL(string: "ebook://book/\(path)")!
        file.updateCompoundKey()
        return file
    }
}
