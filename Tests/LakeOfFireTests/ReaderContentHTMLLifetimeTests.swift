import Foundation
import RealmSwift
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireReader
@testable import SwiftUIWebView

@MainActor
final class ReaderContentHTMLLifetimeTests: XCTestCase {
    private let fileURL = URL(string: "reader-file://file/load/local/example.txt")!

    private func fixture() throws -> (Realm, HistoryRecord) {
        let realm = try Realm(configuration: Realm.Configuration(
            inMemoryIdentifier: UUID().uuidString, objectTypes: [HistoryRecord.self]
        ))
        let record = HistoryRecord()
        record.url = fileURL
        record.rssContainsFullContent = false
        record.isFromClipboard = false
        record.updateCompoundKey()
        try realm.write { realm.add(record) }
        return (realm, record)
    }

    func testAlreadyInvalidatedRowDoesNotStartIO() async throws {
        let (realm, record) = try fixture()
        try realm.write { realm.delete(record) }
        let result = try await record.htmlToDisplay(
            readFile: { _ in XCTFail("Invalid row started I/O"); return nil },
            resolveMIMEType: { _ in XCTFail("Invalid row loaded metadata"); return nil }
        )
        XCTAssertNil(result)
    }

    func testDeletionDuringReadStopsBeforeMetadata() async throws {
        let (realm, record) = try fixture()
        let result = try await record.htmlToDisplay(
            readFile: { url in
                XCTAssertEqual(url, self.fileURL)
                await Task.yield()
                try realm.write { realm.delete(record) }
                return Data("Original text".utf8)
            },
            resolveMIMEType: { _ in XCTFail("Retired row loaded metadata"); return nil }
        )
        XCTAssertTrue(record.isInvalidated)
        XCTAssertNil(result)
    }

    func testDeletionDuringMetadataDoesNotPublishHTML() async throws {
        let (realm, record) = try fixture()
        let result = try await record.htmlToDisplay(
            readFile: { _ in Data("Original text".utf8) },
            resolveMIMEType: { url in
                XCTAssertEqual(url, self.fileURL)
                await Task.yield()
                try realm.write { realm.delete(record) }
                return "text/plain"
            }
        )
        XCTAssertTrue(record.isInvalidated)
        XCTAssertNil(result)
    }

    func testURLReplacementDuringReadDoesNotLoadSuccessorMetadata() async throws {
        let (realm, record) = try fixture()
        let result = try await record.htmlToDisplay(
            readFile: { _ in
                await Task.yield()
                try realm.write { record.url = URL(string: "reader-file://file/load/local/new.html")! }
                return Data("Original text".utf8)
            },
            resolveMIMEType: { _ in XCTFail("Changed URL loaded metadata"); return nil }
        )
        XCTAssertNil(result)
    }

    func testURLReplacementDuringMetadataDoesNotPublishOriginalBytes() async throws {
        let (realm, record) = try fixture()
        let result = try await record.htmlToDisplay(
            readFile: { _ in Data("Original text".utf8) },
            resolveMIMEType: { _ in
                await Task.yield()
                try realm.write { record.url = URL(string: "reader-file://file/load/local/new.txt")! }
                return "text/plain"
            }
        )
        XCTAssertNil(result)
    }

    func testValidFileAndMissingMIMENormalizeCapturedURL() async throws {
        let (realm, record) = try fixture()
        defer { withExtendedLifetime(realm) {} }
        for mimeType in ["text/plain", nil] as [String?] {
            let result = try await record.htmlToDisplay(
                readFile: { url in
                    XCTAssertEqual(url, self.fileURL)
                    return Data("Readable Japanese text".utf8)
                },
                resolveMIMEType: { url in
                    XCTAssertEqual(url, self.fileURL)
                    return mimeType
                }
            )
            XCTAssertTrue(try XCTUnwrap(result).contains("Readable Japanese text"))
        }
    }

    func testInlineHTMLDoesNotStartFileIO() async throws {
        let (realm, record) = try fixture()
        try realm.write {
            record.rssContainsFullContent = true
            record.html = "<p>Inline content</p>"
        }
        let result = try await record.htmlToDisplay(
            readFile: { _ in XCTFail("Inline content read a file"); return nil },
            resolveMIMEType: { _ in XCTFail("Inline content loaded metadata"); return nil }
        )
        XCTAssertEqual(result, "<p>Inline content</p>")
    }
}

// Physical invalidation is deliberately controlled here. Ordinary application
// deletion retains a synchronized tombstone and does not establish this race.
extension ReaderContentHTMLLifetimeTests {
    private func renderFixture() throws -> (Realm, HistoryRecord, ReaderContent, ReaderModeViewModel, WebViewNavigator) {
        let (realm, row) = try fixture()
        let reader = ReaderContent()
        reader.pageURL = row.url
        reader.content = row
        let mode = ReaderModeViewModel()
        let navigator = WebViewNavigator()
        mode.navigator = navigator
        mode.readerLocalHTMLLoader = { _ in "<html><body><p>Original readable body.</p></body></html>" }
        mode.readerPublicationDateLoader = { _ in nil }
        return (realm, row, reader, mode, navigator)
    }

    private func render(_ mode: ReaderModeViewModel, reader: ReaderContent) async {
        let url = reader.pageURL
        mode.showReaderView(readerContent: reader, scriptCaller: WebViewScriptCaller())
        await mode.waitForReaderModeRender(for: url)
    }

