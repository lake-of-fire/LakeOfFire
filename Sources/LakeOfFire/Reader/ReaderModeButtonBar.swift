import SwiftUI
import LakeKit

public struct ReaderModeButtonBar: View {
    @EnvironmentObject private var readerContent: ReaderContent
    @EnvironmentObject private var readerModeViewModel: ReaderModeViewModel

    public init() { }
    
    public var body: some View {
        //        ZStack {
        HStack {
            ReaderModeButton()
//                .padding(.horizontal, 44)
                .padding(.leading, 5)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            
            DismissButton(.xMark) {
                Task { @MainActor in
                    guard let content = readerContent.content else { return }
                    try await readerModeViewModel.hideReaderModeButtonBar(content: content)
                }
            }
        }
        .padding(2)
    }
}
