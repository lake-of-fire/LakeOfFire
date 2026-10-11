import SwiftUI
import Combine
import RealmSwift
import RealmSwiftGaps
import SwiftUtilities
import SwiftUIWebView
import LakeOfFireCore
import LakeOfFireAdblock
import LakeOfFireContent
import LakeOfFireReader

let libraryScriptFormSectionsQueue = DispatchQueue(label: "LibraryScriptFormSections")

@MainActor
class LibraryScriptFormSectionsViewModel: ObservableObject {
    var script: UserScript? {
        didSet {
            guard let script else { return }
            let scriptRef = ThreadSafeReference(to: script)
            Task { @RealmBackgroundActor [weak self] in
                guard let self else { return }
                let realm = try await RealmBackgroundActor.shared.cachedRealm(for: LibraryDataManager.realmConfiguration)
                guard let script = realm.resolve(scriptRef) else { return }
                objectNotificationToken = script
                    .observe { [weak self] change in
                        switch change {
                        case .change(_, _), .deleted:
                            Task { @MainActor [weak self] in
                                self?.refresh()
                            }
                        case .error(let error):
                            print("An error occurred: \(error)")
                        }
                    }
                await refresh()
            }
        }
    }
    
    @Published var allowedDomainIDs: [UUID]? = nil

    @Published var scriptTitle = ""
    @Published var scriptText = ""
    @Published var scriptEnabled = false
    @Published var scriptInjectAtStart = false
    @Published var scriptMainFrameOnly = true
    @Published var scriptSandboxed = false
    @Published var scriptPreviewURL = ""
    
    var cancellables = Set<AnyCancellable>()
    @RealmBackgroundActor private var objectNotificationToken: NotificationToken?
    
    init() {
        $scriptTitle
            .removeDuplicates()
            .debounceLeadingTrailing(for: .seconds(0.35), scheduler: DispatchQueue.main)
            .sink { @MainActor [weak self] scriptTitle in
                guard let self = self, let script = script else { return }
                let scriptRef = ThreadSafeReference(to: script)
                Task.detached {
                    try await Realm.asyncWrite(scriptRef, configuration: LibraryDataManager.realmConfiguration) { _, script in
                        guard script.title != scriptTitle else { return }
                        script.title = scriptTitle
                        script.refreshChangeMetadata(explicitlyModified: true)
                    }
                }
            }
            .store(in: &cancellables)
        $scriptText
            .removeDuplicates()
            .debounceLeadingTrailing(for: .seconds(0.35), scheduler: DispatchQueue.main)
            .sink { @MainActor [weak self] scriptText in
                guard let self = self, let script = script else { return }
                let scriptRef = ThreadSafeReference(to: script)
                Task.detached {
                    try await Realm.asyncWrite(scriptRef, configuration: LibraryDataManager.realmConfiguration) { _, script in
                        guard script.script != scriptText else { return }
                        script.script = scriptText
                        script.refreshChangeMetadata(explicitlyModified: true)
                    }
                }
            }
            .store(in: &cancellables)
        $scriptEnabled
            .removeDuplicates()
            .sink { @MainActor [weak self] scriptEnabled in
                guard let self = self, let script = script else { return }
                let scriptRef = ThreadSafeReference(to: script)
                Task.detached {
                    try await Realm.asyncWrite(scriptRef, configuration: LibraryDataManager.realmConfiguration) { _, script in
                        let isArchived = !scriptEnabled
                        guard script.isArchived != isArchived else { return }
                        script.isArchived = isArchived
                        script.refreshChangeMetadata(explicitlyModified: true)
                    }
                }
            }
            .store(in: &cancellables)
        $scriptInjectAtStart
            .removeDuplicates()
            .sink { @MainActor [weak self] scriptInjectAtStart in
                guard let self = self, let script = script else { return }
                let scriptRef = ThreadSafeReference(to: script)
                Task.detached {
                    try await Realm.asyncWrite(scriptRef, configuration: LibraryDataManager.realmConfiguration) { _, script in
                        guard script.injectAtStart != scriptInjectAtStart else { return }
                        script.injectAtStart = scriptInjectAtStart
                        script.refreshChangeMetadata(explicitlyModified: true)
                    }
                }
            }
            .store(in: &cancellables)
        $scriptMainFrameOnly
            .removeDuplicates()
            .sink { @MainActor [weak self] scriptMainFrameOnly in
                guard let self = self, let script = script else { return }
                let scriptRef = ThreadSafeReference(to: script)
                Task.detached {
                    try await Realm.asyncWrite(scriptRef, configuration: LibraryDataManager.realmConfiguration) { _, script in
                        guard script.mainFrameOnly != scriptMainFrameOnly else { return }
                        script.mainFrameOnly = scriptMainFrameOnly
                        script.refreshChangeMetadata(explicitlyModified: true)
                    }
                }
            }
            .store(in: &cancellables)
        $scriptSandboxed
            .removeDuplicates()
            .sink { @MainActor [weak self] scriptSandboxed in
                guard let self = self, let script = script else { return }
                let scriptRef = ThreadSafeReference(to: script)
                Task.detached {
                    try await Realm.asyncWrite(scriptRef, configuration: LibraryDataManager.realmConfiguration) { _, script in
                        guard script.sandboxed != scriptSandboxed else { return }
                        script.sandboxed = scriptSandboxed
                        script.refreshChangeMetadata(explicitlyModified: true)
                    }
                }
            }
            .store(in: &cancellables)
        $scriptPreviewURL
            .removeDuplicates()
            .debounceLeadingTrailing(for: .seconds(0.35), scheduler: DispatchQueue.main)
            .sink { @MainActor [weak self] scriptPreviewURL in
                guard let self = self, let script = script else { return }
                let scriptRef = ThreadSafeReference(to: script)
                Task.detached {
                    try await Realm.asyncWrite(scriptRef, configuration: LibraryDataManager.realmConfiguration) { _, script in
                        let previewURL = scriptPreviewURL.isEmpty ? nil : URL(string: scriptPreviewURL)
                        guard script.previewURL != previewURL else { return }
                        script.previewURL = previewURL
                        script.refreshChangeMetadata(explicitlyModified: true)
                    }
                }
            }
            .store(in: &cancellables)
    }
    
