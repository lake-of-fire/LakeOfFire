import BigSyncKit
import RealmSwift
import RealmSwiftGaps
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireLibrary
@testable import LakeOfFireReader

@MainActor
final class LibraryFeedEditorOwnershipTests: XCTestCase {
    func testDelayedFeedFieldAndPasteStayInOriginatingRealm() async throws {
        let originalConfiguration = configuration()
        let replacementConfiguration = configuration()
        let original = try Realm(configuration: originalConfiguration)
        let replacement = try Realm(configuration: replacementConfiguration)
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
        let realm = try Realm(configuration: configuration())
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
        let realm = try Realm(configuration: configuration())
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
        let original = try Realm(configuration: originalConfiguration)
        let replacementConfiguration = configuration()
        let replacement = try Realm(configuration: replacementConfiguration)
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
        let realm = try Realm(configuration: configuration())
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
        let realm = try Realm(configuration: configuration())
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
        let realm = try Realm(configuration: configuration())
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
        let realm = try Realm(configuration: configuration())
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
        let realm = try Realm(configuration: configuration())
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
                let realm = try Realm(configuration: configuration())
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
        let realm = try Realm(configuration: configuration())
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
        let realm = try Realm(configuration: configuration())
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
        let realm = try Realm(configuration: configuration())
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
            let realm = try Realm(configuration: configuration())
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
            let realm = try Realm(configuration: configuration())
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

    func testReaderPreviewScriptObservationUsesCapturedConfigurationBeforeAndAfterReplacement() async throws {
        for usesExplicitConfiguration in [true, false] {
            let originalConfiguration = configuration()
            let replacementConfiguration = configuration()
            let original = try Realm(configuration: originalConfiguration)
            let replacement = try Realm(configuration: replacementConfiguration)
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

    func testViewMetadataDelayRejectsInvalidationCancellationAndSupersessionBeforeIO() async throws {
        for rejection in ["invalidated", "cancelled", "superseded"] {
            let realm = try Realm(configuration: configuration())
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
        let realm = try Realm(configuration: configuration())
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
