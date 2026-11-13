import LakeOfFireWeb
import SwiftUI
import LakeOfFireFiles
import LakeOfFireContentUI
import LakeOfFireReader
import LakeOfFireContent
import LakeOfFireCore
import Combine
import RealmSwift
import FilePicker
import UniformTypeIdentifiers
import OPML
import SwiftUIWebView
import FaviconFinder
import DebouncedOnChange
import OpenGraph
import RealmSwiftGaps
import SwiftUtilities
import LakeImage

// Use Realm's public row identity through its protocol requirement, rather
// than Feed's separately declared UUID id or a frozen wrapper's memory address.
private func libraryFeedRowKey<T: ObjectKeyIdentifiable>(_ object: T) -> UInt64 { object.id }

struct LibraryFeedPresentationIdentity: Hashable {
    let storage: LibraryRecordPresentationIdentity
    let feedRowKey: UInt64
    let categoryRowKey: UInt64

    init?(feed: Feed) {
        guard !feed.isInvalidated, let realm = feed.realm,
              let category = feed.getCategory(), !category.isInvalidated else { return nil }
        storage = LibraryRecordPresentationIdentity(recordID: feed.id, configuration: realm.configuration)
        feedRowKey = libraryFeedRowKey(feed)
        categoryRowKey = libraryFeedRowKey(category)
    }
}

@available(iOS 16.0, macOS 13, *)
struct LibraryFeedView: View {
    let feed: Feed
    
    @State private var libraryFeedFormSectionsViewModel: LibraryFeedFormSectionsViewModel?
    
    var body: some View {
        Group {
            if let model = libraryFeedFormSectionsViewModel {
                LibraryFeedEditorHost(model: model)
            } else if LibraryFeedPresentationIdentity(feed: feed) == nil {
                Text("This feed was removed or moved. Reopen it from the library to continue.")
                    .padding()
            }
        }
        .task(id: LibraryFeedPresentationIdentity(feed: feed)) { @MainActor in
            let identity = LibraryFeedPresentationIdentity(feed: feed)
            guard identity != libraryFeedFormSectionsViewModel?.presentationIdentity else { return }
            guard identity != nil else {
                libraryFeedFormSectionsViewModel?.retireOwnership()
                return
            }
            libraryFeedFormSectionsViewModel = LibraryFeedFormSectionsViewModel(feed: feed)
        }
    }
}

@available(iOS 16.0, macOS 13, *)
private struct LibraryFeedEditorHost: View {
    @ObservedObject var model: LibraryFeedFormSectionsViewModel

    var body: some View {
        Group {
            if !model.ownershipRetired, !model.feed.isInvalidated {
                Form {
                    LibraryFeedFormSections(viewModel: model, feed: model.feed)
                        .id(model.presentationIdentity)
                        .disabled(!model.canEdit)
                }
                .formStyle(.grouped)
            } else {
                Text("This feed was removed, moved, or is no longer editable. Reopen it from the library to continue.")
                    .padding()
            }
        }
        .toolbar {
            if !model.ownershipRetired, !model.feed.isInvalidated {
                LibraryFeedMenu(feed: model.feed)
            }
        }
    }
}

fileprivate extension OPMLEntry {
    var uuid: String? {
        attributes?.first { $0.name == "uuid" }?.value
    }
}

fileprivate func findEntry(uuid target: String, in entries: [OPMLEntry]) -> OPMLEntry? {
    for entry in entries {
        if entry.uuid == target { return entry }
        if let kids = entry.children, let hit = findEntry(uuid: target, in: kids) {
            return hit
        }
    }
    return nil
}

private struct LibraryFeedMenu: View {
    let feed: Feed
    