    func testRouteRejectsRowPhysicallyInvalidatedDuringHTMLRead() async throws {
        let (realm, row, reader, mode, _) = try renderFixture()
        mode.readerLocalHTMLLoader = { content in
            try await content.htmlToDisplay(readFile: { _ in
                await Task.yield()
                try realm.write { realm.delete(row) }
                return Data("Retired file".utf8)
            }, resolveMIMEType: { _ in XCTFail("Retired row requested metadata"); return nil })
        }
        let route = await mode.readerModeRouteForTesting(readerContent: reader)
        XCTAssertTrue(row.isInvalidated)
        XCTAssertEqual(route, "unavailable")
        XCTAssertNil(mode.readabilityContent)
    }

    func testRouteRetainsValidSnippetFallbackWhenHTMLGetterReturnsNil() async throws {
        let (realm, row, reader, mode, _) = try renderFixture()
        let url = URL(string: "internal://local/snippet?key=caller-fallback")!
        try realm.write { row.url = url; row.html = "  <p>Retained snippet.</p>  " }
        reader.pageURL = url
        mode.readerLocalHTMLLoader = { _ in nil }
        let route = await mode.readerModeRouteForTesting(readerContent: reader)
        XCTAssertEqual(route, "swiftFinalLoad")
    }

    func testRouteRetainsMissingNonSnippetHTMLAsUnavailable() async throws {
        let (_, _, reader, mode, _) = try renderFixture()
        mode.readerLocalHTMLLoader = { _ in nil }
        let route = await mode.readerModeRouteForTesting(readerContent: reader)
        XCTAssertEqual(route, "unavailable")
    }

    func testRenderRejectsRowPhysicallyInvalidatedDuringPublicationDate() async throws {
        let (realm, row, reader, mode, navigator) = try renderFixture()
        mode.readerPublicationDateLoader = { _ in
            await Task.yield()
            try! realm.write { realm.delete(row) }
            return nil
        }
        mode.swiftReadabilityProcessor = { _, _, _, _ in
            XCTFail("Retired date lookup started processing")
            return nil
        }
        await render(mode, reader: reader)
        XCTAssertTrue(row.isInvalidated)
        XCTAssertNil(mode.readabilityContent)
        XCTAssertEqual(navigator.debugLoadSnapshot.lastDataLoadBaseURL, "nil")
        XCTAssertEqual(navigator.debugLoadSnapshot.lastHTMLBaseURL, "nil")
    }

    func testRenderRejectsSuccessfulProcessingAfterPhysicalInvalidation() async throws {
        let (realm, row, reader, mode, navigator) = try renderFixture()
        mode.swiftReadabilityProcessor = { _, _, _, _ in
            await Task.yield()
            try! realm.write { realm.delete(row) }
            return "<html><body><div id='reader-content'>Retired processing output.</div></body></html>"
        }
        await render(mode, reader: reader)
        XCTAssertTrue(row.isInvalidated)
        XCTAssertNil(mode.readabilityContent, "Retired processing must not publish its result")
        XCTAssertEqual(navigator.debugLoadSnapshot.lastDataLoadBaseURL, "nil")
        XCTAssertEqual(navigator.debugLoadSnapshot.lastHTMLBaseURL, "nil")
    }

    func testRenderRejectsDirectFallbackAfterPhysicalInvalidation() async throws {
        let (realm, row, reader, mode, navigator) = try renderFixture()
        mode.swiftReadabilityProcessor = { _, _, _, _ in
            await Task.yield()
            try! realm.write { realm.delete(row) }
            return nil
        }
        await render(mode, reader: reader)
        XCTAssertTrue(row.isInvalidated)
        XCTAssertNil(mode.readabilityContent)
        XCTAssertEqual(navigator.debugLoadSnapshot.lastDataLoadBaseURL, "nil")
        XCTAssertEqual(navigator.debugLoadSnapshot.lastHTMLBaseURL, "nil")
    }

    func testRetiredProcessingLeavesSuccessorLoadingAndNavigationAlone() async throws {
        let (realm, row, reader, mode, navigator) = try renderFixture()
        let successor = HistoryRecord()
        successor.url = URL(string: "https://example.com/successor")!
        let successorHTML = "Successor capture"
        mode.swiftReadabilityProcessor = { _, _, _, _ in
            await Task.yield()
            try! realm.write { realm.delete(row) }
            reader.pageURL = successor.url
            reader.content = successor
            reader.isRenderingReaderHTML = true
            mode.beginReaderModeLoad(for: successor.url)
            mode.readabilityContent = successorHTML
            navigator.load(URLRequest(url: successor.url))
            return "Retired processing output"
        }
        await render(mode, reader: reader)
        XCTAssertEqual(mode.readabilityContent, successorHTML)
        XCTAssertTrue(mode.isReaderModeLoading)
        XCTAssertTrue(reader.isRenderingReaderHTML)
        XCTAssertEqual(mode.pendingReaderModeURL, successor.url)
        XCTAssertEqual(navigator.debugLoadSnapshot.lastRequestURL, successor.url.absoluteString)
        XCTAssertEqual(navigator.debugLoadSnapshot.lastDataLoadBaseURL, "nil")
    }

    func testCurrentProcessingFailureStillLoadsDirectHTML() async throws {
        let (realm, row, reader, mode, navigator) = try renderFixture()
        defer { withExtendedLifetime(realm) {} }
        mode.swiftReadabilityProcessor = { _, url, _, _ in
            XCTAssertEqual(url, self.fileURL)
            return nil
        }
        await render(mode, reader: reader)
        XCTAssertFalse(row.isInvalidated)
        XCTAssertEqual(navigator.debugLoadSnapshot.lastDataLoadBaseURL, fileURL.absoluteString)
    }
}
