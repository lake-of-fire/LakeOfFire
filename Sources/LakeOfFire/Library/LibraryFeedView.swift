import SwiftUI
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
    
    func unfrozen(_ feed: Feed) -> Feed {
        return feed.isFrozen ? feed.thaw() ?? feed : feed
    }
    
    var body: some View {
        Form {
            LibraryFeedFormSections(feed: feed)
            .disabled(!feed.isUserEditable)
        }
        .formStyle(.grouped)
    }
}

@available(iOS 16.0, macOS 13, *)
struct LibraryFeedFormSections: View {
    @ObservedRealmObject var feed: Feed
    
    @ScaledMetric(relativeTo: .body) private var textEditorHeight = 80
    @ScaledMetric(relativeTo: .body) private var readerPreviewHeight = 480
    @ScaledMetric(relativeTo: .body) private var readerPreviewLocationBarHeight = 40
    
//    @State private var readerContent: (any ReaderContentModel) = ReaderContentLoader.unsavedHome
//    @State private var readerState = WebViewState.empty
//    @State private var readerAction = WebViewAction.idle
    @StateObject private var readerViewModel = ReaderViewModel(realmConfiguration: LibraryDataManager.realmConfiguration, systemScripts: [])
    
    @State private var readerFeedEntry: FeedEntry?
    @State private var feedTitle = ""
    @State private var feedDescription = ""
    
    @Environment(\.openURL) private var openURL

    private func unfrozen(_ feed: Feed) -> Feed {
        return feed.isFrozen ? feed.thaw() ?? feed : feed
    }
    