    var body: some View {
        Menu {
            Button("Copy OPML Entry") {
                guard !feed.isInvalidated else { return }
                let feedID = feed.id
                let configuration = feed.realm?.configuration ?? LibraryDataManager.realmConfiguration
                Task { @MainActor in
                    do {
                        let opml = try await LibraryDataManager.shared.exportUserOPML(
                            realmConfiguration: configuration
                        )
                        guard let entry = findEntry(uuid: feedID.uuidString, in: opml.entries) else {
                            print("No matching OPML entry found for feed with UUID: \(feedID) out of OPML entry IDs: \(opml.entries.map { $0.attributeUUIDValue("uuid") })")
                            return
                        }
                        let xml = entry.xml
#if os(iOS)
                        UIPasteboard.general.string = xml
#else
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(xml, forType: .string)
#endif
                    } catch {
                        print("Failed to copy OPML entry:", error)
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuIndicator(.hidden)
    }
}

enum LibraryFeedEditorField: Int, Hashable, Sendable {
    case title, description, enabled, url, iconURL, readerMode, headerImage
    case extractImage, fullContent, publicationDate, other
}

struct LibraryFeedOpenGraphMetadata: Sendable {
    let url: URL?
    let title: String?
    let description: String?
}

private struct LibraryFeedMetadataRequest: Sendable {
    let identifier: UUID
    let rssURL: URL
    let revisions: [LibraryFeedEditorField: UInt64]
    let sharedIntents: [Int: UInt64]
}

// Only plain input revisions cross actors. Realm objects stay on their owner.
// The lock makes synchronous UI input publication visible in the final writer
// without suspending a Realm transaction to consult MainActor state.
private final class LibraryFeedMetadataAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var identifier = UUID()
    private var revisions: [LibraryFeedEditorField: UInt64] = [:]
    private var values: [LibraryFeedEditorField: String] = [:]

    func update(field: LibraryFeedEditorField, value: String, isUserEdit: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if isUserEdit || values[field] != value {
            revisions[field, default: 0] &+= 1
        }
        values[field] = value
    }

    func begin(identifier: UUID, rssURL: URL, sharedIntents: [Int: UInt64]) -> LibraryFeedMetadataRequest {
        lock.lock()
        defer { lock.unlock() }
        self.identifier = identifier
        return LibraryFeedMetadataRequest(
            identifier: identifier, rssURL: rssURL, revisions: revisions, sharedIntents: sharedIntents
        )
    }

    func invalidate(identifier expectedIdentifier: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard identifier == expectedIdentifier else { return }
        identifier = UUID()
    }

    func admits(_ request: LibraryFeedMetadataRequest, field: LibraryFeedEditorField) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCurrent(request, field: field)
    }

    func withAdmission(_ request: LibraryFeedMetadataRequest, field: LibraryFeedEditorField, apply: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard isCurrent(request, field: field) else { return }
        apply()
    }

    private func isCurrent(_ request: LibraryFeedMetadataRequest, field: LibraryFeedEditorField) -> Bool {
        identifier == request.identifier
            && values[.url] == request.rssURL.absoluteString
            && revisions[.url] == request.revisions[.url]
            && revisions[field] == request.revisions[field]
            && (values[field] ?? "").isEmpty
    }
}

// Fixed-schema local Realm identity: Realm's public row key is the ObjKey
// carried by its Object TSR payload. Keep UUID and category linkage checks too,
// and admit the captured physical store before looking up rows in an owned write.
private struct LibraryFeedPhysicalOwner: Sendable {
    let configuration: Realm.Configuration
    let storageAdmission: RealmStorageAdmission
    let feedID: UUID
    let categoryID: UUID
    let feedRowKey: UInt64
    let categoryRowKey: UInt64

    func validateStorage() throws {
        guard storageAdmission.matchesCurrentStorageIdentity({
            RealmBackgroundActor.shared.realmCacheKey(for: configuration)
        }) else { throw RealmBackgroundActorError.realmFileChangedDuringOpen }
    }

    func matches(feed: Feed, category: FeedCategory) -> Bool {
        do { try validateStorage() } catch { return false }
        guard !feed.isInvalidated, !category.isInvalidated,
              feed.id == feedID, category.id == categoryID,
              !feed.isDeleted, !category.isDeleted, feed.categoryID == categoryID,
              libraryFeedRowKey(feed) == feedRowKey, libraryFeedRowKey(category) == categoryRowKey,
              let currentCategory = feed.getCategory(), !currentCategory.isInvalidated,
              libraryFeedRowKey(currentCategory) == categoryRowKey else { return false }
        return true
    }

    @RealmBackgroundActor
    func currentFeed(in realm: Realm) -> Feed? {
        guard let feed = realm.object(ofType: Feed.self, forPrimaryKey: feedID),
              let category = realm.object(ofType: FeedCategory.self, forPrimaryKey: categoryID),
              matches(feed: feed, category: category) else { return nil }
        return feed
    }
}

private enum LibraryFeedWriteOutcome: Sendable, Equatable {
    case settled
    case retryWhenEditable
}

// Retain the result beside the original public task, so cancellation and task
// identity keep their existing contract. Retirement can distinguish a joined
// deferred attempt from a settled command without submitting a duplicate.
@RealmBackgroundActor
private final class LibraryFeedWriteAttemptResult {
    var outcome: LibraryFeedWriteOutcome?
    nonisolated init() {}
}

private struct LibraryFeedActiveWrite: Sendable {
    let task: Task<Void, Error>
    let result: LibraryFeedWriteAttemptResult
}

private struct LibraryFeedFieldCommand: Sendable {
    let feedID: UUID
    let physicalOwner: LibraryFeedPhysicalOwner?
    let field: LibraryFeedEditorField
    let sequence: UInt64
    let writeOrdering: LibraryEditorWriteOrdering
    let metadataRequest: LibraryFeedMetadataRequest?
    let metadataAdmission: LibraryFeedMetadataAdmission?
    let apply: @RealmBackgroundActor @Sendable (Feed) -> Bool

    @RealmBackgroundActor
    func write(beforeWrite: (@RealmBackgroundActor @Sendable () async throws -> Void)? = nil) async throws -> LibraryFeedWriteOutcome {
        guard let physicalOwner else { return .settled }
        let realm = try await RealmBackgroundActor.shared.cachedRealm(
            for: physicalOwner.configuration, storageAdmission: physicalOwner.storageAdmission
        )
        try await beforeWrite?()
        try Task.checkCancellation()
        return try await realm.asyncWritePreservingOwnership {
            try Task.checkCancellation()
            try physicalOwner.validateStorage()
            guard let feed = physicalOwner.currentFeed(in: realm) else { return .settled }
            guard feed.isUserEditable() else {
                // A live physical owner can become editable again. Human input
                // remains pending; automatic metadata is a disposable attempt.
                return metadataRequest == nil ? .retryWhenEditable : .settled
            }
            let applyChange = {
                guard writeOrdering.admits(recordID: feedID, field: field.rawValue, sequence: sequence) else { return }
                let previousRSSURL = feed.rssUrl
                guard apply(feed) else { return }
                if feed.rssUrl != previousRSSURL {
                    feed.retireFetchMetadata()
                }
                feed.refreshChangeMetadata(explicitlyModified: true)
            }
            if let metadataRequest, let metadataAdmission {
                writeOrdering.humanInputAdmission.withMetadataAdmission(
                    recordID: feedID, field: field.rawValue, sourceField: LibraryFeedEditorField.url.rawValue,
                    expected: metadataRequest.sharedIntents
                ) {
                    metadataAdmission.withAdmission(metadataRequest, field: field, apply: applyChange)
                }
            } else {
                writeOrdering.humanInputAdmission.withAdmission(
                    recordID: feedID, field: field.rawValue, sequence: sequence, apply: applyChange
                )
            }
            try physicalOwner.validateStorage()
            return .settled
        }
    }
}

@MainActor
class LibraryFeedFormSectionsViewModel: ObservableObject {
    let feed: Feed
    let feedID: UUID
    let realmConfiguration: Realm.Configuration
    let presentationIdentity: LibraryFeedPresentationIdentity?
    @Published private(set) var ownershipRetired = false
    @Published private(set) var canEdit = false
    
    @Published var feedTitle = "" {
        didSet { metadataAdmission.update(field: .title, value: feedTitle, isUserEdit: !isRefreshing) }
    }
    @Published var feedDescription = "" {
        didSet { metadataAdmission.update(field: .description, value: feedDescription, isUserEdit: !isRefreshing) }
    }
    @Published var feedEnabled = false
    @Published var feedURL = "" {
        didSet { metadataAdmission.update(field: .url, value: feedURL, isUserEdit: !isRefreshing) }
    }
    @Published var feedIconURL = "" {
        didSet { metadataAdmission.update(field: .iconURL, value: feedIconURL, isUserEdit: !isRefreshing) }
    }
    @Published var feedIsReaderModeByDefault = false
    @Published var feedInjectEntryImageIntoHeader = false
    @Published var feedExtractImageFromContent = false
    @Published var feedRssContainsFullContent = false
    @Published var feedDisplayPublicationDate = false
    
    @Published var feedEntries: [FeedEntry]?
    
    var isEditing = false
    var hasInitializedValues = false
    private var isRefreshing = false
    private var pendingFieldCommands: [LibraryFeedEditorField: LibraryFeedFieldCommand] = [:]
    private var activeWrites: [UInt64: LibraryFeedActiveWrite] = [:]
    private let beforeFieldWrite: (@RealmBackgroundActor @Sendable () async throws -> Void)?
    private let retirementDidFinish: (@RealmBackgroundActor @Sendable () -> Void)?
    private let observesFormInput: Bool
    private let writeOrdering: LibraryEditorWriteOrdering
    private let physicalOwner: LibraryFeedPhysicalOwner?
    private let originalCategory: FeedCategory?
    private let metadataAdmission = LibraryFeedMetadataAdmission()
    private var metadataRequest: LibraryFeedMetadataRequest?
    
    var cancellables = Set<AnyCancellable>()
    
    private var presentationCancellables = Set<AnyCancellable>()
    private var objectNotificationToken: NotificationToken?
    private var categoryNotificationToken: NotificationToken?
    private var observationsStopped = false
    
    init(
        feed: Feed, observesRealm: Bool = true, observesFormInput: Bool? = nil,
        beforeFieldWrite: (@RealmBackgroundActor @Sendable () async throws -> Void)? = nil,
        retirementDidFinish: (@RealmBackgroundActor @Sendable () -> Void)? = nil,
        didInstallOwnershipObservers: (@MainActor () -> Void)? = nil
    ) {
        self.observesFormInput = observesFormInput ?? observesRealm
        self.beforeFieldWrite = beforeFieldWrite
        self.retirementDidFinish = retirementDidFinish
        realmConfiguration = feed.realm?.configuration ?? LibraryDataManager.realmConfiguration
        presentationIdentity = LibraryFeedPresentationIdentity(feed: feed)
        let recordScope = presentationIdentity.map { "feed:\($0.feedRowKey):category:\($0.categoryRowKey)" }
        writeOrdering = .shared(configuration: realmConfiguration, recordKind: "feed", recordScope: recordScope)
        self.feed = feed.isInvalidated ? feed : (feed.isFrozen ? feed.thaw() ?? feed : feed)
        feedID = feed.isInvalidated ? UUID() : feed.id
        // Capture both input row keys before thawing the category. A frozen
        // navigation value must not adopt a same-UUID replacement category.
        if !feed.isInvalidated, let identity = presentationIdentity,
           let category = feed.getCategory(), !category.isInvalidated {
            originalCategory = category.isFrozen ? category.thaw() : category
            physicalOwner = LibraryFeedPhysicalOwner(
                configuration: realmConfiguration,
                storageAdmission: RealmBackgroundActor.shared.captureStorageAdmission(for: realmConfiguration),
                feedID: feed.id, categoryID: category.id,
                feedRowKey: identity.feedRowKey, categoryRowKey: identity.categoryRowKey
            )
        } else {
            originalCategory = nil
            physicalOwner = nil
        }
        if let physicalOwner, let originalCategory {
            ownershipRetired = self.feed.isFrozen || !physicalOwner.matches(feed: self.feed, category: originalCategory)
        } else {
            ownershipRetired = true
        }
        canEdit = !ownershipRetired && self.feed.isUserEditable()
        refresh()
        if self.observesFormInput { observeFormInput() }
        guard observesRealm, !ownershipRetired, let originalCategory, let realm = self.feed.realm else { return }
        // These are the original UI-owned live rows, on MainActor's run loop.
        // A foreign background writer neither owns this Realm nor blocks its
        // observation setup. Mutation still uses the background owned queue.
        objectNotificationToken = self.feed.observe { [weak self] (change: ObjectChange<Feed>) in
            switch change {
            case .change(_, _), .deleted:
                self?.refreshOwnershipPresentation()
            case .error(let error):
                print("An error occurred:", error)
            }
        }
        categoryNotificationToken = originalCategory.observe { [weak self] (change: ObjectChange<FeedCategory>) in
            switch change {
            case .change(_, _), .deleted:
                self?.refreshOwnershipPresentation()
            case .error(let error):
                print("An error occurred:", error)
            }
        }
        let feedID = self.feedID
        let entrySubscription = realm.objects(FeedEntry.self)
            .where { $0.feedID == feedID }
            .collectionPublisher
            .map { _ in () }
            .debounceLeadingTrailing(for: .seconds(0.5), scheduler: DispatchQueue.main)
            .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] _ in
                self?.refreshPresentedEntries()
            })
        guard !observationsStopped, !ownershipRetired else { entrySubscription.cancel(); return }
        entrySubscription.store(in: &presentationCancellables)
        refreshPresentedEntries()
        guard !observationsStopped, !ownershipRetired else { return }
        didInstallOwnershipObservers?()
    }

    func stopObserving() {
        observationsStopped = true
        objectNotificationToken?.invalidate()
        categoryNotificationToken?.invalidate()
        objectNotificationToken = nil
        categoryNotificationToken = nil
        presentationCancellables.removeAll()
    }

    private func originalOwnershipIsCurrent() -> Bool {
        guard !observationsStopped, !ownershipRetired,
              let physicalOwner, let originalCategory else { return false }
        return physicalOwner.matches(feed: feed, category: originalCategory)
    }

    private func refreshOwnershipPresentation() {
        guard !observationsStopped, !ownershipRetired else { return }
        guard originalOwnershipIsCurrent() else { retireOwnership(); return }
        canEdit = feed.isUserEditable()
        if !isEditing { refresh() }
    }

    private func refreshPresentedEntries() {
        guard !observationsStopped, !ownershipRetired else { return }
        guard originalOwnershipIsCurrent(), let realm = feed.realm else { retireOwnership(); return }
        let feedID = self.feedID
        feedEntries = Array(realm.objects(FeedEntry.self).where { $0.feedID == feedID })
    }

    private func observeFormInput() {
        observeBuffered($feedTitle, field: .title) { value, feed in
            guard feed.title != value else { return false }
            feed.title = value
            return true
        }
        observeBuffered($feedDescription, field: .description) { value, feed in
            guard feed.markdownDescription != value else { return false }
            feed.markdownDescription = value
            return true
        }
        $feedEnabled
            .dropFirst()
            .filter { [weak self] _ in self?.isRefreshing == false }
            .sink { [weak self] feedEnabled in
                guard let self else { return }
                writeFeedAsync(field: .enabled) { feed in
                    guard feed.isArchived != !feedEnabled else { return false }
                    feed.isArchived = !feedEnabled
                    return true
                }
            }
            .store(in: &cancellables)
        observeBuffered($feedURL, field: .url) { value, feed in
            guard let url = URL(string: value.isEmpty ? "about:blank" : value),
                  feed.rssUrl != url else { return false }
            feed.rssUrl = url
            return true
        }
        observeBuffered($feedIconURL, field: .iconURL) { value, feed in
            guard let url = URL(string: value.isEmpty ? "about:blank" : value),
                  feed.iconUrl != url else { return false }
            feed.iconUrl = url
            return true
        }
        $feedIsReaderModeByDefault
            .dropFirst()
            .filter { [weak self] _ in self?.isRefreshing == false }
            .sink { [weak self] feedIsReaderModeByDefault in
                guard let self else { return }
                writeFeedAsync(field: .readerMode) { feed in
                    guard feed.isReaderModeByDefault != feedIsReaderModeByDefault else { return false }
                    feed.isReaderModeByDefault = feedIsReaderModeByDefault
                    return true
                }
            }
            .store(in: &cancellables)
        $feedInjectEntryImageIntoHeader
            .dropFirst()
            .filter { [weak self] _ in self?.isRefreshing == false }
            .sink { [weak self] feedInjectEntryImageIntoHeader in
                guard let self else { return }
                writeFeedAsync(field: .headerImage) { feed in
                    guard feed.injectEntryImageIntoHeader != feedInjectEntryImageIntoHeader else { return false }
                    feed.injectEntryImageIntoHeader = feedInjectEntryImageIntoHeader
                    return true
                }
            }
            .store(in: &cancellables)
        $feedExtractImageFromContent
            .dropFirst()
            .filter { [weak self] _ in self?.isRefreshing == false }
            .sink { [weak self] feedExtractImageFromContent in
                guard let self else { return }
                writeFeedAsync(field: .extractImage) { feed in
                    guard feed.extractImageFromContent != feedExtractImageFromContent else { return false }
                    feed.extractImageFromContent = feedExtractImageFromContent
                    return true
                }
            }
            .store(in: &cancellables)
        $feedRssContainsFullContent
            .dropFirst()
            .filter { [weak self] _ in self?.isRefreshing == false }
            .sink { [weak self] feedRssContainsFullContent in
                guard let self else { return }
                writeFeedAsync(field: .fullContent) { feed in
                    guard feed.rssContainsFullContent != feedRssContainsFullContent else { return false }
                    feed.rssContainsFullContent = feedRssContainsFullContent
                    return true
                }
            }
            .store(in: &cancellables)
        $feedDisplayPublicationDate
            .dropFirst()
            .filter { [weak self] _ in self?.isRefreshing == false }
            .sink { [weak self] feedDisplayPublicationDate in
                guard let self else { return }
                writeFeedAsync(field: .publicationDate) { feed in
                    guard feed.displayPublicationDate != feedDisplayPublicationDate else { return false }
                    feed.displayPublicationDate = feedDisplayPublicationDate
                    return true
                }
            }
            .store(in: &cancellables)
        hasInitializedValues = true
    }

    private func observeBuffered(
        _ publisher: Published<String>.Publisher, field: LibraryFeedEditorField,
        apply: @escaping @RealmBackgroundActor @Sendable (String, Feed) -> Bool
    ) {
        publisher.dropFirst()
            .compactMap { [weak self] value -> LibraryFeedFieldCommand? in
                guard let self, !self.isRefreshing else { return nil }
                let command = self.makeCommand(field: field) { feed in apply(value, feed) }
                self.pendingFieldCommands[field] = command
                return command
            }
            .debounceLeadingTrailing(for: .seconds(0.35), scheduler: DispatchQueue.main)
            .sink { [weak self] command in
                guard let self else { return }
                self.observeCompletion(self.submit(command))
            }
            .store(in: &cancellables)
    }

    private func submit(
        _ command: LibraryFeedFieldCommand,
        beforeWrite: (@RealmBackgroundActor @Sendable () async throws -> Void)? = nil
    ) -> Task<Void, Error> {
        if let active = activeWrites[command.sequence] { return active.task }
        guard pendingFieldCommands[command.field]?.sequence == command.sequence else {
            return Task<Void, Error> {}
        }
        let beforeWrite = beforeWrite ?? beforeFieldWrite
        let result = LibraryFeedWriteAttemptResult()
        let task = Task<Void, Error> { @RealmBackgroundActor [weak self] in
            do {
                let outcome = try await command.write(beforeWrite: beforeWrite)
                result.outcome = outcome
                await self?.settle(command, succeeded: outcome == .settled)
            } catch {
                await self?.settle(command, succeeded: false)
                throw error
            }
        }
        activeWrites[command.sequence] = LibraryFeedActiveWrite(task: task, result: result)
        return task
    }

    private func settle(_ command: LibraryFeedFieldCommand, succeeded: Bool) {
        activeWrites[command.sequence] = nil
        // Retain failed drafts, and never let an older completion clear newer input.
        guard succeeded, pendingFieldCommands[command.field]?.sequence == command.sequence else { return }
        pendingFieldCommands[command.field] = nil
        if !isEditing { refresh(only: command.field == .other ? nil : command.field) }
    }

    private func observeCompletion(_ task: Task<Void, Error>) {
        Task { @MainActor in
            do { try await task.value }
            catch { print("LibraryFeedEditor field write failed: \(error)") }
        }
    }

    @discardableResult
    func finishEditing() -> Task<Void, Error> {
        isEditing = false
        for command in pendingFieldCommands.values.sorted(by: { $0.sequence < $1.sequence }) {
            _ = submit(command)
        }
        let writes = activeWrites.sorted(by: { $0.key < $1.key }).map { $0.value.task }
        refresh()
        let completion = Task<Void, Error> { @RealmBackgroundActor in
            var firstError: Error?
            for write in writes {
                do { try await write.value }
                catch { if firstError == nil { firstError = error } }
            }
            if let firstError { throw firstError }
        }
        observeCompletion(completion)
        return completion
    }

    deinit {
        let commands = pendingFieldCommands.values.sorted { $0.sequence < $1.sequence }
        let writes = activeWrites
        let retirementDidFinish = retirementDidFinish
        Task { @RealmBackgroundActor in
            defer { retirementDidFinish?() }
            for command in commands {
                if let active = writes[command.sequence] {
                    do {
                        try await active.task.value
                        if active.result.outcome == .settled { continue }
                    } catch { /* Retry the retained command below. */ }
                }
                do { _ = try await command.write() }
                catch { print("LibraryFeedEditor retirement write failed: \(error)") }
            }
        }

    }
    
    @discardableResult
    func writeFeedAsync(
        field: LibraryFeedEditorField = .other,
        beforeWrite: (@RealmBackgroundActor @Sendable () async throws -> Void)? = nil,
        _ block: @escaping @RealmBackgroundActor @Sendable (Feed) -> Bool
    ) -> Task<Void, Error> {
        let command = makeCommand(field: field, apply: block)
        pendingFieldCommands[field] = command
        return submit(command, beforeWrite: beforeWrite)
    }

    private func makeCommand(
        field: LibraryFeedEditorField,
        metadataRequest: LibraryFeedMetadataRequest? = nil,
        apply: @escaping @RealmBackgroundActor @Sendable (Feed) -> Bool
    ) -> LibraryFeedFieldCommand {
        let sequence = writeOrdering.issueSequence()
        if metadataRequest == nil {
            writeOrdering.humanInputAdmission.record(recordID: feedID, field: field.rawValue, sequence: sequence)
        }
        return LibraryFeedFieldCommand(
            feedID: feedID, physicalOwner: physicalOwner, field: field,
            sequence: sequence, writeOrdering: writeOrdering,
            metadataRequest: metadataRequest, metadataAdmission: metadataRequest == nil ? nil : metadataAdmission, apply: apply
        )
    }
    

    @MainActor
    func refresh(only field: LibraryFeedEditorField? = nil) {
        if !feed.isFrozen { feed.realm?.refresh() }
        guard originalOwnershipIsCurrent() else { retireOwnership(); return }
        isRefreshing = true
        defer { isRefreshing = false }
        if (field == nil || field == .title), pendingFieldCommands[.title] == nil { feedTitle = feed.title }
        if (field == nil || field == .description), pendingFieldCommands[.description] == nil { feedDescription = feed.markdownDescription ?? "" }
        if (field == nil || field == .enabled), pendingFieldCommands[.enabled] == nil { feedEnabled = !(feed.isArchived || feed.isDeleted) }
        if (field == nil || field == .url), pendingFieldCommands[.url] == nil { feedURL = feed.rssUrl.absoluteString == "about:blank" ? "" : feed.rssUrl.absoluteString }
        if (field == nil || field == .iconURL), pendingFieldCommands[.iconURL] == nil { feedIconURL = feed.iconUrl.absoluteString == "about:blank" ? "" : feed.iconUrl.absoluteString }
        if (field == nil || field == .readerMode), pendingFieldCommands[.readerMode] == nil { feedIsReaderModeByDefault = feed.isReaderModeByDefault }
        if (field == nil || field == .headerImage), pendingFieldCommands[.headerImage] == nil { feedInjectEntryImageIntoHeader = feed.injectEntryImageIntoHeader }
        if (field == nil || field == .extractImage), pendingFieldCommands[.extractImage] == nil { feedExtractImageFromContent = feed.extractImageFromContent }
        if (field == nil || field == .fullContent), pendingFieldCommands[.fullContent] == nil { feedRssContainsFullContent = feed.rssContainsFullContent }
        if (field == nil || field == .publicationDate), pendingFieldCommands[.publicationDate] == nil { feedDisplayPublicationDate = feed.displayPublicationDate }
    }
    
    var currentRSSURL: URL? {
        guard originalOwnershipIsCurrent() else { return nil }
        return feed.rssUrl
    }

    func refreshMetadataAfterDelay(
        expectedRSSURL: URL,
        expectedGeneration: UUID,
        delay: @escaping @Sendable () async throws -> Void = {
            try await Task.sleep(nanoseconds: 1_500_000_000)
        },
        performRefresh: (@MainActor @Sendable () async -> Void)? = nil
    ) async {
        let admission = metadataAdmission
        await withTaskCancellationHandler {
            do {
                try await delay()
                try Task.checkCancellation()
                guard currentRSSURL == expectedRSSURL,
                      metadataRequest?.identifier == expectedGeneration else { return }
                if let performRefresh {
                    await performRefresh()
                    return
                }
                async let feedRefresh: Void = refreshFeed(expectedRSSURL: expectedRSSURL)
                async let iconRefresh: Void = refreshIcon(
                    expectedRSSURL: expectedRSSURL, expectedGeneration: expectedGeneration
                )
                async let metadataRefresh: Void = refreshFromOpenGraph(
                    expectedRSSURL: expectedRSSURL, expectedGeneration: expectedGeneration
                )
                _ = await (feedRefresh, iconRefresh, metadataRefresh)
            } catch is CancellationError {
                return
            } catch {
                print("Failed to refresh feed metadata:", error)
            }
        } onCancel: {
            admission.invalidate(identifier: expectedGeneration)
        }
    }

    private func refreshFeed(expectedRSSURL: URL) async {
        guard currentRSSURL == expectedRSSURL, let physicalOwner else { return }
        try? await feed.fetch(
            realmConfiguration: realmConfiguration,
            storageAdmission: physicalOwner.storageAdmission
        )
    }

    func beginMetadataRefresh(rssURL: URL, identifier: UUID) {
        guard !ownershipRetired else { return }
        metadataRequest = metadataAdmission.begin(
            identifier: identifier, rssURL: rssURL,
            sharedIntents: writeOrdering.humanInputAdmission.snapshot(recordID: feedID)
        )
    }

    func retireOwnership() {
        guard !ownershipRetired else { return }
        ownershipRetired = true
        canEdit = false
        if let request = metadataRequest { endMetadataRefresh(identifier: request.identifier) }
        stopObserving()
    }

    func endMetadataRefresh(identifier: UUID) {
        metadataAdmission.invalidate(identifier: identifier)
        if metadataRequest?.identifier == identifier { metadataRequest = nil }
    }

    func refreshFromOpenGraph(
        expectedRSSURL rssURL: URL,
        expectedGeneration: UUID,
        beforeWrite: (@RealmBackgroundActor @Sendable () async -> Void)? = nil,
        fetch: @escaping @Sendable (URL) async throws -> LibraryFeedOpenGraphMetadata = { url in
            let metadata = try await OpenGraph.fetch(url: url)
            return LibraryFeedOpenGraphMetadata(
                url: metadata[.url].flatMap { URL(string: $0) },
                title: metadata[.siteName] ?? metadata[.title],
                description: metadata[.description]
            )
        }
    ) async {
        guard let request = metadataRequest, request.identifier == expectedGeneration,
              request.rssURL == rssURL, !feed.isInvalidated, !feed.isDeleted,
              feed.rssUrl == rssURL, feed.isUserEditable(),
              !rssURL.isNativeReaderView else { return }
        let baseDomain = rssURL.domainURL
        var titleSet = !feed.title.isEmpty
        var descriptionSet = feed.markdownDescription != nil

        @MainActor
        func needsTitle() -> Bool {
            !titleSet && metadataAdmission.admits(request, field: .title)
        }

        @MainActor
        func needsDescription() -> Bool {
            !descriptionSet && metadataAdmission.admits(request, field: .description)
        }

        @MainActor
        func apply(_ metadata: LibraryFeedOpenGraphMetadata, allowDescription: Bool) async {
            guard !Task.isCancelled, !feed.isInvalidated, !feed.isDeleted, feed.rssUrl == rssURL,
                  metadata.url?.domainURL == baseDomain else { return }
            if !titleSet, let title = metadata.title, !title.isEmpty {
                await applyMetadataValue(title, field: .title, request: request, beforeWrite: beforeWrite)
                guard !feed.isInvalidated, !feed.isDeleted else { return }
                titleSet = !feed.title.isEmpty
            }
            if allowDescription, !descriptionSet,
               let description = metadata.description?.trimmingCharacters(in: .whitespacesAndNewlines),
               !description.isEmpty {
                await applyMetadataValue(description, field: .description, request: request, beforeWrite: beforeWrite)
                guard !feed.isInvalidated, !feed.isDeleted else { return }
                descriptionSet = feed.markdownDescription != nil
            }
        }

        let stripped = rssURL.deletingLastPathComponent()
        if (needsTitle() || needsDescription()), stripped != rssURL,
           let metadata = try? await fetch(stripped) {
            await apply(metadata, allowDescription: true)
        }
        if needsTitle(), !Task.isCancelled,
           metadataRequest?.identifier == expectedGeneration, !feed.isInvalidated, !feed.isDeleted,
           feed.rssUrl == rssURL,
           let entryURL = feed.getEntries()?.first?.url,
           let metadata = try? await fetch(entryURL) {
            await apply(metadata, allowDescription: false)
        }
        if (needsTitle() || needsDescription()), !Task.isCancelled,
           metadataRequest?.identifier == expectedGeneration, !feed.isInvalidated, !feed.isDeleted,
           feed.rssUrl == rssURL,
           let metadata = try? await fetch(baseDomain) {
            await apply(metadata, allowDescription: true)
        }
    }

    func refreshIcon(
        expectedRSSURL: URL,
        expectedGeneration: UUID,
        beforeWrite: (@RealmBackgroundActor @Sendable () async -> Void)? = nil,
        fetch: @escaping @Sendable (URL) async throws -> URL = { url in
            try await Task.detached {
                try await FaviconFinder(
                    url: url,
                    configuration: .init(
                        preferredSource: .html,
                        preferences: [
                            .html: FaviconFormatType.appleTouchIcon.rawValue,
                            .ico: "favicon.ico",
                            .webApplicationManifestFile: FaviconFormatType.launcherIcon4x.rawValue
                        ]
                    )
                )
                .fetchFaviconURLs()
                .largest()
                .source
            }.value
        }
    ) async {
        guard let request = metadataRequest, request.identifier == expectedGeneration,
              request.rssURL == expectedRSSURL, !feed.isInvalidated, !feed.isDeleted,
              feed.rssUrl == expectedRSSURL,
              feed.iconUrl.isNativeReaderView, !expectedRSSURL.isNativeReaderView else { return }
        do {
            let iconURL = try await fetch(expectedRSSURL.domainURL)
            guard !Task.isCancelled, !iconURL.isNativeReaderView else { return }
            await applyMetadataValue(iconURL.absoluteString, field: .iconURL, request: request, beforeWrite: beforeWrite)
        } catch is CancellationError {
            return
        } catch {
            print("Error finding favicon:", error)
        }
    }

    private func applyMetadataValue(
        _ value: String, field: LibraryFeedEditorField, request: LibraryFeedMetadataRequest,
        beforeWrite: (@RealmBackgroundActor @Sendable () async -> Void)?
    ) async {
        guard !Task.isCancelled, !feed.isInvalidated, !feed.isDeleted, feed.rssUrl == request.rssURL,
              metadataAdmission.admits(request, field: field) else { return }
        do {
            // Metadata is a transient cancellable attempt, never a retained human draft.
            let command = makeCommand(
                field: field, metadataRequest: request
            ) { feed in
                guard feed.rssUrl == request.rssURL else { return false }
                switch field {
                case .title:
                    guard feed.title.isEmpty else { return false }
                    feed.title = value
                case .description:
                    guard feed.markdownDescription == nil else { return false }
                    feed.markdownDescription = value
                case .iconURL:
                    guard feed.iconUrl.isNativeReaderView, let url = URL(string: value),
                          feed.iconUrl != url else { return false }
                    feed.iconUrl = url
                default:
                    return false
                }
                return true
            }
            let write = Task { @RealmBackgroundActor in
                try await command.write(beforeWrite: beforeWrite)
            }
            _ = try await withTaskCancellationHandler {
                try await write.value
            } onCancel: {
                write.cancel()
            }
            feed.realm?.refresh()
            // Hydrate only the admitted field. Another field may have buffered
            // input, and this completion must not reset the whole form.
            guard !Task.isCancelled, !feed.isInvalidated, !feed.isDeleted,
                  metadataAdmission.admits(request, field: field) else { return }
            isRefreshing = true
            defer { isRefreshing = false }
            switch field {
            case .title: feedTitle = feed.title
            case .description: feedDescription = feed.markdownDescription ?? ""
            case .iconURL: feedIconURL = feed.iconUrl.isNativeReaderView ? "" : feed.iconUrl.absoluteString
            default: break
            }
        } catch is CancellationError {
            return
        } catch {
            print("Failed to apply feed metadata:", error)
        }
    }

    func previewEntries() throws -> [FeedEntry]? {
        guard originalOwnershipIsCurrent() else { return nil }
        return Array(feed.getEntries() ?? [])
    }

    @discardableResult
    func pasteRSSURL(strings: [String]) -> Task<Void, Error> {
        let url = URL(string: strings.first ?? "") ?? URL(string: "about:blank")!
        // Capture one URL intent through the publisher, then join or flush it.
        feedURL = url.absoluteString
        if observesFormInput, let command = pendingFieldCommands[.url] {
            return submit(command)
        }
        // Preserve the observer-disabled model API used by direct writer callers.
        return writeFeedAsync(field: .url) { feed in
            guard feed.rssUrl != url else { return false }
            feed.rssUrl = url
            return true
        }
    }
}

