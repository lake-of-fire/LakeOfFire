import SwiftUI

public struct ReaderModeButtonBar: View {
    @EnvironmentObject private var readerContent: ReaderContent
    @EnvironmentObject private var readerModeViewModel: ReaderModeViewModel

    public init() { }
    
    public var body: some View {
        ReaderToastBar(
            isPresented: {
                guard let content = readerContent.content else { return false }
                return readerModeViewModel.isReaderModeButtonBarVisible(content: content)
            },
            onDismiss: {
                Task { @MainActor in
                    guard let content = readerContent.content else { return }
                    try await readerModeViewModel.hideReaderModeButtonBar(content: content)
                }
            }) {
                ReaderModeButton()
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
    }
}
