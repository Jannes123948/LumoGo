import ActivityKit
import Foundation

/**
 * Live-Aktivität der Navigation (Sperrbildschirm + Dynamic Island) — von App UND Widget-Erweiterung
 * genutzt (Ordner `Shared/` gehört zu beiden Targets). Farben kommen als feste Werte mit, weil die
 * Erweiterung die Einstellungen der App nicht lesen kann (keine App Group).
 */
struct NavActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var distanceText: String
        var instruction: String
        /** SF-Symbol des Manövers + Drehung (wie im HUD). */
        var symbolName: String
        var symbolRotation: Double
        var etaText: String
        var remainingText: String
        var arrived: Bool
    }

    var destinationName: String
    /** Hintergrund/Schrift der Navigationsleisten (0xRRGGBB, wie in Design & Farben). */
    var backgroundHex: Int
    var textHex: Int
}
