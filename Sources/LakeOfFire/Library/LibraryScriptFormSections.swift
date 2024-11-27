import SwiftUI
import Combine
import RealmSwift
import RealmSwiftGaps
import SwiftUIWebView

@MainActor
class LibraryScriptFormSectionsViewModel: ObservableObject {
    var script: UserScript? {
        didSet {
            guard let script = script else { return }
            let scriptRef = ThreadSafeReference(to: script)
            Task { @RealmBackgroundActor [weak self] in
                guard let self else { return }
                guard let realm = await RealmBackgroundActor.shared.cachedRealm(for: LibraryDataManager.realmConfiguration) else { return }
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
            .debounce(for: .seconds(0.35), scheduler: DispatchQueue.main)
            .sink { [weak self] scriptTitle in
                guard let self = self, let script = script else { return }
                let scriptRef = ThreadSafeReference(to: script)
                Task.detached {
                    try await Realm.asyncWrite(scriptRef, configuration: LibraryDataManager.realmConfiguration) { _, script in
                        script.title = scriptTitle
                    }
                }
            }
            .store(in: &cancellables)
        $scriptText
            .removeDuplicates()
            .debounce(for: .seconds(0.35), scheduler: DispatchQueue.main)
            .sink { [weak self] scriptText in
                guard let self = self, let script = script else { return }
                let scriptRef = ThreadSafeReference(to: script)
                Task.detached {
                    try await Realm.asyncWrite(scriptRef, configuration: LibraryDataManager.realmConfiguration) { _, script in
                        script.script = scriptText
                    }
                }
            }
            .store(in: &cancellables)
        $scriptEnabled
            .removeDuplicates()
            .sink { [weak self] scriptEnabled in
                guard let self = self, let script = script else { return }
                let scriptRef = ThreadSafeReference(to: script)
                Task.detached {
                    try await Realm.asyncWrite(scriptRef, configuration: LibraryDataManager.realmConfiguration) { _, script in
                        script.isArchived = !scriptEnabled
                    }
                }
            }
            .store(in: &cancellables)
        $scriptInjectAtStart
            .removeDuplicates()
            .sink { [weak self] scriptInjectAtStart in
                guard let self = self, let script = script else { return }
                let scriptRef = ThreadSafeReference(to: script)
                Task.detached {
                    try await Realm.asyncWrite(scriptRef, configuration: LibraryDataManager.realmConfiguration) { _, script in
                        script.injectAtStart = scriptInjectAtStart
                    }
                }
            }
            .store(in: &cancellables)
        $scriptMainFrameOnly
            .removeDuplicates()
            .sink { [weak self] scriptMainFrameOnly in
                guard let self = self, let script = script else { return }
                let scriptRef = ThreadSafeReference(to: script)
                Task.detached {
                    try await Realm.asyncWrite(scriptRef, configuration: LibraryDataManager.realmConfiguration) { _, script in
                        script.mainFrameOnly = scriptMainFrameOnly
                    }
                }
            }
            .store(in: &cancellables)
        $scriptSandboxed
            .removeDuplicates()
            .sink { [weak self] scriptSandboxed in
                guard let self = self, let script = script else { return }
                let scriptRef = ThreadSafeReference(to: script)
                Task.detached {
                    try await Realm.asyncWrite(scriptRef, configuration: LibraryDataManager.realmConfiguration) { _, script in
                        script.sandboxed = scriptSandboxed
                    }
                }
            }
            .store(in: &cancellables)
        $scriptPreviewURL
            .removeDuplicates()
            .debounce(for: .seconds(0.35), scheduler: DispatchQueue.main)
            .sink { [weak self] scriptPreviewURL in
                guard let self = self, let script = script else { return }
                let scriptRef = ThreadSafeReference(to: script)
                Task.detached {
                    try await Realm.asyncWrite(scriptRef, configuration: LibraryDataManager.realmConfiguration) { _, script in
                        if scriptPreviewURL.isEmpty {
                            script.previewURL = nil
                        } else {
                            script.previewURL = URL(string: scriptPreviewURL)
                        }
                    }
                }
            }
            .store(in: &cancellables)
    }
    
    deinit {
        Task { @RealmBackgroundActor [weak self] in
            self?.objectNotificationToken?.invalidate()
        }
    }
    
    @MainActor
    func refresh() {
        scriptTitle = script?.title ?? ""
        scriptText = script?.script ?? ""
        scriptEnabled = !(script?.isArchived ?? true || script?.isDeleted ?? true)
        scriptInjectAtStart = script?.injectAtStart ?? false
        scriptMainFrameOnly = script?.mainFrameOnly ?? true
        scriptSandboxed = script?.sandboxed ?? false
        scriptPreviewURL = script?.previewURL?.absoluteString ?? ""
    }
    
    @MainActor
    func onDeleteOfAllowedDomains(at offsets: IndexSet) {
        Task { @MainActor [weak self] in
            guard let self = self, let script = script else { return }
            try await Realm.asyncWrite(ThreadSafeReference(to: script), configuration: LibraryDataManager.realmConfiguration) { _, script in
                script.allowedDomains.remove(atOffsets: offsets)
            }
        }
    }
    
    func addEmptyDomain() {
        Task { @MainActor [weak self] in
            guard let self = self, let script = script else { return }
            try await Realm.asyncWrite(ThreadSafeReference(to: script), configuration: LibraryDataManager.realmConfiguration) { _, script in
                script.allowedDomains.append(UserScriptAllowedDomain())
            }
        }
    }
    
    func pastePreviewURL(strings: [String]) {
        Task { @MainActor [weak self] in
            guard let self = self, let script = script else { return }
            try await Realm.asyncWrite(ThreadSafeReference(to: script), configuration: LibraryDataManager.realmConfiguration) { _, script in
                script.previewURL = URL(string: (strings.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? URL(string: "about:blank")!
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
    
    func userScriptSection(script: UserScript) -> some View {
        Group {
        }
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
            ForEach(script.allowedDomains.where({ $0.isDeleted == false })) { (domain: UserScriptAllowedDomain) in
                let domain = domain.isFrozen ? domain.thaw() ?? domain : domain
                UserScriptAllowedDomainCell(domain: domain)
                    .disabled(!script.isUserEditable)
                    .deleteDisabled(!script.isUserEditable)
                    .contextMenu {
                        if script.isUserEditable {
                            Button(role: .destructive) {
                                Task { @MainActor in
                                    try await Realm.asyncWrite(ThreadSafeReference(to: script), configuration: LibraryDataManager.realmConfiguration) { _, script in
                                        if let idx = script.allowedDomains.index(of: domain) {
                                            script.allowedDomains.remove(at: idx)
                                        }
                                    }
                                }
                            } label: {
                                Text("Delete")
                            }
                            .tint(.red)
                        }
                    }
            }
            .onDelete { offsets in
                viewModel.onDeleteOfAllowedDomains(at: offsets)
            }
            
            Button {
                viewModel.addEmptyDomain()
            } label: {
                Label("Add Domain", systemImage: "plus.circle")
                    .fixedSize(horizontal: false, vertical: true)
            }
            if script.allowedDomains.isEmpty {
                Label("Granted access to all web domains", systemImage: "exclamationmark.triangle.fill")
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
                            config: WebViewConfig(userScripts: [script.webViewUserScript]),
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
