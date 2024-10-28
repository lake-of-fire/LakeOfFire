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
    
    public init() { }
    
    @MainActor
    public func onNavigationCommitted(content: any ReaderContentProtocol, newState: WebViewState) async throws {
        let voiceAudioURLs = Array(content.voiceAudioURLs)
        if !newState.pageURL.isNativeReaderView, newState.pageURL.host != nil, !newState.pageURL.isFileURL {
            if voiceAudioURLs != audioURLs {
                audioURLs = voiceAudioURLs
            }
            if !voiceAudioURLs.isEmpty {
                isMediaPlayerPresented = true
            }
        } else if newState.pageURL.isNativeReaderView {
            Task { @MainActor [weak self] in
                try Task.checkCancellation()
                guard let self = self else { return }
                if self.isMediaPlayerPresented {
                    self.isMediaPlayerPresented = false
                    audioURLs.removeAll()
                }
            }
        }
    }
}
