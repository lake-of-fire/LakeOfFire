import Foundation
import WebKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUIWebView

public struct Readability {
    public static let shared = Readability()
    
    public let userScriptSource: String
    public let css: String
    public let scripts: String
    
    public init(meaningfulContentMinChars: Int = 1) {
        var readabilityJS: String
        var readabilityInitializationJS: String
        var domPurifyJS: String
        var readabilityImagesJS: String
        var readabilityOriginalJS: String
        
        var mozillaCSS: String
        var swiftReadabilityCSS: String
        
        do {
            mozillaCSS = try loadFile(name: "Reader", type: "css")
            swiftReadabilityCSS = try loadFile(name: "SwiftReadability", type: "css")
            
            readabilityJS = try loadFile(name: "Readability", type: "js")
            domPurifyJS = try loadFile(name: "dompurify.min", type: "js")
            readabilityInitializationJS = try loadFile(name: "readability_initialization.template", type: "js")
            readabilityOriginalJS = try loadFile(name: "readability_view_original", type: "js")
        } catch {
            fatalError("Couldn't load Readability scripts. \(error)")
        }
        scripts = readabilityOriginalJS
//        let regex = try! NSRegularExpression(pattern: "(\\|`|[$])", options: [])
//        let range = NSRange(location: 0, length: scripts.utf16.count)
//        let escapedScripts = regex.stringByReplacingMatches(in: scripts, options: [], range: range, withTemplate: "\\$1")

        css = mozillaCSS + swiftReadabilityCSS
        
        readabilityInitializationJS = readabilityInitializationJS
            .replacingOccurrences(of: "##CHAR_THRESHOLD##", with: String(meaningfulContentMinChars))
            .replacingOccurrences(of: "##CSS##", with: css)
//            .replacingOccurrences(of: "##SCRIPT##", with: escapedScripts)
            .replacingOccurrences(of: "##SCRIPT##", with: scripts)
        
        userScriptSource = readabilityJS + domPurifyJS + readabilityInitializationJS
    }
    
    public var userScript: WebViewUserScript {
        WebViewUserScript(
            source: userScriptSource,
//            injectionTime: .atDocumentStart,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false,
            in: .page,
            allowedDomains: Set()
        )
    }
}
