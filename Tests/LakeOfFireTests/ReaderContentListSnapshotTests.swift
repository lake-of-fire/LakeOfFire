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
        let oldItem = DeleteCommandContent()
        oldItem.compoundKey = "old"
        let newItem = DeleteCommandContent()
        newItem.compoundKey = "new"
        let model = ReaderContentListModalsModel()
        model.presentDeleteConfirmation(for: [oldItem])
        oldItem.deletion = {
            // A newer request arrives while the old command is suspended.
            await Task.yield()
            model.presentDeleteConfirmation(for: [newItem])
        }
        await model.deleteConfirmedItems([oldItem])
        XCTAssertEqual(oldItem.deleteCalls, 1)
        XCTAssertEqual(newItem.deleteCalls, 0)
        guard case .confirm(let items, _, _, _)? = model.deleteDialog else {
            return XCTFail("An older completion must preserve the newer confirmation")
        }
        XCTAssertEqual(items.map(\.compoundKey), ["new"])
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
