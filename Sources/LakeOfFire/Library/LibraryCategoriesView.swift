import SwiftUI
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

let libraryCategoriesQueue = DispatchQueue(label: "LibraryCategories")

fileprivate class LibraryCategoriesViewModel: ObservableObject {
    @Published var categories: [FeedCategory]? = nil
    @Published var archivedCategories: [FeedCategory]? = nil
    
    @RealmBackgroundActor
    private var cancellables = Set<AnyCancellable>()
    
    @Published var libraryConfiguration: LibraryConfiguration?
    
    init() {
        Task { @RealmBackgroundActor [weak self] in
            guard let realm = await RealmBackgroundActor.shared.cachedRealm(for: LibraryDataManager.realmConfiguration) else { return }

            realm.objects(LibraryConfiguration.self)
                .collectionPublisher
                .subscribe(on: libraryCategoriesQueue)
                .map { _ in }
                .debounce(for: .seconds(0.3), scheduler: libraryDataQueue)
                .sink(receiveCompletion: { _ in }, receiveValue: { _ in
                    self?.refreshData()
                })
                .store(in: &cancellables)
            
            realm.objects(FeedCategory.self)
                .collectionPublisher
                .subscribe(on: libraryCategoriesQueue)
                .map { _ in }
                .debounce(for: .seconds(0.3), scheduler: libraryCategoriesQueue)
                .sink(receiveCompletion: { _ in}, receiveValue: { [weak self] _ in
                    self?.refreshData()
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
                let realm = try await Realm(configuration: LibraryDataManager.realmConfiguration, actor: MainActor.shared)
                
                guard let libraryConfiguration = realm.object(ofType: LibraryConfiguration.self, forPrimaryKey: libraryConfigurationID) else { return }
                self.libraryConfiguration = libraryConfiguration
                self.categories = Array(libraryConfiguration.categories)

                let activeCategoryIDs = libraryConfiguration.activeCategories.map { $0.id } ?? []
                self.archivedCategories = Array(realm.objects(FeedCategory.self).where { ($0.isArchived || !$0.id.in(activeCategoryIDs)) && !$0.isDeleted })
            }()
        }
    }
    
    func deletionTitle(category: FeedCategory) -> String {
        if category.isArchived {
            return "Delete Category"
        }
        return "Archive Category"
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
            guard let realm = await RealmBackgroundActor.shared.cachedRealm(for: LibraryDataManager.realmConfiguration) else { return }
            guard let category = realm.resolve(ref) else { return }
            try await LibraryDataManager.shared.deleteCategory(category)
        }()
        try await task
    }
    
    @MainActor
    func restoreCategory(_ category: FeedCategory) async throws {
        let ref = ThreadSafeReference(to: category)
        async let task = { @RealmBackgroundActor in
            guard let realm = await RealmBackgroundActor.shared.cachedRealm(for: LibraryDataManager.realmConfiguration) else { return }
            guard let category = realm.resolve(ref) else { return }
            try await LibraryDataManager.shared.restoreCategory(category)
        }()
        try await task
    }
    
    @MainActor
    func deleteCategory(at offsets: IndexSet) {
        Task { @MainActor in
            guard let libraryConfiguration = libraryConfiguration else { return }
            for offset in offsets {
                let category = libraryConfiguration.categories[offset]
                guard category.isUserEditable else { continue }
                let ref = ThreadSafeReference(to: category)
                try await Task { @RealmBackgroundActor in
                    guard let realm = await RealmBackgroundActor.shared.cachedRealm(for: LibraryDataManager.realmConfiguration) else { return }
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
                libraryConfiguration.categories.move(fromOffsets: fromOffsets, toOffset: toOffset)
                libraryConfiguration.modifiedAt = Date()
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
    
    var addButtonPlacement: ToolbarItemPlacement {
#if os(iOS)
        return .bottomBar
#else
        return .automatic
#endif
    }
    
    @ViewBuilder var importExportView: some View {
        ShareLink(item: libraryManagerViewModel.exportedOPMLFileURL ?? URL(string: "about:blank")!, message: Text(""), preview: SharePreview("Manabi Reader User Feeds OPML File", image: Image(systemName: "doc"))) {
#if os(macOS)
            Text("Share User Library…")
                .frame(maxWidth: .infinity)
#else
            Text("Export User Library…")
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
            Label("Export User Library…", systemImage: "square.and.arrow.down")
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
            Label("Import User Library…", systemImage: "square.and.arrow.down")
#if os(macOS)
                .frame(maxWidth: .infinity)
#endif
        })
    }
    
    @ViewBuilder var libraryView: some View {
        ForEach(viewModel.categories ?? []) { category in
            NavigationLink(value: category) {
                FeedCategoryButtonLabel(
                    title: category.title,
                    backgroundImageURL: category.backgroundImageUrl,
                    font: .headline,
                    isCompact: true,
                    showEditingDisabled: !category.isUserEditable
                )
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
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
    
    @ViewBuilder var archiveView: some View {
        ForEach(viewModel.archivedCategories ?? []) { category in
            NavigationLink(value: category) {
                FeedCategoryButtonLabel(title: category.title, backgroundImageURL: category.backgroundImageUrl, font: .headline, isCompact: true)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .saturation(0)
            }
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
            List {
                Section(header: EmptyView(), footer: Text("Uses the OPML file format for RSS reader compatibility. User Scripts can also be shared. User Library exports exclude system-provided data.").font(.footnote).foregroundColor(.secondary)) {
                    importExportView
                }
                .labelStyle(.titleOnly)
                .tint(appTint)
                
                Section("Extensions") {
                    NavigationLink(value: LibraryRoute.userScripts, label: {
                        Label("User Scripts", systemImage: "wrench.and.screwdriver")
                    })
                }
                
                Section("Library") {
                    libraryView
                }
                
                Section("Archive") {
                    archiveView
                }
            }
            .listStyle(.sidebar)
#if os(macOS)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 0) {
                    addCategoryButton(scrollProxy: scrollProxy)
                        .buttonStyle(.borderless)
                        .padding()
                    Spacer(minLength: 0)
                }
            }
#endif
#if os(iOS)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if viewModel.categories?.contains(where: { $0.isUserEditable }) ?? false {
                        EditButton()
                    }
                }
                ToolbarItemGroup(placement: addButtonPlacement) {
                    addCategoryButton(scrollProxy: scrollProxy)
                    Spacer(minLength: 0)
                }
            }
#endif
        }
    }
    
    @ViewBuilder func addCategoryButton(scrollProxy: ScrollViewProxy) -> some View {
        Button {
            Task { @RealmBackgroundActor in
                let category = try await LibraryDataManager.shared.createEmptyCategory(addToLibrary: true)
                let ref = ThreadSafeReference(to: category)
                try await Task { @MainActor in
                    let realm = try await Realm(configuration: LibraryDataManager.realmConfiguration, actor: MainActor.shared)
                    guard let category = realm.resolve(ref) else { return }
                    categoryIDNeedsScrollTo = category.id.uuidString
                    try await Task.sleep(nanoseconds: 100_000_000_000)
                    libraryManagerViewModel.navigationPath.removeLast(libraryManagerViewModel.navigationPath.count)
                    libraryManagerViewModel.navigationPath.append(category)
                }.value
            }
        } label: {
            Label("Add Category", systemImage: "plus.circle")
        }
        .labelStyle(.titleAndIcon)
        .buttonStyle(.borderless)
        .onChange(of: categoryIDNeedsScrollTo) { categoryIDNeedsScrollTo in
            guard let categoryIDNeedsScrollTo = categoryIDNeedsScrollTo else { return }
            Task { @MainActor in // Untested whether this is needed
                scrollProxy.scrollTo("library-sidebar-\(categoryIDNeedsScrollTo)")
                self.categoryIDNeedsScrollTo = nil
            }
        }
    }
}
