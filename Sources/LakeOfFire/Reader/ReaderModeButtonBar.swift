import SwiftUI

public struct ReaderModeButtonBar<C: ReaderContentProtocol>: View {
    @ObservedObject var readerContent: C

//    @EnvironmentObject private var readerContent: ReaderContent
    @EnvironmentObject private var readerModeViewModel: ReaderModeViewModel
    
    public init(readerContent: C) {
        self.readerContent = readerContent
    }
    
    public var body: some View {
        let _ = Self._printChanges()
        ReaderToastBar(
            isPresented: .constant({
                return readerModeViewModel.isReaderModeButtonBarVisible(content: readerContent)
            }()),
            onDismiss: {
                Task { @MainActor in
                    try await readerModeViewModel.hideReaderModeButtonBar(content: readerContent)
                }
            }
        ) {
            ReaderModeButton()
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
    }
}

@available(iOS 16, macOS 13.0, *)
public extension ReaderContentProtocol {
    var readerModeButtonBar: some View {
        ReaderModeButtonBar(readerContent: self)
    }
}
