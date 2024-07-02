import SwiftUI
import LakeKit

public struct ReaderModeButtonBar: View {
    @EnvironmentObject private var readerViewModel: ReaderViewModel
    
    public init() { }
    
    public var body: some View {
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

//    public var body: some View {
//        ZStack {
//            Group {
//                ReaderModeButton(readerViewModel: readerViewModel)
//                    .labelStyle(.titleOnly)
//                    .padding(.horizontal, 44)
//                    .buttonStyle(.borderedProminent)
//                    .controlSize(.regular)
//                
//                HStack {
//                    Spacer(minLength: 0)
//                    DismissButton(.xMark) {
//                        Task { @MainActor in
//                            try await readerViewModel.hideReaderModeButtonBar()
//                        }
//                    }
//                }
//            }
//            .padding(8)
//        }
//        .frame(maxWidth: .infinity)
//    }
}
