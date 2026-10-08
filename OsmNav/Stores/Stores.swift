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
    /** Nach jeder Änderung (die App aktualisiert damit die Siri-Favoriten). */
    static var onChange: (() -> Void)?

    private static func save(_ favorites: [Favorite]) {
        DefaultsCodable.save(key, favorites)
        onChange?()
    }

    static func list() -> [Favorite] {
        let favorites: [Favorite] = DefaultsCodable.load(key)
        return favorites.filter(\.isHome) + favorites.filter { !$0.isHome }
    }

    static func add(name: String, point: LatLon) {
        save(list() + [Favorite(id: UUID().uuidString, name: name, point: point, isHome: false)])
    }

    static func remove(id: String) {
        save(list().filter { $0.id != id })
    }

    static func home() -> Favorite? { list().first(where: \.isHome) }

    /** Setzt [point]/[name] als Zuhause — ersetzt einen zuvor gesetzten Zuhause-Eintrag. */
    static func setHome(name: String, point: LatLon) {
        save(list().filter { !$0.isHome } + [Favorite(id: homeId, name: name, point: point, isHome: true)])
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

/** Ein Halt einer gespeicherten Route. */
struct SavedStop: Codable, Hashable {
    let label: String
    let lat: Double
    let lon: Double
    var point: LatLon { LatLon(lat, lon) }
}

/** Gespeicherte Route: Ziele in Reihenfolge + Profil, oder eine GPX-Tour ([tourId]). */
struct SavedRoute: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    let stops: [SavedStop]
    let profile: String
    /** Gesetzt bei GPX-Touren (Spur in [TourStore]). */
    var tourId: String?
    let createdAt: Date

    var isTour: Bool { tourId != nil }
}

/** Gespeicherte Routen und Touren (neueste zuerst). Touren-Spuren als Dateien, siehe [TourStore]. */
enum SavedRoutesStore {
    private static let key = "osmnav_saved_routes"

    static func list() -> [SavedRoute] {
        let routes: [SavedRoute] = DefaultsCodable.load(key)
        return routes.sorted { $0.createdAt > $1.createdAt }
    }

    static func add(_ route: SavedRoute) {
        DefaultsCodable.save(key, [route] + list().filter { $0.id != route.id })
    }

    static func rename(id: String, to name: String) {
        DefaultsCodable.save(key, list().map { var r = $0; if r.id == id { r.name = name }; return r })
    }

    static func remove(id: String) {
        let all = list()
        if let tourId = all.first(where: { $0.id == id })?.tourId { TourStore.delete(id: tourId) }
        DefaultsCodable.save(key, all.filter { $0.id != id })
    }
}

/** GPX-Touren als JSON-Dateien (Spuren mit Tausenden Punkten gehören nicht in UserDefaults). */
enum TourStore {
    private static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("tours", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static func file(_ id: String) -> URL { directory.appendingPathComponent("\(id).json") }

    static func save(_ tour: Tour) { try? JSONEncoder().encode(tour).write(to: file(tour.id), options: .atomic) }

    static func load(id: String) -> Tour? {
        guard let data = try? Data(contentsOf: file(id)) else { return nil }
        return try? JSONDecoder().decode(Tour.self, from: data)
    }

    static func delete(id: String) { try? FileManager.default.removeItem(at: file(id)) }
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
        let all = (list() + [trip]).sorted { $0.timestamp > $1.timestamp }
        DefaultsCodable.save(key, Array(all.prefix(maxEntries)))
        // Herausgefallene Fahrten: Strecken-Dateien mit löschen.
        all.dropFirst(maxEntries).forEach { TripTrackStore.delete(tripId: $0.id) }
    }

    static func remove(id: String) {
        DefaultsCodable.save(key, list().filter { $0.id != id })
        TripTrackStore.delete(tripId: id)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
        TripTrackStore.deleteAll()
    }
}

/** Aufgezeichnete Strecken der Fahrten — eine JSON-Datei je Fahrt (nicht in UserDefaults: 200 Fahrten
 *  mit je Tausenden Punkten wären dort zu groß). */
