import Foundation

/**
 * Sprache der App: wie das iPhone, Deutsch oder Englisch. Umgesetzt über `AppleLanguages` in den
 * eigenen Einstellungen — iOS lädt die Übersetzungen beim nächsten Start der App (bzw. der Widget-/
 * Teilen-Erweiterung, die die Wahl über die App Group übernehmen, siehe [syncFromAppGroup]).
 */
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, de, en
    var id: String { rawValue }

    static let settingsKey = "app_language"

    /** Gespeicherte Wahl (App-Einstellungen, in Erweiterungen aus der App Group). */
    static var selected: AppLanguage {
        let raw = UserDefaults.standard.string(forKey: settingsKey)
            ?? UserDefaults(suiteName: NavWidgetStore.appGroup)?.string(forKey: settingsKey)
        return AppLanguage(rawValue: raw ?? "") ?? .system
    }

    /** Sprache, in der die App gerade WIRKLICH läuft (erst nach Neustart = Wahl). */
    static var isEnglish: Bool {
        forceEnglish ?? (Bundle.main.preferredLocalizations.first?.hasPrefix("en") == true)
    }

    /** Nur für Tests (macOS-Testprogramme ohne App-Bundle). */
    static var forceEnglish: Bool?

    /** „de“/„en“ für Server-Anfragen (Nominatim) und die Stimme. */
    static var code: String { isEnglish ? "en" : "de" }

    static var locale: Locale { Locale(identifier: isEnglish ? "en_GB" : "de_DE") }

    /** Wahl speichern; wirkt ab dem nächsten Start. */
    static func select(_ language: AppLanguage) {
        let defaults = UserDefaults.standard
        defaults.set(language.rawValue, forKey: settingsKey)
        UserDefaults(suiteName: NavWidgetStore.appGroup)?.set(language.rawValue, forKey: settingsKey)
        apply(language, to: defaults)
    }

    /** Erweiterungen: Wahl der App übernehmen (wirkt beim nächsten Start der Erweiterung). */
    static func syncFromAppGroup() {
        guard let raw = UserDefaults(suiteName: NavWidgetStore.appGroup)?.string(forKey: settingsKey),
              let language = AppLanguage(rawValue: raw) else { return }
        apply(language, to: .standard)
    }

    private static func apply(_ language: AppLanguage, to defaults: UserDefaults) {
        switch language {
        case .system: defaults.removeObject(forKey: "AppleLanguages")
        case .de: defaults.set(["de"], forKey: "AppleLanguages")
        case .en: defaults.set(["en"], forKey: "AppleLanguages")
        }
    }
}
