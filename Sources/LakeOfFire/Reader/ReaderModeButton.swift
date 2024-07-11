import SwiftUI

public struct ReaderModeButton: View {
    @EnvironmentObject private var readerContent: ReaderContent
    @EnvironmentObject private var readerModeViewModel: ReaderModeViewModel

    public var body: some View {
        Button {
            readerModeViewModel.showReaderView(content: readerContent.content)
        } label: {
            Label("Reader Mode", systemImage: "doc.plaintext")
        }
    }
    
    public init() { }
}
