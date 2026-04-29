import SwiftUI
import SwiftUIWebView
import LakeOfFireContent

public struct ReaderModeButton: View {
    @EnvironmentObject private var readerContent: ReaderContent
    @EnvironmentObject private var readerModeViewModel: ReaderModeViewModel
    @EnvironmentObject private var scriptCaller: WebViewScriptCaller
    private let title: String
    private let systemImage: String

    public var body: some View {
        Button {
            readerModeViewModel.showReaderView(
                readerContent: readerContent,
                scriptCaller: scriptCaller
            )
        } label: {
            Label(title, systemImage: systemImage)
        }
    }

    public init(title: String = "Show Reader", systemImage: String = "doc.plaintext") {
        self.title = title
        self.systemImage = systemImage
    }
}
