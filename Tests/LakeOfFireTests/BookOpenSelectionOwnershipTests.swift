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
