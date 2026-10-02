import LakeOfFireWeb
import SwiftUI
import LakeOfFireFiles
import LakeOfFireContentUI
import LakeOfFireReader
import LakeOfFireContent
import LakeOfFireCore
import UniformTypeIdentifiers
import RealmSwift
import FilePicker
import SwiftUIWebView
import FaviconFinder
import DebouncedOnChange
import OpenGraph
import RealmSwiftGaps
import SwiftUtilities
import Combine
import LakeKit

let libraryCategoriesQueue = DispatchQueue(label: "LibraryCategories")

@MainActor
class LibraryCategoriesViewModel: ObservableObject {
    let realmConfiguration: Realm.Configuration

    @Published var categories: [FeedCategory]? = nil
    @Published var userLibraryCategories: [FeedCategory]? = nil
    @Published var editorsPicksLibraryCategories: [FeedCategory]? = nil
    @Published var archivedCategories: [FeedCategory]? = nil
    
    @RealmBackgroundActor
    private var cancellables = Set<AnyCancellable>()
    
    @Published var libraryConfiguration: LibraryConfiguration?
    
    init(
        observesRealm: Bool = true,
        realmConfiguration: Realm.Configuration = LibraryDataManager.realmConfiguration
    ) {
        self.realmConfiguration = realmConfiguration
        guard observesRealm else { return }
        Task { @RealmBackgroundActor [weak self] in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: realmConfiguration)

            realm.objects(LibraryConfiguration.self)
                .collectionPublisher
                .subscribe(on: libraryCategoriesQueue)
                .map { @Sendable _ in }
                .debounceLeadingTrailing(for: .seconds(0.3), scheduler: libraryDataQueue)
                .sink(receiveCompletion: { @Sendable _ in }, receiveValue: { @Sendable [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.refreshData()
                    }
                })
                .store(in: &cancellables)
            
            realm.objects(FeedCategory.self)
                .collectionPublisher
                .subscribe(on: libraryCategoriesQueue)
                .map { @Sendable _ in }
                .debounceLeadingTrailing(for: .seconds(0.3), scheduler: libraryCategoriesQueue)
                .sink(receiveCompletion: { @Sendable _ in}, receiveValue: { @Sendable [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.refreshData()
                    }
                })
                .store(in: &cancellables)
        }
    }
        
    @discardableResult
    func refreshData() -> Task<Void, Error> {
        Task { @RealmBackgroundActor [realmConfiguration] in
            let libraryConfiguration = try await LibraryConfiguration.getConsolidatedOrCreate(
                realmConfiguration: realmConfiguration
            )
            let libraryConfigurationID = libraryConfiguration.id
            
            try await { @MainActor [weak self] in
                guard let self else { return }
                let realm = try await Realm.open(configuration: realmConfiguration)
                
                guard let libraryConfiguration = realm.object(ofType: LibraryConfiguration.self, forPrimaryKey: libraryConfigurationID) else { return }
                self.libraryConfiguration = libraryConfiguration
                let categories = Array(libraryConfiguration.getCategories() ?? [])
                self.categories = categories
                self.userLibraryCategories = categories.filter(\.isUserEditable)
                self.editorsPicksLibraryCategories = categories.filter { !$0.isUserEditable }

                let activeCategoryIDs = libraryConfiguration.getActiveCategories()?.map { $0.id } ?? []
                self.archivedCategories = Array(realm.objects(FeedCategory.self).where { ($0.isArchived || !$0.id.in(activeCategoryIDs)) && !$0.isDeleted })
            }()
        }
    }
    
    func deletionTitle(category: FeedCategory) -> String {
        if category.isArchived {
            return "Delete"
        }
        return "Archive"
    }

    func showDeleteButton(category: FeedCategory) -> Bool {
        return category.isUserEditable && !category.isDeleted
    }
    
    func showRestoreButton(category: FeedCategory) -> Bool {
        return category.isUserEditable && category.isArchived
    }

    @MainActor
    func deleteCategory(_ category: FeedCategory) async throws {
        let categoryID = category.id
        try await Task { @RealmBackgroundActor [realmConfiguration] in
            try await LibraryDataManager.shared.deleteCategory(
                categoryID: categoryID,
                realmConfiguration: realmConfiguration
            )
        }.value
    }
    
    @MainActor
    func restoreCategory(_ category: FeedCategory) async throws {
        let categoryID = category.id
        try await Task { @RealmBackgroundActor [realmConfiguration] in
            try await LibraryDataManager.shared.restoreCategory(
                categoryID: categoryID,
                realmConfiguration: realmConfiguration
            )
        }.value
    }

    @MainActor
    func createCategory() async throws -> UUID {
        try await Task { @RealmBackgroundActor [realmConfiguration] in
            try await LibraryDataManager.shared.createEmptyCategory(
                addToLibrary: true,
                realmConfiguration: realmConfiguration
            )
        }.value
    }
    
    @MainActor
    @discardableResult
    func deleteCategory(at offsets: IndexSet) -> Task<Void, Error> {
        deleteCategory(at: offsets, from: userLibraryCategories)
    }

    @MainActor
    @discardableResult
    func deleteCategory(at offsets: IndexSet, from categories: [FeedCategory]?) -> Task<Void, Error> {
        deleteCategory(at: offsets, fromCategoryIDs: categories?.map(\.id) ?? [])
    }

    @MainActor
    @discardableResult
    func deleteCategory(at offsets: IndexSet, fromCategoryIDs categoryIDs: [UUID]) -> Task<Void, Error> {
        let categoryIDsToDelete = offsets.compactMap { offset -> UUID? in
            guard categoryIDs.indices.contains(offset) else { return nil }
            return categoryIDs[offset]
        }
        return Task { @MainActor in
            for categoryID in categoryIDsToDelete {
                try await Task { @RealmBackgroundActor [realmConfiguration] in
                    try await LibraryDataManager.shared.deleteCategory(
                        categoryID: categoryID,
                        realmConfiguration: realmConfiguration
                    )
                }.value
            }
        }
    }
   
    @MainActor
    @discardableResult
    func moveCategories(
        fromOffsets: IndexSet,
        toOffset: Int,
        displayedCategoryIDs: [UUID]? = nil
    ) -> Task<Void, Error>? {
        guard let libraryConfiguration else { return nil }
        let originalIDs = Array(libraryConfiguration.categoryIDs)
        let visibleIDs = displayedCategoryIDs ?? userLibraryCategories?.map(\.id) ?? []
        guard !visibleIDs.isEmpty,
              fromOffsets.allSatisfy(visibleIDs.indices.contains),
              visibleIDs.indices.contains(toOffset) || toOffset == visibleIDs.endIndex else { return nil }
        var reorderedIDs = visibleIDs
        reorderedIDs.move(fromOffsets: fromOffsets, toOffset: toOffset)
        guard reorderedIDs != visibleIDs else { return nil }
        let configurationID = libraryConfiguration.id
        let configurationCreatedAt = libraryConfiguration.createdAt
        return Task { @MainActor in
            try await Task { @RealmBackgroundActor [realmConfiguration] in
                let realm = try await RealmBackgroundActor.shared.cachedRealm(for: realmConfiguration)
                try await realm.asyncWrite {
                    guard let libraryConfiguration = realm.object(
                        ofType: LibraryConfiguration.self,
                        forPrimaryKey: configurationID
                    ),
                    libraryConfiguration.createdAt == configurationCreatedAt,
                    Array(libraryConfiguration.categoryIDs) == originalIDs else { return }
                    let visibleIDSet = Set(visibleIDs)
                    let currentVisibleIDs = originalIDs.compactMap { categoryID -> UUID? in
                        guard visibleIDSet.contains(categoryID),
                              let category = realm.object(ofType: FeedCategory.self, forPrimaryKey: categoryID),
                              !category.isDeleted,
                              category.isUserEditable else { return nil }
                        return categoryID
                    }
                    guard currentVisibleIDs == visibleIDs,
                          reorderedIDs.count == currentVisibleIDs.count,
                          Set(reorderedIDs) == Set(currentVisibleIDs) else { return }
                    var nextRawIDs = originalIDs
                    var reorderedIndex = 0
                    for index in nextRawIDs.indices where visibleIDSet.contains(nextRawIDs[index]) {
                        guard reorderedIndex < reorderedIDs.count else { return }
                        nextRawIDs[index] = reorderedIDs[reorderedIndex]
                        reorderedIndex += 1
                    }
                    guard reorderedIndex == reorderedIDs.count,
                          nextRawIDs.count == originalIDs.count,
                          nextRawIDs != originalIDs else { return }
                    libraryConfiguration.categoryIDs.removeAll()
                    libraryConfiguration.categoryIDs.append(objectsIn: nextRawIDs)
                    libraryConfiguration.refreshChangeMetadata(explicitlyModified: true)
                }
            }.value
        }
    }
}

