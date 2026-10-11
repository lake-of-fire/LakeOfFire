import Foundation

#if DEBUG && MANABI_QUALIFICATION
/// Exact packaged Lake resources for mounted WKWebView qualification.
/// This accessor grants no native mutation or account authority.
public enum HostedBookResourceQualification {
    public static func javascript(named name: String) throws -> Data {
        guard !name.contains("/"), !name.contains("..") else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        for directory in ["foliate-js", "Resources/foliate-js", "Resources/Resources/foliate-js"] {
            if let url = Bundle.module.url(forResource: name, withExtension: "js", subdirectory: directory) {
                return try Data(contentsOf: url)
            }
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
#endif
