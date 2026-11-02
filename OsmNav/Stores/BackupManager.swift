import Foundation

/**
 * Datensicherung als Datei (Ersatz für iCloud): Favoriten, gespeicherte Routen, Fahrtenbuch (ohne
 * aufgezeichnete Strecken), eigene Markierungen und der gemerkte Parkplatz in einer JSON-Datei.
 * Beim Wiederherstellen wird **zusammengeführt** (nichts wird überschrieben oder gelöscht).
 */
enum BackupManager {
    private static let formatVersion = 1
    private static let listKeys = ["osmnav_favorites", "osmnav_saved_routes", "osmnav_trips", MarkerStore.key]
    private static let parkingKey = "osmnav_parked_car"

    struct Summary {
        var favorites = 0, routes = 0, trips = 0, markers = 0, parking = false
        var isEmpty: Bool { favorites + routes + trips + markers == 0 && !parking }
        var text: String {
            var parts: [String] = []
            if favorites > 0 { parts.append(String(localized: "\(favorites) Favoriten")) }
            if routes > 0 { parts.append(String(localized: "\(routes) Routen")) }
            if trips > 0 { parts.append(String(localized: "\(trips) Fahrten")) }
            if markers > 0 { parts.append(String(localized: "\(markers) Markierungen")) }
            if parking { parts.append(String(localized: "Parkplatz")) }
            return parts.joined(separator: ", ")
        }
    }

    // MARK: - Export

    /** Schreibt die Sicherung in eine temporäre Datei (zum Teilen/Speichern über das Teilen-Blatt). */
    static func export() throws -> URL {
        let defaults = UserDefaults.standard
        var root: [String: Any] = ["app": "LumoGo", "version": formatVersion, "created": ISO8601DateFormatter().string(from: Date())]
        for key in listKeys {
            guard let data = defaults.data(forKey: key), let json = try? JSONSerialization.jsonObject(with: data) else { continue }
            // Touren liegen als Dateien vor und gehören nicht in die Sicherung.
            if key == "osmnav_saved_routes", let routes = json as? [[String: Any]] {
                root[key] = routes.filter { $0["tourId"] == nil }
            } else {
                root[key] = json
            }
        }
        if let data = defaults.data(forKey: parkingKey), let json = try? JSONSerialization.jsonObject(with: data) {
            root[parkingKey] = json
        }
        let day = Date().formatted(.iso8601.year().month().day())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LumoGo-Sicherung-\(day).json")
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: - Import

    /** Führt die Sicherung mit den vorhandenen Daten zusammen; gibt zurück, was neu dazukam. */
    @discardableResult
    static func restore(_ data: Data) throws -> Summary {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["app"] as? String == "LumoGo" else { throw AppError.parse }
        var summary = Summary()
        let defaults = UserDefaults.standard

        summary.favorites = try merge(root, "osmnav_favorites", Favorite.self, id: \.id) { _ in }
        summary.routes = try merge(root, "osmnav_saved_routes", SavedRoute.self, id: \.id) { list in
            list.sort { $0.createdAt > $1.createdAt }
        }
        summary.trips = try merge(root, "osmnav_trips", Trip.self, id: \.id) { list in
            list.sort { $0.timestamp > $1.timestamp }
            list = Array(list.prefix(200))
        }
        summary.markers = try merge(root, MarkerStore.key, MapMarker.self, id: \.id) { _ in }

        // Parkplatz: nur übernehmen, wenn er neuer ist als der gemerkte.
        if let json = root[parkingKey], let encoded = try? JSONSerialization.data(withJSONObject: json),
           let backupCar = try? decoder.decode(ParkedCar.self, from: encoded) {
            if ParkingStore.load().map({ backupCar.date > $0.date }) ?? true {
                defaults.set(try encoder.encode(backupCar), forKey: parkingKey)
                ParkingStore.publish(backupCar)
                summary.parking = true
            }
        }

        if summary.favorites > 0 {
            FavoritesStore.onChange?()
            NotificationCenter.default.post(name: FavoritesStore.changed, object: nil)
        }
        NotificationCenter.default.post(name: CloudSync.changed, object: nil)
        return summary
    }

    private static let decoder = JSONDecoder()
    private static let encoder = JSONEncoder()

    /** Fügt die Einträge der Sicherung hinzu, deren ID es noch nicht gibt; Zahl der neuen Einträge. */
    private static func merge<T: Codable>(_ root: [String: Any], _ key: String, _: T.Type, id: (T) -> String,
                                          finish: (inout [T]) -> Void) throws -> Int {
        guard let json = root[key], let data = try? JSONSerialization.data(withJSONObject: json),
              let incoming = try? decoder.decode([T].self, from: data) else { return 0 }
        let local: [T] = UserDefaults.standard.data(forKey: key).flatMap { try? decoder.decode([T].self, from: $0) } ?? []
        let known = Set(local.map(id))
        let added = incoming.filter { !known.contains(id($0)) }
        guard !added.isEmpty else { return 0 }
        var all = local + added
        finish(&all)
        UserDefaults.standard.set(try encoder.encode(all), forKey: key)
        CloudSync.localChanged(key)
        return added.count
    }
}
