import BigSyncKit
import Combine
import RealmSwift
import RealmSwiftGaps
import SwiftUIWebView
import WebKit
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireLibrary
@testable import LakeOfFireReader

@MainActor
final class LibraryFeedEditorOwnershipTests: XCTestCase {
    func testDelayedFeedFieldAndPasteStayInOriginatingRealm() async throws {
        let originalConfiguration = configuration()
        let replacementConfiguration = configuration()
        let original = try await Realm(configuration: originalConfiguration)
        let replacement = try await Realm(configuration: replacementConfiguration)
        let categoryID = UUID()
        let feedID = UUID()
        let originalFeed = try installFeed(id: feedID, categoryID: categoryID, title: "Original", in: original)
        let replacementFeed = try installFeed(
            id: feedID, categoryID: categoryID, title: "Replacement", in: replacement
        )
        let previous = LibraryDataManager.realmConfiguration
        defer { LibraryDataManager.realmConfiguration = previous }
        LibraryDataManager.realmConfiguration = originalConfiguration
        let model = LibraryFeedFormSectionsViewModel(feed: originalFeed)
        let initialized = await waitUntil { model.hasInitializedValues }
        XCTAssertTrue(initialized)
        model.feedTitle = "Leading original edit"
        model.feedTitle = "Delayed original edit"
        LibraryDataManager.realmConfiguration = replacementConfiguration
        let edited = await waitUntil { original.refresh(); return originalFeed.title == "Delayed original edit" }
        XCTAssertTrue(edited)
        try await model.pasteRSSURL(strings: ["https://example.com/edited.xml"]).value
        original.refresh()
        replacement.refresh()
        XCTAssertEqual(originalFeed.rssUrl.absoluteString, "https://example.com/edited.xml")
        XCTAssertEqual(model.feedURL, "https://example.com/edited.xml")
        XCTAssertEqual(replacementFeed.title, "Replacement")
        XCTAssertEqual(replacementFeed.rssUrl.absoluteString, "https://example.com/original.xml")
        XCTAssertTrue(replacement.objects(BigSyncPendingMutation.self).isEmpty)
        XCTAssertFalse(original.objects(BigSyncPendingMutation.self).isEmpty)
    }