    deinit {
        Task { @RealmBackgroundActor [weak objectNotificationToken] in
            objectNotificationToken?.invalidate()
        }
    }
    
    @MainActor
    func refresh() {
        if let allowedDomainIDs = script?.allowedDomainIDs {
            self.allowedDomainIDs = Array(allowedDomainIDs)
        } else {
            allowedDomainIDs = nil
        }
        
        scriptTitle = script?.title ?? ""
        scriptText = script?.script ?? ""
        scriptEnabled = !(script?.isArchived ?? true || script?.isDeleted ?? true)
        scriptInjectAtStart = script?.injectAtStart ?? false
        scriptMainFrameOnly = script?.mainFrameOnly ?? true
        scriptSandboxed = script?.sandboxed ?? false
        scriptPreviewURL = script?.previewURL?.absoluteString ?? ""
    }
    
    @MainActor
    @discardableResult
    func onDeleteOfAllowedDomains(
        at offsets: IndexSet, displayedDomains: [UserScriptAllowedDomainEditor], owner: LibraryScriptDomainOwner,
        beforeWrite: (@RealmBackgroundActor @Sendable () async -> Void)? = nil
    ) -> Task<Void, Error> {
        let selections = offsets.compactMap {
            displayedDomains.indices.contains($0) ? displayedDomains[$0].selection : nil
        }
        return deleteAllowedDomains(selections, owner: owner, beforeWrite: beforeWrite)
    }

    @discardableResult
    func deleteAllowedDomains(
        _ selections: [LibraryScriptDomainSelection], owner: LibraryScriptDomainOwner,
        beforeWrite: (@RealmBackgroundActor @Sendable () async -> Void)? = nil
    ) -> Task<Void, Error> {
        Task { @RealmBackgroundActor in
            try await owner.write(.delete(selections), beforeWrite: beforeWrite)
        }
    }

    @discardableResult
    func addEmptyDomain(
        owner: LibraryScriptDomainOwner,
        beforeWrite: (@RealmBackgroundActor @Sendable () async -> Void)? = nil
    ) -> Task<Void, Error> {
        Task { @RealmBackgroundActor in
            try await owner.write(.add, beforeWrite: beforeWrite)
        }
    }
    
