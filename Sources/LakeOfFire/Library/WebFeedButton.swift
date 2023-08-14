import SwiftUI
import RealmSwift
import SwiftUIWebView
import SwiftUtilities

@available(iOS 16.0, macOS 13.0, *)
struct WebFeedMenuAddButtons: View {
    @ObservedRealmObject var libraryConfiguration: LibraryConfiguration
    let url: URL
    let title: String
    @Binding var isLibraryPresented: Bool
    @ObservedObject var libraryViewModel = LibraryManagerViewModel()
    
    @Environment(\.openWindow) var openWindow
    
    var body: some View {
        let userCategories = libraryConfiguration.userCategories
        if userCategories.isEmpty {
            Button("Add Feed to User Library") {
                libraryViewModel.add(rssURL: url, title: title)
#if os(macOS)
                openWindow(id: "user-library")
#else
                isLibraryPresented = true
#endif
            }
        } else {
            ForEach(userCategories) { category in
                Button("Add Feed to \(category.title)") {
                    libraryViewModel.add(rssURL: url, title: title, toCategory: category.freeze())
#if os(macOS)
                    openWindow(id: "user-library")
#else
                    isLibraryPresented = true
#endif
                }
            }
        }
    }
}

@available(iOS 16.0, macOS 13.0, *)
public struct WebFeedButton: View {
    @ObservedRealmObject var libraryConfiguration: LibraryConfiguration
    @Binding var readerContent: any ReaderContentModel
    
    @ObservedResults(FeedCategory.self, configuration: LibraryDataManager.realmConfiguration, where: { $0.isDeleted == false }) private var categories
    @ObservedResults(Feed.self, configuration: LibraryDataManager.realmConfiguration, where: { $0.isDeleted == false }) var feeds
    
    @State private var feed: Feed?
    @State private var isLibraryPresented = false
    
    @EnvironmentObject private var scriptCaller: WebViewScriptCaller
    
    @StateObject private var libraryViewModel = LibraryManagerViewModel()
    
    private var isDisabled: Bool {
        return readerContent.rssURLs.isEmpty
    }
    
    public  var body: some View {
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
                        WebFeedMenuAddButtons(libraryConfiguration: libraryConfiguration, url: url, title: title, isLibraryPresented: $isLibraryPresented, libraryViewModel: libraryViewModel)
                    } else {
                        Menu("Add Feed \"\(title)\"") {
                            WebFeedMenuAddButtons(libraryConfiguration: libraryConfiguration, url: url, title: title, isLibraryPresented: $isLibraryPresented, libraryViewModel: libraryViewModel)
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
    
    public init(libraryConfiguration: LibraryConfiguration, readerContent: Binding<any ReaderContentModel>) {
        self.libraryConfiguration = libraryConfiguration
        _readerContent = readerContent
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
