import SwiftUI
import SwiftUIWebView
import SwiftSoup
import RealmSwift
import Combine
import RealmSwiftGaps
import WebKit

@MainActor
public class ReaderMediaPlayerViewModel: ObservableObject {
    @Published public var isMediaPlayerPresented = false
    @Published public var audioURLs = [URL]()
    @Published public var isPlaying = false
    
    public init() { }
    
    @MainActor
    public func onNavigationCommitted(content: any ReaderContentProtocol, newState: WebViewState) async throws {
        let voiceAudioURLs = Array(content.voiceAudioURLs)
#if DEBUG
        debugPrint(
            "# AUDIO ReaderMediaPlayerViewModel.onNavigationCommitted url=\(newState.pageURL.absoluteString) voiceCount=\(voiceAudioURLs.count) host=\(newState.pageURL.host ?? "nil") isReaderMode=\(newState.pageURL.isNativeReaderView)"
        )
#endif
        if !newState.pageURL.isNativeReaderView, newState.pageURL.host != nil, !newState.pageURL.isFileURL {
            if voiceAudioURLs != audioURLs {
#if DEBUG
                debugPrint(
                    "# AUDIO ReaderMediaPlayerViewModel.audioURLsUpdated old=\(audioURLs.map { $0.absoluteString }) new=\(voiceAudioURLs.map { $0.absoluteString })"
                )
#endif
                audioURLs = voiceAudioURLs
            }
            if !voiceAudioURLs.isEmpty {
#if DEBUG
                if !isMediaPlayerPresented {
                    debugPrint("# AUDIO ReaderMediaPlayerViewModel.presentingNowPlaying reason=navigation voiceCount=\(voiceAudioURLs.count)")
                }
#endif
                isMediaPlayerPresented = true
            }
        } else if newState.pageURL.isNativeReaderView {
            Task { @MainActor [weak self] in
                try Task.checkCancellation()
                guard let self = self else { return }
                if self.isMediaPlayerPresented {
#if DEBUG
                    debugPrint("# AUDIO ReaderMediaPlayerViewModel.dismissNowPlaying reason=readerMode")
#endif
                    self.isMediaPlayerPresented = false
                }
                if !audioURLs.isEmpty {
#if DEBUG
                    debugPrint("# AUDIO ReaderMediaPlayerViewModel.audioURLsCleared reason=readerMode")
#endif
                    audioURLs.removeAll()
                }
            }
        }
    }
}
