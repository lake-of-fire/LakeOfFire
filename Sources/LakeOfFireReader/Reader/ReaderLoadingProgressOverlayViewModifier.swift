import SwiftUI
import LakeOfFireWeb
import LakeOfFireFiles
import LakeOfFireContentUI
import LakeOfFireContent
import LakeOfFireCore

public struct ReaderLoadingProgressOverlayViewModifier: ViewModifier {
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
    private let heartbeatLoggingEnabled = ProcessInfo.processInfo.environment["MANABI_READER_OVERLAY_HEARTBEAT"] == "1"

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
    @State private var statusDisplayGeneration = 0

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
            lastLoggedEmission = OverlayEmission(
                isLoading: newValue,
                statusMessage: newValue ? statusMessage : nil
            )
            if newValue {
                startHeartbeat()
            } else {
                stopHeartbeat()
            }
            syncVisibility()
            syncStatusDisplay()
        }
        .onChange(of: statusMessage) { _ in
            latestStatusMessage = statusMessage
            syncStatusDisplay()
        }
        .onChange(of: isVisible) { _ in
            syncStatusDisplay()
        }
        .onAppear {
            latestIsLoading = isLoading
            latestStatusMessage = statusMessage
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
        statusDisplayGeneration &+= 1
        let generation = statusDisplayGeneration
        cancelShowWork()

        if !latestIsLoading {
            cancelHideWork()
            if displayedMessage != nil || isShowingStatus {
                debugPrint(
                    "# READERLOAD stage=overlay.complete",
                    "context=\(context)",
                    "messageCleared",
                    "isLoading=\(latestIsLoading)"
                )
            }
            displayedMessage = nil
            isShowingStatus = false
            stopHeartbeat()
            return
        }

        let trimmedMessage = latestStatusMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasMessage = !(trimmedMessage?.isEmpty ?? true)

        if !hasMessage, displayedMessage != nil, !isVisible {
            cancelHideWork()
            displayedMessage = nil
            isShowingStatus = false
            return
        }

        guard isVisible else {
            return
        }

        if hasMessage, let message = trimmedMessage {
            cancelHideWork()
            let sameMessage = displayedMessage == message
            displayedMessage = message

            if sameMessage && (isShowingStatus || showWorkItem != nil) {
                return
            }

            let workItem = DispatchWorkItem {
                guard generation == statusDisplayGeneration,
                      latestIsLoading,
                      isVisible,
                      displayedMessage == message else { return }
                debugPrint(
                    "# READERLOAD stage=overlay.status",
                    "context=\(context)",
                    "action=show",
                    "message=\(message)",
                    "isLoading=\(latestIsLoading)"
                )
                isShowingStatus = true
            }
            showWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250), execute: workItem)
        } else {
            if displayedMessage != nil {
                scheduleHide()
                return
            }
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
                "# READERLOAD stage=overlay.complete",
                "context=\(context)",
                "messageCleared",
                "isLoading=\(latestIsLoading)"
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
        guard heartbeatLoggingEnabled else { return }
        heartbeatTask?.cancel()
        heartbeatTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if Task.isCancelled { break }
                let activeMessage: String
                if latestIsLoading || isShowingStatus {
                    activeMessage = displayedMessage ?? latestStatusMessage ?? "<none>"
                } else {
                    activeMessage = "<none>"
                }
                debugPrint(
                    "# READERLOAD stage=overlay.heartbeat",
                    "context=\(context)",
                    "isLoading=\(latestIsLoading)",
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
