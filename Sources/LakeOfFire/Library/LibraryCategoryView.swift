import SwiftUI
import RealmSwift
import FilePicker
import UniformTypeIdentifiers
import OPML
import SwiftUIWebView
import FaviconFinder
import DebouncedOnChange
import OpenGraph
import RealmSwiftGaps
import Combine
import SwiftUtilities

@MainActor
class LibraryCategoryViewModel: ObservableObject {
    let category: FeedCategory
    let libraryConfiguration: LibraryConfiguration
    @Binding var selectedFeed: Feed?
    
    @Published var categoryTitle = ""
    @Published var categoryBackgroundImageURL = ""
    
    var cancellables = Set<AnyCancellable>()
    @RealmBackgroundActor private var objectNotificationToken: NotificationToken?
    
    init(category: FeedCategory, libraryConfiguration: LibraryConfiguration, selectedFeed: Binding<Feed?>) {
        self.category = category
        self.libraryConfiguration = libraryConfiguration
        _selectedFeed = selectedFeed
        
        let ref = ThreadSafeReference(to: category)
        Task.detached { @RealmBackgroundActor [weak self] in
            guard let self = self else { return }
            let realm = try await Realm(configuration: LibraryDataManager.realmConfiguration, actor: RealmBackgroundActor.shared)
            guard let category = realm.resolve(ref) else { return }
            objectNotificationToken = category
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
        
        $categoryTitle
            .removeDuplicates()
            .debounce(for: .seconds(0.35), scheduler: DispatchQueue.main)
            .sink { [weak self] categoryTitle in
                Task { [weak self] in
                    guard let self = self else { return }
                    try await Realm.asyncWrite(ThreadSafeReference(to: category), configuration: LibraryDataManager.realmConfiguration) { _, category in
                        category.title = categoryTitle
                    }
                }
            }
            .store(in: &cancellables)
        $categoryBackgroundImageURL
            .removeDuplicates()
            .debounce(for: .seconds(0.35), scheduler: DispatchQueue.main)
            .sink { [weak self] categoryBackgroundImageURL in
                Task { [weak self] in
                    guard let self = self else { return }
                    try await Realm.asyncWrite(ThreadSafeReference(to: category), configuration: LibraryDataManager.realmConfiguration) { _, category in
                        if categoryBackgroundImageURL.isEmpty {
                            category.backgroundImageUrl = URL(string: "about:blank")!
                        } else if let url = URL(string: categoryBackgroundImageURL) {
                            category.backgroundImageUrl = url
                        }
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
        categoryTitle = category.title
        categoryBackgroundImageURL = category.backgroundImageUrl.absoluteString
    }
    
    @MainActor
    func addFeedButton(scrollProxy: ScrollViewProxy) -> some View {
        Button {
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                guard let feed = try await LibraryDataManager.shared.createEmptyFeed(inCategory: ThreadSafeReference(to: category)) else { return }
                scrollProxy.scrollTo("library-sidebar-\(feed.id.uuidString)")
            }
        } label: {
            Label("Add Feed", systemImage: "plus.circle")
                .labelStyle(.titleAndIcon)
        }
        .disabled(category.opmlURL != nil)
        .keyboardShortcut("n", modifiers: [.command])
    }
    
    @MainActor
    func deleteFeed(_ feed: Feed) async throws {
        guard feed.isUserEditable else { return }
        try await Realm.asyncWrite(ThreadSafeReference(to: feed), configuration: ReaderContentLoader.feedEntryRealmConfiguration) { _, feed in
            feed.isDeleted = true
        }
    }
    
    @MainActor
    func deleteFeed(at offsets: IndexSet) {
        if category.opmlURL != nil {
            return
        }
        
        for offset in offsets {
            let feed = category.feeds[offset]
            guard feed.isUserEditable else { continue }
            Task {
                try await deleteFeed(feed)
            }
        }
    }
}

@available(iOS 16.0, macOS 13.0, *)
struct LibraryCategoryView: View {
    @EnvironmentObject private var viewModel: LibraryCategoryViewModel
    @EnvironmentObject private var libraryManagerViewModel: LibraryManagerViewModel
    
#if os(iOS)
    @ScaledMetric(relativeTo: .largeTitle) private var scaledCategoryHeight: CGFloat = 50
#else
    @ScaledMetric(relativeTo: .largeTitle) private var scaledCategoryHeight: CGFloat = 32
#endif
    
    func unfrozen(_ category: FeedCategory) -> FeedCategory {
        return category.isFrozen ? category.thaw() ?? category : category
    }
    
    var addFeedButtonPlacement: ToolbarItemPlacement {
#if os(iOS)
        return .bottomBar
#else
        return .automatic
#endif
    }
    
    private func matchingDistinctFeed(category: FeedCategory, feed: Feed) -> Feed? {
        return category.feeds.where { $0.isDeleted == false }.first(where: { $0.rssUrl == feed.rssUrl && $0.id != feed.id })
    }
    
    func duplicationMenu(feed: Feed) -> some View {
        Menu("Duplicate In…") {
            ForEach(viewModel.libraryConfiguration.categories.filter({ $0.isUserEditable })) { (category: FeedCategory) in
                if matchingDistinctFeed(category: category, feed: feed) != nil { //}, matchingFeed?.category.id != feed.category.id {
                    Menu(category.title) {
                        Button("Overwrite Existing Feed") {
                            Task {
                                try await libraryManagerViewModel.duplicate(feed: ThreadSafeReference(to: feed), inCategory: ThreadSafeReference(to: category), overwriteExisting: true)
                            }
                        }
                        Button("Duplicate") {
                            Task {
                                try await libraryManagerViewModel.duplicate(feed: ThreadSafeReference(to: feed), inCategory: ThreadSafeReference(to: category), overwriteExisting: false)
                            }
                        }
                    }
                } else {
                    Button {
                        Task {
                            try await libraryManagerViewModel.duplicate(feed: ThreadSafeReference(to: feed), inCategory: ThreadSafeReference(to: category), overwriteExisting: false)
                        }
                    } label: {
                        Text(viewModel.category.title)
                    }
                }
            }
        }
    }
    
    var body: some View {
        ScrollViewReader { scrollProxy in
            List(selection: $viewModel.selectedFeed) {
                Section(header: Text("Category"), footer: Text("Enter an image URL to show as the category button background.").font(.footnote).foregroundColor(.secondary)) {
                    ZStack {
                        FeedCategoryImage(category: viewModel.category)
                            .allowsHitTesting(false)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .frame(maxHeight: scaledCategoryHeight)
                        TextField("Title", text: $viewModel.categoryTitle, prompt: Text("Enter title"))
                            .lineLimit(1)
                            .multilineTextAlignment(.center)
                            .font(.title3.bold())
                            .foregroundColor(.white)
                            .background { Color.clear }
                        //                            .backgroundColor(.clear)
                            .padding(.horizontal)
                            .background(.ultraThinMaterial)
                            .padding(.horizontal, 10)
                    }
                    .frame(maxHeight: scaledCategoryHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    
                    TextField("Background Image URL", text: $viewModel.categoryBackgroundImageURL, axis: .vertical)
                    .lineLimit(2)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                }
                if let opmlURL = viewModel.category.opmlURL {
                    Section("Synchronized") {
                        if LibraryConfiguration.opmlURLs.contains(opmlURL) {
                            Text("This category is not user-editable. Manabi Reader manages and actively improves this category for you.")
                                .lineLimit(9001)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text("Synchronized with: \(opmlURL.absoluteString)")
                                .lineLimit(9001)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Section("Feeds") {
                    ForEach(viewModel.category.feeds.where({ $0.isDeleted == false }).sorted(by: \.title)) { feed in
                        NavigationLink(value: feed) {
                            FeedCell(feed: feed, includesDescription: false, horizontalSpacing: 5)
                        }
                        .deleteDisabled(!feed.isUserEditable)
                        .contextMenu {
                            duplicationMenu(feed: feed)
                            if feed.isUserEditable {
                                Divider()
                                Button(role: .destructive) {
                                    Task {
                                        try await viewModel.deleteFeed(feed)
                                    }
                                } label: {
                                    Text("Delete")
                                }
                                .tint(.red)
                            }
                        }
                    }
                    .onDelete {
                        viewModel.deleteFeed(at: $0)
                    }
                }
            }
#if os(iOS)
            .listStyle(.insetGrouped)
#endif
#if os(macOS)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 0) {
                    viewModel.addFeedButton(scrollProxy: scrollProxy)
                        .buttonStyle(.borderless)
                        .padding()
                    Spacer(minLength: 0)
                }
            }
#endif
#if os(iOS)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    EditButton()
                }
                ToolbarItem(placement: addFeedButtonPlacement) {
                    viewModel.addFeedButton(scrollProxy: scrollProxy)
                }
            }
#endif
        }
    }
}
