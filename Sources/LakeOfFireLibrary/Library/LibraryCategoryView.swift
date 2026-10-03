import LakeOfFireWeb
import SwiftUI
import LakeOfFireFiles
import LakeOfFireContentUI
import LakeOfFireReader
import LakeOfFireContent
import LakeOfFireCore
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
import LakeKit

@MainActor
class LibraryCategoryViewModel: ObservableObject {
    let category: FeedCategory
    let libraryConfiguration: LibraryConfiguration
    let realmConfiguration: Realm.Configuration
    @Binding var selectedFeed: Feed?
    
    @Published var categoryTitle = ""
    @Published var categoryBackgroundImageURL = ""
    @Published var isEditing = false
    
    var cancellables = Set<AnyCancellable>()
    @RealmBackgroundActor private var objectNotificationToken: NotificationToken?
    private var isRefreshing = false
    private var nextEditSequence: UInt64 = 0
    private var pendingFieldSequences: [Int: UInt64] = [:]
    private let writeOrdering = LibraryEditorWriteOrdering()
    
    var isUserEditable: Bool {
        return category.opmlURL == nil
    }
    
    var deleteButtonTitle: String {
        if category.isArchived {
            return "Delete"
        }
        return "Archive"
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
        realmConfiguration = category.realm?.configuration
            ?? libraryConfiguration.realm?.configuration
            ?? LibraryDataManager.realmConfiguration
        self.category = category.isFrozen ? (category.thaw() ?? category) : category
        // The StateObject survives parent snapshots; keep its menu source live.
        self.libraryConfiguration = libraryConfiguration.isFrozen
            ? (libraryConfiguration.thaw() ?? libraryConfiguration)
            : libraryConfiguration
        _selectedFeed = selectedFeed
        categoryTitle = category.title
        categoryBackgroundImageURL = category.backgroundImageUrl.absoluteString == "about:blank" ? "" : category.backgroundImageUrl.absoluteString
        
        let categoryID = category.id
        Task { @RealmBackgroundActor [weak self] in
            guard let self = self else { return }
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: realmConfiguration)
            guard let category = realm.object(ofType: FeedCategory.self, forPrimaryKey: categoryID) else { return }
            objectNotificationToken = category
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
        }
        
