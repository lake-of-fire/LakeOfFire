import SwiftUI

public struct ReaderModeButton: View {
    @ObservedObject var readerViewModel: ReaderViewModel
    
    public var body: some View {
        Button {
            readerViewModel.showReaderView()
        } label: {
            Label("Reader Mode", systemImage: "doc.plaintext")
        }
    }
    
    public init(readerViewModel: ReaderViewModel) {
        self.readerViewModel = readerViewModel
    }
}
