import Foundation
import LakeOfFireCore
import WebKit
import SwiftUIWebView
import LakeKit

public struct NetflixUserScript {
    public static let shared = ReadabilityImagesUserScript()
    
    public let userScriptSource: String
    
    public init(meaningfulContentMinChars: Int = 1) {
        do {
            userScriptSource = try loadModuleFile(
                name: "netflix",
                type: "js",
                subdirectory: "User Scripts",
                in: .module
            )
        } catch {
            fatalError("Couldn't load user script. \(error)")
        }
    }
    
    public var userScript: WebViewUserScript {
        WebViewUserScript(
            source: userScriptSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: .page,
            allowedDomains: ["www.netflix.com"]
        )
    }
}
