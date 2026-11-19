import Foundation
import Combine
import XCTest
@testable import LakeOfFireContent

@MainActor
final class ReaderPreparationPublicationTests: XCTestCase {
    private func content(_ key: String, title: String) -> HistoryRecord {
        let row = HistoryRecord()
        row.compoundKey = key
        row.url = URL(string: "https://example.com/shared-reader-identity")!
        row.title = title
        return row
    }

    func testReentrantAdmissionAfterWillSetCannotOverwriteSameURLSuccessor() {
        let reader = ReaderContent()
        let original = content("original", title: "Original")
        let proposed = content("proposed", title: "Older update")
        let successor = content("successor", title: "Newer update")
        reader.pageURL = original.url
        reader.content = original
        var willSetWasPublished = false
        var replaced = false
        var lastPublished: (any ReaderContentProtocol)?
        let observation = reader.$content.sink { value in
            lastPublished = value
            if value === proposed { willSetWasPublished = true }
        }

        let published = reader.publishUpdatedContent(proposed, permitsPublication: {
            if willSetWasPublished && !replaced {
                replaced = true
                reader.content = successor
            }
            return true
        })

        XCTAssertTrue(willSetWasPublished)
        XCTAssertTrue(replaced)
        XCTAssertFalse(published)
        XCTAssertTrue(reader.content === successor)
        XCTAssertTrue(lastPublished === successor)
        XCTAssertEqual(reader.contentTitle, "Newer update")
        withExtendedLifetime(observation) {}
    }

    func testStableAdmissionPublishesTheUpdatedSameURLRow() {
        let reader = ReaderContent()
        let original = content("original", title: "Original")
        let updated = content("updated", title: "Updated")
        reader.pageURL = original.url
        reader.content = original
        XCTAssertTrue(reader.publishUpdatedContent(updated, permitsPublication: { true }))
        XCTAssertTrue(reader.content === updated)
        XCTAssertEqual(reader.contentTitle, "Updated")
    }
}
