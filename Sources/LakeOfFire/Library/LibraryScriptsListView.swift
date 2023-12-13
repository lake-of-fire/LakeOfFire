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
    
    func list(libraryConfiguration: LibraryConfiguration) -> some View {
        Group {
            List(selection: $selectedScript) {
                ForEach(viewModel.userScripts) { script in
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
                .onMove(perform: $libraryConfiguration.userScripts.move)
                .onDelete(perform: deleteScript)
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
        ScrollViewReader { scrollProxy in
            if let libraryConfiguration = viewModel.libraryConfiguration {
                list(libraryConfiguration: libraryConfiguration)
            }
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
    
    func deleteScript(_ script: UserScript) async throws {
        guard let libraryConfiguration = viewModel.libraryConfiguration else { return }
        
        if !script.isUserEditable || (script.isArchived && script.opmlURL != nil) {
            return
        }
        
        let scriptID = script.id
        try await Realm.asyncWrite(libraryConfiguration) { realm, libraryConfiguration in
            guard let script = realm?.object(ofType: UserScript.self, forPrimaryKey: scriptID) else { return }
            if let idx = libraryConfiguration.userScripts.firstIndex(where: { $0.id == scriptID }) {
                libraryConfiguration.userScripts.remove(at: idx)
            }
        }
        
        try await Realm.asyncWrite(script) { _, script in
            if script.isArchived, let opmlURL = script.opmlURL, !LibraryConfiguration.opmlURLs.contains(opmlURL) {
                script.isDeleted = true
            } else if script.isArchived && script.opmlURL == nil {
                script.isDeleted = true
            } else if !script.isArchived {
                script.isArchived = true
            }
        }
    }
    
    func deleteScript(at offsets: IndexSet) {
        for offset in offsets {
            let script = libraryConfiguration.userScripts[offset]
            guard script.isUserEditable else { continue }
            deleteScript(script)
        }
    }
    
    func restoreScript(_ script: UserScript) {
        guard script.isUserEditable else { return }
        safeWrite(script) { _, script in
            script.isArchived = false
        }
        safeWrite(libraryConfiguration) { realm, libraryConfiguration in
            guard let script = realm?.object(ofType: UserScript.self, forPrimaryKey: script.id) else { return }
            if !libraryConfiguration.userScripts.contains(script) {
                libraryConfiguration.userScripts.append(script)
            }
        }
    }
}
