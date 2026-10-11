import SwiftUI
import RealmSwift
import FilePicker
import UniformTypeIdentifiers
import OPML
import SwiftUIWebView
import FaviconFinder
import OpenGraph
import RealmSwiftGaps
import Combine
import SwiftUtilities
import LakeOfFireCore
import LakeOfFireAdblock
import LakeOfFireContent

private enum LibraryCategoryFieldCommandError: LocalizedError {
    case categoryUnavailable

    var errorDescription: String? {
        "The category changed before the edit could be saved. Try again."
    }
}

private struct LibraryCategoryEditorIdentity: Hashable {
    let categoryID: UUID
    let categoryCreatedAt: Date
    let libraryConfigurationID: UUID
    let libraryConfigurationCreatedAt: Date
    let realmStorageIdentity: String

    init(category: FeedCategory, libraryConfiguration: LibraryConfiguration) {
        categoryID = category.id
        categoryCreatedAt = category.createdAt
        libraryConfigurationID = libraryConfiguration.id
        libraryConfigurationCreatedAt = libraryConfiguration.createdAt
        let configuration = category.realm?.configuration
            ?? libraryConfiguration.realm?.configuration
            ?? LibraryDataManager.realmConfiguration
        if let fileURL = configuration.fileURL {
            realmStorageIdentity = "file:\(fileURL.standardizedFileURL.resolvingSymlinksInPath().absoluteString)"
        } else if let identifier = configuration.inMemoryIdentifier {
            realmStorageIdentity = "memory:\(identifier)"
        } else {
            realmStorageIdentity = "default"
        }
    }
}

private enum LibraryCategoryEditorMutation: Equatable, Sendable {
    case title(String)
    case backgroundImageURL(URL)

    var field: LibraryCategoryField {
        switch self {
        case .title: .title
        case .backgroundImageURL: .backgroundImageURL
        }
    }
}

private struct LibraryCategoryEditorRequest: Sendable {
    let categoryID: UUID
    let categoryCreatedAt: Date
    let configuration: Realm.Configuration
    let mutation: LibraryCategoryEditorMutation
    let generation: UInt64
}

@MainActor
class LibraryCategoryViewModel: ObservableObject {
    let category: FeedCategory
    let libraryConfiguration: LibraryConfiguration
    let realmConfiguration: Realm.Configuration
    @Binding var selectedFeed: Feed?
    
    @Published var categoryTitle = ""
    @Published var categoryBackgroundImageURL = ""
    @Published var isEditing = false
    @Published private(set) var pendingFieldSaveCount = 0
    @Published private var titleSaveErrorMessage: String?
    @Published private var backgroundImageSaveErrorMessage: String?
    @Published private var observationErrorMessage: String?

    private let categoryID: UUID
    private let categoryCreatedAt: Date
    private var isApplyingObservedState = false
    private var isObserving = false
    private var observationGeneration: UInt64 = 0
    private var latestFieldGenerations = [LibraryCategoryField: UInt64]()
    private var locallyOwnedFieldGenerations = [LibraryCategoryField: UInt64]()
    private var pendingFieldRequests = [LibraryCategoryField: LibraryCategoryEditorRequest]()
    private var enqueuedFieldGenerations = [LibraryCategoryField: UInt64]()
    private var fieldPersistenceTail: Task<Void, Never>?
    
    var cancellables = Set<AnyCancellable>()
    @RealmBackgroundActor private var objectNotificationToken: NotificationToken?
    @RealmBackgroundActor private var installedObservationGeneration: UInt64 = 0
    
