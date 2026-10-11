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

struct UserScriptEditorIdentity: Hashable, Sendable {
    let id: UUID
    let createdAt: Date
    let realmConfigurationIdentity: String
}

func userScriptEditorConfigurationIdentity(_ configuration: Realm.Configuration) -> String {
    if let fileURL = configuration.fileURL {
        return "file:\(fileURL.standardizedFileURL.resolvingSymlinksInPath().absoluteString)"
    }
    if let identifier = configuration.inMemoryIdentifier {
        return "memory:\(identifier)"
    }
    return "default"
}

@MainActor
private final class UserScriptEditorLifetime {
    var latestIntentGeneration = [LibraryUserScriptEditorField: UInt64]()
}

private struct UserScriptEditorLibraryTarget: Equatable, Sendable {
    let id: UUID
    let createdAt: Date
}

private struct UserScriptEditorMutationRequest: Sendable {
    let identity: UserScriptEditorIdentity
    let mutation: UserScriptEditorMutationRequestMutation
    let configuration: Realm.Configuration
    let generation: UInt64
    let scriptGeneration: UInt64
    let lifetime: UserScriptEditorLifetime
}

private enum UserScriptEditorMutationRequestMutation: Equatable, Sendable {
    case field(LibraryUserScriptEditorFieldMutation)
    case enabled(Bool, libraryTarget: UserScriptEditorLibraryTarget?)

    var field: LibraryUserScriptEditorField {
        switch self {
        case .field(let mutation):
            mutation.field
        case .enabled:
            .enabled
        }
    }
}

private enum LibraryUserScriptEditorCommandError: LocalizedError {
    case superseded
    case unavailable

    var errorDescription: String? {
        switch self {
        case .superseded:
            "This script was replaced before the edit could be saved. Try again."
        case .unavailable:
            "This script is no longer available to edit."
        }
    }
}

@MainActor
class LibraryScriptFormSectionsViewModel: ObservableObject {
    var script: UserScript? {
        willSet {
            saveRetiringDrafts()
        }
        didSet {
            if let configuration = script?.realm?.configuration {
                realmConfiguration = configuration
            }
            isObserving = true
            scriptGeneration &+= 1
            pendingRequests.removeAll()
            enqueuedGenerations.removeAll()
            latestIntentGeneration.removeAll()
            editorLifetime = UserScriptEditorLifetime()
            locallyOwnedFieldGenerations.removeAll()
            fieldErrorMessages.removeAll()
            persistenceErrorMessage = nil
            domainCommandErrorMessage = nil
            let generation = scriptGeneration
            guard let script else {
                Task { @RealmBackgroundActor [weak self] in
                    self?.invalidateObservation(through: generation)
                }
                refresh()
                return
            }
            refresh()
            let realmConfiguration = self.realmConfiguration
            let identity = UserScriptEditorIdentity(
                id: script.id,
                createdAt: script.createdAt,
                realmConfigurationIdentity: userScriptEditorConfigurationIdentity(realmConfiguration)
            )
            Task { @RealmBackgroundActor [weak self] in
                guard let self else { return }
                do {
                    let realm = try await RealmBackgroundActor.shared.cachedRealm(
                        for: realmConfiguration
                    )
                    guard let script = realm.object(ofType: UserScript.self, forPrimaryKey: identity.id),
                          !script.isDeleted,
                          script.createdAt == identity.createdAt,
                          await self.canObserve(identity: identity, generation: generation),
                          generation >= installedObservationGeneration else { return }
                    installedObservationGeneration = generation
                    objectNotificationToken?.invalidate()
                    objectNotificationToken = script
                        .observe { [weak self] change in
                            switch change {
                            case .change(_, _), .deleted:
                                Task { @MainActor [weak self] in
                                    guard let self,
                                          self.canObserve(identity: identity, generation: generation) else { return }
                                    self.refresh()
                                }
                            case .error(let error):
                                Task { @MainActor [weak self] in
                                    guard let self,
                                          self.canObserve(identity: identity, generation: generation) else { return }
                                    self.persistenceErrorMessage = error.localizedDescription
                                }
                            }
                        }
                    await MainActor.run {
                        guard self.canObserve(identity: identity, generation: generation) else { return }
                        self.refresh()
                    }
                } catch {
                    await MainActor.run {
                        guard self.canObserve(identity: identity, generation: generation) else { return }
                        self.persistenceErrorMessage = error.localizedDescription
                    }
                }
            }
        }
    }

