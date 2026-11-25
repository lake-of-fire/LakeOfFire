import BigSyncKit
import Foundation
import RealmSwift
import RealmSwiftGaps
import SwiftUI
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireReader
@testable import SwiftUIWebView

#if DEBUG
@MainActor
final class ReaderRSSDiscoveryOwnershipTests: XCTestCase {
    func testSameURLReplacementCannotCommitRetiredRSSDiscovery() async throws {
        var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        configuration.objectTypes = [Bookmark.self, ContentFile.self, HistoryRecord.self, FeedEntry.self]
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        let realm = try await Realm(configuration: configuration, actor: MainActor.shared)
        let storage = ReaderContentLoader.MutationStorage(
            bookmarkConfiguration: configuration,
            historyConfiguration: configuration,
            feedConfiguration: configuration
        )
        var libraryConfiguration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        libraryConfiguration.objectTypes = [LibraryConfiguration.self, FeedCategory.self, UserScript.self]
        configureLakeOfFireMutationTrackingForTesting(&libraryConfiguration)
        let fixtureConfiguration = configuration
        let fixtureLibraryConfiguration = libraryConfiguration
        addTeardownBlock {
            _ = await RealmBackgroundActor.shared.removeCachedRealm(for: fixtureConfiguration)
            _ = await RealmBackgroundActor.shared.removeCachedRealm(for: fixtureLibraryConfiguration)
        }

        let pageURL = URL(string: "https://example.invalid/article")!
        let initialURL = URL(string: "https://example.invalid/initial.xml")!
        let replacementURL = URL(string: "https://example.invalid/replacement.xml")!
        let record = HistoryRecord()
        record.url = pageURL
        record.updateCompoundKey()
        try realm.write { realm.add(record) }

        let originalOwner = ReaderContent()
        originalOwner.preloadResolvedContent(record, for: pageURL)
        try await originalOwner.load(url: pageURL)
        let replacementOwner = ReaderContent()
        replacementOwner.preloadResolvedContent(record, for: pageURL)
        try await replacementOwner.load(url: pageURL)
        XCTAssertNotNil(originalOwner.validCachedContent)
        XCTAssertNotNil(replacementOwner.validCachedContent)

        let viewModel = ReaderViewModel(realmConfiguration: libraryConfiguration, systemScripts: [])
        viewModel.state.pageURL = pageURL
        let mode = ReaderModeViewModel()
        let navigator = WebViewNavigator()
        let caller = WebViewScriptCaller()
        caller.installBinding(
            ownedBy: UUID(),
            asyncCaller: { _, _, _, _ in
                XCTFail("RSS discovery should use the received pairs")
                return WebViewScriptCaller.JavaScriptEvaluationResult(nil)
            },
            unsafeCaller: nil,
            snapshotCapture: nil,
            coordinateOriginInWindow: { nil }
        )
        let binding = try XCTUnwrap(caller.currentJavaScriptBindingToken)
        let handlers = ReaderMessageHandlers(
            forceReaderModeWhenAvailable: false,
            scriptCaller: caller,
            readerViewModel: viewModel,
            readerModeViewModel: mode,
            readerContent: originalOwner,
            navigator: navigator,
            hideNavigationDueToScroll: .constant(false),
            showOriginalWillBeginHandler: nil,
            navigationVisibilityWillChangeHandler: nil,
            colorScheme: .light
        )

        func report(_ feedURL: URL, title: String) async throws -> ReaderContentMutationOutcome? {
            try await handlers.handleRSSURLs(
                [[feedURL.absoluteString, title]], windowURL: pageURL, frameMainDocumentURL: pageURL,
                isMainFrame: true, binding: binding, storage: storage
            )
        }
        let journalKey = "HistoryRecord.\(record.compoundKey)"
        func journalGeneration() -> String? {
            realm.object(ofType: BigSyncPendingMutation.self, forPrimaryKey: journalKey)?.generation
        }

        let firstResult = try await report(initialURL, title: "Initial title")
        let first = try XCTUnwrap(firstResult)
        XCTAssertEqual(first.mutatedObjectCount, 1)
        XCTAssertNil(first.errorMessage)
        await realm.asyncRefresh()
        XCTAssertEqual(Array(record.rssURLs), [initialURL])
        XCTAssertEqual(Array(record.rssTitles), ["Initial title"])
        XCTAssertTrue(record.isRSSAvailable)
        let initialGeneration = try XCTUnwrap(journalGeneration())
        let initialModifiedAt = record.modifiedAt

        let replayResult = try await report(initialURL, title: "Initial title")
        let replay = try XCTUnwrap(replayResult)
        XCTAssertEqual(replay.matchedObjectCount, 1)
        XCTAssertEqual(replay.mutatedObjectCount, 0)
        XCTAssertNil(replay.errorMessage)
        await realm.asyncRefresh()
        XCTAssertEqual(journalGeneration(), initialGeneration)
        XCTAssertEqual(record.modifiedAt, initialModifiedAt)

        let previousGate = await { @RealmBackgroundActor in
            let previous = ReaderContentLoader.contentWriteGateForTesting
            ReaderContentLoader.contentWriteGateForTesting = { operation in
                guard operation == .contentMutation else { return }
                await { @MainActor in
                    handlers.update(
                        forceReaderModeWhenAvailable: false,
                        scriptCaller: caller,
                        readerViewModel: viewModel,
                        readerModeViewModel: mode,
                        readerContent: replacementOwner,
                        navigator: handlers.navigator,
                        hideNavigationDueToScroll: .constant(false),
                        showOriginalWillBeginHandler: nil,
                        navigationVisibilityWillChangeHandler: nil,
                        ebookOpeningPreparer: nil,
                        colorScheme: .light
                    )
                }()
            }
            return previous
        }()
        addTeardownBlock {
            await { @RealmBackgroundActor in ReaderContentLoader.contentWriteGateForTesting = previousGate }()
        }
        let retiredResult = try await report(replacementURL, title: "Retired title")
        await { @RealmBackgroundActor in ReaderContentLoader.contentWriteGateForTesting = previousGate }()
        let retired = try XCTUnwrap(retiredResult)
        XCTAssertTrue(handlers.readerContent === replacementOwner)
        XCTAssertEqual(viewModel.state.pageURL, pageURL)
        XCTAssertEqual(caller.currentJavaScriptBindingToken, binding)
        XCTAssertEqual(retired.matchedObjectCount, 1)
        XCTAssertEqual(retired.committedObjectCount, 0)
        XCTAssertTrue(retired.cancelledBeforeCommit)
        await realm.asyncRefresh()
        XCTAssertEqual(Array(record.rssURLs), [initialURL])
        XCTAssertEqual(Array(record.rssTitles), ["Initial title"])
        XCTAssertEqual(journalGeneration(), initialGeneration)
        XCTAssertEqual(record.modifiedAt, initialModifiedAt)

        let currentResult = try await report(replacementURL, title: "Replacement title")
        let current = try XCTUnwrap(currentResult)
        XCTAssertEqual(current.mutatedObjectCount, 1)
        XCTAssertNil(current.errorMessage)
        await realm.asyncRefresh()
        XCTAssertEqual(Array(record.rssURLs), [replacementURL])
        XCTAssertEqual(Array(record.rssTitles), ["Replacement title"])
        XCTAssertTrue(record.isRSSAvailable)
        XCTAssertNotEqual(try XCTUnwrap(journalGeneration()), initialGeneration)
    }
}
#endif
