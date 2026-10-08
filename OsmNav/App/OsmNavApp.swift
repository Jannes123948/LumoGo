import SwiftUI

@main
struct OsmNavApp: App {
    @StateObject private var settings: AppSettings
    @StateObject private var model: AppModel

    init() {
        // Netzwerk-Einstellungen für MapLibre (User-Agent, Offline-Sperre) vor allem anderen.
        MapController.configureNetwork()
        let settings = AppSettings()
        _settings = StateObject(wrappedValue: settings)
        _model = StateObject(wrappedValue: AppModel(settings: settings))
        // Offline-Suchdaten (mit Adressen) im Hintergrund vorladen.
        OfflinePlacesStore.shared.warmUp()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .environmentObject(model)
                .tint(settings.accent)
                .preferredColorScheme(settings.mapTheme.colorScheme)
        }
    }
}