    @Published var allowedDomainTargets: [LibraryUserScriptAllowedDomainTarget]? = nil

    @Published var scriptTitle = ""
    @Published var scriptText = ""
    @Published var scriptEnabled = false
    @Published var scriptInjectAtStart = false
    @Published var scriptMainFrameOnly = true
    @Published var scriptSandboxed = false
    @Published var scriptPreviewURL = ""
    @Published private(set) var persistenceErrorMessage: String?
    @Published private(set) var domainCommandErrorMessage: String?
    
    var cancellables = Set<AnyCancellable>()
    @RealmBackgroundActor private var objectNotificationToken: NotificationToken?
    @RealmBackgroundActor private var installedObservationGeneration: UInt64 = 0
    private var scriptGeneration: UInt64 = 0
    private var isObserving = true
    private var persistenceTail: Task<Void, Never>?
    private var domainPersistenceTail: Task<Void, Never>?
    private var domainIntentGeneration: UInt64 = 0
    private var editorLifetime = UserScriptEditorLifetime()
    private var latestIntentGeneration = [LibraryUserScriptEditorField: UInt64]()
    private var locallyOwnedFieldGenerations = [LibraryUserScriptEditorField: UInt64]()
    private var fieldErrorMessages = [LibraryUserScriptEditorField: String]()
    private var pendingRequests = [LibraryUserScriptEditorField: UserScriptEditorMutationRequest]()
    private var enqueuedGenerations = [LibraryUserScriptEditorField: UInt64]()
    private var isApplyingObservedState = false
    private(set) var realmConfiguration: Realm.Configuration
    
    init(realmConfiguration: Realm.Configuration = LibraryDataManager.realmConfiguration) {
        self.realmConfiguration = realmConfiguration
        $scriptTitle
            .removeDuplicates()
            .compactMap { @MainActor [weak self] value in
                self?.makeMutationRequest(.title(value))
            }
            .debounceLeadingTrailing(for: .seconds(0.35), scheduler: DispatchQueue.main)
            .sink { @MainActor [weak self] request in
                self?.enqueue(request)
            }
            .store(in: &cancellables)
        $scriptText
            .removeDuplicates()
            .compactMap { @MainActor [weak self] value in
                self?.makeMutationRequest(.source(value))
            }
            .debounceLeadingTrailing(for: .seconds(0.35), scheduler: DispatchQueue.main)
            .sink { @MainActor [weak self] request in
                self?.enqueue(request)
            }
            .store(in: &cancellables)
        $scriptEnabled
            .removeDuplicates()
            .compactMap { @MainActor [weak self] value in
                self?.makeEnabledRequest(value)
            }
            .sink { @MainActor [weak self] request in
                self?.enqueue(request)
            }
            .store(in: &cancellables)
        $scriptInjectAtStart
            .removeDuplicates()
            .compactMap { @MainActor [weak self] value in
                self?.makeMutationRequest(.injectAtStart(value))
            }
            .sink { @MainActor [weak self] request in
                self?.enqueue(request)
            }
            .store(in: &cancellables)
        $scriptMainFrameOnly
            .removeDuplicates()
            .compactMap { @MainActor [weak self] value in
                self?.makeMutationRequest(.mainFrameOnly(value))
            }
            .sink { @MainActor [weak self] request in
                self?.enqueue(request)
            }
            .store(in: &cancellables)
        $scriptSandboxed
            .removeDuplicates()
            .compactMap { @MainActor [weak self] value in
                self?.makeMutationRequest(.sandboxed(value))
            }
            .sink { @MainActor [weak self] request in
                self?.enqueue(request)
            }
            .store(in: &cancellables)
        $scriptPreviewURL
            .removeDuplicates()
            .compactMap { @MainActor [weak self] value -> UserScriptEditorMutationRequest? in
                self?.makePreviewURLMutationRequest(value)
            }
            .debounceLeadingTrailing(for: .seconds(0.35), scheduler: DispatchQueue.main)
            .sink { @MainActor [weak self] request in
                self?.enqueue(request)
            }
            .store(in: &cancellables)
    }

