import SwiftUI

// TODO: Instead of layering this across eg Reader and ManabiReader, have it once and use environment to set its activation (or similar)
public struct ReaderLoadingProgressOverlayViewModifier: ViewModifier {
    // For some reason it doesn't always redraw if simply let isLoading: Bool
    let isLoading: Bool
    let statusMessage: String?
    let context: String
    let showsImmediately: Bool

    public init(
        isLoading: Bool,
        statusMessage: String? = nil,
        context: String = "ReaderOverlay",
        showsImmediately: Bool = false
    ) {
        self.isLoading = isLoading
        self.statusMessage = statusMessage
        self.context = context
        self.showsImmediately = showsImmediately
    }

    public func body(content: Content) -> some View {
        content
            .overlay {
                ReaderLoadingOverlay(
                    isLoading: isLoading,
                    statusMessage: statusMessage,
                    context: context,
                    showDelayNanoseconds: showsImmediately ? 0 : 200_000_000,
                    showsImmediately: showsImmediately
                )
            }
    }
}

private struct ReaderLoadingOverlay: View {
    let isLoading: Bool
    let statusMessage: String?
    let context: String
    let showDelayNanoseconds: UInt64
    let showsImmediately: Bool

    @Environment(\.colorScheme) private var colorScheme

    private struct OverlayEmission: Equatable {
        let isLoading: Bool
        let statusMessage: String?
    }

    private let minimumVisibleNanoseconds: UInt64 = 250_000_000

    @State private var displayedMessage: String?
    @State private var isShowingStatus = false
    @State private var showWorkItem: DispatchWorkItem?
    @State private var hideWorkItem: DispatchWorkItem?
    @State private var heartbeatTask: Task<Void, Never>?
    @State private var lastLoggedEmission: OverlayEmission?
    @State private var isVisible = false
    @State private var visibleSince: Date?
    @State private var showVisibilityTask: Task<Void, Never>?
    @State private var hideVisibilityTask: Task<Void, Never>?
    @State private var latestIsLoading = false
    @State private var latestStatusMessage: String?

