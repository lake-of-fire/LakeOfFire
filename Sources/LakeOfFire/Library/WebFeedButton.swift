import SwiftUI
import RealmSwift
import SwiftUIWebView
import RealmSwiftGaps
import RealmSwift
import SwiftUtilities

@MainActor
class WebFeedButtonViewModel: ObservableObject {
    @Published var libraryConfiguration: LibraryConfiguration? {
        didSet {
            Task.detached { @RealmBackgroundActor [weak self] in
                guard let self = self else { return }
                let libraryConfiguration = try await LibraryConfiguration.getOrCreate()
                objectNotificationToken?.invalidate()
                objectNotificationToken = libraryConfiguration
                    .observe { [weak self] change in
                        guard let self = self else { return }
                        switch change {
                        case .change(_, _), .deleted:
                            Task { @MainActor [weak self] in
                                self?.objectWillChange.send()
                            }
                        case .error(let error):
                            print("An error occurred: \(error)")
                        }
                    }
            }
        }
    }
    
    @RealmBackgroundActor private var objectNotificationToken: NotificationToken?
    
    init() {
        Task.detached { @RealmBackgroundActor [weak self] in
            let libraryConfigurationRef = try await ThreadSafeReference(to: LibraryConfiguration.getOrCreate())
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let realm = try await Realm(configuration: LibraryDataManager.realmConfiguration, actor: RealmBackgroundActor.shared)
                guard let libraryConfiguration = realm.resolve(libraryConfigurationRef) else { return }
                self.libraryConfiguration = libraryConfiguration
            }
        }
    }
    
    deinit {
        Task.detached { @RealmBackgroundActor [weak self] in
            self?.objectNotificationToken?.invalidate()
        }
    }
}

@available(iOS 16.0, macOS 13.0, *)
struct WebFeedMenuAddButtons: View {
    @ObservedObject private var viewModel: WebFeedButtonViewModel
    let url: URL
    let title: String
    @Binding var isLibraryPresented: Bool
    @ObservedObject var libraryViewModel: LibraryManagerViewModel
    
    @Environment(\.openWindow) var openWindow
    
    var body: some View {
        if let userCategories = viewModel.libraryConfiguration?.userCategories {
            ForEach(userCategories) { category in
                Button("Add Feed to \(category.title)") {
                    Task { @MainActor in
                        try await libraryViewModel.add(rssURL: url, title: title, toCategory: ThreadSafeReference(to: category))
#if os(macOS)
                        openWindow(id: "user-library")
#else
                        isLibraryPresented = true
#endif
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
                    isLibraryPresented = true
#endif
                }
            }
        }
    }
    
    init(viewModel: WebFeedButtonViewModel, url: URL, title: String, isLibraryPresented: Binding<Bool>, libraryViewModel: LibraryManagerViewModel) {
        self.viewModel = viewModel
        self.url = url
        self.title = title
        _isLibraryPresented = isLibraryPresented
        self.libraryViewModel = libraryViewModel
    }
}

@available(iOS 16.0, macOS 13.0, *)
public struct WebFeedButton<C: ReaderContentModel>: View {
    var readerContent: C
    
    @ObservedResults(FeedCategory.self, configuration: LibraryDataManager.realmConfiguration, where: { $0.isDeleted == false }) private var categories
    @ObservedResults(Feed.self, configuration: LibraryDataManager.realmConfiguration, where: { $0.isDeleted == false }) var feeds
    
    @State private var feed: Feed?
    @State private var isLibraryPresented = false
    
    @EnvironmentObject private var scriptCaller: WebViewScriptCaller
    
    @StateObject private var viewModel = WebFeedButtonViewModel()
    @StateObject private var libraryViewModel = LibraryManagerViewModel()
    
    private var isDisabled: Bool {
        return readerContent.rssURLs.isEmpty
    }
    
    public var body: some View {
        Menu {
            if let feed = feed, !feed.isDeleted, let category = feed.category {
                Button("Edit Feed in Library") {
                    libraryViewModel.navigationPath.removeLast(libraryViewModel.navigationPath.count)
                    libraryViewModel.navigationPath.append(category)
                    libraryViewModel.selectedFeed = feed
                    isLibraryPresented = true
                }
            } else {
                ForEach(Array(readerContent.rssURLs.map ({ $0 }).enumerated()), id: \.element) { (idx, url) in
                    let title = readerContent.rssTitles[idx]
                    if readerContent.rssURLs.count == 1 {
                        WebFeedMenuAddButtons(viewModel: viewModel, url: url, title: title, isLibraryPresented: $isLibraryPresented, libraryViewModel: libraryViewModel)
                    } else {
                        Menu("Add Feed \"\(title)\"") {
                            WebFeedMenuAddButtons(viewModel: viewModel, url: url, title: title, isLibraryPresented: $isLibraryPresented, libraryViewModel: libraryViewModel)
                        }
                    }
                }
                Divider()
                Button("Manage Library Categories") {
                    libraryViewModel.navigationPath.removeLast(libraryViewModel.navigationPath.count)
                    isLibraryPresented = true
                }
            }
        } label: {
            Label("RSS Feed", systemImage:  "dot.radiowaves.up.forward")
        }
        .disabled(isDisabled)
        .fixedSize()
        .sheet(isPresented: $isLibraryPresented) {
            LibraryManagerView(isPresented: $isLibraryPresented, viewModel: libraryViewModel)
#if os(macOS)
                .frame(minWidth: 500, minHeight: 400)
#endif
        }
        .task {
            refresh()
        }
        .onChange(of: feeds) { _ in
            refresh()
        }
        .onChange(of: readerContent.isRSSAvailable) { _ in
            refresh()
        }
    }
    
    public init(readerContent: C) {
        self.readerContent = readerContent
    }
    
    private func refresh() {
        let rssURLs = Array(readerContent.rssURLs)
        Task.detached {
            let realm = try! Realm(configuration: LibraryDataManager.realmConfiguration)
            let feed = realm.objects(Feed.self).filter { rssURLs.map({ $0 }).contains($0.rssUrl) }.first?.freeze()
            Task { @MainActor in
                guard let feed = feed?.thaw() else { return }
                self.feed = feed
            }
        }
    }
}

@available(iOS 16, macOS 13.0, *)
public extension ReaderContentModel {
    var webFeedButtonView: some View {
        WebFeedButton(readerContent: self)
    }
}