    var isUserEditable: Bool {
        return !category.isInvalidated && category.isUserEditable
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
    
    var fieldSaveErrorMessage: String? {
        titleSaveErrorMessage ?? backgroundImageSaveErrorMessage ?? observationErrorMessage
    }

    init(category: FeedCategory, libraryConfiguration: LibraryConfiguration, selectedFeed: Binding<Feed?>) {
        let configuration = category.realm?.configuration
            ?? libraryConfiguration.realm?.configuration
            ?? LibraryDataManager.realmConfiguration
        realmConfiguration = configuration
        self.category = category
        self.libraryConfiguration = libraryConfiguration
        categoryID = category.id
        categoryCreatedAt = category.createdAt
        _selectedFeed = selectedFeed
        categoryTitle = category.title
        categoryBackgroundImageURL = category.backgroundImageUrl.absoluteString == "about:blank"
            ? "" : category.backgroundImageUrl.absoluteString
        $categoryTitle
            .dropFirst()
            .removeDuplicates()
            .compactMap { @MainActor [weak self] value in
                self?.makeTitleRequest(value)
            }
            .debounceLeadingTrailing(for: .seconds(0.35), scheduler: DispatchQueue.main)
            .sink { @MainActor [weak self] request in
                self?.enqueueFieldRequest(request)
            }
            .store(in: &cancellables)
        $categoryBackgroundImageURL
            .dropFirst()
            .removeDuplicates()
            .compactMap { @MainActor [weak self] value in
                self?.makeBackgroundImageRequest(value)
            }
            .debounceLeadingTrailing(for: .seconds(0.35), scheduler: DispatchQueue.main)
            .sink { @MainActor [weak self] request in
                self?.enqueueFieldRequest(request)
            }
            .store(in: &cancellables)
        beginEditing()
    }

    func beginEditing() {
        refresh()
        guard !isObserving else { return }
        isObserving = true
        observationGeneration &+= 1
        let categoryID = self.categoryID
        let configuration = realmConfiguration
        let generation = observationGeneration
        let categoryCreatedAt = self.categoryCreatedAt

        Task { @RealmBackgroundActor [weak self] in
            guard let self else { return }
            do {
                let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
                guard let observedCategory = realm.object(ofType: FeedCategory.self, forPrimaryKey: categoryID),
                      !observedCategory.isDeleted, observedCategory.createdAt == categoryCreatedAt,
                      await self.isCurrentObservation(generation),
                      generation >= installedObservationGeneration else { return }
                installedObservationGeneration = generation
                objectNotificationToken?.invalidate()
                objectNotificationToken = observedCategory.observe { [weak self] change in
                    switch change {
                    case .change(_, _), .deleted:
                        Task { @MainActor [weak self] in
                            guard let self, self.isCurrentObservation(generation) else { return }
                            self.refresh()
                        }
                    case .error(let error):
                        Task { @MainActor [weak self] in
                            guard let self, self.isCurrentObservation(generation) else { return }
                            self.observationErrorMessage = error.localizedDescription
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    guard self.isCurrentObservation(generation) else { return }
                    self.observationErrorMessage = error.localizedDescription
                }
            }
        }

    }

    private func isCurrentObservation(_ generation: UInt64) -> Bool {
        isObserving && observationGeneration == generation
    }

    deinit {
        Task { @RealmBackgroundActor [weak objectNotificationToken] in
            objectNotificationToken?.invalidate()
        }
    }

    func refresh() {
        guard !category.isInvalidated else { return }
        isApplyingObservedState = true
        defer { isApplyingObservedState = false }
        if locallyOwnedFieldGenerations[.title] == nil {
            categoryTitle = category.title
        }
        if locallyOwnedFieldGenerations[.backgroundImageURL] == nil {
            categoryBackgroundImageURL = category.backgroundImageUrl.absoluteString == "about:blank"
                ? "" : category.backgroundImageUrl.absoluteString
        }
    }

    func dismissFieldSaveError() {
        titleSaveErrorMessage = nil
        backgroundImageSaveErrorMessage = nil
        observationErrorMessage = nil
    }

    func flushPendingFieldDrafts() {
        for request in pendingFieldRequests.values {
            enqueueFieldRequest(request)
        }
    }

    func finishEditing() async {
        let generation = observationGeneration
        isObserving = false
        flushPendingFieldDrafts()
        await fieldPersistenceTail?.value
        await invalidateObservation(through: generation)
    }

    @RealmBackgroundActor
    private func invalidateObservation(through generation: UInt64) {
        guard installedObservationGeneration <= generation else { return }
        objectNotificationToken?.invalidate()
        objectNotificationToken = nil
    }

    func saveCategoryTitle(_ title: String) {
        guard let request = makeTitleRequest(title) else { return }
        enqueueFieldRequest(request)
    }

    func saveCategoryBackgroundImageURL(_ rawValue: String) {
        guard let request = makeBackgroundImageRequest(rawValue) else { return }
        enqueueFieldRequest(request)
    }

    private func beginFieldIntent(_ field: LibraryCategoryField) -> UInt64? {
        guard !isApplyingObservedState, isUserEditable else { return nil }
        let generation = (latestFieldGenerations[field] ?? 0) &+ 1
        latestFieldGenerations[field] = generation
        locallyOwnedFieldGenerations[field] = generation
        return generation
    }

    private func makeTitleRequest(_ title: String) -> LibraryCategoryEditorRequest? {
        guard let generation = beginFieldIntent(.title) else { return nil }
        return retainFieldRequest(.title(title), generation: generation)
    }

    private func makeBackgroundImageRequest(_ rawValue: String) -> LibraryCategoryEditorRequest? {
        guard let generation = beginFieldIntent(.backgroundImageURL) else { return nil }
        let url: URL
        if rawValue.isEmpty {
            url = URL(string: "about:blank")!
        } else if let parsedURL = URL(string: rawValue),
                  let scheme = parsedURL.scheme?.lowercased(),
                  ["http", "https"].contains(scheme), parsedURL.host?.isEmpty == false {
            url = parsedURL
        } else {
            pendingFieldRequests[.backgroundImageURL] = nil
            backgroundImageSaveErrorMessage = "Enter a complete background image URL."
            return nil
        }
        return retainFieldRequest(.backgroundImageURL(url), generation: generation)
    }

    private func retainFieldRequest(
        _ mutation: LibraryCategoryEditorMutation,
        generation: UInt64
    ) -> LibraryCategoryEditorRequest {
        let request = LibraryCategoryEditorRequest(
            categoryID: categoryID,
            categoryCreatedAt: categoryCreatedAt,
            configuration: realmConfiguration,
            mutation: mutation,
            generation: generation
        )
        pendingFieldRequests[mutation.field] = request
        return request
    }

    private func enqueueFieldRequest(_ request: LibraryCategoryEditorRequest) {
        let field = request.mutation.field
        guard latestFieldGenerations[field] == request.generation,
              enqueuedFieldGenerations[field] != request.generation else { return }
        enqueuedFieldGenerations[field] = request.generation
        pendingFieldSaveCount += 1
        let predecessor = fieldPersistenceTail
        // Retain the mounted editor until admitted writes finish; retirement never retries a failed request.
        fieldPersistenceTail = Task { @MainActor [self] in
            await predecessor?.value
            defer { pendingFieldSaveCount -= 1 }
            guard latestFieldGenerations[field] == request.generation else { return }
            do {
                let result = try await Self.persist(request)
                guard latestFieldGenerations[field] == request.generation else { return }
                guard result != .unavailable else {
                    throw LibraryCategoryFieldCommandError.categoryUnavailable
                }
                locallyOwnedFieldGenerations[field] = nil
                pendingFieldRequests[field] = nil
                setFieldError(nil, field: field)
            } catch {
                guard latestFieldGenerations[field] == request.generation else { return }
                pendingFieldRequests[field] = nil
                setFieldError(error.localizedDescription, field: field)
            }
        }
    }

    private func setFieldError(_ message: String?, field: LibraryCategoryField) {
        switch field {
        case .title: titleSaveErrorMessage = message
        case .backgroundImageURL: backgroundImageSaveErrorMessage = message
        }
    }

    @RealmBackgroundActor
    private static func persist(
        _ request: LibraryCategoryEditorRequest
    ) async throws -> LibraryCategoryFieldMutationResult {
        switch request.mutation {
        case .title(let title):
            return try await LibraryCategoryFieldCommand.setTitle(
                title, categoryID: request.categoryID, categoryCreatedAt: request.categoryCreatedAt,
                configuration: request.configuration
            )
        case .backgroundImageURL(let url):
            return try await LibraryCategoryFieldCommand.setBackgroundImageURL(
                url, categoryID: request.categoryID, categoryCreatedAt: request.categoryCreatedAt,
                configuration: request.configuration
            )
        }
    }

    @MainActor
    func deleteFeed(_ feed: Feed) async throws {
        guard feed.isUserEditable() else { return }
        try await Realm.asyncWrite(ThreadSafeReference(to: feed), configuration: ReaderContentLoader.feedEntryRealmConfiguration) { _, feed in
            feed.isDeleted = true
            feed.refreshChangeMetadata(explicitlyModified: true)
        }
    }
    
    @MainActor
    func deleteFeed(at offsets: IndexSet) {
        if category.opmlURL != nil {
            return
        }
        
        for offset in offsets {
            let feed = category.getFeeds()?[offset]
            guard let feed, feed.isUserEditable() else { continue }
            Task { @MainActor in
                try await deleteFeed(feed)
            }
        }
    }
    
    @MainActor
    func createFeed() async throws -> UUID? {
        let categoryID = category.id
        let categoryCreatedAt = category.createdAt
        let realmConfiguration = category.realm?.configuration
            ?? libraryConfiguration.realm?.configuration
            ?? LibraryDataManager.realmConfiguration
        let feedID = try await LibraryDataManager.shared.createEmptyFeed(
            categoryID: categoryID,
            categoryCreatedAt: categoryCreatedAt,
            realmConfiguration: realmConfiguration
        )
        guard let feedID else { return nil }
        let realm = try await Realm.open(configuration: realmConfiguration)
        guard let category = realm.object(ofType: FeedCategory.self, forPrimaryKey: categoryID),
              category.createdAt == categoryCreatedAt, !category.isDeleted, category.isUserEditable,
              let feed = realm.object(ofType: Feed.self, forPrimaryKey: feedID),
              !feed.isDeleted, feed.categoryID == categoryID else { return nil }
        selectedFeed = feed
        return feedID
    }

    @MainActor
    func deleteCategory() async throws {
        let ref = ThreadSafeReference(to: category)
        try await Task { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: LibraryDataManager.realmConfiguration)
            guard let category = realm.resolve(ref) else { return }
            try await LibraryDataManager.shared.deleteCategory(category)
        }.value
    }
    
    @MainActor
    func restoreCategory() async throws {
        let ref = ThreadSafeReference(to: category)
        try await Task { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: LibraryDataManager.realmConfiguration)
            guard let category = realm.resolve(ref) else { return }
            try await LibraryDataManager.shared.restoreCategory(category)
        }.value
    }
}

@available(iOS 16.0, macOS 13.0, *)
struct LibraryCategoryView: View {
    let category: FeedCategory
    let libraryConfiguration: LibraryConfiguration
    @Binding var selectedFeed: Feed?

