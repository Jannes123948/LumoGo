import Foundation

/**
 * Navigationszustand für das Navigations-Widget (klein/mittel/groß — Ersatz für Androids Bild-im-Bild).
 * Die App schreibt ihn als JSON in den gemeinsamen Container der App Group, das Widget liest ihn.
 * Ohne App Group (Signierung ohne Fähigkeit) ist [NavWidgetStore.fileURL] nil → alles still aus.
 */
struct NavWidgetState: Codable, Equatable {
    var active: Bool
    var distanceText: String
    var instruction: String
    var symbolName: String
    var symbolRotation: Double
    /** Das Manöver danach (nur wenn bekannt), z.B. „Links abbiegen auf Hauptstraße“. */
    var thenInstruction: String?
    var etaText: String
    var remainingText: String
    var destination: String
    /** Wann die App den Zustand zuletzt geschrieben hat — ist er alt, war die App beendet. */
    var updatedAt: Date
    /** Navi-Leisten-Farben (0xRRGGBB, wie in Design & Farben). */
    var backgroundHex: Int
    var textHex: Int
    var routeHex: Int
    /**
     * Routenlinie in Metern relativ zur eigenen Position, Fahrtrichtung zeigt nach oben (+y = voraus,
     * +x = rechts). Für die schematische Karte — eine echte Karte kann das Widget im Hintergrund nicht
     * bekommen (keine GPU-Nutzung, wenn die App nicht vorne ist).
     */
    var route: [[Double]]
    /** Nächster Manöverpunkt im selben System, nil = außerhalb des Ausschnitts. */
    var maneuver: [Double]?

    static let inactive = NavWidgetState(
        active: false, distanceText: "", instruction: "", symbolName: "arrow.up", symbolRotation: 0,
        thenInstruction: nil, etaText: "", remainingText: "", destination: "", updatedAt: .distantPast,
        backgroundHex: 0x1B5E20, textHex: 0xFFFFFF, routeHex: 0x2962FF, route: [], maneuver: nil
    )
}

enum NavWidgetStore {
    /** Muss in den Entitlements von App UND Erweiterung stehen. */
    static let appGroup = "group.com.jannehorst.osmnav"
    static let widgetKind = "LumoGoNavigation"

    static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("nav_widget_state.json")
    }

    static func load() -> NavWidgetState {
        guard let url = fileURL, let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(NavWidgetState.self, from: data) else { return .inactive }
        return state
    }

    /** false = kein gemeinsamer Container (App Group fehlt). */
    @discardableResult
    static func save(_ state: NavWidgetState) -> Bool {
        guard let url = fileURL, let data = try? JSONEncoder().encode(state) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }
}
