import BigSyncKit
import Foundation
import RealmSwift
import RealmSwiftGaps
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireReader
@testable import SwiftUIWebView

// Shared only by document-admission regression fixtures. Entry races producer
// completion; joins are bounded without awaiting an uncooperative task forever.
final class ReaderDocumentTestSignal: @unchecked Sendable {
    let expectation: XCTestExpectation
    private let lock = NSLock()
    private var signalled = false

    init(_ expectation: XCTestExpectation) { self.expectation = expectation }

    var hasSignalled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return signalled
    }

    func signal() {
        lock.lock()
        let shouldSignal = !signalled
        signalled = true
        lock.unlock()
        if shouldSignal { expectation.fulfill() }
    }
}

enum ReaderDocumentTestError: Error { case producerDidNotEnter, producerDidNotFinish }

private actor ReaderDocumentWriterGate {
    private(set) var entered = false
    private var released = false
    private let entrySignal: ReaderDocumentTestSignal
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(entrySignal: ReaderDocumentTestSignal) { self.entrySignal = entrySignal }

    // Deliberately ignores cancellation, as queued work may still resume.
    func wait() async {
        entered = true
        entrySignal.signal()
        if !released { await withCheckedContinuation { releaseWaiters.append($0) } }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

@MainActor
final class ReaderDocumentMutationFenceTests: XCTestCase {
    private let targetURL = URL(string: "https://example.com/article")!

    private func bind(_ caller: WebViewScriptCaller) {
        caller.installBinding(
            ownedBy: UUID(),
            asyncCaller: { _, _, _, _ in .init(nil) },
            unsafeCaller: nil,
            snapshotCapture: nil,
            coordinateOriginInWindow: { nil }
        )
    }

    func testProvenanceRejectsUnrelatedDocumentAndRequiresMainFrameWhenRequested() {
        let otherURL = URL(string: "https://example.com/other")!
        XCTAssertTrue(ReaderDocumentMutationAdmission.acceptsTopLevelDocument(
            claimedURL: URL(string: "https://example.com/article#section")!,
            frameMainDocumentURL: targetURL, currentPageURL: targetURL,
            requiresMainFrame: true, isMainFrame: true
        ))
        for (claimed, native, isMainFrame) in [
            (otherURL, targetURL, true),
            (targetURL, otherURL, true),
            (targetURL, targetURL, false)
        ] {
            XCTAssertFalse(ReaderDocumentMutationAdmission.acceptsTopLevelDocument(
                claimedURL: claimed, frameMainDocumentURL: native,
                currentPageURL: targetURL, requiresMainFrame: true, isMainFrame: isMainFrame
            ))
        }
        XCTAssertTrue(ReaderDocumentMutationAdmission.acceptsTopLevelDocument(
            claimedURL: targetURL, frameMainDocumentURL: targetURL,
            currentPageURL: targetURL, requiresMainFrame: false, isMainFrame: false
        ))
    }

    func testMissingReceiptCannotBorrowCurrentBindingOrAnotherWindow() throws {
        let caller = WebViewScriptCaller()
        bind(caller)
        XCTAssertNil(ReaderDocumentMutationAdmission.capture(
            targetURL: targetURL, requiring: nil, scriptCaller: caller
        ))
        let otherCaller = WebViewScriptCaller()
        bind(otherCaller)
        XCTAssertNil(ReaderDocumentMutationAdmission.capture(
            targetURL: targetURL,
            requiring: try XCTUnwrap(otherCaller.currentJavaScriptBindingToken),
            scriptCaller: caller
        ))
    }

    func testSameURLReplacementRejectsSuspendedMetadataAndChangeMetadata() async throws {
        try await exerciseMetadataUpdate(replaceBinding: true, cancelWriter: false)
    }

    func testCancelledMetadataUpdateRejectsFieldsWhenBindingIsCurrent() async throws {
        try await exerciseMetadataUpdate(replaceBinding: false, cancelWriter: true)
    }

    func testCurrentDocumentCanPersistMetadata() async throws {
        try await exerciseMetadataUpdate(replaceBinding: false, cancelWriter: false)
    }

    func testNativeMetadataCallbackKeepsPublicAPI() async throws {
        try await exerciseMetadataUpdate(replaceBinding: false, cancelWriter: false, useNativeCallback: true)
    }

    private func exerciseMetadataUpdate(
        replaceBinding: Bool,
        cancelWriter: Bool,
        useNativeCallback: Bool = false
    ) async throws {
        var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        configuration.objectTypes = [Bookmark.self, ContentFile.self, HistoryRecord.self, FeedEntry.self]
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        let previousBookmark = ReaderContentLoader.bookmarkRealmConfiguration
        let previousHistory = ReaderContentLoader.historyRealmConfiguration
        let previousFeed = ReaderContentLoader.feedEntryRealmConfiguration
        let previousProviders = ReaderContentLoader.additionalContentProviders
        let previousResolver = ReaderContent.contentResolver
        defer {
            ReaderContentLoader.bookmarkRealmConfiguration = previousBookmark
            ReaderContentLoader.historyRealmConfiguration = previousHistory
            ReaderContentLoader.feedEntryRealmConfiguration = previousFeed
            ReaderContentLoader.additionalContentProviders = previousProviders
            ReaderContent.contentResolver = previousResolver
        }
        await ReaderContentLoader.resetTransientCachesForTesting()
        ReaderContentLoader.bookmarkRealmConfiguration = configuration
        ReaderContentLoader.historyRealmConfiguration = configuration
        ReaderContentLoader.feedEntryRealmConfiguration = configuration
        let entry = ReaderDocumentTestSignal(expectation(description: "metadata lookup entered or completed"))
        let completion = ReaderDocumentTestSignal(expectation(description: "metadata producer completed"))
        let gate = ReaderDocumentWriterGate(entrySignal: entry)
        ReaderContentLoader.additionalContentProviders = [ReaderContentAdditionalProvider(
            id: "document-admission-suspension",
            load: { _ in
                await gate.wait()
                return []
            }
        )]
        let realm = try await Realm(configuration: configuration, actor: MainActor.shared)
        let bookmark = Bookmark()
        bookmark.url = targetURL
        bookmark.title = "Original"
        bookmark.author = "Original Author"
        bookmark.updateCompoundKey()
        try realm.write { realm.add(bookmark) }
        let originalModifiedAt = bookmark.modifiedAt
        let originalExplicitlyModifiedAt = bookmark.explicitlyModifiedAt
        let viewModel = ReaderViewModel(
            realmConfiguration: configuration, systemScripts: [], observeLibraryChanges: false
        )
        viewModel.state.pageURL = targetURL
        bind(viewModel.scriptCaller)
        let admission = try XCTUnwrap(ReaderDocumentMutationAdmission.capture(
            targetURL: targetURL,
            requiring: try XCTUnwrap(viewModel.scriptCaller.currentJavaScriptBindingToken),
            scriptCaller: viewModel.scriptCaller
        ))
        // Exercise the production metadata method and real loader/Realm path;
        // the provider suspends its lookup, without copying the writer logic.
        let writer = Task { @MainActor in
            defer { completion.signal(); entry.signal() }
            if useNativeCallback {
                try await viewModel.pageMetadataUpdated(title: "New Title", author: "New Author")
            } else {
                try await viewModel.pageMetadataUpdated(
                    title: "New Title", author: "New Author", admission: admission
                )
            }
        }
        await fulfillment(of: [entry.expectation], timeout: 2)
        guard await gate.entered else {
            writer.cancel()
            await gate.release()
            await fulfillment(of: [completion.expectation], timeout: 2)
            if completion.hasSignalled { try await writer.value }
            throw ReaderDocumentTestError.producerDidNotEnter
        }
        if replaceBinding { bind(viewModel.scriptCaller) } // Target URL is identical.
        if cancelWriter { writer.cancel() }
        await gate.release()
        await fulfillment(of: [completion.expectation], timeout: 2)
        guard completion.hasSignalled else {
            writer.cancel()
            throw ReaderDocumentTestError.producerDidNotFinish
        }
        do {
            try await writer.value
        } catch is CancellationError {
            XCTAssertTrue(cancelWriter)
        }
        await realm.asyncRefresh()
        let shouldCommit = !replaceBinding && !cancelWriter
        XCTAssertEqual(bookmark.title, shouldCommit ? "New Title" : "Original")
        XCTAssertEqual(bookmark.author, shouldCommit ? "New Author" : "Original Author")
        if shouldCommit {
            XCTAssertNotEqual(bookmark.explicitlyModifiedAt, originalExplicitlyModifiedAt)
        } else {
            XCTAssertEqual(bookmark.modifiedAt, originalModifiedAt)
            XCTAssertEqual(bookmark.explicitlyModifiedAt, originalExplicitlyModifiedAt)
        }
        await ReaderContentLoader.resetTransientCachesForTesting()
    }
}
