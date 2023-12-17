import SwiftUI
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
        Group {
            if let libraryFeedFormSectionsViewModel = libraryFeedFormSectionsViewModel {
                Form {
                    LibraryFeedFormSections(viewModel: libraryFeedFormSectionsViewModel)
                        .disabled(!feed.isUserEditable)
                }
                .formStyle(.grouped)
            }
        }
        .task { @MainActor in
            libraryFeedFormSectionsViewModel = LibraryFeedFormSectionsViewModel(feed: feed)
        }
    }
}

@MainActor
class LibraryFeedFormSectionsViewModel: ObservableObject {
    let feed: Feed
    
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
    
    var cancellables = Set<AnyCancellable>()
    @RealmBackgroundActor private var objectNotificationToken: NotificationToken?
    
    init(feed: Feed) {
        self.feed = feed
        let feedRef = ThreadSafeReference(to: feed)
        Task.detached { @RealmBackgroundActor [weak self] in
            guard let self = self else { return }
            let realm = try await Realm(configuration: LibraryDataManager.realmConfiguration, actor: RealmBackgroundActor.shared)
            guard let feed = realm.resolve(feedRef) else { return }
            objectNotificationToken = feed
                .observe { [weak self] change in
                    switch change {
                    case .change(_, _), .deleted:
                        Task { @MainActor [weak self] in
                            self?.refresh()
                        }
                    case .error(let error):
                        print("An error occurred: \(error)")
                    }
                }
            await refresh()
        }
        
        $feedTitle
            .removeDuplicates()
            .debounce(for: .seconds(0.35), scheduler: DispatchQueue.main)
            .sink { [weak self] feedTitle in
                Task { [weak self] in
                    guard let self = self else { return }
                    try await Realm.asyncWrite(ThreadSafeReference(to: feed)) { _, feed in
                        feed.title = feedTitle
                    }
                }
            }
            .store(in: &cancellables)
        $feedDescription
            .removeDuplicates()
            .debounce(for: .seconds(0.35), scheduler: DispatchQueue.main)
            .sink { [weak self] feedDescription in
                Task { [weak self] in
                    guard let self = self else { return }
                    try await Realm.asyncWrite(ThreadSafeReference(to: feed)) { _, feed in
                        feed.markdownDescription = feedDescription
                    }
                }
            }
            .store(in: &cancellables)
        $feedEnabled
            .removeDuplicates()
            .sink { [weak self] feedEnabled in
                Task { [weak self] in
                    guard let self = self else { return }
                    try await Realm.asyncWrite(ThreadSafeReference(to: feed)) { _, feed in
                        feed.isArchived = !feedEnabled
                    }
                }
            }
            .store(in: &cancellables)
        $feedURL
            .removeDuplicates()
            .debounce(for: .seconds(0.35), scheduler: DispatchQueue.main)
            .sink { [weak self] feedURL in
                Task { [weak self] in
                    guard let self = self else { return }
                    try await Realm.asyncWrite(ThreadSafeReference(to: feed)) { _, feed in
                        if feedURL.isEmpty {
                            feed.rssUrl = URL(string: "about:blank")!
                        } else if let url = URL(string: feedURL) {
                            feed.rssUrl = url
                        }
                    }
                }
            }
            .store(in: &cancellables)
        $feedIconURL
            .removeDuplicates()
            .debounce(for: .seconds(0.35), scheduler: DispatchQueue.main)
            .sink { [weak self] feedIconURL in
                Task { [weak self] in
                    guard let self = self else { return }
                    try await Realm.asyncWrite(ThreadSafeReference(to: feed)) { _, feed in
                        if feedIconURL.isEmpty {
                            feed.iconUrl = URL(string: "about:blank")!
                        } else if let url = URL(string: feedIconURL) {
                            feed.iconUrl = url
                        }
                    }
                }
            }
            .store(in: &cancellables)
        $feedIsReaderModeByDefault
            .removeDuplicates()
            .sink { [weak self] feedIsReaderModeByDefault in
                Task { [weak self] in
                    guard let self = self else { return }
                    try await Realm.asyncWrite(ThreadSafeReference(to: feed)) { _, feed in
                        feed.isReaderModeByDefault = feedIsReaderModeByDefault
                    }
                }
            }
            .store(in: &cancellables)
        $feedInjectEntryImageIntoHeader
            .removeDuplicates()
            .sink { [weak self] feedInjectEntryImageIntoHeader in
                Task { [weak self] in
                    guard let self = self else { return }
                    try await Realm.asyncWrite(ThreadSafeReference(to: feed)) { _, feed in
                        feed.injectEntryImageIntoHeader = feedInjectEntryImageIntoHeader
                    }
                }
            }
            .store(in: &cancellables)
        $feedExtractImageFromContent
            .removeDuplicates()
            .sink { [weak self] feedExtractImageFromContent in
                Task { [weak self] in
                    guard let self = self else { return }
                    try await Realm.asyncWrite(ThreadSafeReference(to: feed)) { _, feed in
                        feed.extractImageFromContent = feedExtractImageFromContent
                    }
                }
            }
            .store(in: &cancellables)
        $feedRssContainsFullContent
            .removeDuplicates()
            .sink { [weak self] feedRssContainsFullContent in
                Task { [weak self] in
                    guard let self = self else { return }
                    try await Realm.asyncWrite(ThreadSafeReference(to: feed)) { _, feed in
                        feed.rssContainsFullContent = feedRssContainsFullContent
                    }
                }
            }
            .store(in: &cancellables)
        $feedDisplayPublicationDate
            .removeDuplicates()
            .sink { [weak self] feedDisplayPublicationDate in
                Task { [weak self] in
                    guard let self = self else { return }
                    try await Realm.asyncWrite(ThreadSafeReference(to: feed)) { _, feed in
                        feed.displayPublicationDate = feedDisplayPublicationDate
                    }
                }
            }
            .store(in: &cancellables)
    }
    
