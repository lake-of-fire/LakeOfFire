import Combine
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireContentUI

@MainActor
final class ReaderContentListSnapshotTests: XCTestCase {
    func testFilteredContentsAndIDsPublishAsOneAlignedSnapshot() async throws {
        let first = contentFile(path: "first.epub")
        let second = contentFile(path: "second.epub")
        let viewModel = ReaderContentListViewModel(initialContents: [first])
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
        XCTAssertTrue(observedCounts.allSatisfy { $0.contents == $0.ids })
        XCTAssertEqual(viewModel.filteredContents.count, 2)
        XCTAssertEqual(viewModel.filteredContentIDs.count, 2)
    }

    func testUnmanagedContentLimitKeepsValuesAndIDsAligned() async throws {
        let contents = (0...10_000).map { contentFile(path: "book-\($0).epub") }
        let viewModel = ReaderContentListViewModel<ContentFile>()

        try await viewModel.load(contents: contents, sortOrder: .providedOrder)

        XCTAssertEqual(viewModel.filteredContents.count, 10_000)
        XCTAssertEqual(viewModel.filteredContentIDs.count, 10_000)
        XCTAssertEqual(viewModel.filteredContents.map(\.compoundKey), viewModel.filteredContentIDs)
    }

    private func contentFile(path: String) -> ContentFile {
        let file = ContentFile()
        file.url = URL(string: "ebook://book/\(path)")!
        file.updateCompoundKey()
        return file
    }
}
