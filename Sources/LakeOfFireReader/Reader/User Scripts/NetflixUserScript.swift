//import Foundation
//import WebKit
//import SwiftUIWebView
//import LakeKit
//
//public struct NetflixUserScript {
//    public static let shared = ReadabilityImagesUserScript()
//    
//    public let userScriptSource: String
//    
//    public init(meaningfulContentMinChars: Int = 1) {
//        do {
//            userScriptSource = try loadModuleFile(name: "netflix", extension: "js", subdirectory: "User Scripts")
//        } catch {
//            fatalError("Couldn't load user script. \(error)")
//        }
//    }
//    
//    public var userScript: WebViewUserScript {
//        WebViewUserScript(
//            source: userScriptSource,
//            injectionTime: .atDocumentStart,
//            forMainFrameOnly: true,
//            in: .page,
//            allowedDomains: ["www.netflix.com"]
//        )
//    }
//}
import LakeOfFireCore
import LakeOfFireAdblock
import LakeOfFireContent
