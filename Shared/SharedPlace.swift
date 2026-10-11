import Foundation

/**
 * Ein aus einer anderen App geteilter Ort (Teilen-Erweiterung „LumoGoShare“): entweder mit
 * Koordinaten (Karten-Link) oder nur als Suchtext (Adresse, Name).
 */
struct SharedPlace: Codable, Equatable {
    var latitude: Double?
    var longitude: Double?
    /** Name/Adresse, falls bekannt. */
    var name: String?
    /** Ohne Koordinaten: danach suchen. */
    var query: String?
    var createdAt = Date()

    var hasCoordinate: Bool { latitude != nil && longitude != nil }

    var displayName: String {
        name ?? query ?? latitude.flatMap { lat in longitude.map { String(format: "%.5f, %.5f", lat, $0) } } ?? String(localized: "Ort")
    }
}

/**
 * Übergabe Erweiterung → App über den gemeinsamen Container der App Group (wie das Navigations-
 * Widget). Die Erweiterung legt den Ort ab und öffnet `lumogo://shared`; klappt das Öffnen nicht,
 * holt die App ihn beim nächsten Start ab.
 */
enum SharedPlaceInbox {
    private static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: NavWidgetStore.appGroup)?
            .appendingPathComponent("shared_place.json")
    }

    /** false = kein gemeinsamer Container (App Group fehlt bei der Signierung). */
    @discardableResult
    static func put(_ place: SharedPlace) -> Bool {
        guard let url = fileURL, let data = try? JSONEncoder().encode(place) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    /** Abgelegten Ort holen und löschen; ältere als 30 Minuten verfallen. */
    static func take() -> SharedPlace? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        try? FileManager.default.removeItem(at: url)
        guard let place = try? JSONDecoder().decode(SharedPlace.self, from: data),
              Date().timeIntervalSince(place.createdAt) < 30 * 60 else { return nil }
        return place
    }
}