    var body: some View {
        ZStack {
            Rectangle()
                .fill(overlayColor)
            VStack(spacing: 12) {
                ProgressView()
                    .tint(.secondary)
                    .delayedAppearance(forceDisplay: showsImmediately)
                Group {
                    if let message = displayedMessage, !message.isEmpty {
                        Text(message)
                            .font(.callout)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                            .opacity(isShowingStatus ? 1 : 0)
                            .scaleEffect(isShowingStatus ? 1 : 0.98)
                    } else {
                        Color.clear
                    }
                }
                .frame(height: 24)
                .animation(.easeInOut(duration: 0.2), value: isShowingStatus)
            }
        }
        .ignoresSafeArea(.all)
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible)
        .animation(showsImmediately ? nil : .easeInOut(duration: 0.2), value: isVisible)
        .onChange(of: isLoading) { newValue in
            latestIsLoading = newValue
            latestStatusMessage = statusMessage
            let emission = OverlayEmission(
                isLoading: newValue,
                statusMessage: newValue ? statusMessage : nil
            )
            if lastLoggedEmission != emission {
                lastLoggedEmission = emission
                debugPrint(
                    "# READER overlay.loading",
                    "context=\(context)",
                    "isLoading=\(newValue)",
                    "currentMessage=\((newValue ? statusMessage : nil) ?? "nil")"
                )
                debugPrint(
                    "# FLASH overlay.loading",
                    "context=\(context)",
                    "isLoading=\(newValue)",
                    "status=\((newValue ? statusMessage : nil) ?? "nil")"
                    )
                if shouldSnippetLog {
                    debugPrint(
                        "# SNIPPETLOAD overlay.loading",
                        "context=\(context)",
                        "isLoading=\(newValue)",
                        "status=\((newValue ? statusMessage : nil) ?? "nil")"
                    )
                }
            }
            if newValue { startHeartbeat() } else { stopHeartbeat() }
            syncVisibility()
            syncStatusDisplay()
        }
        .onChange(of: statusMessage) { _ in
            latestStatusMessage = statusMessage
            syncStatusDisplay()
        }
        .onChange(of: isVisible) { _ in
            syncStatusDisplay()
            if shouldSnippetLog {
                debugPrint(
                    "# SNIPPETLOAD overlay.visibility",
                    "context=\(context)",
                    "isVisible=\(isVisible)",
                    "latestIsLoading=\(latestIsLoading)"
                )
            }
        }
        .onAppear {
            latestIsLoading = isLoading
            latestStatusMessage = statusMessage
            debugPrint(
                "# FLASH overlay.appear",
                "context=\(context)",
                "isLoading=\(isLoading)",
                "status=\(statusMessage ?? "nil")"
            )
            if shouldSnippetLog {
                debugPrint(
                    "# SNIPPETLOAD overlay.appear",
                    "context=\(context)",
                    "isLoading=\(isLoading)",
                    "status=\(statusMessage ?? "nil")"
                )
            }
            syncVisibility()
            syncStatusDisplay()
        }
        .onDisappear {
            cancelAllWork()
            displayedMessage = nil
            isShowingStatus = false
            cancelVisibilityWork()
            isVisible = false
            visibleSince = nil
            stopHeartbeat()
        }
    }

    private var overlayColor: Color {
        colorScheme == .dark ? .black : .white
    }

    private var shouldSnippetLog: Bool {
        context.contains("LookupsSnippet") || context.contains("ManabiReader")
    }

    @MainActor
    private func syncVisibility() {
        cancelVisibilityWork()

        if latestIsLoading {
            if showDelayNanoseconds == 0 {
                if !isVisible {
                    isVisible = true
                    visibleSince = Date()
                }
                return
            }
            showVisibilityTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: showDelayNanoseconds)
                if Task.isCancelled { return }
                guard latestIsLoading else { return }
                if !isVisible {
                    isVisible = true
                    visibleSince = Date()
                }
            }
            return
        }

        guard isVisible else {
            visibleSince = nil
            return
        }

        let shownAt = visibleSince ?? Date()
        let elapsedSeconds = Date().timeIntervalSince(shownAt)
        let elapsedNanoseconds = UInt64(max(0, elapsedSeconds) * 1_000_000_000)
        let remainingNanoseconds = minimumVisibleNanoseconds > elapsedNanoseconds
            ? (minimumVisibleNanoseconds - elapsedNanoseconds)
            : 0
        hideVisibilityTask = Task { @MainActor in
            if remainingNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: remainingNanoseconds)
            }
            if Task.isCancelled { return }
            guard !latestIsLoading else { return }
            isVisible = false
            visibleSince = nil
        }
    }

    @MainActor
    private func cancelVisibilityWork() {
        showVisibilityTask?.cancel()
        showVisibilityTask = nil
        hideVisibilityTask?.cancel()
        hideVisibilityTask = nil
    }

    @MainActor
    private func syncStatusDisplay() {
        cancelShowWork()

        // If loading just turned off, immediately clear any lingering status text
        // to prevent heartbeats from logging stale “Loading reader mode…” messages.
        if !isLoading {
            cancelHideWork()
            if displayedMessage != nil || isShowingStatus {
                debugPrint(
                    "# READER overlay.complete",
                    "context=\(context)",
                    "messageCleared",
                    "isLoading=\(isLoading)"
                )
            }
            displayedMessage = nil
            isShowingStatus = false
            stopHeartbeat()
            return
        }

        // Avoid flashing the status message during short loading pulses by only
        // showing status while the overlay is actually visible (debounced).
        guard isVisible else {
            cancelHideWork()
            if displayedMessage != nil || isShowingStatus {
                displayedMessage = nil
                isShowingStatus = false
            }
            return
        }

        let trimmedMessage = statusMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasMessage = !(trimmedMessage?.isEmpty ?? true)

        if hasMessage, let message = trimmedMessage {
            cancelHideWork()
            let sameMessage = displayedMessage == message
            displayedMessage = message

            if sameMessage && (isShowingStatus || showWorkItem != nil) {
                return
            }

            debugPrint(
                "# READER overlay.status",
                "context=\(context)",
                "action=show",
                "message=\(message)",
                "isLoading=\(isLoading)"
            )
            debugPrint(
                "# FLASH overlay.status",
                "context=\(context)",
                "action=show",
                "message=\(message)",
                "isLoading=\(isLoading)"
            )
            let workItem = DispatchWorkItem {
                guard latestIsLoading, isVisible else { return }
                isShowingStatus = true
            }
            showWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250), execute: workItem)
        } else {
            if displayedMessage != nil {
                debugPrint(
                    "# READER overlay.status",
                    "context=\(context)",
                    "action=hide",
                    "message=\(displayedMessage ?? "")",
                    "isLoading=\(isLoading)"
                )
                debugPrint(
                    "# FLASH overlay.status",
                    "context=\(context)",
                    "action=hide",
                    "message=\(displayedMessage ?? "")",
                    "isLoading=\(isLoading)"
                )
            }
            scheduleHide()
        }
    }

    @MainActor
    private func scheduleHide() {
        cancelHideWork()

        guard isShowingStatus || displayedMessage != nil else { return }

        let workItem = DispatchWorkItem {
            isShowingStatus = false
            displayedMessage = nil
            debugPrint(
                "# READER overlay.complete",
                "context=\(context)",
                "messageCleared",
                "isLoading=\(isLoading)"
            )
            debugPrint(
                "# FLASH overlay.complete",
                "context=\(context)",
                "messageCleared",
                "isLoading=\(isLoading)"
            )
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250), execute: workItem)
    }

    @MainActor
    private func cancelShowWork() {
        showWorkItem?.cancel()
        showWorkItem = nil
    }

    @MainActor
    private func cancelHideWork() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
    }

    @MainActor
    private func cancelAllWork() {
        cancelShowWork()
        cancelHideWork()
    }

    @MainActor
    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if Task.isCancelled { break }
                // When loading is false, reflect that in the log by suppressing any stale status text.
                let activeMessage: String
                if isLoading || isShowingStatus {
                    activeMessage = displayedMessage ?? statusMessage ?? "<none>"
                } else {
                    activeMessage = "<none>"
                }
                debugPrint(
                    "# READER overlay.heartbeat",
                    "context=\(context)",
                    "isLoading=\(isLoading)",
                    "isShowingStatus=\(isShowingStatus)",
                    "message=\(activeMessage)"
                )
                debugPrint(
                    "# FLASH overlay.heartbeat",
                    "context=\(context)",
                    "isLoading=\(isLoading)",
                    "isShowingStatus=\(isShowingStatus)",
                    "message=\(activeMessage)"
                )
            }
        }
    }

    @MainActor
    private func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }
}
