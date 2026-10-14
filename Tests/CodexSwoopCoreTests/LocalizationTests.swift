import XCTest
@testable import CodexSwoopCore

@MainActor
final class LocalizationTests: XCTestCase {
    func testSupportedLocalesFallbackAndPluralForms() {
        XCTAssertEqual(L10n.resolve(.system, preferred: ["ru-RU"]), "ru")
        XCTAssertEqual(L10n.resolve(.system, preferred: ["uz-UZ"]), "uz-Latn")
        XCTAssertEqual(L10n.resolve(.system, preferred: ["uz-Cyrl"]), "en")
        XCTAssertEqual(L10n.format("menu.add", locale: "unknown"), "Add Account")
        for (count, word) in [(1, "аккаунт"), (2, "аккаунта"), (5, "аккаунтов"), (11, "аккаунтов"), (21, "аккаунт")] {
            XCTAssertEqual(L10n.format("account.count", locale: "ru", arguments: [String(count)], count: count), "\(count) \(word)")
        }
        XCTAssertEqual(L10n.format("menu.add", locale: "uz-Latn"), "Hisob qo‘shish")
    }
    func testSubstitutionDoesNotInterpretBracesInProfileName() {
        let name = "Fictional {1} ../profile"
        XCTAssertEqual(L10n.format("message.0394db2a65", locale: "ru", arguments: [name]), "Удалить «\(name)»?")
    }
    func testLanguageSelectionPersistsOnlyInDisposableSuite() throws {
        let name = "codexswoop-xctest-\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { preferences.removePersistentDomain(forName: name) }
        preferences.set(AppLanguage.uzbek.rawValue, forKey: L10n.preferenceKey)
        XCTAssertEqual(UserDefaults(suiteName: name)?.string(forKey: L10n.preferenceKey), "uz-Latn")
    }
}
