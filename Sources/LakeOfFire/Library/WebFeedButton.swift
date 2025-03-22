import SwiftUI
import RealmSwift
import SwiftUIWebView
import RealmSwiftGaps
import RealmSwift
import SwiftUtilities
import Combine

@MainActor
class WebFeedButtonViewModel<C: ReaderContentProtocol>: ObservableObject {
    @Published var libraryConfiguration: LibraryConfiguration?
    
    @Published var userCategories: [FeedCategory]? = nil
    @Published var feed: Feed?
    @Published var rssTitles: [String]?
    @Published var rssURLs: [URL]? {
        didSet {
            guard let rssURLs = rssURLs else { 
                feed = nil
                return
            }
            
            Task { @RealmBackgroundActor in
                rssURLsCancellables.forEach { $0.cancel() }
                guard let realm = await RealmBackgroundActor.shared.cachedRealm(for: LibraryDataManager.realmConfiguration) else { return }
                realm.objects(Feed.self)
                    .where { !$0.isDeleted }
                    .collectionPublisher
                    .freeze()
                    .debounce(for: .seconds(0.1), scheduler: RunLoop.main)
                    .sink(receiveCompletion: { _ in}, receiveValue: { [weak self] feeds in
                        guard let self else { return }
                        guard let feed = feeds.first(where: { rssURLs.contains($0.rssUrl) }) else {
                            Task { @MainActor [weak self] in
                                self?.feed = nil
                            }
                            return
                        }
                        let ref = ThreadSafeReference(to: feed)
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            let realm = try await Realm(configuration: LibraryDataManager.realmConfiguration, actor: MainActor.shared)
                            if let feed = realm.resolve(ref) {
                                self.feed = feed
                            }
                        }
                    })
                    .store(in: &rssURLsCancellables)
            }
        }
    }
    
    @RealmBackgroundActor private var readerContentObjectNotificationToken: NotificationToken?
    
    var isDisabled: Bool {
        return rssURLs?.isEmpty ?? true
    }

    @RealmBackgroundActor
    private var rssURLsCancellables = Set<AnyCancellable>()
    @RealmBackgroundActor
    private var cancellables = Set<AnyCancellable>()

    init() {
        Task { @RealmBackgroundActor [weak self] in
            guard let realm = await RealmBackgroundActor.shared.cachedRealm(for: LibraryDataManager.realmConfiguration) else { return }
            
            realm.objects(LibraryConfiguration.self)
                .collectionPublisher
                .subscribe(on: libraryDataQueue)
                .map { _ in }
                .debounce(for: .seconds(0.3), scheduler: libraryDataQueue)
                .sink(receiveCompletion: { _ in }, receiveValue: { _ in
                    Task { @RealmBackgroundActor in
                        let libraryConfiguration = try await LibraryConfiguration.getConsolidatedOrCreate()
                        let libraryConfigurationID = libraryConfiguration.id
                        
                        try await { @MainActor [weak self] in
                            guard let self else { return }
                            let realm = try await Realm(configuration: LibraryDataManager.realmConfiguration, actor: MainActor.shared)
                            let libraryConfiguration = realm.object(ofType: LibraryConfiguration.self, forPrimaryKey: libraryConfigurationID)
                            self.libraryConfiguration = libraryConfiguration
                            setCategories(from: libraryConfiguration)

                        }()
                    }
                })
                .store(in: &cancellables)
        }
    }
    
    deinit {
        Task { @RealmBackgroundActor [weak readerContentObjectNotificationToken] in
            readerContentObjectNotificationToken?.invalidate()
        }
    }
    
    func initialize(readerContent: C) {
        rssURLs = Array(readerContent.rssURLs)
        rssTitles = Array(readerContent.rssTitles)
        let ref = ThreadSafeReference(to: readerContent)
        guard let realmConfig = readerContent.realm?.configuration else { return }
        Task { @RealmBackgroundActor in
            readerContentObjectNotificationToken?.invalidate()
            guard let realm = await RealmBackgroundActor.shared.cachedRealm(for: realmConfig) else { return }
            guard let readerContent = realm.resolve(ref) else { return }
            readerContentObjectNotificationToken = readerContent
                .observe(keyPaths: ["rssURLs", "isRSSAvailable", "rssTitles"]) { [weak self] change in
                    guard let self = self else { return }
                    switch change {
                    case .change(let object, _):
                        guard let readerContent = object as? C else { return }
                        let rssURLs = Array(readerContent.rssURLs)
                        let rssTitles = Array(readerContent.rssTitles)
                        Task { @MainActor [weak self] in
                            self?.rssURLs = rssURLs
                            self?.rssTitles = rssTitles
                        }
                    case .deleted:
                        Task { @MainActor [weak self] in
                            self?.rssURLs = nil
                            self?.rssTitles = nil
                        }
                    case .error(let error):
                        print("An error occurred: \(error)")
                    }
                }
        }
    }
    
    @MainActor
    private func setCategories(from libraryConfiguration: LibraryConfiguration?) {
        guard let libraryConfiguration = libraryConfiguration else {
            userCategories = nil
            return
        }
        userCategories = Array(libraryConfiguration.getActiveCategories()?.filter { $0.opmlURL == nil } ?? [])
    }
}

