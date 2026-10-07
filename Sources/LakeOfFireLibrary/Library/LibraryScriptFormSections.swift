import LakeOfFireWeb
import SwiftUI
import LakeOfFireFiles
import LakeOfFireContentUI
import LakeOfFireReader
import LakeOfFireContent
import LakeOfFireCore
import Combine
import RealmSwift
import RealmSwiftGaps
import SwiftUIWebView

let libraryScriptFormSectionsQueue = DispatchQueue(label: "LibraryScriptFormSections")

private enum LibraryScriptFieldEdit: Equatable, Sendable {
    case title(String)
    case text(String)
    case enabled(Bool)
    case injectAtStart(Bool)
    case mainFrameOnly(Bool)
    case sandboxed(Bool)
    case previewURL(String)

    var fieldIdentifier: Int {
        switch self {
        case .title: return 0
        case .text: return 1
        case .enabled: return 2
        case .injectAtStart: return 3
        case .mainFrameOnly: return 4
        case .sandboxed: return 5
        case .previewURL: return 6
        }
    }

    func apply(to script: UserScript) -> Bool {
        switch self {
        case .title(let value):
            guard script.title != value else { return false }
            script.title = value
        case .text(let value):
            guard script.script != value else { return false }
            script.script = value
        case .enabled(let value):
            guard script.isArchived != !value else { return false }
            script.isArchived = !value
        case .injectAtStart(let value):
            guard script.injectAtStart != value else { return false }
            script.injectAtStart = value
        case .mainFrameOnly(let value):
            guard script.mainFrameOnly != value else { return false }
            script.mainFrameOnly = value
        case .sandboxed(let value):
            guard script.sandboxed != value else { return false }
            script.sandboxed = value
        case .previewURL(let value):
            let url = value.isEmpty ? nil : URL(string: value)
            guard script.previewURL != url else { return false }
            script.previewURL = url
        }
        return true
    }
}

private struct LibraryScriptFieldCommand: Sendable {
    let scriptID: UUID
    let realmConfiguration: Realm.Configuration
    let edit: LibraryScriptFieldEdit
    let sequence: UInt64
    let writeOrdering: LibraryEditorWriteOrdering

    @RealmBackgroundActor
    func write() async throws {
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: realmConfiguration)
        try await realm.asyncWritePreservingOwnership {
            guard let script = realm.object(ofType: UserScript.self, forPrimaryKey: scriptID),
                  !script.isDeleted, script.isUserEditable,
                  writeOrdering.admits(recordID: scriptID, field: edit.fieldIdentifier, sequence: sequence),
                  edit.apply(to: script) else { return }
            script.refreshChangeMetadata(explicitlyModified: true)
        }
    }
}