    deinit {
        Task.detached { @RealmBackgroundActor [weak self] in
            self?.objectNotificationToken?.invalidate()
        }
    }
    
    @MainActor
    func refresh() {
        feedTitle = feed.title
        feedDescription = feed.markdownDescription
        feedEnabled = !(feed.isArchived || feed.isDeleted)
        feedURL = feed.rssUrl.absoluteString
        feedIconURL = feed.iconUrl.absoluteString
        feedIsReaderModeByDefault = feed.isReaderModeByDefault
        feedInjectEntryImageIntoHeader = feed.injectEntryImageIntoHeader
        feedExtractImageFromContent = feed.extractImageFromContent
        feedRssContainsFullContent = feed.rssContainsFullContent
        feedDisplayPublicationDate = feed.displayPublicationDate
    }
    
    func pasteRSSURL(strings: [String]) {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            try await Realm.asyncWrite(ThreadSafeReference(to: feed)) { _, feed in
                feed.rssUrl = URL(string: strings.first ?? "") ?? URL(string: "about:blank")!
            }
        }
    }
}

@available(iOS 16.0, macOS 13, *)
struct LibraryFeedFormSections: View {
    @ObservedObject var viewModel: LibraryFeedFormSectionsViewModel
    
    @ScaledMetric(relativeTo: .body) private var textEditorHeight = 80
    @ScaledMetric(relativeTo: .body) private var readerPreviewHeight = 480
    @ScaledMetric(relativeTo: .body) private var readerPreviewLocationBarHeight = 40
    
//    @State private var readerContent: (any ReaderContentModel) = ReaderContentLoader.unsavedHome
//    @State private var readerState = WebViewState.empty
//    @State private var readerAction = WebViewAction.idle
    @StateObject private var readerViewModel = ReaderViewModel(realmConfiguration: LibraryDataManager.realmConfiguration, systemScripts: [])
    
    @State private var readerFeedEntry: FeedEntry?
    
    @Environment(\.openURL) private var openURL

