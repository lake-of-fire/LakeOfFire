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
import LakeOfFireContent

// TODO: the error messages might not be useful anymore with how we do String()
public struct ReaderConsoleLogsUserScript {
    public static let shared = ReaderConsoleLogsUserScript()
    
    private static let errorScript = """
        if (location.protocol !== "blob:" && location.protocol !== "ebook:") {
            window.onerror = function (msg, source, lineno, colno, error) {
                window.webkit.messageHandlers.readerOnError?.postMessage({
                    "message": String(msg),
                    "source": source != null ? String(source) : null,
                    "lineno": lineno != null ? Number(lineno) : null,
                    "colno": colno != null ? Number(colno) : null,
                    "error": (error && error.stack) ? String(error.stack) : String(error)
                });
            };
        
            window.onunhandledrejection = function (event) {
                window.webkit.messageHandlers.readerOnError?.postMessage({
                    "message": event.reason && event.reason.message ? String(event.reason.message) : "Unhandled rejection",
                    "source": null,
                    "lineno": null,
                    "colno": null,
                    "error": (event.reason && event.reason.stack) ? String(event.reason.stack) : String(event.reason)
                });
            };
        }
        """
    
    private static let logScript = """
        (function() {
            let old = {};
    
            let appLog = function(severity, args) {
                const safeArgs = Array.from(args).map(arg => {
                    const t = typeof arg;
                    return (arg === null || t === "string" || t === "number" || t === "boolean") ? arg : String(arg);
                });
                window.webkit.messageHandlers.readerConsoleLog.postMessage({
                    "severity": severity,
                    "arguments": (safeArgs.length < 2) ? safeArgs[0] : safeArgs
                });
            };
    
            ["log", "debug", "info", "warn", "error"].forEach(function(fn) {
                old[fn] = console[fn];
                console[fn] = function() {
                    old[fn].apply(null, arguments);
                    appLog(fn, arguments);
                };
            });
        })();
    """
    
    public init() { }
    
    public var userScript: WebViewUserScript {
        WebViewUserScript(
            source: Self.errorScript + Self.logScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: .page,
            allowedDomains: Set()
        )
    }
}
