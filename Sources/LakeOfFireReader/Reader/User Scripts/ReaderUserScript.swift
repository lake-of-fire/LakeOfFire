//import Foundation
//import WebKit
//#if os(macOS)
//import AppKit
//#else
//import UIKit
//#endif
//import SwiftUIWebView
//
//public struct ReaderUserScript {
//    public static let shared = ReaderUserScript()
//    
//    public let userScript: WebViewUserScript
//    
//    public init() {
//        var readabilityJS: String
//        var readabilityInitializationJS: String
//        var domPurifyJS: String
//        var readabilityImagesJS: String
//        
//        var mozillaCSS: String
//        var swiftReadabilityCSS: String
//        
//        do {
//            mozillaCSS = try loadFile(name: "Reader", type: "css")
//            swiftReadabilityCSS = try loadFile(name: "SwiftReadability", type: "css")
//            
//            readabilityJS = try loadFile(name: "Readability", type: "js")
//            domPurifyJS = try loadFile(name: "dompurify.min", type: "js")
//            readabilityInitializationJS = try loadFile(name: "readability_initialization.template", type: "js")
//            readabilityImagesJS = try loadFile(name: "readability_images", type: "js")
//            readabilityImagesJS = try loadFile(name: "readability_view_original", type: "js")
//        } catch {
//            fatalError("Couldn't load Readability scripts. \(error)")
//        }
//        let scripts = readabilityImagesJS + additionalJS
////        let regex = try! NSRegularExpression(pattern: "(\\|`|[$])", options: [])
////        let range = NSRange(location: 0, length: scripts.utf16.count)
////        let escapedScripts = regex.stringByReplacingMatches(in: scripts, options: [], range: range, withTemplate: "\\$1")
//
//        readabilityInitializationJS = readabilityInitializationJS
//            .replacingOccurrences(of: "##CHAR_THRESHOLD##", with: String(meaningfulContentMinChars))
//            .replacingOccurrences(of: "##CSS##", with: mozillaCSS + swiftReadabilityCSS + additionalCSS)
////            .replacingOccurrences(of: "##SCRIPT##", with: escapedScripts)
//            .replacingOccurrences(of: "##SCRIPT##", with: scripts)
//        
//        userScriptSource = readabilityJS + domPurifyJS + readabilityInitializationJS
//    }
//    
//    public var userScript: WebViewUserScript {
//        WebViewUserScript(source: userScriptSource, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .page, allowedDomains: Set())
//    }
//}
import LakeOfFireCore
import LakeOfFireAdblock
import LakeOfFireContent