    private var currentIdentity: UserScriptEditorIdentity? {
        guard let script, !script.isInvalidated else { return nil }
        return UserScriptEditorIdentity(
            id: script.id,
            createdAt: script.createdAt,
            realmConfigurationIdentity: userScriptEditorConfigurationIdentity(realmConfiguration)
        )
    }

    private func isCurrent(identity: UserScriptEditorIdentity, generation: UInt64) -> Bool {
        scriptGeneration == generation && currentIdentity == identity
    }

    private func canObserve(identity: UserScriptEditorIdentity, generation: UInt64) -> Bool {
        isObserving && isCurrent(identity: identity, generation: generation)
    }

    private func makeMutationRequest(
        _ mutation: LibraryUserScriptEditorFieldMutation
    ) -> UserScriptEditorMutationRequest? {
        guard !isApplyingObservedState else { return nil }
        guard let identity = currentIdentity else { return nil }
        let field = mutation.field
        let generation = (latestIntentGeneration[field] ?? 0) &+ 1
        latestIntentGeneration[field] = generation
        editorLifetime.latestIntentGeneration[field] = generation
        locallyOwnedFieldGenerations[field] = generation
        let request = UserScriptEditorMutationRequest(
            identity: identity,
            mutation: .field(mutation),
            configuration: realmConfiguration,
            generation: generation,
            scriptGeneration: scriptGeneration,
            lifetime: editorLifetime
        )
        pendingRequests[request.mutation.field] = request
        return request
    }

    private var currentLibraryTarget: UserScriptEditorLibraryTarget? {
        guard let script, !script.isInvalidated, let realm = script.realm else { return nil }
        let owners = realm.objects(LibraryConfiguration.self).filter {
            !$0.isDeleted && $0.userScriptIDs.contains(script.id)
        }
        guard owners.count == 1, let owner = owners.first else { return nil }
        return UserScriptEditorLibraryTarget(id: owner.id, createdAt: owner.createdAt)
    }

    private func makeEnabledRequest(_ enabled: Bool) -> UserScriptEditorMutationRequest? {
        guard !isApplyingObservedState, let identity = currentIdentity else { return nil }
        let generation = (latestIntentGeneration[.enabled] ?? 0) &+ 1
        latestIntentGeneration[.enabled] = generation
        editorLifetime.latestIntentGeneration[.enabled] = generation
        locallyOwnedFieldGenerations[.enabled] = generation
        let request = UserScriptEditorMutationRequest(
            identity: identity,
            mutation: .enabled(enabled, libraryTarget: currentLibraryTarget),
            configuration: realmConfiguration,
            generation: generation,
            scriptGeneration: scriptGeneration,
            lifetime: editorLifetime
        )
        pendingRequests[request.mutation.field] = request
        return request
    }

    private func makePreviewURLMutationRequest(
        _ value: String
    ) -> UserScriptEditorMutationRequest? {
        guard !isApplyingObservedState, currentIdentity != nil else { return nil }
        let previewURL = value.isEmpty ? nil : URL(string: value)
        guard value.isEmpty || previewURL != nil else {
            let generation = (latestIntentGeneration[.previewURL] ?? 0) &+ 1
            latestIntentGeneration[.previewURL] = generation
            editorLifetime.latestIntentGeneration[.previewURL] = generation
            locallyOwnedFieldGenerations[.previewURL] = generation
            pendingRequests[.previewURL] = nil
            setPersistenceError("Enter a valid preview URL.", for: .previewURL)
            return nil
        }
        return makeMutationRequest(.previewURL(previewURL))
    }

