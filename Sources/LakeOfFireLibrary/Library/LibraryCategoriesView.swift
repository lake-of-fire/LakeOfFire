import SwiftUI
import UniformTypeIdentifiers
import FilePicker
import RealmSwift
import RealmSwiftGaps
import SwiftUtilities
import LakeOfFireCore
import LakeOfFireAdblock
import LakeOfFireContent

@available(iOS 16.0, macOS 13.0, *)
struct LibraryCategoriesView: View {
    @Binding var contentRoute: ContentPaneRoute?
    
    @StateObject private var viewModel = LibraryCategoriesViewModel()
    
    @EnvironmentObject private var libraryManagerViewModel: LibraryManagerViewModel
    
    @AppStorage("appTint") private var appTint: Color = .accentColor
    
#if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
#endif
    
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
    
    @ViewBuilder var userLibraryView: some View {
        if let categories = viewModel.userLibraryCategories {
            ForEach(Array(categories), id: \.id) { category in
                NavigationLink(value: ContentPaneRoute.contentCategory(category.id)) {
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
    }
    
    @ViewBuilder var editorsPicksLibraryView: some View {
        if let categories = viewModel.editorsPicksLibraryCategories {
            ForEach(Array(categories), id: \.id) { category in
                NavigationLink(value: ContentPaneRoute.contentCategory(category.id)) {
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
            .onMove {
                viewModel.moveCategories(fromOffsets: $0, toOffset: $1)
            }
            .onDelete {
                viewModel.deleteCategory(at: $0)
            }
        }
    }
    
    @ViewBuilder var archiveView: some View {
        if let categories = viewModel.archivedCategories {
            ForEach(Array(categories), id: \.id) { category in
                NavigationLink(value: ContentPaneRoute.contentCategory(category.id)) {
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
        }
    }
    
    var body: some View {
        ScrollViewReader { scrollProxy in
            List(selection: $contentRoute) {
                Section(header: EmptyView(), footer: Text("Uses the OPML file format for RSS reader compatibility. User Scripts can also be shared. User Library exports exclude system-provided data.").font(.footnote).foregroundColor(.secondary)) {
                    importExportView
                }
                .labelStyle(.titleOnly)
                .accentColor(appTint)
                
                Section("Extensions") {
                    NavigationLink(value: ContentPaneRoute.userScripts, label: {
                        Label("User Scripts", systemImage: "wrench.and.screwdriver")
                    })
                }
                
                Section("Library") {
                    userLibraryView
                }
                
                Section("Editor's Picks") {
                    editorsPicksLibraryView
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
                    if viewModel.userLibraryCategories?.contains(where: { $0.isUserEditable }) ?? false {
                        EditButton()
                    }
                }
                ToolbarItem/*Group*/(placement: addButtonPlacement) {
                    addCategoryButton(scrollProxy: scrollProxy)
                    //                    Spacer(minLength: 0)
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
                try await { @MainActor in
                    let realm = try await Realm.open(configuration: LibraryDataManager.realmConfiguration)
                    guard let category = realm.resolve(ref) else { return }
                    categoryIDNeedsScrollTo = category.id.uuidString
                    try await Task.sleep(nanoseconds: 100_000_000)
                    //                    libraryManagerViewModel.navigationPath.removeLast(libraryManagerViewModel.navigationPath.count)
                    contentRoute = .contentCategory(category.id)
                }()
            }
        } label: {
            Text("Add Category")
        }
        .modifier {
            if #available(iOS 26, macOS 26, *) {
                $0
            } else {
                $0.buttonStyle(.borderless)
            }
        }
        .onChange(of: categoryIDNeedsScrollTo) { categoryIDNeedsScrollTo in
            guard let categoryIDNeedsScrollTo = categoryIDNeedsScrollTo else { return }
            Task { @MainActor in // Untested whether this is needed
                scrollProxy.scrollTo("library-sidebar-\(categoryIDNeedsScrollTo)")
                self.categoryIDNeedsScrollTo = nil
            }
        }
    }
}
