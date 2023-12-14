import SwiftUI
import RealmSwift
import RealmSwiftGaps

@MainActor
fileprivate class LibraryScriptsListViewModel: ObservableObject {
    @Published var libraryConfiguration: LibraryConfiguration?
    @Published var userScripts: [UserScript]? = nil
    
    @RealmBackgroundActor private var objectNotificationToken: NotificationToken?
    
    init() {
        Task.detached { @RealmBackgroundActor [weak self] in
            guard let self = self else { return }
            let libraryConfiguration = try await LibraryConfiguration.shared
            objectNotificationToken = libraryConfiguration
                .observe { [weak self] change in
                    guard let self = self else { return }
                    switch change {
                    case .change(_, _):
                        let userScripts = Array(libraryConfiguration.userScripts)
                        Task { @MainActor [weak self] in
                            self?.userScripts = userScripts
                        }
                    case .error(let error):
                        print("An error occurred: \(error)")
                    case .deleted:
                        print("The object was deleted.")
                    }
                }
            
            await Task { @MainActor in
                self.libraryConfiguration = libraryConfiguration
            }.value
        }
    }
    
    deinit {
        Task { @RealmBackgroundActor [weak self] in
            self?.objectNotificationToken?.invalidate()
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
            guard let script = realm.object(ofType: UserScript.self, forPrimaryKey: scriptID) else { return }
            if let idx = libraryConfiguration.userScripts.firstIndex(where: { $0.id == scriptID }) {
                libraryConfiguration.userScripts.remove(at: idx)
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
            guard let libraryConfiguration = libraryConfiguration else { return }
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
            try await Realm.asyncWrite(ThreadSafeReference(to: libraryConfiguration)) { _, libraryConfiguration in
                libraryConfiguration.userScripts.move(fromOffsets: fromOffsets, toOffset: toOffset)
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
    
    func list(libraryConfiguration: LibraryConfiguration, userScripts: [UserScript]) -> some View {
        ScrollViewReader { scrollProxy in
            List(selection: $selectedScript) {
                ForEach(userScripts) { script in
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
                                    if script.allowedDomains.isEmpty {
                                        Label("Granted access to all web domains", systemImage: "exclamationmark.triangle.fill")
                                    }
                                }
                            }
                        }
                        .font(.caption)
                    }
                    .tag(script)
                    //                    .listRowSeparator(.hidden)
                    .deleteDisabled(!script.isUserEditable)
                    .moveDisabled(!script.isUserEditable)
                    //                    .id("library-sidebar-\(script.id.uuidString)")
                }
//                .onMove(perform: $libraryConfiguration.userScripts.move)
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
        if let libraryConfiguration = viewModel.libraryConfiguration, let userScripts = viewModel.userScripts {
            list(libraryConfiguration: libraryConfiguration, userScripts: userScripts)
        }
    }
    
    func addScriptButton(scrollProxy: ScrollViewProxy) -> some View {
        Button {
            Task {
                let script = try await LibraryDataManager.shared.createEmptyScript(addToLibrary: true)
                await Task { @MainActor in
                    scrollProxy.scrollTo("library-sidebar-\(script.id.uuidString)")
                }.value
            }
        } label: {
            Label("Add Script", systemImage: "plus.circle")
                .labelStyle(.titleAndIcon)
        }
        .keyboardShortcut("n", modifiers: [.command])
    }
}
