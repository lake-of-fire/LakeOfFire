import XCTest
@testable import LakeOfFireReader

final class ReaderCanonicalSegmentSidecarResolutionTests: XCTestCase {
    func testResolverRejectsStaleFingerprint() throws {
        let data = Data(#"{"v":10}"#.utf8)
        let stored = try XCTUnwrap(ReaderExternalSegmentSidecarStore.shared.insert(data))

        XCTAssertEqual(
            readerCanonicalSegmentSidecar(matchingRevision: stored.signature),
            data
        )
        XCTAssertNil(
            readerCanonicalSegmentSidecar(
                matchingRevision: stored.signature.replacingOccurrences(
                    of: "sha256:",
                    with: "sha256:1"
                )
            )
        )
    }
}
