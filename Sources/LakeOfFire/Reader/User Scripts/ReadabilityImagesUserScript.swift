import Foundation
import WebKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUIWebView

public struct ReadabilityImagesUserScript {
    public static let shared = ReadabilityImagesUserScript()
    
    public let userScriptSource: String
    
    public init(meaningfulContentMinChars: Int = 1) {
        var readabilityImagesJS: String
        
        do {
            readabilityImagesJS = try loadFile(name: "readability_images", type: "js")
        } catch {
            fatalError("Couldn't load Readability scripts. \(error)")
        }
        
        userScriptSource = readabilityImagesJS
    }
    
    public var userScript: WebViewUserScript {
        WebViewUserScript(
            source: userScriptSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: .page,
            allowedDomains: Set()
        )
    }
}
