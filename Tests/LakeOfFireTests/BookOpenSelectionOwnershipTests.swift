import XCTest
import Foundation
@testable import LakeOfFireOPDS
@testable import LakeOfFireReader

private actor BookOpenSelectionGate {
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func suspendIgnoringCancellation() async {
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilSuspended() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

final class BookOpenSelectionOwnershipTests: XCTestCase {
    @MainActor
    func testOPDS2RelationlessImagesUseDocumentOrderAndFinalDocumentBase() throws {
        let document = try catalogDocument(#"""
        {"metadata":{"title":"Ordinary OPDS2 book"},"images":[
          {"href":"covers/first.jpg","type":"image/jpeg","width":800,"height":1200},
          {"href":"covers/larger.png","type":"image/png","width":1600,"height":2400}]}
        """#)
        let images = try XCTUnwrap(document.publication?.images)
        XCTAssertEqual(images.count, 2)
        XCTAssertTrue(images.allSatisfy { $0.rels.isEmpty })
        let books = try XCTUnwrap(BookLibraryViewModel.mappedPublications(
            in: document, relativeTo: catalogRequestURL))
        XCTAssertEqual(books.first?.coverURL?.absoluteString,
            "https://cdn.example/releases/v2/covers/first.jpg")
    }

    @MainActor
    func testOPDS2RelationlessImagesNeverReplaceExistingCoverPriorities() throws {
        let image = #"{"href":"image.png","rel":"http://opds-spec.org/image"}"#
        let thumbnail = #"{"href":"thumbnail.png","rel":"http://opds-spec.org/image/thumbnail"}"#
        let cover = #"{"href":"cover.png","rel":"cover"}"#
        for (tagged, expected) in [
            ([thumbnail], "thumbnail.png"),
            ([thumbnail, image], "image.png"),
            ([thumbnail, image, cover], "cover.png"),
        ] {
            let document = try catalogDocument("""
            {"metadata":{"title":"Priority"},"images":[{"href":"unrelated-first.png"},
             \(tagged.joined(separator: ","))]}
            """)
            let books = try XCTUnwrap(BookLibraryViewModel.mappedPublications(
                in: document, relativeTo: catalogRequestURL))
            XCTAssertEqual(books.first?.coverURL?.lastPathComponent, expected)
        }
    }

    @MainActor
    func testOPDS2ImageFallbackLeavesAbsentAndEmptyImagesWithoutACover() throws {
        for images in ["", ",\"images\":[]"] {
            let document = try catalogDocument("{\"metadata\":{\"title\":\"No cover\"}\(images)}")
            let books = try XCTUnwrap(BookLibraryViewModel.mappedPublications(
                in: document, relativeTo: catalogRequestURL))
            XCTAssertEqual(books.map(\.title), ["No cover"])
            XCTAssertNil(books.first?.coverURL)
        }
    }

    @MainActor
    func testOPDS2AcquisitionAliasesReachCanonicalRelationsAndReaderDownloads() throws {
        for (alias, canonical) in [("acquisition", LinkRelation.opdsAcquisition),
                                   ("download", LinkRelation.opdsAcquisitionOpenAccess)] {
            for relationJSON in ["\"\(alias)\"", "[\"alternate\",\"\(alias)\"]"] {
                let document = try catalogDocument("""
                {"metadata":{"title":"Alias book"},"links":[{"href":"../books/alias.epub",
                 "rel":\(relationJSON)}]}
                """)
                let publication = try XCTUnwrap(document.publication)
                let acquisition = try XCTUnwrap(publication.links.first(withRel: canonical))
                XCTAssertTrue(acquisition.rels.contains(canonical))
                XCTAssertTrue(acquisition.rels.contains(where: \.isOPDSAcquisition))
                let books = try XCTUnwrap(BookLibraryViewModel.mappedPublications(
                    in: document, relativeTo: catalogRequestURL))
                XCTAssertEqual(books.map(\.title), ["Alias book"])
                XCTAssertEqual(books.first?.downloadURL?.absoluteString,
                    "https://cdn.example/releases/books/alias.epub")
            }
        }
    }

    @MainActor
    func testOPDS2AliasSpellingsKeepGenericAcquisitionPriority() throws {
        for generic in ["acquisition", LinkRelation.opdsAcquisition.string] {
            for openAccess in ["download", LinkRelation.opdsAcquisitionOpenAccess.string] {
                let document = try catalogDocument("""
                {"metadata":{"title":"Feed"},"publications":[{"metadata":{"title":"Priority"},
                  "links":[{"href":"open.epub","rel":"\(openAccess)"},
                           {"href":"generic.epub","rel":"\(generic)"}]}]}
                """)
                let books = try XCTUnwrap(BookLibraryViewModel.mappedPublications(
                    in: document, relativeTo: catalogRequestURL))
                XCTAssertEqual(books.first?.downloadURL?.lastPathComponent, "generic.epub")
            }
        }
    }

    @MainActor
    func testOPDS2AliasNormalizationPreservesRestrictedCustomAndLookalikeRelations() throws {
        let relations = ["buy", "borrow", "preview", "subscribe", "download-preview", "download/preview",
                         "downloaded", "acquisition-extra", "acquisition/open-access", " download ",
                         "https://custom.example/download"]
        for relation in relations {
            let document = try catalogDocument("""
            {"metadata":{"title":"Not a direct download"},"links":[{"href":"not-full.epub",
             "rel":["alternate","\(relation)"]}]}
            """)
            let parsedRelations = try XCTUnwrap(document.publication?.links.first?.rels)
            XCTAssertEqual(parsedRelations, [.alternate, LinkRelation(relation)], relation)
            let books = try XCTUnwrap(BookLibraryViewModel.mappedPublications(
                in: document, relativeTo: catalogRequestURL))
            XCTAssertNil(books.first?.downloadURL, relation)
        }
    }

    @MainActor
    func testShortAcquisitionAliasesDoNotChangeAtomOrDirectRelationConstruction() throws {
        for alias in ["acquisition", "download"] {
            let document = try catalogDocument("""
            <entry xmlns="http://www.w3.org/2005/Atom"><title>Custom Atom role</title>
              <link href="custom.epub" rel="\(alias)"/>
            </entry>
            """, atom: true)
            let link = try XCTUnwrap(document.publication?.links.first)
            XCTAssertEqual(link.rels, [LinkRelation(alias)])
            XCTAssertFalse(LinkRelation(alias).isOPDSAcquisition)
            let books = try XCTUnwrap(BookLibraryViewModel.mappedPublications(
                in: document, relativeTo: catalogRequestURL))
            XCTAssertNil(books.first?.downloadURL)
        }
    }

    @MainActor
    func testCatalogNavigationCyclesStopBeforeRepeatingARequest() async throws {
        for kind in ["self", "fragment", "two-documents"] {
            let fixture = catalogLoadingFixture()
            let first = fixture.url("first.json"), second = fixture.url("second.json")
            fixture.set(.document(catalogNavigation(kind == "two-documents" ? second :
                (kind == "fragment" ? first.appending(fragment: "another-position") : first))), at: first)
            if kind == "two-documents" {
                fixture.set(.document(catalogNavigation(first)), at: second)
            }
            let result = await BookLibraryViewModel.fetchPublications(from: first, session: fixture.session)
            XCTAssertTrue(result.0.isEmpty)
            XCTAssertNotNil(result.1)
            XCTAssertEqual(fixture.requests, kind == "two-documents" ? [first, second] : [first], kind)
        }
    }

    @MainActor
    func testCatalogQueriesRemainDistinctAndFiniteChainsHaveNoArbitraryLimit() async throws {
        let fixture = catalogLoadingFixture()
        let urls = (0..<20).map { fixture.url("catalog.json?cursor=\($0)") }
        for index in urls.indices {
            fixture.set(.document(index == urls.count - 1 ? catalogBook("Reached book") :
                catalogNavigation(urls[index + 1])), at: urls[index])
        }
        let result = await BookLibraryViewModel.fetchPublications(from: urls[0], session: fixture.session)
        XCTAssertEqual(result.0.map(\.title), ["Reached book"])
        XCTAssertEqual(result.0.first?.downloadURL?.lastPathComponent, "full.epub")
        XCTAssertNil(result.1)
        XCTAssertEqual(fixture.requests, urls)
    }

    @MainActor
    func testCatalogFinalResponseAliasesCannotReenterAnAlreadyLoadedDocument() async throws {
        let fixture = catalogLoadingFixture()
        let first = fixture.url("first.json"), alias = fixture.url("actual.json")
        let second = fixture.url("second.json"), unwanted = fixture.url("unwanted.json")
        fixture.set(.document(catalogNavigation(second), finalURL: alias), at: first)
        fixture.set(.document(catalogNavigation(unwanted), finalURL: alias), at: second)
        let result = await BookLibraryViewModel.fetchPublications(from: first, session: fixture.session)
        XCTAssertTrue(result.0.isEmpty)
        XCTAssertNotNil(result.1)
        XCTAssertEqual(fixture.requests, [first, second],
            "Controlled response metadata proves final-document identity, not actual HTTP redirect delivery")
    }

    @MainActor
    func testCancellingCatalogRefreshStopsItsNativeRequestAndAllowsSameURLRetry() async throws {
        let fixture = catalogLoadingFixture()
        let url = fixture.url("held.json")
        let started = expectation(description: "Native catalog request started")
        let stopped = expectation(description: "Native catalog request stopped")
        fixture.set(.held(started: started, stopped: stopped), at: url)
        let model = BookLibraryViewModel(opdsURL: url)
        model.publicationFetcher = { await BookLibraryViewModel.fetchPublications(from: $0, session: fixture.session) }
        let operation = Task { @MainActor in await model.fetchAllData() }
        fixture.operations.append(operation)
        await fulfillment(of: [started], timeout: 5)
        operation.cancel()
        let stoppedResult = await XCTWaiter.fulfillment(of: [stopped], timeout: 5)
        XCTAssertEqual(stoppedResult, .completed,
            "Cancellation must stop the native request before its transport timeout")
        guard stoppedResult == .completed else {
            fixture.session.invalidateAndCancel()
            await operation.value
            return
        }
        await operation.value
        XCTAssertEqual(fixture.requests, [url])
        XCTAssertTrue(model.editorsPicks.isEmpty)
        XCTAssertNil(model.errorMessage)

        fixture.set(.document(catalogBook("Retry book")), at: url)
        await model.fetchAllData()
        XCTAssertEqual(model.editorsPicks.map(\.title), ["Retry book"])
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(fixture.requests, [url, url])
    }

    @MainActor
    func testReleasingLibraryModelStopsAnActiveRetryNativeRequest() async throws {
        let fixture = catalogLoadingFixture()
        let url = fixture.url("owner-release.json")
        let started = expectation(description: "Retry native request started")
        let stopped = expectation(description: "Released owner's native request stopped")
        fixture.set(.held(started: started, stopped: stopped), at: url)
        var model: BookLibraryViewModel? = BookLibraryViewModel(opdsURL: url)
        weak var weakModel = model
        model?.publicationFetcher = {
            await BookLibraryViewModel.fetchPublications(from: $0, session: fixture.session)
        }
        let operation = try XCTUnwrap(model?.fetchEditorsPicks())
        fixture.operations.append(operation)
        let startedResult = await XCTWaiter.fulfillment(of: [started], timeout: 5)
        XCTAssertEqual(startedResult, .completed)
        guard startedResult == .completed else {
            model = nil
            await fixture.close()
            return
        }
        XCTAssertEqual(fixture.requests, [url])
        model = nil
        XCTAssertNil(weakModel, "An active Retry must not retain its library model")
        let stoppedResult = await XCTWaiter.fulfillment(of: [stopped], timeout: 5)
        XCTAssertEqual(stoppedResult, .completed,
            "Model release must stop the native request before manual cleanup or its 15-second timeout")
        guard stoppedResult == .completed else {
            await fixture.close()
            return
        }
        await operation.value
        XCTAssertEqual(fixture.requests, [url])
    }

    @MainActor
    func testCancelledCatalogEntrantNeverStartsARequest() async {
        let fixture = catalogLoadingFixture()
        let operation = Task { @MainActor in
            let result = await BookLibraryViewModel.fetchPublications(
                from: fixture.url("unused.json"), session: fixture.session)
            XCTAssertTrue(result.0.isEmpty)
            XCTAssertNil(result.1)
        }
        fixture.operations.append(operation)
        operation.cancel()
        await operation.value
        XCTAssertTrue(fixture.requests.isEmpty)
    }

    @MainActor
    func testAsyncCatalogParserRetainsHTTPAndPartialDocumentAdmission() async throws {
        let fixture = catalogLoadingFixture()
        for status in [503, 206] {
            let url = fixture.url("status-\(status).json")
            fixture.set(.document(catalogBook("Must not be admitted"), status: status), at: url)
            do {
                _ = try await OPDSParser.parseURL(url: url, session: fixture.session)
                XCTFail("A complete-looking body cannot waive HTTP status \(status)")
            } catch OPDSParserError.httpStatus(let actual) {
                XCTAssertEqual(actual, status)
                XCTAssertEqual(status, 503)
            } catch OPDSParserError.partialDocument {
                XCTAssertEqual(status, 206)
            }
        }
    }

    @MainActor
    private func catalogLoadingFixture() -> BookCatalogLoadingFixture {
        let fixture = BookCatalogLoadingFixture()
        addTeardownBlock { @MainActor in await fixture.close() }
        return fixture
    }

    private func catalogNavigation(_ target: URL) -> String {
        "{\"metadata\":{\"title\":\"Catalog\"},\"navigation\":[{\"title\":\"All Books\",\"href\":\"\(target.absoluteString)\"}]}"
    }

    private func catalogBook(_ title: String) -> String {
        "{\"metadata\":{\"title\":\"\(title)\"},\"links\":[{\"href\":\"full.epub\",\"rel\":\"http://opds-spec.org/acquisition/open-access\"}]}"
    }

    @MainActor
    func testStandaloneJSONCatalogEntryKeepsOpenAccessDownloadAndMetadata() throws {
        let document = try catalogDocument(#"""
        {"metadata":{"title":"Standalone","author":["First","Second"],
          "published":"2020-01-02","description":"Summary","subtitle":"Fallback"},
         "links":[{"href":"../books/full.epub?edition=1%202#start",
                   "rel":"http://opds-spec.org/acquisition/open-access"}],
         "images":[{"href":"images/front.png","rel":"http://opds-spec.org/image"}]}
        """#)
        XCTAssertNotNil(document.publication, "Exercise the selected parser's standalone route")
        let books = try XCTUnwrap(BookLibraryViewModel.mappedPublications(
            in: document, relativeTo: catalogRequestURL))
        let book = try XCTUnwrap(books.first)
        XCTAssertEqual(books.count, 1)
        XCTAssertEqual(book.title, "Standalone")
        XCTAssertEqual(book.author, "First, Second")
        XCTAssertEqual(book.summary, "Summary")
        XCTAssertEqual(book.publicationDate?.timeIntervalSince1970, 1_577_923_200)
        XCTAssertEqual(book.coverURL?.absoluteString, "https://cdn.example/releases/v2/images/front.png")
        XCTAssertEqual(book.downloadURL?.absoluteString,
            "https://cdn.example/releases/books/full.epub?edition=1%202#start")
    }

    @MainActor
    func testStandaloneAtomCatalogEntryKeepsItsScopedBaseAndOpenAccessDownload() throws {
        let document = try catalogDocument("""
        <entry xmlns="http://www.w3.org/2005/Atom" xml:base="../books/">
          <title>Atom book</title><author><name>Writer</name></author>
          <summary>Atom summary</summary>
          <link href="cover.png" rel="cover"/>
          <link xml:base="files/" href="full.epub" rel="http://opds-spec.org/acquisition/open-access"/>
        </entry>
        """, atom: true)
        XCTAssertNotNil(document.publication)
        let books = try XCTUnwrap(BookLibraryViewModel.mappedPublications(
            in: document, relativeTo: catalogRequestURL))
        XCTAssertEqual(books.map(\.title), ["Atom book"])
        XCTAssertEqual(books.first?.summary, "Atom summary")
        XCTAssertEqual(books.first?.coverURL?.absoluteString, "https://cdn.example/releases/books/cover.png")
        XCTAssertEqual(books.first?.downloadURL?.absoluteString,
            "https://cdn.example/releases/books/files/full.epub")
    }

    @MainActor
    func testCatalogFeedKeepsGenericAcquisitionCoverAndPublicationOrder() throws {
        let document = try catalogDocument(#"""
        {"metadata":{"title":"Catalog"},"publications":[
          {"metadata":{"title":"First"},"links":[
            {"href":"open.epub","rel":"http://opds-spec.org/acquisition/open-access"},
            {"href":"generic.epub","rel":"http://opds-spec.org/acquisition"}],
           "images":[{"href":"thumb.png","rel":"http://opds-spec.org/image/thumbnail"},
                     {"href":"image.png","rel":"http://opds-spec.org/image"},
                     {"href":"cover.png","rel":"cover"}]},
          {"metadata":{"title":"Second"},"links":[
            {"href":"purchase","rel":"http://opds-spec.org/acquisition/buy"},
            {"href":"full.epub","rel":["alternate","http://opds-spec.org/acquisition/open-access"]}]}]}
        """#)
        XCTAssertEqual(document.feed?.publications.count, 2)
        let books = try XCTUnwrap(BookLibraryViewModel.mappedPublications(
            in: document, relativeTo: catalogRequestURL))
        XCTAssertEqual(books.map(\.title), ["First", "Second"])
        XCTAssertEqual(books[0].downloadURL?.lastPathComponent, "generic.epub")
        XCTAssertEqual(books[0].coverURL?.lastPathComponent, "cover.png")
        XCTAssertEqual(books[1].downloadURL?.lastPathComponent, "full.epub")
    }

    @MainActor
    func testRestrictedCatalogEntriesNeverBecomeFullBookDownloads() throws {
        for relation in ["buy", "borrow", "sample", "subscribe", "open-access-preview", "open-access/preview"] {
            let document = try catalogDocument("""
            {"metadata":{"title":"Restricted"},"links":[{"href":"restricted.epub",
             "rel":"http://opds-spec.org/acquisition/\(relation)"}]}
            """)
            let books = try XCTUnwrap(BookLibraryViewModel.mappedPublications(
                in: document, relativeTo: catalogRequestURL))
            XCTAssertEqual(books.map(\.title), ["Restricted"])
            XCTAssertNil(books.first?.downloadURL, relation)
        }
    }

    @MainActor
    func testNavigationAndEmptyCatalogsRemainWithExistingLoader() throws {
        for body in [
            #"{"metadata":{"title":"Navigation"},"navigation":[{"href":"all.json","title":"All Books"}]}"#,
            #"{"metadata":{"title":"Empty"},"publications":[]}"#,
        ] {
            let document = try catalogDocument(body)
            XCTAssertNil(BookLibraryViewModel.mappedPublications(in: document, relativeTo: catalogRequestURL))
        }
    }

    private var catalogRequestURL: URL { URL(string: "https://requested.example/catalog/index.json")! }

    private func catalogDocument(_ body: String, atom: Bool = false) throws -> ParseData {
        // Supply actual response metadata to the shipping parser. This proves
        // final-document/scoped URL resolution, not an HTTP redirect transport.
        let response = URLResponse(url: URL(string: "https://cdn.example/releases/v2/document.json")!,
            mimeType: nil, expectedContentLength: body.utf8.count, textEncodingName: "utf-8")
        if atom {
            return try OPDS1Parser.parse(xmlData: Data(body.utf8), url: catalogRequestURL, response: response)
        }
        return try OPDS2Parser.parse(jsonData: Data(body.utf8), url: catalogRequestURL, response: response)
    }

    @MainActor
    func testProductionOpenPipelineRejectsCancellationIgnoringOlderSelection()
    async throws {
        let viewModel = BookLibraryViewModel()
        let gate = BookOpenSelectionGate()
        var events: [String] = []
        let older = try XCTUnwrap(viewModel.startOpenSelection { selection in
            do {
                try await viewModel.open(
                    selection: selection,
                    stages: .init(
                        resolveDownloadable: { true },
                        existsLocally: { true },
                        importContent: { _ in
                            await gate.suspendIgnoringCancellation()
                            events.append("older-import-complete")
                            return true
                        },
                        loadContent: {
                            events.append("older-load")
                            return true
                        },
                        navigate: { _ in events.append("older-navigate") },
                        publishNavigation: {
                            events.append("older-publish")
                        }
                    )
                )
            } catch {
                XCTFail("unexpected older open error: \(error)")
            }
        })
        await gate.waitUntilSuspended()

        let newer = try XCTUnwrap(viewModel.startOpenSelection { selection in
            do {
                try await viewModel.open(
                    selection: selection,
                    stages: .init(
                        resolveDownloadable: { true },
                        existsLocally: { true },
                        importContent: { _ in true },
                        loadContent: { true },
                        navigate: { claim in
                            XCTAssertTrue(claim.isCurrent())
                            events.append("newer-navigate")
                        },
                        publishNavigation: {
                            events.append("newer-publish")
                        }
                    )
                )
            } catch {
                XCTFail("unexpected newer open error: \(error)")
            }
        })
        await newer.value
        await gate.release()
        await older.value

        XCTAssertEqual(
            events,
            [
                "newer-navigate",
                "newer-publish",
                "older-import-complete",
            ]
        )
    }

    @MainActor
    func testCancelledEntrantDoesNotRevokeSuspendedHealthyProductionOpen()
    async throws {
        let viewModel = BookLibraryViewModel()
        let gate = BookOpenSelectionGate()
        var events: [String] = []
        let healthy = try XCTUnwrap(viewModel.startOpenSelection { selection in
            do {
                try await viewModel.open(
                    selection: selection,
                    stages: .init(
                        resolveDownloadable: { true },
                        existsLocally: { true },
                        importContent: { _ in
                            await gate.suspendIgnoringCancellation()
                            return true
                        },
                        loadContent: { true },
                        navigate: { claim in
                            XCTAssertTrue(claim.isCurrent())
                            events.append("healthy-navigate")
                        },
                        publishNavigation: {
                            events.append("healthy-publish")
                        }
                    )
                )
            } catch {
                XCTFail("unexpected healthy open error: \(error)")
            }
        })
        await gate.waitUntilSuspended()

        let cancelled = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return viewModel.startOpenSelection { _ in
                events.append("cancelled")
            }
        }
        let cancelledResult = await cancelled.value
        XCTAssertNil(cancelledResult)
        XCTAssertTrue(events.isEmpty)

        await gate.release()
        await healthy.value

        XCTAssertEqual(events, ["healthy-navigate", "healthy-publish"])
    }

    @MainActor
    func testUnsupersededProductionOpenNavigatesAndPublishesExactlyOnce()
    async throws {
        let viewModel = BookLibraryViewModel()
        var events: [String] = []
        let task = try XCTUnwrap(viewModel.startOpenSelection { selection in
            do {
                try await viewModel.open(
                    selection: selection,
                    stages: .init(
                        resolveDownloadable: { true },
                        existsLocally: { false },
                        importContent: { existsLocally in
                            XCTAssertFalse(existsLocally)
                            return true
                        },
                        loadContent: { true },
                        navigate: { claim in
                            XCTAssertTrue(claim.isCurrent())
                            events.append("navigate")
                        },
                        publishNavigation: { events.append("publish") }
                    )
                )
            } catch {
                XCTFail("unexpected open error: \(error)")
            }
        })

        await task.value

        XCTAssertEqual(events, ["navigate", "publish"])
    }

    @MainActor
    func testDisappearanceRevokesSuspendedProductionOpen() async throws {
        let viewModel = BookLibraryViewModel()
        let gate = BookOpenSelectionGate()
        var events: [String] = []
        let task = try XCTUnwrap(viewModel.startOpenSelection { selection in
            do {
                try await viewModel.open(
                    selection: selection,
                    stages: .init(
                        resolveDownloadable: { true },
                        existsLocally: { true },
                        importContent: { _ in
                            await gate.suspendIgnoringCancellation()
                            return true
                        },
                        loadContent: { true },
                        navigate: { _ in events.append("navigate") },
                        publishNavigation: { events.append("publish") }
                    )
                )
            } catch {
                XCTFail("unexpected open error: \(error)")
            }
        })
        await gate.waitUntilSuspended()

        viewModel.cancelOpenSelection()
        await gate.release()
        await task.value

        XCTAssertTrue(events.isEmpty)
    }

    @MainActor
    func testDownloadedTopTapPipelineHonorsCancellationAfterSuspension()
    async throws {
        let gate = BookOpenSelectionGate()
        var events: [String] = []
        let task = Task { @MainActor in
            try await BookLibraryViewModel.openDownloaded(
                stages: .init(
                    resolveDownloadable: { true },
                    existsLocally: { true },
                    importContent: { _ in
                        await gate.suspendIgnoringCancellation()
                        return true
                    },
                    loadContent: {
                        events.append("load")
                        return true
                    },
                    navigate: { _ in events.append("navigate") },
                    publishNavigation: { events.append("publish") }
                )
            )
        }
        await gate.waitUntilSuspended()

        task.cancel()
        await gate.release()
        try await task.value

        XCTAssertTrue(events.isEmpty)
    }

    @MainActor
    func testDownloadedTopTapPipelinePublishesForCurrentOwner() async throws {
        var events: [String] = []
        try await BookLibraryViewModel.openDownloaded(
            stages: .init(
                resolveDownloadable: { true },
                existsLocally: { true },
                importContent: { existsLocally in
                    XCTAssertTrue(existsLocally)
                    return true
                },
                loadContent: { true },
                navigate: { claim in
                    XCTAssertTrue(claim.isCurrent())
                    events.append("navigate")
                },
                publishNavigation: { events.append("publish") }
            )
        )

        XCTAssertEqual(events, ["navigate", "publish"])
    }

    @MainActor
    func testSupersededOwnerCannotPublishAfterNavigatorReturns() async throws {
        let viewModel = BookLibraryViewModel()
        let gate = BookOpenSelectionGate()
        var events: [String] = []
        let older = try XCTUnwrap(viewModel.startOpenSelection { selection in
            do {
                try await viewModel.open(
                    selection: selection,
                    stages: .init(
                        resolveDownloadable: { true },
                        existsLocally: { true },
                        importContent: { _ in true },
                        loadContent: { true },
                        navigate: { claim in
                            XCTAssertTrue(claim.isCurrent())
                            events.append("older-navigator-admitted")
                            await gate.suspendIgnoringCancellation()
                            XCTAssertFalse(claim.isCurrent())
                            events.append("older-navigator-returned")
                        },
                        publishNavigation: {
                            events.append("older-publish")
                        }
                    )
                )
            } catch {
                XCTFail("unexpected older navigation error: \(error)")
            }
        })
        await gate.waitUntilSuspended()

        let newer = try XCTUnwrap(viewModel.startOpenSelection { selection in
            do {
                try await viewModel.open(
                    selection: selection,
                    stages: .init(
                        resolveDownloadable: { true },
                        existsLocally: { true },
                        importContent: { _ in true },
                        loadContent: { true },
                        navigate: { claim in
                            XCTAssertTrue(claim.isCurrent())
                            events.append("newer-navigate")
                        },
                        publishNavigation: {
                            events.append("newer-publish")
                        }
                    )
                )
            } catch {
                XCTFail("unexpected newer navigation error: \(error)")
            }
        })
        await newer.value
        await gate.release()
        await older.value

        XCTAssertEqual(
            events,
            [
                "older-navigator-admitted",
                "newer-navigate",
                "newer-publish",
                "older-navigator-returned",
            ]
        )
    }
}

@MainActor
private final class BookCatalogLoadingFixture {
    let identifier = UUID().uuidString
    let session: URLSession
    var operations: [Task<Void, Never>] = []

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BookCatalogLoadingProtocol.self]
        // Longer than the stopLoading assertion: an ordinary transport timeout
        // must not masquerade as propagation of the caller's cancellation.
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        session = URLSession(configuration: configuration)
    }

    func url(_ path: String) -> URL { URL(string: "https://catalog-loading.test/\(identifier)/\(path)")! }

    func set(_ reply: BookCatalogLoadingReplies.Reply, at url: URL) {
        BookCatalogLoadingProtocol.replies.set(reply, at: url)
    }

    var requests: [URL] { BookCatalogLoadingProtocol.replies.requests(for: identifier) }

    func close() async {
        operations.forEach { $0.cancel() }
        session.invalidateAndCancel()
        for operation in operations { await operation.value }
        BookCatalogLoadingProtocol.replies.remove(identifier: identifier)
    }
}

private final class BookCatalogLoadingReplies: @unchecked Sendable {
    enum Reply {
        case document(String, finalURL: URL? = nil, status: Int = 200)
        case held(started: XCTestExpectation, stopped: XCTestExpectation)
    }
    private let lock = NSLock()
    private var replies: [URL: Reply] = [:]
    private var recorded: [URL] = []

    func set(_ reply: Reply, at url: URL) {
        lock.lock()
        defer { lock.unlock() }
        replies[url] = reply
    }

    func take(at url: URL) -> Reply? {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(url)
        // Finite replies make a regressed cycle settle with an unexpected
        // request failure instead of spinning indefinitely in the test host.
        return replies.removeValue(forKey: url)
    }

    func requests(for identifier: String) -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        return recorded.filter { $0.pathComponents.contains(identifier) }
    }

    func remove(identifier: String) {
        lock.lock()
        defer { lock.unlock() }
        replies = replies.filter { !$0.key.pathComponents.contains(identifier) }
        recorded.removeAll { $0.pathComponents.contains(identifier) }
    }
}

private final class BookCatalogLoadingProtocol: URLProtocol {
    static let replies = BookCatalogLoadingReplies()
    private let lock = NSLock()
    private var stopped: XCTestExpectation?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let reply = Self.replies.take(at: url) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        switch reply {
        case let .held(started, stopped):
            lock.lock()
            self.stopped = stopped
            lock.unlock()
            started.fulfill()
        case let .document(body, finalURL, status):
            let response = HTTPURLResponse(url: finalURL ?? url, statusCode: status,
                httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        lock.lock()
        let expectation = stopped
        stopped = nil
        lock.unlock()
        expectation?.fulfill()
    }
}

private extension URL {
    func appending(fragment: String) -> URL {
        var components = URLComponents(url: self, resolvingAgainstBaseURL: true)!
        components.fragment = fragment
        return components.url!
    }
}
