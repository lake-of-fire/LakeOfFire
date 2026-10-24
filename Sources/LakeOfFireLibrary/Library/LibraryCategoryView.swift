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

/// Keep each row's identity independent of later managed-object refreshes.
struct LibraryCategoryFeedRow: Identifiable {
    let id: LibraryCategoryFeedSelection
    let feed: Feed

    @MainActor
    init?(feed: Feed) {
        guard let selection = LibraryCategoryFeedSelection(feed: feed) else { return nil }
        id = selection
        self.feed = feed
    }
}

@MainActor
class LibraryCategoryViewModel: ObservableObject {
    let category: FeedCategory
    let categoryID: UUID
    let realmConfiguration: Realm.Configuration
    let libraryConfiguration: LibraryConfiguration
    @Binding var selectedFeed: Feed?
    
    @Published var categoryTitle = ""
    @Published var categoryBackgroundImageURL = ""
    @Published var isEditing = false
    
    private var isRefreshing = false
    private var pendingFieldCommands: [LibraryCategoryField: LibraryCategoryFieldCommand] = [:]
    private var activeWrites: [UUID: Task<Void, Error>] = [:]
    private var feedCreationRequestID: UUID?
    private var feedCreationTask: Task<UUID?, Error>?
    private let owner: LibraryCategoryFieldOwner?
    private let ordering: LibraryCategoryFieldWriteOrdering?
    private let beforeFieldWrite: (@RealmBackgroundActor @Sendable () async throws -> Void)?
    private let retirementDidFinish: (@RealmBackgroundActor @Sendable () -> Void)?
    private let debouncedWriteDidFinish: (@MainActor @Sendable (LibraryCategoryFieldEdit) -> Void)?
    var cancellables = Set<AnyCancellable>()
    @RealmBackgroundActor private var objectNotificationToken: NotificationToken?
    
    var isUserEditable: Bool {
        return owner?.isCurrentStorage == true && !category.isInvalidated && !category.isDeleted && category.opmlURL == nil
    }
    
    var deleteButtonTitle: String {
        if !category.isInvalidated && category.isArchived {
            return "Delete"
        }
        return "Archive"
    }
    