        $categoryTitle
            .dropFirst()
            .compactMap { [weak self] value -> (value: String, sequence: UInt64)? in
                guard let sequence = self?.prepareFieldEdit(field: 0) else { return nil }
                return (value, sequence)
            }
            .debounceLeadingTrailing(for: .seconds(0.35), scheduler: DispatchQueue.main)
            .sink { [weak self] edit in
                guard let self else { return }
                let categoryID = category.id
                let writeOrdering = self.writeOrdering
                Task { @RealmBackgroundActor [realmConfiguration] in
                    do {
                        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: realmConfiguration)
                        try await realm.asyncWrite {
                            guard writeOrdering.admits(recordID: categoryID, field: 0, sequence: edit.sequence),
                                  let category = realm.object(ofType: FeedCategory.self, forPrimaryKey: categoryID),
                                  category.isUserEditable, !category.isDeleted,
                                  category.title != edit.value else { return }
                            category.title = edit.value
                            category.refreshChangeMetadata(explicitlyModified: true)
                        }
                    } catch {
                        print("LibraryCategoryEditor title write failed: \(error)")
                    }
                    await self.settleFieldEdit(field: 0, sequence: edit.sequence)
                }
            }
            .store(in: &cancellables)
        $categoryBackgroundImageURL
            .dropFirst()
            .compactMap { [weak self] value -> (value: String, sequence: UInt64)? in
                guard let sequence = self?.prepareFieldEdit(field: 1) else { return nil }
                return (value, sequence)
            }
            .debounceLeadingTrailing(for: .seconds(0.35), scheduler: DispatchQueue.main)
            .sink { [weak self] edit in
                guard let self else { return }
                let categoryID = category.id
                let writeOrdering = self.writeOrdering
                Task { @RealmBackgroundActor [realmConfiguration] in
                    do {
                        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: realmConfiguration)
                        try await realm.asyncWrite {
                            guard writeOrdering.admits(recordID: categoryID, field: 1, sequence: edit.sequence),
                                  let category = realm.object(ofType: FeedCategory.self, forPrimaryKey: categoryID),
                                  category.isUserEditable, !category.isDeleted,
                                  let newURL = URL(string: edit.value.isEmpty ? "about:blank" : edit.value),
                                  category.backgroundImageUrl != newURL else { return }
                            category.backgroundImageUrl = newURL
                            category.refreshChangeMetadata(explicitlyModified: true)
                        }
                    } catch {
                        print("LibraryCategoryEditor image write failed: \(error)")
                    }
                    await self.settleFieldEdit(field: 1, sequence: edit.sequence)
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
        if !category.isFrozen { category.realm?.refresh() }
        guard !category.isInvalidated else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        if pendingFieldSequences[0] == nil {
            categoryTitle = category.title
        }
        if pendingFieldSequences[1] == nil {
            categoryBackgroundImageURL = category.backgroundImageUrl.absoluteString == "about:blank"
                ? "" : category.backgroundImageUrl.absoluteString
        }
    }

    private func prepareFieldEdit(field: Int) -> UInt64? {
        // Published delivers synchronously, so hydration never enters debounce
        // and a buffered draft is protected before the leading write can finish.
        guard !isRefreshing else { return nil }
        nextEditSequence &+= 1
        pendingFieldSequences[field] = nextEditSequence
        return nextEditSequence
    }

    private func settleFieldEdit(field: Int, sequence: UInt64) {
        guard pendingFieldSequences[field] == sequence else { return }
        pendingFieldSequences[field] = nil
        if !isEditing { refresh() }
    }
    
    @MainActor
    func deleteFeed(_ feed: Feed) async throws {
        try await deleteFeed(feedID: feed.id)
    }
    
    @MainActor
    @discardableResult
    func deleteFeed(at offsets: IndexSet) -> Task<Void, Error> {
        deleteFeed(at: offsets, fromFeedIDs: (category.getFeeds() ?? []).map(\.id))
    }

    @MainActor
    @discardableResult
    func deleteFeed(at offsets: IndexSet, fromFeedIDs displayedFeedIDs: [UUID]) -> Task<Void, Error> {
        let feedIDs = offsets.compactMap { offset -> UUID? in
            guard category.opmlURL == nil,
                  displayedFeedIDs.indices.contains(offset) else { return nil }
            return displayedFeedIDs[offset]
        }
        return Task { @MainActor in
            for feedID in feedIDs {
                try await deleteFeed(feedID: feedID)
            }
        }
    }

    @MainActor
    private func deleteFeed(feedID: UUID) async throws {
        try await Task { @RealmBackgroundActor [realmConfiguration] in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: realmConfiguration)
            try await realm.asyncWrite {
                guard let feed = realm.object(ofType: Feed.self, forPrimaryKey: feedID),
                      feed.isUserEditable(),
                      !feed.isDeleted else { return }
                feed.isDeleted = true
                feed.refreshChangeMetadata(explicitlyModified: true)
            }
        }.value
    }

    @MainActor
    func createFeed() async throws -> UUID? {
        let categoryID = category.id
        let feedID: UUID? = try await Task { @RealmBackgroundActor [realmConfiguration] in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: realmConfiguration)
            guard let category = realm.object(ofType: FeedCategory.self, forPrimaryKey: categoryID),
                  category.isUserEditable else { return nil }
            return try await LibraryDataManager.shared.createEmptyFeed(
                inCategory: ThreadSafeReference(to: category),
                realmConfiguration: realmConfiguration
            )
        }.value
        guard let feedID else { return nil }
        let realm = try await Realm.open(configuration: realmConfiguration)
        selectedFeed = realm.object(ofType: Feed.self, forPrimaryKey: feedID)
        return feedID
    }
    
    @MainActor
    func deleteCategory() async throws {
        let categoryID = category.id
        try await Task { @RealmBackgroundActor [realmConfiguration] in
            try await LibraryDataManager.shared.deleteCategory(
                categoryID: categoryID,
                realmConfiguration: realmConfiguration
            )
        }.value
    }
    
    @MainActor
    func restoreCategory() async throws {
        let categoryID = category.id
        try await Task { @RealmBackgroundActor [realmConfiguration] in
            try await LibraryDataManager.shared.restoreCategory(
                categoryID: categoryID,
                realmConfiguration: realmConfiguration
            )
        }.value
    }
}

@available(iOS 16.0, macOS 13.0, *)
struct LibraryCategoryView: View {
    @StateObject private var libraryCategoryViewModel: LibraryCategoryViewModel
    private let onEditorAppear: ((LibraryCategoryViewModel) -> Void)?