    private var synchronizationSection: some View {
        Section("Synchronized") {
            Text("Manabi Reader manages this feed for you.")
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    
    private var feedLocationSection: some View {
        Section(header: Group {
            HStack(alignment: .bottom) {
                if !feed.iconUrl.isNativeReaderView {
                    LakeImage(feed.iconUrl)
                        .frame(maxWidth: 44, maxHeight: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                if feed.isUserEditable {
                    TextField("", text: $feedTitle, prompt: Text("Enter website title"))
                        .textCase(nil)
                        .font(.headline)
                } else {
                    Text(feed.title)
                        .textCase(nil)
                        .font(.headline)
                }
            }
        }, footer: Text("Feeds are either RSS or Atom web syndication formats. Look for the RSS icon button that appears in Manabi Reader's main toolbar menus which indicates RSS or Atom availability on any page you visit.").font(.footnote).foregroundColor(.secondary)) {
            Toggle("Enabled", isOn: Binding(get: { !feed.isArchived }, set: { isEnabled in
                safeWrite(feed) { $1.isArchived = !isEnabled }}))
            HStack {
                TextField("Feed URL", text: Binding(
                    get: { feed.rssUrl.absoluteString },
                    set: { url in
                        guard feed.rssUrl.absoluteString != url else { return }
                        safeWrite(feed) { _, feed in
                            feed.rssUrl = URL(string: url) ?? feed.rssUrl
                        }
                    }), prompt: Text("Enter URL of RSS or Atom content"), axis: .vertical)
                if feed.isUserEditable {
                    PasteButton(payloadType: String.self) { strings in
                        Task { @MainActor in
                            safeWrite(feed) { _, feed in
                                feed.rssUrl = URL(string: strings.first ?? "") ?? URL(string: "about:blank")!
                            }
                        }
                    }
                }
            }
        }
    }
    
    private var iconSection: some View {
        Section {
            TextField("Icon URL", text: Binding(
                get: { feed.iconUrl.absoluteString },
                set: { url in
                    guard feed.iconUrl.absoluteString != url else { return }
                    safeWrite(feed) { _, feed in
                        feed.iconUrl = URL(string: url) ?? feed.iconUrl
                    }
                }), prompt: Text("Enter website icon URL"), axis: .vertical)
        }
    }
    
    private var descriptionSection: some View {
        Section("Description") {
            TextEditor(text: $feedDescription)
                .foregroundColor(.secondary)
                .frame(idealHeight: textEditorHeight)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }
    
    private var stylingSection: some View {
        Section("Feed Styling") {
            Group {
                Toggle("Automatic Reader Mode", isOn: $feed.isReaderModeByDefault)
                Toggle("Use feed image as article header", isOn: $feed.injectEntryImageIntoHeader)
                Toggle("Use content image in feed", isOn: $feed.extractImageFromContent)
                Toggle("Feed contains full content", isOn: $feed.rssContainsFullContent)
                Toggle("Display publication dates", isOn: $feed.displayPublicationDate)
            }
        }
    }
    
    private var previewReader: some View {
        Reader(
            readerViewModel: readerViewModel,
            persistentWebViewID: "library-feed-preview-\(feed.id.uuidString)",
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
        .onChange(of: feed) { [oldFeed = feed] feed in
            Task { @MainActor in
                guard oldFeed.id != feed.id else { return }
                reinitializeState(feed: feed)
            }
        }
        .onChange(of: feedTitle, debounceTime: 0.5) { text in
            Task.detached {
                await safeWrite(feed) { _, feed in
                    feed.title = text
                }
            }
        }
        .onChange(of: feedDescription, debounceTime: 0.5) { text in
            Task { @MainActor in
                safeWrite(feed) { _, feed in
                    feed.markdownDescription = text
                }
            }
        }
        .onChange(of: feed.rssUrl, debounceTime: 1.5) { _ in
            Task { @MainActor in
                refreshFeed()
                refreshIcon()
                refreshFromOpenGraph()
            }
        }
        .onChange(of: feed.entries) { [oldEntries = feed.entries] entries in
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
        .onChange(of: feed.isReaderModeByDefault) { isReaderModeByDefault in
            Task { @MainActor in
                safeWrite(readerViewModel.content) { _, content in
                    content.isReaderModeByDefault = isReaderModeByDefault
                }
                refresh(forceRefresh: true)
            }
        }
        .onChange(of: feed.injectEntryImageIntoHeader) { _ in
            refresh(forceRefresh: true)
        }
        .onChange(of: feed.rssContainsFullContent) { rssContainsFullContent in
            refresh(forceRefresh: true)
        }
     }
    
    var body: some View {
        if let opmlURL = feed.category?.opmlURL, LibraryConfiguration.opmlURLs.contains(opmlURL) {
            synchronizationSection
        }
        feedLocationSection
        iconSection
        stylingSection
        feedPreviewSection
    }
   
    private func reinitializeState(feed: Feed? = nil) {
        let feed = feed ?? self.feed
        feedTitle = feed.title
        feedDescription = feed.markdownDescription
        readerFeedEntry = nil
        readerViewModel.action = .load(URLRequest(url: URL(string: "about:blank")!))
        
        refreshFromOpenGraph()
        if feed.entries.isEmpty {
            refreshFeed(feed: feed)
        }
        if feed.iconUrl.isNativeReaderView {
            refreshIcon(feed: feed)
        }
        refresh(entries: Array(feed.entries))
    }
    
    private func refreshFeed(feed: Feed? = nil) {
        let feed = feed ?? self.feed
        Task { @MainActor in
            try await feed.fetch()
        }
    }
    
    private func refreshFromOpenGraph() {
        Task { @MainActor in
            guard feed.isUserEditable, !feed.rssUrl.isNativeReaderView else { return }
            let url = feed.entries.first?.url ?? feed.rssUrl.domainURL
            do {
                let og = try await OpenGraph.fetch(url: url)
                guard let rawURL = og[.url], let url = URL(string: rawURL), url.domainURL == self.feed.rssUrl.domainURL else { return }
                if feed.title.isEmpty, let name = og[.siteName] ?? og[.title], !name.isEmpty {
                    safeWrite(feed) { _, feed in
                        feed.title = name
                    }
                    feedTitle = name
                }
                if feed.markdownDescription.isEmpty, let description = og[.description], !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    safeWrite(feed) { _, feed in
                        feed.markdownDescription = description
                    }
                    feedDescription = description
                }
            } catch {
                print(error)
            }
        }
    }
    
    private func refreshIcon(feed: Feed? = nil) {
        let feed = feed ?? self.feed
        guard feed.iconUrl.isNativeReaderView, !feed.rssUrl.isNativeReaderView else { return }
        let url = feed.rssUrl.domainURL
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
                    guard feed.iconUrl.isNativeReaderView else { return }
                    safeWrite(feed) { _, feed in
                        feed.iconUrl = favicon.url
                    }
                }
            } catch let error {
                print("Error finding favicon: \(error)")
            }
        }
    }
    
    private func refresh(entries: [FeedEntry]? = nil, forceRefresh: Bool = false) {
        guard let feed = try! Realm(configuration: ReaderContentLoader.feedEntryRealmConfiguration).object(ofType: Feed.self, forPrimaryKey: feed.id) else {
            readerFeedEntry = nil
            readerViewModel.action = .load(URLRequest(url: URL(string: "about:blank")!))
            return
        }
        
        let entries: [FeedEntry] = entries ?? Array(feed.entries)
        Task { @MainActor in
//            if let entry = entries.max(by: { ($0.publicationDate ?? Date()) < ($1.publicationDate ?? Date()) }) {
            if let entry = entries.last {
                if forceRefresh || (entry.url != readerViewModel.state.pageURL && !readerViewModel.state.isProvisionallyNavigating), let load = WebViewAction.load(content: entry) {
                    readerFeedEntry = entry
                    if readerViewModel.action != load {
                        readerViewModel.action = load
                    }
                }
            } else {
                readerFeedEntry = nil
                readerViewModel.action = .load(URLRequest(url: URL(string: "about:blank")!))
            }
        }
    }
}
