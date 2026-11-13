import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LakeOfFireOPDS
import XCTest
@testable import LakeOfFireReader

@MainActor
final class BookCatalogPublicationMappingTests: XCTestCase {
    func testGroupedCatalogBooksFollowTopLevelBooksInDeclaredOrder() async throws {
        let document = try await aliasDocument(#"""
        {"metadata":{"title":"Catalog"},"publications":[{"metadata":{"title":"Top level"}}],
         "groups":[{"metadata":{"title":"First group"},"publications":[{"metadata":{"title":"Grouped one"}},{"metadata":{"title":"Grouped two"}}]},
                   {"metadata":{"title":"Second group"},"publications":[{"metadata":{"title":"Grouped three"}}]}]}
        """#)
        let publications = try XCTUnwrap(BookCatalogPublicationMapper.publications(in: document))
        XCTAssertEqual(publications.map(\.title), ["Top level", "Grouped one", "Grouped two", "Grouped three"])
    }

    func testOPDS2RelationlessImagesUseDocumentOrderAndFinalDocumentBase() async throws {
        let document = try await aliasDocument(#"""
        {"metadata":{"title":"Ordinary OPDS2 book"},"images":[
          {"href":"covers/first.jpg","type":"image/jpeg","width":800,"height":1200},
          {"href":"covers/larger.png","type":"image/png","width":1600,"height":2400}]}
        """#)
        let images = try XCTUnwrap(document.publication?.images)
        XCTAssertEqual(images.count, 2)
        XCTAssertTrue(images.allSatisfy { $0.rels.isEmpty })
        let books = try XCTUnwrap(BookCatalogPublicationMapper.publications(in: document))
        XCTAssertEqual(books.first?.coverURL?.absoluteString,
            "https://cdn.example/catalog/covers/first.jpg")
    }

    func testOPDS2RelationlessImagesNeverReplaceExistingCoverPriorities() async throws {
        let image = #"{"href":"image.png","rel":"http://opds-spec.org/image"}"#
        let thumbnail = #"{"href":"thumbnail.png","rel":"http://opds-spec.org/image/thumbnail"}"#
        let cover = #"{"href":"cover.png","rel":"cover"}"#
        for (tagged, expected) in [
            ([thumbnail], "thumbnail.png"),
            ([thumbnail, image], "image.png"),
            ([thumbnail, image, cover], "cover.png"),
        ] {
            let document = try await aliasDocument("""
            {"metadata":{"title":"Priority"},"images":[{"href":"unrelated-first.png"},
             \(tagged.joined(separator: ","))]}
            """)
            let books = try XCTUnwrap(BookCatalogPublicationMapper.publications(in: document))
            XCTAssertEqual(books.first?.coverURL?.lastPathComponent, expected)
        }
    }

    func testOPDS2ImageFallbackLeavesAbsentAndEmptyImagesWithoutACover() async throws {
        for images in ["", ",\"images\":[]"] {
            let document = try await aliasDocument("{\"metadata\":{\"title\":\"No cover\"}\(images)}")
            let books = try XCTUnwrap(BookCatalogPublicationMapper.publications(in: document))
            XCTAssertEqual(books.map(\.title), ["No cover"])
            XCTAssertNil(books.first?.coverURL)
        }
    }

    func testOPDS2AcquisitionAliasesReachCanonicalRelationsAndReaderDownloads() async throws {
        for (alias, canonical) in [("acquisition", LinkRelation.opdsAcquisition),
                                   ("download", LinkRelation.opdsAcquisitionOpenAccess)] {
            for relationJSON in ["\"\(alias)\"", "[\"alternate\",\"\(alias)\"]"] {
                let document = try await aliasDocument("""
                {"metadata":{"title":"Alias book"},"links":[{"href":"../books/alias.epub",
                 "rel":\(relationJSON)}]}
                """)
                let publication = try XCTUnwrap(document.publication)
                let acquisition = try XCTUnwrap(publication.links.first(withRel: canonical))
                XCTAssertTrue(acquisition.rels.contains(canonical))
                XCTAssertTrue(acquisition.rels.contains(where: \.isOPDSAcquisition))
                let books = try XCTUnwrap(BookCatalogPublicationMapper.publications(in: document))
                XCTAssertEqual(books.map(\.title), ["Alias book"])
                XCTAssertEqual(books.first?.downloadURL?.absoluteString,
                    "https://cdn.example/books/alias.epub")
            }
        }
    }

    func testOPDS2AliasSpellingsKeepGenericAcquisitionPriority() async throws {
        for generic in ["acquisition", LinkRelation.opdsAcquisition.string] {
            for openAccess in ["download", LinkRelation.opdsAcquisitionOpenAccess.string] {
                let document = try await aliasDocument("""
                {"metadata":{"title":"Feed"},"publications":[{"metadata":{"title":"Priority"},
                  "links":[{"href":"open.epub","rel":"\(openAccess)"},
                           {"href":"generic.epub","rel":"\(generic)"}]}]}
                """)
                let books = try XCTUnwrap(BookCatalogPublicationMapper.publications(in: document))
                XCTAssertEqual(books.first?.downloadURL?.lastPathComponent, "generic.epub")
            }
        }
    }

    func testOPDS2AliasNormalizationPreservesRestrictedCustomAndLookalikeRelations() async throws {
        let relations = ["buy", "borrow", "preview", "subscribe", "download-preview", "download/preview",
                         "downloaded", "acquisition-extra", "acquisition/open-access", " download ",
                         "https://custom.example/download"]
        for relation in relations {
            let document = try await aliasDocument("""
            {"metadata":{"title":"Not a direct download"},"links":[{"href":"not-full.epub",
             "rel":["alternate","\(relation)"]}]}
            """)
            let parsedRelations = try XCTUnwrap(document.publication?.links.first?.rels)
            XCTAssertEqual(parsedRelations, [.alternate, LinkRelation(relation)], relation)
            let books = try XCTUnwrap(BookCatalogPublicationMapper.publications(in: document))
            XCTAssertNil(books.first?.downloadURL, relation)
        }
    }

    func testShortAcquisitionAliasesDoNotChangeAtomOrDirectRelationConstruction() async throws {
        for alias in ["acquisition", "download"] {
            let document = try await aliasDocument("""
            <entry xmlns="http://www.w3.org/2005/Atom"><title>Custom Atom role</title>
              <link href="custom.epub" rel="\(alias)"/>
            </entry>
            """)
            let link = try XCTUnwrap(document.publication?.links.first)
            XCTAssertEqual(link.rels, [LinkRelation(alias)])
            XCTAssertFalse(LinkRelation(alias).isOPDSAcquisition)
            let books = try XCTUnwrap(BookCatalogPublicationMapper.publications(in: document))
            XCTAssertNil(books.first?.downloadURL)
        }
    }


    func testOPDS2ImageFallbackSkipsUnresolvablePreferredAndOrdinaryImages() async throws {
        let document = try await aliasDocument(#"""
        {"metadata":{"title":"Resolvable cover"},"images":[
          {"href":"http://[invalid","rel":"cover"},
          {"href":"http://[also-invalid"},
          {"href":"covers/usable.png"},
          {"href":"covers/later.png"}]}
        """#)
        let images = try XCTUnwrap(document.publication?.images)
        XCTAssertEqual(images.count, 4)
        XCTAssertNil(images[0].url(relativeTo: document.documentURL))
        XCTAssertNil(images[1].url(relativeTo: document.documentURL))
        let books = try XCTUnwrap(BookCatalogPublicationMapper.publications(in: document))
        XCTAssertEqual(books.first?.coverURL?.absoluteString, "https://cdn.example/catalog/covers/usable.png")
    }

    private func aliasDocument(_ body: String) async throws -> ParseData {
        let fixture = CatalogMappingSession(replies: [.document(body)])
        defer { fixture.close() }
        return try await fixture.document()
    }

    func testFeedRetainsMetadataCoverAndFinalResponseURL() async throws {
        let fixture = CatalogMappingSession(replies: [.document(#"""
        {"metadata":{"title":"Catalog"},"publications":[{
          "metadata":{"title":"A Book","author":["Author One","Author Two"],
            "published":"2020-01-02","description":"Summary","subtitle":"Subtitle"},
          "links":[{"href":"book.epub","rel":"http://opds-spec.org/acquisition"}],
          "images":[{"href":"cover.png","rel":"cover"}]
        }]}
        """#)])
        defer { fixture.close() }
        let books = try await fixture.requiredPublications()
        let book = try XCTUnwrap(books.first)
        XCTAssertEqual(books.count, 1)
        XCTAssertEqual(book.title, "A Book")
        XCTAssertEqual(book.author, "Author One, Author Two")
        XCTAssertEqual(book.publicationDate?.timeIntervalSince1970, 1_577_923_200)
        XCTAssertEqual(book.summary, "Summary")
        XCTAssertEqual(book.coverURL?.absoluteString, "https://cdn.example/catalog/cover.png")
        XCTAssertEqual(book.downloadURL?.absoluteString, "https://cdn.example/catalog/book.epub")
        XCTAssertFalse(book.hasContentAudio)
    }

    func testStandaloneJSONPublicationProducesAnOpenAccessDownload() async throws {
        let fixture = CatalogMappingSession(replies: [.document(#"""
        {"metadata":{"title":"Standalone","author":"Writer","subtitle":"Fallback summary"},
          "links":[{"href":"../books/full.epub","rel":"http://opds-spec.org/acquisition/open-access"}],
          "images":[{"href":"images/front.png","rel":"http://opds-spec.org/image"}]}
        """#)])
        defer { fixture.close() }
        let books = try await fixture.requiredPublications()
        XCTAssertEqual(books.map(\.title), ["Standalone"])
        XCTAssertEqual(books.first?.author, "Writer")
        XCTAssertEqual(books.first?.summary, "Fallback summary")
        XCTAssertEqual(books.first?.coverURL?.absoluteString, "https://cdn.example/catalog/images/front.png")
        XCTAssertEqual(books.first?.downloadURL?.absoluteString, "https://cdn.example/books/full.epub")
    }

    func testStandaloneAtomEntryPreservesLexicalBaseAndMetadata() async throws {
        let fixture = CatalogMappingSession(replies: [.document("""
        <entry xmlns="http://www.w3.org/2005/Atom" xml:base="../books/">
          <title>Standalone Atom</title>
          <author><name>First</name></author><author><name>Second</name></author>
          <published>2020-01-02T00:00:00Z</published>
          <summary>Atom summary</summary>
          <link href="front.png" rel="cover"/>
          <link xml:base="files/" href="full.epub" rel="http://opds-spec.org/acquisition/open-access"/>
        </entry>
        """)])
        defer { fixture.close() }
        let books = try await fixture.requiredPublications()
        let book = try XCTUnwrap(books.first)
        XCTAssertEqual(books.count, 1)
        XCTAssertEqual(book.title, "Standalone Atom")
        XCTAssertEqual(book.author, "First, Second")
        XCTAssertEqual(book.summary, "Atom summary")
        XCTAssertEqual(book.publicationDate?.timeIntervalSince1970, 1_577_923_200)
        XCTAssertEqual(book.coverURL?.absoluteString, "https://cdn.example/books/front.png")
        XCTAssertEqual(book.downloadURL?.absoluteString, "https://cdn.example/books/files/full.epub")
    }

    func testAtomFeedOpenAccessEntryRemainsAPublication() async throws {
        let fixture = CatalogMappingSession(replies: [.document("""
        <feed xmlns="http://www.w3.org/2005/Atom">
          <title>Catalog</title>
          <entry><title>Open Book</title>
            <link href="purchase" rel="http://opds-spec.org/acquisition/buy"/>
            <link href="sample.epub" rel="http://opds-spec.org/acquisition/sample"/>
            <link href="full.epub" rel="http://opds-spec.org/acquisition/open-access"/>
          </entry>
        </feed>
        """)])
        defer { fixture.close() }
        let books = try await fixture.requiredPublications()
        XCTAssertEqual(books.map(\.title), ["Open Book"])
        XCTAssertEqual(books.first?.downloadURL?.absoluteString, "https://cdn.example/catalog/full.epub")
    }

    func testGenericAcquisitionAndCoverKeepPriorityOverEarlierFallbackLinks() async throws {
        let fixture = CatalogMappingSession(replies: [.document(#"""
        {"metadata":{"title":"Priority"},"publications":[{
          "metadata":{"title":"A Book"},
          "links":[
            {"href":"full.epub","rel":"http://opds-spec.org/acquisition/open-access"},
            {"href":"original.epub","rel":"http://opds-spec.org/acquisition"}],
          "images":[
            {"href":"thumbnail.png","rel":"http://opds-spec.org/image/thumbnail"},
            {"href":"image.png","rel":"http://opds-spec.org/image"},
            {"href":"cover.png","rel":"cover"}]
        }]}
        """#)])
        defer { fixture.close() }
        let books = try await fixture.requiredPublications()
        XCTAssertEqual(books.first?.downloadURL?.lastPathComponent, "original.epub")
        XCTAssertEqual(books.first?.coverURL?.lastPathComponent, "cover.png")
    }

    func testOpenAccessDoesNotSelectEarlierPurchaseBorrowSampleOrSubscriptionLinks() async throws {
        let fixture = CatalogMappingSession(replies: [.document(#"""
        {"metadata":{"title":"Catalog"},"publications":[{
          "metadata":{"title":"Open Book"},"links":[
            {"href":"purchase","rel":"http://opds-spec.org/acquisition/buy"},
            {"href":"borrow","rel":"http://opds-spec.org/acquisition/borrow"},
            {"href":"sample.epub","rel":"http://opds-spec.org/acquisition/sample"},
            {"href":"subscribe","rel":"http://opds-spec.org/acquisition/subscribe"},
            {"href":"full.epub","rel":["alternate","http://opds-spec.org/acquisition/open-access"]}]
        }]}
        """#)])
        defer { fixture.close() }
        let books = try await fixture.requiredPublications()
        XCTAssertEqual(books.first?.downloadURL?.lastPathComponent, "full.epub")
    }

    func testNonFullBookRelationsRemainVisibleWithoutDownloads() async throws {
        let relations = [
            "http://opds-spec.org/acquisition/buy",
            "http://opds-spec.org/acquisition/borrow",
            "http://opds-spec.org/acquisition/sample",
            "http://opds-spec.org/acquisition/subscribe",
            "http://opds-spec.org/acquisition/open-access-preview",
            "http://opds-spec.org/acquisition/open-access/preview",
            "http://opds-spec.org/acquisition-other",
        ]
        for relation in relations {
            let fixture = CatalogMappingSession(replies: [.document("""
            {"metadata":{"title":"Restricted"},"links":[{"href":"not-full.epub","rel":"\(relation)"}]}
            """)])
            defer { fixture.close() }
            let books = try await fixture.requiredPublications()
            XCTAssertEqual(books.map(\.title), ["Restricted"], relation)
            XCTAssertNil(books.first?.downloadURL, relation)
        }
    }

    func testCoverFallbackOrderAndMissingOptionalMetadataStayUnchanged() async throws {
        let fixture = CatalogMappingSession(replies: [.document(#"""
        {"metadata":{"title":"Catalog"},"publications":[
          {"metadata":{"title":"Image"},"images":[
            {"href":"small.png","rel":"http://opds-spec.org/image/thumbnail"},
            {"href":"large.png","rel":"http://opds-spec.org/image"}]},
          {"metadata":{"title":"Thumbnail"},"images":[
            {"href":"small.png","rel":"http://opds-spec.org/image/thumbnail"}]},
          {"metadata":{"title":"No optional metadata"}}
        ]}
        """#)])
        defer { fixture.close() }
        let books = try await fixture.requiredPublications()
        XCTAssertEqual(books.map(\.title), ["Image", "Thumbnail", "No optional metadata"])
        XCTAssertEqual(books[0].coverURL?.lastPathComponent, "large.png")
        XCTAssertEqual(books[1].coverURL?.lastPathComponent, "small.png")
        XCTAssertNil(books[2].coverURL)
        XCTAssertNil(books[2].downloadURL)
        XCTAssertNil(books[2].summary)
        XCTAssertNil(books[2].publicationDate)
        XCTAssertEqual(books[2].author, "")
        XCTAssertTrue(books.allSatisfy { !$0.hasContentAudio })
    }

    func testResolvedEscapesQueryAndFragmentAreNotReinterpretedByMapping() async throws {
        let fixture = CatalogMappingSession(replies: [.document(#"""
        {"metadata":{"title":"Escaped"},"links":[{
          "href":"../books/%E8%AA%AD%E6%9B%B8.epub?edition=1%202#section",
          "rel":"http://opds-spec.org/acquisition/open-access"}]}
        """#)])
        defer { fixture.close() }
        let books = try await fixture.requiredPublications()
        XCTAssertEqual(books.first?.downloadURL?.absoluteString,
            "https://cdn.example/books/%E8%AA%AD%E6%9B%B8.epub?edition=1%202#section")
    }

    func testMappedValuesDoNotRetainTheMutableFeedGraph() async throws {
        let fixture = CatalogMappingSession(replies: [.document(#"""
        {"metadata":{"title":"Catalog"},"publications":[{"metadata":{"title":"Retained book"}}]}
        """#)])
        defer { fixture.close() }
        let document = try await fixture.document()
        let books = try XCTUnwrap(BookCatalogPublicationMapper.publications(in: document))
        document.feed?.publications.removeAll()
        document.feed?.metadata.title = "Changed feed"
        XCTAssertEqual(books.map(\.title), ["Retained book"])
    }

    func testNavigationAndEmptyFeedsRemainUnmappedForTheExistingLoader() async throws {
        let documents = [
            #"{"metadata":{"title":"Navigation"},"navigation":[{"href":"all.json","title":"All Books"}]}"#,
            #"{"metadata":{"title":"Empty"},"publications":[]}"#,
            #"{"metadata":{"title":"Grouped"},"groups":[{"metadata":{"title":"Group"},"publications":[{"metadata":{"title":"Grouped book"}}]}]}"#,
        ]
        for body in documents {
            let fixture = CatalogMappingSession(replies: [.document(body)])
            defer { fixture.close() }
            let books = try await fixture.publications()
            XCTAssertNil(books)
        }
    }

    func testFeedPublicationsKeepOrderAndTakePrecedenceOverNavigation() async throws {
        let fixture = CatalogMappingSession(replies: [.document(#"""
        {"metadata":{"title":"Catalog"},"navigation":[{"href":"all.json","title":"All Books"}],
         "publications":[{"metadata":{"title":"Second alphabetically"}},
                         {"metadata":{"title":"First alphabetically"}}]}
        """#)])
        defer { fixture.close() }
        let books = try await fixture.requiredPublications()
        XCTAssertEqual(books.map(\.title), ["Second alphabetically", "First alphabetically"])
    }

    func testHTTPFailureCannotMapAValidLookingBodyAndSameURLCanRetry() async throws {
        let body = #"{"metadata":{"title":"Retry book"},"links":[{"href":"full.epub","rel":"http://opds-spec.org/acquisition/open-access"}]}"#
        let fixture = CatalogMappingSession(replies: [
            .document(body, status: 503), .document(body),
        ])
        defer { fixture.close() }
        do {
            _ = try await fixture.publications()
            XCTFail("HTTP failure produced publications")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("503"))
        }
        let retry = try await fixture.requiredPublications()
        XCTAssertEqual(retry.map(\.title), ["Retry book"])
        XCTAssertEqual(retry.first?.downloadURL?.lastPathComponent, "full.epub")
    }

    func testTransportFailureCanRetryWithoutRetainingAnEarlierResult() async throws {
        let fixture = CatalogMappingSession(replies: [
            .transportFailure(.networkConnectionLost),
            .document(#"{"metadata":{"title":"Recovered standalone"}}"#),
        ])
        defer { fixture.close() }
        do {
            _ = try await fixture.publications()
            XCTFail("Transport failure produced publications")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost)
        }
        let retry = try await fixture.requiredPublications()
        XCTAssertEqual(retry.map(\.title), ["Recovered standalone"])
    }
}

@MainActor
private final class CatalogMappingSession {
    let url = URL(string: "https://book-mapping.example/\(UUID().uuidString)/requested.xml")!
    let session: URLSession

    init(replies: [CatalogMappingReply]) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogMappingProtocol.self]
        configuration.timeoutIntervalForRequest = 3
        session = URLSession(configuration: configuration)
        CatalogMappingProtocol.replies.set(replies, for: url)
    }

    func document() async throws -> ParseData {
        try await OPDSParser.parseURL(url: url, session: session)
    }

    func publications() async throws -> [LakeOfFireReader.Publication]? {
        let parsed = try await document()
        return BookCatalogPublicationMapper.publications(in: parsed)
    }

    func requiredPublications(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> [LakeOfFireReader.Publication] {
        let books = try await publications()
        return try XCTUnwrap(books, file: file, line: line)
    }

    func close() {
        session.invalidateAndCancel()
        CatalogMappingProtocol.replies.remove(for: url)
    }
}

private enum CatalogMappingReply: Sendable {
    case document(String, status: Int = 200)
    case transportFailure(URLError.Code)
}

/// Scripted transport only: parsing, relation selection, metadata and URL
/// mapping all run through the shipping OPDS parser and Reader mapper.
private final class CatalogMappingReplies: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [URL: [CatalogMappingReply]] = [:]

    func set(_ replies: [CatalogMappingReply], for url: URL) {
        lock.lock()
        defer { lock.unlock() }
        values[url] = replies
    }

    func take(for url: URL) -> CatalogMappingReply? {
        lock.lock()
        defer { lock.unlock() }
        guard var replies = values[url], !replies.isEmpty else { return nil }
        let first = replies.removeFirst()
        values[url] = replies
        return first
    }

    func remove(for url: URL) {
        lock.lock()
        defer { lock.unlock() }
        values.removeValue(forKey: url)
    }
}

private final class CatalogMappingProtocol: URLProtocol {
    static let replies = CatalogMappingReplies()

    override class func canInit(with request: URLRequest) -> Bool {
        // Installed only on the private fixture session. An unexpected URL
        // fails against the finite script instead of reaching the network.
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let reply = Self.replies.take(for: url) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        switch reply {
        case let .transportFailure(code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case let .document(body, status):
            // Control the final document URI without simulating an HTTP
            // redirect or URLSession redirect-delegate behavior.
            let response = HTTPURLResponse(
                url: URL(string: "https://cdn.example/catalog/document.json")!,
                statusCode: status, httpVersion: nil, headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
