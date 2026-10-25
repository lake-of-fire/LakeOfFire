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

    func testRouteRejectsAlreadyInvalidatedContentBeforeReadingManagedURL() async throws {
        let (realm, record) = try fixture()
        let manager = ReaderFileManager()
        try realm.write { realm.delete(record) }
        XCTAssertTrue(record.isInvalidated)

        do {
            let route = try await ReaderContentLoader.load(content: record, readerFileManager: manager)
            XCTFail("Invalidated content must not produce a navigation route: \(String(describing: route))")
        } catch is CancellationError {
            // The real route selector must reject before persisted URL access.
        } catch {
            XCTFail("Expected cancellation for invalidated content, received \(error)")
        }
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

    private func prepareSnippet(_ row: HistoryRecord, in realm: Realm, reader: ReaderContent) async throws {
        try realm.write {
            row.url = URL(string: "internal://local/snippet?key=render-rename")!
            row.title = "Original title"
            row.html = "<html><body><p>Original readable body.</p></body></html>"
            row.rssContainsFullContent = true
            row.isReaderModeByDefault = true
            row.isReaderModeAvailable = false
            row.isReaderModeOfferHidden = false
        }
        reader.content = nil
        reader.preloadResolvedContent(row, for: row.url)
        try await reader.load(url: row.url)
    }

    private func renameWithFreshWrapper(_ row: HistoryRecord, in realm: Realm, reader: ReaderContent) throws {
        try realm.write { row.title = "Renamed snippet" }
        let replacement = try XCTUnwrap(realm.object(ofType: HistoryRecord.self, forPrimaryKey: row.compoundKey))
        XCTAssertFalse(replacement === row, "The regression requires a fresh Swift wrapper")
        XCTAssertTrue(row.isSameObject(as: replacement))
        reader.content = replacement
        reader.refreshObservedContentState()
    }

    func testSameRowSnippetRenameDuringRouteReadStillDispatchesAndCompletes() async throws {
        try await assertSameRowSnippetRenameCompletes(duringProcessing: false)
    }

    func testSameRowSnippetRenameDuringProcessingStillDispatchesAndCompletes() async throws {
        try await assertSameRowSnippetRenameCompletes(duringProcessing: true)
    }

    func testSameRowSnippetRenameKeepsBothLocalHTMLRoutesAvailable() async throws {
        for readerByDefault in [false, true] {
            let (realm, row, reader, mode, _) = try renderFixture()
            defer {
                mode.readerLocalHTMLLoader = nil
                withExtendedLifetime(realm) {}
            }
            try await prepareSnippet(row, in: realm, reader: reader)
            try realm.write { row.isReaderModeByDefault = readerByDefault }
            let selectionID = try XCTUnwrap(reader.currentSelectionID)
            var reads = 0
            mode.readerLocalHTMLLoader = { content in
                reads += 1
                XCTAssertTrue(content === row)
                await Task.yield()
                try self.renameWithFreshWrapper(row, in: realm, reader: reader)
                return content.html
            }
            let route = await mode.readerModeRouteForTesting(readerContent: reader)
            XCTAssertEqual(route, "swiftFinalLoad", "readerByDefault=\(readerByDefault)")
            XCTAssertEqual(reads, 1, "The route must retain its captured local HTML")
            XCTAssertEqual(reader.currentSelectionID, selectionID)
            XCTAssertEqual(reader.content?.title, "Renamed snippet")
        }
    }

    private func assertSameRowSnippetRenameCompletes(duringProcessing: Bool) async throws {
        let (realm, row, reader, mode, navigator) = try renderFixture()
        defer {
            mode.readerLocalHTMLLoader = nil
            mode.swiftReadabilityProcessor = nil
            withExtendedLifetime(realm) {}
        }
        try await prepareSnippet(row, in: realm, reader: reader)
        let url = row.url
        let selectionID = try XCTUnwrap(reader.currentSelectionID)
        var renamed = false
        var reads = 0
        var processingCalls = 0
        let processedHTML = "<html><body><div id='reader-content'>Processed snippet.</div></body></html>"
        mode.readerLocalHTMLLoader = { content in
            reads += 1
            XCTAssertTrue(content === row, "Routing must use its captured row")
            await Task.yield()
            if !duringProcessing {
                try self.renameWithFreshWrapper(row, in: realm, reader: reader)
                renamed = true
            }
            return content.html
        }
        mode.swiftReadabilityProcessor = { _, _, _, _ in
            processingCalls += 1
            await Task.yield()
            if duringProcessing {
                do {
                    try self.renameWithFreshWrapper(row, in: realm, reader: reader)
                } catch {
                    XCTFail("Could not replace the snippet wrapper: \(error)")
                    return nil
                }
                renamed = true
            }
            return processedHTML
        }
        await render(mode, reader: reader)
        XCTAssertTrue(renamed)
        XCTAssertEqual(reads, 1, "Same-row wrapper replacement must not reread HTML")
        XCTAssertEqual(processingCalls, 1)
        XCTAssertEqual(reader.currentSelectionID, selectionID)
        XCTAssertEqual(reader.content?.title, "Renamed snippet")
        XCTAssertEqual(mode.readabilityContent, processedHTML)
        XCTAssertEqual(navigator.debugLoadSnapshot.lastDataLoadBaseURL, url.absoluteString)
        XCTAssertTrue(mode.isReaderModeLoading, "Dispatch awaits the normal document-ready signal")
        XCTAssertEqual(mode.pendingReaderModeURL, url)
        // Model the ready signal only after proving the renderer dispatched.
        mode.markReaderModeLoadComplete(for: url)
        XCTAssertFalse(mode.isReaderModeLoading)
        XCTAssertNil(mode.pendingReaderModeURL)
    }

    private enum RetiredSnippetOwner: CaseIterable, Equatable {
        case differentRow, differentStore, recreatedRow, newSelection, newGeneration, cancelledGeneration, changedURL
    }

    func testSnippetWrapperReplacementDoesNotTransferRetiredRenderOwnership() async throws {
        for duringProcessing in [false, true] {
            for retirement in RetiredSnippetOwner.allCases {
                let (realm, row, reader, mode, navigator) = try renderFixture()
                defer {
                    mode.readerLocalHTMLLoader = nil
                    mode.swiftReadabilityProcessor = nil
                }
                try await prepareSnippet(row, in: realm, reader: reader)
                let url = row.url
                var retainedStore: Realm?
                var retired = false
                let successorHTML = "<html><body><div id='reader-content'>Successor capture</div></body></html>"
                let retire = { @MainActor in
                    await Task.yield()
                    let replacement: HistoryRecord
                    switch retirement {
                    case .differentRow:
                        replacement = HistoryRecord(value: row)
                        replacement.compoundKey += "-different-row"
                        try realm.write { realm.add(replacement) }
                    case .differentStore:
                        let other = try await Realm(configuration: Realm.Configuration(
                            inMemoryIdentifier: UUID().uuidString, objectTypes: [HistoryRecord.self]
                        ))
                        replacement = HistoryRecord(value: row)
                        try other.write { other.add(replacement) }
                        retainedStore = other
                    case .recreatedRow:
                        replacement = HistoryRecord(value: row)
                        try realm.write { realm.delete(row); realm.add(replacement) }
                        XCTAssertTrue(row.isInvalidated)
                    case .newSelection, .newGeneration, .cancelledGeneration, .changedURL:
                        replacement = try XCTUnwrap(realm.object(ofType: HistoryRecord.self, forPrimaryKey: row.compoundKey))
                        XCTAssertFalse(replacement === row)
                        XCTAssertTrue(row.isSameObject(as: replacement))
                    }
                    if retirement == .differentRow || retirement == .differentStore {
                        XCTAssertEqual(row.url, replacement.url)
                        XCTAssertFalse(row.isSameObject(as: replacement))
                    }
                    if retirement == .differentStore {
                        XCTAssertEqual(row.compoundKey, replacement.compoundKey)
                    }
                    if retirement == .newSelection {
                        let priorSelection = reader.currentSelectionID
                        reader.content = nil
                        reader.preloadResolvedContent(replacement, for: url)
                        try await reader.load(url: url)
                        XCTAssertNotEqual(reader.currentSelectionID, priorSelection)
                    } else {
                        reader.content = replacement
                    }
                    if retirement == .cancelledGeneration || retirement == .newGeneration {
                        mode.cancelReaderModeLoad(for: url)
                    }
                    if retirement == .changedURL {
                        try realm.write { row.url = URL(string: "internal://local/snippet?key=successor")! }
                        reader.pageURL = row.url
                    }
                    mode.beginReaderModeLoad(for: reader.pageURL)
                    reader.isRenderingReaderHTML = true
                    mode.readabilityContent = successorHTML
                    navigator.load(URLRequest(url: reader.pageURL))
                    if retirement == .newGeneration {
                        // Let a real successor generation dispatch before the
                        // old suspended callback returns with obsolete output.
                        mode.readabilityContent = nil
                        mode.readerLocalHTMLLoader = { _ in
                            "<html><body><p>Successor readable body.</p></body></html>"
                        }
                        mode.swiftReadabilityProcessor = { _, _, _, _ in successorHTML }
                        mode.showReaderView(readerContent: reader, scriptCaller: WebViewScriptCaller())
                        await mode.waitForReaderModeRender(for: url)
                    }
                    retired = true
                }
                mode.readerLocalHTMLLoader = { _ in
                    if !duringProcessing { try await retire() }
                    return "<html><body><p>Original readable body.</p></body></html>"
                }
                mode.swiftReadabilityProcessor = { _, _, _, _ in
                    if duringProcessing {
                        do {
                            try await retire()
                        } catch {
                            XCTFail("Could not retire the render owner: \(error)")
                            return nil
                        }
                    }
                    return "Retired processing output"
                }
                await render(mode, reader: reader)
                XCTAssertTrue(retired, "Suspension seam was not reached: \(retirement)")
                XCTAssertEqual(mode.readabilityContent, successorHTML, "\(retirement)")
                XCTAssertTrue(mode.isReaderModeLoading, "\(retirement)")
                XCTAssertTrue(reader.isRenderingReaderHTML, "\(retirement)")
                XCTAssertEqual(mode.pendingReaderModeURL, reader.pageURL, "\(retirement)")
                XCTAssertEqual(navigator.debugLoadSnapshot.lastRequestURL,
                               retirement == .newGeneration ? "nil" : reader.pageURL.absoluteString)
                XCTAssertEqual(navigator.debugLoadSnapshot.lastDataLoadBaseURL,
                               retirement == .newGeneration ? url.absoluteString : "nil")
                XCTAssertEqual(navigator.debugLoadSnapshot.lastHTMLBaseURL, "nil")
                withExtendedLifetime((realm, retainedStore)) {}
            }
        }
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

    func testSameURLReplacementDuringHTMLReadDoesNotResolveOrCleanUpSuccessor() async throws {
        let (realm, row, reader, mode, navigator) = try renderFixture()
        defer { withExtendedLifetime(realm) {} }
        let successor = HistoryRecord()
        successor.url = fileURL
        var reads = 0
        mode.readerLocalHTMLLoader = { content in
            reads += 1
            XCTAssertTrue(content === row, "Old route must not start a read for its successor")
            await Task.yield()
            reader.content = successor
            mode.beginReaderModeLoad(for: self.fileURL)
            reader.isRenderingReaderHTML = true
            mode.readabilityContent = "Successor capture"
            return nil
        }
        await render(mode, reader: reader)
        XCTAssertEqual(reads, 1)
        XCTAssertFalse(row.isInvalidated)
        XCTAssertEqual(mode.readabilityContent, "Successor capture")
        XCTAssertTrue(mode.isReaderModeLoading)
        XCTAssertTrue(reader.isRenderingReaderHTML)
        XCTAssertEqual(mode.pendingReaderModeURL, fileURL)
        XCTAssertEqual(navigator.debugLoadSnapshot.lastDataLoadBaseURL, "nil")
    }

    func testSameURLReplacementDuringProcessingDoesNotPublishOrCleanUpSuccessor() async throws {
        let (realm, row, reader, mode, navigator) = try renderFixture()
        defer { withExtendedLifetime(realm) {} }
        let successor = HistoryRecord()
        successor.url = fileURL
        mode.swiftReadabilityProcessor = { _, _, _, _ in
            await Task.yield()
            reader.content = successor
            mode.beginReaderModeLoad(for: self.fileURL)
            reader.isRenderingReaderHTML = true
            mode.readabilityContent = "Successor capture"
            return "Retired processing output"
        }
        await render(mode, reader: reader)
        XCTAssertFalse(row.isInvalidated)
        XCTAssertEqual(mode.readabilityContent, "Successor capture")
        XCTAssertTrue(mode.isReaderModeLoading)
        XCTAssertTrue(reader.isRenderingReaderHTML)
        XCTAssertEqual(navigator.debugLoadSnapshot.lastDataLoadBaseURL, "nil")
    }

    // Begin with reader metadata already persisted so these fixtures reach the
    // final transform without requiring an unrelated synchronized metadata write.
    private func prepareFinalTransformMetadata(_ row: HistoryRecord, in realm: Realm) throws {
        try realm.write {
            row.isReaderModeByDefault = true
            row.isReaderModeAvailable = false
            row.isReaderModeOfferHidden = false
            row.rssContainsFullContent = true
        }
    }

    func testFinalHTMLTransformRejectsPhysicallyInvalidatedContent() async throws {
        let (realm, row, reader, mode, navigator) = try renderFixture()
        try prepareFinalTransformMetadata(row, in: realm)
        mode.swiftReadabilityProcessor = { _, _, _, _ in
            "<html><body><div id='reader-content'>Readable body.</div></body></html>"
        }
        var transformed = false
        mode.processHTMLBytes = { bytes, _ in
            await MainActor.run {
                transformed = true
                try! realm.write { realm.delete(row) }
            }
            return bytes
        }

        await render(mode, reader: reader)

        XCTAssertTrue(transformed, "The regression must reach the final transform")
        XCTAssertTrue(row.isInvalidated)
        XCTAssertEqual(navigator.debugLoadSnapshot.lastDataLoadBaseURL, "nil")
        XCTAssertEqual(navigator.debugLoadSnapshot.lastHTMLBaseURL, "nil")
    }

    func testFinalHTMLTransformDoesNotDispatchOrCleanUpSameURLSuccessor() async throws {
        let (realm, row, reader, mode, navigator) = try renderFixture()
        try prepareFinalTransformMetadata(row, in: realm)
        defer { withExtendedLifetime(realm) {} }
        let successor = HistoryRecord()
        successor.url = fileURL
        mode.swiftReadabilityProcessor = { _, _, _, _ in
            "<html><body><div id='reader-content'>Original body.</div></body></html>"
        }
        var transformed = false
        mode.processHTML = { html, _ in
            await MainActor.run {
                transformed = true
                reader.content = successor
                reader.isRenderingReaderHTML = true
                mode.beginReaderModeLoad(for: self.fileURL)
                mode.readabilityContent = "Successor capture"
            }
            return html
        }

        await render(mode, reader: reader)

        XCTAssertTrue(transformed)
        XCTAssertFalse(row.isInvalidated)
        XCTAssertEqual(navigator.debugLoadSnapshot.lastDataLoadBaseURL, "nil")
        XCTAssertEqual(mode.readabilityContent, "Successor capture")
        XCTAssertTrue(reader.isRenderingReaderHTML)
        XCTAssertTrue(mode.isReaderModeLoading)
        XCTAssertEqual(mode.pendingReaderModeURL, fileURL)
    }

    func testFinalHTMLTransformAllowsFreshWrapperForSameLiveSnippet() async throws {
        let (realm, row, reader, mode, navigator) = try renderFixture()
        try await prepareSnippet(row, in: realm, reader: reader)
        let url = row.url
        mode.swiftReadabilityProcessor = { _, _, _, _ in
            "<html><body><div id='reader-content'>Snippet body.</div></body></html>"
        }
        var transformed = false
        mode.processHTMLBytes = { bytes, _ in
            await MainActor.run {
                transformed = true
                try! self.renameWithFreshWrapper(row, in: realm, reader: reader)
            }
            return bytes
        }

        await render(mode, reader: reader)

        XCTAssertTrue(transformed)
        XCTAssertEqual(reader.content?.title, "Renamed snippet")
        XCTAssertEqual(navigator.debugLoadSnapshot.lastDataLoadBaseURL, url.absoluteString)
        XCTAssertTrue(mode.isReaderModeLoading, "Normal document readiness still owns completion")
        XCTAssertEqual(mode.pendingReaderModeURL, url)
    }
    func testCapturedReadabilityCannotAdoptSameURLSelectionDuringPublicationDate() async throws {
        for recreatesRow in [false, true] {
            let (realm, row, reader, mode, navigator) = try renderFixture()
            defer {
                mode.readerPublicationDateLoader = nil
                withExtendedLifetime(realm) {}
            }
            try prepareFinalTransformMetadata(row, in: realm)
            // Use the captured-readability route: reader mode is already the
            // stored default, so it is considered before the local-file fallback.
            reader.content = nil
            reader.preloadResolvedContent(row, for: fileURL)
            try await reader.load(url: fileURL)
            let originalSelection = try XCTUnwrap(reader.currentSelectionID)
            let originalFence = reader.makeSelectionCommitFence(requiring: originalSelection)
            let capturedHTML = "<html><body><div id='reader-content'>Retired captured article.</div></body></html>"
            let successorHTML = "Successor capture"
            mode.readabilityContent = capturedHTML
            var dateLookups = 0
            var successor: HistoryRecord?
            mode.readerPublicationDateLoader = { url in
                dateLookups += 1
                XCTAssertEqual(url, self.fileURL)
                await Task.yield()
                do {
                    let replacement: HistoryRecord
                    if recreatesRow {
                        replacement = HistoryRecord(value: row)
                        try realm.write {
                            realm.delete(row)
                            realm.add(replacement)
                        }
                        XCTAssertTrue(row.isInvalidated)
                    } else {
                        replacement = try XCTUnwrap(realm.object(
                            ofType: HistoryRecord.self, forPrimaryKey: row.compoundKey
                        ))
                        XCTAssertTrue(row.isSameObject(as: replacement))
                    }
                    reader.content = nil
                    reader.preloadResolvedContent(replacement, for: self.fileURL)
                    try await reader.load(url: self.fileURL)
                    successor = replacement
                    XCTAssertNotEqual(reader.currentSelectionID, originalSelection)
                    XCTAssertFalse(originalFence())
                    // The selection changes without starting another render:
                    // the obsolete job's URL generation is deliberately intact.
                    mode.beginReaderModeLoad(for: self.fileURL)
                    reader.isRenderingReaderHTML = true
                    mode.readabilityContent = successorHTML
                    navigator.load(URLRequest(url: self.fileURL))
                } catch {
                    XCTFail("Could not replace the captured reader selection: \(error)")
                }
                return nil
            }
            var processed = false
            mode.processHTMLBytes = { bytes, _ in
                await MainActor.run { processed = true }
                return bytes
            }
            await render(mode, reader: reader)

            XCTAssertEqual(dateLookups, 1, "The captured route must reach its publication-date await")
            XCTAssertNotNil(successor)
            XCTAssertFalse(processed, "Retired captured HTML must not enter the successor's processing pipeline")
            XCTAssertEqual(mode.readabilityContent, successorHTML)
            XCTAssertTrue(mode.isReaderModeLoading)
            XCTAssertTrue(reader.isRenderingReaderHTML)
            XCTAssertEqual(mode.pendingReaderModeURL, fileURL)
            XCTAssertEqual(navigator.debugLoadSnapshot.lastRequestURL, fileURL.absoluteString)
            XCTAssertEqual(navigator.debugLoadSnapshot.lastDataLoadBaseURL, "nil")
            XCTAssertEqual(navigator.debugLoadSnapshot.lastHTMLBaseURL, "nil")
        }
    }

    func testCapturedReadabilityRejectsDifferentRowWithoutSelectionChange() async throws {
        let (realm, row, reader, mode, navigator) = try renderFixture()
        defer {
            mode.readerPublicationDateLoader = nil
            withExtendedLifetime(realm) {}
        }
        try prepareFinalTransformMetadata(row, in: realm)
        mode.readabilityContent = "<html><body><div id='reader-content'>Retired capture.</div></body></html>"
        let originalSelection = reader.currentSelectionID
        let replacement = HistoryRecord(value: row)
        replacement.compoundKey += "-replacement"
        try realm.write { realm.add(replacement) }
        var dateLookups = 0
        mode.readerPublicationDateLoader = { _ in
            dateLookups += 1
            await Task.yield()
            reader.content = replacement
            mode.beginReaderModeLoad(for: self.fileURL)
            reader.isRenderingReaderHTML = true
            mode.readabilityContent = "Successor capture"
            return nil
        }
        await render(mode, reader: reader)

        XCTAssertEqual(dateLookups, 1)
        XCTAssertEqual(reader.currentSelectionID, originalSelection)
        XCTAssertFalse(row.isSameObject(as: replacement))
        XCTAssertEqual(mode.readabilityContent, "Successor capture")
        XCTAssertTrue(mode.isReaderModeLoading)
        XCTAssertTrue(reader.isRenderingReaderHTML)
        XCTAssertEqual(navigator.debugLoadSnapshot.lastDataLoadBaseURL, "nil")
        XCTAssertEqual(navigator.debugLoadSnapshot.lastHTMLBaseURL, "nil")
    }

    func testCapturedReadabilityAllowsFreshWrapperForSameLiveRow() async throws {
        let (realm, row, reader, mode, navigator) = try renderFixture()
        defer {
            mode.readerPublicationDateLoader = nil
            withExtendedLifetime(realm) {}
        }
        try prepareFinalTransformMetadata(row, in: realm)
        mode.readabilityContent = "<html><body><div id='reader-content'>Current captured article.</div></body></html>"
        let originalSelection = reader.currentSelectionID
        var dateLookups = 0
        mode.readerPublicationDateLoader = { _ in
            dateLookups += 1
            await Task.yield()
            do {
                try self.renameWithFreshWrapper(row, in: realm, reader: reader)
            } catch {
                XCTFail("Could not rename the current content: \(error)")
            }
            return nil
        }
        await render(mode, reader: reader)

        XCTAssertEqual(dateLookups, 1)
        XCTAssertEqual(reader.currentSelectionID, originalSelection)
        XCTAssertEqual(reader.content?.title, "Renamed snippet")
        XCTAssertEqual(navigator.debugLoadSnapshot.lastDataLoadBaseURL, fileURL.absoluteString)
        XCTAssertTrue(mode.isReaderModeLoading, "The admitted render still waits for normal document readiness")
        XCTAssertEqual(mode.pendingReaderModeURL, fileURL)
    }

}
