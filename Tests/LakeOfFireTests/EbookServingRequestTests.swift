import Foundation
import XCTest
@testable import LakeOfFireReader
@testable import LakeOfFireContent

final class EbookServingRequestTests: XCTestCase {
    private let source = URL(string: "ebook://ebook/load/local/Books/book.epub")!

    private func lease(in store: ReaderEBookServingSessionStore) throws -> ReaderEBookServingLease {
        let files = [
            ("mimetype", "application/epub+zip"),
            ("META-INF/container.xml", "<container xmlns='urn:oasis:names:tc:opendocument:xmlns:container'><rootfiles><rootfile full-path='OPS/book.opf' media-type='application/oebps-package+xml'/></rootfiles></container>"),
            ("OPS/book.opf", "<package><spine/></package>"),
            ("OPS/chapter.xhtml", "Original")
        ]
        let bytes = EBookZIPPathFixture.archive(files.map {
            EBookZIPPathFixture.File(name: Data($0.0.utf8), bytes: Data($0.1.utf8))
        })
        return try EBookZIPPathFixture.withFile(bytes) { url in
            let snapshot = try ReaderEBookPackageSnapshot.retainCoordinatedFile(at: url, maximumBytes: 1_000_000)
            return try store.install(ReaderEBookServingPackage(sourceURL: source, snapshot: snapshot))
        }
    }

    private func request(_ path: String, session: String? = nil) -> URLRequest {
        var components = URLComponents(string: "ebook://ebook" + path)!
        components.queryItems = [URLQueryItem(name: "sourceURL", value: source.absoluteString)]
        if let session { components.queryItems?.append(URLQueryItem(name: "packageSessionID", value: session)) }
        var request = URLRequest(url: components.url!)
        request.mainDocumentURL = source
        return request
    }

    func testMatchingQueryAndHeaderCaptureButDisagreementAndDuplicatesReject() throws {
        let store = ReaderEBookServingSessionStore(), lease = try lease(in: store)
        let binding = ReaderEBookServingSessionBinding(store: store)
        var request = request("/entries", session: lease.id)
        request.setValue(lease.id, forHTTPHeaderField: "X-Ebook-Package-Session")
        let access = try XCTUnwrap(EbookServingRequest.capture(request, binding: binding))
        XCTAssertTrue(access.lease === lease)
        request.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "X-Ebook-Package-Session")
        XCTAssertThrowsError(try EbookServingRequest.capture(request, binding: binding))
        request.setValue(nil, forHTTPHeaderField: "X-Ebook-Package-Session")
        request.url = URL(string: request.url!.absoluteString + "&packageSessionID=" + lease.id)!
        XCTAssertThrowsError(try EbookServingRequest.capture(request, binding: binding))
    }

    func testRelativeResourceInheritsExactSectionSessionAndRejectsForeignHeader() throws {
        let store = ReaderEBookServingSessionStore(), lease = try lease(in: store)
        let binding = ReaderEBookServingSessionBinding(store: store)
        var section = request("/processed-section", session: lease.id)
        section.url = URL(string: section.url!.absoluteString + "&subpath=OPS%2Fchapter.xhtml")!
        let base = ebookProcessedSectionBaseURL(
            sourceURL: source, sectionHref: "OPS/chapter.xhtml", generationID: lease.generationID
        )
        var resource = URLRequest(url: URL(string: base + "chapter.xhtml")!)
        resource.mainDocumentURL = section.url
        let captured = try XCTUnwrap(EbookServingRequest.capture(resource, binding: binding))
        XCTAssertTrue(captured.lease === lease)
        XCTAssertEqual(try captured.lease?.readEntry(subpath: "OPS/chapter.xhtml"), Data("Original".utf8))
        resource.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "X-Ebook-Package-Session")
        XCTAssertThrowsError(try EbookServingRequest.capture(resource, binding: binding))
    }

    func testSectionHeaderAloneCannotLoseCapabilityForRelativeAssets() throws {
        let store = ReaderEBookServingSessionStore(), lease = try lease(in: store)
        let binding = ReaderEBookServingSessionBinding(store: store)
        var section = request("/processed-section")
        section.url = URL(string: section.url!.absoluteString + "&subpath=OPS%2Fchapter.xhtml")!
        section.setValue(lease.id, forHTTPHeaderField: "X-Ebook-Package-Session")
        XCTAssertThrowsError(try EbookServingRequest.capture(section, binding: binding))
    }

    func testWithdrawalRejectsCapturedPublicationAndOmittedTokenCannotFallback() throws {
        let store = ReaderEBookServingSessionStore(), lease = try lease(in: store)
        let binding = ReaderEBookServingSessionBinding(store: store)
        let captured = try XCTUnwrap(EbookServingRequest.capture(request("/entries", session: lease.id), binding: binding))
        store.withdraw(lease)
        XCTAssertThrowsError(try captured.validate())
        XCTAssertThrowsError(try EbookServingRequest.capture(request("/entries"), binding: binding))
    }

    func testTextProcessingRequiresTheSameNativePackageCapability() throws {
        let store = ReaderEBookServingSessionStore(), lease = try lease(in: store)
        let binding = ReaderEBookServingSessionBinding(store: store)
        var processing = URLRequest(url: URL(string: "ebook://ebook/process-text")!)
        processing.mainDocumentURL = source
        processing.setValue(source.absoluteString, forHTTPHeaderField: "X-Content-Location")
        XCTAssertThrowsError(try EbookServingRequest.capture(processing, binding: binding))
        processing.setValue(lease.id, forHTTPHeaderField: "X-Ebook-Package-Session")
        let captured = try XCTUnwrap(EbookServingRequest.capture(processing, binding: binding))
        XCTAssertTrue(captured.lease === lease)
        store.close()
        XCTAssertThrowsError(try captured.validate())
    }
}
