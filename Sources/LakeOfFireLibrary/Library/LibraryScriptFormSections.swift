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
    let realmConfiguration: Realm.Configuration
    private let observesRealm: Bool
    private let retirementDidFinish: (@RealmBackgroundActor @Sendable () -> Void)?
    private var isRefreshing = false
    private var pendingFieldCommands: [LibraryScriptField: LibraryScriptFieldCommand] = [:]
    private var activeWrites: [UUID: Task<Void, Error>] = [:]
    private var scriptObservationID = UUID()
    private var scriptObservation: AnyCancellable?
    private var ordering: LibraryScriptFieldWriteOrdering?
    private var owner: LibraryScriptDomainOwner?
    var script: UserScript? {
        willSet {
            observeCompletion(retireEditing())
            scriptObservation?.cancel()
            scriptObservation = nil
            scriptObservationID = UUID()
        }
        didSet {
            owner = script.flatMap { LibraryScriptDomainOwner(script: $0) }
            ordering = owner.map { .shared(identity: LibraryScriptEditorIdentity(owner: $0)) }
            refresh()
            guard observesRealm, let script, !script.isInvalidated,
                  !script.isFrozen, script.realm != nil else { return }
            let observationID = scriptObservationID
            scriptObservation = script.objectPublisher
                .sink(receiveCompletion: { [weak self] completion in
                    Task { @MainActor [weak self] in
                        guard let self, self.scriptObservationID == observationID else { return }
                        if case .failure(let error) = completion {
                            print("# LIBRARYSCRIPTEDITOR observation failed: \(error)")
                        }
                        self.refresh()
                    }
                }, receiveValue: { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self, self.scriptObservationID == observationID else { return }
                        self.refresh()
                    }
                })
        }
    }

    @Published var allowedDomainIDs: [UUID]?
    @Published var scriptTitle = ""
    @Published var scriptText = ""
    @Published var scriptEnabled = false
    @Published var scriptInjectAtStart = false
    @Published var scriptMainFrameOnly = true
    @Published var scriptSandboxed = false
    @Published var scriptPreviewURL = ""

    private var cancellables = Set<AnyCancellable>()

    init(
        realmConfiguration: Realm.Configuration = LibraryDataManager.realmConfiguration,
        observesRealm: Bool = true,
        retirementDidFinish: (@RealmBackgroundActor @Sendable () -> Void)? = nil
    ) {
        self.realmConfiguration = realmConfiguration
        self.observesRealm = observesRealm
        self.retirementDidFinish = retirementDidFinish
        observe($scriptTitle, edit: LibraryScriptFieldEdit.title, debounced: true)
        observe($scriptText, edit: LibraryScriptFieldEdit.text, debounced: true)
        observe($scriptEnabled, edit: LibraryScriptFieldEdit.enabled)
        observe($scriptInjectAtStart, edit: LibraryScriptFieldEdit.injectAtStart)
        observe($scriptMainFrameOnly, edit: LibraryScriptFieldEdit.mainFrameOnly)
        observe($scriptSandboxed, edit: LibraryScriptFieldEdit.sandboxed)
        observe($scriptPreviewURL, edit: LibraryScriptFieldEdit.previewURL, debounced: true)
    }

    private func observe<Value>(
        _ publisher: Published<Value>.Publisher, edit: @escaping (Value) -> LibraryScriptFieldEdit,
        debounced: Bool = false
    ) {
        let commands = publisher.dropFirst()
            .compactMap { [weak self] value -> LibraryScriptFieldCommand? in
                guard let self, !self.isRefreshing else { return nil }
                return self.capture(edit(value))
            }
            .eraseToAnyPublisher()
        let writes = debounced
            ? commands.debounceLeadingTrailing(for: .seconds(0.35), scheduler: DispatchQueue.main)
                .eraseToAnyPublisher()
            : commands
        writes.sink { [weak self] command in
            guard let self else { return }
            self.observeCompletion(self.submit(command))
        }
        .store(in: &cancellables)
    }

    private func capture(_ edit: LibraryScriptFieldEdit) -> LibraryScriptFieldCommand? {
        guard let owner, let ordering, let script, !script.isInvalidated,
              script.id == owner.scriptID, script.createdAt == owner.scriptCreatedAt,
              !script.isDeleted, script.isUserEditable else { return nil }
        let command = LibraryScriptFieldCommand(
            owner: owner, edit: edit, intent: ordering.issueIntent(field: edit.field), ordering: ordering
        )
        pendingFieldCommands[edit.field] = command
        return command
    }

    private func submit(
        _ command: LibraryScriptFieldCommand,
        beforeWrite: (@RealmBackgroundActor @Sendable () async throws -> Void)? = nil
    ) -> Task<Void, Error> {
        if let active = activeWrites[command.intent] { return active }
        // Retirement owns its captured batch. A delayed publisher cannot submit
        // that command again after rebinding, settlement or newer input.
        guard pendingFieldCommands[command.edit.field]?.intent == command.intent else {
            return Task<Void, Error> {}
        }
        let task = Task<Void, Error> { @RealmBackgroundActor [weak self] in
            do {
                try await command.write(beforeWrite: beforeWrite)
                await self?.settle(command, succeeded: true)
            } catch {
                await self?.settle(command, succeeded: false)
                throw error
            }
        }
        activeWrites[command.intent] = task
        return task
    }

    private func settle(_ command: LibraryScriptFieldCommand, succeeded: Bool) {
        activeWrites[command.intent] = nil
        guard succeeded, pendingFieldCommands[command.edit.field]?.intent == command.intent else { return }
        pendingFieldCommands[command.edit.field] = nil
        refresh()
    }

    private func observeCompletion(_ task: Task<Void, Error>) {
        Task { @MainActor in
            do { try await task.value }
            catch { print("# LIBRARYSCRIPTEDITOR write failed: \(error)") }
        }
    }

    @discardableResult
    func finishEditing() -> Task<Void, Error> {
        for command in pendingFieldCommands.values { _ = submit(command) }
        let writes = Array(activeWrites.values)
        return Task { @RealmBackgroundActor in
            var firstError: Error?
            for write in writes {
                do { try await write.value }
                catch { if firstError == nil { firstError = error } }
            }
            if let firstError { throw firstError }
        }
    }

    /// Immediate explicit input through the same owner/order/write path as form publishers.
    @discardableResult
    func writeFieldAsync(
        _ edit: LibraryScriptFieldEdit,
        beforeWrite: (@RealmBackgroundActor @Sendable () async throws -> Void)? = nil
    ) -> Task<Void, Error> {
        guard let command = capture(edit) else { return Task<Void, Error> {} }
        publishDraft(edit)
        return submit(command, beforeWrite: beforeWrite)
    }

    private func publishDraft(_ edit: LibraryScriptFieldEdit) {
        isRefreshing = true
        defer { isRefreshing = false }
        switch edit {
        case .title(let value): scriptTitle = value
        case .text(let value): scriptText = value
        case .enabled(let value): scriptEnabled = value
        case .injectAtStart(let value): scriptInjectAtStart = value
        case .mainFrameOnly(let value): scriptMainFrameOnly = value
        case .sandboxed(let value): scriptSandboxed = value
        case .previewURL(let value): scriptPreviewURL = value
        }
    }

    private func retireEditing() -> Task<Void, Error> {
        let retirement = LibraryScriptFieldRetirement(
            commands: Array(pendingFieldCommands.values), activeWrites: activeWrites
        )
        pendingFieldCommands.removeAll()
        let retirementDidFinish = retirementDidFinish
        return Task { @RealmBackgroundActor in
            defer { if !retirement.commands.isEmpty { retirementDidFinish?() } }
            try await retirement.finish()
        }
    }

    deinit {
        let retirement = LibraryScriptFieldRetirement(
            commands: Array(pendingFieldCommands.values), activeWrites: activeWrites
        )
        let retirementDidFinish = retirementDidFinish
        Task { @RealmBackgroundActor in
            defer { if !retirement.commands.isEmpty { retirementDidFinish?() } }
            do { try await retirement.finish() }
            catch { print("# LIBRARYSCRIPTEDITOR retirement write failed: \(error)") }
        }
    }

    func refresh() {
        if let script, !script.isInvalidated, !script.isFrozen { script.realm?.refresh() }
        isRefreshing = true
        defer { isRefreshing = false }
        guard let script, !script.isInvalidated, !script.isDeleted else {
            allowedDomainIDs = nil
            if pendingFieldCommands[.title] == nil { scriptTitle = "" }
            if pendingFieldCommands[.text] == nil { scriptText = "" }
            if pendingFieldCommands[.enabled] == nil { scriptEnabled = false }
            if pendingFieldCommands[.injectAtStart] == nil { scriptInjectAtStart = false }
            if pendingFieldCommands[.mainFrameOnly] == nil { scriptMainFrameOnly = true }
            if pendingFieldCommands[.sandboxed] == nil { scriptSandboxed = false }
            if pendingFieldCommands[.previewURL] == nil { scriptPreviewURL = "" }
            return
        }
        allowedDomainIDs = Array(script.allowedDomainIDs)
        if pendingFieldCommands[.title] == nil { scriptTitle = script.title }
        if pendingFieldCommands[.text] == nil { scriptText = script.script }
        if pendingFieldCommands[.enabled] == nil { scriptEnabled = !script.isArchived }
        if pendingFieldCommands[.injectAtStart] == nil { scriptInjectAtStart = script.injectAtStart }
        if pendingFieldCommands[.mainFrameOnly] == nil { scriptMainFrameOnly = script.mainFrameOnly }
        if pendingFieldCommands[.sandboxed] == nil { scriptSandboxed = script.sandboxed }
        if pendingFieldCommands[.previewURL] == nil { scriptPreviewURL = script.previewURL?.absoluteString ?? "" }
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

    @discardableResult
    func pastePreviewURL(strings: [String]) -> Task<Void, Error> {
        let url = URL(string: (strings.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
            ?? URL(string: "about:blank")!
        return writeFieldAsync(.previewURL(url.absoluteString))
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
        _viewModel = StateObject(wrappedValue: LibraryScriptFormSectionsViewModel(realmConfiguration: configuration))
        _webViewModel = StateObject(wrappedValue: ReaderViewModel(realmConfiguration: configuration, systemScripts: []))
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
                    observeEditorChange(viewModel.pastePreviewURL(strings: strings))
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
        .task(id: LibraryScriptEditorIdentity(script: script)) { @MainActor in
            viewModel.script = script
        }
        .onDisappear { observeEditorChange(viewModel.finishEditing()) }
    }
    
    private func observeDomainChange(_ task: Task<Void, Error>) {
        Task { @MainActor in
            do { try await task.value }
            catch { print("# LIBRARYSCRIPTDOMAIN list change failed: \(error)") }
        }
    }

    private func observeEditorChange(_ task: Task<Void, Error>) {
        Task { @MainActor in
            do { try await task.value }
            catch { print("# LIBRARYSCRIPTEDITOR write failed: \(error)") }
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
