import SwiftUI

public struct TeamChatLink: View {
    public let url: URL
    public var teamName = ""
    
    public var body: some View {
        Link(destination: url) { Label("Chat With Team\(teamName.isEmpty ? "" : " \(teamName)")", systemImage: "message") }
    }
    
    public init(url: URL, teamName: String = "") {
        self.url = url
        self.teamName = teamName
    }
}

@available(macOS 13, iOS 16, *)
public struct TeamChatButton: View {
    public var teamName = ""
    
    @Environment(\.openWindow) private var openWindow
    
    public var body: some View {
        Button {
            openWindow(id: "chat-with-team")
        } label: {
            Label("Chat With Team\(teamName.isEmpty ? "" : " \(teamName)")", systemImage: "message")
        }
    }
    
    public init(teamName: String = "") {
        self.teamName = teamName
    }
}

public struct TeamChat: View {
    public let url: URL
    
    @State private var webNavigator = WebViewNavigator()
    @State private var webState = WebViewState.empty
    
    public var body: some View {
        GeometryReader { geometry in
            WebView(
                config: WebViewConfig(pageZoom: 0.9, userScripts: [
                ]),
                navigator: webNavigator,
                state: $webState,
                //                            scriptCaller: viewModel.resourcesScriptCaller,
                obscuredInsets: geometry.safeAreaInsets)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            webNavigator.load(URLRequest(url: url))
        }
    }
    
    public init(url: URL) {
        self.url = url
    }
}
