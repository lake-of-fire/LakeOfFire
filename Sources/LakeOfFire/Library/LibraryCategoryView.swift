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
    
    var isUserEditable: Bool {
        return category.opmlURL == nil
    }
    
    var deleteButtonTitle: String {
        if category.isArchived {
            return "Delete Category"
        }
        return "Archive Category"
    }
    
    var deleteButtonImageName: String {
        if category.isArchived {
            return "trash"
        }
        return "archivebox"
    }
    
    var showMoreOptions: Bool {
        return isUserEditable && showDeleteButton
    }
    
    var showDeleteButton: Bool {
        return isUserEditable && !category.isDeleted
    }
    
    var showRestoreButton: Bool {
        return isUserEditable && category.isArchived
    }

    init(category: FeedCategory, libraryConfiguration: LibraryConfiguration, selectedFeed: Binding<Feed?>) {
        self.category = category
        self.libraryConfiguration = libraryConfiguration
        _selectedFeed = selectedFeed
        
        let ref = ThreadSafeReference(to: category)
        Task { @RealmBackgroundActor [weak self] in
            guard let self = self else { return }
            guard let realm = await RealmBackgroundActor.shared.cachedRealm(for: LibraryDataManager.realmConfiguration) else { return }
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
            .sink { categoryTitle in
                Task {
                    try await Realm.asyncWrite(ThreadSafeReference(to: category), configuration: LibraryDataManager.realmConfiguration) { _, category in
                        category.title = categoryTitle
                    }
                }
            }
            .store(in: &cancellables)
        $categoryBackgroundImageURL
            .removeDuplicates()
            .debounce(for: .seconds(0.35), scheduler: DispatchQueue.main)
            .sink { categoryBackgroundImageURL in
                Task {
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
        Task { @RealmBackgroundActor [weak self] in
            self?.objectNotificationToken?.invalidate()
        }
    }
    
    @MainActor
    func refresh() {
        categoryTitle = category.title
        categoryBackgroundImageURL = category.backgroundImageUrl.absoluteString
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
    
    @MainActor
    func deleteCategory() async throws {
        let ref = ThreadSafeReference(to: category)
        try await Task { @RealmBackgroundActor in
            let realm = try await Realm(configuration: LibraryDataManager.realmConfiguration)
            guard let category = realm.resolve(ref) else { return }
            try await LibraryDataManager.shared.deleteCategory(category)
        }.value
    }
    
    @MainActor
    func restoreCategory() async throws {
        let ref = ThreadSafeReference(to: category)
        try await Task { @RealmBackgroundActor in
            let realm = try await Realm(configuration: LibraryDataManager.realmConfiguration)
            guard let category = realm.resolve(ref) else { return }
            try await LibraryDataManager.shared.restoreCategory(category)
        }.value
    }
}

@available(iOS 16.0, macOS 13.0, *)
struct LibraryCategoryView: View {
    @EnvironmentObject private var viewModel: LibraryCategoryViewModel
    @EnvironmentObject private var libraryManagerViewModel: LibraryManagerViewModel
    
    func unfrozen(_ category: FeedCategory) -> FeedCategory {
        return category.isFrozen ? category.thaw() ?? category : category
    }
    
    var buttonsPlacement: ToolbarItemPlacement {
#if os(iOS)
        return .bottomBar
#else
        return .automatic
#endif
    }
    
    private func matchingDistinctFeed(category: FeedCategory, feed: Feed) -> Feed? {
        return category.feeds.where { $0.isDeleted == false }.first(where: { $0.rssUrl == feed.rssUrl && $0.id != feed.id })
    }
    
    @ViewBuilder func duplicationMenu(feed: Feed) -> some View {
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
    
    @ViewBuilder private var categoryLabel: some View {
        FeedCategoryButtonLabel(title: viewModel.categoryTitle, backgroundImageURL: viewModel.category.backgroundImageUrl, isCompact: true)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .listRowInsets(EdgeInsets())
    }
    
    var body: some View {
        ScrollViewReader { scrollProxy in
            List(selection: $viewModel.selectedFeed) {
                categoryLabel
                
                if let opmlURL = viewModel.category.opmlURL {
                    Section(header: Label("Synced", systemImage: "lock.fill")) {
                        if LibraryConfiguration.opmlURLs.contains(opmlURL) {
                            Text("Manabi Reader manages this category for you.")
                                .foregroundStyle(.secondary)
                                .lineLimit(9001)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text("Synced with: \(opmlURL.absoluteString)")
                                .lineLimit(9001)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                
                if viewModel.showRestoreButton {
                    Section("Archive") {
                        Button {
                            Task {
                                try await viewModel.restoreCategory()
                            }
                        } label: {
                            Label("Restore Category", systemImage: viewModel.deleteButtonImageName)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                
                Section("Category Title") {
                    TextField("Title", text: $viewModel.categoryTitle, prompt: Text("Enter category title"))
                        .disabled(!viewModel.isUserEditable)
                }
                    
                Section {
                    TextField("Image URL", text: $viewModel.categoryBackgroundImageURL, axis: .vertical)
                        .disabled(!viewModel.isUserEditable)
                } header: {
                    Text("Category Image URL")
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
                                    Text("Delete Feed")
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
            .textFieldStyle(.roundedBorder)
            .safeAreaInset(edge: .bottom) {
                if viewModel.isUserEditable {
                    HStack(spacing: 0) {
                        addFeedButton(scrollProxy: scrollProxy)
                            .buttonStyle(.borderless)
                        Spacer(minLength: 0)
                    }
                    .padding()
                }
            }
#endif
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    if viewModel.showMoreOptions {
                        moreOptionsMenu
                    }
                }
#if os(iOS)
                ToolbarItem(placement: .navigationBarTrailing) {
                    if viewModel.isUserEditable && !viewModel.category.feeds.isEmpty {
                        EditButton()
                    }
                }
                ToolbarItem(placement: buttonsPlacement) {
                    if viewModel.isUserEditable {
                        addFeedButton(scrollProxy: scrollProxy)
                    }
                }
#endif
            }
        }
    }
    
    @ViewBuilder private func addFeedButton(scrollProxy: ScrollViewProxy) -> some View {
        Button {
            Task { @MainActor in
                let ref = ThreadSafeReference(to: viewModel.category)
                try await Task { @RealmBackgroundActor in
                    guard let feed = try await LibraryDataManager.shared.createEmptyFeed(inCategory: ref) else { return }
                    let feedID = feed.id.uuidString
                    await Task { @MainActor in
                        scrollProxy.scrollTo("library-sidebar-\(feedID)")
                    }.value
                }.value
            }
        } label: {
            Label("Add Feed", systemImage: "plus.circle")
                .labelStyle(.titleAndIcon)
        }
        .disabled(viewModel.category.opmlURL != nil)
        .keyboardShortcut("n", modifiers: [.command])
    }
    
    @ViewBuilder private var moreOptionsMenu: some View {
        Menu {
            if viewModel.showDeleteButton {
                Button(role: .destructive) {
                    Task {
                        try await viewModel.deleteCategory()
                    }
                } label: {
                    Label(viewModel.deleteButtonTitle, systemImage: viewModel.deleteButtonImageName)
                        .frame(maxWidth: .infinity)
                }
            }
        } label: {
            Label("More Options", systemImage: "ellipsis.circle")
                .foregroundStyle(.secondary)
                .labelStyle(.iconOnly)
        }
        .menuIndicator(.hidden)
    }
}