@available(iOS 16.0, macOS 13, *)
struct LibraryFeedFormSections: View {
    @ObservedObject var viewModel: LibraryFeedFormSectionsViewModel
    @ObservedRealmObject var feed: Feed

    @ScaledMetric(relativeTo: .body) private var textEditorHeight = 80
    @ScaledMetric(relativeTo: .body) private var readerPreviewHeight = 480
    
    // Focus management for keyboard dismissal and field navigation
    @FocusState private var focusedField: Field?
    private enum Field: Hashable {
        case title, description, url, iconURL
    }
    
    @StateObject private var webNavigator = WebViewNavigator()
    @StateObject private var readerContent = ReaderContent()
    @StateObject private var readerViewModel: ReaderViewModel
    @StateObject private var readerModeViewModel = ReaderModeViewModel()
    @StateObject private var readerLocationBarViewModel = ReaderLocationBarViewModel()
    @StateObject private var readerMediaPlayerViewModel = ReaderMediaPlayerViewModel()
    
    @State private var readerFeedEntry: FeedEntry?
    @State private var metadataRefreshGeneration = UUID()
    @State private var entryMetadataRefreshTask: Task<Void, Never>?
    
    @ScaledMetric(relativeTo: .headline) private var maxContentCellHeight: CGFloat = 100
    
