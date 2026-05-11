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
fileprivate class LibraryCategoriesViewModel: ObservableObject {
    @Published var categories: [FeedCategory]? = nil
    @Published var userLibraryCategories: [FeedCategory]? = nil
    @Published var editorsPicksLibraryCategories: [FeedCategory]? = nil
    @Published var archivedCategories: [FeedCategory]? = nil
    
    @RealmBackgroundActor
    private var cancellables = Set<AnyCancellable>()
    
    @Published var libraryConfiguration: LibraryConfiguration?
    
    init() {
        Task { @RealmBackgroundActor [weak self] in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: LibraryDataManager.realmConfiguration)

            realm.objects(LibraryConfiguration.self)
                .collectionPublisher
                .subscribe(on: libraryCategoriesQueue)
                .map { _ in }
                .debounceLeadingTrailing(for: .seconds(0.3), scheduler: libraryDataQueue)
                .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.refreshData()
                    }
                })
                .store(in: &cancellables)
            
            realm.objects(FeedCategory.self)
                .collectionPublisher
                .subscribe(on: libraryCategoriesQueue)
                .map { _ in }
                .debounceLeadingTrailing(for: .seconds(0.3), scheduler: libraryCategoriesQueue)
                .sink(receiveCompletion: { _ in}, receiveValue: { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.refreshData()
                    }
                })
                .store(in: &cancellables)
        }
    }
        
    private func refreshData() {
        Task { @RealmBackgroundActor in
            let libraryConfiguration = try await LibraryConfiguration.getConsolidatedOrCreate()
            let libraryConfigurationID = libraryConfiguration.id
            
            try await { @MainActor [weak self] in
                guard let self else { return }
                let realm = try await Realm.open(configuration: LibraryDataManager.realmConfiguration)
                
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
        let ref = ThreadSafeReference(to: category)
        async let task = { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: LibraryDataManager.realmConfiguration)
            guard let category = realm.resolve(ref) else { return }
            try await LibraryDataManager.shared.deleteCategory(category)
        }()
        try await task
    }
    
    @MainActor
    func restoreCategory(_ category: FeedCategory) async throws {
        let ref = ThreadSafeReference(to: category)
        async let task = { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: LibraryDataManager.realmConfiguration)
            guard let category = realm.resolve(ref) else { return }
            try await LibraryDataManager.shared.restoreCategory(category)
        }()
        try await task
    }
    
    @MainActor
    func deleteCategory(at offsets: IndexSet) {
        Task { @MainActor in
            guard let libraryConfiguration = libraryConfiguration else { return }
            guard let categories = libraryConfiguration.getCategories() else { return }
            for offset in offsets {
                let category = categories[offset]
                guard category.isUserEditable else { continue }
                let ref = ThreadSafeReference(to: category)
                try await Task { @RealmBackgroundActor in
                    let realm = try await RealmBackgroundActor.shared.cachedRealm(for: LibraryDataManager.realmConfiguration)
                    guard let category = realm.resolve(ref) else { return }
                    try await LibraryDataManager.shared.deleteCategory(category)
                }.value
            }
        }
    }
   
    @MainActor
    func moveCategories(fromOffsets: IndexSet, toOffset: Int) {
        Task { @MainActor in
            guard let libraryConfiguration = libraryConfiguration else { return }
            try await Realm.asyncWrite(ThreadSafeReference(to: libraryConfiguration), configuration: LibraryDataManager.realmConfiguration) { _, libraryConfiguration in
                libraryConfiguration.categoryIDs.move(fromOffsets: fromOffsets, toOffset: toOffset)
                libraryConfiguration.refreshChangeMetadata(explicitlyModified: true)
            }
        }
    }
}

@available(iOS 16.0, macOS 13.0, *)
struct LibraryCategoriesView: View {
    @StateObject private var viewModel = LibraryCategoriesViewModel()
    
    @EnvironmentObject private var libraryManagerViewModel: LibraryManagerViewModel

    @AppStorage("appTint") private var appTint: Color = .accentColor
    
    @State private var categoryIDNeedsScrollTo: String?
    
#if os(macOS)
    @State private var savePanel: NSSavePanel?
    @State private var window: NSWindow?
#endif
    
    private var isUserLibraryEmpty: Bool {
        guard let userLibraryCategories = viewModel.userLibraryCategories else { return false }
        return userLibraryCategories.isEmpty
    }

    @ViewBuilder var importExportView: some View {
        ShareLink(item: libraryManagerViewModel.exportedOPMLFileURL ?? URL(string: "about:blank")!, message: Text(""), preview: SharePreview("Manabi Reader User Feeds OPML File", image: Image(systemName: "doc"))) {
#if os(macOS)
            Text("Share My Library…")
                .frame(maxWidth: .infinity)
#else
            Text("Export My Library…")
#endif
        }
        .labelStyle(.titleAndIcon)
        .disabled(libraryManagerViewModel.exportedOPML == nil)
#if os(macOS)
        Button {
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
                if result == NSApplication.ModalResponse.OK, let url = savePanel.url, let opml = libraryManagerViewModel.exportedOPML {
                    Task { @MainActor in
                        //                                    let filename = url.lastPathComponent
                        do {
                            try opml.xml.write(to: url, atomically: true, encoding: String.Encoding.utf8)
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
            Task.detached {
                await LibraryDataManager.shared.importOPML(fileURLs: urls)
            }
        }, label: {
            Label("Import My Library…", systemImage: "square.and.arrow.down")
#if os(macOS)
                .frame(maxWidth: .infinity)
#endif
        })
    }
    
    @ViewBuilder var userLibraryView: some View {
        ForEach(viewModel.userLibraryCategories ?? []) { category in
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
            viewModel.moveCategories(fromOffsets: $0, toOffset: $1)
        }
        .onDelete {
            viewModel.deleteCategory(at: $0)
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
        ForEach(viewModel.archivedCategories ?? []) { category in
            NavigationLink(value: LibrarySidebarDestination.category(category.id)) {
                FeedCategoryButtonLabel(title: category.title, backgroundImageURL: category.backgroundImageUrl, isCompact: true)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .saturation(0)
            }
            .id("library-sidebar-\(category.id.uuidString)")
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
            viewModel.deleteCategory(at: $0)
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
    }

    @ViewBuilder private func inlineAddCategoryButton(scrollProxy: ScrollViewProxy) -> some View {
        addCategoryButton(scrollProxy: scrollProxy)
            .tint(.secondary)
    }

    @ViewBuilder private func emptyStateAddCategoryButton(scrollProxy: ScrollViewProxy) -> some View {
        Button("Add Category") {
            createCategory(scrollProxy: scrollProxy)
        }
        .tint(.secondary)
        .foregroundStyle(.primary)
    }

    private func createCategory(scrollProxy: ScrollViewProxy) {
        Task { @RealmBackgroundActor in
            let categoryID = try await LibraryDataManager.shared.createEmptyCategory(addToLibrary: true)
            try await { @MainActor in
                let realm = try await Realm.open(configuration: LibraryDataManager.realmConfiguration)
                guard let category = realm.object(ofType: FeedCategory.self, forPrimaryKey: categoryID) else { return }
                categoryIDNeedsScrollTo = category.id.uuidString
                try await Task.sleep(nanoseconds: 100_000_000)
                libraryManagerViewModel.showCategory(category.id)
            }()
        }
    }
}