@available(iOS 16.0, macOS 13.0, *)
struct LibraryCategoriesView: View {
    @StateObject private var viewModel = LibraryCategoriesViewModel()
    
    @EnvironmentObject private var libraryManagerViewModel: LibraryManagerViewModel

    @AppStorage("appTint") private var appTint: Color = .accentColor
    
    @State private var categoryIDNeedsScrollTo: String?
    @State private var exportViewRegistrationID = UUID()
    
#if os(macOS)
    @State private var savePanel: NSSavePanel?
    @State private var window: NSWindow?
#endif
    
    private var isUserLibraryEmpty: Bool {
        guard let userLibraryCategories = viewModel.userLibraryCategories else { return false }
        return userLibraryCategories.isEmpty
    }

    @ViewBuilder var importExportView: some View {
        Group {
            if let shareItem = libraryManagerViewModel.exportedOPMLShareItem {
                ShareLink(
                    item: shareItem,
                    message: Text(""),
                    preview: SharePreview(
                        "Manabi Reader User Feeds OPML File",
                        image: Image(systemName: "doc")
                    )
                ) {
#if os(macOS)
                    Text("Share My Library…")
                        .frame(maxWidth: .infinity)
#else
                    Text("Export My Library…")
#endif
                }
                .labelStyle(.titleAndIcon)
                .accessibilityIdentifier("library-opml-share")
            } else {
                Button {
                } label: {
#if os(macOS)
                    Text("Share My Library…")
                        .frame(maxWidth: .infinity)
#else
                    Text("Export My Library…")
#endif
                }
                .disabled(true)
            }
        }
        if libraryManagerViewModel.opmlExportFailed {
            Button("Export failed. Retry") {
                libraryManagerViewModel.refreshOPMLExport()
            }
            .accessibilityIdentifier("library-opml-retry")
        }
#if os(macOS)
        Button {
            guard let exportedXML = libraryManagerViewModel.exportedOPML?.xml else { return }
            savePanel = savePanel ?? NSSavePanel()
            guard let savePanel = savePanel else { return }
            savePanel.allowedContentTypes = [UTType(exportedAs: "public.opml")]
            savePanel.allowsOtherFileTypes = false
            savePanel.prompt = "Export OPML"
            savePanel.title = "Export OPML"
            savePanel.nameFieldLabel = "Export to:"
            savePanel.message = "Choose a location for the exported OPML file."
            savePanel.isExtensionHidden = false
            savePanel.nameFieldStringValue = "ManabiReaderUserLibrary.opml"
            guard let window = window else { return }
            savePanel.beginSheetModal(for: window) { result in
                if result == NSApplication.ModalResponse.OK, let url = savePanel.url {
                    Task { @MainActor in
                        //                                    let filename = url.lastPathComponent
                        do {
                            try exportedXML.write(to: url, atomically: true, encoding: String.Encoding.utf8)
                        }
                        catch let error as NSError {
                            NSApplication.shared.presentError(error)
                        }
                    }
                }
            }
        } label: {
            Label("Export My Library…", systemImage: "square.and.arrow.down")
                .frame(maxWidth: .infinity)
        }
        .background(WindowAccessor(for: $window))
        .disabled(libraryManagerViewModel.exportedOPML == nil)
#endif
        FilePicker(types: [UTType(exportedAs: "public.opml"), .xml], allowMultiple: true, afterPresented: nil, onPicked: { urls in
            let realmConfiguration = viewModel.realmConfiguration
            Task.detached {
                await LibraryDataManager.shared.importOPML(
                    fileURLs: urls, realmConfiguration: realmConfiguration
                )
            }
        }, label: {
            Label("Import My Library…", systemImage: "square.and.arrow.down")
#if os(macOS)
                .frame(maxWidth: .infinity)
#endif
        })
    }
    
