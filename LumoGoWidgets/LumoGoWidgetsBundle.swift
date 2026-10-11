import SwiftUI
import WidgetKit

/** Widget-Erweiterung von LumoGo: Navigations-Widget, Navigation auf Sperrbildschirm/Dynamic Island, Schnellzugriff. */
@main
struct LumoGoWidgetsBundle: WidgetBundle {
    init() {
        // Sprache der App übernehmen (wirkt beim nächsten Start der Erweiterung).
        AppLanguage.syncFromAppGroup()
    }

    var body: some Widget {
        NavigationWidget()
        QuickActionsWidget()
        NavLiveActivityWidget()
    }
}

extension Color {
    /** 0xRRGGBB — eigene Kopie, die Erweiterung hat die Farbhelfer der App nicht. */
    init(widgetHex hex: Int) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/** Markenfarben wie das App-Symbol (dunkelblauer Verlauf, cyan Pfeil). */
enum Brand {
    static let top = Color(red: 0.05, green: 0.16, blue: 0.36)
    static let bottom = Color(red: 0.02, green: 0.07, blue: 0.18)
    static let glow = Color(red: 0.55, green: 0.92, blue: 1.0)
}
