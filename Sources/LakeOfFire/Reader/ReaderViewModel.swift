import SwiftUI
import SwiftUIWebView
import RealmSwift
import Combine

public class ReaderViewModel: NSObject, ObservableObject {
    @Published public var content: (any ReaderContentModel) = ReaderContentLoader.unsavedHome
    @Published var readabilityContent: String? = nil
    @Published var isNextLoadInReaderMode = false
    @Published public var scriptCaller = WebViewScriptCaller()
    @Published var webViewUserScripts =  LibraryConfiguration.shared.activeWebViewUserScripts
    @Published var webViewSystemScripts = LibraryConfiguration.shared.systemScripts
    
    @Published var contentRules: String? = nil
    @Published public var isMediaPlayerPresented = false
    @Published public var audioURLs = [URL]()
    
    private var cancellables = Set<AnyCancellable>()
    
    public var allScripts: [WebViewUserScript] {
        return webViewSystemScripts + webViewUserScripts
    }
    
    public var contentRulesForReadabilityLoading = """
    [\(["image", "style-sheet", "font", "media", "popup", "svg-document", "websocket", "other"].map {
        """
        {
             "trigger": {
                 "url-filter": ".*",
                 "resource-type": ["\($0)"]
             },
             "action": {
                 "type": "block"
             }
         },
        """
    })
    ]
    """
    
    public init(realmConfiguration: Realm.Configuration = Realm.Configuration.defaultConfiguration, systemScripts: [WebViewUserScript]) {
        super.init()
        
        webViewUserScripts = webViewUserScripts + systemScripts
        
        let realm = try! Realm(configuration: realmConfiguration)
        realm.objects(UserScript.self)
            .changesetPublisher
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main, options: .init(qos: .userInitiated))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] changes in
                switch changes {
                case .initial(_):
                    self?.updateScripts()
                case .update(_, deletions: _, insertions: _, modifications: _):
                    self?.updateScripts()
                case .error(let error):
                    print(error.localizedDescription)
                }
            }
            .store(in: &cancellables)
    }
    
    private func updateScripts() {
        Task { @MainActor in
            let scripts = LibraryConfiguration.shared.activeWebViewUserScripts
            if webViewUserScripts != scripts {
                webViewUserScripts = scripts
            }
        }
    }
}