    @ViewBuilder var userLibraryView: some View {
        let categories = viewModel.userLibraryCategories ?? []
        let displayedCategoryIDs = categories.map(\.id)
        ForEach(categories) { category in
            NavigationLink(value: LibrarySidebarDestination.category(category.id)) {
                FeedCategoryButtonLabel(
                    title: category.title,
                    backgroundImageURL: category.backgroundImageUrl,
                    isCompact: true,
                    showEditingDisabled: !category.isUserEditable
                )
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .id("library-sidebar-\(category.id.uuidString)")
            .accessibilityIdentifier("library-sidebar-\(category.id.uuidString)")
            .listRowSeparator(.hidden)
            .deleteDisabled(!category.isUserEditable)
            .moveDisabled(!category.isUserEditable)
            .swipeActions(edge: .trailing) {
                if viewModel.showDeleteButton(category: category) {
                    Button(role: .destructive) {
                        Task {
                            try await viewModel.deleteCategory(category)
                        }
                    } label: {
                        Text(viewModel.deletionTitle(category: category))
                    }
                    .tint(.red)
                }
            }
            .contextMenu {
                if viewModel.showDeleteButton(category: category) {
                    Button(role: .destructive) {
                        Task {
                            try await viewModel.deleteCategory(category)
                        }
                    } label: {
                        Label("Archive", systemImage: "archivebox")
                    }
                }
            }
        }
        .onMove {
            _ = viewModel.moveCategories(
                fromOffsets: $0, toOffset: $1, displayedCategoryIDs: displayedCategoryIDs
            )
        }
        .onDelete {
            _ = viewModel.deleteCategory(at: $0, fromCategoryIDs: displayedCategoryIDs)
        }
    }

    @ViewBuilder var editorsPicksLibraryView: some View {
        ForEach(viewModel.editorsPicksLibraryCategories ?? []) { category in
            NavigationLink(value: LibrarySidebarDestination.category(category.id)) {
                FeedCategoryButtonLabel(
                    title: category.title,
                    backgroundImageURL: category.backgroundImageUrl,
                    isCompact: true,
                    showEditingDisabled: !category.isUserEditable
                )
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .id("library-sidebar-\(category.id.uuidString)")
            .listRowSeparator(.hidden)
            .deleteDisabled(true)
            .moveDisabled(true)
        }
    }
    
    @ViewBuilder var archiveView: some View {
        let categories = viewModel.archivedCategories ?? []
        let displayedCategoryIDs = categories.map(\.id)
        ForEach(categories) { category in
            NavigationLink(value: LibrarySidebarDestination.category(category.id)) {
                FeedCategoryButtonLabel(title: category.title, backgroundImageURL: category.backgroundImageUrl, isCompact: true)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .saturation(0)
            }
            .id("library-sidebar-\(category.id.uuidString)")
            .accessibilityIdentifier("library-sidebar-\(category.id.uuidString)")
            .listRowSeparator(.hidden)
            .swipeActions(edge: .leading) {
                if viewModel.showRestoreButton(category: category) {
                    Button {
                        Task {
                            try await viewModel.restoreCategory(category)
                        }
                    } label: {
                        Text("Restore")
                    }
                }
            }
            .swipeActions(edge: .trailing) {
                if viewModel.showDeleteButton(category: category) {
                    Button(role: .destructive) {
                        Task {
                            try await viewModel.deleteCategory(category)
                        }
                    } label: {
                        Text("Delete")
                    }
                    .tint(.red)
                }
            }
            .contextMenu {
                if viewModel.showRestoreButton(category: category) {
                    Button {
                        Task {
                            try await viewModel.restoreCategory(category)
                        }
                    } label: {
                        Label("Restore Category", systemImage: "plus")
                    }
                    Divider()
                }
                if viewModel.showDeleteButton(category: category) {
                    Button(role: .destructive) {
                        Task {
                            try await viewModel.deleteCategory(category)
                        }
                    } label: {
                        Text(viewModel.deletionTitle(category: category))
                    }
                    .tint(.red)
                }
            }
        }
        .onDelete {
            _ = viewModel.deleteCategory(at: $0, fromCategoryIDs: displayedCategoryIDs)
        }
    }
    
    var body: some View {
        ScrollViewReader { scrollProxy in
            List(selection: Binding(
                get: { libraryManagerViewModel.selectedSidebarDestination },
                set: { libraryManagerViewModel.selectedSidebarDestination = $0 }
            )) {
                Section {
                    if isUserLibraryEmpty {
                        EmptyStateBoxView(
                            title: Text("Create categories for your feeds"),
                            text: Text("Add categories to organize the RSS and Atom feeds you want to keep in your library. When Manabi Reader detects a feed on a webpage, an RSS menu appears in the toolbar or the More menu so you can add it here."),
                            systemImageName: "square.stack.3d.up"
                        ) {
                            emptyStateAddCategoryButton(scrollProxy: scrollProxy)
                        }
                        .listRowSeparatorIfAvailable(.hidden)
                        .listRowBackground(Color.clear)
                        .stackListStyle(.grouped)
                    } else {
                        userLibraryView
                    }
                } header: {
                    HStack {
                        Text("My Library")
                            .foregroundStyle(.primary)
                        if !isUserLibraryEmpty {
                            Spacer(minLength: 12)
                            inlineAddCategoryButton(scrollProxy: scrollProxy)
                        }
                    }
                }

                Section(header: EmptyView(), footer: Text("Uses the OPML file format for RSS reader compatibility. User Scripts can also be shared. My Library exports exclude system-provided data.").font(.footnote).foregroundColor(.secondary)) {
                    importExportView
                }
                .onAppear {
                    libraryManagerViewModel.registerOPMLExportUI(exportViewRegistrationID)
                }
                .onDisappear {
                    libraryManagerViewModel.unregisterOPMLExportUI(exportViewRegistrationID)
                }
                .labelStyle(.titleOnly)
                .accentColor(appTint)
                
                Section {
                    editorsPicksLibraryView
                } header: {
                    Text("Editor's Picks")
                        .foregroundStyle(.primary)
                }
                
                Section("Extensions") {
                    NavigationLink(value: LibrarySidebarDestination.userScripts, label: {
                        Label("User Scripts", systemImage: "wrench.and.screwdriver")
                    })
                }
                
                Section {
                    archiveView
                } header: {
                    Text("Archive")
                        .foregroundStyle(.primary)
                }
            }
            .headerProminence(.increased)
            .listStyle(.sidebar)
#if os(iOS)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !isUserLibraryEmpty {
                        EditButton()
                            .tint(.primary)
                    }
                }
            }
#endif
            .onChange(of: categoryIDNeedsScrollTo) { categoryIDNeedsScrollTo in
                guard let categoryIDNeedsScrollTo else { return }
                Task { @MainActor in
                    scrollProxy.scrollTo("library-sidebar-\(categoryIDNeedsScrollTo)")
                    self.categoryIDNeedsScrollTo = nil
                }
            }
        }
    }
    
    @ViewBuilder func addCategoryButton(scrollProxy: ScrollViewProxy) -> some View {
        Button {
            createCategory(scrollProxy: scrollProxy)
        } label: {
            Text("Add Category")
                .foregroundStyle(.primary)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .font(.footnote)
        .fontWeight(.semibold)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Add Category")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("Library.AddCategory")
    }

    @ViewBuilder private func inlineAddCategoryButton(scrollProxy: ScrollViewProxy) -> some View {
        addCategoryButton(scrollProxy: scrollProxy)
            .tint(.secondary)
    }

    @ViewBuilder private func emptyStateAddCategoryButton(scrollProxy: ScrollViewProxy) -> some View {
        Button("Add Category") {
            createCategory(scrollProxy: scrollProxy)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Add Category")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("Library.AddCategory")
        .tint(.secondary)
        .foregroundStyle(.primary)
    }

    private func createCategory(scrollProxy: ScrollViewProxy) {
        Task { @MainActor in
            let categoryID = try await viewModel.createCategory()
            let realm = try await Realm.open(configuration: viewModel.realmConfiguration)
            guard let category = realm.object(ofType: FeedCategory.self, forPrimaryKey: categoryID) else { return }
            categoryIDNeedsScrollTo = category.id.uuidString
            try await Task.sleep(nanoseconds: 100_000_000)
            libraryManagerViewModel.showCategory(category.id)
        }
    }
}