    private var synchronizationSection: some View {
        Section("Synchronized") {
            Text("Manabi Reader manages this feed for you.")
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    
    private var feedLocationSection: some View {
        Section(header: Group {
            HStack(alignment: .bottom) {
                if !viewModel.feed.iconUrl.isNativeReaderView {
                    LakeImage(viewModel.feed.iconUrl)
                        .frame(maxWidth: 44, maxHeight: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                if viewModel.feed.isUserEditable {
                    TextField("", text: $viewModel.feedTitle, prompt: Text("Enter website title"))
                        .textCase(nil)
                        .font(.headline)
                } else {
                    Text(viewModel.feed.title)
                        .textCase(nil)
                        .font(.headline)
                }
            }
        }, footer: Text("Feeds are either RSS or Atom web syndication formats. Look for the RSS icon button that appears in Manabi Reader's main toolbar menus which indicates RSS or Atom availability on any page you visit.").font(.footnote).foregroundColor(.secondary)) {
            Toggle("Enabled", isOn: $viewModel.feedEnabled)
            HStack {
                TextField("Feed URL", text: $viewModel.feedURL, prompt: Text("Enter URL of RSS or Atom content"), axis: .vertical)
                if viewModel.feed.isUserEditable {
                    PasteButton(payloadType: String.self) { strings in
                        viewModel.pasteRSSURL(strings: strings)
                    }
                }
            }
        }
    }
    
    private var iconSection: some View {
        Section {
            TextField("Icon URL", text: $viewModel.feedIconURL, prompt: Text("Enter website icon URL"), axis: .vertical)
        }
    }
    
    private var descriptionSection: some View {
        Section("Description") {
            TextEditor(text: $viewModel.feedDescription)
                .foregroundColor(.secondary)
                .frame(idealHeight: textEditorHeight)
                .clipShape(RoundedRectangle(cornerRadius: 4))
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
    }
    
    private var previewReader: some View {
        Reader(
            readerViewModel: readerViewModel,
            persistentWebViewID: "library-feed-preview-\(viewModel.feed.id.uuidString)",
            bounces: false)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .frame(idealHeight: readerPreviewHeight)
        .padding(.horizontal, 15)
    }
    
    private var feedPreview: some View {
        Group {
            if let readerFeedEntry = readerFeedEntry {
                ReaderContentCell(item: readerFeedEntry)
                HStack(alignment: .center) {
                    GroupBox {
                        Button(readerViewModel.state.pageURL.absoluteString) {
                            openURL(readerViewModel.state.pageURL)
                        }
#if os(macOS)
                        .buttonStyle(.link)
#endif
                        .padding(10)
                    }
                    Spacer()
                    if readerViewModel.state.isLoading || readerViewModel.state.isProvisionallyNavigating {
                        ProgressView()
                            .scaleEffect(0.5)
                    }
                    Button {
                        refresh(forceRefresh: true)
                    } label: {
                        Label("Reload", systemImage: "arrow.clockwise")
                            .fixedSize()
                            .padding(.horizontal)
                    }
                    .labelStyle(.iconOnly)
                }
                .frame(minHeight: readerPreviewLocationBarHeight)
                .padding(.horizontal)
                
                previewReader
            } else {
                Text("Enter valid RSS or Atom URL above.")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
        }
    }
    
    private var feedPreviewSection: some View {
        Section("Feed Preview") {
            feedPreview
        }
        .task {
            Task { @MainActor in
                reinitializeState()
            }
        }
//        .onChange(of: viewModel.feed) { [oldFeed = feed] feed in
//            Task { @MainActor in
//                guard oldFeed.id != feed.id else { return }
//                reinitializeState(feed: feed)
//            }
//        }
        .onChange(of: viewModel.feed.rssUrl, debounceTime: 1.5) { _ in
            Task { @MainActor in
                refreshFeed()
                refreshIcon()
                refreshFromOpenGraph()
            }
        }
        .onChange(of: viewModel.feed.entries) { [oldEntries = viewModel.feed.entries] entries in
            let entry = entries.max(by: { ($0.publicationDate ?? Date()) < ($1.publicationDate ?? Date()) })
            let oldEntry = oldEntries.max(by: { ($0.publicationDate ?? Date()) < ($1.publicationDate ?? Date()) })
            Task { @MainActor in
                if let entry = entry {
                    readerViewModel.content = entry
                } else {
                    readerViewModel.content = ReaderContentLoader.unsavedHome
                }
                if entry?.id != oldEntry?.id {
                    refresh(entries: Array(entries))
                    refreshFromOpenGraph()
                }
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
    
    var body: some View {
        if let opmlURL = viewModel.feed.category?.opmlURL, LibraryConfiguration.opmlURLs.contains(opmlURL) {
            synchronizationSection
        }
        feedLocationSection
        iconSection
        stylingSection
        feedPreviewSection
    }
   
    private func reinitializeState() {
        readerFeedEntry = nil
        readerViewModel.navigator.load(URLRequest(url: URL(string: "about:blank")!))
        
        refreshFromOpenGraph()
        if viewModel.feed.entries.isEmpty {
            refreshFeed()
        }
        if viewModel.feed.iconUrl.isNativeReaderView {
            refreshIcon()
        }
        refresh(entries: Array(viewModel.feed.entries))
    }
    
    private func refreshFeed() {
        Task {
            try await viewModel.feed.fetch()
        }
    }
    
    private func refreshFromOpenGraph() {
        Task { @MainActor in
            guard viewModel.feed.isUserEditable, !viewModel.feed.rssUrl.isNativeReaderView else { return }
            let url = viewModel.feed.entries.first?.url ?? viewModel.feed.rssUrl.domainURL
            do {
                let og = try await OpenGraph.fetch(url: url)
                guard let rawURL = og[.url], let url = URL(string: rawURL), url.domainURL == self.viewModel.feed.rssUrl.domainURL else { return }
                if viewModel.feed.title.isEmpty, let name = og[.siteName] ?? og[.title], !name.isEmpty {
                    viewModel.feedTitle = name
                }
                if viewModel.feed.markdownDescription.isEmpty, let description = og[.description], !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    viewModel.feedDescription = description
                }
            } catch {
                print(error)
            }
        }
    }
    
    private func refreshIcon() {
        guard viewModel.feed.iconUrl.isNativeReaderView, !viewModel.feed.rssUrl.isNativeReaderView else { return }
        let url = viewModel.feed.rssUrl.domainURL
        Task.detached {
            do {
                let favicon = try await FaviconFinder(
                    url: url,
                    preferredType: .html,
                    preferences: [
                        :
//                        .html: FaviconType.appleTouchIcon.rawValue,
//                        .ico: "favicon.ico",
//                        .webApplicationManifestFile: FaviconType.launcherIcon4x.rawValue
                    ],
                    downloadImage: false
                ).downloadFavicon()
                Task { @MainActor in
                    guard !viewModel.feed.iconUrl.isNativeReaderView else { return }
                    viewModel.feedIconURL = favicon.url.absoluteString
                }
            } catch let error {
                print("Error finding favicon: \(error)")
            }
        }
    }
    
    private func refresh(entries: [FeedEntry]? = nil, forceRefresh: Bool = false) {
        guard let feed = try! Realm(configuration: ReaderContentLoader.feedEntryRealmConfiguration).object(ofType: Feed.self, forPrimaryKey: viewModel.feed.id) else {
            readerFeedEntry = nil
            readerViewModel.navigator.load(URLRequest(url: URL(string: "about:blank")!))
            return
        }
        
        let entries: [FeedEntry] = entries ?? Array(feed.entries)
        Task { @MainActor in
//            if let entry = entries.max(by: { ($0.publicationDate ?? Date()) < ($1.publicationDate ?? Date()) }) {
            if let entry = entries.last {
                if forceRefresh || (entry.url != readerViewModel.state.pageURL && !readerViewModel.state.isProvisionallyNavigating) {
                    readerFeedEntry = entry
                    if readerViewModel.content != entry {
                        readerViewModel.navigator.load(content: entry)
                    }
                }
            } else {
                readerFeedEntry = nil
                readerViewModel.navigator.load(URLRequest(url: URL(string: "about:blank")!))
            }
        }
    }
}