@MainActor
class LibraryScriptFormSectionsViewModel: ObservableObject {
    let realmConfiguration: Realm.Configuration
    private let observesRealm: Bool
    private var isRefreshing = false
    private var pendingFieldCommands: [Int: LibraryScriptFieldCommand] = [:]
    private let writeOrdering: LibraryEditorWriteOrdering
    private var scriptObservationGeneration: UInt64 = 0
    @RealmBackgroundActor private var installedScriptObservationGeneration: UInt64 = 0
    var script: UserScript? {
        willSet {
            finishEditing()
            pendingFieldCommands.removeAll()
        }
        didSet {
            scriptObservationGeneration &+= 1
            let generation = scriptObservationGeneration
            refresh()
            guard observesRealm, let script else { return }
            let scriptID = script.id
            Task { @RealmBackgroundActor [weak self] in
                guard let self else { return }
                let realm = try await RealmBackgroundActor.shared.cachedRealm(for: realmConfiguration)
                guard await MainActor.run(body: {
                    self.scriptObservationGeneration == generation && self.script?.id == scriptID
                }), generation >= installedScriptObservationGeneration,
                      let script = realm.object(ofType: UserScript.self, forPrimaryKey: scriptID) else { return }
                installedScriptObservationGeneration = generation
                objectNotificationToken?.invalidate()
                objectNotificationToken = script
                    .observe { [weak self] change in
                        switch change {
                        case .change(_, _), .deleted:
                            Task { @MainActor [weak self] in
                                guard let self, self.scriptObservationGeneration == generation,
                                      self.script?.id == scriptID else { return }
                                self.refresh()
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
    
    init(
        realmConfiguration: Realm.Configuration = LibraryDataManager.realmConfiguration,
        observesRealm: Bool = true
    ) {
        self.realmConfiguration = realmConfiguration
        writeOrdering = .shared(configuration: realmConfiguration, recordKind: "script")
        self.observesRealm = observesRealm
        observe($scriptTitle, edit: LibraryScriptFieldEdit.title, debounced: true)
        observe($scriptText, edit: LibraryScriptFieldEdit.text, debounced: true)
        observe($scriptEnabled, edit: LibraryScriptFieldEdit.enabled)
        observe($scriptInjectAtStart, edit: LibraryScriptFieldEdit.injectAtStart)
        observe($scriptMainFrameOnly, edit: LibraryScriptFieldEdit.mainFrameOnly)
        observe($scriptSandboxed, edit: LibraryScriptFieldEdit.sandboxed)
        observe($scriptPreviewURL, edit: LibraryScriptFieldEdit.previewURL, debounced: true)
    }

    private func observe<Value>(
        _ publisher: Published<Value>.Publisher,
        edit: @escaping (Value) -> LibraryScriptFieldEdit,
        debounced: Bool = false
    ) {
        let commands = publisher
            .compactMap { [weak self] value -> LibraryScriptFieldCommand? in
                // @Published emits synchronously. Capture the originating record
                // before debounce, and never enqueue hydration as a user edit.
                guard let self, !self.isRefreshing, let script = self.script, !script.isInvalidated else { return nil }
                let sequence = self.writeOrdering.issueSequence()
                let command = LibraryScriptFieldCommand(
                    scriptID: script.id, realmConfiguration: self.realmConfiguration, edit: edit(value),
                    sequence: sequence, writeOrdering: self.writeOrdering
                )
                self.pendingFieldCommands[command.edit.fieldIdentifier] = command
                return command
            }
            .eraseToAnyPublisher()
        let writes = debounced
            ? commands.debounceLeadingTrailing(for: .seconds(0.35), scheduler: DispatchQueue.main)
                .eraseToAnyPublisher()
            : commands
        writes.sink { [weak self] command in self?.submit(command) }
        .store(in: &cancellables)
    }

    private func submit(_ command: LibraryScriptFieldCommand) {
        Task { @RealmBackgroundActor [weak self] in
            do { try await command.write() }
            catch { print("LibraryScriptEditor field write failed: \(error)") }
            await self?.settle(command)
        }
    }

    private func settle(_ command: LibraryScriptFieldCommand) {
        let field = command.edit.fieldIdentifier
        guard let pending = pendingFieldCommands[field],
              pending.scriptID == command.scriptID, pending.sequence == command.sequence else { return }
        pendingFieldCommands[field] = nil
        refresh()
    }

    func finishEditing() {
        for command in pendingFieldCommands.values { submit(command) }
    }

    deinit {
        let commands = Array(pendingFieldCommands.values)
        Task { @RealmBackgroundActor in
            for command in commands {
                do { try await command.write() }
                catch { print("LibraryScriptEditor retirement write failed: \(error)") }
            }
        }
        Task { @RealmBackgroundActor [weak objectNotificationToken] in
            objectNotificationToken?.invalidate()
        }
    }
    
    @MainActor
    func refresh() {
        if let script, !script.isFrozen { script.realm?.refresh() }
        guard script?.isInvalidated != true else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        if let allowedDomainIDs = script?.allowedDomainIDs {
            self.allowedDomainIDs = Array(allowedDomainIDs)
        } else {
            allowedDomainIDs = nil
        }
        
        if pendingFieldCommands[0] == nil { scriptTitle = script?.title ?? "" }
        if pendingFieldCommands[1] == nil { scriptText = script?.script ?? "" }
        if pendingFieldCommands[2] == nil { scriptEnabled = !(script?.isArchived ?? true || script?.isDeleted ?? true) }
        if pendingFieldCommands[3] == nil { scriptInjectAtStart = script?.injectAtStart ?? false }
        if pendingFieldCommands[4] == nil { scriptMainFrameOnly = script?.mainFrameOnly ?? true }
        if pendingFieldCommands[5] == nil { scriptSandboxed = script?.sandboxed ?? false }
        if pendingFieldCommands[6] == nil { scriptPreviewURL = script?.previewURL?.absoluteString ?? "" }
    }
    
    @discardableResult
    func onDeleteOfAllowedDomains(
        at offsets: IndexSet, displayedDomainIDs: [UUID], scriptID: UUID? = nil
    ) -> Task<Void, Error> {
        let domainIDs = offsets.compactMap {
            displayedDomainIDs.indices.contains($0) ? displayedDomainIDs[$0] : nil
        }
        return deleteAllowedDomains(domainIDs, scriptID: scriptID)
    }

    @discardableResult
    func deleteAllowedDomains(_ domainIDs: [UUID], scriptID: UUID? = nil) -> Task<Void, Error> {
        let scriptID = scriptID ?? script?.id
        let selectedIDs = Set(domainIDs)
        return Task { @MainActor [realmConfiguration] in
            try await Task { @RealmBackgroundActor in
                guard let scriptID, !selectedIDs.isEmpty else { return }
                let realm = try await RealmBackgroundActor.shared.cachedRealm(for: realmConfiguration)
                try await realm.asyncWritePreservingOwnership {
                    guard let script = realm.object(ofType: UserScript.self, forPrimaryKey: scriptID),
                          !script.isDeleted, script.isUserEditable else { return }
                    let removedIDs = Set(script.allowedDomainIDs).intersection(selectedIDs)
                    guard !removedIDs.isEmpty else { return }
                    let now = Date()
                    for domainID in removedIDs {
                        if let domain = realm.object(ofType: UserScriptAllowedDomain.self, forPrimaryKey: domainID),
                           !domain.isDeleted {
                            domain.isDeleted = true
                            domain.refreshChangeMetadata(explicitlyModified: true, at: now)
                        }
                    }
                    for index in script.allowedDomainIDs.indices.reversed()
                        where removedIDs.contains(script.allowedDomainIDs[index]) {
                        script.allowedDomainIDs.remove(at: index)
                    }
                    script.refreshChangeMetadata(explicitlyModified: true, at: now)
                }
            }.value
        }
    }

    @discardableResult
    func addEmptyDomain(scriptID: UUID? = nil) -> Task<Void, Error> {
        let scriptID = scriptID ?? script?.id
        return Task { @RealmBackgroundActor [realmConfiguration] in
            guard let scriptID else { return }
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: realmConfiguration)
            try await realm.asyncWritePreservingOwnership {
                guard let script = realm.object(ofType: UserScript.self, forPrimaryKey: scriptID),
                      !script.isDeleted, script.isUserEditable else { return }
                let allowedDomain = UserScriptAllowedDomain()
                let now = Date()
                realm.add(allowedDomain)
                allowedDomain.refreshChangeMetadata(explicitlyModified: true, at: now)
                script.allowedDomainIDs.append(allowedDomain.id)
                script.refreshChangeMetadata(explicitlyModified: true, at: now)
            }
        }
    }

    @discardableResult
    func pastePreviewURL(strings: [String]) -> Task<Void, Error> {
        let scriptID = script?.id
        let url = URL(
            string: (strings.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        ) ?? URL(string: "about:blank")!
        // Replace buffered field edits with this explicit current input. The
        // transaction equality check makes the later trailing write a no-op.
        scriptPreviewURL = url.absoluteString
        let sequence = writeOrdering.issueSequence()
        return Task { @RealmBackgroundActor [realmConfiguration, writeOrdering] in
            guard let scriptID else { return }
            try await LibraryScriptFieldCommand(
                scriptID: scriptID, realmConfiguration: realmConfiguration,
                edit: .previewURL(url.absoluteString), sequence: sequence, writeOrdering: writeOrdering
            ).write()
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
    @StateObject private var webViewModel: ReaderViewModel
    @StateObject private var readerModeViewModel: ReaderViewModel
    
    @AppStorage("LibraryScriptFormSections.isPreviewReaderMode") private var isPreviewReaderMode = true
    @AppStorage("LibraryScriptFormSections.isWordWrapping") private var isWordWrapping = true
    
    @StateObject private var viewModel: LibraryScriptFormSectionsViewModel

    init(script: UserScript) {
        self.script = script
        let configuration = script.realm?.configuration ?? LibraryDataManager.realmConfiguration
        _viewModel = StateObject(wrappedValue: LibraryScriptFormSectionsViewModel(
            realmConfiguration: configuration
        ))
        _webViewModel = StateObject(wrappedValue: ReaderViewModel(
            realmConfiguration: configuration, systemScripts: []
        ))
        _readerModeViewModel = StateObject(wrappedValue: ReaderViewModel(
            realmConfiguration: configuration, systemScripts: []
        ))
    }
    
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
            // TODO: Cache allowedDomains in a subview struct
            let displayedDomainIDs = viewModel.allowedDomainIDs ?? []
            let scriptID = script.id
            let realmConfiguration = viewModel.realmConfiguration
            ForEach(displayedDomainIDs, id: \.self) { (domainID: UUID) in
                UserScriptAllowedDomainCell(
                    domainID: domainID, scriptID: scriptID, realmConfiguration: realmConfiguration
                )
                    .id(LibraryRecordPresentationIdentity(
                        recordID: domainID, ownerID: scriptID, configuration: realmConfiguration
                    ))
                    .disabled(!script.isUserEditable)
                    .deleteDisabled(!script.isUserEditable)
                    .contextMenu {
                        if script.isUserEditable {
                            Button(role: .destructive) {
                                viewModel.deleteAllowedDomains([domainID], scriptID: scriptID)
                            } label: {
                                Text("Delete")
                            }
                            .tint(.red)
                        }
                    }
            }
            .onDelete { offsets in
                viewModel.onDeleteOfAllowedDomains(
                    at: offsets, displayedDomainIDs: displayedDomainIDs, scriptID: scriptID
                )
            }
            
            Button {
                viewModel.addEmptyDomain(scriptID: scriptID)
            } label: {
                Label("Add Domain", systemImage: "plus.circle")
                    .fixedSize(horizontal: false, vertical: true)
            }
            if viewModel.allowedDomainIDs?.isEmpty ?? false {
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
                            config: WebViewConfig(userScripts: [script.getWebViewUserScript()].compactMap { $0 }),
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
        .onDisappear { viewModel.finishEditing() }
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