    func pastePreviewURL(strings: [String]) {
        Task { @MainActor [weak self] in
            guard let self = self, let script = script else { return }
            try await Realm.asyncWrite(ThreadSafeReference(to: script), configuration: LibraryDataManager.realmConfiguration) { _, script in
                let previewURL = URL(string: (strings.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? URL(string: "about:blank")!
                guard script.previewURL != previewURL else { return }
                script.previewURL = previewURL
                script.refreshChangeMetadata(explicitlyModified: true)
            }
        }
    }
}

@available(iOS 16.0, macOS 13, *)
struct LibraryScriptFormSections: View {
    let script: UserScript
    
    @ScaledMetric(relativeTo: .body) private var textEditorHeight = 200
    @ScaledMetric(relativeTo: .body) private var readerPreviewHeight = 350
    @ScaledMetric(relativeTo: .body) private var compactReaderPreviewHeight = 270
    
    @State private var webState = WebViewState.empty
    @StateObject private var webNavigator = WebViewNavigator()
    @StateObject private var webViewModel = ReaderViewModel(realmConfiguration: LibraryDataManager.realmConfiguration, systemScripts: [])
    @StateObject private var readerModeViewModel = ReaderViewModel(realmConfiguration: LibraryDataManager.realmConfiguration, systemScripts: [])
    
    @AppStorage("LibraryScriptFormSections.isPreviewReaderMode") private var isPreviewReaderMode = true
    @AppStorage("LibraryScriptFormSections.isWordWrapping") private var isWordWrapping = true
    
    @StateObject private var viewModel = LibraryScriptFormSectionsViewModel()
    
    //    @State var webViewUserScripts =  LibraryConfiguration.getOrCreate().activeWebViewUserScripts
    //    @State var webViewSystemScripts = LibraryConfiguration.getOrCreate().systemScripts
    
#if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
#endif
    
    private func unfrozen(_ script: UserScript) -> UserScript {
        return script.isFrozen ? script.thaw() ?? script : script
    }
    
    private var unfrozenScript: UserScript {
        return unfrozen(script)
    }
    
    private var computedReaderPreviewHeight: CGFloat {
#if os(iOS)
        if horizontalSizeClass == .compact {
            return compactReaderPreviewHeight
        }
#endif
        return readerPreviewHeight
    }
    
    var body: some View {
        if let opmlURL = script.opmlURL, LibraryConfiguration.opmlURLs.contains(opmlURL)  {
            Section("Synced") {
                Text("Manabi Reader manages this User Script for you.")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        
        Section("User Script") {
            Toggle("Enabled", isOn: $viewModel.scriptEnabled)
            
            TextField("Script Title", text: $viewModel.scriptTitle, prompt: Text("Enter user script title"))
#if os(macOS)
            LabeledContent("Execution Options") {
                Toggle("Inject At Document Start", isOn: $viewModel.scriptInjectAtStart)
                Toggle("Main Frame Only", isOn: $viewModel.scriptMainFrameOnly)
                Toggle("Sandboxed", isOn: $viewModel.scriptSandboxed)
            }
#else
            Toggle("Inject At Document Start", isOn: $viewModel.scriptInjectAtStart)
            Toggle("Main Frame Only", isOn: $viewModel.scriptMainFrameOnly)
            Toggle("Sandboxed", isOn: $viewModel.scriptSandboxed)
#endif
        }
        .disabled(!script.isUserEditable)
        
        if let opmlURL = script.opmlURL {
            Section("Synced") {
                if LibraryConfiguration.opmlURLs.contains(opmlURL) {
                    Text("Manabi Reader manages this User Script for you.")
                        .lineLimit(9001)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Synchronized with: \(opmlURL.absoluteString)")
                        .lineLimit(9001)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        Section(header: Text("Allowed Domains"), footer: Text("Top-level hostnames of domains this script is allowed to run on. No support for wildcards or subdomains. All subdomains are matched against their top-level parent domain. Leave empty for access to all domains.").font(.footnote).foregroundColor(.secondary)) {
            if let owner = LibraryScriptDomainOwner(script: script) {
                let domainEditors = (viewModel.allowedDomainIDs ?? []).compactMap {
                    UserScriptAllowedDomainEditor(script: script, domainID: $0)
                }
                ForEach(domainEditors, id: \.identity) { editor in
                    UserScriptAllowedDomainCell(editor: editor)
                        .id(editor.identity)
                        .disabled(!script.isUserEditable)
                        .deleteDisabled(!script.isUserEditable)
                        .contextMenu {
                            if script.isUserEditable {
                                Button(role: .destructive) {
                                    observeDomainChange(viewModel.deleteAllowedDomains([editor.selection], owner: owner))
                                } label: {
                                    Text("Delete")
                                }
                                .tint(.red)
                            }
                        }
                }
                .onDelete { offsets in
                    observeDomainChange(viewModel.onDeleteOfAllowedDomains(
                        at: offsets, displayedDomains: domainEditors, owner: owner
                    ))
                }

                Button {
                    observeDomainChange(viewModel.addEmptyDomain(owner: owner))
                } label: {
                    Label("Add Domain", systemImage: "plus.circle")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .disabled(!script.isUserEditable)
                if viewModel.allowedDomainIDs != nil && domainEditors.isEmpty {
                    Label("Granted access to all web domains", systemImage: "exclamationmark.triangle.fill")
                }
            }
        }
        
        Section(header: Text("JavaScript"), footer: Text("This JavaScript will run on every page load. It has access to the DOM and runs in a sandbox independent of other user and system scripts. User Script execution order is not guaranteed. Use Safari Developer Tools to inspect.").font(.footnote).foregroundColor(.secondary)) {
            CodeEditor(text: $viewModel.scriptText, isWordWrapping: isWordWrapping)
                .frame(idealHeight: textEditorHeight)
            //            Toggle("Word Wrap", isOn: $isWordWrapping)
        }
        .onChange(of: script.script, debounceTime: 2) { _ in
            Task { @MainActor in
                refresh(forceRefresh: true)
            }
        }
        
        Section {
            HStack {
                TextField("Preview URL", text: $viewModel.scriptPreviewURL, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                PasteButton(payloadType: String.self) { strings in
                    viewModel.pastePreviewURL(strings: strings)
                }
                Button {
                    refresh(forceRefresh: true)
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .labelStyle(.iconOnly)
            }
            if script.previewURL != nil {
                Toggle("Reader Mode", isOn: $isPreviewReaderMode)
                /*
                 GroupBox("Reader Mode") {
                 if !readerModeViewModel.content.isReaderModeAvailable {
                 Text("Reader Mode currently unavailable for this URL.")
                 .foregroundColor(.secondary)
                 .padding(5)
                 }
                 Reader(readerViewModel: readerModeViewModel, state: $readerState, action: $readerAction, wordTrackingStats: .constant(nil), isPresentingReaderSettings: .constant(false), forceReaderModeWhenAvailable: true)
                 .frame(width: readerModeViewModel.content.isReaderModeAvailable ? computedReaderPreviewHeight : 0, height: readerModeViewModel.content.isReaderModeAvailable ? nil : 0)
                 .clipShape(RoundedRectangle(cornerRadius: 8))
                 .onAppear {
                 refresh()
                 }
                 }
                 GroupBox("Web Original") {
                 Reader(readerViewModel: webViewModel, state: $webState, action: $webAction, wordTrackingStats: .constant(nil), isPresentingReaderSettings: .constant(false))
                 .clipShape(RoundedRectangle(cornerRadius: 8))
                 .frame(idealHeight: readerPreviewHeight)
                 }*/
                Group {
                    if isPreviewReaderMode {
                        Reader(
                            forceReaderModeWhenAvailable: false,
                            /*persistentWebViewID: "library-script-preview-\(script.id.uuidString)",*/
                            bounces: false)
                        .environmentObject(readerModeViewModel)
                    } else {
                        WebView(
                            config: WebViewConfig(userScripts: script.getWebViewUserScript().map { [$0] } ?? []),
                            navigator: webNavigator,
                            state: $webState,
                            bounces: false)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .frame(idealHeight: readerPreviewHeight)
                .task {
                    refresh()
                }
                //                .onAppear {
                //                    refresh()
                //                }
            } else {
                Text("Enter URL to view preview.")
                    .foregroundColor(.secondary)
            }
        }
        .listRowSeparator(.hidden, edges: .all)
        .onChange(of: script.previewURL, debounceTime: 0.5) { url in
            guard let url = url else { return }
            refresh(url: url)
        }
        .task(id: script.id) { @MainActor in
            viewModel.script = script
        }
    }
    
    private func observeDomainChange(_ task: Task<Void, Error>) {
        Task { @MainActor in
            do { try await task.value }
            catch { print("# LIBRARYSCRIPTDOMAIN list change failed: \(error)") }
        }
    }

    private func refresh(url: URL? = nil, forceRefresh: Bool = false) {
        Task { @MainActor in
            guard let url = url ?? script.previewURL else { return }
            if webState.pageURL != url || forceRefresh {
                webNavigator.load(URLRequest(url: url))
            }
            if readerModeViewModel.state.pageURL != url || forceRefresh {
                readerModeViewModel.navigator?.load(URLRequest(url: url))
            }
        }
    }
}
