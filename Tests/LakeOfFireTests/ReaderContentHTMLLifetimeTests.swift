import Foundation
import Combine
import RealmSwift
@testable import SwiftUIWebView
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireReader

@MainActor
private final class HTMLNavigationModeProbe: ReaderModeViewModel, @unchecked Sendable {
    var beforeFontReturns: (@MainActor () async -> Void)?
    private(set) var readerPresentationRequests = 0
    private(set) var presentationSelectionFence: (@Sendable () -> Bool)?

    override func injectSharedFontIfNeeded(
        scriptCaller: WebViewScriptCaller,
        pageURL: URL,
        documentIsCurrent: @escaping @MainActor () -> Bool
    ) async {
        await beforeFontReturns?()
    }

    override func showReaderView(
        readerContent: ReaderContent,
        scriptCaller: WebViewScriptCaller,
        selectionIsCurrent: @escaping @Sendable () -> Bool
    ) {
        readerPresentationRequests += 1
        presentationSelectionFence = selectionIsCurrent
    }
}

@MainActor
private final class HTMLNavigationReadGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isReleased = false

    func wait() async {
        guard !isReleased else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
final class ReaderContentHTMLLifetimeTests: XCTestCase {
    private let fileURL = URL(string: "reader-file://file/load/local/example.txt")!

    private enum FixtureError: Error {
        case unavailable
    }

    private func fixture() throws -> (Realm, HistoryRecord) {
        let configuration = Realm.Configuration(
            inMemoryIdentifier: "HTMLLifetime-\(UUID().uuidString)",
            objectTypes: [HistoryRecord.self]
        )
        let realm = try Realm(configuration: configuration)
        let record = HistoryRecord()
        record.rssContainsFullContent = false
        record.isFromClipboard = false
        record.url = fileURL
        record.updateCompoundKey()
        try realm.write { realm.add(record) }
        return (realm, record)
    }

    private func navigationFixture(
        for record: HistoryRecord,
        hasFileManager: Bool = true
    ) throws -> (content: ReaderContent, mode: HTMLNavigationModeProbe, navigator: WebViewNavigator, state: WebViewState) {
        let content = ReaderContent()
        content.replaceSelection(with: record)
        content.pageURL = record.url
        let mode = HTMLNavigationModeProbe()
        mode.readerFileManager = hasFileManager ? ReaderFileManager() : nil
        let navigator = WebViewNavigator()
        mode.navigator = navigator
        var state = WebViewState.empty
        state.pageURL = try XCTUnwrap(ReaderContentLoader.readerLoaderURL(for: record.url))
        return (content, mode, navigator, state)
    }

    private func assertCancelled(
        _ operation: @MainActor () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        do {
            try await operation()
            XCTFail("Retired navigation must throw CancellationError", file: file, line: line)
        } catch is CancellationError {
        }
    }

    private func replaceSelectionAwayAndBack(
        _ content: ReaderContent,
        returningTo record: HistoryRecord
    ) {
        let originalSelectionID = content.currentSelectionID
        let other = HistoryRecord()
        other.url = URL(string: "https://example.com/other-selection/\(UUID().uuidString)")!
        other.updateCompoundKey()
        content.replaceSelection(with: other)
        content.pageURL = other.url
        content.replaceSelection(with: record)
        content.pageURL = record.url
        XCTAssertNotEqual(content.currentSelectionID, originalSelectionID)
    }

    func testAlreadyDeletedRowDoesNotReadPersistedFieldsOrStartIO() async throws {
        let (realm, record) = try fixture()
        try realm.write { realm.delete(record) }
        XCTAssertTrue(record.isInvalidated)
        let result = try await record.htmlToDisplay(
            readFile: { _ in XCTFail("Deleted row must not start I/O"); return nil },
            resolveMIMEType: { _ in XCTFail("Deleted row must not load metadata"); return nil }
        )
        XCTAssertNil(result)
    }

    func testDeletionDuringReadDoesNotAccessRetiredURLOrLoadMetadata() async throws {
        let (realm, record) = try fixture()
        let result = try await record.htmlToDisplay(
            readFile: { requestedURL in
                XCTAssertEqual(requestedURL, self.fileURL)
                try realm.write { realm.delete(record) }
                return Data("Original text".utf8)
            },
            resolveMIMEType: { _ in XCTFail("Retired read must stop"); return nil }
        )
        XCTAssertTrue(record.isInvalidated)
        XCTAssertNil(result)
    }

    func testDeletionDuringMetadataResolutionDoesNotPublishHTML() async throws {
        let (realm, record) = try fixture()
        let result = try await record.htmlToDisplay(
            readFile: { _ in Data("Original text".utf8) },
            resolveMIMEType: { requestedURL in
                XCTAssertEqual(requestedURL, self.fileURL)
                try realm.write { realm.delete(record) }
                return "text/plain"
            }
        )
        XCTAssertTrue(record.isInvalidated)
        XCTAssertNil(result)
    }

    func testURLReplacementDuringReadDoesNotCombineOldBytesWithNewMetadata() async throws {
        let (realm, record) = try fixture()
        let result = try await record.htmlToDisplay(
            readFile: { _ in
                try realm.write {
                    record.url = URL(string: "reader-file://file/load/local/replacement.html")!
                }
                return Data("Original text".utf8)
            },
            resolveMIMEType: { _ in XCTFail("Changed URL must stop"); return nil }
        )
        XCTAssertNil(result)
    }

    func testURLReplacementDuringMetadataResolutionDoesNotPublishOldBytes() async throws {
        let (realm, record) = try fixture()
        let result = try await record.htmlToDisplay(
            readFile: { _ in Data("Original text".utf8) },
            resolveMIMEType: { _ in
                try realm.write {
                    record.url = URL(string: "reader-file://file/load/local/replacement.txt")!
                }
                return "text/plain"
            }
        )
        XCTAssertNil(result)
    }

    func testValidFileUsesCapturedURLAndNormalizesText() async throws {
        let (_, record) = try fixture()
        let result = try await record.htmlToDisplay(
            readFile: { requestedURL in
                XCTAssertEqual(requestedURL, self.fileURL)
                return Data("Readable Japanese text".utf8)
            },
            resolveMIMEType: { requestedURL in
                XCTAssertEqual(requestedURL, self.fileURL)
                return "text/plain"
            }
        )
        XCTAssertTrue(try XCTUnwrap(result).contains("Readable Japanese text"))
    }

    func testInlineHTMLStillAvoidsFileAndMetadataIO() async throws {
        let record = HistoryRecord()
        record.rssContainsFullContent = true
        record.html = "<p>Inline text</p>"
        let result = try await record.htmlToDisplay(
            readFile: { _ in XCTFail("Inline content needs no file read"); return nil },
            resolveMIMEType: { _ in XCTFail("Inline content needs no metadata read"); return nil }
        )
        XCTAssertEqual(result, "<p>Inline text</p>")
    }

    func testFileReadFailureDoesNotLoadMetadata() async throws {
        let (_, record) = try fixture()
        let result = try await record.htmlToDisplay(
            readFile: { _ in throw FixtureError.unavailable },
            resolveMIMEType: { _ in XCTFail("Failed read must stop"); return nil }
        )
        XCTAssertNil(result)
    }

    func testMissingMIMETypeStillNormalizesFileText() async throws {
        let (_, record) = try fixture()
        let result = try await record.htmlToDisplay(
            readFile: { _ in Data("Readable file text".utf8) },
            resolveMIMEType: { requestedURL in
                XCTAssertEqual(requestedURL, self.fileURL)
                return nil
            }
        )
        XCTAssertTrue(try XCTUnwrap(result).contains("Readable file text"))
    }

    func testMIMEFailureStillNormalizesFileText() async throws {
        let (_, record) = try fixture()
        let result = try await record.htmlToDisplay(
            readFile: { _ in Data("Readable file text".utf8) },
            resolveMIMEType: { _ in throw FixtureError.unavailable }
        )
        XCTAssertTrue(try XCTUnwrap(result).contains("Readable file text"))
    }

    func testCancellationDuringReadDoesNotStartMetadata() async throws {
        let (_, record) = try fixture()
        let task = Task { @MainActor in
            try await record.htmlToDisplay(
                readFile: { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                    return Data("Cancelled file text".utf8)
                },
                resolveMIMEType: { _ in XCTFail("Cancelled read must stop"); return nil }
            )
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled file read must not publish HTML")
        } catch is CancellationError {
            // The child task's cancellation is observed before metadata starts.
        }
    }

    func testCancellationDuringMetadataDoesNotPublishHTML() async throws {
        let (_, record) = try fixture()
        let task = Task { @MainActor in
            try await record.htmlToDisplay(
                readFile: { _ in Data("Cancelled file text".utf8) },
                resolveMIMEType: { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                    return "text/plain"
                }
            )
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled metadata resolution must not publish HTML")
        } catch is CancellationError {
            // A completed read is not an admitted presentation result.
        }
    }

    func testConsumerRejectsAlreadyDeletedContentBeforeLoading() async throws {
        let (realm, record) = try fixture()
        try realm.write { realm.delete(record) }
        let result = try await locallyRetrievableReaderHTML(for: record) {
            XCTFail("Retired content must not invoke its getter")
            return nil
        }
        XCTAssertNil(result)
    }

    func testConsumerRejectsDeletedContentAfterGetterReturnsNil() async throws {
        let (realm, record) = try fixture()
        let result = try await locallyRetrievableReaderHTML(for: record) {
            try await record.htmlToDisplay(
                readFile: { _ in
                    try realm.write { realm.delete(record) }
                    return Data("Original file text".utf8)
                },
                resolveMIMEType: { _ in XCTFail("Retired read must stop"); return nil }
            )
        }
        XCTAssertTrue(record.isInvalidated)
        XCTAssertNil(result, "Nil from the getter must not trigger an invalidated URL read")
    }

    func testConsumerDoesNotAdoptReplacementSnippetAfterFileRead() async throws {
        let (realm, record) = try fixture()
        let snippetURL = try XCTUnwrap(ReaderContentLoader.snippetURL(key: "replacement"))
        let result = try await locallyRetrievableReaderHTML(for: record) {
            try await record.htmlToDisplay(
                readFile: { _ in
                    try realm.write {
                        record.url = snippetURL
                        record.html = "<p>Successor snippet</p>"
                    }
                    return Data("Original file text".utf8)
                },
                resolveMIMEType: { _ in XCTFail("Replaced read must stop"); return nil }
            )
        }
        XCTAssertEqual(record.url, snippetURL)
        XCTAssertNil(result, "An old file request must not publish a successor's snippet fallback")
    }

    func testConsumerPreservesCurrentSnippetFallbackAndTrimsHTML() async throws {
        let record = HistoryRecord()
        record.url = try XCTUnwrap(ReaderContentLoader.snippetURL(key: "current"))
        record.rssContainsFullContent = false
        record.isFromClipboard = false
        record.html = "  <p>Current snippet</p>\n"
        let result = try await locallyRetrievableReaderHTML(for: record) {
            try await record.htmlToDisplay(
                readFile: { _ in XCTFail("A snippet needs no file read"); return nil },
                resolveMIMEType: { _ in XCTFail("A snippet needs no MIME metadata"); return nil }
            )
        }
        XCTAssertEqual(result, "<p>Current snippet</p>")
    }

    func testConsumerRejectsCancellationAfterFailedFileRead() async throws {
        let (_, record) = try fixture()
        let task = Task { @MainActor in
            try await locallyRetrievableReaderHTML(for: record) {
                try await record.htmlToDisplay(
                    readFile: { _ in
                        withUnsafeCurrentTask { $0?.cancel() }
                        throw CancellationError()
                    },
                    resolveMIMEType: { _ in XCTFail("Failed read must stop"); return nil }
                )
            }
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled loading must not become a successful presentation result")
        } catch is CancellationError {
            // The consumer rechecks cancellation even when best-effort I/O returns nil.
        }
    }

    func testCancelledCommitCannotReplaceSuccessorRequestAfterNilOrFailedRead() async throws {
        for throwsReadError in [false, true] {
            let (_, record) = try fixture()
            let navigation = try navigationFixture(for: record)
            let manager = NavigationTaskManager()
            let gate = HTMLNavigationReadGate()
            let readStarted = expectation(description: "file read suspended: \(throwsReadError)")
            manager.startOnNavigationCommitted {
                try await navigation.mode.onNavigationCommitted(
                    readerContent: navigation.content,
                    newState: navigation.state,
                    scriptCaller: WebViewScriptCaller(),
                    loadHTML: { content, _ in
                        try await content.htmlToDisplay(
                            readFile: { _ in
                                readStarted.fulfill()
                                await gate.wait()
                                if throwsReadError { throw FixtureError.unavailable }
                                return nil
                            },
                            resolveMIMEType: { _ in XCTFail("An absent read needs no metadata"); return nil }
                        )
                    }
                )
            }
            let retiredTask = try XCTUnwrap(manager.onNavigationCommittedTask)
            await fulfillment(of: [readStarted], timeout: 1)
            let successorURL = try XCTUnwrap(URL(string: "https://example.com/successor"))
            manager.startOnNavigationCommitted {
                navigation.navigator.load(URLRequest(url: successorURL))
            }
            try await manager.onNavigationCommittedTask?.value
            gate.release()
            try await assertCancelled { try await retiredTask.value }
            XCTAssertEqual(navigation.navigator.debugLoadSnapshot.lastRequestURL, successorURL.absoluteString)
            XCTAssertEqual(navigation.mode.readerPresentationRequests, 0)
        }
    }

    func testCommitRejectsDeletedSourceBeforeMissingHTMLFallback() async throws {
        let (realm, record) = try fixture()
        let navigation = try navigationFixture(for: record)
        try await assertCancelled {
            try await navigation.mode.onNavigationCommitted(
                readerContent: navigation.content,
                newState: navigation.state,
                scriptCaller: WebViewScriptCaller(),
                loadHTML: { content, _ in
                    try await content.htmlToDisplay(
                        readFile: { _ in
                            try realm.write { realm.delete(record) }
                            return Data("Retired file text".utf8)
                        },
                        resolveMIMEType: { _ in XCTFail("Retired read must stop"); return nil }
                    )
                }
            )
        }
        XCTAssertTrue(record.isInvalidated)
        XCTAssertEqual(navigation.navigator.debugLoadSnapshot.lastRequestURL, "nil")
        XCTAssertEqual(navigation.mode.readerPresentationRequests, 0)
    }

    func testCommitRejectsReplacedSourceURLBeforeMissingHTMLFallback() async throws {
        let (realm, record) = try fixture()
        let navigation = try navigationFixture(for: record)
        try await assertCancelled {
            try await navigation.mode.onNavigationCommitted(
                readerContent: navigation.content,
                newState: navigation.state,
                scriptCaller: WebViewScriptCaller(),
                loadHTML: { content, _ in
                    try await content.htmlToDisplay(
                        readFile: { _ in
                            try realm.write {
                                record.url = URL(string: "reader-file://file/load/local/replacement.txt")!
                            }
                            return Data("Original file text".utf8)
                        },
                        resolveMIMEType: { _ in XCTFail("Replaced read must stop"); return nil }
                    )
                }
            )
        }
        XCTAssertEqual(navigation.navigator.debugLoadSnapshot.lastRequestURL, "nil")
        XCTAssertEqual(navigation.mode.readerPresentationRequests, 0)
    }

    func testChangedPageRejectsBothMissingAndPresentFileHTML() async throws {
        for returnsHTML in [false, true] {
            let (_, record) = try fixture()
            let navigation = try navigationFixture(for: record)
            let successorURL = try XCTUnwrap(URL(string: "https://example.com/successor"))
            try await assertCancelled {
                try await navigation.mode.onNavigationCommitted(
                    readerContent: navigation.content,
                    newState: navigation.state,
                    scriptCaller: WebViewScriptCaller(),
                    loadHTML: { content, _ in
                        try await content.htmlToDisplay(
                            readFile: { _ in
                                navigation.content.pageURL = successorURL
                                return returnsHTML ? Data("Original file text".utf8) : nil
                            },
                            resolveMIMEType: { _ in "text/plain" }
                        )
                    }
                )
            }
            XCTAssertEqual(navigation.content.pageURL, successorURL)
            XCTAssertFalse(navigation.content.isRenderingReaderHTML)
            XCTAssertEqual(navigation.navigator.debugLoadSnapshot.lastRequestURL, "nil")
            XCTAssertEqual(navigation.mode.readerPresentationRequests, 0)
        }
    }

    func testCurrentMissingOrFailedFileReadPreservesFallbackNavigation() async throws {
        for throwsReadError in [false, true] {
            let (_, record) = try fixture()
            let navigation = try navigationFixture(for: record)
            try await navigation.mode.onNavigationCommitted(
                readerContent: navigation.content,
                newState: navigation.state,
                scriptCaller: WebViewScriptCaller(),
                loadHTML: { content, _ in
                    try await content.htmlToDisplay(
                        readFile: { _ in
                            if throwsReadError { throw FixtureError.unavailable }
                            return nil
                        },
                        resolveMIMEType: { _ in XCTFail("An absent read needs no metadata"); return nil }
                    )
                }
            )
            XCTAssertEqual(navigation.navigator.debugLoadSnapshot.lastRequestURL, fileURL.absoluteString)
            XCTAssertEqual(navigation.mode.readerPresentationRequests, 0)
        }
    }

    func testCurrentInlineHTMLUsesPublicCommitPresentationPath() async throws {
        let (realm, record) = try fixture()
        try realm.write {
            record.rssContainsFullContent = true
            record.html = "<p>Current inline content</p>"
        }
        let navigation = try navigationFixture(for: record)
        try await navigation.mode.onNavigationCommitted(
            readerContent: navigation.content,
            newState: navigation.state,
            scriptCaller: WebViewScriptCaller()
        )
        XCTAssertTrue(navigation.content.isRenderingReaderHTML)
        XCTAssertEqual(navigation.mode.readerPresentationRequests, 1)
        XCTAssertEqual(navigation.navigator.debugLoadSnapshot.lastRequestURL, "nil")
    }

    func testNoFileManagerFallbackRejectsPageChangedDuringPreparation() async throws {
        let (_, record) = try fixture()
        let navigation = try navigationFixture(for: record, hasFileManager: false)
        let successorURL = try XCTUnwrap(URL(string: "https://example.com/successor"))
        navigation.mode.beforeFontReturns = { [content = navigation.content] in
            content.pageURL = successorURL
        }
        try await assertCancelled {
            try await navigation.mode.onNavigationCommitted(
                readerContent: navigation.content,
                newState: navigation.state,
                scriptCaller: WebViewScriptCaller()
            )
        }
        XCTAssertEqual(navigation.navigator.debugLoadSnapshot.lastRequestURL, "nil")
        XCTAssertEqual(navigation.mode.readerPresentationRequests, 0)
    }

    func testCurrentNoFileManagerUsesPublicFallbackPath() async throws {
        let (_, record) = try fixture()
        let navigation = try navigationFixture(for: record, hasFileManager: false)
        try await navigation.mode.onNavigationCommitted(
            readerContent: navigation.content,
            newState: navigation.state,
            scriptCaller: WebViewScriptCaller()
        )
        XCTAssertEqual(navigation.navigator.debugLoadSnapshot.lastRequestURL, fileURL.absoluteString)
        XCTAssertEqual(navigation.mode.readerPresentationRequests, 0)
    }

    func testGetterErrorPreservesCurrentFailureAndWithdrawsRetiredFailure() async throws {
        for changesPage in [false, true] {
            let (_, record) = try fixture()
            let navigation = try navigationFixture(for: record)
            do {
                try await navigation.mode.onNavigationCommitted(
                    readerContent: navigation.content,
                    newState: navigation.state,
                    scriptCaller: WebViewScriptCaller(),
                    loadHTML: { _, _ in
                        if changesPage {
                            navigation.content.pageURL = URL(string: "https://example.com/successor")!
                        }
                        throw FixtureError.unavailable
                    }
                )
                XCTFail("A failed getter must not complete navigation")
            } catch is CancellationError {
                XCTAssertTrue(changesPage)
            } catch FixtureError.unavailable {
                XCTAssertFalse(changesPage)
            }
            XCTAssertEqual(navigation.navigator.debugLoadSnapshot.lastRequestURL, "nil")
            XCTAssertEqual(navigation.mode.readerPresentationRequests, 0)
        }
    }

    func testSelectionABARetiresPresentMissingAndFailedFileReadsBeforeCommandOutput() async throws {
        let html = "<html><body class=\"readability-mode\"><div id=\"reader-content\">Original HTML</div></body></html>"
        for outcome in ["html", "missing", "readError"] {
            let (_, record) = try fixture()
            let navigation = try navigationFixture(for: record)
            let gate = HTMLNavigationReadGate()
            let readStarted = expectation(description: "original selection began file read: \(outcome)")
            let task = Task { @MainActor in
                try await navigation.mode.onNavigationCommitted(
                    readerContent: navigation.content,
                    newState: navigation.state,
                    scriptCaller: WebViewScriptCaller(),
                    loadHTML: { content, _ in
                        try await content.htmlToDisplay(
                            readFile: { _ in
                                readStarted.fulfill()
                                await gate.wait()
                                if outcome == "readError" { throw FixtureError.unavailable }
                                return outcome == "html" ? Data(html.utf8) : nil
                            },
                            resolveMIMEType: { _ in "text/html" }
                        )
                    }
                )
            }
            defer {
                gate.release()
                task.cancel()
            }
            let started = await XCTWaiter.fulfillment(of: [readStarted], timeout: 2)
            guard started == .completed else {
                gate.release()
                task.cancel()
                _ = try? await task.value
                XCTFail("The actual production getter must reach its file dependency")
                return
            }
            replaceSelectionAwayAndBack(navigation.content, returningTo: record)
            XCTAssertFalse(record.isInvalidated)
            XCTAssertEqual(record.url, fileURL)
            XCTAssertEqual(navigation.content.pageURL, fileURL)
            XCTAssertFalse(task.isCancelled)
            let successorRequest = URL(string: "https://example.com/current-request/\(UUID().uuidString)")!
            navigation.navigator.load(URLRequest(url: successorRequest))
            gate.release()
            try await assertCancelled { try await task.value }
            XCTAssertEqual(navigation.navigator.debugLoadSnapshot.lastRequestURL, successorRequest.absoluteString)
            XCTAssertFalse(navigation.content.isRenderingReaderHTML)
            XCTAssertNil(navigation.mode.readabilityContent)
            XCTAssertEqual(navigation.mode.readerPresentationRequests, 0)

            // The returned selection can independently retry the same production getter.
            try await navigation.mode.onNavigationCommitted(
                readerContent: navigation.content,
                newState: navigation.state,
                scriptCaller: WebViewScriptCaller(),
                loadHTML: { content, _ in
                    try await content.htmlToDisplay(
                        readFile: { _ in
                            if outcome == "readError" { throw FixtureError.unavailable }
                            return outcome == "html" ? Data(html.utf8) : nil
                        },
                        resolveMIMEType: { _ in "text/html" }
                    )
                }
            )
            if outcome == "html" {
                XCTAssertEqual(navigation.mode.readerPresentationRequests, 1)
                XCTAssertTrue(navigation.content.isRenderingReaderHTML)
                XCTAssertEqual(navigation.navigator.debugLoadSnapshot.lastRequestURL, successorRequest.absoluteString)
            } else {
                XCTAssertEqual(navigation.mode.readerPresentationRequests, 0)
                XCTAssertEqual(navigation.navigator.debugLoadSnapshot.lastRequestURL, fileURL.absoluteString)
            }
        }
    }

    func testSelectionABARetiresGetterErrorButCurrentRetryPreservesTheError() async throws {
        let (_, record) = try fixture()
        let navigation = try navigationFixture(for: record)
        try await assertCancelled {
            try await navigation.mode.onNavigationCommitted(
                readerContent: navigation.content,
                newState: navigation.state,
                scriptCaller: WebViewScriptCaller(),
                loadHTML: { _, _ in
                    self.replaceSelectionAwayAndBack(navigation.content, returningTo: record)
                    throw FixtureError.unavailable
                }
            )
        }
        do {
            try await navigation.mode.onNavigationCommitted(
                readerContent: navigation.content,
                newState: navigation.state,
                scriptCaller: WebViewScriptCaller(),
                loadHTML: { _, _ in throw FixtureError.unavailable }
            )
            XCTFail("The current selection must preserve the getter's original error")
        } catch FixtureError.unavailable {
        }
        XCTAssertEqual(navigation.navigator.debugLoadSnapshot.lastRequestURL, "nil")
        XCTAssertEqual(navigation.mode.readerPresentationRequests, 0)
    }

    func testPublicCommitRetiresSelectionABADuringFontPreparationBeforeFallback() async throws {
        let (_, record) = try fixture()
        let navigation = try navigationFixture(for: record, hasFileManager: false)
        navigation.mode.beforeFontReturns = { [content = navigation.content] in
            self.replaceSelectionAwayAndBack(content, returningTo: record)
        }
        try await assertCancelled {
            try await navigation.mode.onNavigationCommitted(
                readerContent: navigation.content,
                newState: navigation.state,
                scriptCaller: WebViewScriptCaller()
            )
        }
        XCTAssertEqual(navigation.navigator.debugLoadSnapshot.lastRequestURL, "nil")
        XCTAssertEqual(navigation.mode.readerPresentationRequests, 0)

        navigation.mode.beforeFontReturns = nil
        try await navigation.mode.onNavigationCommitted(
            readerContent: navigation.content,
            newState: navigation.state,
            scriptCaller: WebViewScriptCaller()
        )
        XCTAssertEqual(navigation.navigator.debugLoadSnapshot.lastRequestURL, fileURL.absoluteString)
    }

    func testPublicCommitPassesItsSelectionFenceToPresentation() async throws {
        let (realm, record) = try fixture()
        try realm.write {
            record.rssContainsFullContent = true
            record.html = "<p>Current inline content</p>"
        }
        let navigation = try navigationFixture(for: record)
        try await navigation.mode.onNavigationCommitted(
            readerContent: navigation.content,
            newState: navigation.state,
            scriptCaller: WebViewScriptCaller()
        )
        XCTAssertEqual(navigation.mode.readerPresentationRequests, 1)
        let presentedFence = try XCTUnwrap(navigation.mode.presentationSelectionFence)
        XCTAssertTrue(presentedFence())
        replaceSelectionAwayAndBack(navigation.content, returningTo: record)
        XCTAssertFalse(presentedFence())
    }

    func testExplicitRetiredFenceCannotStartRenderForTheReturnedSelection() throws {
        let (_, record) = try fixture()
        let content = ReaderContent()
        content.replaceSelection(with: record)
        content.pageURL = fileURL
        let originalFence = content.makeSelectionCommitFence(requiring: content.currentSelectionID)
        replaceSelectionAwayAndBack(content, returningTo: record)
        let mode = ReaderModeViewModel()
        mode.showReaderView(
            readerContent: content,
            scriptCaller: WebViewScriptCaller(),
            selectionIsCurrent: originalFence
        )
        XCTAssertNil(mode.activeRenderTask(for: fileURL))
        XCTAssertFalse(mode.isReaderModeLoading)
    }

    func testCommitRechecksSelectionAfterReadabilityPublicationBeforeRendering() async throws {
        let (_, record) = try fixture()
        let navigation = try navigationFixture(for: record)
        let publication = navigation.mode.$readabilityContent.dropFirst().sink { [content = navigation.content] html in
            guard html != nil else { return }
            self.replaceSelectionAwayAndBack(content, returningTo: record)
        }
        defer { publication.cancel() }
        try await assertCancelled {
            try await navigation.mode.onNavigationCommitted(
                readerContent: navigation.content,
                newState: navigation.state,
                scriptCaller: WebViewScriptCaller(),
                loadHTML: { _, _ in
                    "<html><body class=\"readability-mode\"><div id=\"reader-content\">Prepared HTML</div></body></html>"
                }
            )
        }
        XCTAssertFalse(navigation.content.isRenderingReaderHTML)
        XCTAssertEqual(navigation.mode.readerPresentationRequests, 0)
        XCTAssertEqual(navigation.navigator.debugLoadSnapshot.lastRequestURL, "nil")
    }

    func testCommitRechecksSelectionAfterRenderingPublicationBeforePresentation() async throws {
        let (_, record) = try fixture()
        let navigation = try navigationFixture(for: record)
        let publication = navigation.content.$isRenderingReaderHTML.dropFirst().sink { [content = navigation.content] isRendering in
            guard isRendering else { return }
            self.replaceSelectionAwayAndBack(content, returningTo: record)
        }
        defer { publication.cancel() }
        try await assertCancelled {
            try await navigation.mode.onNavigationCommitted(
                readerContent: navigation.content,
                newState: navigation.state,
                scriptCaller: WebViewScriptCaller(),
                loadHTML: { _, _ in "<p>Prepared HTML</p>" }
            )
        }
        XCTAssertEqual(navigation.mode.readerPresentationRequests, 0)
        XCTAssertEqual(navigation.navigator.debugLoadSnapshot.lastRequestURL, "nil")
    }

    func testCommitRechecksSelectionAfterDuplicateRenderCancellation() async throws {
        let (_, record) = try fixture()
        let navigation = try navigationFixture(for: record, hasFileManager: false)
        let content = navigation.content
        let mode = navigation.mode
        let url = fileURL
        let originalFence = content.makeSelectionCommitFence(requiring: content.currentSelectionID)
        let gate = HTMLNavigationReadGate()
        let installed = expectation(description: "retired render registered its cancellation handler")
        XCTAssertTrue(mode.startRenderTaskIfNeeded(
            for: url, reason: "navigation-selection-ingress", selectionIsCurrent: originalFence
        ) { _ in
            await { @MainActor in
                await withTaskCancellationHandler {
                    installed.fulfill()
                    await gate.wait()
                } onCancel: {
                    MainActor.assumeIsolated {
                        guard let current = content.content as? HistoryRecord else { return }
                        self.replaceSelectionAwayAndBack(content, returningTo: current)
                    }
                }
            }()
        })
        let retiredRender = try XCTUnwrap(mode.activeRenderTask(for: url))
        addTeardownBlock {
            await MainActor.run {
                content.replaceSelection(with: nil)
                mode.cancelReaderModeLoad(for: url, reason: "selection-ingress-test-cleanup")
                retiredRender.cancel()
                gate.release()
            }
            await retiredRender.value
        }
        let ready = await XCTWaiter.fulfillment(of: [installed], timeout: 2)
        guard ready == .completed else {
            XCTFail("The actual render must register its synchronous cancellation handler")
            return
        }
        replaceSelectionAwayAndBack(navigation.content, returningTo: record)
        try await assertCancelled {
            try await navigation.mode.onNavigationCommitted(
                readerContent: navigation.content,
                newState: navigation.state,
                scriptCaller: WebViewScriptCaller()
            )
        }
        gate.release()
        await retiredRender.value
        XCTAssertEqual(navigation.navigator.debugLoadSnapshot.lastRequestURL, "nil")
        XCTAssertEqual(navigation.mode.readerPresentationRequests, 0)
    }
}
