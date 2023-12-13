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
                guard let self = self else { return }
                let realm = try await Realm(configuration: LibraryDataManager.realmConfiguration, actor: RealmBackgroundActor.shared)
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
            }
        }
    }
    
    @State private var scriptTitle = ""
    @State private var scriptText = ""
    @State private var scriptEnabled = false
    
    @RealmBackgroundActor private var objectNotificationToken: NotificationToken?
    
    init() {
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
    }
}

@available(iOS 16.0, macOS 13, *)
struct LibraryScriptFormSections: View {
    let script: UserScript
    
    @ScaledMetric(relativeTo: .body) private var textEditorHeight = 200
    @ScaledMetric(relativeTo: .body) private var readerPreviewHeight = 350
    @ScaledMetric(relativeTo: .body) private var compactReaderPreviewHeight = 270
    
    //    @State private var readerContent: (any ReaderContentModel) = ReaderContentLoader.unsavedHome
    @State private var webState = WebViewState.empty
    @State private var webNavigator = WebViewNavigator()
    @StateObject private var webViewModel = ReaderViewModel(realmConfiguration: LibraryDataManager.realmConfiguration, systemScripts: [])
    @StateObject private var readerModeViewModel = ReaderViewModel(realmConfiguration: LibraryDataManager.realmConfiguration, systemScripts: [])
    
    @AppStorage("LibraryScriptFormSections.isPreviewReaderMode") private var isPreviewReaderMode = true
    @AppStorage("LibraryScriptFormSections.isWordWrapping") private var isWordWrapping = true
    
    @StateObject private var viewModel = LibraryScriptFormSectionsViewModel()
    
    //    @State var webViewUserScripts =  LibraryConfiguration.shared.activeWebViewUserScripts
    //    @State var webViewSystemScripts = LibraryConfiguration.shared.systemScripts
    
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
            Section("Synchronized") {
                Text("Manabi Reader manages this User Script for you.")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        
        Section("User Script") {
            Toggle("Enabled", isOn: $viewModel.scriptEnabled)
                .task { @MainActor in
                    scriptEnabled = !script.isArchived
                }
                .onChange(of: scriptEnabled) { scriptEnabled in
                    Task {
                        try await Realm.asyncWrite(script) { _, script in
                            script.isArchived = !scriptEnabled
                        }
                    }
                }
            
            TextField("Script Title", text: $scriptTitle, prompt: Text("Enter user script title"))
#if os(macOS)
            LabeledContent("Execution Options") {
                Toggle("Inject At Document Start", isOn: $script.injectAtStart)
                Toggle("Main Frame Only", isOn: $script.mainFrameOnly)
                Toggle("Sandboxed", isOn: $script.sandboxed)
            }
#else
            Toggle("Inject At Document Start", isOn: $script.injectAtStart)
            Toggle("Main Frame Only", isOn: $script.mainFrameOnly)
            Toggle("Sandboxed", isOn: $script.sandboxed)
#endif
        }
        .disabled(!script.isUserEditable)
        if let opmlURL = script.opmlURL {
            Section("Synchronization") {
                if LibraryConfiguration.opmlURLs.contains(opmlURL) {
                    Text("Manabi Reader manages and actively improves this user script for you.")
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Synchronized with: \(opmlURL.absoluteString)")
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
                                safeWrite(script) { _, script in
                                    if let idx = script.allowedDomains.index(of: domain) {
                                        script.allowedDomains.remove(at: idx)
                                    }
                                }
                            } label: {
                                Text("Delete")
                            }
                            .tint(.red)
                        }
                    }
            }
            .onDelete(perform: $script.allowedDomains.remove)
            
            Button {
                $script.allowedDomains.append(UserScriptAllowedDomain())
            } label: {
                Label("Add Domain", systemImage: "plus.circle")
                    .fixedSize(horizontal: false, vertical: true)
            }
            if script.allowedDomains.isEmpty {
                Label("Granted access to all web domains", systemImage: "exclamationmark.triangle.fill")
            }
        }
        
        Section(header: Text("JavaScript"), footer: Text("This JavaScript will run on every page load. It has access to the DOM and runs in a sandbox independent of other user and system scripts. User Script execution order is not guaranteed. Use Safari Developer Tools to inspect.").font(.footnote).foregroundColor(.secondary)) {
            CodeEditor(text: $scriptText, isWordWrapping: isWordWrapping)
                .frame(idealHeight: textEditorHeight)
            //            Toggle("Word Wrap", isOn: $isWordWrapping)
        }
        .task { @MainActor in
                scriptTitle = script.title
                scriptText = script.script
        }
        .onChange(of: scriptTitle, debounceTime: 0.1) { text in
            Task.detached {
                await safeWrite(script) { _, script in
                    script.title = text
                }
            }
        }
        .onChange(of: scriptText, debounceTime: 0.75) { scriptText in
            Task.detached {
                await safeWrite(script) { _, script in
                    script.script = scriptText
                }
            }
        }
        .onChange(of: script.script, debounceTime: 1.5) { _ in
            Task { @MainActor in
                refresh(forceRefresh: true)
            }
        }
        
        Section {
            HStack {
                TextField("Preview URL", text: Binding(
                    get: { script.previewURL?.absoluteString ?? "" },
                    set: { url in
                        guard script.previewURL?.absoluteString != url else { return }
                        safeWrite(script) { _, script in
                            script.previewURL = URL(string: url)
                        }
                    }), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                PasteButton(payloadType: String.self) { strings in
                    Task { @MainActor in
                        safeWrite(script) { _, script in
                            script.previewURL = URL(string: (strings.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? URL(string: "about:blank")!
                        }
                    }
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
                            readerViewModel: readerModeViewModel,
                            forceReaderModeWhenAvailable: false,
                            /*persistentWebViewID: "library-script-preview-\(script.id.uuidString)",*/
                            bounces: false)
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
                readerModeViewModel.navigator.load(URLRequest(url: url))
            }
        }
    }
}
