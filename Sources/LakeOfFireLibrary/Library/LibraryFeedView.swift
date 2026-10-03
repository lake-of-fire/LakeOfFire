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
import SwiftUIBackports
import FaviconFinder
import DebouncedOnChange
import OpenGraph
import RealmSwiftGaps
import SwiftUtilities
import LakeImage

@available(iOS 16.0, macOS 13, *)
struct LibraryFeedView: View {
    let feed: Feed
    
    @State private var libraryFeedFormSectionsViewModel: LibraryFeedFormSectionsViewModel?
    
    func unfrozen(_ feed: Feed) -> Feed {
        return feed.isFrozen ? feed.thaw() ?? feed : feed
    }
    
    var body: some View {
        VStack(spacing: 0) {
            if let libraryFeedFormSectionsViewModel = libraryFeedFormSectionsViewModel {
                Form {
                    LibraryFeedFormSections(
                        viewModel: libraryFeedFormSectionsViewModel,
                        feed: feed
                    )
                        .disabled(!feed.isUserEditable())
                }
                .formStyle(.grouped)
            }
        }
        .toolbar {
            LibraryFeedMenu(feed: feed)
        }
        .task(id: LibraryRecordPresentationIdentity(
            recordID: feed.id, configuration: feed.realm?.configuration ?? LibraryDataManager.realmConfiguration
        )) { @MainActor in
            libraryFeedFormSectionsViewModel = LibraryFeedFormSectionsViewModel(feed: feed)
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
                        let opml = try await LibraryDataManager.shared.exportUserOPML(
                            realmConfiguration: feed.realm?.configuration ?? LibraryDataManager.realmConfiguration
                        )
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

enum LibraryFeedEditorField: Int, Sendable {
    case title, description, enabled, url, iconURL, readerMode, headerImage
    case extractImage, fullContent, publicationDate, other
}

@MainActor
class LibraryFeedFormSectionsViewModel: ObservableObject {
    let feed: Feed
    let realmConfiguration: Realm.Configuration
    
    @Published var feedTitle = ""
    @Published var feedDescription = ""
    @Published var feedEnabled = false
    @Published var feedURL = ""
    @Published var feedIconURL = ""
    @Published var feedIsReaderModeByDefault = false
    @Published var feedInjectEntryImageIntoHeader = false
    @Published var feedExtractImageFromContent = false
    @Published var feedRssContainsFullContent = false
    @Published var feedDisplayPublicationDate = false
    
    @Published var feedEntries: [FeedEntry]?
    
    var isEditing = false
    var hasInitializedValues = false
    private var isRefreshing = false
    private var nextWriteSequence: UInt64 = 0
    private let writeOrdering = LibraryEditorWriteOrdering()
    
    var cancellables = Set<AnyCancellable>()
    
    @RealmBackgroundActor
    var realmCancellables = Set<AnyCancellable>()
    @RealmBackgroundActor
    private var objectNotificationToken: NotificationToken?
    
    init(feed: Feed, observesRealm: Bool = true) {
        realmConfiguration = feed.realm?.configuration ?? LibraryDataManager.realmConfiguration
        self.feed = feed
        // TODO: only resolve this once instead of repeatedly below...
        let feedID = feed.id
        guard observesRealm else {
            refresh()
            return
        }
        Task { @RealmBackgroundActor [weak self, realmConfiguration] in
            guard let self else { return }
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: realmConfiguration)
            guard let feed = realm.object(ofType: Feed.self, forPrimaryKey: feedID) else { return }
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
                        let realm = try await Realm.open(configuration: realmConfiguration)
                        self.feedEntries = realm.objects(FeedEntry.self).where { $0.feedID == feedID } .map { $0 }
                    }
                })
                .store(in: &realmCancellables)
            
            await refresh()
            
            try await { @MainActor [weak self] in
                guard let self else { return }
                $feedTitle
                    .dropFirst()
                    .filter { [weak self] _ in self?.isRefreshing == false }
                    .debounceLeadingTrailing(for: .seconds(0.35), scheduler: DispatchQueue.main)
                    .sink { [weak self] feedTitle in
                        guard let self else { return }
                        writeFeedAsync(field: .title) { feed in
                            guard feed.title != feedTitle else { return false }
                            feed.title = feedTitle
                            return true
                        }
                    }
                    .store(in: &cancellables)
                $feedDescription
                    .dropFirst()
                    .filter { [weak self] _ in self?.isRefreshing == false }
                    .debounceLeadingTrailing(for: .seconds(0.35), scheduler: DispatchQueue.main)
                    .sink { [weak self] feedDescription in
                        guard let self else { return }
                        writeFeedAsync(field: .description) { feed in
                            guard feed.markdownDescription != feedDescription else { return false }
                            feed.markdownDescription = feedDescription
                            return true
                        }
                    }
                    .store(in: &cancellables)
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
                $feedURL
                    .dropFirst()
                    .filter { [weak self] _ in self?.isRefreshing == false }
                    .debounceLeadingTrailing(for: .seconds(0.35), scheduler: DispatchQueue.main)
                    .sink { [weak self] feedURL in
                        guard let self else { return }
                        writeFeedAsync(field: .url) { feed in
                            guard let url = URL(string: feedURL.isEmpty ? "about:blank" : feedURL),
                                  feed.rssUrl != url else { return false }
                            feed.rssUrl = url
                            return true
                        }
                    }
                    .store(in: &cancellables)
                $feedIconURL
                    .dropFirst()
                    .filter { [weak self] _ in self?.isRefreshing == false }
                    .debounceLeadingTrailing(for: .seconds(0.35), scheduler: DispatchQueue.main)
                    .sink { [weak self] feedIconURL in
                        guard let self else { return }
                        writeFeedAsync(field: .iconURL) { feed in
                            guard let url = URL(string: feedIconURL.isEmpty ? "about:blank" : feedIconURL),
                                  feed.iconUrl != url else { return false }
                            feed.iconUrl = url
                            return true
                        }
                    }
                    .store(in: &cancellables)
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
            }()
        }
    }
    
    deinit {
        Task { @RealmBackgroundActor [weak objectNotificationToken] in
            objectNotificationToken?.invalidate()
        }
    }
    
    @discardableResult
    func writeFeedAsync(
        field: LibraryFeedEditorField = .other,
        beforeWrite: (@RealmBackgroundActor @Sendable () async -> Void)? = nil,
        _ block: @escaping @RealmBackgroundActor @Sendable (Feed) -> Bool
    ) -> Task<Void, Error> {
        let feedID = feed.id
        nextWriteSequence &+= 1
        let sequence = nextWriteSequence
        return Task { @RealmBackgroundActor [realmConfiguration, writeOrdering] in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: realmConfiguration)
            await beforeWrite?()
            try Task.checkCancellation()
            try await realm.asyncWrite {
                try Task.checkCancellation()
                guard let feed = realm.object(ofType: Feed.self, forPrimaryKey: feedID),
                      !feed.isDeleted, feed.isUserEditable(),
                      writeOrdering.admits(recordID: feedID, field: field.rawValue, sequence: sequence),
                      block(feed) else { return }
                feed.refreshChangeMetadata(explicitlyModified: true)
            }
        }
    }
    
    @MainActor
    func refresh() {
        guard !feed.isInvalidated else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        feedTitle = feed.title
        feedDescription = feed.markdownDescription ?? ""
        feedEnabled = !(feed.isArchived || feed.isDeleted)
        feedURL = feed.rssUrl.absoluteString == "about:blank" ? "" : feed.rssUrl.absoluteString
        feedIconURL = feed.iconUrl.absoluteString == "about:blank" ? "" : feed.iconUrl.absoluteString
        feedIsReaderModeByDefault = feed.isReaderModeByDefault
        feedInjectEntryImageIntoHeader = feed.injectEntryImageIntoHeader
        feedExtractImageFromContent = feed.extractImageFromContent
        feedRssContainsFullContent = feed.rssContainsFullContent
        feedDisplayPublicationDate = feed.displayPublicationDate
    }
    
    @discardableResult
    func pasteRSSURL(strings: [String]) -> Task<Void, Error> {
        let url = URL(string: strings.first ?? "") ?? URL(string: "about:blank")!
        // Explicit paste is the newest edit, so replace any buffered URL input
        // through the same publisher before its immediate write.
        feedURL = url.absoluteString
        let write = writeFeedAsync(field: .url) { feed in
            guard feed.rssUrl != url else { return false }
            feed.rssUrl = url
            return true
        }
        return Task { @MainActor [weak self] in
            try await write.value
            self?.feed.realm?.refresh()
            self?.refresh()
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
    @StateObject private var readerViewModel = ReaderViewModel(realmConfiguration: LibraryDataManager.realmConfiguration, systemScripts: [])
    @StateObject private var readerModeViewModel = ReaderModeViewModel()
    @StateObject private var readerLocationBarViewModel = ReaderLocationBarViewModel()
    @StateObject private var readerMediaPlayerViewModel = ReaderMediaPlayerViewModel()
    
    @State private var readerFeedEntry: FeedEntry?
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
        .task(id: viewModel.feed.rssUrl) { @MainActor in
            let expectedRSSURL = viewModel.feed.rssUrl
            let expectedGeneration = UUID()
            metadataRefreshGeneration = expectedGeneration
            do {
                try await Task.sleep(for: .seconds(1.5))
                try Task.checkCancellation()
                guard viewModel.feed.rssUrl == expectedRSSURL,
                      metadataRefreshGeneration == expectedGeneration else { return }
                async let feedRefresh: Void = refreshFeed(expectedRSSURL: expectedRSSURL)
                async let iconRefresh: Void = refreshIcon(
                    expectedRSSURL: expectedRSSURL,
                    expectedGeneration: expectedGeneration
                )
                async let openGraphRefresh: Void = refreshFromOpenGraph(
                    expectedRSSURL: expectedRSSURL,
                    expectedGeneration: expectedGeneration
                )
                _ = await (feedRefresh, iconRefresh, openGraphRefresh)
            } catch is CancellationError {
                return
            } catch {
                return
            }
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
            let expectedRSSURL = viewModel.feed.rssUrl
            let expectedGeneration = metadataRefreshGeneration
            Task { @MainActor in
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
            viewModel.isEditing = (newFocus != nil)
            if newFocus == nil {
                refresh()
            }
        }
        .task(id: viewModel.feed.id) { @MainActor in
            reinitializeState()
        }
    }
    
    private func reinitializeState() {
        readerFeedEntry = nil
        readerViewModel.navigator = webNavigator
        readerModeViewModel.navigator = webNavigator
        readerViewModel.navigator?.load(URLRequest(url: URL(string: "about:blank")!))
        
        refresh(entries: Array(viewModel.feed.getEntries() ?? []))
    }
    
    @MainActor
    private func refreshFeed(expectedRSSURL: URL) async {
        guard viewModel.feed.rssUrl == expectedRSSURL else { return }
        try? await viewModel.feed.fetch()
    }
    
    @MainActor
    private func refreshFromOpenGraph(
        expectedRSSURL rssURL: URL,
        expectedGeneration: UUID
    ) async {
        guard viewModel.feed.rssUrl == rssURL,
              metadataRefreshGeneration == expectedGeneration,
              viewModel.feed.isUserEditable(),
              !rssURL.isNativeReaderView else { return }
            
        let baseDomain = rssURL.domainURL
        var titleSet = !viewModel.feed.title.isEmpty
        var descSet = viewModel.feed.markdownDescription != nil
            
        @MainActor
        func applyOG(_ og: OpenGraph, allowDescription: Bool) {
            guard !Task.isCancelled,
                  viewModel.feed.rssUrl == rssURL,
                  metadataRefreshGeneration == expectedGeneration else { return }
            if !titleSet, let name = og[.siteName] ?? og[.title], !name.isEmpty {
                viewModel.feedTitle = name
                titleSet = true
            }
            if allowDescription,
               !descSet,
               let description = og[.description]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !description.isEmpty {
                viewModel.feedDescription = description
                descSet = true
            }
        }

        // 1. Try RSS URL with last path component removed (e.g. .../feed.rss -> .../newsroom/)
        if !titleSet || !descSet {
            let stripped = rssURL.deletingLastPathComponent()
            if stripped != rssURL,
               let og = try? await OpenGraph.fetch(url: stripped),
               let raw = og[.url], let u = URL(string: raw), u.domainURL == baseDomain {
                applyOG(og, allowDescription: true)
            }
        }

        // 2. Fall back to first entry URL – title only (description will come from pure domain)
        if !titleSet,
           !Task.isCancelled,
           viewModel.feed.rssUrl == rssURL,
           metadataRefreshGeneration == expectedGeneration,
           let entryURL = viewModel.feed.getEntries()?.first?.url,
           let og = try? await OpenGraph.fetch(url: entryURL),
           let raw = og[.url], let u = URL(string: raw), u.domainURL == baseDomain {
            applyOG(og, allowDescription: false)
        }
            
        // 3. Finally, fetch the bare domain for description (or still-missing title/desc)
        if (!descSet || !titleSet),
           !Task.isCancelled,
           viewModel.feed.rssUrl == rssURL,
           metadataRefreshGeneration == expectedGeneration,
           let og = try? await OpenGraph.fetch(url: baseDomain),
           let raw = og[.url], let u = URL(string: raw), u.domainURL == baseDomain {
            applyOG(og, allowDescription: true)
        }
    }

    @MainActor
    private func refreshIcon(
        expectedRSSURL: URL,
        expectedGeneration: UUID
    ) async {
        guard viewModel.feed.rssUrl == expectedRSSURL,
              metadataRefreshGeneration == expectedGeneration,
              viewModel.feed.iconUrl.isNativeReaderView,
              !expectedRSSURL.isNativeReaderView else { return }
        let url = expectedRSSURL.domainURL
        do {
            let favicon = try await Task.detached {
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
            }.value
            guard !Task.isCancelled,
                  viewModel.feed.rssUrl == expectedRSSURL,
                  metadataRefreshGeneration == expectedGeneration,
                  viewModel.feed.iconUrl.isNativeReaderView,
                  !favicon.source.isNativeReaderView else { return }
            viewModel.feedIconURL = favicon.source.absoluteString
        } catch is CancellationError {
            return
        } catch {
            print("Error finding favicon: \(error)")
        }
    }
    
    private func refresh(entries: [FeedEntry]? = nil, forceRefresh: Bool = false) {
        let realm: Realm
        do {
            realm = try Realm(configuration: ReaderContentLoader.feedEntryRealmConfiguration)
        } catch {
            // A transient Realm open failure should not terminate the feed editor
            // or discard the preview which is already on screen. A later edit,
            // reload, or feed update will retry this refresh.
            print("Failed to open feed Realm while refreshing preview:", error)
            return
        }
        guard let feed = realm.object(ofType: Feed.self, forPrimaryKey: viewModel.feed.id) else {
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
