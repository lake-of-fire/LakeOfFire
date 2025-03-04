import SwiftUI

public struct ReaderModeButton: View {
    @EnvironmentObject private var readerContent: ReaderContent
    @EnvironmentObject private var readerModeViewModel: ReaderModeViewModel

    public var body: some View {
        Button {
            readerModeViewModel.showReaderView(readerContent: readerContent)
        } label: {
            Label("Show Reader", systemImage: "doc.plaintext")
        }
    }
    
    public init() { }
}
