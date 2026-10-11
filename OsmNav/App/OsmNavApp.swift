import SwiftUI

@main
struct OsmNavApp: App {
    @StateObject private var settings: AppSettings
    @StateObject private var model: AppModel

    init() {
        // Sprachwahl auch für Widgets/Teilen-Erweiterung ablegen.
        UserDefaults(suiteName: NavWidgetStore.appGroup)?.set(AppLanguage.selected.rawValue, forKey: AppLanguage.settingsKey)
        // Netzwerk-Einstellungen für MapLibre (User-Agent, Offline-Sperre) vor allem anderen.
        MapController.configureNetwork()
        let settings = AppSettings()
        _settings = StateObject(wrappedValue: settings)
        _model = StateObject(wrappedValue: AppModel(settings: settings))
        // Offline-Suchdaten (mit Adressen) im Hintergrund vorladen.
        OfflinePlacesStore.shared.warmUp()
        // Siri kennt die Favoriten-Namen („Navigiere mit LumoGo zu Arbeit“) — bei Änderungen neu melden.
        FavoritesStore.onChange = { LumoGoShortcuts.updateAppShortcutParameters() }
        LumoGoShortcuts.updateAppShortcutParameters()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .modifier(TextTint(settings: settings))
                .environmentObject(settings)
                .environmentObject(model)
                .preferredColorScheme(settings.mapTheme.colorScheme)
        }
    }
}

/**
 * Systemfarbe `tint` (Text-Knöpfe wie „Fertig“, Links, Schalter, Auswahl) — NICHT direkt die
 * Oberflächenfarbe: Weiß/Gelb machte sonst Schrift auf hellem Hintergrund unsichtbar. Gefüllte
 * Knöpfe bekommen die Oberflächenfarbe selbst (siehe `ProminentButtonStyle`).
 */
private struct TextTint: ViewModifier {
    @ObservedObject var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.tint(Color(hex: settings.textTintHex(dark: colorScheme == .dark)))
    }
}
