import SwiftUI

// TODO: Instead of layering this across eg Reader and ManabiReader, have it once and use environment to set its activation (or similar)
public struct ReaderLoadingProgressOverlayViewModifier: ViewModifier {
    // For some reason it doesn't always redraw if simply let isLoading: Bool
    let isLoading: Bool
    let statusMessage: String?
    let context: String

    public init(isLoading: Bool, statusMessage: String? = nil, context: String = "ReaderOverlay") {
        self.isLoading = isLoading
        self.statusMessage = statusMessage
        self.context = context
    }

    public func body(content: Content) -> some View {
        content
            .overlay {
                ReaderLoadingOverlay(isLoading: isLoading, statusMessage: statusMessage, context: context)
            }
    }
}

private struct ReaderLoadingOverlay: View {
    let isLoading: Bool
    let statusMessage: String?
    let context: String

    @Environment(\.colorScheme) private var colorScheme

    private struct OverlayEmission: Equatable {
        let isLoading: Bool
        let statusMessage: String?
    }

    @State private var displayedMessage: String?
    @State private var isShowingStatus = false
    @State private var showWorkItem: DispatchWorkItem?
    @State private var hideWorkItem: DispatchWorkItem?
    @State private var heartbeatTask: Task<Void, Never>?
    @State private var lastLoggedEmission: OverlayEmission?

    var body: some View {
        ZStack {
            Rectangle()
                .fill(overlayColor)
            VStack(spacing: 12) {
                ProgressView()
                    .tint(.secondary)
                    .delayedAppearance()
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
        .opacity(isLoading ? 1 : 0)
        .allowsHitTesting(isLoading)
        .animation(.easeInOut(duration: 0.2), value: isShowingStatus)
        .onChange(of: isLoading) { newValue in
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
            }
            if newValue { startHeartbeat() } else { stopHeartbeat() }
            syncStatusDisplay()
        }
        .onChange(of: statusMessage) { _ in
            syncStatusDisplay()
        }
        .onAppear {
            debugPrint(
                "# FLASH overlay.appear",
                "context=\(context)",
                "isLoading=\(isLoading)",
                "status=\(statusMessage ?? "nil")"
            )
            syncStatusDisplay()
        }
        .onDisappear {
            cancelAllWork()
            displayedMessage = nil
            isShowingStatus = false
            stopHeartbeat()
        }
    }

    private var overlayColor: Color {
        colorScheme == .dark ? .black : .white
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
