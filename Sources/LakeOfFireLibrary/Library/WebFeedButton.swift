import SwiftUI
import RealmSwift
import SwiftUIWebView
import RealmSwiftGaps
import RealmSwift
import SwiftUtilities
import Combine
import LakeOfFireCore
import LakeOfFireAdblock
import LakeOfFireContent

@MainActor
final class WebFeedButtonLibraryState: ObservableObject {
    static let shared = WebFeedButtonLibraryState()

    @Published var libraryConfiguration: LibraryConfiguration?
    @Published var userCategories: [FeedCategory]? = nil
    @Published private var feedsByRSSURL: [URL: Feed] = [:]

    nonisolated(unsafe) private var cancellables = Set<AnyCancellable>()
    private var hasStartedObservation = false

    private init() { }

    func startIfNeeded() {
        guard !hasStartedObservation else { return }
        hasStartedObservation = true
        Task { @RealmBackgroundActor [weak self] in
            guard let self else { return }
            do {
                let realm = try await RealmBackgroundActor.shared.cachedRealm(for: LibraryDataManager.realmConfiguration)
                try await self.refreshLibraryConfiguration()
                try await self.refreshFeeds(from: realm)

                realm.objects(LibraryConfiguration.self)
                    .collectionPublisher
                    .subscribe(on: libraryDataQueue)
                    .map { @Sendable _ in }
                    .debounceLeadingTrailing(for: .seconds(0.3), scheduler: libraryDataQueue)
                    .sink(receiveCompletion: { @Sendable _ in }, receiveValue: { @Sendable [weak self] _ in
                        Task { @RealmBackgroundActor [weak self] in
                            try await self?.refreshLibraryConfiguration()
                        }
                    })
                    .store(in: &self.cancellables)

                realm.objects(Feed.self)
                    .where { !$0.isDeleted }
                    .collectionPublisher
                    .subscribe(on: libraryDataQueue)
                    .map { @Sendable _ in }
                    .debounceLeadingTrailing(for: .seconds(0.1), scheduler: libraryDataQueue)
                    .sink(receiveCompletion: { @Sendable _ in }, receiveValue: { @Sendable [weak self] _ in
                        Task { @RealmBackgroundActor [weak self] in
                            guard let self else { return }
                            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: LibraryDataManager.realmConfiguration)
                            try await self.refreshFeeds(from: realm)
                        }
                    })
                    .store(in: &self.cancellables)
            } catch {
                await MainActor.run { [weak self] in
                    self?.hasStartedObservation = false
                }
                print(error)
            }
        }
    }

    @RealmBackgroundActor
    private func refreshLibraryConfiguration() async throws {
        let libraryConfiguration = try await LibraryConfiguration.getConsolidatedOrCreate()
        let libraryConfigurationID = libraryConfiguration.id

        try await { @MainActor [weak self] in
            guard let self else { return }
            let realm = try await Realm.open(configuration: LibraryDataManager.realmConfiguration)
            let libraryConfiguration = realm.object(ofType: LibraryConfiguration.self, forPrimaryKey: libraryConfigurationID)
            self.libraryConfiguration = libraryConfiguration
            self.setCategories(from: libraryConfiguration)
        }()
    }

    @RealmBackgroundActor
    private func refreshFeeds(from realm: Realm) async throws {
        var feedIDs: [UUID] = []
        for feed in realm.objects(Feed.self).where({ !$0.isDeleted }) {
            feedIDs.append(feed.id)
        }

        try await { @MainActor [weak self] in
            guard let self else { return }
            let realm = try await Realm.open(configuration: LibraryDataManager.realmConfiguration)
            var feedsByRSSURL: [URL: Feed] = [:]
            for feedID in feedIDs {
                guard let feed = realm.object(ofType: Feed.self, forPrimaryKey: feedID) else {
                    continue
                }
                if feedsByRSSURL[feed.rssUrl] == nil {
                    feedsByRSSURL[feed.rssUrl] = feed
                }
            }
            self.feedsByRSSURL = feedsByRSSURL
        }()
    }

    private func setCategories(from libraryConfiguration: LibraryConfiguration?) {
        guard let libraryConfiguration = libraryConfiguration else {
            userCategories = nil
            return
        }
        userCategories = Array(libraryConfiguration.getActiveCategories()?.filter { $0.opmlURL == nil } ?? [])
    }

    func feed(matching rssURLs: [URL]) -> Feed? {
        rssURLs.lazy.compactMap { self.feedsByRSSURL[$0] }.first
    }
}

