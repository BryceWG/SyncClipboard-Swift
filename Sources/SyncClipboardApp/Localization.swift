import Foundation

/// Thin wrapper over the main bundle's Localizable.strings.
/// Keys are the English source strings; zh-Hans translations live in
/// `Resources/zh-Hans.lproj/Localizable.strings`.
enum L10n {
    static func tr(_ key: String) -> String {
        NSLocalizedString(key, bundle: .main, comment: "")
    }
}
