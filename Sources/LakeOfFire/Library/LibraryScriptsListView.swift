import SwiftUI
import Combine
import RealmSwift
import RealmSwiftGaps
import SwiftUtilities

@MainActor
fileprivate class LibraryScriptsListViewModel: ObservableObject {
    @Published var libraryConfiguration: LibraryConfiguration?
    @Published var userScripts: [UserScript]? = nil
    
    @RealmBackgroundActor
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        Task { @RealmBackgroundActor [weak self] in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: LibraryDataManager.realmConfiguration)
            
            realm.objects(LibraryConfiguration.self)
                .collectionPublisher
                .subscribe(on: libraryDataQueue)
                .map { _ in }
                .debounceLeadingTrailing(for: .seconds(0.3), scheduler: libraryDataQueue)
                .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] _ in
                    Task { @RealmBackgroundActor [weak self] in
                        let libraryConfiguration = try await LibraryConfiguration.getConsolidatedOrCreate()
                        let libraryConfigurationID = libraryConfiguration.id
                        let userScriptIDs = Array(libraryConfiguration.getUserScripts() ?? []).map { $0.id }
                        
                        try await { @MainActor [weak self] in
                            guard let self else { return }
                            let realm = try await Realm.open(configuration: LibraryDataManager.realmConfiguration)
                            self.userScripts = userScriptIDs.compactMap { realm.object(ofType: UserScript.self, forPrimaryKey: $0) }
                            self.libraryConfiguration = realm.object(ofType: LibraryConfiguration.self, forPrimaryKey: libraryConfigurationID)
                        }()
                    }
                })
                .store(in: &cancellables)
        }
    }
    
    @MainActor
    func deleteScript(_ script: UserScript) async throws {
        guard let libraryConfiguration = libraryConfiguration else { return }
        
        if !script.isUserEditable || (script.isArchived && script.opmlURL != nil) {
            return
        }
        
        let scriptID = script.id
        try await Realm.asyncWrite(ThreadSafeReference(to: libraryConfiguration), configuration: LibraryDataManager.realmConfiguration) { realm, libraryConfiguration in
            if let idx = libraryConfiguration.userScriptIDs.firstIndex(where: { $0 == scriptID }) {
                libraryConfiguration.userScriptIDs.remove(at: idx)
                libraryConfiguration.refreshChangeMetadata(explicitlyModified: true)
            }
        }
        
        try await Realm.asyncWrite(ThreadSafeReference(to: script), configuration: LibraryDataManager.realmConfiguration) { _, script in
            if script.isArchived, let opmlURL = script.opmlURL, !LibraryConfiguration.opmlURLs.contains(opmlURL) {
                script.isDeleted = true
            } else if script.isArchived && script.opmlURL == nil {
                script.isDeleted = true
            } else if !script.isArchived {
                script.isArchived = true
            }
        }
    }
    
    #warning("TODO: add script restoration")
    //    func restoreScript(_ script: UserScript) {
//        guard script.isUserEditable else { return }
//        safeWrite(script) { _, script in
//            script.isArchived = false
//        }
//        safeWrite(libraryConfiguration) { realm, libraryConfiguration in
//            guard let script = realm?.object(ofType: UserScript.self, forPrimaryKey: script.id) else { return }
//            if !libraryConfiguration.userScripts.contains(script) {
//                libraryConfiguration.userScripts.append(script)
//            }
//        }
//    }
    
    @MainActor
    func deleteScript(at offsets: IndexSet) {
        Task { @MainActor in
            for offset in offsets {
                guard let script = userScripts?[offset] else { return }
                guard script.isUserEditable else { continue }
                try await deleteScript(script)
            }
        }
    }
    
    @MainActor
    func moveScripts(fromOffsets: IndexSet, toOffset: Int) {
        Task { @MainActor in
            guard let libraryConfiguration = libraryConfiguration else { return }
            try await Realm.asyncWrite(ThreadSafeReference(to: libraryConfiguration), configuration: LibraryDataManager.realmConfiguration) { _, libraryConfiguration in
                libraryConfiguration.userScriptIDs.move(fromOffsets: fromOffsets, toOffset: toOffset)
                libraryConfiguration.refreshChangeMetadata(explicitlyModified: true)
            }
        }
    }
}

