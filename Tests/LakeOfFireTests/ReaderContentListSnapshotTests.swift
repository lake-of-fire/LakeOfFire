import Combine
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireReader

@MainActor
final class ReaderContentListSnapshotTests: XCTestCase {
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

    func testSeparatedGroupsPreserveRowOrderHeadersAndBoundaries() {
        let first = contentFile(path: "first.epub")
        let second = contentFile(path: "second.epub")
        let third = contentFile(path: "third.epub")
        let presentation = ReaderContentGroupingPresentation(sections: [
            ReaderContentGroupingSection<ContentFile>(id: "empty", title: "Empty", items: []),
            ReaderContentGroupingSection(id: "today", title: "Today", items: [first, second]),
            ReaderContentGroupingSection(id: "yesterday", title: "Yesterday", items: [third])
        ])

        XCTAssertEqual(presentation.sections.map(\.id), ["empty", "today", "yesterday"])
        XCTAssertEqual(presentation.separatedRows.map { $0.item.id },
                       [first.compoundKey, second.compoundKey, third.compoundKey])
        XCTAssertEqual(presentation.separatedRows.map(\.headerTitle), ["Today", nil, "Yesterday"])
        XCTAssertEqual(presentation.separatedRows.map { $0.item.offset }, [0, 1, 0])
        XCTAssertEqual(presentation.separatedRows.map(\.isLastInGroup), [false, true, true])
    }

    func testSeparatedRowIdentitySurvivesReorderingAndUsesPublishedIDs() {
        let first = contentFile(path: "first.epub")
        let second = contentFile(path: "second.epub")
        let original = ReaderContentGroupingPresentation(sections: [
            ReaderContentGroupingSection(id: "group", title: "Group", items: [first, second],
                                         itemIDs: ["first-id", "second-id"])
        ])
        let reordered = ReaderContentGroupingPresentation(sections: [
            ReaderContentGroupingSection(id: "group", title: "Renamed", items: [second, first],
                                         itemIDs: ["second-id", "first-id"])
        ])

        XCTAssertEqual(original.separatedRows[0].id, reordered.separatedRows[1].id)
        XCTAssertEqual(original.separatedRows[1].id, reordered.separatedRows[0].id)
        first.compoundKey = "changed-after-publication"
        XCTAssertEqual(original.separatedRows[0].id.contentID, "first-id")
        XCTAssertEqual(original.separatedRows[0].item.id, "first-id")

        let regrouped = ReaderContentGroupingPresentation(sections: [
            ReaderContentGroupingSection(id: "other", title: "Other", items: [first], itemIDs: ["first-id"])
        ])
        XCTAssertNotEqual(original.separatedRows[0].id, regrouped.separatedRows[0].id)
        XCTAssertEqual(regrouped.separatedRows[0].headerTitle, "Other")
        XCTAssertTrue(regrouped.separatedRows[0].isLastInGroup)
    }

    func testSortedLoadPublishesOnePreparedSnapshot() async throws {
        let first = contentFile(path: "first.epub")
        let second = contentFile(path: "second.epub")
        first.createdAt = Date(timeIntervalSince1970: 1)
        second.createdAt = Date(timeIntervalSince1970: 2)
        let model = ReaderContentListViewModel<ContentFile>()
        var revisions = Set([model.contentRevision])
        let observation = model.objectWillChange.sink { revisions.insert(model.contentRevision) }
        defer { observation.cancel() }
        try await model.load(contents: [first, second], sortOrder: .createdAt)
        revisions.insert(model.contentRevision)
        XCTAssertEqual(revisions.count, 2, "Only the initial empty and final sorted snapshots are published")
        XCTAssertEqual(model.identifiedItems.map(\.id), [second.compoundKey, first.compoundKey])
        XCTAssertEqual(model.identifiedItems.map(\.offset), [0, 1])
        XCTAssertEqual(model.identifiedItems.map { $0.content.compoundKey }, model.filteredContentIDs)
    }

    func testSameIdentitiesStillPublishNewValuesAndRevision() async throws {
        let old = contentFile(path: "same.epub")
        let replacement = contentFile(path: "same.epub")
        old.title = "Old"
        replacement.title = "Changed"
        let model = ReaderContentListViewModel(initialContents: [old])
        let previousRevision = model.contentRevision
        try await model.load(contents: [replacement], sortOrder: .providedOrder)
        XCTAssertNotEqual(model.contentRevision, previousRevision)
        XCTAssertTrue(model.identifiedItems[0].content === replacement)
        XCTAssertEqual(model.filteredContents[0].title, "Changed")
    }

    private func contentFile(path: String) -> ContentFile {
        let file = ContentFile()
        file.url = URL(string: "ebook://book/\(path)")!
        file.updateCompoundKey()
        return file
    }
}