    private func enqueue(_ request: UserScriptEditorMutationRequest) {
        guard isCurrent(identity: request.identity, generation: request.scriptGeneration),
              latestIntentGeneration[request.mutation.field] == request.generation,
              enqueuedGenerations[request.mutation.field] != request.generation else { return }
        enqueuedGenerations[request.mutation.field] = request.generation
        let predecessor = persistenceTail
        persistenceTail = Task { @MainActor in
            await predecessor?.value
            guard request.lifetime.latestIntentGeneration[request.mutation.field] == request.generation else {
                return
            }
            do {
                let result = try await Self.persist(request)
                guard self.isCurrent(identity: request.identity, generation: request.scriptGeneration),
                      self.latestIntentGeneration[request.mutation.field] == request.generation else {
                    return
                }
                switch result {
                case .changed, .unchanged:
                    break
                case .superseded:
                    throw LibraryUserScriptEditorCommandError.superseded
                case .unavailable:
                    throw LibraryUserScriptEditorCommandError.unavailable
                }
                self.locallyOwnedFieldGenerations[request.mutation.field] = nil
                self.pendingRequests[request.mutation.field] = nil
                self.setPersistenceError(nil, for: request.mutation.field)
            } catch {
                guard self.isCurrent(identity: request.identity, generation: request.scriptGeneration),
                      self.latestIntentGeneration[request.mutation.field] == request.generation else {
                    return
                }
                self.pendingRequests[request.mutation.field] = nil
                self.setPersistenceError(error.localizedDescription, for: request.mutation.field)
            }
        }
    }

    // Keep captured intents alive when SwiftUI retires the mounted editor during debounce.
    func finishEditing() async {
        let generation = scriptGeneration
        isObserving = false
        for request in pendingRequests.values {
            enqueue(request)
        }
        await persistenceTail?.value
        await domainPersistenceTail?.value
        await invalidateObservation(through: generation)
    }

    @RealmBackgroundActor
    private func invalidateObservation(through generation: UInt64) {
        guard installedObservationGeneration <= generation else { return }
        objectNotificationToken?.invalidate()
        objectNotificationToken = nil
    }

    private func saveRetiringDrafts() {
        for request in pendingRequests.values {
            enqueue(request)
        }
    }

    @RealmBackgroundActor
    private static func persist(
        _ request: UserScriptEditorMutationRequest
    ) async throws -> LibraryUserScriptEditorFieldMutationResult {
        let target = LibraryUserScriptEditorTarget(
            scriptID: request.identity.id,
            createdAt: request.identity.createdAt
        )
        switch request.mutation {
        case .field(let mutation):
            return try await LibraryUserScriptEditorFieldCommand.perform(
                mutation,
                target: target,
                configuration: request.configuration
            )
        case .enabled(let enabled, let libraryTarget):
            return try await persistEnabled(
                enabled,
                target: target,
                libraryTarget: libraryTarget,
                configuration: request.configuration
            )
        }
    }

    @RealmBackgroundActor
    private static func persistEnabled(
        _ enabled: Bool,
        target: LibraryUserScriptEditorTarget,
        libraryTarget: UserScriptEditorLibraryTarget?,
        configuration: Realm.Configuration
    ) async throws -> LibraryUserScriptEditorFieldMutationResult {
        guard let libraryTarget else { return .unavailable }
        let lifecycleTarget = LibraryUserScriptTarget(
            scriptID: target.scriptID,
            createdAt: target.createdAt
        )
        let result = try await LibraryUserScriptLifecycleCommand.setEnabled(
            enabled,
            target: lifecycleTarget,
            configurationID: libraryTarget.id,
            configurationCreatedAt: libraryTarget.createdAt,
            realmConfiguration: configuration,
            requiringExistingMembership: true
        )
        return (result.archivedScriptIDs.isEmpty && result.restoredScriptIDs.isEmpty && !result.membershipChanged)
            ? .unchanged
            : .changed(changedAt: result.changedAt)
    }

