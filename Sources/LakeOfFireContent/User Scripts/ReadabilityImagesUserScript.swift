import Foundation
import WebKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUIWebView
import LakeOfFireCore
import LakeOfFireAdblock

public struct ReadabilityImagesUserScript {
    public static let shared = ReadabilityImagesUserScript()
    
    public let userScriptSource: String
    
    public init(meaningfulContentMinChars: Int = 1) {
        var readabilityImagesJS: String
        
        do {
            readabilityImagesJS = try loadModuleFile(name: "readability_images", type: "js", subdirectory: "User Scripts", in: Bundle.module)
        } catch {
            fatalError("Couldn't load Readability scripts. \(error)")
        }
        
        userScriptSource = readabilityImagesJS
    }
    
    public var userScript: WebViewUserScript {
        WebViewUserScript(
            source: userScriptSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: .page,
            allowedDomains: Set()
        )
    }
}
