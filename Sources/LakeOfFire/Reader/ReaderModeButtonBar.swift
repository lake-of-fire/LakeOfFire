import SwiftUI
import LakeKit

struct ReaderModeButtonBar: View {
    @ObservedObject var readerViewModel: ReaderViewModel
    
    var body: some View {
        ZStack {
            Group {
                ReaderModeButton(readerViewModel: readerViewModel)
                    .labelStyle(.titleOnly)
                    .padding(.horizontal, 44)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                
                HStack {
                    Spacer(minLength: 0)
                    DismissButton(.xMark) {
                        Task { @MainActor in
                            try await readerViewModel.hideReaderModeButtonBar()
                        }
                    }
                }
            }
            .padding(8)
        }
        .frame(maxWidth: .infinity)
    }
}