    private func setPersistenceError(
        _ message: String?,
        for field: LibraryUserScriptEditorField
    ) {
        fieldErrorMessages[field] = message
        persistenceErrorMessage = fieldErrorMessages.values.first
    }
    
    deinit {
        Task { @RealmBackgroundActor [weak objectNotificationToken] in
            objectNotificationToken?.invalidate()
        }
    }
    
    @MainActor
    func refresh() {
        let script = script.flatMap { $0.isInvalidated ? nil : $0 }
        if let script, let realm = script.realm {
            allowedDomainTargets = script.allowedDomainIDs.compactMap { domainID in
                guard let domain = realm.object(
                    ofType: UserScriptAllowedDomain.self,
                    forPrimaryKey: domainID
                ), !domain.isDeleted else {
                    return nil
                }
                return LibraryUserScriptAllowedDomainTarget(
                    domainID: domain.id,
                    createdAt: domain.createdAt
                )
            }
        } else {
            allowedDomainTargets = nil
        }

        isApplyingObservedState = true
        defer { isApplyingObservedState = false }
        if locallyOwnedFieldGenerations[.title] == nil {
            scriptTitle = script?.title ?? ""
        }
        if locallyOwnedFieldGenerations[.source] == nil {
            scriptText = script?.script ?? ""
        }
        if locallyOwnedFieldGenerations[.enabled] == nil {
            scriptEnabled = !(script?.isArchived ?? true || script?.isDeleted ?? true)
        }
        if locallyOwnedFieldGenerations[.injectAtStart] == nil {
            scriptInjectAtStart = script?.injectAtStart ?? false
        }
        if locallyOwnedFieldGenerations[.mainFrameOnly] == nil {
            scriptMainFrameOnly = script?.mainFrameOnly ?? true
        }
        if locallyOwnedFieldGenerations[.sandboxed] == nil {
            scriptSandboxed = script?.sandboxed ?? false
        }
        if locallyOwnedFieldGenerations[.previewURL] == nil {
            scriptPreviewURL = script?.previewURL?.absoluteString ?? ""
        }
    }
    
    @MainActor
    func onDeleteOfAllowedDomains(at offsets: IndexSet) {
        let targets = offsets.compactMap { offset in
            allowedDomainTargets?.indices.contains(offset) == true
                ? allowedDomainTargets?[offset]
                : nil
        }
        deleteAllowedDomains(targets)
    }

    func addEmptyDomain() {
        guard let target = currentTarget else { return }
        let configuration = realmConfiguration
        let identity = currentIdentity
        let generation = scriptGeneration
        domainIntentGeneration &+= 1
        let intentGeneration = domainIntentGeneration
        let predecessor = domainPersistenceTail
        let domainID = UUID()
        domainPersistenceTail = Task { @MainActor [weak self] in
            await predecessor?.value
            do {
                let result = try await LibraryUserScriptAllowedDomainMembershipCommand.addEmptyDomain(
                    to: target,
                    domainID: domainID,
                    configuration: configuration
                )
                guard let self, let identity,
                      self.isCurrent(identity: identity, generation: generation),
                      self.domainIntentGeneration == intentGeneration else { return }
                switch result.0 {
                case .changed, .unchanged:
                    self.domainCommandErrorMessage = nil
                case .superseded, .unavailable:
                    self.domainCommandErrorMessage = domainCommandError(for: result.0)
                }
            } catch {
                guard let self, let identity,
                      self.isCurrent(identity: identity, generation: generation),
                      self.domainIntentGeneration == intentGeneration else { return }
                self.domainCommandErrorMessage = error.localizedDescription
            }
        }
    }

    func deleteAllowedDomain(_ target: LibraryUserScriptAllowedDomainTarget) {
        deleteAllowedDomains([target])
    }

    private var currentTarget: LibraryUserScriptEditorTarget? {
        guard let identity = currentIdentity else { return nil }
        return LibraryUserScriptEditorTarget(scriptID: identity.id, createdAt: identity.createdAt)
    }

