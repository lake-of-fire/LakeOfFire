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

    @State private var isShowingStatus = false
    @State private var statusWorkItem: DispatchWorkItem?

    var body: some View {
        ZStack {
            Rectangle()
                .fill(overlayColor)
            VStack(spacing: 12) {
                ProgressView()
                    .tint(.secondary)
                    .delayedAppearance()
                Group {
                    if let message = statusMessage, !message.isEmpty {
                        Text(message)
                            .font(.callout)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                            .opacity(isShowingStatus ? 1 : 0)
                            .scaleEffect(isShowingStatus ? 1 : 0.98)
                    } else {
                        Spacer()
                            .frame(height: 0)
                    }
                }
                .frame(minHeight: 24)
                .animation(.easeInOut(duration: 0.2), value: isShowingStatus)
            }
        }
        .ignoresSafeArea(.all)
        .opacity(isLoading ? 1 : 0)
        .allowsHitTesting(isLoading)
        .animation(.easeInOut(duration: 0.2), value: isLoading)
        .animation(.easeInOut(duration: 0.2), value: isShowingStatus)
        .onChange(of: isLoading) { newValue in
            if newValue {
                scheduleStatus()
            } else {
                cancelStatus()
            }
        }
        .onChange(of: statusMessage) { _ in
            scheduleStatus()
        }
        .onAppear {
            if isLoading {
                scheduleStatus()
            }
        }
        .onDisappear {
            cancelStatus()
        }
    }

    private var overlayColor: Color {
        colorScheme == .dark ? .black : .white
    }

    @MainActor
    private func scheduleStatus() {
        cancelStatus()
        guard isLoading, let message = statusMessage, !message.isEmpty else {
            isShowingStatus = false
            return
        }

        let workItem = DispatchWorkItem { isShowingStatus = true }
        statusWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250), execute: workItem)
    }

    @MainActor
    private func cancelStatus() {
        statusWorkItem?.cancel()
        statusWorkItem = nil
        isShowingStatus = false
    }
}
