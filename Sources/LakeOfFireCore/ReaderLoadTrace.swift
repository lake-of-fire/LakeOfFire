import Foundation
import os.signpost
import LakeKit

/// Development and TestFlight loading milestones persist in exportable logs.
/// App Store distributions leave these diagnostics disabled. Detailed signposts
/// also require MANABI_READER_LOAD_TRACE=1 or --reader-load-trace. Persisted
/// milestones omit content, URLs, and user identifiers. Intervals include suspension time.
public enum ReaderLoadTrace {
    /// Random operation identity only; never derived from content or an account.
    @TaskLocal public static var operationID: UUID?
    @TaskLocal public static var attempt: Int = 0
#if DEBUG
    /// Scoped diagnostic capture for native tests; never changes admission.
    @TaskLocal public static var eventObserver: (@Sendable (String, String) -> Void)?
#endif

    private static var context: String {
        "operation=\(operationID?.uuidString ?? "none") attempt=\(attempt)"
    }
    private static let launchID = UUID()
    private static let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
    private static let pendingLock = NSLock()
    private static var pendingSpans: [UUID: (stage: String, operation: UUID?, started: TimeInterval)] = [:]

    private static func trackPending(_ span: Span) {
        guard diagnosticsPermitted else { return }
        pendingLock.lock()
        if pendingSpans.count >= 256, let oldest = pendingSpans.min(by: { $0.value.started < $1.value.started })?.key {
            pendingSpans.removeValue(forKey: oldest)
        }
        pendingSpans[span.token] = (span.stage, operationID, span.startedAt)
        pendingLock.unlock()
        let token = span.token
        let spanContext = span.context
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 8) {
            pendingLock.lock()
            guard let pending = pendingSpans[token] else { pendingLock.unlock(); return }
            let stages = pendingSpans.values.filter { $0.operation == pending.operation }
                .sorted { $0.started < $1.started }.prefix(16)
            let now = ProcessInfo.processInfo.systemUptime
            let summary = stages.map { "\($0.stage):\(Int(max(0, now - $0.started) * 1_000))ms" }.joined(separator: ",")
            pendingLock.unlock()
            // Stage names and random correlation identities only. Never copy
            // resource URLs, cookies, registration capabilities or page data.
            record("event stage=loading.pendingSnapshot \(spanContext) pending=\(summary)")
        }
    }

    static func permitsDiagnostics(isDevelopmentBuild: Bool, receiptFilename: String?) -> Bool {
        isDevelopmentBuild || receiptFilename == "sandboxReceipt"
    }

    private static let diagnosticsPermitted: Bool = {
#if DEBUG
        let isDevelopmentBuild = true
#else
        let isDevelopmentBuild = false
#endif
        // Match the app's TestFlight distribution check. A production or
        // missing receipt fails closed; promoting a build to the App Store
        // therefore turns this filter off without another build setting.
        return permitsDiagnostics(
            isDevelopmentBuild: isDevelopmentBuild,
            receiptFilename: Bundle.main.appStoreReceiptURL?.lastPathComponent
        )
    }()

    // Development/TestFlight milestones use the existing rotating/exportable log files.
    // Detailed per-document/cache diagnostics and signposts remain opt-in.
    private static func persists(_ stage: String) -> Bool {
        guard diagnosticsPermitted else { return false }
        switch stage {
        case "app.main", "app.init", "app.initialization", "app.launchBootstrap",
             "app.coreConstruction", "app.coreInitializationStep",
             "loading.applied", "loading.processingClaimFinished", "loading.processingClaimRejected",
             "loading.renderCompletionDeferred", "loading.initializingReplayIgnored", "loading.overlayVisibility", "reader.scene",
             "restore.initialTask", "restore.initialTaskScheduled", "restore.resolve", "restore.storedContent", "restore.dispatch", "restore.dispatchRetrySkipped", "restore.ready", "restore.finished",
             "webview.didCommit", "webview.didFinish", "webview.intermediateBlankSkipped", "webview.readerNavigationPolicy",
             "webview.construction", "reader.viewModelConstruction", "reader.mediaModelConstruction",
             "reader.viewModelFactory", "reader.readerModeFactory", "reader.containerAppeared", "reader.scriptSnapshot",
             "ebook.initialization", "ebook.initializationStep",
             "webview.navigationFailed", "webview.documentContextInvalidated",
             "readerMode.request", "readerMode.renderTaskScheduled", "readerMode.renderTaskStarted", "readerMode.renderTaskReturned",
             "readerMode.resolveRoute", "readerMode.route", "readerMode.swiftProcessing", "readerMode.processAndSerialize",
             "readerMode.render", "readerMode.renderContentResolution", "readerMode.canonicalInterpretation",
             "readerMode.readabilityPreparation", "readerMode.readabilityExtraction", "readerMode.publicationDateFallback",
             "readerMode.primaryMetadataWrite", "readerMode.headerImageResolution",
             "readerMode.nativeProcessingFinished", "readerMode.serialize", "readerMode.loadFinalHTML", "readerMode.navigationSubmission", "readerMode.navigationMainQueueTurn", "readerMode.fontPreparation", "readerMode.renderFailed", "readerMode.defaultsPropagation",
             "readerMode.renderReadyAccepted", "readerMode.loadCompleted", "readerMode.loadCancelled", "readerMode.loadFailed", "readerMode.restoreOwnedDocument",
             "readerMode.visibilitySnapshot", "readerMode.initialArticlePresentation", "readerMode.navigationCommittedCallback", "readerMode.fontInjection", "readerMode.fontReadiness", "readerMode.fontResource", "readerMode.paginationSetup",
             "reader.reload", "reader.reloadDispatched", "reader.reloadSkipped", "reader.reloadFallback",
             "reader.lookupPrewarm", "reader.lookupPrewarmSkipped", "reader.userScriptAssembly",
             "reader.requiredDownloads", "reader.startupAsset", "reader.startupAssetCleanup", "reader.requiredDownloadOrder",
             "reader.initialLocalPreparation", "reader.initialLocalMigration", "reader.initialLocalLookup", "reader.initialLocalAsset", "reader.initialLocalAssetStep",
             "reader.sheetTabSelection", "reader.sheetDismissal", "reader.sheetDetentSelection",
             "maintenance.sentenceGraphRepair",
             "suspension.previous-transition", "suspension.launch-repair", "suspension.startup",
             "suspension.share-inbox", "suspension.app-sync", "suspension.realm-warmups",
             "suspension.cloudkit", "suspension.reader-files", "suspension.word-tracking",
             "suspension.data-caches", "suspension.sentences", "suspension.anki",
             "suspension.downloads", "suspension.widgets",
             "reader.showOriginal", "reader.showOriginalSkipped",
             "reader.openDispatched", "reader.directLoadSkipped",
             "reader.documentPreparation", "reader.documentDelivery", "reader.documentReconstructionRequested",
             "reader.resourceRegistered", "reader.resourceCancelled", "reader.assetRequest",
             "reader.embedServerStartup", "reader.embedServerStopped", "reader.embedState", "reader.embedStateRejected", "reader.embedRequest",
             "reader.dictionaryPublicationReload", "reader.dictionaryPublicationAdopted", "readerMode.preparationSuperseded", "processor.dictionaryPublication", "processor.foreground", "processor.refreshDictionaries", "processor.lookupAdmission",
             "processor.lookupFingerprintSnapshot", "processor.lookupMorphology", "processor.lookupDictionaryOwner", "processor.lookupArtifactIdentity", "lookup.dictionaryOpen",
             "processor.lookupAdmissionWait", "processor.lookupAdmissionRetry",
             "processor.runtimePublicationAdmission", "processor.analysisSession", "processor.cacheRead", "processor.parse",
             "processor.sentenceCatalog", "processor.semanticPreparation",
             "processor.preprocessAndInject", "processor.htmlInjectionCache", "processor.documentCacheIdentity", "processor.documentCachePopulation", "processor.documentCacheWrite", "processor.textAnalysisProfile", "processor.textAnalysis", "processor.textAnalysisProgress", "processor.candidateProfile", "processor.semanticEvidenceProfile", "processor.trackingStatuses", "processor.rejected",
             "processor.trackingAccountSnapshot", "processor.trackingRealmOpen", "processor.trackingRealmRefresh",
             "processor.trackingReconcile", "processor.trackingReconcileRequested",
             "tracking.reconciliationAdmission", "tracking.reconciliationPass", "tracking.reconciliationAvailability", "tracking.reconciliationBaseline", "tracking.reconciliationPlan", "tracking.reconciliationCancelled", "tracking.pageStatusPreparation", "tracking.pageStatusSnapshot",
             "tracking.segmentAdmission", "tracking.wordBootstrap", "tracking.maintenanceScheduling",
             "processor.attempt", "processor.attemptCancelled", "processor.awaitActivation",
             "processor.publicationAdmissionRetry", "processor.injectionFinished",
             "bridge.readerInitializing", "bridge.readerInitialized", "bridge.trackingAccountAdmission", "bridge.settingsRefresh", "bridge.settingsSubscription", "bridge.settingsFont",
             "bridge.initializeTracking", "bridge.trackingAcknowledgement", "bridge.refreshAfterTracking", "bridge.initialArticlePresentation",
             "bridge.trackingInitializationFailed":
            return true
        default:
            return false
        }
    }

    private static func record(_ message: String) {
        LakeKit.Logger.shared.recordDiagnostic(
            "reader-load launch=\(launchID.uuidString) pid=\(ProcessInfo.processInfo.processIdentifier) build=\(build) uptime_ms=\(String(format: "%.3f", ProcessInfo.processInfo.systemUptime * 1_000)) \(message)"
        )
    }
    public static let isEnabled = diagnosticsPermitted && (
        ProcessInfo.processInfo.environment["MANABI_READER_LOAD_TRACE"] == "1"
            || ProcessInfo.processInfo.arguments.contains("--reader-load-trace")
    )
    /// Includes a scoped test observer even when OS logging is disabled.
    public static var isCollectingEvents: Bool {
#if DEBUG
        isEnabled || eventObserver != nil
#else
        isEnabled
#endif
    }
    /// Lets callers avoid preparing bounded diagnostic payloads when this
    /// stage will be discarded, including App Store distribution.
    public static func isRecording(_ stage: String) -> Bool {
        isCollectingEvents || persists(stage)
    }

    private static let log = OSLog(subsystem: "io.manabi.reader", category: "ReaderLoad")
    // Standard Time Profiler templates collect this category by default.
    // Keep textual logs separate so existing ReaderLoad predicates still work.
    private static let signpostLog = OSLog(subsystem: "io.manabi.reader", category: .pointsOfInterest)

    public struct Span {
        fileprivate let token: UUID
        fileprivate let stage: String
        fileprivate let id: OSSignpostID
        fileprivate let startedAt: TimeInterval
        fileprivate let context: String
        fileprivate let persistent: Bool

        public func end(_ detail: String = "") {
            ReaderLoadTrace.pendingLock.lock()
            ReaderLoadTrace.pendingSpans.removeValue(forKey: token)
            ReaderLoadTrace.pendingLock.unlock()
            let elapsed = (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
            if persistent {
                ReaderLoadTrace.record("end stage=\(stage) elapsed_ms=\(String(format: "%.3f", elapsed)) \(context) \(detail)")
            }
            guard ReaderLoadTrace.isEnabled else { return }
            os_signpost(.end, log: ReaderLoadTrace.signpostLog, name: "ReaderLoad", signpostID: id,
                        "%{public}@ elapsed_ms=%.3f %{public}@ %{public}@", stage, elapsed, context, detail)
            os_log(.info, log: ReaderLoadTrace.log,
                   "reader-load end stage=%{public}@ signpost=%llu uptime_ms=%.3f elapsed_ms=%.3f %{public}@ %{public}@",
                   stage, id.rawValue, ProcessInfo.processInfo.systemUptime * 1_000, elapsed, context, detail)
        }
    }

    public static func begin(_ stage: String) -> Span? {
        let persistent = persists(stage)
        guard isEnabled || persistent else { return nil }
        // OS signpost IDs can be zero when signposts are disabled. Persist an
        // independent random span identity in the existing diagnostic context.
        let span = Span(token: UUID(), stage: stage, id: OSSignpostID(log: signpostLog),
                        startedAt: ProcessInfo.processInfo.systemUptime,
                        context: "\(context) span=\(UUID().uuidString)", persistent: persistent)
        trackPending(span)
        if persistent {
            record("begin stage=\(stage) \(span.context)")
        }
        guard isEnabled else { return span }
        os_signpost(.begin, log: signpostLog, name: "ReaderLoad", signpostID: span.id, "%{public}@ %{public}@", stage, span.context)
        os_log(.info, log: log, "reader-load begin stage=%{public}@ signpost=%llu uptime_ms=%.3f %{public}@",
               stage, span.id.rawValue, span.startedAt * 1_000, span.context)
        return span
    }

    public static func event(_ stage: String, _ detail: @autoclosure () -> String = "") {
        let persistent = persists(stage)
        guard isCollectingEvents || persistent else { return }
        let detail = detail()
        if persistent {
            record("event stage=\(stage) \(context) \(detail)")
        }
#if DEBUG
        eventObserver?(stage, "\(context) \(detail)")
#endif
        guard isEnabled else { return }
        os_signpost(.event, log: signpostLog, name: "ReaderLoadEvent", "%{public}@ %{public}@ %{public}@", stage, context, detail)
        os_log(.info, log: log, "reader-load event stage=%{public}@ uptime_ms=%.3f %{public}@ %{public}@",
               stage, ProcessInfo.processInfo.systemUptime * 1_000, context, detail)
    }
}