    private func deleteAllowedDomains(_ targets: [LibraryUserScriptAllowedDomainTarget]) {
        guard let scriptTarget = currentTarget, !targets.isEmpty else { return }
        let configuration = realmConfiguration
        let identity = currentIdentity
        let generation = scriptGeneration
        domainIntentGeneration &+= 1
        let intentGeneration = domainIntentGeneration
        let predecessor = domainPersistenceTail
        domainPersistenceTail = Task { @MainActor [weak self] in
            await predecessor?.value
            do {
                let result = try await LibraryUserScriptAllowedDomainMembershipCommand.deleteDomains(
                    targets,
                    from: scriptTarget,
                    configuration: configuration
                )
                guard let self, let identity,
                      self.isCurrent(identity: identity, generation: generation),
                      self.domainIntentGeneration == intentGeneration else { return }
                switch result {
                case .changed, .unchanged:
                    self.domainCommandErrorMessage = nil
                case .superseded, .unavailable:
                    self.domainCommandErrorMessage = domainCommandError(for: result)
                }
            } catch {
                guard let self, let identity,
                      self.isCurrent(identity: identity, generation: generation),
                      self.domainIntentGeneration == intentGeneration else { return }
                self.domainCommandErrorMessage = error.localizedDescription
            }
        }
    }

    private func domainCommandError(
        for result: LibraryUserScriptAllowedDomainMembershipMutationResult
    ) -> String? {
        switch result {
        case .changed, .unchanged:
            nil
        case .superseded:
            "The script changed before its domains could be saved. Try again."
        case .unavailable:
            "The script or one of its domains is no longer available."
        }
    }

    
    func pastePreviewURL(strings: [String]) {
        let value = (strings.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.isEmpty || URL(string: value) != nil else {
            let generation = (latestIntentGeneration[.previewURL] ?? 0) &+ 1
            latestIntentGeneration[.previewURL] = generation
            editorLifetime.latestIntentGeneration[.previewURL] = generation
            locallyOwnedFieldGenerations[.previewURL] = generation
            pendingRequests[.previewURL] = nil
            setPersistenceError("Enter a valid preview URL.", for: .previewURL)
            return
        }
        scriptPreviewURL = value
    }
}

@available(iOS 16.0, macOS 13, *)
struct LibraryScriptFormSections: View {
    let script: UserScript

    var body: some View {
        let configuration = script.realm?.configuration ?? LibraryDataManager.realmConfiguration
        LibraryScriptFormSectionsContent(script: script)
            .id(UserScriptEditorIdentity(
                id: script.id,
                createdAt: script.createdAt,
                realmConfigurationIdentity: userScriptEditorConfigurationIdentity(configuration)
            ))
    }
}

@available(iOS 16.0, macOS 13, *)
private struct LibraryScriptFormSectionsContent: View {
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
            if let persistenceErrorMessage = viewModel.persistenceErrorMessage {
                Text(persistenceErrorMessage)
                    .foregroundStyle(.red)
            }
            if let domainCommandErrorMessage = viewModel.domainCommandErrorMessage {
                Text(domainCommandErrorMessage)
                    .foregroundStyle(.red)
            }
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
            ForEach(viewModel.allowedDomainTargets ?? []) { target in
                UserScriptAllowedDomainCell(
                    target: target,
                    scriptTarget: LibraryUserScriptEditorTarget(scriptID: script.id, createdAt: script.createdAt),
                    realmConfiguration: viewModel.realmConfiguration
                )
                    .disabled(!script.isUserEditable)
                    .deleteDisabled(!script.isUserEditable)
                    .contextMenu {
                        if script.isUserEditable {
                            Button(role: .destructive) {
                                viewModel.deleteAllowedDomain(target)
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
            if viewModel.allowedDomainTargets?.isEmpty ?? false {
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
        .onDisappear {
            Task { @MainActor in
                await viewModel.finishEditing()
            }
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
