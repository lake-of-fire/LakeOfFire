import SwiftUI
import SwiftUIWebView
import LakeOfFireCore
import LakeOfFireAdblock
import LakeOfFireContent

public struct ReaderModeButton: View {
    @EnvironmentObject private var readerContent: ReaderContent
    @EnvironmentObject private var readerModeViewModel: ReaderModeViewModel
    @EnvironmentObject private var scriptCaller: WebViewScriptCaller

    public var body: some View {
        Button {
            readerModeViewModel.showReaderView(
                readerContent: readerContent,
                scriptCaller: scriptCaller
            )
        } label: {
            Label("Show Reader", systemImage: "doc.plaintext")
        }
    }
    
    public init() { }
}
