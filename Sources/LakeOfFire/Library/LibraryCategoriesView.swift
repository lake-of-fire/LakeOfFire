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

fileprivate class LibraryCategoriesViewModel: ObservableObject {
    @Published var categories: [FeedCategory]? = nil
    @Published var archivedCategories: [FeedCategory]? = nil
    
    private var cancellables = Set<AnyCancellable>()
    
    @Published var libraryConfiguration: LibraryConfiguration? {
        didSet {
            setCategories(from: libraryConfiguration)
            Task.detached { @RealmBackgroundActor [weak self] in
                guard let self = self else { return }
                let libraryConfiguration = try await LibraryConfiguration.getOrCreate()
                objectNotificationToken?.invalidate()
                objectNotificationToken = libraryConfiguration
                    .observe(keyPaths: ["id", "isDeleted", "categories.id", "categories.title", "categories.backgroundImageUrl", "categories.isArchived", "categories.isDeleted"]) { [weak self] change in
                        guard let self = self else { return }
                        switch change {
                        case .change(let object, _):
                            guard let libraryConfiguration = object as? LibraryConfiguration else { return }
                            let ref = ThreadSafeReference(to: libraryConfiguration)
                            Task { @MainActor [weak self] in
                                guard let self = self else { return }
                                let realm = try await Realm(configuration: LibraryDataManager.realmConfiguration, actor: MainActor.shared)
                                if let libraryConfiguration = realm.resolve(ref) {
                                    setCategories(from: libraryConfiguration)
                                }
                            }
                        case .deleted:
                            Task { @MainActor [weak self] in
                                self?.categories = nil
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
        let realm = try! Realm(configuration: LibraryDataManager.realmConfiguration)
        realm.objects(FeedCategory.self)
            .where { !$0.isDeleted }
            .collectionPublisher
            .freeze()
            .removeDuplicates()
            .debounce(for: .seconds(0.1), scheduler: DispatchQueue.main)
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { _ in}, receiveValue: { [weak self] categories in
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    let libraryConfiguration = try await LibraryConfiguration.getOnMain()
                    let activeCategoryIDs = libraryConfiguration?.categories.map { $0.id } ?? []
                    self.archivedCategories = categories.filter { category in
                        category.isArchived
                        || !activeCategoryIDs.contains(category.id)
                    }
                }
            })
            .store(in: &cancellables)
        
        Task.detached { @RealmBackgroundActor [weak self] in
            let libraryConfigurationRef = try await ThreadSafeReference(to: LibraryConfiguration.getOrCreate())
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let realm = try await Realm(configuration: LibraryDataManager.realmConfiguration, actor: MainActor.shared)
                guard let libraryConfiguration = realm.resolve(libraryConfigurationRef) else { return }
                self.libraryConfiguration = libraryConfiguration
            }
        }
    }
    
    deinit {
        Task.detached { @RealmBackgroundActor [objectNotificationToken] in
            objectNotificationToken?.invalidate()
        }
    }
    
    private func setCategories(from libraryConfiguration: LibraryConfiguration?) {
        guard let libraryConfiguration = libraryConfiguration else {
            categories = nil
            return
        }
        categories = Array(libraryConfiguration.categories).filter { !$0.isArchived && !$0.isDeleted }
    }
    
    @MainActor
    func deleteCategory(_ category: FeedCategory) async throws {
        guard let libraryConfiguration = libraryConfiguration else { return }
        if !category.isUserEditable || (category.isArchived && category.opmlURL != nil) {
            return
        }
        
        let categoryID = category.id
        try await Realm.asyncWrite(ThreadSafeReference(to: libraryConfiguration), configuration: LibraryDataManager.realmConfiguration) { realm, libraryConfiguration in
            guard let category = realm.object(ofType: FeedCategory.self, forPrimaryKey: categoryID) else { return }
            if let idx = libraryConfiguration.categories.firstIndex(of: category) {
                libraryConfiguration.categories.remove(at: idx)
            }
        }
        
        try await Realm.asyncWrite(ThreadSafeReference(to: category), configuration: LibraryDataManager.realmConfiguration) { realm, category in
            if category.isArchived && !LibraryConfiguration.opmlURLs.map({ $0 }).contains(category.opmlURL) {
                category.isDeleted = true
            } else if !category.isArchived {
                category.isArchived = true
            }
        }
    }
    
    @MainActor
    func deleteCategory(at offsets: IndexSet) {
        Task { @MainActor in
            guard let libraryConfiguration = libraryConfiguration else { return }
            for offset in offsets {
                let category = libraryConfiguration.categories[offset]
                guard category.isUserEditable else { continue }
                try await deleteCategory(category)
            }
        }
    }
    
    @MainActor
    func restoreCategory(_ category: FeedCategory) async throws {
        guard let libraryConfiguration = libraryConfiguration else { return }
        guard category.isUserEditable else { return }
        try await Realm.asyncWrite(ThreadSafeReference(to: category), configuration: LibraryDataManager.realmConfiguration) { realm, category in
            category.isArchived = false
        }
        let categoryID = category.id
        try await Realm.asyncWrite(ThreadSafeReference(to: libraryConfiguration), configuration: LibraryDataManager.realmConfiguration) { realm, libraryConfiguration in
            guard let category = realm.object(ofType: FeedCategory.self, forPrimaryKey: categoryID) else { return }
            if !libraryConfiguration.categories.contains(category) {
                libraryConfiguration.categories.append(category)
            }
        }
    }
    
    @MainActor
    func moveCategories(fromOffsets: IndexSet, toOffset: Int) {
        Task { @MainActor in
            guard let libraryConfiguration = libraryConfiguration else { return }
            try await Realm.asyncWrite(ThreadSafeReference(to: libraryConfiguration), configuration: LibraryDataManager.realmConfiguration) { _, libraryConfiguration in
                libraryConfiguration.categories.move(fromOffsets: fromOffsets, toOffset: toOffset)
            }
        }
    }
}

@available(iOS 16.0, macOS 13.0, *)
struct LibraryCategoriesView: View {
    @StateObject private var viewModel = LibraryCategoriesViewModel()
    @EnvironmentObject private var libraryManagerViewModel: LibraryManagerViewModel
    
    @AppStorage("appTint") private var appTint: Color = .accentColor
    
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
            Text("Share User Library…")
                .frame(maxWidth: .infinity)
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
                .frame(maxWidth: .infinity)
        })
    }
    
    @ViewBuilder var libraryView: some View {
        ForEach(viewModel.categories ?? []) { category in
            NavigationLink(value: category) {
                FeedCategoryButtonLabel(title: category.title, backgroundImageURL: category.backgroundImageUrl, font: .headline, isCompact: true)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .listRowSeparator(.hidden)
            .deleteDisabled(!category.isUserEditable)
            .moveDisabled(!category.isUserEditable)
            .contextMenu {
                if category.isUserEditable {
                    Button {
                        Task {
                            try await viewModel.deleteCategory(category)
                        }
                    } label: {
                        Label("Archive", systemImage: "archivebox")
                    }
                }
            }
            //                        .id("library-sidebar-\(category.id.uuidString)")
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
                Button {
                    Task {
                        try await viewModel.restoreCategory(category)
                    }
                } label: {
                    Label("Restore", systemImage: "plus")
                }
            }
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) {
                    Task {
                        try await viewModel.deleteCategory(category)
                    }
                } label: {
                    Text("Delete")
                }
                .tint(.red)
            }
            .contextMenu {
                if category.isUserEditable {
                    Button {
                        Task {
                            try await viewModel.restoreCategory(category)
                        }
                    } label: {
                        Label("Restore", systemImage: "plus")
                    }
                    Divider()
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
            //                        .id("library-sidebar-\(category.id.uuidString)")
        }
        .onDelete {
            viewModel.deleteCategory(at: $0)
        }
    }
    
    var body: some View {
        ScrollViewReader { scrollProxy in
            List {
                Section(header: Text("Import and Export"), footer: Text("Imports and exports use the OPML file format, which is optimized for RSS reader compatibility. The User Scripts category is supported for importing/exporting. User Library exports exclude Manabi Reader system-provided data.").font(.footnote).foregroundColor(.secondary)) {
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
                    EditButton()
                }
                ToolbarItem(placement: addButtonPlacement) {
                    addCategoryButton(scrollProxy: scrollProxy)
                }
            }
#endif
        }
    }
    
    func addCategoryButton(scrollProxy: ScrollViewProxy) -> some View {
        Button {
            Task { @MainActor in
                let category = try await LibraryDataManager.shared.createEmptyCategory(addToLibrary: true)
                scrollProxy.scrollTo("library-sidebar-\(category.id.uuidString)")
            }
        } label: {
            Label("Add User Category", systemImage: "plus.circle")
                .labelStyle(.titleAndIcon)
        }
    }
}
