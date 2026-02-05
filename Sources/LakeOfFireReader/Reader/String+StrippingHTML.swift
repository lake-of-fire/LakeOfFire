import Foundation
import SwiftSoup
import LakeOfFireCore
import LakeOfFireAdblock

public extension String {
    // TODO: move somewhere appropriate
    func strippingHTML() -> String {
        if !contains("<") {
            return self
        }
        if let doc = try? SwiftSoup.parse(self) {
            do {
                doc.outputSettings().prettyPrint(pretty: false)
                let rubyTags = try (doc.body() ?? doc).getElementsByTag(UTF8Arrays.ruby)
                for rubyTag in rubyTags {
                    for tagName in [UTF8Arrays.rp, UTF8Arrays.rt, UTF8Arrays.rtc] {
                        try rubyTag.getElementsByTag(tagName).remove()
                    }
                    let surface = try rubyTag.text(trimAndNormaliseWhitespace: false)
                    
                    try rubyTag.before(surface)
                    try rubyTag.remove()
                }
                return try doc.text(trimAndNormaliseWhitespace: true)
            } catch {
                debugPrint("Error stripping HTML", error)
                return escapeHtml()
            }
        } else {
            return escapeHtml()
        }
    }
}
