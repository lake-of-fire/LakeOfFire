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
        VStack(spacing: 0) {
            if let libraryFeedFormSectionsViewModel = libraryFeedFormSectionsViewModel {
                Form {
                    LibraryFeedFormSections(viewModel: libraryFeedFormSectionsViewModel)
                        .disabled(!feed.isUserEditable())
                }
                .formStyle(.grouped)
            }
        }
        .task(id: feed.id) { @MainActor in
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
    
    @Published var feedEntries: [FeedEntry]?

    var cancellables = Set<AnyCancellable>()
    
    @RealmBackgroundActor
    var realmCancellables = Set<AnyCancellable>()
    @RealmBackgroundActor
    private var objectNotificationToken: NotificationToken?
    
    init(feed: Feed) {
        self.feed = feed
        // TODO: only resolve this once instead of repeatedly below...
        let feedID = feed.id
        Task { @RealmBackgroundActor [weak self] in
            guard let self = self else { return }
            guard let realm = await RealmBackgroundActor.shared.cachedRealm(for: LibraryDataManager.realmConfiguration) else { return }
            guard let feed = realm.object(ofType: Feed.self, forPrimaryKey: feedID) else { return }
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
            
            realm.objects(FeedEntry.self)
                .where { $0.feedID == feedID }
                .collectionPublisher
                .subscribe(on: libraryDataQueue)
                .map { _ in }
                .debounce(for: .seconds(0.5), scheduler: libraryDataQueue)
                .sink(receiveCompletion: { _ in }, receiveValue: { _ in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        let realm = try await Realm(configuration: LibraryDataManager.realmConfiguration, actor: MainActor.shared)
                        self.feedEntries = realm.objects(FeedEntry.self).where { $0.feedID == feedID } .map { $0 }
                    }
                })
                .store(in: &realmCancellables)

            await refresh()
        }
        
        func writeFeedAsync(_ block: @escaping (Feed) -> Void) {
            Task { @RealmBackgroundActor in
                guard let realm = await RealmBackgroundActor.shared.cachedRealm(for: LibraryDataManager.realmConfiguration) else { return }
                guard let feed = realm.object(ofType: Feed.self, forPrimaryKey: feedID) else { return }
                await realm.asyncRefresh()
                try await realm.asyncWrite {
                    block(feed)
                    feed.modifiedAt = Date()
                }
            }
        }
        
        $feedTitle
            .dropFirst()
            .removeDuplicates()
            .debounce(for: .seconds(0.35), scheduler: DispatchQueue.main)
            .sink { feedTitle in
                writeFeedAsync { feed in
                    feed.title = feedTitle
                }
            }
            .store(in: &cancellables)
        $feedDescription
            .dropFirst()
            .removeDuplicates()
            .debounce(for: .seconds(0.35), scheduler: DispatchQueue.main)
            .sink { feedDescription in
                writeFeedAsync { feed in
                    feed.markdownDescription = feedDescription
                }
            }
            .store(in: &cancellables)
        $feedEnabled
            .dropFirst()
            .removeDuplicates()
            .sink { feedEnabled in
                writeFeedAsync { feed in
                    feed.isArchived = !feedEnabled
                }
            }
            .store(in: &cancellables)
        $feedURL
            .dropFirst()
            .removeDuplicates()
            .debounce(for: .seconds(0.35), scheduler: DispatchQueue.main)
            .sink { feedURL in
                writeFeedAsync { feed in
                    if feedURL.isEmpty {
                        feed.rssUrl = URL(string: "about:blank")!
                    } else if let url = URL(string: feedURL) {
                        feed.rssUrl = url
                    }
                }
            }
            .store(in: &cancellables)
        $feedIconURL
            .dropFirst()
            .removeDuplicates()
            .debounce(for: .seconds(0.35), scheduler: DispatchQueue.main)
            .sink { feedIconURL in
                writeFeedAsync { feed in
                    if feedIconURL.isEmpty {
                        feed.iconUrl = URL(string: "about:blank")!
                    } else if let url = URL(string: feedIconURL) {
                        feed.iconUrl = url
                    }
                }
            }
            .store(in: &cancellables)
        $feedIsReaderModeByDefault
            .dropFirst()
            .removeDuplicates()
            .sink { feedIsReaderModeByDefault in
                writeFeedAsync { feed in
                    feed.isReaderModeByDefault = feedIsReaderModeByDefault
                }
            }
            .store(in: &cancellables)
        $feedInjectEntryImageIntoHeader
            .dropFirst()
            .removeDuplicates()
            .sink { feedInjectEntryImageIntoHeader in
                writeFeedAsync { feed in
                    feed.injectEntryImageIntoHeader = feedInjectEntryImageIntoHeader
                }
            }
            .store(in: &cancellables)
        $feedExtractImageFromContent
            .dropFirst()
            .removeDuplicates()
            .sink { feedExtractImageFromContent in
                writeFeedAsync { feed in
                    feed.extractImageFromContent = feedExtractImageFromContent
                }
            }
            .store(in: &cancellables)
        $feedRssContainsFullContent
            .dropFirst()
            .removeDuplicates()
            .sink { feedRssContainsFullContent in
                writeFeedAsync { feed in
                    feed.rssContainsFullContent = feedRssContainsFullContent
                }
            }
            .store(in: &cancellables)
        $feedDisplayPublicationDate
            .dropFirst()
            .removeDuplicates()
            .sink { feedDisplayPublicationDate in
                writeFeedAsync { feed in
                    feed.displayPublicationDate = feedDisplayPublicationDate
                }
            }
            .store(in: &cancellables)
    }
    
    deinit {
        Task { @RealmBackgroundActor [weak objectNotificationToken] in
            objectNotificationToken?.invalidate()
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
            try await Realm.asyncWrite(ThreadSafeReference(to: feed), configuration: LibraryDataManager.realmConfiguration) { _, feed in
                feed.rssUrl = URL(string: strings.first ?? "") ?? URL(string: "about:blank")!
                feed.modifiedAt = Date()
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
    
//    @State private var readerContent: (any ReaderContentProtocol) = ReaderContentLoader.unsavedHome
//    @State private var readerState = WebViewState.empty
//    @State private var readerAction = WebViewAction.idle
    @StateObject private var readerContent = ReaderContent()
    @StateObject private var readerViewModel = ReaderViewModel(realmConfiguration: LibraryDataManager.realmConfiguration, systemScripts: [])
    @StateObject private var readerModeViewModel = ReaderModeViewModel()
    @StateObject private var readerLocationBarViewModel = ReaderLocationBarViewModel()
    @StateObject private var readerMediaPlayerViewModel = ReaderMediaPlayerViewModel()

    @State private var readerFeedEntry: FeedEntry?
    
    @EnvironmentObject private var readerFileManager: ReaderFileManager
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
                if viewModel.feed.isUserEditable() {
                    PasteButton(payloadType: String.self) { strings in
                        viewModel.pasteRSSURL(strings: strings)
                    }
                }
            }
        } header: {
            Text("Feed")
        } footer: {
            Text("Feeds use RSS or Atom syndication formats.").font(.footnote).foregroundColor(.secondary)
        }
    }
    
    @ViewBuilder private var iconSection: some View {
        Section("Icon URL") {
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
//            persistentWebViewID: "library-feed-preview-\(viewModel.feed.id.uuidString)",
            bounces: false)
        .environmentObject(readerContent)
        .environmentObject(readerViewModel)
        .environmentObject(readerModeViewModel)
        .environmentObject(readerLocationBarViewModel)
        .environmentObject(readerMediaPlayerViewModel)
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
                        PageURLLinkButton()
                            .environmentObject(readerViewModel)
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
    
    @ViewBuilder private var feedPreviewSection: some View {
        Section("Feed Preview") {
            feedPreview
        }
        .task(id: viewModel.feed.id) { @MainActor in
            reinitializeState()
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
        .onChange(of: viewModel.feedEntries ?? []) { [oldEntries = viewModel.feedEntries] entries in
            let entry = entries.max(by: { ($0.publicationDate ?? Date()) < ($1.publicationDate ?? Date()) })
            let oldEntry = oldEntries?.max(by: { ($0.publicationDate ?? Date()) < ($1.publicationDate ?? Date()) })
            Task { @MainActor in
                if let entry = entry {
                    readerContent.content = entry
                } else {
                    readerContent.content = ReaderContentLoader.unsavedHome
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
        feedTitleSection
        if let opmlURL = viewModel.feed.getCategory()?.opmlURL, LibraryConfiguration.opmlURLs.contains(opmlURL) {
            synchronizationSection
        }
        feedLocationSection
        iconSection
        stylingSection
        feedPreviewSection
    }
   
    private func reinitializeState() {
        readerFeedEntry = nil
        readerViewModel.navigator?.load(URLRequest(url: URL(string: "about:blank")!))
        
        refreshFromOpenGraph()
        if viewModel.feed.getEntries()?.isEmpty ?? true {
            refreshFeed()
        }
        if viewModel.feed.iconUrl.isNativeReaderView {
            refreshIcon()
        }
        refresh(entries: Array(viewModel.feed.getEntries() ?? []))
    }
    
    private func refreshFeed() {
        Task {
            try await viewModel.feed.fetch()
        }
    }
    
    private func refreshFromOpenGraph() {
        Task { @MainActor in
            guard viewModel.feed.isUserEditable(), !viewModel.feed.rssUrl.isNativeReaderView else { return }
            let url = viewModel.feed.getEntries()?.first?.url ?? viewModel.feed.rssUrl.domainURL
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
                await Task { @MainActor in
                    guard !viewModel.feed.iconUrl.isNativeReaderView else { return }
                    viewModel.feedIconURL = favicon.url.absoluteString
                }.value
            } catch let error {
                print("Error finding favicon: \(error)")
            }
        }
    }
    
    private func refresh(entries: [FeedEntry]? = nil, forceRefresh: Bool = false) {
        guard let feed = try! Realm(configuration: ReaderContentLoader.feedEntryRealmConfiguration).object(ofType: Feed.self, forPrimaryKey: viewModel.feed.id) else {
            readerFeedEntry = nil
            readerViewModel.navigator?.load(URLRequest(url: URL(string: "about:blank")!))
            return
        }
        
        let entries: [FeedEntry] = entries ?? Array(feed.getEntries() ?? [])
        Task { @MainActor in
//            if let entry = entries.max(by: { ($0.publicationDate ?? Date()) < ($1.publicationDate ?? Date()) }) {
            if let entry = entries.last {
                if forceRefresh || (entry.url != readerViewModel.state.pageURL && !readerViewModel.state.isProvisionallyNavigating) {
                    readerFeedEntry = entry
                    if let content = readerContent.content, content != entry {
                        try await readerViewModel.navigator?.load(content: entry, readerFileManager: readerFileManager)
                    }
                }
            } else {
                readerFeedEntry = nil
                readerViewModel.navigator?.load(URLRequest(url: URL(string: "about:blank")!))
            }
        }
    }
}

fileprivate struct PageURLLinkButton: View {
    @Environment(\.openURL) private var openURL
    
    @EnvironmentObject private var readerViewModel: ReaderViewModel

    var body: some View {
        Button(readerViewModel.state.pageURL.absoluteString) {
            openURL(readerViewModel.state.pageURL)
        }
#if os(macOS)
        .buttonStyle(.link)
#endif
    }
}
