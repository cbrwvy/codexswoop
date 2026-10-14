import Foundation

public enum AppLanguage: String, CaseIterable, Sendable {
    case system, english = "en", russian = "ru", uzbek = "uz-Latn"
    public var title: String {
        switch self {
        case .system: L10n.text("language.system")
        case .english: "English"
        case .russian: "Русский"
        case .uzbek: "O‘zbekcha"
        }
    }
}

/// A compiled, complete catalog is shared by SwiftUI, native dialogs and core errors.
/// Locale selection is per app; it never rewrites AppleLanguages or system preferences.
public enum L10n {
    public static let preferenceKey = "interfaceLanguage"
    public static let changed = Notification.Name("CodexSwoopLanguageChanged")
    private static let session = LanguageSession()
    public static var language: AppLanguage {
        if let selected = session.get() { return selected }
        return AppLanguage(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "system") ?? .system
    }
    public static var locale: Locale { Locale(identifier: resolve(language, preferred: Locale.preferredLanguages)) }
    public static func resolve(_ selection: AppLanguage, preferred: [String]) -> String {
        if selection != .system { return selection.rawValue }
        guard let first = preferred.first?.lowercased().replacingOccurrences(of: "_", with: "-") else { return "en" }
        if first == "ru" || first.hasPrefix("ru-") { return "ru" }
        if first == "uz" || first == "uz-latn" || first.hasPrefix("uz-latn-") || first == "uz-uz" { return "uz-Latn" }
        return "en"
    }
    public static func setSessionLanguage(_ value: AppLanguage) {
        session.set(value)
        NotificationCenter.default.post(name: changed, object: nil)
    }
    public static func select(_ value: AppLanguage) {
        UserDefaults.standard.set(value.rawValue, forKey: preferenceKey)
        setSessionLanguage(value)
    }
    public static func text(_ key: String, _ arguments: CustomStringConvertible...) -> String {
        format(key, locale: locale.identifier, arguments: arguments.map(\.description))
    }
    public static func plural(_ key: String, count: Int) -> String {
        format(key, locale: locale.identifier, arguments: [String(count)], count: count)
    }
    public static func format(_ key: String, locale: String, arguments: [String] = [], count: Int? = nil) -> String {
        let resolved = resolve(.system, preferred: [locale])
        let form: String
        if let count {
            if resolved == "ru" {
                let n = abs(count % 100), unit = n % 10
                form = unit == 1 && n != 11 ? "one" : ((2...4).contains(unit) && !(12...14).contains(n) ? "few" : "many")
            } else { form = count == 1 ? "one" : "other" }
        } else { form = "other" }
        guard let entry = catalog[key] else { return key }
        let selected = entry[resolved] ?? entry["en"] ?? [:]
        var output = selected[form] ?? selected["other"] ?? entry["en"]?["other"] ?? key
        // Single-pass substitution prevents a profile name containing {1} being interpreted as a template.
        let regex = try! NSRegularExpression(pattern: #"\{([0-9]+)\}"#)
        let original = output as NSString
        for match in regex.matches(in: output, range: NSRange(location: 0, length: original.length)).reversed() {
            guard let index = Int(original.substring(with: match.range(at: 1))), arguments.indices.contains(index),
                  let range = Range(match.range, in: output) else { continue }
            output.replaceSubrange(range, with: arguments[index])
        }
        return output
    }
}

private final class LanguageSession: @unchecked Sendable {
    private let lock = NSLock()
    private var selection: AppLanguage?
    func get() -> AppLanguage? { lock.lock(); defer { lock.unlock() }; return selection }
    func set(_ value: AppLanguage) { lock.lock(); defer { lock.unlock() }; selection = value }
}