@available(iOS 16.0, macOS 13.0, *)
struct LibraryScriptsListView: View {
    @Binding var selectedScript: UserScript?
    
#if os(iOS)
    @ScaledMetric(relativeTo: .largeTitle) private var scaledCategoryHeight: CGFloat = 50
#else
    @ScaledMetric(relativeTo: .largeTitle) private var scaledCategoryHeight: CGFloat = 32
#endif
    
    @StateObject private var viewModel = LibraryScriptsListViewModel()
    
    func unfrozen(_ category: FeedCategory) -> FeedCategory {
        return category.isFrozen ? category.thaw() ?? category : category
    }
    
    var addScriptButtonPlacement: ToolbarItemPlacement {
#if os(iOS)
        return .bottomBar
#else
        return .automatic
#endif
    }
    
    @ViewBuilder func list(libraryConfiguration: LibraryConfiguration, userScripts: [UserScript]) -> some View {
        ScrollViewReader { scrollProxy in
            List {
                ForEach(userScripts) { script in
                    NavigationLink(value: script) {
                        VStack(alignment: .leading) {
                            Group {
                                if script.title.isEmpty {
                                    Text("Untitled Script")
                                        .foregroundColor(.secondary)
                                } else {
                                    Text(script.title)
                                }
                            }
                            .foregroundColor(script.isArchived ? .secondary : .primary)
                            Group {
                                if script.isArchived {
                                    Text("Disabled")
                                        .foregroundColor(.secondary)
                                } else {
                                    if let opmlURL = script.opmlURL, LibraryConfiguration.opmlURLs.contains(opmlURL) {
                                        Text("Official Manabi Reader system script")
                                            .bold()
                                    } else {
                                        if script.allowedDomainIDs.isEmpty {
                                            Label("Granted access to all web domains", systemImage: "exclamationmark.triangle.fill")
                                        }
                                    }
                                }
                            }
                            .font(.caption)
                        }
                    }
                    //                    .listRowSeparator(.hidden)
                    .deleteDisabled(!script.isUserEditable)
                    .moveDisabled(!script.isUserEditable)
                    //                    .id("library-sidebar-\(script.id.uuidString)")
                }
                .onMove {
                    viewModel.moveScripts(fromOffsets: $0, toOffset: $1)
                }
                .onDelete {
                    viewModel.deleteScript(at: $0)
                }
            }
#if os(iOS)
            .listStyle(.insetGrouped)
#endif
#if os(macOS)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 0) {
                    addScriptButton(scrollProxy: scrollProxy)
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
                ToolbarItem(placement: addScriptButtonPlacement) {
                    addScriptButton(scrollProxy: scrollProxy)
                }
            }
#endif
        }
    }
    
    var body: some View {
//        Text("Hm \(viewModel.userScripts?.debugDescription ?? "-") \(viewModel.libraryConfiguration?.debugDescription ?? "-")")
        if let libraryConfiguration = viewModel.libraryConfiguration, let userScripts = viewModel.userScripts {
            list(libraryConfiguration: libraryConfiguration, userScripts: userScripts)
        }
    }
    
    func addScriptButton(scrollProxy: ScrollViewProxy) -> some View {
        Button {
            Task { @RealmBackgroundActor in
                let script = try await LibraryDataManager.shared.createEmptyScript(addToLibrary: true)
                let scriptID = script.id
                await Task { @MainActor in
                    scrollProxy.scrollTo("library-sidebar-\(scriptID.uuidString)")
                }.value
            }
        } label: {
            Label("Add Script", systemImage: "plus.circle")
                .bold()
        }
        .labelStyle(.titleAndIcon)
        .keyboardShortcut("n", modifiers: [.command])
    }
}