@available(iOS 16.0, macOS 13.0, *)
struct WebFeedMenuAddButtons<C: ReaderContentProtocol>: View {
    @ObservedObject private var viewModel: WebFeedButtonViewModel<C>
    let url: URL
    let title: String
    
    @EnvironmentObject private var libraryViewModel: LibraryManagerViewModel
    
    @Environment(\.openWindow) var openWindow
    
    var body: some View {
        if let userCategories = viewModel.userCategories {
            if userCategories.isEmpty {
                Text("You must create your own category for RSS feeds.")
                Button {
                    LibraryManagerViewModel.shared.isLibraryPresented = true
                    Task { @MainActor in
                        try await LibraryDataManager.shared.createEmptyCategory(addToLibrary: true)
                    }
                } label: {
                    Label("New Library Category", systemImage: "square.and.pencil")
                }
            } else {
                ForEach(userCategories) { category in
                    Button("Add Feed to \(category.title)") {
                        Task { @MainActor in
                            try await libraryViewModel.add(rssURL: url, title: title, toCategory: ThreadSafeReference(to: category))
#if os(macOS)
                            openWindow(id: "user-library")
#else
                            libraryViewModel.isLibraryPresented = true
#endif
                        }
                    }
                }
            }
        } else {
            Button("Add Feed to User Library") {
                Task { @MainActor in
                    try await libraryViewModel.add(rssURL: url, title: title)
#if os(macOS)
                    openWindow(id: "user-library")
#else
                    libraryViewModel.isLibraryPresented = true
#endif
                }
            }
        }
    }
    
    init(viewModel: WebFeedButtonViewModel<C>, url: URL, title: String) {
        self.viewModel = viewModel
        self.url = url
        self.title = title
    }
}

@available(iOS 16.0, macOS 13.0, *)
public struct WebFeedButton<C: ReaderContentProtocol>: View {
    @ObservedObject var readerContent: C
    
    @EnvironmentObject private var libraryViewModel: LibraryManagerViewModel
    @EnvironmentObject private var scriptCaller: WebViewScriptCaller
    
    @StateObject private var viewModel = WebFeedButtonViewModel<C>()
    
    public var body: some View {
        Menu {
            if let feed = viewModel.feed, !feed.isDeleted, let category = feed.getCategory() {
                Button("Edit Feed in Library") {
                    libraryViewModel.navigationPath.removeLast(libraryViewModel.navigationPath.count)
                    libraryViewModel.navigationPath.append(category)
                    libraryViewModel.selectedFeed = feed
                    LibraryManagerViewModel.shared.isLibraryPresented = true
                }
            } else if let rssURLs = viewModel.rssURLs, let rssTitles = viewModel.rssTitles {
                ForEach(Array(zip(rssURLs.indices, rssURLs)), id: \.1) { (idx, url) in
                    let title = rssTitles[idx]
                    if rssURLs.count == 1 {
                        WebFeedMenuAddButtons(viewModel: viewModel, url: url, title: title)
                    } else {
                        Menu("Add Feed \"\(title)\"") {
                            WebFeedMenuAddButtons(viewModel: viewModel, url: url, title: title)
                        }
                    }
                }
                Divider()
                Button( "Manage Library Categories") {
                    libraryViewModel.navigationPath.removeLast(libraryViewModel.navigationPath.count)
                    LibraryManagerViewModel.shared.isLibraryPresented = true
                }
            }
        } label: {
            Label("RSS Feed", systemImage:  "dot.radiowaves.up.forward")
        }
        .disabled(viewModel.isDisabled)
        .fixedSize()
        .task { @MainActor in
            viewModel.initialize(readerContent: readerContent)
        }
    }
    
    public init(readerContent: C) {
        self.readerContent = readerContent
    }
}

@available(iOS 16, macOS 13.0, *)
public extension ReaderContentProtocol {
    var webFeedButtonView: some View {
        WebFeedButton(readerContent: self)
    }
}