    var deleteButtonImageName: String {
        if !category.isInvalidated && category.isArchived {
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

    var visibleFeeds: [Feed] {
        guard owner?.isCurrentStorage == true,
              !category.isInvalidated, !category.isDeleted else { return [] }
        return (category.getFeeds() ?? []).filter { !$0.isInvalidated }
    }

    var visibleFeedRows: [LibraryCategoryFeedRow] {
        visibleFeeds.compactMap { LibraryCategoryFeedRow(feed: $0) }
    }

    var duplicationCategories: [FeedCategory] {
        guard owner?.isCurrentStorage == true,
              !category.isInvalidated, !category.isDeleted,
              !libraryConfiguration.isInvalidated else { return [] }
        return (libraryConfiguration.getCategories() ?? [])
            .filter { !$0.isInvalidated && !$0.isDeleted && $0.isUserEditable }
    }

    var managedOPMLURL: URL? {
        guard owner?.isCurrentStorage == true,
              !category.isInvalidated, !category.isDeleted else { return nil }
        return category.opmlURL
    }

    var categoryImageURL: URL {
        guard owner?.isCurrentStorage == true,
              !category.isInvalidated, !category.isDeleted else { return URL(string: "about:blank")! }
        return category.backgroundImageUrl
    }
    
    /// Scheduled field delivery must target the main queue. Tests may suspend a
    /// main-targeted queue to stage Done before the queued trailing delivery.
    init(
        category: FeedCategory,
        libraryConfiguration: LibraryConfiguration,
        selectedFeed: Binding<Feed?>,
        observesRealm: Bool = true,
        beforeFieldWrite: (@RealmBackgroundActor @Sendable () async throws -> Void)? = nil,
        retirementDidFinish: (@RealmBackgroundActor @Sendable () -> Void)? = nil,
        fieldDebounceScheduler: DispatchQueue = .main,
        debouncedWriteDidFinish: (@MainActor @Sendable (LibraryCategoryFieldEdit) -> Void)? = nil
    ) {
        self.beforeFieldWrite = beforeFieldWrite
        self.retirementDidFinish = retirementDidFinish
        self.debouncedWriteDidFinish = debouncedWriteDidFinish
        self.realmConfiguration =
            category.realm?.configuration
            ?? libraryConfiguration.realm?.configuration
            ?? LibraryDataManager.realmConfiguration
        owner = LibraryCategoryFieldOwner(category: category, realmConfiguration: realmConfiguration)
        ordering = owner.map { .shared(identity: LibraryCategoryFieldIdentity(owner: $0)) }
        self.categoryID = category.id
        self.category = category
        self.libraryConfiguration = libraryConfiguration
        _selectedFeed = selectedFeed
        categoryTitle = category.title
        categoryBackgroundImageURL = category.backgroundImageUrl.absoluteString == "about:blank" ? "" : category.backgroundImageUrl.absoluteString
        
        let fieldOwner = owner
        if observesRealm {
            Task { @RealmBackgroundActor [weak self] in
                guard let self, let fieldOwner else { return }
                let realm = try await RealmBackgroundActor.shared.cachedRealm(
                    for: fieldOwner.realmConfiguration,
                    storageAdmission: fieldOwner.storageAdmission
                )
                guard fieldOwner.isCurrentStorage,
                      let category = realm.object(
                        ofType: FeedCategory.self,
                        forPrimaryKey: fieldOwner.categoryID
                      ), category.createdAt == fieldOwner.createdAt else { return }
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
        }
        observe($categoryTitle, edit: LibraryCategoryFieldEdit.title, scheduler: fieldDebounceScheduler)
        observe($categoryBackgroundImageURL, edit: LibraryCategoryFieldEdit.imageURL, scheduler: fieldDebounceScheduler)
    }

    private func observe(
        _ publisher: Published<String>.Publisher,
        edit: @escaping (String) -> LibraryCategoryFieldEdit,
        scheduler: DispatchQueue
    ) {
        publisher.dropFirst()
            .compactMap { [weak self] value -> LibraryCategoryFieldCommand? in
                guard let self, !self.isRefreshing else { return nil }
                return self.capture(edit(value))
            }
            .debounceLeadingTrailing(for: .seconds(0.35), scheduler: scheduler)
            .sink { [weak self] command in
                guard let self else { return }
                self.observeCompletion(self.submit(command), edit: command.edit)
            }
            .store(in: &cancellables)
    }

    private func capture(_ edit: LibraryCategoryFieldEdit) -> LibraryCategoryFieldCommand? {
        guard let owner, let ordering, owner.isCurrentStorage, isUserEditable,
              category.id == owner.categoryID, category.createdAt == owner.createdAt else { return nil }
        let command = LibraryCategoryFieldCommand(
            owner: owner, edit: edit, intent: ordering.issueIntent(field: edit.field), ordering: ordering
        )
        pendingFieldCommands[edit.field] = command
        return command
    }

    private func submit(
        _ command: LibraryCategoryFieldCommand,
        beforeWrite: (@RealmBackgroundActor @Sendable () async throws -> Void)? = nil
    ) -> Task<Void, Error> {
        if let active = activeWrites[command.intent] { return active }
        // A trailing delivery may arrive after finish settled this command.
        guard pendingFieldCommands[command.edit.field]?.intent == command.intent else {
            return Task<Void, Error> {}
        }
        let beforeWrite = beforeWrite ?? beforeFieldWrite
        let task = Task<Void, Error> { @RealmBackgroundActor [weak self] in
            do {
                try await command.write(beforeWrite: beforeWrite)
                await self?.settle(command, succeeded: true)
            } catch {
                await self?.settle(command, succeeded: false)
                throw error
            }
        }
        activeWrites[command.intent] = task
        return task
    }

    private func settle(_ command: LibraryCategoryFieldCommand, succeeded: Bool) {
        activeWrites[command.intent] = nil
        guard succeeded, pendingFieldCommands[command.edit.field]?.intent == command.intent else { return }
        pendingFieldCommands[command.edit.field] = nil
        if !isEditing { refresh() }
    }

    private func observeCompletion(_ task: Task<Void, Error>, edit: LibraryCategoryFieldEdit? = nil) {
        let didFinish = debouncedWriteDidFinish
        Task { @MainActor in
            defer { if let edit { didFinish?(edit) } }
            do { try await task.value }
            catch { print("# LIBRARYCATEGORYEDITOR write failed: \(error)") }
        }
    }

    @discardableResult
    func finishEditing() -> Task<Void, Error> {
        isEditing = false
        for command in pendingFieldCommands.values { _ = submit(command) }
        let writes = Array(activeWrites.values)
        refresh()
        let completion = Task<Void, Error> { @RealmBackgroundActor in
            var firstError: Error?
            for write in writes {
                do { try await write.value }
                catch { if firstError == nil { firstError = error } }
            }
            if let firstError { throw firstError }
        }
        observeCompletion(completion)
        return completion
    }

    @discardableResult
    func writeFieldAsync(
        _ edit: LibraryCategoryFieldEdit,
        beforeWrite: (@RealmBackgroundActor @Sendable () async throws -> Void)? = nil
    ) -> Task<Void, Error> {
        guard let command = capture(edit) else { return Task<Void, Error> {} }
        isRefreshing = true
        switch edit {
        case .title(let value): categoryTitle = value
        case .imageURL(let value): categoryBackgroundImageURL = value
        }
        isRefreshing = false
        return submit(command, beforeWrite: beforeWrite)
    }

    deinit {
        let commands = Array(pendingFieldCommands.values)
        let writes = activeWrites
        let retirementDidFinish = retirementDidFinish
        Task { @RealmBackgroundActor in
            defer { retirementDidFinish?() }
            for command in commands {
                // Join the original attempt before deciding whether one retry is needed.
                if let active = writes[command.intent] {
                    do { try await active.value; continue }
                    catch { /* Retry the retained command below. */ }
                }
                do { try await command.write() }
                catch { print("# LIBRARYCATEGORYEDITOR retirement write failed: \(error)") }
            }
        }
        Task { @RealmBackgroundActor [weak objectNotificationToken] in
            objectNotificationToken?.invalidate()
        }
    }

    @MainActor
    func refresh() {
        guard owner?.isCurrentStorage == true, !category.isInvalidated else { return }
        if !category.isFrozen { category.realm?.refresh() }
        guard !category.isInvalidated else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        if pendingFieldCommands[.title] == nil { categoryTitle = category.title }
        if pendingFieldCommands[.imageURL] == nil {
            categoryBackgroundImageURL = category.backgroundImageUrl.absoluteString == "about:blank"
                ? "" : category.backgroundImageUrl.absoluteString
        }
    }

    /// Admit the rendered category before scheduling, and publish only the
    /// committed incarnation while this presentation still owns the request.
    @discardableResult
    func createFeed(
        beforeWrite: (@RealmBackgroundActor @Sendable () async throws -> Void)? = nil,
        beforePublication: (@MainActor @Sendable () async throws -> Void)? = nil,
        didPublish: @escaping @MainActor (UUID) -> Void = { _ in }
    ) -> Task<UUID?, Error>? {
        guard !Task.isCancelled, let owner, owner.isCurrentStorage, isUserEditable,
              category.id == owner.categoryID, category.createdAt == owner.createdAt else { return nil }
        let previousSelection: LibraryCategoryFeedSelection?
        if let feed = selectedFeed {
            guard let selection = LibraryCategoryFeedSelection(feed: feed) else { return nil }
            previousSelection = selection
        } else {
            previousSelection = nil
        }
        let reference = ThreadSafeReference(to: category)
        let requestID = UUID()
        feedCreationTask?.cancel()
        feedCreationRequestID = requestID
        let task = Task<UUID?, Error> { @MainActor in
            defer {
                if self.feedCreationRequestID == requestID {
                    self.feedCreationRequestID = nil
                    self.feedCreationTask = nil
                }
            }
            guard let result = try await LibraryDataManager.shared.createEmptyFeedWithIdentity(
                inCategory: reference,
                realmConfiguration: owner.realmConfiguration,
                storageAdmission: owner.storageAdmission,
                expectedCategoryCreatedAt: owner.createdAt,
                beforeWrite: beforeWrite
            ) else { return nil }
            try await beforePublication?()
            guard !Task.isCancelled, self.feedCreationRequestID == requestID,
                  owner.isCurrentStorage, self.selectionMatches(previousSelection),
                  result.categoryID == owner.categoryID,
                  result.categoryCreatedAt == owner.createdAt else { return nil }
            let realm = try await Realm.open(configuration: owner.realmConfiguration)
            await realm.asyncRefresh()
            guard !Task.isCancelled, self.feedCreationRequestID == requestID,
                  owner.isCurrentStorage, self.selectionMatches(previousSelection),
                  let category = realm.object(ofType: FeedCategory.self, forPrimaryKey: result.categoryID),
                  category.createdAt == result.categoryCreatedAt,
                  !category.isDeleted, category.isUserEditable,
                  let feed = realm.object(ofType: Feed.self, forPrimaryKey: result.feedID),
                  feed.createdAt == result.feedCreatedAt, !feed.isDeleted,
                  feed.categoryID == result.categoryID else { return nil }
            self.selectedFeed = feed
            // A binding may synchronously select another row or retire the view.
            guard !Task.isCancelled, self.feedCreationRequestID == requestID,
                  owner.isCurrentStorage,
                  self.selectionMatches(.init(id: result.feedID, createdAt: result.feedCreatedAt)) else { return nil }
            didPublish(result.feedID)
            return result.feedID
        }
        feedCreationTask = task
        return task
    }

    private func selectionMatches(_ expected: LibraryCategoryFeedSelection?) -> Bool {
        guard let feed = selectedFeed else { return expected == nil }
        guard let selection = LibraryCategoryFeedSelection(feed: feed) else { return false }
        return selection == expected
    }

    func retireFeedCreation() {
        feedCreationRequestID = nil
        feedCreationTask?.cancel()
        feedCreationTask = nil
    }

    @MainActor
    func deleteFeed(_ feed: Feed) async throws {
        guard let owner, isUserEditable,
              let selection = LibraryCategoryFeedSelection(feed: feed) else { return }
        // Keep the caller's task through the actor hop and owned transaction.
        try await LibraryCategoryFeedDeleteCommand(owner: owner, selections: [selection]).write()
    }

    @discardableResult
    func deleteFeeds(
        _ selections: [LibraryCategoryFeedSelection],
        beforeWrite: (@RealmBackgroundActor @Sendable () async throws -> Void)? = nil
    ) -> Task<Void, Error> {
        guard let owner, isUserEditable, !selections.isEmpty else {
            return Task<Void, Error> {}
        }
        let command = LibraryCategoryFeedDeleteCommand(owner: owner, selections: selections)
        let completion = Task<Void, Error> { @RealmBackgroundActor in
            try await command.write(beforeWrite: beforeWrite)
        }
        observeCompletion(completion)
        return completion
    }

    @MainActor
    func deleteFeed(at offsets: IndexSet) {
        deleteFeed(at: offsets, displayedFeeds: visibleFeedRows.map(\.id))
    }

    @discardableResult
    func deleteFeed(
        at offsets: IndexSet,
        displayedFeeds: [LibraryCategoryFeedSelection]
    ) -> Task<Void, Error> {
        let selections = offsets.compactMap { offset -> LibraryCategoryFeedSelection? in
            guard displayedFeeds.indices.contains(offset) else { return nil }
            return displayedFeeds[offset]
        }
        return deleteFeeds(selections)
    }

    @MainActor
    func deleteCategory() async throws {
        guard isUserEditable else { return }
        let ref = ThreadSafeReference(to: category)
        try await Task { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: LibraryDataManager.realmConfiguration)
            guard let category = realm.resolve(ref) else { return }
            try await LibraryDataManager.shared.deleteCategory(category)
        }.value
    }
    
    @MainActor
    func restoreCategory() async throws {
        guard isUserEditable else { return }
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
        guard !category.isInvalidated, !feed.isInvalidated else { return nil }
        return category.getFeeds()?.first(where: {
            !$0.isInvalidated && $0.rssUrl == feed.rssUrl && $0.id != feed.id
        })
    }
    
    @ViewBuilder func duplicationMenu(feed: Feed) -> some View {
        Menu("Duplicate In…") {
            ForEach(libraryCategoryViewModel.duplicationCategories) { (category: FeedCategory) in
                if matchingDistinctFeed(category: category, feed: feed) != nil {
                    Menu(category.title) {
                        Button("Overwrite Existing Feed") {
                            Task {
                                guard !feed.isInvalidated, !category.isInvalidated else { return }
                                try await libraryManagerViewModel.duplicate(feed: ThreadSafeReference(to: feed), inCategory: ThreadSafeReference(to: category), overwriteExisting: true)
                            }
                        }
                        Button("Duplicate") {
                            Task {
                                guard !feed.isInvalidated, !category.isInvalidated else { return }
                                try await libraryManagerViewModel.duplicate(feed: ThreadSafeReference(to: feed), inCategory: ThreadSafeReference(to: category), overwriteExisting: false)
                            }
                        }
                    }
                } else {
                    Button {
                        Task {
                            guard !feed.isInvalidated, !category.isInvalidated else { return }
                            try await libraryManagerViewModel.duplicate(feed: ThreadSafeReference(to: feed), inCategory: ThreadSafeReference(to: category), overwriteExisting: false)
                        }
                    } label: {
                        Text(category.title)
                    }
                }
            }
        }
    }
    
    @ViewBuilder private var categoryLabel: some View {
        FeedCategoryButtonLabel(
            title: libraryCategoryViewModel.categoryTitle,
            backgroundImageURL: libraryCategoryViewModel.categoryImageURL,
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
                    
                    if let opmlURL = libraryCategoryViewModel.managedOPMLURL {
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
                    
                    Section("Feeds") {
                        let rows = libraryCategoryViewModel.visibleFeedRows
                        let displayedFeeds = rows.map(\.id)
                        ForEach(rows) { row in
                            let feed = row.feed
                            if !feed.isInvalidated {
                                let isFeedUserEditable = libraryCategoryViewModel.isUserEditable && feed.isUserEditable()
                                NavigationLink(value: feed) {
                                    FeedCell(feed: feed, includesDescription: false, horizontalSpacing: 5)
                                }
                                .deleteDisabled(!isFeedUserEditable)
                                .contextMenu {
                                    duplicationMenu(feed: feed)
                                    if isFeedUserEditable {
                                        Divider()
                                        Button(role: .destructive) {
                                            libraryCategoryViewModel.deleteFeeds([row.id])
                                        } label: {
                                            Text("Delete Feed")
                                        }
                                        .tint(.red)
                                    }
                                }
                            }
                        }
                        .onDelete {
                            libraryCategoryViewModel.deleteFeed(at: $0, displayedFeeds: displayedFeeds)
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
        .task(id: libraryCategoryViewModel.categoryID) { @MainActor in
            libraryCategoryViewModel.refresh()
        }
        .onChange(of: focusedField) { newValue in
            if newValue == nil {
                libraryCategoryViewModel.finishEditing()
            } else {
                libraryCategoryViewModel.isEditing = true
            }
        }
        .onDisappear {
            libraryCategoryViewModel.retireFeedCreation()
            libraryCategoryViewModel.finishEditing()
        }
    }
    
    @ViewBuilder private func addFeedButton(scrollProxy: ScrollViewProxy) -> some View {
        let button = Button {
            libraryCategoryViewModel.createFeed(didPublish: { feedID in
                scrollProxy.scrollTo("library-sidebar-\(feedID.uuidString)")
            })
        } label: {
            Label("Add Feed", systemImage: "plus.circle")
                .bold()
        }

        if #available(iOS 26, macOS 26, *) {
            button
                .labelStyle(.titleOnly)
                .buttonStyle(.borderless)
                .disabled(!libraryCategoryViewModel.isUserEditable)
                .keyboardShortcut("n", modifiers: [.command])
        } else {
            button
                .labelStyle(.titleAndIcon)
                .buttonStyle(.borderless)
                .disabled(!libraryCategoryViewModel.isUserEditable)
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
