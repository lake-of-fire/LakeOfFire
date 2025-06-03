import Foundation
import WebKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUIWebView

public struct ReaderConsoleLogsUserScript {
    public static let shared = ReaderConsoleLogsUserScript()
    
    private static let errorScript = """
        if (location.protocol !== "blob:" && location.protocol !== "ebook:") {
            window.onerror = function (msg, source, lineno, colno, error) {
                window.webkit.messageHandlers.readerOnError?.postMessage({
                    "message": msg,
                    "source": source,
                    "lineno": lineno,
                    "colno": colno,
                    "error": event.reason?.stack ?? String(event.reason)
                });
            };

            window.onunhandledrejection = function (event) {
                window.webkit.messageHandlers.readerOnError?.postMessage({
                    message: event.reason?.message ?? "Unhandled rejection",
                    source: null,
                    lineno: null,
                    colno: null,
                    error: event.reason?.stack ?? String(event.reason)
                });
            };
        }
        """
    
    //    private static let logScript = """
    //        (function() {
    //            let old = {};
    //
    //            let appLog = function(severity, args) {
    //                window.webkit.messageHandlers.log.postMessage({
    //                    "severity": severity,
    //                    "arguments": (args.length < 2) ? args[0] : Array.from(args)
    //                });
    //            };
    //
    //            ["log", "debug", "info", "warn", "error"].forEach(function(fn) {
    //                old[fn] = console[fn];
    //
    //                console[fn] = function() {
    //                    old[fn].apply(null, arguments);
    //
    //                    appLog(fn, arguments);
    //                };
    //            });
    //        })();
    //    """
    
    public init() { }
    
    public var userScript: WebViewUserScript {
        WebViewUserScript(
            source: Self.errorScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: .page,
            allowedDomains: Set()
        )
    }
}
