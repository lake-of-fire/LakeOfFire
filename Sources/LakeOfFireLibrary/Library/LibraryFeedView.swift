import SwiftUI
import Combine
import RealmSwift
import FilePicker
import UniformTypeIdentifiers
import OPML
import SwiftUIWebView
import SwiftUIBackports
import FaviconFinder
import OpenGraph
import RealmSwiftGaps
import SwiftUtilities
import LakeImage
import LakeOfFireCore
import LakeOfFireAdblock
import LakeOfFireContent
import LakeOfFireContentUI
import LakeOfFireReader

struct LibraryFeedFormIdentity: Hashable, Sendable {
    let id: UUID
    let createdAt: Date
    let categoryID: UUID?
    let categoryCreatedAt: Date?
    let storage: String

    @MainActor
    init(feed: Feed, storageAdmission: RealmStorageAdmission) {
        id = feed.id
        createdAt = feed.createdAt
        categoryID = feed.categoryID
        categoryCreatedAt = feed.getCategory()?.createdAt
        storage = storageAdmission.scopeIdentity
    }
}

struct LibraryFeedFormCapture: Sendable {
    let identity: LibraryFeedFormIdentity
    let realmConfiguration: Realm.Configuration
    let storageAdmission: RealmStorageAdmission
    private let sourceAccessor: ObjectIdentifier

    @MainActor
    init(feed: Feed) {
        realmConfiguration = feed.realm?.configuration ?? LibraryDataManager.realmConfiguration
        storageAdmission = RealmBackgroundActor.shared.captureStorageAdmission(for: realmConfiguration)
        identity = LibraryFeedFormIdentity(feed: feed, storageAdmission: storageAdmission)
        sourceAccessor = ObjectIdentifier(feed)
    }

    @MainActor
    func refreshingRowIdentity(for feed: Feed) -> Self? {
        guard sourceAccessor == ObjectIdentifier(feed), !feed.isInvalidated else { return nil }
        // Keep the captured physical owner, including before the first form
        // task. Only a live row in that same store may refresh its identity.
        guard isCurrentStorage else { return self }
        return Self(
            identity: LibraryFeedFormIdentity(feed: feed, storageAdmission: storageAdmission),
            realmConfiguration: realmConfiguration, storageAdmission: storageAdmission,
            sourceAccessor: sourceAccessor
        )
    }

    private init(
        identity: LibraryFeedFormIdentity, realmConfiguration: Realm.Configuration,
        storageAdmission: RealmStorageAdmission, sourceAccessor: ObjectIdentifier
    ) {
        self.identity = identity
        self.realmConfiguration = realmConfiguration
        self.storageAdmission = storageAdmission
        self.sourceAccessor = sourceAccessor
    }

    var isCurrentStorage: Bool {
        storageAdmission.matchesCurrentStorageIdentity {
            RealmBackgroundActor.shared.realmCacheKey(for: realmConfiguration)
        }
    }

    @MainActor
    func admits(_ feed: Feed) -> Bool {
        guard isCurrentStorage, !feed.isInvalidated, !feed.isDeleted,
              sourceAccessor == ObjectIdentifier(feed) else { return false }
        return feed.id == identity.id && feed.createdAt == identity.createdAt
            && feed.categoryID == identity.categoryID
            && feed.getCategory()?.createdAt == identity.categoryCreatedAt
    }
}

@available(iOS 16.0, macOS 13, *)
struct LibraryFeedView: View {
    let feed: Feed

    var body: some View {
        LibraryFeedOwnedForm(feed: feed)
            .id(ObjectIdentifier(feed))
    }
}

@available(iOS 16.0, macOS 13, *)
private struct LibraryFeedOwnedForm: View {
    let feed: Feed
    
    // The child is keyed to its source accessor. SwiftUI retains this first
    // physical owner through rerenders even before the initial task runs.
    @State private var capturedForm: LibraryFeedFormCapture?
    @State private var libraryFeedFormSectionsViewModel: LibraryFeedFormSectionsViewModel?
    @State private var initializedFeedIdentity: LibraryFeedFormIdentity?

