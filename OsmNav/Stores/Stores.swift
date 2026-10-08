import Foundation

/** Kleiner Helfer: Codable-Listen in UserDefaults (Ersatz für JSON-in-SharedPreferences). */
private enum DefaultsCodable {
    static func load<T: Decodable>(_ key: String) -> [T] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let value = try? JSONDecoder().decode([T].self, from: data) else { return [] }
        return value
    }

    static func save<T: Encodable>(_ key: String, _ value: [T]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: key)
    }
}

/** Gespeicherte Orte (Favoriten + höchstens ein "Zuhause", steht immer oben). */
enum FavoritesStore {
    private static let key = "osmnav_favorites"
    private static let homeId = "home"

    static func list() -> [Favorite] {
        let favorites: [Favorite] = DefaultsCodable.load(key)
        return favorites.filter(\.isHome) + favorites.filter { !$0.isHome }
    }

    static func add(name: String, point: LatLon) {
        DefaultsCodable.save(key, list() + [Favorite(id: UUID().uuidString, name: name, point: point, isHome: false)])
    }

    static func remove(id: String) {
        DefaultsCodable.save(key, list().filter { $0.id != id })
    }

    static func home() -> Favorite? { list().first(where: \.isHome) }

    /** Setzt [point]/[name] als Zuhause — ersetzt einen zuvor gesetzten Zuhause-Eintrag. */
    static func setHome(name: String, point: LatLon) {
        DefaultsCodable.save(key, list().filter { !$0.isHome } + [Favorite(id: homeId, name: name, point: point, isHome: true)])
    }

    /** Export-Format kompatibel zur Android-App (`name`/`lat`/`lon`/`isHome`). */
    static func exportJson() -> Data {
        let array = list().map { ["name": $0.name, "lat": $0.point.latitude, "lon": $0.point.longitude, "isHome": $0.isHome] as [String: Any] }
        return (try? JSONSerialization.data(withJSONObject: array, options: [.prettyPrinted])) ?? Data("[]".utf8)
    }

    /** Ergänzt die Liste (überschreibt nichts); ein importiertes "Zuhause" nur, wenn noch keins
     *  gesetzt ist. Gibt die Anzahl importierter Einträge zurück. */
    static func importJson(_ data: Data) throws -> Int {
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw AppError.parse }
        var imported = 0
        for obj in array {
            guard let name = obj["name"] as? String, let lat = obj["lat"] as? Double, let lon = obj["lon"] as? Double else { continue }
            if (obj["isHome"] as? Bool ?? false) && home() == nil {
                setHome(name: name, point: LatLon(lat, lon))
            } else {
                add(name: name, point: LatLon(lat, lon))
            }
            imported += 1
        }
        return imported
    }
}

/** Zuletzt ausgewählte Suchergebnisse (neueste zuerst, max. 8, ohne Duplikate). */
enum RecentSearchesStore {
    private static let key = "osmnav_recent_searches"
    private static let maxEntries = 8

    static func list() -> [SearchResult] { DefaultsCodable.load(key) }

    static func add(_ result: SearchResult) {
        let deduped = list().filter { $0 != result }
        DefaultsCodable.save(key, Array(([result] + deduped).prefix(maxEntries)))
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}

/** Fahrtenbuch — abgeschlossene Fahrten, neueste zuerst, max. 200. */
enum TripHistoryStore {
    private static let key = "osmnav_trips"
    private static let maxEntries = 200

    static func list() -> [Trip] {
        let trips: [Trip] = DefaultsCodable.load(key)
        return trips.sorted { $0.timestamp > $1.timestamp }
    }

    static func add(_ trip: Trip) {
        DefaultsCodable.save(key, Array((list() + [trip]).sorted { $0.timestamp > $1.timestamp }.prefix(maxEntries)))
    }

    static func remove(id: String) {
        DefaultsCodable.save(key, list().filter { $0.id != id })
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}

/**
 * Offline-Suchdatenbank: benannte Orte/POIs je heruntergeladenem Kartenpaket (beim Download per
 * Overpass geholt). Eine JSON-Datei pro Paket in Application Support — für die typischen
 * Datenmengen (einige tausend Einträge je Landkreis) reicht eine lineare Suche völlig.
 */
final class OfflinePlacesStore {
    static let shared = OfflinePlacesStore()

    private let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("offline_places", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private func file(_ regionId: String) -> URL { directory.appendingPathComponent("\(regionId).json") }

    func replace(regionId: String, places: [OverpassPlace]) {
        try? JSONEncoder().encode(places).write(to: file(regionId), options: .atomic)
    }

    func delete(regionId: String) {
        try? FileManager.default.removeItem(at: file(regionId))
    }

    func count(regionId: String) -> Int {
        guard let data = try? Data(contentsOf: file(regionId)),
              let places = try? JSONDecoder().decode([OverpassPlace].self, from: data) else { return 0 }
        return places.count
    }

    func search(_ query: String, limit: Int = 20) -> [SearchResult] {
        let needle = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        guard !needle.isEmpty,
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        var results: [SearchResult] = []
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let places = try? JSONDecoder().decode([OverpassPlace].self, from: data) else { continue }
            for place in places where place.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).contains(needle) {
                let name = place.locality.map { "\(place.name) (\($0))" } ?? place.name
                results.append(SearchResult(displayName: name, lat: place.lat, lon: place.lon, boundingBox: nil))
                if results.count >= limit { return results }
            }
        }
        return results
    }
}