    @Environment(\.openURL) private var openURL
    
    init(viewModel: LibraryFeedFormSectionsViewModel, feed: Feed) {
        self.viewModel = viewModel
        self.feed = feed
        _readerViewModel = StateObject(wrappedValue: ReaderViewModel(
            realmConfiguration: viewModel.realmConfiguration, systemScripts: []
        ))
    }

    @ViewBuilder private var synchronizationSection: some View {
        Section("Synced") {
            Text("Manabi Reader manages this feed for you.")
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    
    @ViewBuilder private var feedTitleSection: some View {
        Section {
            LabeledContent {
                TextField("", text: $viewModel.feedTitle, prompt: Text("Enter website title"))
                    .textCase(nil)
                    .font(.headline)
                    .disabled(!viewModel.feed.isUserEditable())
                    .focused($focusedField, equals: .title)
                    .onSubmit { focusedField = nil }
            } label: {
                if !viewModel.feed.iconUrl.isNativeReaderView {
                    LakeImage(viewModel.feed.iconUrl)
                        .frame(maxWidth: 44, maxHeight: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }
    
    @ViewBuilder private var feedLocationSection: some View {
        Section {
            Toggle("Enabled", isOn: $viewModel.feedEnabled)
            HStack {
                TextField("Feed URL", text: $viewModel.feedURL, prompt: Text("Enter URL of RSS or Atom content"), axis: .vertical)
                    .focused($focusedField, equals: .url)
                    .onSubmit { focusedField = nil }
                if viewModel.feed.isUserEditable() {
                    PasteButton(payloadType: String.self) { strings in
                        viewModel.pasteRSSURL(strings: strings)
                    }
                }
            }
            TextField("Icon URL", text: $viewModel.feedIconURL, prompt: Text("Enter website icon URL"), axis: .vertical)
                .focused($focusedField, equals: .iconURL)
                .onSubmit { focusedField = nil }
        } header: {
            Text("Feed")
        } footer: {
            Text("Feeds use RSS or Atom syndication formats.").font(.footnote).foregroundColor(.secondary)
        }
        .task(id: viewModel.currentRSSURL) { @MainActor in
            guard let expectedRSSURL = viewModel.currentRSSURL else { return }
            let expectedGeneration = UUID()
            metadataRefreshGeneration = expectedGeneration
            viewModel.beginMetadataRefresh(rssURL: expectedRSSURL, identifier: expectedGeneration)
            await viewModel.refreshMetadataAfterDelay(
                expectedRSSURL: expectedRSSURL, expectedGeneration: expectedGeneration
            )
        }
    }
    
    private var descriptionSection: some View {
        Section("Description") {
            if viewModel.feedDescription.isEmpty && viewModel.feed.markdownDescription == nil {
                Button {
                    viewModel.writeFeedAsync(field: .description) { feed in
                        guard feed.markdownDescription == nil else { return false }
                        feed.markdownDescription = ""
                        return true
                    }
                } label: {
                    Label("Add Description", systemImage: "plus")
                }
            } else {
                TextEditor(text: $viewModel.feedDescription)
                    .foregroundColor(.secondary)
                    .frame(idealHeight: textEditorHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .focused($focusedField, equals: .description)
            }
        }
    }
    
    private var stylingSection: some View {
        Section("Feed Styling") {
            Group {
                Toggle("Automatic Reader Mode", isOn: $viewModel.feedIsReaderModeByDefault)
                Toggle("Use feed image as article header", isOn: $viewModel.feedInjectEntryImageIntoHeader)
                Toggle("Use content image in feed", isOn: $viewModel.feedExtractImageFromContent)
                Toggle("Feed contains full content", isOn: $viewModel.feedRssContainsFullContent)
                Toggle("Display publication dates", isOn: $viewModel.feedDisplayPublicationDate)
            }
        }
        .onChange(of: viewModel.feed.isReaderModeByDefault) { _ in
            refresh(forceRefresh: true)
        }
        .onChange(of: viewModel.feed.injectEntryImageIntoHeader) { _ in
            refresh(forceRefresh: true)
        }
        .onChange(of: viewModel.feed.rssContainsFullContent) { _ in
            refresh(forceRefresh: true)
        }
    }
    
    private var previewReader: some View {
        Reader(
            //            persistentWebViewID: "library-feed-preview-\(viewModel.feed.id.uuidString)",
            bounces: false)
        .environmentObject(readerContent)
        .environmentObject(readerViewModel)
        .environmentObject(readerModeViewModel)
        .environmentObject(readerLocationBarViewModel)
        .environmentObject(readerMediaPlayerViewModel)
        .environmentObject(readerViewModel.scriptCaller)
        .environment(\.webViewNavigator, webNavigator)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .frame(idealHeight: readerPreviewHeight)
        .padding(.horizontal, 15)
    }
    
    private var feedPreview: some View {
        Group {
            if let readerFeedEntry = readerFeedEntry {
                ReaderContentCell(
                    item: readerFeedEntry,
                    appearance: ReaderContentCellAppearance(
                        maxCellHeight: maxContentCellHeight
                    )
                )
            } else {
                Text("Enter valid RSS or Atom URL above.")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
        }
    }
    
    @ViewBuilder private var feedPreviewSection: some View {
        Section {
            feedPreview
        } header: {
            HStack {
                Text("Feed Entry Preview")
                Spacer()
                Button {
                    refresh(forceRefresh: true)
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                        .fixedSize()
                }
                .labelStyle(.iconOnly)
            }
        }
        .onChange(of: viewModel.feedEntries ?? []) { [oldEntries = viewModel.feedEntries] entries in
            let entry = entries.max(by: { ($0.publicationDate ?? Date()) < ($1.publicationDate ?? Date()) })
            let oldEntry = oldEntries?.max(by: { ($0.publicationDate ?? Date()) < ($1.publicationDate ?? Date()) })
            guard let expectedRSSURL = viewModel.currentRSSURL else { return }
            let expectedGeneration = metadataRefreshGeneration
            entryMetadataRefreshTask?.cancel()
            entryMetadataRefreshTask = Task { @MainActor in
                if entry?.id != oldEntry?.id {
                    refresh(entries: Array(entries))
                    await refreshFromOpenGraph(
                        expectedRSSURL: expectedRSSURL,
                        expectedGeneration: expectedGeneration
                    )
                }
            }
        }
    }
    
    @ViewBuilder private var feedEntryPreviewSection: some View {
        Section {
            previewReader
        } header: {
            HStack {
                Text("Reader Preview")
                Spacer()
                
                if readerViewModel.state.pageURL.absoluteString != "about:blank" {
                    PageURLLinkButton()
                }
            }
        }
    }
    
    var body: some View {
        Group {
            if !viewModel.ownershipRetired, !viewModel.feed.isInvalidated {
                feedTitleSection
                if let opmlURL = viewModel.feed.getCategory()?.opmlURL, LibraryConfiguration.opmlURLs.contains(opmlURL) {
                    synchronizationSection
                }
                feedLocationSection
                descriptionSection
                stylingSection
                feedPreviewSection
                feedEntryPreviewSection
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focusedField = nil }
            }
        }
        .onChange(of: focusedField) { newFocus in
            if newFocus == nil {
                viewModel.finishEditing()
                refresh()
            } else {
                viewModel.isEditing = true
            }
        }
        .onDisappear {
            viewModel.endMetadataRefresh(identifier: metadataRefreshGeneration)
            entryMetadataRefreshTask?.cancel()
            entryMetadataRefreshTask = nil
            viewModel.finishEditing()
        }
        .task(id: viewModel.feedID) { @MainActor in
            reinitializeState()
        }
    }
    
    private func reinitializeState() {
        readerFeedEntry = nil
        readerViewModel.navigator = webNavigator
        readerModeViewModel.navigator = webNavigator
        readerViewModel.navigator?.load(URLRequest(url: URL(string: "about:blank")!))
        
        refresh()
    }
    
    @MainActor
    private func refreshFromOpenGraph(expectedRSSURL: URL, expectedGeneration: UUID) async {
        await viewModel.refreshFromOpenGraph(
            expectedRSSURL: expectedRSSURL, expectedGeneration: expectedGeneration
        )
    }

    private func refresh(entries: [FeedEntry]? = nil, forceRefresh: Bool = false) {
        let resolvedEntries: [FeedEntry]?
        do {
            resolvedEntries = try viewModel.previewEntries()
        } catch {
            print("Failed to open feed Realm while refreshing preview:", error)
            return
        }
        guard let resolvedEntries else {
            readerFeedEntry = nil
            readerContent.content = nil
            readerViewModel.navigator?.load(URLRequest(url: URL(string: "about:blank")!))
            return
        }
        let entries = entries ?? resolvedEntries
        Task { @MainActor in
            guard viewModel.currentRSSURL != nil else { return }
            //            if let entry = entries.max(by: { ($0.publicationDate ?? Date()) < ($1.publicationDate ?? Date()) }) {
            if let entry = entries.last {
                guard !entry.isInvalidated, !entry.isDeleted else { return }
                if forceRefresh || (entry.url != readerViewModel.state.pageURL && !readerViewModel.state.isProvisionallyNavigating) {
                    readerFeedEntry = entry
                    if readerContent.content?.url != entry.url {
                        readerContent.content = entry
                        try await readerViewModel.navigator?.load(
                            content: entry,
                            readerModeViewModel: readerModeViewModel
                        )
                    }
                }
            } else {
                readerFeedEntry = nil
                readerContent.content = nil
                readerViewModel.navigator?.load(URLRequest(url: URL(string: "about:blank")!))
            }
        }
    }
}

fileprivate struct PageURLLinkButton: View {
    @Environment(\.openURL) private var openURL
    
    @EnvironmentObject private var readerViewModel: ReaderViewModel
    
    var body: some View {
        Button {
            openURL(readerViewModel.state.pageURL)
        } label: {
            Label("Reload", systemImage: "safari")
                .fixedSize()
        }
        .labelStyle(.iconOnly)
    }
}