    var body: some View {
        LibraryCategoryViewContent(
            category: category,
            libraryConfiguration: libraryConfiguration,
            selectedFeed: $selectedFeed
        )
        .id(LibraryCategoryEditorIdentity(category: category, libraryConfiguration: libraryConfiguration))
    }
}

@available(iOS 16.0, macOS 13.0, *)
private struct LibraryCategoryViewContent: View {
    @StateObject private var libraryCategoryViewModel: LibraryCategoryViewModel
    
    init(category: FeedCategory, libraryConfiguration: LibraryConfiguration, selectedFeed: Binding<Feed?>) {
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
        ScrollViewReader { scrollProxy in
            Group {
                List {
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
                            .focused($focusedField, equals: .title)
                            .onSubmit { focusedField = nil }
                    }
                    
                    Section {
                        TextField("Image URL", text: Binding {
                            libraryCategoryViewModel.categoryBackgroundImageURL == "about:blank" ? "" : libraryCategoryViewModel.categoryBackgroundImageURL
                        } set: { libraryCategoryViewModel.categoryBackgroundImageURL = $0 }, axis: .vertical)
                        .disabled(!libraryCategoryViewModel.isUserEditable)
                        .focused($focusedField, equals: .backgroundImageURL)
                        .onSubmit { focusedField = nil }
                    } header: {
                        Text("Category Image URL")
                    }
                    
                    if libraryCategoryViewModel.pendingFieldSaveCount > 0 {
                        Section {
                            HStack {
                                ProgressView()
                                Text("Saving category changes…")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let errorMessage = libraryCategoryViewModel.fieldSaveErrorMessage {
                        Section {
                            Text(errorMessage)
                                .foregroundStyle(.red)
                            Button("Dismiss") {
                                libraryCategoryViewModel.dismissFieldSaveError()
                            }
                        }
                    }

                    Section("Feeds") {
                        // TODO: Cache feeds in subview structs
                        ForEach(libraryCategoryViewModel.category.getFeeds() ?? []) { feed in
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
                            libraryCategoryViewModel.deleteFeed(at: $0)
                        }
                    }
                }
            }
#if os(iOS)
            .listStyle(.insetGrouped)
#endif
#if os(macOS)
            .textFieldStyle(.roundedBorder)
            .safeAreaInset(edge: .bottom) {
                if libraryCategoryViewModel.isUserEditable {
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
                    if libraryCategoryViewModel.showMoreOptions {
                        moreOptionsMenu
                    }
                }
#if os(iOS)
                ToolbarItem(placement: .navigationBarTrailing) {
                    // TODO: Cache feeds in subview structs
                    if libraryCategoryViewModel.isUserEditable && !libraryCategoryViewModel.category.isEmpty() {
                        EditButton()
                    }
                }
                ToolbarItemGroup(placement: buttonsPlacement) {
                    if libraryCategoryViewModel.isUserEditable {
                        addFeedButton(scrollProxy: scrollProxy)
                        Spacer(minLength: 0)
                    }
                }
#endif
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focusedField = nil }
                }
            }
        }
        .task { @MainActor in
            libraryCategoryViewModel.beginEditing()
        }
        .onChange(of: focusedField) { newValue in
            libraryCategoryViewModel.isEditing = (newValue != nil)
            if newValue == nil {
                libraryCategoryViewModel.flushPendingFieldDrafts()
            }
        }
        .onDisappear {
            Task { @MainActor in
                await libraryCategoryViewModel.finishEditing()
            }
        }
    }
    
    @ViewBuilder private func addFeedButton(scrollProxy: ScrollViewProxy) -> some View {
        let button = Button {
            Task { @MainActor in
                guard let feedID = try await libraryCategoryViewModel.createFeed() else { return }
                scrollProxy.scrollTo("library-sidebar-\(feedID.uuidString)")
            }
        } label: {
            Label("Add Feed", systemImage: "plus.circle")
                .bold()
        }

        if #available(iOS 26, macOS 26, *) {
            button
                .labelStyle(.titleOnly)
                .buttonStyle(.borderless)
                .disabled(libraryCategoryViewModel.category.opmlURL != nil)
                .keyboardShortcut("n", modifiers: [.command])
        } else {
            button
                .labelStyle(.titleAndIcon)
                .buttonStyle(.borderless)
                .disabled(libraryCategoryViewModel.category.opmlURL != nil)
                .keyboardShortcut("n", modifiers: [.command])
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
            Label("More Options", systemImage: "ellipsis.circle")
                .foregroundStyle(.secondary)
                .labelStyle(.iconOnly)
        }
        .menuIndicator(.hidden)
    }
}
