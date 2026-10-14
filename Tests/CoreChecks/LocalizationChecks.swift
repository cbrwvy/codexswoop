import Foundation
import CodexSwoopCore

extension CoreChecks {
    @MainActor static func localizationChecks(run: @MainActor (String, @MainActor () async throws -> Void) async -> Void) async {
        for (selection, preferred, expected) in [
            (AppLanguage.system, ["ru-RU"], "ru"), (.system, ["uz-Latn-UZ"], "uz-Latn"),
            (.system, ["uz-UZ"], "uz-Latn"), (.system, ["uz-Cyrl"], "en"),
            (.system, ["fr-FR"], "en"), (.system, [], "en"), (.english, ["ru"], "en"),
            (.russian, ["en"], "ru"), (.uzbek, ["en"], "uz-Latn")
        ] {
            await run("Localization: \(selection)/\(preferred)") { try expect(L10n.resolve(selection, preferred: preferred) == expected, "Exact supported locale/fallback") }
        }
        await run("Localization: parameters preserve profile names, paths, UUIDs and braces") {
            let value = "Fictional User {1} /private/tmp/x UUID"
            let text = L10n.format("message.0394db2a65", locale: "ru", arguments: [value])
            try expect(text == "Удалить «\(value)»?", "One-pass parameter substitution")
        }
        await run("Localization: Russian plural rules and Uzbek Latin") {
            for (count, word) in [(1,"аккаунт"),(2,"аккаунта"),(5,"аккаунтов"),(11,"аккаунтов"),(21,"аккаунт")] {
                try expect(L10n.format("account.count", locale: "ru", arguments: [String(count)], count: count) == "\(count) \(word)", "Russian plural form")
            }
            try expect(L10n.format("menu.add", locale: "uz-Latn") == "Hisob qo‘shish", "Uzbek Latin")
        }
        await run("Localization: unsupported locale uses English; missing key stays visible") {
            try expect(L10n.format("menu.add", locale: "xx-ZZ") == "Add Account", "English fallback")
            try expect(L10n.format("missing.fixture", locale: "ru") == "missing.fixture", "Missing key exposed")
        }
        await run("Localization: selection persists in isolated preferences") {
            let id = "codexswoop-fixture-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: id)!
            defer { defaults.removePersistentDomain(forName: id) }
            defaults.set(AppLanguage.uzbek.rawValue, forKey: L10n.preferenceKey)
            try expect(UserDefaults(suiteName: id)?.string(forKey: L10n.preferenceKey) == "uz-Latn", "Restart persistence")
        }
        await run("Localization: live selection updates warnings and errors without changing raw identifiers") {
            defer { L10n.setSessionLanguage(.english) }
            let english = EnvironmentError.unsafeDirectory.errorDescription
            L10n.setSessionLanguage(.russian)
            try expect(EnvironmentError.unsafeDirectory.errorDescription != english && AccountOpeningMode.openSeparately.title == "Открыть отдельно", "Dynamic error and action")
            L10n.setSessionLanguage(.uzbek)
            try expect(AccountOpeningMode.openSeparately.title == "Alohida ochish" && UsageStatus.unavailable.rawValue == "Unavailable", "Raw protocol/status values preserved")
        }
    }
}
