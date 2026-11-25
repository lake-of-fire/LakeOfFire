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

    func testMainFrameRequestSuppliesMissingTopLevelProvenance() {
        for requiresMainFrame in [false, true] {
            XCTAssertTrue(ReaderDocumentMutationAdmission.acceptsTopLevelDocument(
                claimedURL: URL(string: "https://example.com/article#reported"),
                frameMainDocumentURL: nil,
                frameRequestURL: URL(string: "https://example.com/article#loaded"),
                currentPageURL: current,
                requiresMainFrame: requiresMainFrame,
                isMainFrame: true
            ))
        }
    }

    func testMainFrameRequestMustAgreeWithClaimedAndCurrentDocument() {
        let other = URL(string: "https://example.com/previous")!
        let cases: [(claimed: URL?, request: URL?, current: URL)] = [
            (other, current, current),
            (current, other, current),
            (current, current, other),
            (nil, current, current),
            (current, nil, current)
        ]
        for (index, input) in cases.enumerated() {
            XCTAssertFalse(ReaderDocumentMutationAdmission.acceptsTopLevelDocument(
                claimedURL: input.claimed,
                frameMainDocumentURL: nil,
                frameRequestURL: input.request,
                currentPageURL: input.current,
                requiresMainFrame: false,
                isMainFrame: true
            ), "Mismatched or absent provenance at case \(index) must be rejected")
        }
    }

    func testMainDocumentURLRemainsAuthoritativeWhenRequestMatchesCurrentDocument() {
        XCTAssertFalse(ReaderDocumentMutationAdmission.acceptsTopLevelDocument(
            claimedURL: current,
            frameMainDocumentURL: URL(string: "https://example.com/previous"),
            frameRequestURL: current,
            currentPageURL: current,
            requiresMainFrame: false,
            isMainFrame: true
        ))
    }

    func testSubframeRequestCannotSupplyMissingTopLevelProvenance() {
        for requiresMainFrame in [false, true] {
            XCTAssertFalse(ReaderDocumentMutationAdmission.acceptsTopLevelDocument(
                claimedURL: current,
                frameMainDocumentURL: nil,
                frameRequestURL: current,
                currentPageURL: current,
                requiresMainFrame: requiresMainFrame,
                isMainFrame: false
            ))
        }
    }

    func testSubframeWithNativeTopLevelProvenanceRemainsAdmissible() {
        XCTAssertTrue(ReaderDocumentMutationAdmission.acceptsTopLevelDocument(
            claimedURL: current,
            frameMainDocumentURL: URL(string: "https://example.com/article#loaded"),
            frameRequestURL: URL(string: "https://example.com/embedded-frame"),
            currentPageURL: current,
            requiresMainFrame: false,
            isMainFrame: false
        ))
        XCTAssertFalse(ReaderDocumentMutationAdmission.acceptsTopLevelDocument(
            claimedURL: current,
            frameMainDocumentURL: current,
            frameRequestURL: URL(string: "https://example.com/embedded-frame"),
            currentPageURL: current,
            requiresMainFrame: true,
            isMainFrame: false
        ))
    }

    func testExistingCallersWithoutRequestProvenanceRemainFailClosed() {
        XCTAssertFalse(ReaderDocumentMutationAdmission.acceptsTopLevelDocument(
            claimedURL: current,
            frameMainDocumentURL: nil,
            currentPageURL: current,
            requiresMainFrame: false,
            isMainFrame: true
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
