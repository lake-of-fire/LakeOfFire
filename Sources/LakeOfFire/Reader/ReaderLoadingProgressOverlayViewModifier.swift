import SwiftUI

// TODO: Instead of layering this across eg Reader and ManabiReader, have it once and use environment to set its activation (or similar)
public struct ReaderLoadingProgressOverlayViewModifier: ViewModifier {
    // For some reason it doesn't always redraw if simply let isLoading: Bool
    let isLoading: Bool
    let statusMessage: String?

    public init(isLoading: Bool, statusMessage: String? = nil) {
        self.isLoading = isLoading
        self.statusMessage = statusMessage
    }

    public func body(content: Content) -> some View {
        content
            .overlay {
                ReaderLoadingOverlay(isLoading: isLoading, statusMessage: statusMessage)
            }
    }
}

private struct ReaderLoadingOverlay: View {
    let isLoading: Bool
    let statusMessage: String?

    @Environment(\.colorScheme) private var colorScheme

    @State private var displayedMessage: String?
    @State private var isShowingStatus = false
    @State private var showWorkItem: DispatchWorkItem?
    @State private var hideWorkItem: DispatchWorkItem?

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
        .onChange(of: isLoading) { _ in
            syncStatusDisplay()
        }
        .onChange(of: statusMessage) { _ in
            syncStatusDisplay()
        }
        .onAppear {
            syncStatusDisplay()
        }
        .onDisappear {
            cancelAllWork()
            displayedMessage = nil
            isShowingStatus = false
        }
    }

    private var overlayColor: Color {
        colorScheme == .dark ? .black : .white
    }

    @MainActor
    private func syncStatusDisplay() {
        cancelShowWork()
        let trimmedMessage = statusMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasMessage = isLoading && !(trimmedMessage?.isEmpty ?? true)

        if hasMessage, let message = trimmedMessage {
            cancelHideWork()
            let sameMessage = displayedMessage == message
            displayedMessage = message

            if sameMessage && (isShowingStatus || showWorkItem != nil) {
                return
            }

            let workItem = DispatchWorkItem {
                isShowingStatus = true
            }
            showWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250), execute: workItem)
        } else {
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
}
