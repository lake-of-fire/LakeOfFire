import SwiftUI
import XCTest
@testable import LakeOfFireContentUI

final class ReaderImageRequestTests: XCTestCase {
    func test_thumbnailRequest_isOptInAndUsesDisplayPointBounds() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/cover.jpg"))

        let originalRequest = makeReaderImageRequest(
            url: url,
            contentMode: .fill,
            thumbnailSize: nil
        )
        let thumbnailRequest = makeReaderImageRequest(
            url: url,
            contentMode: .fit,
            thumbnailSize: CGSize(width: 80, height: 120)
        )

        XCTAssertNil(originalRequest.thumbnail)
        XCTAssertNotNil(thumbnailRequest.thumbnail)

        let largerRequest = makeReaderImageRequest(
            url: url,
            contentMode: .fit,
            thumbnailSize: CGSize(width: 160, height: 240)
        )
        let fillRequest = makeReaderImageRequest(
            url: url,
            contentMode: .fill,
            thumbnailSize: CGSize(width: 80, height: 120)
        )
        XCTAssertNotEqual(thumbnailRequest.thumbnail, largerRequest.thumbnail)
        XCTAssertNotEqual(thumbnailRequest.thumbnail, fillRequest.thumbnail)
    }

    func test_thumbnailRequest_invalidBoundsPreserveOriginalDecode() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/cover.jpg"))
        let invalidSizes = [
            CGSize(width: 0, height: 48),
            CGSize(width: 48, height: -1),
            CGSize(width: CGFloat.infinity, height: 48),
            CGSize(width: 48, height: CGFloat.nan),
        ]

        for invalidSize in invalidSizes {
            let request = makeReaderImageRequest(
                url: url,
                contentMode: .fill,
                thumbnailSize: invalidSize
            )
            XCTAssertNil(request.thumbnail)
        }
    }
}
