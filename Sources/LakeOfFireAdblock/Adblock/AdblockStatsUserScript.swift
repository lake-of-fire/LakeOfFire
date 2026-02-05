import Foundation
import SwiftUIWebView
import WebKit

public struct AdblockStatsUserScript {
    public static let shared = AdblockStatsUserScript()
    public static let handlerName = "adblockStats"
    public static let securityToken = UUID().uuidString

    public let userScript: WebViewUserScript

    public init() {
        let source = Self.loadScript(named: "TrackingProtectionStats")
        let secured = Self.secureScript(
            handlerName: Self.handlerName,
            securityToken: Self.securityToken,
            script: source
        )
        self.userScript = WebViewUserScript(
            source: secured,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: .page,
            allowedDomains: Set()
        )
    }

    public static func isValidMessageBody(_ body: Any) -> Bool {
        (body as? [String: Any])?["securityToken"] as? String == securityToken
    }

    private static var resourceBundle: Bundle {
#if SWIFT_PACKAGE
        return .module
#else
        return Bundle(for: BundleLocator.self)
#endif
    }

    private final class BundleLocator { }

    private static func loadScript(named name: String) -> String {
        guard let url = resourceBundle.url(
            forResource: name,
            withExtension: "js",
            subdirectory: "User Scripts"
        ) else {
            print("# AdblockStatsUserScript missing script: \(name).js")
            return ""
        }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            print("# AdblockStatsUserScript failed to load \(name).js: \(error)")
            return ""
        }
    }

    private static func secureScript(
        handlerName: String,
        securityToken: String,
        script: String
    ) -> String {
        guard !script.isEmpty else { return script }

        var script = script
        script = script.replacingOccurrences(of: "$<message_handler>", with: handlerName)

        let handlerFreeze = """
        (function() {
            if (!window.webkit || !webkit.messageHandlers) { return; }
            const handler = webkit.messageHandlers['\(handlerName)'];
            if (handler && handler.postMessage) {
                Object.freeze(handler);
                Object.freeze(handler.postMessage);
            }
        })();
        """

        return """
        (function() {
            const SECURITY_TOKEN = '\(securityToken)';
            \(handlerFreeze)
            \(script)
        })();
        """
    }
}
