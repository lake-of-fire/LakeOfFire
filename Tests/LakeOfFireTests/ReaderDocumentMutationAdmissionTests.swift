import XCTest
@testable import LakeOfFireReader

final class ReaderDocumentMutationAdmissionTests: XCTestCase {
    private let current = URL(string: "https://example.com/article#visible")!

    func testTopLevelAdmissionRequiresPayloadWebKitAndCurrentDocumentToAgree() {
        XCTAssertTrue(ReaderDocumentMutationAdmission.acceptsTopLevelDocument(
            claimedURL: URL(string: "https://example.com/article#reported"),
            frameMainDocumentURL: URL(string: "https://example.com/article#loaded"),
            currentPageURL: current,
            requiresMainFrame: true,
            isMainFrame: true
        ))

        XCTAssertFalse(ReaderDocumentMutationAdmission.acceptsTopLevelDocument(
            claimedURL: URL(string: "https://victim.example/article"),
            frameMainDocumentURL: URL(string: "https://example.com/article"),
            currentPageURL: current,
            requiresMainFrame: true,
            isMainFrame: true
        ))
        XCTAssertFalse(ReaderDocumentMutationAdmission.acceptsTopLevelDocument(
            claimedURL: URL(string: "https://example.com/article"),
            frameMainDocumentURL: URL(string: "https://example.com/previous"),
            currentPageURL: current,
            requiresMainFrame: true,
            isMainFrame: true
        ))
        XCTAssertFalse(ReaderDocumentMutationAdmission.acceptsTopLevelDocument(
            claimedURL: URL(string: "https://example.com/article"),
            frameMainDocumentURL: URL(string: "https://example.com/article"),
            currentPageURL: current,
            requiresMainFrame: true,
            isMainFrame: false
        ))
    }

    func testFrameTargetCannotNameAnUnrelatedRecord() {
        XCTAssertTrue(ReaderDocumentMutationAdmission.acceptsFrameTarget(
            claimedFrameURL: URL(string: "https://www.youtube.com/watch?v=abcdefghijk#captions"),
            frameRequestURL: URL(string: "https://www.youtube.com/watch?v=abcdefghijk")
        ))
        XCTAssertFalse(ReaderDocumentMutationAdmission.acceptsFrameTarget(
            claimedFrameURL: URL(string: "https://www.youtube.com/watch?v=otherrecord"),
            frameRequestURL: URL(string: "https://www.youtube.com/watch?v=abcdefghijk")
        ))
    }
}