    init(
        category: FeedCategory, libraryConfiguration: LibraryConfiguration, selectedFeed: Binding<Feed?>,
        onEditorAppear: ((LibraryCategoryViewModel) -> Void)? = nil
    ) {
        self.onEditorAppear = onEditorAppear
        _libraryCategoryViewModel = StateObject(
            wrappedValue: LibraryCategoryViewModel(
                category: category,
                libraryConfiguration: libraryConfiguration,
                selectedFeed: selectedFeed
            )
        )
    }
    
    @EnvironmentObject private var libraryManagerViewModel: LibraryManagerViewModel
    
    @FocusState private var focusedField: Field?
    private enum Field: Hashable { case title, backgroundImageURL }
    
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
        return category.getFeeds()?.first(where: { $0.rssUrl == feed.rssUrl && $0.id != feed.id })
    }

    private var visibleFeeds: [Feed] {
        libraryCategoryViewModel.category.getFeeds() ?? []
    }
    
    @ViewBuilder func duplicationMenu(feed: Feed) -> some View {
        Menu("Duplicate In…") {
            ForEach((libraryCategoryViewModel.libraryConfiguration.getCategories() ?? []).filter({ $0.isUserEditable })) { (category: FeedCategory) in
                if matchingDistinctFeed(category: category, feed: feed) != nil {
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
                        Text(libraryCategoryViewModel.category.title)
                    }
                }
            }
        }
    }
    
    @ViewBuilder private var categoryLabel: some View {
        FeedCategoryButtonLabel(
            title: libraryCategoryViewModel.categoryTitle,
            backgroundImageURL: libraryCategoryViewModel.category.backgroundImageUrl,
            isCompact: true
        )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .listRowInsets(EdgeInsets())
    }
    
    var body: some View {
        let visibleFeeds = self.visibleFeeds
        let displayedFeedIDs = visibleFeeds.map(\.id)
        ScrollViewReader { scrollProxy in
            Group {
                List(selection: $libraryCategoryViewModel.selectedFeed) {
                    categoryLabel
                    
                    if let opmlURL = libraryCategoryViewModel.category.opmlURL {
                        Section(header: Label("Managed", systemImage: "lock.fill")) {
                            if LibraryConfiguration.opmlURLs.contains(opmlURL) {
                                Text("Official Manabi Reader categories cannot be edited.")
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
                    
                    if libraryCategoryViewModel.showRestoreButton {
                        Section("Archive") {
                            Button {
                                Task {
                                    try await libraryCategoryViewModel.restoreCategory()
                                }
                            } label: {
                                Label("Restore Category", systemImage: libraryCategoryViewModel.deleteButtonImageName)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                    }
                    
                    Section("Category Title") {
                        TextField("Title", text: $libraryCategoryViewModel.categoryTitle, prompt: Text("Enter category title"))
                            .disabled(!libraryCategoryViewModel.isUserEditable)
                            .accessibilityIdentifier("Library.CategoryTitle")
                            .focused($focusedField, equals: .title)
                            .onSubmit { focusedField = nil }
                    }
                    
                    Section {
                        TextField("Image URL", text: Binding {
                            libraryCategoryViewModel.categoryBackgroundImageURL == "about:blank" ? "" : libraryCategoryViewModel.categoryBackgroundImageURL
                        } set: { libraryCategoryViewModel.categoryBackgroundImageURL = $0 }, axis: .vertical)
                        .disabled(!libraryCategoryViewModel.isUserEditable)
                        .accessibilityIdentifier("Library.CategoryImageURL")
                        .focused($focusedField, equals: .backgroundImageURL)
                        .onSubmit { focusedField = nil }
                    } header: {
                        Text("Category Image URL")
                    }
                    
                    Section {
                        if visibleFeeds.isEmpty {
                            EmptyStateBoxView(
                                title: Text("Add feeds to this category"),
                                text: Text("Use this category to organize the RSS and Atom feeds you want to follow together. When Manabi Reader discovers a feed on a webpage, an RSS menu appears in the toolbar or More menu so you can add it here."),
                                systemImageName: "dot.radiowaves.up.forward"
                            ) {
                                if libraryCategoryViewModel.isUserEditable {
                                    emptyStateAddFeedButton(scrollProxy: scrollProxy)
                                }
                            }
                            .listRowSeparatorIfAvailable(.hidden)
                            .listRowBackground(Color.clear)
                            .stackListStyle(.grouped)
                        } else {
                            ForEach(visibleFeeds) { feed in
                                let isFeedUserEditable = feed.isUserEditable()
                                NavigationLink(value: feed) {
                                    FeedCell(feed: feed, includesDescription: false, horizontalSpacing: 5)
                                }
                                .deleteDisabled(!isFeedUserEditable)
                                .contextMenu {
                                    duplicationMenu(feed: feed)
                                    if isFeedUserEditable {
                                        Divider()
                                        Button(role: .destructive) {
                                            Task {
                                                try await libraryCategoryViewModel.deleteFeed(feed)
                                            }
                                        } label: {
                                            Text("Delete Feed")
                                        }
                                        .tint(.red)
                                    }
                                }
                            }
                            .onDelete {
                                libraryCategoryViewModel.deleteFeed(at: $0, fromFeedIDs: displayedFeedIDs)
                            }
                        }
                    } header: {
                        HStack {
                            Text("Feeds")
                            if libraryCategoryViewModel.isUserEditable && !visibleFeeds.isEmpty {
                                Spacer(minLength: 12)
                                inlineAddFeedButton(scrollProxy: scrollProxy)
                            }
                        }
                    }
                }
            }
#if os(iOS)
            .listStyle(.insetGrouped)
#endif
#if os(macOS)
            .textFieldStyle(.roundedBorder)
#endif
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    if libraryCategoryViewModel.showMoreOptions {
                        moreOptionsMenu
                    }
                }
#if os(iOS)
                ToolbarItem(placement: .navigationBarTrailing) {
                    if libraryCategoryViewModel.isUserEditable && !visibleFeeds.isEmpty {
                        EditButton()
                            .tint(.primary)
                    }
                }
#endif
                ToolbarItemGroup(placement: .keyboard) {
                    if focusedField != nil {
                        Spacer()
                        Button("Done") { focusedField = nil }
                            .accessibilityIdentifier("Library.CategoryKeyboardDone")
                    }
                }
            }
        }
        .task(id: libraryCategoryViewModel.category.id) { @MainActor in
            libraryCategoryViewModel.refresh()
            onEditorAppear?(libraryCategoryViewModel)
        }
        .onChange(of: focusedField) { newValue in
            libraryCategoryViewModel.isEditing = (newValue != nil)
            if newValue == nil {
                libraryCategoryViewModel.refresh()
            }
        }
    }
    
    @ViewBuilder private func addFeedButton(scrollProxy: ScrollViewProxy) -> some View {
        Button("Add Feed") {
            createFeed(scrollProxy: scrollProxy)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .font(.footnote)
        .fontWeight(.semibold)
        .foregroundStyle(.primary)
        .disabled(libraryCategoryViewModel.category.opmlURL != nil)
        .keyboardShortcut("n", modifiers: [.command])
    }

    @ViewBuilder private func inlineAddFeedButton(scrollProxy: ScrollViewProxy) -> some View {
        addFeedButton(scrollProxy: scrollProxy)
    }

    @ViewBuilder private func emptyStateAddFeedButton(scrollProxy: ScrollViewProxy) -> some View {
        Button("Add Feed") {
            createFeed(scrollProxy: scrollProxy)
        }
        .tint(.secondary)
        .foregroundStyle(.primary)
    }

    private func createFeed(scrollProxy: ScrollViewProxy) {
        Task { @MainActor in
            guard let feedID = try await libraryCategoryViewModel.createFeed() else { return }
            scrollProxy.scrollTo("library-sidebar-\(feedID.uuidString)")
        }
    }
    
    @ViewBuilder private var moreOptionsMenu: some View {
        Menu {
            if libraryCategoryViewModel.showDeleteButton {
                Button(role: .destructive) {
                    Task {
                        try await libraryCategoryViewModel.deleteCategory()
                    }
                } label: {
                    Label(libraryCategoryViewModel.deleteButtonTitle, systemImage: libraryCategoryViewModel.deleteButtonImageName)
                        .frame(maxWidth: .infinity)
                }
            }
        } label: {
            Label("More Options", systemImage: "ellipsis")
                .foregroundStyle(.primary)
                .labelStyle(.iconOnly)
        }
        .tint(.primary)
        .menuIndicator(.hidden)
    }
}
