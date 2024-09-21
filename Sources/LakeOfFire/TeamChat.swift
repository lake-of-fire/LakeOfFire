import SwiftUI
import SwiftUIWebView

public struct TeamChatLink: View {
    public let url: URL
    public var teamName = ""
    
    @AppStorage("appTint") private var appTint: Color = Color("AccentColor")
    @Environment(\.openURL) private var openURL
    
    public var body: some View {
//        Link(destination: url) { Label("Chat With Team\(teamName.isEmpty ? "" : " \(teamName)")", systemImage: "message") }
        Button {
            openURL(url)
        } label: {
            Label("Chat With Team\(teamName.isEmpty ? "" : " \(teamName)")", systemImage: "message")
        }
        .buttonStyle(.borderless)
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
        .buttonStyle(.borderless)
    }
    
    public init(teamName: String = "") {
        self.teamName = teamName
    }
}

public struct TeamChat: View {
    public let url: URL
    
    @StateObject private var webNavigator = WebViewNavigator()
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