@available(iOS 16.0, macOS 13.0, *)
struct WebFeedMenuAddButtons: View {
    let userCategories: [FeedCategory]?
    let url: URL
    let title: String
    
    @EnvironmentObject private var libraryViewModel: LibraryManagerViewModel
    
    @Environment(\.openWindow) var openWindow
    
    var body: some View {
        if let userCategories {
            Group {
                ForEach(userCategories) { category in
                    Button {
                        Task { @MainActor in
                            try await libraryViewModel.add(rssURL: url, title: title, toCategory: ThreadSafeReference(to: category))
#if os(macOS)
                            openWindow(id: "user-library")
#else
                            libraryViewModel.isLibraryPresented = true
#endif
                        }
                    } label: {
                        Label("Add Feed to \(category.title.isEmpty ? "Untitled" : category.title)", systemImage: "plus")
                    }
                }
            }
        } else {
            Button {
                Task { @MainActor in
                    try await libraryViewModel.add(rssURL: url, title: title)
#if os(macOS)
                    openWindow(id: "user-library")
#else
                    libraryViewModel.isLibraryPresented = true
#endif
                }
            } label: {
                Label("Add Feed to My Library", systemImage: "plus")
            }
        }
    }
    
    init(userCategories: [FeedCategory]?, url: URL, title: String) {
        self.userCategories = userCategories
        self.url = url
        self.title = title
    }
}

@available(iOS 16.0, macOS 13.0, *)
public struct WebFeedButton<C: ReaderContentProtocol>: View {
    @ObservedObject var readerContent: C
    
    @EnvironmentObject private var libraryViewModel: LibraryManagerViewModel
    @EnvironmentObject private var scriptCaller: WebViewScriptCaller
    
    @ObservedObject private var libraryState = WebFeedButtonLibraryState.shared
    
    public var body: some View {
        let rssURLs = Array(readerContent.rssURLs)
        let rssTitles = Array(readerContent.rssTitles)

        Menu {
            Group {
                if let feed = libraryState.feed(matching: rssURLs), !feed.isDeleted, let category = feed.getCategory() {
                    Button("Edit Feed in Library…") {
                        libraryViewModel.navigationPath.removeLast(libraryViewModel.navigationPath.count)
                        libraryViewModel.navigationPath.append(category)
                        libraryViewModel.selectedFeed = feed
                        LibraryManagerViewModel.shared.isLibraryPresented = true
                    }
                } else if !rssURLs.isEmpty {
                    ForEach(Array(rssURLs.indices), id: \.self) { idx in
                        let url = rssURLs[idx]
                        let title = idx < rssTitles.count ? rssTitles[idx] : url.absoluteString
                        if rssURLs.count == 1 {
                            WebFeedMenuAddButtons(
                                userCategories: libraryState.userCategories,
                                url: url,
                                title: title
                            )
                        } else {
                            Menu("Add Feed \"\(title)\"") {
                                WebFeedMenuAddButtons(
                                    userCategories: libraryState.userCategories,
                                    url: url,
                                    title: title
                                )
                            }
                        }
                    }
                    Divider()
                    Button("Manage Library Categories…") {
                        libraryViewModel.navigationPath.removeLast(libraryViewModel.navigationPath.count)
                        LibraryManagerViewModel.shared.isLibraryPresented = true
                    }
                }
            }
            .labelStyle(.titleAndIcon)
        } label: {
            Label("RSS Feed", systemImage:  "dot.radiowaves.up.forward")
        }
        .disabled(rssURLs.isEmpty)
        .fixedSize()
        .task { @MainActor in
            libraryState.startIfNeeded()
        }
    }
    
    public init(readerContent: C) {
        self.readerContent = readerContent
    }
}

@available(iOS 16, macOS 13.0, *)
public extension ReaderContentProtocol {
    @MainActor
    var webFeedButtonView: some View {
        WebFeedButton(readerContent: self)
    }
}
