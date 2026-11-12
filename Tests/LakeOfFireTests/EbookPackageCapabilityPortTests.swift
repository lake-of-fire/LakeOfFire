import Foundation
import XCTest
@testable import LakeOfFireReader

final class EbookPackageCapabilityPortTests: XCTestCase {
    func testPackageCapabilityRejectsConflictingLegacyRouteIdentities() throws {
        let packageA = try XCTUnwrap(URL(string: "ebook://ebook/load/local/Books/a.epub"))
        let packageB = try XCTUnwrap(URL(string: "ebook://ebook/load/local/Books/b.epub"))
        var request = URLRequest(url: try XCTUnwrap(URL(string:
            "ebook://ebook/entries?sourceURL=\(packageA.absoluteString)"
        )))
        request.mainDocumentURL = packageA

        XCTAssertEqual(
            ebookPackageCapabilitySourceURL(for: request, route: "/entries"),
            packageA
        )

        request.setValue(packageB.absoluteString, forHTTPHeaderField: "X-Ebook-Source-URL")
        XCTAssertNil(ebookPackageCapabilitySourceURL(for: request, route: "/entries"))

        request.setValue(nil, forHTTPHeaderField: "X-Ebook-Source-URL")
        request.url = try XCTUnwrap(URL(string:
            "ebook://ebook/entries?sourceURL=\(packageA.absoluteString)&sourceURL=\(packageA.absoluteString)"
        ))
        XCTAssertNil(ebookPackageCapabilitySourceURL(for: request, route: "/entries"))
    }

    func testPackageCapabilityRejectsPresentInvalidOrValuelessIdentities() throws {
        let package = try XCTUnwrap(URL(string: "ebook://ebook/load/local/Books/a.epub"))
        var request = URLRequest(url: try XCTUnwrap(URL(string: "ebook://ebook/entries")))
        request.mainDocumentURL = package

        request.setValue("https://example.com/not-an-ebook", forHTTPHeaderField: "X-Ebook-Source-URL")
        XCTAssertNil(ebookPackageCapabilitySourceURL(for: request, route: "/entries"))

        request.setValue("", forHTTPHeaderField: "X-Ebook-Source-URL")
        XCTAssertNil(ebookPackageCapabilitySourceURL(for: request, route: "/entries"))

        request.setValue(nil, forHTTPHeaderField: "X-Ebook-Source-URL")
        request.url = try XCTUnwrap(URL(string: "ebook://ebook/entries?sourceURL"))
        XCTAssertNil(ebookPackageCapabilitySourceURL(for: request, route: "/entries"))

        request.url = try XCTUnwrap(URL(string: "ebook://ebook/entries?sourceURL="))
        XCTAssertNil(ebookPackageCapabilitySourceURL(for: request, route: "/entries"))

        request.url = try XCTUnwrap(URL(string:
            "ebook://ebook/entries?sourceURL=not-a-package&sourceURL=")
        )
        XCTAssertNil(ebookPackageCapabilitySourceURL(for: request, route: "/entries"))

        request.url = try XCTUnwrap(URL(string: "ebook://ebook/entries"))
        request.mainDocumentURL = try XCTUnwrap(URL(string: "https://example.com/book.epub"))
        XCTAssertNil(ebookPackageCapabilitySourceURL(for: request, route: "/entries"))
    }

    func testProcessTextContentLocationRequiresAdmittedPackageCapability() throws {
        let packageA = try XCTUnwrap(URL(string: "ebook://ebook/load/local/Books/a.epub"))
        let packageB = try XCTUnwrap(URL(string: "ebook://ebook/load/local/Books/b.epub"))
        var request = URLRequest(url: try XCTUnwrap(URL(string: "ebook://ebook/process-text")))
        request.mainDocumentURL = packageA
        request.setValue(packageA.absoluteString, forHTTPHeaderField: "X-CONTENT-LOCATION")

        XCTAssertEqual(ebookProcessTextContentURL(for: request), packageA)

        request.setValue(packageB.absoluteString, forHTTPHeaderField: "X-CONTENT-LOCATION")
        XCTAssertNil(ebookProcessTextContentURL(for: request))

        request.setValue("not-a-package", forHTTPHeaderField: "X-CONTENT-LOCATION")
        XCTAssertNil(ebookProcessTextContentURL(for: request))

        request.setValue("https://example.com/book.epub", forHTTPHeaderField: "X-CONTENT-LOCATION")
        XCTAssertNil(ebookProcessTextContentURL(for: request))
    }

    func testPackageCapabilityCanonicalizesDecorationsButDoesNotRebindNilDocument() throws {
        let package = try XCTUnwrap(URL(string: "ebook://ebook/load/local/Books/a.epub"))
        let decoratedPackage = try XCTUnwrap(URL(string:
            "ebook://ebook/load/local/Books/a.epub?stale=1#fragment"
        ))
        var request = URLRequest(url: try XCTUnwrap(URL(string: "ebook://ebook/entries")))
        request.mainDocumentURL = decoratedPackage

        XCTAssertEqual(
            ebookPackageCapabilitySourceURL(for: request, route: "/entries"),
            package
        )

        request.mainDocumentURL = nil
        XCTAssertNil(ebookPackageCapabilitySourceURL(for: request, route: "/entries"))
        XCTAssertEqual(
            ebookPackageCapabilitySourceURL(
                for: request,
                route: "/processed-section",
                expectedSourceURL: package,
                allowsMissingMainDocument: true
            ),
            package
        )
    }
    func testCanonicalPackageRejectsCredentialsPortsAndRelativeIdentity() {
        for raw in ["ebook://user@ebook/load/a.epub", "ebook://user:pass@ebook/load/a.epub", "ebook://ebook:42/load/a.epub"] {
            XCTAssertNil(ebookCanonicalPackageURL(URL(string: raw)!))
        }
        XCTAssertNil(ebookCanonicalPackageURL(URL(string: "a.epub", relativeTo: URL(string: "ebook://ebook/load/")!)!))
    }

    func testProcessedDocumentOwnsOnlyItsDeclaredSource() throws {
        let source = URL(string: "ebook://ebook/load/local/a.epub")!
        var owner = URLComponents(string: "ebook://ebook/processed-section")!
        owner.queryItems = [
            .init(name: "sourceURL", value: source.absoluteString),
            .init(name: "subpath", value: "OPS/a.xhtml")
        ]
        var request = URLRequest(url: URL(string: "ebook://ebook/entries")!)
        request.mainDocumentURL = owner.url
        XCTAssertEqual(ebookPackageCapabilitySourceURL(for: request, route: "/entries"), source)
        request.setValue("ebook://ebook/load/local/b.epub", forHTTPHeaderField: "X-Ebook-Source-URL")
        XCTAssertNil(ebookPackageCapabilitySourceURL(for: request, route: "/entries"))
    }

    func testHeaderAloneCannotCreateDocumentOwnership() {
        var request = URLRequest(url: URL(string: "ebook://ebook/entry?subpath=OPS/a.xhtml")!)
        request.setValue("ebook://ebook/load/local/a.epub", forHTTPHeaderField: "X-Ebook-Source-URL")
        XCTAssertNil(ebookPackageCapabilitySourceURL(for: request, route: "/entry"))
    }
}