    func testFeedWriterRechecksCurrentCategoryAndDeletionBeforeMutating() async throws {
        let realm = try await Realm(configuration: configuration())
        let categoryID = UUID()
        let feed = try installFeed(id: UUID(), categoryID: categoryID, title: "Original", in: realm)
        let model = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false)
        let category = try XCTUnwrap(realm.object(ofType: FeedCategory.self, forPrimaryKey: categoryID))
        let pending = model.pasteRSSURL(strings: ["https://example.com/blocked.xml"])
        try realm.write { category.opmlURL = URL(string: "https://example.com/managed.opml") }
        try await pending.value
        realm.refresh()
        XCTAssertEqual(feed.rssUrl.absoluteString, "https://example.com/original.xml")
        XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
        try realm.write { category.opmlURL = nil; category.isDeleted = true }
        XCTAssertFalse(feed.isUserEditable())
        try await model.pasteRSSURL(strings: ["https://example.com/deleted-category.xml"]).value
        try realm.write { realm.delete(category) }
        XCTAssertFalse(feed.isUserEditable())
        try await model.pasteRSSURL(strings: ["https://example.com/missing-category.xml"]).value
        let freshCategory = FeedCategory()
        freshCategory.id = categoryID
        try realm.write { realm.add(freshCategory); feed.isDeleted = true }
        try await model.pasteRSSURL(strings: ["https://example.com/deleted-feed.xml"]).value
        realm.refresh()
        XCTAssertEqual(feed.rssUrl.absoluteString, "https://example.com/original.xml")
        XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
    }

    func testFeedHydrationAndNoOpPasteLeaveJournalGenerationStable() async throws {
        let realm = try await Realm(configuration: configuration())
        let feed = try installFeed(id: UUID(), categoryID: UUID(), title: "Original", in: realm)
        let model = LibraryFeedFormSectionsViewModel(feed: feed)
        let initialized = await waitUntil { model.hasInitializedValues }
        XCTAssertTrue(initialized)
        try await model.pasteRSSURL(strings: [feed.rssUrl.absoluteString]).value
        realm.refresh()
        XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
        try await model.pasteRSSURL(strings: ["https://example.com/changed.xml"]).value
        realm.refresh()
        let generations = journalGenerations(in: realm)
        XCTAssertEqual(generations.count, 1)
        model.refresh()
        try await model.pasteRSSURL(strings: ["https://example.com/changed.xml"]).value
        // Await the same serialized writer lane after a complete debounce window.
        try await Task.sleep(for: .milliseconds(500))
        try await model.writeFeedAsync { _ in false }.value
        realm.refresh()
        XCTAssertEqual(journalGenerations(in: realm), generations)
    }

    func testLibraryButtonObserversKeepTheirPublishedRealmAfterReplacement() async throws {
        let originalConfiguration = configuration()
        let original = try await Realm(configuration: originalConfiguration)
        let replacementConfiguration = configuration()
        let replacement = try await Realm(configuration: replacementConfiguration)
        let categoryID = UUID()
        let feedID = UUID()
        let originalFeed = try installFeed(id: feedID, categoryID: categoryID, title: "Original", in: original)
        _ = try installFeed(id: feedID, categoryID: categoryID, title: "Replacement", in: replacement)
        let libraryID = UUID()
        for realm in [original, replacement] {
            let library = LibraryConfiguration()
            library.id = libraryID
            library.categoryIDs.append(categoryID)
            try realm.write { realm.add(library) }
        }
        let previous = LibraryDataManager.realmConfiguration
        defer { LibraryDataManager.realmConfiguration = previous }
        LibraryDataManager.realmConfiguration = originalConfiguration
        let webFeedState = WebFeedButtonLibraryState(realmConfiguration: originalConfiguration)
        let categoryState = ContentCategoryButtonsViewModel(realmConfiguration: originalConfiguration)
        webFeedState.startIfNeeded()
        let observed = await waitUntil {
            webFeedState.feed(matching: [originalFeed.rssUrl])?.title == "Original"
                && categoryState.libraryConfiguration != nil
        }
        XCTAssertTrue(observed)
        LibraryDataManager.realmConfiguration = replacementConfiguration
        try await Task { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: originalConfiguration)
            try await realm.asyncWrite {
                let feed = try XCTUnwrap(realm.object(ofType: Feed.self, forPrimaryKey: feedID))
                feed.title = "Updated original"
                feed.refreshChangeMetadata(explicitlyModified: true)
                let category = try XCTUnwrap(realm.object(ofType: FeedCategory.self, forPrimaryKey: categoryID))
                category.title = "Updated original category"
                category.refreshChangeMetadata(explicitlyModified: true)
                let library = try XCTUnwrap(realm.object(ofType: LibraryConfiguration.self, forPrimaryKey: libraryID))
                library.refreshChangeMetadata(explicitlyModified: true)
            }
        }.value
        let updated = await waitUntil {
            webFeedState.feed(matching: [originalFeed.rssUrl])?.title == "Updated original"
                && webFeedState.userCategories?.first?.title == "Updated original category"
                && categoryState.libraryConfiguration?.getCategories()?.first?.title == "Updated original category"
        }
        XCTAssertTrue(updated)
        replacement.refresh()
        XCTAssertEqual(replacement.object(ofType: Feed.self, forPrimaryKey: feedID)?.title, "Replacement")
        XCTAssertTrue(replacement.objects(BigSyncPendingMutation.self).isEmpty)
    }

    func testFeedFieldCanReturnToEarlierUserValueAfterHydration() async throws {
        let realm = try await Realm(configuration: configuration())
        let feed = try installFeed(id: UUID(), categoryID: UUID(), title: "Original", in: realm)
        let model = LibraryFeedFormSectionsViewModel(feed: feed)
        let initialized = await waitUntil { model.hasInitializedValues }
        XCTAssertTrue(initialized)
        model.feedTitle = "User value"
        let first = await waitUntil { realm.refresh(); return feed.title == "User value" }
        XCTAssertTrue(first)
        try realm.write { feed.title = "Hydrated value" }
        model.refresh()
        model.feedTitle = "User value"
        let second = await waitUntil { realm.refresh(); return feed.title == "User value" }
        XCTAssertTrue(second)
    }

    func testFeedPasteReplacesBufferedOlderURLWithoutLaterJournalRefresh() async throws {
        let realm = try await Realm(configuration: configuration())
        let feed = try installFeed(id: UUID(), categoryID: UUID(), title: "Original", in: realm)
        let model = LibraryFeedFormSectionsViewModel(feed: feed)
        let initialized = await waitUntil { model.hasInitializedValues }
        XCTAssertTrue(initialized)
        model.feedURL = "https://example.com/leading.xml"
        model.feedURL = "https://example.com/buffered.xml"
        try await model.pasteRSSURL(strings: ["https://example.com/pasted.xml"]).value
        realm.refresh()
        XCTAssertEqual(feed.rssUrl.absoluteString, "https://example.com/pasted.xml")
        let generations = journalGenerations(in: realm)
        try await Task.sleep(for: .milliseconds(500))
        try await model.writeFeedAsync { _ in false }.value
        realm.refresh()
        XCTAssertEqual(feed.rssUrl.absoluteString, "https://example.com/pasted.xml")
        XCTAssertEqual(model.feedURL, "https://example.com/pasted.xml")
        XCTAssertEqual(journalGenerations(in: realm), generations)
    }

    func testNewerNoOpFeedEditRejectsOlderWriterAfterItResumes() async throws {
        let realm = try await Realm(configuration: configuration())
        let feed = try installFeed(id: UUID(), categoryID: UUID(), title: "Current", in: realm)
        let model = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false)
        let suspended = expectation(description: "Older writer suspended before its write turn")
        let gate = FeedEditorWriteGate()
        let older = model.writeFeedAsync(field: .title, beforeWrite: {
            suspended.fulfill()
            await gate.wait()
        }) { feed in
            feed.title = "Obsolete"
            return true
        }
        defer { older.cancel(); Task { await gate.release() } }
        await fulfillment(of: [suspended], timeout: 5)
        let before = journalGenerations(in: realm)
        try await model.writeFeedAsync(field: .title) { feed in
            guard feed.title != "Current" else { return false }
            feed.title = "Current"
            return true
        }.value
        await gate.release()
        try await older.value
        realm.refresh()
        XCTAssertEqual(feed.title, "Current")
        XCTAssertEqual(journalGenerations(in: realm), before)
    }

    func testDelayedMetadataPreservesBufferedUserInputsWithoutJournaling() async throws {
        let realm = try await Realm(configuration: configuration())
        let feed = try installFeed(id: UUID(), categoryID: UUID(), title: "", in: realm)
        let model = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false)
        let generation = UUID()
        model.beginMetadataRefresh(rssURL: feed.rssUrl, identifier: generation)
        let suspended = expectation(description: "Metadata I/O suspended")
        let gate = FeedEditorWriteGate()
        let metadata = Task { @MainActor in
            await model.refreshFromOpenGraph(expectedRSSURL: feed.rssUrl, expectedGeneration: generation) { _ in
                suspended.fulfill()
                await gate.wait()
                return LibraryFeedOpenGraphMetadata(
                    url: URL(string: "https://example.com/"), title: "Suggested", description: "Suggested description"
                )
            }
        }
        defer { metadata.cancel(); Task { await gate.release() } }
        await fulfillment(of: [suspended], timeout: 5)
        // Uncommitted published input is precisely the state that a persisted
        // field check alone misses. Observation is disabled to retain that state
        // deterministically, without racing a wall-clock debounce.
        model.feedTitle = "Buffered title"
        model.feedDescription = "Buffered description"
        let before = journalGenerations(in: realm)
        await gate.release()
        await metadata.value
        realm.refresh()
        XCTAssertEqual(model.feedTitle, "Buffered title")
        XCTAssertEqual(model.feedDescription, "Buffered description")
        XCTAssertEqual(feed.title, "")
        XCTAssertNil(feed.markdownDescription)
        XCTAssertEqual(journalGenerations(in: realm), before)
    }

    func testDelayedMetadataPreservesCommittedUserInputsAndJournalGenerations() async throws {
        let realm = try await Realm(configuration: configuration())
        let feed = try installFeed(id: UUID(), categoryID: UUID(), title: "", in: realm)
        let model = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false)
        let generation = UUID()
        model.beginMetadataRefresh(rssURL: feed.rssUrl, identifier: generation)
        let suspended = expectation(description: "Metadata I/O suspended")
        let gate = FeedEditorWriteGate()
        let metadata = Task { @MainActor in
            await model.refreshFromOpenGraph(expectedRSSURL: feed.rssUrl, expectedGeneration: generation) { _ in
                suspended.fulfill()
                await gate.wait()
                return LibraryFeedOpenGraphMetadata(
                    url: URL(string: "https://example.com/"), title: "Suggested", description: "Suggested description"
                )
            }
        }
        defer { metadata.cancel(); Task { await gate.release() } }
        await fulfillment(of: [suspended], timeout: 5)
        model.feedTitle = "User title"
        model.feedDescription = "User description"
        try await model.writeFeedAsync(field: .title) { feed in
            feed.title = "User title"
            return true
        }.value
        try await model.writeFeedAsync(field: .description) { feed in
            feed.markdownDescription = "User description"
            return true
        }.value
        realm.refresh()
        let before = journalGenerations(in: realm)
        await gate.release()
        await metadata.value
        realm.refresh()
        XCTAssertEqual(feed.title, "User title")
        XCTAssertEqual(feed.markdownDescription, "User description")
        XCTAssertEqual(model.feedTitle, "User title")
        XCTAssertEqual(model.feedDescription, "User description")
        XCTAssertEqual(journalGenerations(in: realm), before)
    }

    func testMetadataFinalWriteRejectsChangedPublishedAndPersistedFields() async throws {
        for committed in [false, true] {
            for field in [LibraryFeedEditorField.title, .description, .iconURL] {
                let realm = try await Realm(configuration: configuration())
                let feed = try installFeed(id: UUID(), categoryID: UUID(), title: "", in: realm)
                let model = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false)
                let generation = UUID()
                model.beginMetadataRefresh(rssURL: feed.rssUrl, identifier: generation)
                let suspended = expectation(description: "Metadata final writer suspended")
                let gate = FeedEditorWriteGate()
                let metadata = Task { @MainActor in
                    let beforeWrite: @RealmBackgroundActor @Sendable () async -> Void = {
                        suspended.fulfill()
                        await gate.wait()
                    }
                    if field == .iconURL {
                        await model.refreshIcon(
                            expectedRSSURL: feed.rssUrl, expectedGeneration: generation, beforeWrite: beforeWrite
                        ) { _ in URL(string: "https://example.com/suggested.png")! }
                    } else {
                        await model.refreshFromOpenGraph(
                            expectedRSSURL: feed.rssUrl, expectedGeneration: generation, beforeWrite: beforeWrite
                        ) { _ in
                            LibraryFeedOpenGraphMetadata(
                                url: URL(string: "https://example.com/"),
                                title: field == .title ? "Suggested" : nil,
                                description: field == .description ? "Suggested description" : nil
                            )
                        }
                    }
                }
                defer { metadata.cancel(); Task { await gate.release() } }
                await fulfillment(of: [suspended], timeout: 5)
                if committed {
                    // Change only persisted state, without model hydration, so
                    // rejection must come from the final transaction's guard.
                    try realm.write {
                        switch field {
                        case .title: feed.title = "User title"
                        case .description: feed.markdownDescription = "User description"
                        case .iconURL: feed.iconUrl = URL(string: "https://example.com/user.png")!
                        default: break
                        }
                        feed.refreshChangeMetadata(explicitlyModified: true)
                    }
                } else {
                    switch field {
                    case .title: model.feedTitle = "Buffered title"
                    case .description: model.feedDescription = "Buffered description"
                    case .iconURL: model.feedIconURL = "https://example.com/buffered.png"
                    default: break
                    }
                }
                realm.refresh()
                let before = journalGenerations(in: realm)
                let title = feed.title
                let description = feed.markdownDescription
                let iconURL = feed.iconUrl
                await gate.release()
                await metadata.value
                realm.refresh()
                XCTAssertEqual(feed.title, title)
                XCTAssertEqual(feed.markdownDescription, description)
                XCTAssertEqual(feed.iconUrl, iconURL)
                XCTAssertEqual(journalGenerations(in: realm), before)
                if !committed {
                    switch field {
                    case .title: XCTAssertEqual(model.feedTitle, "Buffered title")
                    case .description: XCTAssertEqual(model.feedDescription, "Buffered description")
                    case .iconURL: XCTAssertEqual(model.feedIconURL, "https://example.com/buffered.png")
                    default: break
                    }
                }
            }
        }
    }

    func testDelayedIconPreservesBufferedUserInputWithoutJournaling() async throws {
        let realm = try await Realm(configuration: configuration())
        let feed = try installFeed(id: UUID(), categoryID: UUID(), title: "", in: realm)
        let model = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false)
        let generation = UUID()
        model.beginMetadataRefresh(rssURL: feed.rssUrl, identifier: generation)
        let suspended = expectation(description: "Icon I/O suspended")
        let gate = FeedEditorWriteGate()
        let metadata = Task { @MainActor in
            await model.refreshIcon(expectedRSSURL: feed.rssUrl, expectedGeneration: generation) { _ in
                suspended.fulfill()
                await gate.wait()
                return URL(string: "https://example.com/suggested.png")!
            }
        }
        defer { metadata.cancel(); Task { await gate.release() } }
        await fulfillment(of: [suspended], timeout: 5)
        model.feedIconURL = "https://example.com/buffered.png"
        let before = journalGenerations(in: realm)
        await gate.release()
        await metadata.value
        realm.refresh()
        XCTAssertEqual(model.feedIconURL, "https://example.com/buffered.png")
        XCTAssertEqual(feed.iconUrl.absoluteString, "about:blank")
        XCTAssertEqual(journalGenerations(in: realm), before)
    }

    func testCurrentMetadataFillsEmptyFieldsAndRepeatedCompletionDoesNotJournal() async throws {
        let realm = try await Realm(configuration: configuration())
        let feed = try installFeed(id: UUID(), categoryID: UUID(), title: "", in: realm)
        let model = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false)
        let generation = UUID()
        model.beginMetadataRefresh(rssURL: feed.rssUrl, identifier: generation)
        let fetch: @Sendable (URL) async throws -> LibraryFeedOpenGraphMetadata = { _ in
            LibraryFeedOpenGraphMetadata(
                url: URL(string: "https://example.com/"), title: "Suggested", description: "Suggested description"
            )
        }
        await model.refreshFromOpenGraph(expectedRSSURL: feed.rssUrl, expectedGeneration: generation, fetch: fetch)
        await model.refreshIcon(expectedRSSURL: feed.rssUrl, expectedGeneration: generation) { _ in
            URL(string: "https://example.com/suggested.png")!
        }
        realm.refresh()
        XCTAssertEqual(feed.title, "Suggested")
        XCTAssertEqual(feed.markdownDescription, "Suggested description")
        XCTAssertEqual(feed.iconUrl.absoluteString, "https://example.com/suggested.png")
        XCTAssertEqual(model.feedTitle, "Suggested")
        XCTAssertEqual(model.feedDescription, "Suggested description")
        XCTAssertEqual(model.feedIconURL, "https://example.com/suggested.png")
        let before = journalGenerations(in: realm)
        XCTAssertEqual(before.count, 1)
        await model.refreshFromOpenGraph(expectedRSSURL: feed.rssUrl, expectedGeneration: generation, fetch: fetch)
        await model.refreshIcon(expectedRSSURL: feed.rssUrl, expectedGeneration: generation) { _ in
            URL(string: "https://example.com/suggested.png")!
        }
        realm.refresh()
        XCTAssertEqual(journalGenerations(in: realm), before)
    }

    func testSupersededMetadataRequestCannotApplyLateCompletion() async throws {
        let realm = try await Realm(configuration: configuration())
        let feed = try installFeed(id: UUID(), categoryID: UUID(), title: "", in: realm)
        let model = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false)
        let generation = UUID()
        model.beginMetadataRefresh(rssURL: feed.rssUrl, identifier: generation)
        let suspended = expectation(description: "Superseded request suspended")
        let gate = FeedEditorWriteGate()
        let metadata = Task { @MainActor in
            await model.refreshFromOpenGraph(expectedRSSURL: feed.rssUrl, expectedGeneration: generation) { _ in
                suspended.fulfill()
                await gate.wait()
                return LibraryFeedOpenGraphMetadata(
                    url: URL(string: "https://example.com/"), title: "Obsolete", description: "Obsolete"
                )
            }
        }
        defer { metadata.cancel(); Task { await gate.release() } }
        await fulfillment(of: [suspended], timeout: 5)
        model.beginMetadataRefresh(rssURL: feed.rssUrl, identifier: UUID())
        await gate.release()
        await metadata.value
        realm.refresh()
        XCTAssertEqual(feed.title, "")
        XCTAssertNil(feed.markdownDescription)
        XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
    }

    func testMetadataFinalWriterRejectsCancellationSupersessionAndNewerEmptyInput() async throws {
        for rejection in ["cancelled", "superseded", "newer empty input"] {
            let realm = try await Realm(configuration: configuration())
            let feed = try installFeed(id: UUID(), categoryID: UUID(), title: "", in: realm)
            let model = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false)
            let generation = UUID()
            model.beginMetadataRefresh(rssURL: feed.rssUrl, identifier: generation)
            let suspended = expectation(description: "Final metadata writer suspended before rejection")
            let gate = FeedEditorWriteGate()
            let metadata = Task { @MainActor in
                await model.refreshFromOpenGraph(
                    expectedRSSURL: feed.rssUrl, expectedGeneration: generation,
                    beforeWrite: {
                        suspended.fulfill()
                        await gate.wait()
                    }
                ) { _ in
                    LibraryFeedOpenGraphMetadata(
                        url: URL(string: "https://example.com/"), title: "Obsolete", description: nil
                    )
                }
            }
            defer { metadata.cancel(); Task { await gate.release() } }
            await fulfillment(of: [suspended], timeout: 5)
            switch rejection {
            case "cancelled": metadata.cancel()
            case "superseded": model.beginMetadataRefresh(rssURL: feed.rssUrl, identifier: UUID())
            default: model.feedTitle = ""
            }
            await gate.release()
            await metadata.value
            realm.refresh()
            XCTAssertEqual(feed.title, "", rejection)
            XCTAssertEqual(model.feedTitle, "", rejection)
            XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty, rejection)
        }
    }

    func testFeedPreviewEntriesResolveInOriginatingRealmAfterReplacement() throws {
        let originalConfiguration = configuration()
        let replacementConfiguration = configuration()
        let original = try Realm(configuration: originalConfiguration)
        let replacement = try Realm(configuration: replacementConfiguration)
        let feedID = UUID()
        let categoryID = UUID()
        let feed = try installFeed(id: feedID, categoryID: categoryID, title: "Original", in: original)
        _ = try installFeed(id: feedID, categoryID: categoryID, title: "Replacement", in: replacement)
        for (realm, title) in [(original, "Original entry"), (replacement, "Replacement entry")] {
            let entry = FeedEntry()
            entry.feedID = feedID
            entry.compoundKey = "shared-entry-key"
            entry.url = URL(string: "https://example.com/entry")!
            entry.title = title
            try realm.write { realm.add(entry) }
        }
        let model = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false)
        let previousLibrary = LibraryDataManager.realmConfiguration
        let previousPreview = ReaderContentLoader.feedEntryRealmConfiguration
        defer {
            LibraryDataManager.realmConfiguration = previousLibrary
            ReaderContentLoader.feedEntryRealmConfiguration = previousPreview
        }
        LibraryDataManager.realmConfiguration = replacementConfiguration
        ReaderContentLoader.feedEntryRealmConfiguration = replacementConfiguration
        let entries = try XCTUnwrap(model.previewEntries())
        XCTAssertEqual(entries.map(\.title), ["Original entry"])
        XCTAssertEqual(entries.first?.realm?.configuration.inMemoryIdentifier, originalConfiguration.inMemoryIdentifier)
        XCTAssertTrue(original.objects(BigSyncPendingMutation.self).isEmpty)
        XCTAssertTrue(replacement.objects(BigSyncPendingMutation.self).isEmpty)
    }

    func testMetadataAndWriterCompletionAfterFeedInvalidationDoNotAccessDeletedObject() async throws {
        for boundary in ["metadata I/O", "icon I/O", "final writer"] {
            let realm = try await Realm(configuration: configuration())
            let feed = try installFeed(id: UUID(), categoryID: UUID(), title: "", in: realm)
            let model = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false)
            let rssURL = feed.rssUrl
            let generation = UUID()
            model.beginMetadataRefresh(rssURL: rssURL, identifier: generation)
            let suspended = expectation(description: "Completion suspended before feed invalidation")
            let gate = FeedEditorWriteGate()
            let metadata = Task { @MainActor in
                if boundary == "icon I/O" {
                    await model.refreshIcon(expectedRSSURL: rssURL, expectedGeneration: generation) { _ in
                        suspended.fulfill()
                        await gate.wait()
                        return URL(string: "https://example.com/suggested.png")!
                    }
                } else {
                    var beforeWrite: (@RealmBackgroundActor @Sendable () async -> Void)?
                    if boundary == "final writer" {
                        beforeWrite = { suspended.fulfill(); await gate.wait() }
                    }
                    await model.refreshFromOpenGraph(
                        expectedRSSURL: rssURL, expectedGeneration: generation, beforeWrite: beforeWrite
                    ) { _ in
                        if boundary == "metadata I/O" {
                            suspended.fulfill()
                            await gate.wait()
                        }
                        return LibraryFeedOpenGraphMetadata(
                            url: URL(string: "https://example.com/"), title: "Obsolete", description: nil
                        )
                    }
                }
            }
            defer { metadata.cancel(); Task { await gate.release() } }
            await fulfillment(of: [suspended], timeout: 5)
            try realm.write { realm.delete(feed) }
            XCTAssertTrue(feed.isInvalidated)
            await gate.release()
            await metadata.value
            XCTAssertNil(try model.previewEntries())
            try await model.writeFeedAsync { _ in
                XCTFail("An invalidated editor must not mutate a missing record")
                return false
            }.value
            realm.refresh()
            XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty, boundary)
        }
    }

    func testReaderScriptSnapshotRejectsOlderDeliveryWithoutRepublishingUnchangedScripts() {
        let reader = ReaderViewModel(realmConfiguration: configuration(), systemScripts: [])
        let older = UserScriptSnapshot(
            source: "window.oldScript = true;", injectionTime: .atDocumentStart,
            isForMainFrameOnly: true, worldName: "older-world", allowedDomains: []
        )
        let current = UserScriptSnapshot(
            source: "window.currentScript = true;", injectionTime: .atDocumentEnd,
            isForMainFrameOnly: true, worldName: "current-world", allowedDomains: ["current.example.com"]
        )
        var publications = 0
        let observation = reader.$webViewUserScripts.dropFirst().sink { _ in publications += 1 }
        defer { observation.cancel() }
        reader.applyUserScriptSnapshot([current], revision: 2)
        reader.applyUserScriptSnapshot([older], revision: 1)
        XCTAssertEqual(reader.webViewUserScripts.map(\.source), [current.source])
        XCTAssertEqual(publications, 1)

        reader.applyUserScriptSnapshot([current], revision: 4)
        reader.applyUserScriptSnapshot([older], revision: 3)
        XCTAssertEqual(reader.webViewUserScripts.map(\.source), [current.source],
                       "An unchanged newer snapshot still fences delayed older delivery")
        XCTAssertEqual(publications, 1, "Unchanged snapshots must not reinstall user scripts")
        reader.applyUserScriptSnapshot([], revision: 5)
        reader.applyUserScriptSnapshot([older], revision: 4)
        XCTAssertTrue(reader.webViewUserScripts.isEmpty,
                      "A delayed script must not reappear after a newer empty snapshot")
        XCTAssertEqual(publications, 2)
    }

    func testReaderPreviewScriptObservationUsesCapturedConfigurationBeforeAndAfterReplacement() async throws {
        for usesExplicitConfiguration in [true, false] {
            let originalConfiguration = configuration()
            let replacementConfiguration = configuration()
            let original = try await Realm(configuration: originalConfiguration)
            let replacement = try await Realm(configuration: replacementConfiguration)
            let scriptID = UUID()
            let libraryID = UUID()
            for (realm, source) in [(original, "window.origin = 'captured';"), (replacement, "window.origin = 'replacement';")] {
                let script = UserScript()
                script.id = scriptID
                script.script = source
                let library = LibraryConfiguration()
                library.id = libraryID
                library.userScriptIDs.append(scriptID)
                try realm.write { realm.add(script); realm.add(library) }
            }
            let previous = LibraryDataManager.realmConfiguration
            defer { LibraryDataManager.realmConfiguration = previous }
            LibraryDataManager.realmConfiguration = originalConfiguration
            let reader = usesExplicitConfiguration
                ? ReaderViewModel(realmConfiguration: originalConfiguration, systemScripts: [])
                : ReaderViewModel(systemScripts: [])
            // Replace the global before the model's asynchronous observer setup.
            LibraryDataManager.realmConfiguration = replacementConfiguration
            let initial = await waitUntil {
                reader.allScripts.contains { $0.source == "window.origin = 'captured';" }
            }
            XCTAssertTrue(initial)
            XCTAssertFalse(reader.allScripts.contains { $0.source == "window.origin = 'replacement';" })
            try await Task { @RealmBackgroundActor in
                let realm = try await RealmBackgroundActor.shared.cachedRealm(for: originalConfiguration)
                try await realm.asyncWrite {
                    let script = try XCTUnwrap(realm.object(ofType: UserScript.self, forPrimaryKey: scriptID))
                    script.script = "window.origin = 'updated captured';"
                    script.refreshChangeMetadata(explicitlyModified: true)
                }
            }.value
            let updated = await waitUntil {
                reader.allScripts.contains { $0.source == "window.origin = 'updated captured';" }
            }
            XCTAssertTrue(updated)
            XCTAssertFalse(reader.allScripts.contains { $0.source == "window.origin = 'replacement';" })
            replacement.refresh()
            XCTAssertTrue(replacement.objects(BigSyncPendingMutation.self).isEmpty)
        }
    }

    func testReaderScriptRefreshPreservesOrderAndTracksExecutableMetadata() async throws {
        let config = configuration()
        let realm = try await Realm(configuration: config)
        let library = LibraryConfiguration()
        let domain = UserScriptAllowedDomain()
        domain.domain = "example.com"
        let replacementDomain = UserScriptAllowedDomain()
        replacementDomain.domain = "other.example.com"
        let first = UserScript()
        first.script = "window.firstReaderScript = true;"
        first.allowedDomainIDs.append(domain.id)
        let second = UserScript()
        second.script = "window.secondReaderScript = true;"
        library.userScriptIDs.append(objectsIn: [first.id, second.id])
        try realm.write {
            realm.add(library)
            realm.add(first)
            realm.add(second)
            realm.add(domain)
            realm.add(replacementDomain)
            library.refreshChangeMetadata(explicitlyModified: true)
            first.refreshChangeMetadata(explicitlyModified: true)
            second.refreshChangeMetadata(explicitlyModified: true)
            domain.refreshChangeMetadata(explicitlyModified: true)
            replacementDomain.refreshChangeMetadata(explicitlyModified: true)
        }
        let appScript = WebViewUserScript(
            source: "window.appReaderScript = true;", injectionTime: .atDocumentStart,
            forMainFrameOnly: true, in: .page
        )
        let reader = ReaderViewModel(realmConfiguration: config, systemScripts: [appScript])
        XCTAssertTrue(reader.allScripts.contains(appScript))
        XCTAssertEqual(
            reader.webViewSystemScripts,
            [appScript] + LibraryConfiguration.bundledSystemScripts,
            "Bundled document-start scripts must exist before asynchronous Realm delivery"
        )
        var initialSystemPublications = 0
        let initialSystemObservation = reader.$webViewSystemScripts.dropFirst().sink { _ in
            initialSystemPublications += 1
        }
        defer { initialSystemObservation.cancel() }
        let initiallyLoaded = await waitUntil {
            Array(reader.allScripts.suffix(2)).map(\.source) == [first.script, second.script]
        }
        XCTAssertTrue(initiallyLoaded)
        XCTAssertEqual(initialSystemPublications, 0, "Realm hydration must not reinstall bundled scripts")
        let appIndex = try XCTUnwrap(reader.allScripts.firstIndex(of: appScript))
        let bundledIndex = try XCTUnwrap(reader.allScripts.firstIndex(of: LibraryConfiguration.bundledSystemScripts[0]))
        let userIndex = try XCTUnwrap(reader.allScripts.firstIndex { $0.source == first.script })
        XCTAssertLessThan(appIndex, bundledIndex)
        XCTAssertLessThan(bundledIndex, userIndex)

        var userPublications = 0
        var systemPublications = 0
        let userObservation = reader.$webViewUserScripts.dropFirst().sink { _ in userPublications += 1 }
        let systemObservation = reader.$webViewSystemScripts.dropFirst().sink { _ in systemPublications += 1 }
        defer { userObservation.cancel(); systemObservation.cancel() }
        try realm.write {
            first.title = "Non-executable metadata"
            first.refreshChangeMetadata(explicitlyModified: true)
        }
        let updatedSource = "window.updatedReaderScript = true;"
        try realm.write {
            first.script = updatedSource
            first.injectAtStart = false
            first.mainFrameOnly = false
            first.allowedDomainIDs.removeAll()
            first.allowedDomainIDs.append(replacementDomain.id)
            first.refreshChangeMetadata(explicitlyModified: true)
        }
        let updated = await waitUntil {
            reader.allScripts.contains {
                $0.source == updatedSource && $0.injectionTime == .atDocumentEnd
                    && !$0.isForMainFrameOnly && $0.allowedDomains == [replacementDomain.domain]
            }
        }
        XCTAssertTrue(updated)
        XCTAssertEqual(userPublications, 1, "Identical snapshots must not republish the script list")
        XCTAssertEqual(systemPublications, 0, "User-script changes must not republish bundled scripts")

        realm.refresh()
        try realm.write {
            library.userScriptIDs.removeAll()
            library.userScriptIDs.append(objectsIn: [second.id, first.id])
            library.refreshChangeMetadata(explicitlyModified: true)
        }
        let reordered = await waitUntil {
            Array(reader.allScripts.suffix(2)).map(\.source) == [second.script, updatedSource]
        }
        XCTAssertTrue(reordered)
        try realm.write {
            second.isArchived = true
            second.refreshChangeMetadata(explicitlyModified: true)
        }
        let archived = await waitUntil {
            !reader.allScripts.contains { $0.source == second.script }
                && reader.allScripts.contains { $0.source == updatedSource }
        }
        XCTAssertTrue(archived)
        try realm.write {
            first.isDeleted = true
            first.refreshChangeMetadata(explicitlyModified: true)
        }
        let deleted = await waitUntil { reader.webViewUserScripts.isEmpty }
        XCTAssertTrue(deleted)
        XCTAssertTrue(reader.allScripts.contains(appScript))
    }

    func testReaderScriptRefreshTracksIndependentDomainChanges() async throws {
        let config = configuration()
        let realm = try await Realm(configuration: config)
        let library = LibraryConfiguration()
        let script = UserScript()
        script.script = "window.domainOnlyRefresh = true;"
        let domain = UserScriptAllowedDomain()
        domain.domain = "initial.example.com"
        let arrivingDomain = UserScriptAllowedDomain()
        arrivingDomain.domain = "arriving.example.com"
        script.allowedDomainIDs.append(objectsIn: [domain.id, arrivingDomain.id])
        library.userScriptIDs.append(script.id)
        try realm.write {
            realm.add(library)
            realm.add(script)
            realm.add(domain)
            library.refreshChangeMetadata(explicitlyModified: true)
            script.refreshChangeMetadata(explicitlyModified: true)
            domain.refreshChangeMetadata(explicitlyModified: true)
        }
        let reader = ReaderViewModel(realmConfiguration: config, systemScripts: [])
        let loaded = await waitUntil {
            reader.webViewUserScripts.first?.allowedDomains == ["initial.example.com"]
        }
        XCTAssertTrue(loaded)
        try realm.write {
            domain.domain = "renamed.example.com"
            domain.refreshChangeMetadata(explicitlyModified: true)
        }
        let renamed = await waitUntil {
            reader.webViewUserScripts.first?.allowedDomains == ["renamed.example.com"]
        }
        XCTAssertTrue(renamed, "Editing only the domain must refresh filtering")
        try realm.write {
            realm.add(arrivingDomain)
            arrivingDomain.refreshChangeMetadata(explicitlyModified: true)
        }
        let arrived = await waitUntil {
            reader.webViewUserScripts.first?.allowedDomains == ["renamed.example.com", "arriving.example.com"]
        }
        XCTAssertTrue(arrived, "A separately arriving domain must resolve without editing its script")
        try realm.write {
            domain.isDeleted = true
            domain.refreshChangeMetadata(explicitlyModified: true)
        }
        let deleted = await waitUntil {
            reader.webViewUserScripts.first?.allowedDomains == ["arriving.example.com"]
        }
        XCTAssertTrue(deleted)
        try realm.write {
            domain.isDeleted = false
            domain.refreshChangeMetadata(explicitlyModified: true)
        }
        let restored = await waitUntil {
            reader.webViewUserScripts.first?.allowedDomains == ["renamed.example.com", "arriving.example.com"]
        }
        XCTAssertTrue(restored)

        try realm.write {
            domain.isDeleted = true
            arrivingDomain.isDeleted = true
            domain.refreshChangeMetadata(explicitlyModified: true)
            arrivingDomain.refreshChangeMetadata(explicitlyModified: true)
        }
        let withheld = await waitUntil { reader.webViewUserScripts.isEmpty }
        XCTAssertTrue(withheld, "Losing all configured domain rows must not make a script global")
        try realm.write {
            script.allowedDomainIDs.removeAll()
            script.refreshChangeMetadata(explicitlyModified: true)
        }
        let explicitlyGlobal = await waitUntil {
            reader.webViewUserScripts.count == 1
                && reader.webViewUserScripts.first?.allowedDomains.isEmpty == true
        }
        XCTAssertTrue(explicitlyGlobal, "An explicitly empty domain list still means all sites")
        try realm.write {
            script.allowedDomainIDs.append(UUID())
            script.refreshChangeMetadata(explicitlyModified: true)
        }
        let missing = await waitUntil { reader.webViewUserScripts.isEmpty }
        XCTAssertTrue(missing, "An unresolved domain reference must not make a script global")
    }

    func testViewMetadataDelayRejectsInvalidationCancellationAndSupersessionBeforeIO() async throws {
        for rejection in ["invalidated", "cancelled", "superseded"] {
            let realm = try await Realm(configuration: configuration())
            let feed = try installFeed(id: UUID(), categoryID: UUID(), title: "", in: realm)
            let model = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false)
            let rssURL = feed.rssUrl
            let generation = UUID()
            model.beginMetadataRefresh(rssURL: rssURL, identifier: generation)
            let suspended = expectation(description: "Actual form metadata delay suspended")
            let gate = FeedEditorWriteGate()
            let scheduled = Task { @MainActor in
                await model.refreshMetadataAfterDelay(
                    expectedRSSURL: rssURL, expectedGeneration: generation,
                    delay: {
                        suspended.fulfill()
                        await gate.wait()
                    },
                    performRefresh: {
                        XCTFail("Rejected form delay must not start refresh I/O")
                    }
                )
            }
            defer { scheduled.cancel(); Task { await gate.release() } }
            await fulfillment(of: [suspended], timeout: 5)
            switch rejection {
            case "invalidated": try realm.write { realm.delete(feed) }
            case "cancelled": scheduled.cancel()
            default: model.beginMetadataRefresh(rssURL: rssURL, identifier: UUID())
            }
            await gate.release()
            await scheduled.value
            XCTAssertEqual(model.feedTitle, "")
            XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty, rejection)
            if rejection == "invalidated" {
                XCTAssertNil(model.currentRSSURL)
                XCTAssertNil(try model.previewEntries())
            }
        }
    }

    func testRSSPasteCompletionPreservesOtherPublishedFieldDrafts() async throws {
        let realm = try await Realm(configuration: configuration())
        let feed = try installFeed(id: UUID(), categoryID: UUID(), title: "Persisted", in: realm)
        let model = LibraryFeedFormSectionsViewModel(feed: feed, observesRealm: false)
        model.feedTitle = "Pending title"
        model.feedDescription = "Pending description"
        model.feedIconURL = "https://example.com/pending.png"
        try await model.pasteRSSURL(strings: ["https://example.com/new.xml"]).value
        realm.refresh()
        XCTAssertEqual(model.feedURL, "https://example.com/new.xml")
        XCTAssertEqual(model.feedTitle, "Pending title")
        XCTAssertEqual(model.feedDescription, "Pending description")
        XCTAssertEqual(model.feedIconURL, "https://example.com/pending.png")
        XCTAssertEqual(feed.title, "Persisted")
        XCTAssertNil(feed.markdownDescription)
    }

    private func configuration() -> Realm.Configuration {
        var result = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        result.objectTypes = [
            LibraryConfiguration.self, FeedCategory.self, Feed.self, FeedEntry.self,
            FeedDirectory.self, UserScript.self, UserScriptAllowedDomain.self,
        ]
        configureLakeOfFireMutationTrackingForTesting(&result)
        let captured = result
        addTeardownBlock { await RealmBackgroundActor.shared.removeCachedRealm(for: captured) }
        return result
    }

    private func installFeed(id: UUID, categoryID: UUID, title: String, in realm: Realm) throws -> Feed {
        let category = FeedCategory()
        category.id = categoryID
        let feed = Feed()
        feed.id = id
        feed.categoryID = categoryID
        feed.title = title
        feed.rssUrl = URL(string: "https://example.com/original.xml")!
        try realm.write { realm.add(category); realm.add(feed) }
        return feed
    }

    private func journalGenerations(in realm: Realm) -> [String: String] {
        Dictionary(uniqueKeysWithValues: realm.objects(BigSyncPendingMutation.self).map {
            ($0.recordName, $0.generation)
        })
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<150 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}

private actor FeedEditorWriteGate {
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
