import Foundation

/** Ein benannter Ort/POI aus einer Overpass-Antwort. [locality] (aus `addr:city`/`town`/
 *  `village`/`suburb`) hilft, gleichnamige Treffer zu unterscheiden. */
struct OverpassPlace: Codable, Hashable {
    let name: String
    let lat: Double
    let lon: Double
    var locality: String?
    /** Roher OSM-Tag `opening_hours` (optional — ältere gespeicherte Offline-Daten haben ihn nicht). */
    var openingHours: String?

    /** "Geöffnet"/"Geschlossen" für Ergebnislisten, nil ohne (verständliche) Öffnungszeiten. */
    var openStatusText: String? {
        guard UserDefaults.standard.object(forKey: "show_open_status") as? Bool ?? true,
              let raw = openingHours, let hours = OpeningHours.parse(raw) else { return nil }
        let status = hours.status()
        if hours.isAlwaysOpen { return "24 h geöffnet" }
        return status.isOpen ? (status.changesSoon ? "schließt bald" : "geöffnet") : "geschlossen"
    }
}

/**
 * Fragt den öffentlichen Overpass-API-Server (OSM-Rohdaten) ab: benannte Orte für die
 * Offline-Suche, Kategorie-Umkreissuche ("In der Nähe") und POI-/Markennamensuche.
 */
enum OverpassClient {

    private static let baseUrl = URL(string: "https://overpass-api.de/api/interpreter")!
    private static let session = HTTP.session(requestTimeout: 90)
    private static let defaultRetryCount = 3
    private static let retryDelaySeconds: UInt64 = 5

    /** Orte/POIs mit Namen für die Offline-Suche — bewusst OHNE Straßen und Hausadressen
     *  (würden die Abfrage auf dem öffentlichen Server unzuverlässig machen). */
    static func fetchNamedPlaces(_ bbox: BoundingBox) async throws -> [OverpassPlace] {
        let b = "\(bbox.south),\(bbox.west),\(bbox.north),\(bbox.east)"
        let keys = ["place", "amenity", "shop", "tourism", "leisure", "office", "craft", "historic", "railway", "natural", "aeroway"]
        let statements = keys.map { "  node[\"name\"][\"\($0)\"](\(b));" }.joined(separator: "\n")
        let query = "[out:json][timeout:60];\n(\n\(statements)\n);\nout center;"
        return try await execute(query, fallbackName: nil, retryCount: defaultRetryCount)
    }

    /** Umkreissuche für eine feste POI-Kategorie ("In der Nähe"); mehrere [tags] = ODER. */
    static func fetchNearby(center: LatLon, radiusMeters: Int, tags: [(String, String)], fallbackName: String) async throws -> [OverpassPlace] {
        let around = "around:\(radiusMeters),\(center.latitude),\(center.longitude)"
        let statements = tags.map { key, value in
            "  node[\"\(key)\"=\"\(value)\"](\(around));\n  way[\"\(key)\"=\"\(value)\"](\(around));"
        }.joined(separator: "\n")
        let query = "[out:json][timeout:25];\n(\n\(statements)\n);\nout center;"
        return try await execute(query, fallbackName: fallbackName, retryCount: defaultRetryCount)
    }

    /** Namenssuche (Ketten/Marken, die Nominatim oft nicht findet). Nur ein Versuch: läuft bei
     *  jeder Live-Suchtippunterbrechung, Retry-Pausen würden die Suche spürbar verzögern. */
    static func searchByName(_ query: String, bbox: BoundingBox) async throws -> [OverpassPlace] {
        let b = "\(bbox.south),\(bbox.west),\(bbox.north),\(bbox.east)"
        let regex = fuzzyNameRegex(query)
        guard !regex.isEmpty else { return [] }
        let q = "[out:json][timeout:25];\n(\n  node[\"name\"~\"\(regex)\",i](\(b));\n  way[\"name\"~\"\(regex)\",i](\(b));\n);\nout center;"
        return try await execute(q, fallbackName: nil, retryCount: 1)
    }

