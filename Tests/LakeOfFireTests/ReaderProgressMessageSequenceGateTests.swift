import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireReader

final class ReaderProgressMessageSequenceGateTests: XCTestCase {
    func testRejectsOlderProgressAfterNewerFragmentForSameContent() throws {
        var gate = ReaderProgressMessageSequenceGate()
        let olderURL = try XCTUnwrap(URL(string: "ebook://book/reader#older"))
        let newerURL = try XCTUnwrap(URL(string: "ebook://book/reader#newer"))

        XCTAssertTrue(gate.reserve(sequence: 10, contentURL: olderURL))
        XCTAssertTrue(gate.reserve(sequence: 11, contentURL: newerURL))
        XCTAssertFalse(gate.reserve(sequence: 10, contentURL: olderURL))
    }

    func testChangingContentStartsIndependentSequence() throws {
        var gate = ReaderProgressMessageSequenceGate()
        let firstBookURL = try XCTUnwrap(URL(string: "ebook://first/reader"))
        let secondBookURL = try XCTUnwrap(URL(string: "ebook://second/reader"))

        XCTAssertTrue(gate.reserve(sequence: 20, contentURL: firstBookURL))
        XCTAssertFalse(gate.reserve(sequence: 21, contentURL: secondBookURL))
        gate.activate(contentURL: secondBookURL)
        XCTAssertTrue(gate.reserve(sequence: 1, contentURL: secondBookURL))
    }

    func testLoaderAndSourceURLsShareSequenceIdentity() throws {
        var gate = ReaderProgressMessageSequenceGate()
        let sourceURL = URL(fileURLWithPath: "/tmp/Books/sample.epub")
        let loaderURL = try XCTUnwrap(ReaderContentLoader.readerLoaderURL(for: sourceURL))

        XCTAssertTrue(gate.reserve(sequence: 30, contentURL: loaderURL))
        XCTAssertFalse(gate.reserve(sequence: 29, contentURL: sourceURL))
    }
}