    @MainActor
    init(feed: Feed) {
        self.feed = feed
        _capturedForm = State(initialValue: feed.isInvalidated ? nil : LibraryFeedFormCapture(feed: feed))
    }
    
    func unfrozen(_ feed: Feed) -> Feed {
        return feed.isFrozen ? feed.thaw() ?? feed : feed
    }
    
    var body: some View {
        let capture = capturedForm?.refreshingRowIdentity(for: feed)
        VStack(spacing: 0) {
            if let libraryFeedFormSectionsViewModel = libraryFeedFormSectionsViewModel {
                Form {
                    LibraryFeedFormSections(
                        viewModel: libraryFeedFormSectionsViewModel,
                        feed: feed
                    )
                        .id(libraryFeedFormSectionsViewModel.editorIdentity)
                        .disabled(!feed.isUserEditable())
                }
                .formStyle(.grouped)
            }
        }
        .toolbar {
            LibraryFeedMenu(feed: feed)
        }
        .task(id: capture?.identity) { @MainActor in
            guard !Task.isCancelled, let capture, capture.admits(feed),
                  initializedFeedIdentity != capture.identity else { return }
            libraryFeedFormSectionsViewModel?.finishEditing()
            libraryFeedFormSectionsViewModel = LibraryFeedFormSectionsViewModel(feed: feed, formCapture: capture)
            initializedFeedIdentity = capture.identity
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
                Task { @MainActor in
                    do {
                        let opml = try await LibraryDataManager.shared.exportUserOPML()
                        guard let entry = findEntry(uuid: feed.id.uuidString, in: opml.entries) else {
                            print("No matching OPML entry found for feed with UUID: \(feed.id) out of OPML entry IDs: \(opml.entries.map { $0.attributeUUIDValue("uuid") })")
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

@MainActor
class LibraryFeedFormSectionsViewModel: ObservableObject {
    let feed: Feed
    let formCapture: LibraryFeedFormCapture
    var editorIdentity: LibraryFeedFormIdentity { formCapture.identity }
    let feedID: UUID
    private let feedCreatedAt: Date
    private let categoryID: UUID?
    private let categoryCreatedAt: Date?
    let realmConfiguration: Realm.Configuration
    
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
    private var activeWrites: [UInt64: Task<Void, Error>] = [:]
    // Instance-scoped admission seam for deterministic buffered-write regression sources.
    private let beforeFieldWrite: (@RealmBackgroundActor @Sendable () async throws -> Void)?
    // Observes settlement after the captured retirement batch, without retaining the editor.
    private let retirementDidFinish: (@RealmBackgroundActor @Sendable () -> Void)?
    private let writeOrdering: LibraryFeedWriteOrdering
    private let metadataAdmission = LibraryFeedMetadataAdmission()
    private var metadataRequest: LibraryFeedMetadataRequest?
    private(set) var observationTask: Task<Void, Error>?

    private var isCurrentStorage: Bool { formCapture.isCurrentStorage }
    
    var cancellables = Set<AnyCancellable>()
    
    @RealmBackgroundActor
    var realmCancellables = Set<AnyCancellable>()
    @RealmBackgroundActor
    private var objectNotificationToken: NotificationToken?
    
    init(
        feed: Feed, formCapture: LibraryFeedFormCapture? = nil, observesRealm: Bool = true,
        beforeObservation: (@RealmBackgroundActor @Sendable () async throws -> Void)? = nil,
        beforeFieldWrite: (@RealmBackgroundActor @Sendable () async throws -> Void)? = nil,
        retirementDidFinish: (@RealmBackgroundActor @Sendable () -> Void)? = nil
    ) {
        self.beforeFieldWrite = beforeFieldWrite
        self.retirementDidFinish = retirementDidFinish
        let capture = formCapture ?? LibraryFeedFormCapture(feed: feed)
        self.formCapture = capture
        realmConfiguration = capture.realmConfiguration
        writeOrdering = .shared(
            configuration: realmConfiguration, storageAdmission: capture.storageAdmission,
            feedID: capture.identity.id, createdAt: capture.identity.createdAt,
            categoryID: capture.identity.categoryID, categoryCreatedAt: capture.identity.categoryCreatedAt
        )
        self.feed = feed.isFrozen ? feed.thaw() ?? feed : feed
        feedID = capture.identity.id
        feedCreatedAt = capture.identity.createdAt
        categoryID = capture.identity.categoryID
        categoryCreatedAt = capture.identity.categoryCreatedAt
        refresh()
        let feedID = self.feedID
        let capturedCreatedAt = feedCreatedAt
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
                    guard feed.isArchived == feedEnabled else { return false }
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
        guard observesRealm else { return }
        observationTask = Task { @RealmBackgroundActor [weak self, realmConfiguration] in
            try await beforeObservation?()
            try Task.checkCancellation()
            guard let self else { return }
            let realm = try await RealmBackgroundActor.shared.cachedRealm(
                for: realmConfiguration, storageAdmission: capture.storageAdmission
            )
            try Task.checkCancellation()
            guard capture.isCurrentStorage else {
                throw RealmBackgroundActorError.realmFileChangedDuringOpen
            }
            guard let feed = realm.object(ofType: Feed.self, forPrimaryKey: feedID),
                  feed.createdAt == capturedCreatedAt, !feed.isDeleted else { return }
            objectNotificationToken = feed
                .observe { [weak self] change in
                    switch change {
                    case .change(_, _), .deleted:
                        Task { @MainActor [weak self] in
                            guard let self = self else { return }
                            if !self.isEditing {
                                self.refresh()
                            }
                        }
                    case .error(let error):
                        print("An error occurred: \(error)")
                    }
                }
            
            realm.objects(FeedEntry.self)
                .where { $0.feedID == feedID }
                .collectionPublisher
                .subscribe(on: libraryDataQueue)
                .map { @Sendable _ in }
                .debounceLeadingTrailing(for: .seconds(0.5), scheduler: libraryDataQueue)
                .sink(receiveCompletion: { @Sendable _ in }, receiveValue: { @Sendable [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        try await self.refreshFeedEntries()
                    }
                })
                .store(in: &realmCancellables)
            
            await refresh()
            
        }
    }

    func refreshFeedEntries(
        beforePublication: (@MainActor @Sendable () async throws -> Void)? = nil
    ) async throws {
        try Task.checkCancellation()
        guard isCurrentStorage else { throw RealmBackgroundActorError.realmFileChangedDuringOpen }
        let realm = try await Realm(configuration: realmConfiguration, actor: MainActor.shared)
        await realm.asyncRefresh()
        try await beforePublication?()
        try Task.checkCancellation()
        guard isCurrentStorage else { throw RealmBackgroundActorError.realmFileChangedDuringOpen }
        guard let currentFeed = realm.object(ofType: Feed.self, forPrimaryKey: feedID),
              currentFeed.createdAt == feedCreatedAt, !currentFeed.isDeleted else {
            feedEntries = nil
            return
        }
        feedEntries = realm.objects(FeedEntry.self).where { $0.feedID == feedID }.map { $0 }
    }
    
    private func observeBuffered(
        _ publisher: Published<String>.Publisher, field: LibraryFeedEditorField,
        apply: @escaping @RealmBackgroundActor @Sendable (String, Feed) -> Bool
    ) {
        publisher.dropFirst()
            .compactMap { [weak self] value -> LibraryFeedFieldCommand? in
                guard let self, !self.isRefreshing else { return nil }
                let sequence = self.writeOrdering.issueSequence(field: field)
                let command = LibraryFeedFieldCommand(
                    feedID: self.feedID, feedCreatedAt: self.feedCreatedAt,
                    categoryID: self.categoryID, categoryCreatedAt: self.categoryCreatedAt,
                    realmConfiguration: self.realmConfiguration, storageAdmission: self.formCapture.storageAdmission,
                    field: field,
                    sequence: sequence, metadataIntent: nil, writeOrdering: self.writeOrdering,
                    apply: { feed in apply(value, feed) }
                )
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
        if let active = activeWrites[command.sequence] { return active }
        // A trailing debounce may arrive after settlement or newer input.
        guard pendingFieldCommands[command.field]?.sequence == command.sequence else {
            return Task<Void, Error> {}
        }
        let beforeWrite = beforeWrite ?? beforeFieldWrite
        let task = Task<Void, Error> { @RealmBackgroundActor [weak self] in
            do {
                try await command.write(beforeWrite: beforeWrite)
                await self?.settle(command, succeeded: true)
            } catch {
                await self?.settle(command, succeeded: false)
                throw error
            }
        }
        activeWrites[command.sequence] = task
        return task
    }

    private func settle(_ command: LibraryFeedFieldCommand, succeeded: Bool) {
        activeWrites[command.sequence] = nil
        // Failed attempts retain the newest draft for finish/retirement retry.
        // Durable success remains success even when cancellation followed commit submission.
        guard succeeded, pendingFieldCommands[command.field]?.sequence == command.sequence else { return }
        pendingFieldCommands[command.field] = nil
        if !isEditing { refresh() }
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
        let writes = activeWrites.sorted(by: { $0.key < $1.key }).map(\.value)
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
        observationTask?.cancel()
        let commands = pendingFieldCommands.values.sorted { $0.sequence < $1.sequence }
        let writes = activeWrites
        let retirementDidFinish = retirementDidFinish
        Task { @RealmBackgroundActor in
            defer { retirementDidFinish?() }
            for command in commands {
                // Join a submitted attempt before deciding whether retirement needs a retry.
                if let active = writes[command.sequence] {
                    do { try await active.value; continue }
                    catch { /* Retry the retained command below. */ }
                }
                do { try await command.write() }
                catch { print("LibraryFeedEditor retirement write failed: \(error)") }
            }
        }
        Task { @RealmBackgroundActor [weak objectNotificationToken] in
            objectNotificationToken?.invalidate()
        }
    }

    @discardableResult
    func writeFeedAsync(
        field: LibraryFeedEditorField,
        beforeWrite: (@RealmBackgroundActor @Sendable () async throws -> Void)? = nil,
        _ block: @escaping @RealmBackgroundActor @Sendable (Feed) -> Bool
    ) -> Task<Void, Error> {
        let sequence = writeOrdering.issueSequence(field: field)
        let command = LibraryFeedFieldCommand(
            feedID: feedID, feedCreatedAt: feedCreatedAt,
            categoryID: categoryID, categoryCreatedAt: categoryCreatedAt,
            realmConfiguration: realmConfiguration, storageAdmission: formCapture.storageAdmission, field: field,
            sequence: sequence, metadataIntent: nil, writeOrdering: writeOrdering, apply: block
        )
        pendingFieldCommands[field] = command
        return submit(command, beforeWrite: beforeWrite)
    }
    

    @MainActor
    func refresh() {
        guard isCurrentStorage else { return }
        if !feed.isFrozen { feed.realm?.refresh() }
        guard isCurrentStorage, !feed.isInvalidated else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        if pendingFieldCommands[.title] == nil { feedTitle = feed.title }
        if pendingFieldCommands[.description] == nil { feedDescription = feed.markdownDescription ?? "" }
        if pendingFieldCommands[.enabled] == nil { feedEnabled = !(feed.isArchived || feed.isDeleted) }
        if pendingFieldCommands[.url] == nil { feedURL = feed.rssUrl.absoluteString == "about:blank" ? "" : feed.rssUrl.absoluteString }
        if pendingFieldCommands[.iconURL] == nil { feedIconURL = feed.iconUrl.absoluteString == "about:blank" ? "" : feed.iconUrl.absoluteString }
        if pendingFieldCommands[.readerMode] == nil { feedIsReaderModeByDefault = feed.isReaderModeByDefault }
        if pendingFieldCommands[.headerImage] == nil { feedInjectEntryImageIntoHeader = feed.injectEntryImageIntoHeader }
        if pendingFieldCommands[.extractImage] == nil { feedExtractImageFromContent = feed.extractImageFromContent }
        if pendingFieldCommands[.fullContent] == nil { feedRssContainsFullContent = feed.rssContainsFullContent }
        if pendingFieldCommands[.publicationDate] == nil { feedDisplayPublicationDate = feed.displayPublicationDate }
    }
    var currentRSSURL: URL? {
        guard isCurrentStorage, !feed.isInvalidated, !feed.isDeleted else { return nil }
        return feed.rssUrl
    }

    func endMetadataRefresh(identifier: UUID) {
        metadataAdmission.invalidate(identifier: identifier)
        if metadataRequest?.identifier == identifier {
            metadataRequest = nil
        }
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
        guard currentRSSURL == expectedRSSURL else { return }
        try? await feed.fetch(realmConfiguration: realmConfiguration)
    }

    func beginMetadataRefresh(rssURL: URL, identifier: UUID) {
        guard isCurrentStorage else { return }
        metadataRequest = metadataAdmission.begin(
            identifier: identifier, rssURL: rssURL, sharedIntents: writeOrdering.snapshot()
        )
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
        guard isCurrentStorage, let request = metadataRequest, request.identifier == expectedGeneration,
              request.rssURL == rssURL, !feed.isInvalidated, !feed.isDeleted,
              feed.rssUrl == rssURL, feed.isUserEditable(),
              !rssURL.isNativeReaderView else { return }
        let baseDomain = rssURL.domainURL
        var titleSet = !feed.title.isEmpty
        var descriptionSet = feed.markdownDescription != nil

        @MainActor
        func needsTitle() -> Bool {
            isCurrentStorage && !titleSet && metadataAdmission.admits(request, field: .title)
        }

        @MainActor
        func needsDescription() -> Bool {
            isCurrentStorage && !descriptionSet && metadataAdmission.admits(request, field: .description)
        }

        @MainActor
        func apply(_ metadata: LibraryFeedOpenGraphMetadata, allowDescription: Bool) async {
            guard !Task.isCancelled, isCurrentStorage, !feed.isInvalidated, !feed.isDeleted, feed.rssUrl == rssURL,
                  metadata.url?.domainURL == baseDomain else { return }
            if !titleSet, let title = metadata.title, !title.isEmpty {
                await applyMetadataValue(title, field: .title, request: request, beforeWrite: beforeWrite)
                guard isCurrentStorage, !feed.isInvalidated, !feed.isDeleted else { return }
                titleSet = !feed.title.isEmpty
            }
            if allowDescription, !descriptionSet,
               let description = metadata.description?.trimmingCharacters(in: .whitespacesAndNewlines),
               !description.isEmpty {
                await applyMetadataValue(description, field: .description, request: request, beforeWrite: beforeWrite)
                guard isCurrentStorage, !feed.isInvalidated, !feed.isDeleted else { return }
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
            let lookup = Task.detached {
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
            }
            return try await withTaskCancellationHandler {
                try await lookup.value
            } onCancel: {
                lookup.cancel()
            }
        }
    ) async {
        guard isCurrentStorage, let request = metadataRequest, request.identifier == expectedGeneration,
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
        guard !Task.isCancelled, isCurrentStorage, !feed.isInvalidated, !feed.isDeleted, feed.rssUrl == request.rssURL,
              metadataAdmission.admits(request, field: field) else { return }
        let admission = metadataAdmission
        do {
            // Metadata owns one cancellable attempt. It never enters the user
            // draft retirement queue or obtains a newer human-input sequence.
            let command = LibraryFeedFieldCommand(
                feedID: feedID, feedCreatedAt: feedCreatedAt,
                categoryID: categoryID, categoryCreatedAt: categoryCreatedAt,
                realmConfiguration: realmConfiguration, storageAdmission: formCapture.storageAdmission,
                field: field, sequence: 0,
                metadataIntent: request.sharedIntents, writeOrdering: writeOrdering
            ) { feed in
                guard feed.rssUrl == request.rssURL, admission.admits(request, field: field) else { return false }
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
            try await withTaskCancellationHandler {
                try await write.value
            } onCancel: {
                write.cancel()
            }
            guard isCurrentStorage else { return }
            feed.realm?.refresh()
            // Hydrate only the admitted field. Another field may have buffered
            // input, and this completion must not reset the whole form.
            guard !Task.isCancelled, isCurrentStorage, !feed.isInvalidated, !feed.isDeleted,
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

    @discardableResult
    func pasteRSSURL(strings: [String]) -> Task<Void, Error> {
        let url = URL(string: strings.first ?? "") ?? URL(string: "about:blank")!
        // Publish one URL intent, then join or flush that exact command.
        // The common settlement path preserves any input typed afterward.
        feedURL = url.absoluteString == "about:blank" ? "" : url.absoluteString
        guard let command = pendingFieldCommands[.url] else {
            return Task<Void, Error> {}
        }
        return submit(command)
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
    @StateObject private var readerViewModel = ReaderViewModel(realmConfiguration: LibraryDataManager.realmConfiguration, systemScripts: [])
    @StateObject private var readerModeViewModel = ReaderModeViewModel()
    @StateObject private var readerMediaPlayerViewModel = ReaderMediaPlayerViewModel()
    
    @State private var readerFeedEntry: FeedEntry?
    @State private var lastReinitializedFeedID: UUID?
    @State private var metadataRefreshGeneration = UUID()
    
    @ScaledMetric(relativeTo: .headline) private var maxContentCellHeight: CGFloat = 100
    
    @Environment(\.openURL) private var openURL
    
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
            let generation = UUID()
            metadataRefreshGeneration = generation
            viewModel.beginMetadataRefresh(rssURL: expectedRSSURL, identifier: generation)
            await viewModel.refreshMetadataAfterDelay(
                expectedRSSURL: expectedRSSURL, expectedGeneration: generation
            )
        }
    }
    
    private var descriptionSection: some View {
        Section("Description") {
            if viewModel.feedDescription.isEmpty && viewModel.feed.markdownDescription == nil {
                Button {
                    viewModel.writeFeedAsync(field: .description) { feed in
                        guard feed.markdownDescription != "" else { return false }
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
                readerFeedEntry.readerContentCellView(
                    appearance: .init(
                        maxCellHeight: maxContentCellHeight,
                        alwaysShowThumbnails: false,
                        includeSource: false
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
            Task { @MainActor in
                if entry?.id != oldEntry?.id {
                    refresh(entries: Array(entries))
                    refreshFromOpenGraph()
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
            viewModel.finishEditing()
        }
        .task(id: viewModel.feedID) { @MainActor in
            guard lastReinitializedFeedID != viewModel.feedID else { return }
            reinitializeState()
            lastReinitializedFeedID = viewModel.feedID
        }
    }
    
    private func reinitializeState() {
        readerFeedEntry = nil
        readerViewModel.navigator = webNavigator
        readerModeViewModel.navigator = webNavigator
        readerViewModel.navigator?.load(URLRequest(url: URL(string: "about:blank")!))
        
        refresh(entries: Array(viewModel.feed.getEntries() ?? []))
    }
    
    private func refreshFromOpenGraph() {
        guard let rssURL = viewModel.currentRSSURL else { return }
        let generation = metadataRefreshGeneration
        Task { @MainActor in
            await viewModel.refreshFromOpenGraph(expectedRSSURL: rssURL, expectedGeneration: generation)
        }
    }

    private func refresh(entries: [FeedEntry]? = nil, forceRefresh: Bool = false) {
        guard let feed = try! Realm(configuration: ReaderContentLoader.feedEntryRealmConfiguration).object(ofType: Feed.self, forPrimaryKey: viewModel.feed.id) else {
            readerFeedEntry = nil
            readerContent.content = nil
            readerViewModel.navigator?.load(URLRequest(url: URL(string: "about:blank")!))
            return
        }
        
        let entries: [FeedEntry] = entries ?? Array(feed.getEntries() ?? [])
        Task { @MainActor in
            //            if let entry = entries.max(by: { ($0.publicationDate ?? Date()) < ($1.publicationDate ?? Date()) }) {
            if let entry = entries.last {
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