    /**
     * Großzügige Regex: zwischen je zwei Buchstaben darf optional ein Apostroph stehen
     * (`mcdonalds` soll `McDonald's` finden), zwischen Wörtern beliebige Zeichen. Sonderzeichen
     * werden entfernt statt escaped — vermeidet Escaping-Probleme im Overpass-QL-Stringliteral.
     */
    private static func fuzzyNameRegex(_ query: String) -> String {
        query.split(whereSeparator: { $0.isWhitespace })
            .map { word in word.filter { $0.isLetter || $0.isNumber }.map(String.init).joined(separator: "'?") }
            .filter { !$0.isEmpty }
            .joined(separator: ".*")
    }

    private static func execute(_ query: String, fallbackName: String?, retryCount: Int) async throws -> [OverpassPlace] {
        try parse(try await rawQuery(query, retryCount: retryCount), fallbackName: fallbackName)
    }

    /**
     * Wann ist beim Server wieder ein Abfrage-Platz frei? Liest `/api/status` ("3 slots available
     * now" → 0, "Slot available after: …, in 34 seconds." → 34). nil = unbekannt.
     */
    static func suggestedWaitSeconds() async -> UInt64? {
        let url = URL(string: "https://overpass-api.de/api/status")!
        guard let data = try? await HTTP.data(statusSession, for: URLRequest(url: url)),
              let text = String(data: data, encoding: .utf8) else { return nil }
        if text.range(of: "slots? available now", options: .regularExpression) != nil { return 0 }
        let waits = text.matches(of: /in (\d+) seconds/).compactMap { UInt64($0.1) }
        return waits.min()
    }

    private static let statusSession = HTTP.session(requestTimeout: 8)

    /** Rohe JSON-Antwort einer Overpass-Abfrage (z.B. Straßennetz fürs Offline-Routing). */
    static func rawQuery(_ query: String, retryCount: Int = defaultRetryCount) async throws -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = "data=" + (query.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        var request = URLRequest(url: baseUrl)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body.data(using: .utf8)

        var lastError: Error = AppError.parse
        // Der öffentliche Server meldet bei Last 5xx — ein, zwei Versuche mit Pause reichen meist.
        for attempt in 0..<retryCount {
            do {
                return try await HTTP.data(session, for: request)
            } catch {
                if Task.isCancelled { throw error }
                lastError = error
            }
            if attempt < retryCount - 1 {
                try await Task.sleep(nanoseconds: retryDelaySeconds * 1_000_000_000)
            }
        }
        throw lastError
    }

    private static func parse(_ data: Data, fallbackName: String?) throws -> [OverpassPlace] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let elements = root["elements"] as? [[String: Any]] else { throw AppError.parse }
        return elements.compactMap { el in
            guard let tags = el["tags"] as? [String: String] else { return nil }
            func tag(_ key: String) -> String? {
                guard let v = tags[key], !v.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
                return v
            }
            guard let name = tag("name") ?? tag("brand") ?? tag("operator") ?? addressName(tag) ?? fallbackName else { return nil }

            let lat: Double
            let lon: Double
            if let la = el["lat"] as? Double, let lo = el["lon"] as? Double {
                lat = la; lon = lo
            } else if let center = el["center"] as? [String: Any], let la = center["lat"] as? Double, let lo = center["lon"] as? Double {
                lat = la; lon = lo
            } else {
                return nil
            }
            let locality = tag("addr:city") ?? tag("addr:town") ?? tag("addr:village") ?? tag("addr:suburb")
            return OverpassPlace(name: name, lat: lat, lon: lon, locality: locality, openingHours: tag("opening_hours"))
        }
    }

    private static func addressName(_ tag: (String) -> String?) -> String? {
        guard let street = tag("addr:street") else { return nil }
        if let number = tag("addr:housenumber") { return "\(street) \(number)" }
        return street
    }
}
