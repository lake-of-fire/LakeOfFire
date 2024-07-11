import SwiftUI

public struct ReaderModeButton: View {
    @EnvironmentObject private var readerContent: ReaderContent
    @EnvironmentObject private var readerViewModel: ReaderViewModel

    public var body: some View {
        Button {
            readerViewModel.showReaderView(content: readerContent.content)
        } label: {
            Label("Reader Mode", systemImage: "doc.plaintext")
        }
    }
    
    public init() { }
}