enum TripTrackStore {
    private static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("trip_tracks", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static func file(_ tripId: String) -> URL { directory.appendingPathComponent("\(tripId).json") }

    static func save(tripId: String, points: [TrackPoint]) {
        try? JSONEncoder().encode(points).write(to: file(tripId), options: .atomic)
    }

    static func load(tripId: String) -> [TrackPoint] {
        guard let data = try? Data(contentsOf: file(tripId)) else { return [] }
        return (try? JSONDecoder().decode([TrackPoint].self, from: data)) ?? []
    }

    static func delete(tripId: String) { try? FileManager.default.removeItem(at: file(tripId)) }

    static func deleteAll() {
        for url in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: url)
        }
    }
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

    /** Ein Ort samt vorbereiteten Suchwörtern (normalisiert, siehe [normalizedWords]). */
    private struct Entry {
        let place: OverpassPlace
        let words: [String]
        let nameWords: [String]
        /** Name ohne Wortgrenzen („robertboschstr7“) — für zusammengeschriebene Eingaben. */
        let joinedName: String
    }

    /** Dekodierte Pakete im Speicher — mit Adressen sind das schnell 100.000 Einträge, die nicht
     *  bei jedem Tastendruck neu aus JSON gelesen werden sollen. */
    private var cache: [String: [Entry]] = [:]
    /** Anzahl je Paket (für die Paketliste, ohne die Suchwörter aufzubereiten). */
    private var counts: [String: Int] = [:]
    private let lock = NSLock()

    private func file(_ regionId: String) -> URL { directory.appendingPathComponent("\(regionId).json") }

    func replace(regionId: String, places: [OverpassPlace]) {
        try? JSONEncoder().encode(places).write(to: file(regionId), options: .atomic)
        lock.lock(); cache[regionId] = nil; counts[regionId] = places.count; lock.unlock()
    }

    func delete(regionId: String) {
        try? FileManager.default.removeItem(at: file(regionId))
        lock.lock(); cache[regionId] = nil; counts[regionId] = nil; lock.unlock()
    }

    func count(regionId: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        if let count = counts[regionId] ?? cache[regionId]?.count { return count }
        guard let data = try? Data(contentsOf: file(regionId)),
              let places = try? JSONDecoder().decode([OverpassPlace].self, from: data) else { return 0 }
        counts[regionId] = places.count
        return places.count
    }

    /** Lädt alle Pakete im Hintergrund in den Speicher, damit schon die erste Offline-Suche flott ist
     *  (≈ 40.000 Einträge aufbereiten dauert sonst beim ersten Tastendruck über eine Sekunde). */
    func warmUp() {
        DispatchQueue.global(qos: .utility).async {
            guard let files = try? FileManager.default.contentsOfDirectory(at: self.directory, includingPropertiesForKeys: nil) else { return }
            for url in files where url.pathExtension == "json" { _ = self.entries(url.deletingPathExtension().lastPathComponent) }
        }
    }

    private func entries(_ regionId: String) -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        if let cached = cache[regionId] { return cached }
        guard let data = try? Data(contentsOf: file(regionId)),
              let places = try? JSONDecoder().decode([OverpassPlace].self, from: data) else { return [] }
        // Auch ältere, schon gespeicherte Daten von Nur-Nummer-Namen („4“, „Q-3“, „4 12“) befreien.
        let loaded = places.filter { TilePlacesBuilder.isSearchableName($0.name) }.map { place in
            let nameWords = Self.normalizedWords(place.name)
            return Entry(place: place, words: nameWords + Self.normalizedWords(place.locality ?? ""), nameWords: nameWords,
                         joinedName: nameWords.joined())
        }
        cache[regionId] = loaded
        return loaded
    }

    /** Zahlwörter 1–99 in normalisierter Schreibweise („funf“, „dreissig“) → Ziffern. */
    private static let numberWords: [String: String] = {
        let units = ["eins", "zwei", "drei", "vier", "funf", "sechs", "sieben", "acht", "neun"]
        let teens = ["zehn", "elf", "zwolf", "dreizehn", "vierzehn", "funfzehn", "sechzehn", "siebzehn", "achtzehn", "neunzehn"]
        let tens = ["zwanzig", "dreissig", "vierzig", "funfzig", "sechzig", "siebzig", "achtzig", "neunzig"]
        var words: [String: String] = ["ein": "1", "eine": "1"]
        for (i, w) in units.enumerated() { words[w] = "\(i + 1)" }
        for (i, w) in teens.enumerated() { words[w] = "\(i + 10)" }
        for (t, ten) in tens.enumerated() {
            words[ten] = "\((t + 2) * 10)"
            for (u, unit) in units.enumerated() {
                words[(u == 0 ? "ein" : unit) + "und" + ten] = "\((t + 2) * 10 + u + 1)"
            }
        }
        return words
    }()

    /** Ziffern für ein Zahlwort; ab 5 Buchstaben ist ein Tippfehler erlaubt („siben“ → 7). */
    static func numberWord(_ word: String) -> String? {
        if let exact = numberWords[word] { return exact }
        guard word.count >= 5 else { return nil }
        return numberWords.first { abs($0.key.count - word.count) <= 1 && editDistanceIsAtMostOne($0.key, word) }?.value
    }

    private static func editDistanceIsAtMostOne(_ a: String, _ b: String) -> Bool {
        let a = Array(a), b = Array(b)
        var i = 0, j = 0, edits = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] { i += 1; j += 1; continue }
            edits += 1
            if edits > 1 { return false }
            if a.count > b.count { i += 1 } else if b.count > a.count { j += 1 } else { i += 1; j += 1 }
        }
        return edits + (a.count - i) + (b.count - j) <= 1
    }

    /**
     * Kleinschreibung, ohne Akzente, ß → ss, Wortende „strasse“ → „str“, Satzzeichen weg — damit
     * „Wilsdruffer Str. 12“, „wilsdruffer straße 12“ und „Hauptstr 3“ gleich gefunden werden.
     */
    static func normalizedWords(_ text: String) -> [String] {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de_DE"))
            .replacingOccurrences(of: "ß", with: "ss")
        var words: [String] = []
        for raw in folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            var word = String(raw)
            for suffix in ["strasse", "str"] where word.hasSuffix(suffix) {
                word = String(word.dropLast(suffix.count)) + "str"
                break
            }
            words.append(word)
        }
        return words
    }

    /**
     * Jedes Suchwort muss am Anfang eines Wortes von Name oder Ort stehen (Tippen von „haupt“ findet
     * schon „Hauptstraße“); Wörter ab 4 Zeichen dürfen auch mitten im Wort stehen, und zusammen-
     * geschriebene Eingaben („robertboschstraße“) passen auf den Namen ohne Wortgrenzen. Reihenfolge:
     * exakter Name (ggf. + Ort) → Name beginnt mit dem Suchtext → Rest; innerhalb davon nach
     * Entfernung zu [near] (sonst kürzere Namen zuerst). So kommt „Hauptstraße 12“ vor „… 120“.
     * Findet sich nichts, wird es mit ausgeschriebenen Zahlen als Ziffern erneut versucht
     * („Robert-Bosch-Straße sieben“, auch mit einem Tippfehler wie „siben“).
     */
    func search(_ query: String, near: LatLon? = nil, limit: Int = 20) -> [SearchResult] {
        let tokens = Self.normalizedWords(query)
        let results = search(tokens: tokens, near: near, limit: limit)
        if !results.isEmpty { return results }
        // Erst jetzt Zahlwörter umwandeln — sonst würde z.B. „neue“ (≈ „neun“) zur 9.
        let numeric = tokens.enumerated().map { $0.offset > 0 ? (Self.numberWord($0.element) ?? $0.element) : $0.element }
        return numeric == tokens ? [] : search(tokens: numeric, near: near, limit: limit)
    }

    private func search(tokens: [String], near: LatLon?, limit: Int) -> [SearchResult] {
        guard !tokens.isEmpty,
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        let joinedTokens = tokens.joined()
        var matches: [(entry: Entry, score: Int)] = []
        for url in files where url.pathExtension == "json" {
            for entry in entries(url.deletingPathExtension().lastPathComponent) {
                guard tokens.allSatisfy({ token in
                    entry.words.contains { $0.hasPrefix(token) || (token.count >= 4 && $0.contains(token)) }
                        || (token.count >= 6 && entry.joinedName.contains(token))
                }) else { continue }
                let tier: Int
                if entry.nameWords == tokens || joinedTokens == entry.joinedName
                    || (tokens.count > entry.nameWords.count && Array(tokens.prefix(entry.nameWords.count)) == entry.nameWords) {
                    tier = 0
                } else if entry.joinedName.hasPrefix(tokens[0]) {
                    tier = 1
                } else {
                    tier = 2
                }
                let secondary = near.map { Int(GeoUtils.distanceMeters($0, LatLon(entry.place.lat, entry.place.lon))) } ?? entry.place.name.count
                matches.append((entry, tier * 100_000_000 + min(secondary, 99_999_999)))
                if matches.count >= 2000 { break }
            }
        }
        var seen = Set<String>()
        return matches.sorted { $0.score < $1.score }.compactMap { match -> SearchResult? in
            let place = match.entry.place
            let name = place.locality.map { "\(place.name) (\($0))" } ?? place.name
            guard seen.insert(name).inserted else { return nil }
            return SearchResult(displayName: name, lat: place.lat, lon: place.lon, boundingBox: nil)
        }.prefix(limit).map { $0 }
    }
}
