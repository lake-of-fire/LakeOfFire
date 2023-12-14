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

@MainActor
fileprivate class LibraryCategoriesViewModel: ObservableObject {
    @Published var libraryConfiguration: LibraryConfiguration?
    
    @RealmBackgroundActor private var objectNotificationToken: NotificationToken?
    
    init() {
        Task { @RealmBackgroundActor [weak self] in
            guard let self = self else { return }
            let libraryConfiguration = try await LibraryConfiguration.shared
            objectNotificationToken = libraryConfiguration
                .observe { [weak self] change in
                    guard let self = self else { return }
                    switch change {
                    case .change(_, _):
                        objectWillChange.send()
                    case .error(let error):
                        print("An error occurred: \(error)")
                    case .deleted:
                        print("The object was deleted.")
                    }
                }
            let libraryConfigurationRef = try await ThreadSafeReference(to: LibraryConfiguration.shared)
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let realm = try await Realm(configuration: LibraryDataManager.realmConfiguration)
                guard let libraryConfiguration = realm.resolve(libraryConfigurationRef) else { return }
                self.libraryConfiguration = libraryConfiguration
            }
        }
    }
    
    deinit {
        Task { @RealmBackgroundActor [weak self] in
            self?.objectNotificationToken?.invalidate()
        }
    }
    
    @MainActor
    func deleteCategory(_ category: FeedCategory) async throws {
        guard let libraryConfiguration = libraryConfiguration else { return }
        if !category.isUserEditable || (category.isArchived && category.opmlURL != nil) {
            return
        }
        
        let categoryID = category.id
        try await Realm.asyncWrite(ThreadSafeReference(to: libraryConfiguration)) { realm, libraryConfiguration in
            guard let category = realm.object(ofType: FeedCategory.self, forPrimaryKey: categoryID) else { return }
            if let idx = libraryConfiguration.categories.firstIndex(of: category) {
                libraryConfiguration.categories.remove(at: idx)
            }
        }
        
        try await Realm.asyncWrite(ThreadSafeReference(to: category)) { realm, category in
            if category.isArchived && !LibraryConfiguration.opmlURLs.map({ $0 }).contains(category.opmlURL) {
                category.isDeleted = true
            } else if !category.isArchived {
                category.isArchived = true
            }
        }
    }
    
    @MainActor
    func deleteCategory(at offsets: IndexSet) async throws {
        guard let libraryConfiguration = libraryConfiguration else { return }
        for offset in offsets {
            let category = libraryConfiguration.categories[offset]
            guard category.isUserEditable else { continue }
            try await deleteCategory(category)
        }
    }
    
    @MainActor
    func restoreCategory(_ category: FeedCategory) async throws {
        guard let libraryConfiguration = libraryConfiguration else { return }
        guard category.isUserEditable else { return }
        try await Realm.asyncWrite(ThreadSafeReference(to: category)) { realm, category in
            category.isArchived = false
        }
        let categoryID = category.id
        try await Realm.asyncWrite(ThreadSafeReference(to: libraryConfiguration)) { realm, libraryConfiguration in
            guard let category = realm.object(ofType: FeedCategory.self, forPrimaryKey: categoryID) else { return }
            if !libraryConfiguration.categories.contains(category) {
                libraryConfiguration.categories.append(category)
            }
        }
    }
}

@available(iOS 16.0, macOS 13.0, *)
struct LibraryCategoriesView: View {
    @ObservedObject private var libraryManagerViewModel = LibraryManagerViewModel.shared
    @StateObject private var viewModel = LibraryCategoriesViewModel()
    
    @AppStorage("appTint") private var appTint: Color = .accentColor
    
    @ObservedResults(FeedCategory.self, configuration: LibraryDataManager.realmConfiguration, where: { $0.isDeleted == false }) private var categories
    private var archivedCategories: [FeedCategory] {
        Array(categories.filter({ $0.isArchived || !(viewModel.libraryConfiguration?.categories.contains($0) ?? false) }))
    }
    
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
    
    func sections(libraryConfiguration: LibraryConfiguration) -> some View {
        Section(header: Text("Import and Export"), footer: Text("Imports and exports use the OPML file format, which is optimized for RSS reader compatibility. The User Scripts category is supported for importing/exporting. User Library exports exclude Manabi Reader system-provided data.").font(.footnote).foregroundColor(.secondary)) {
            ShareLink(item: libraryManagerViewModel.exportedOPMLFileURL ?? URL(string: "about:blank")!, message: Text(""), preview: SharePreview("Manabi Reader User Feeds OPML File", image: Image(systemName: "doc"))) {
                Text("Share User Library…")
                    .frame(maxWidth: .infinity)
            }
            .labelStyle(.titleAndIcon)
            .disabled(viewModel.exportedOPML == nil)
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
            .disabled(viewModel.exportedOPML == nil)
#endif
            FilePicker(types: [UTType(exportedAs: "public.opml"), .xml], allowMultiple: true, afterPresented: nil, onPicked: { urls in
                Task.detached {
                    LibraryDataManager.shared.importOPML(fileURLs: urls)
                }
            }, label: {
                Label("Import User Library…", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            })
            
        }
        .labelStyle(.titleOnly)
        .tint(appTint)
        Section("Extensions") {
            NavigationLink(value: LibraryRoute.userScripts, label: {
                Label("User Scripts", systemImage: "wrench.and.screwdriver")
            })
        }
        Section("Library") {
            ForEach(libraryConfiguration.categories) { category in
                NavigationLink(value: category) {
                    FeedCategoryButtonLabel(category: category, font: .headline, isCompact: true)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .listRowSeparator(.hidden)
                .deleteDisabled(!category.isUserEditable)
                .moveDisabled(!category.isUserEditable)
                .contextMenu {
                    if category.isUserEditable {
                        Button {
                            Task {
                                try await deleteCategory(category)
                            }
                        } label: {
                            Label("Archive", systemImage: "archivebox")
                        }
                    }
                }
                //                        .id("library-sidebar-\(category.id.uuidString)")
            }
            .onMove(perform: $libraryConfiguration.categories.move)
            .onDelete(perform: deleteCategory)
        }
        Section("Archive") {
            ForEach(archivedCategories) { category in
                NavigationLink(value: category) {
                    FeedCategoryButtonLabel(category: category, font: .headline, isCompact: true)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .saturation(0)
                }
                .listRowSeparator(.hidden)
                .swipeActions(edge: .leading) {
                    Button {
                        Task {
                            try await restoreCategory(category)
                        }
                    } label: {
                        Label("Restore", systemImage: "plus")
                    }
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        Task {
                            try await deleteCategory(category)
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
                                try await restoreCategory(category)
                            }
                        } label: {
                            Label("Restore", systemImage: "plus")
                        }
                        Divider()
                        Button(role: .destructive) {
                            deleteCategory(category)
                        } label: {
                            Text("Delete")
                        }
                        .tint(.red)
                    }
                }
                //                        .id("library-sidebar-\(category.id.uuidString)")
            }
            .onDelete(perform: { deleteCategory(at: $0) })
        }
    }
    
    var body: some View {
        ScrollViewReader { scrollProxy in
            List {
                if let libraryConfiguration = viewModel.libraryConfiguration {
                    sections(libraryConfiguration: libraryConfiguration)
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
            let category = LibraryDataManager.shared.createEmptyCategory(addToLibrary: true)
            Task { @MainActor in
                scrollProxy.scrollTo("library-sidebar-\(category.id.uuidString)")
            }
        } label: {
            Label("Add User Category", systemImage: "plus.circle")
                .labelStyle(.titleAndIcon)
        }
    }
}