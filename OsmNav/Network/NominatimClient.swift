import Foundation

/**
 * Adress-/Ortssuche über den öffentlichen Nominatim-Dienst (OpenStreetMap). Nutzungsrichtlinie
 * verlangt einen eindeutigen User-Agent und max. ~1 Anfrage/Sekunde (500ms-Debounce in der Suche).
 */
enum NominatimClient {

    private static let session = HTTP.session(requestTimeout: 10)

    /**
     * [near] gibt der Suche eine Standort-Vorrangzone (`viewbox`, `bounded=0` — nur Bevorzugung,
     * keine harte Einschränkung), damit z.B. "McDonalds" eine Filiale in der Nähe zuerst zeigt.
     */
    static func search(_ query: String, near: LatLon? = nil) async throws -> [SearchResult] {
        var params: [(String, String)] = [
            ("q", query),
            ("format", "json"),
            ("limit", "6"),
            ("accept-language", "de")
        ]
        if let near {
            let delta = 0.2 // ~20km Vorrangzone
            params.append(("viewbox", "\(near.longitude - delta),\(near.latitude + delta),\(near.longitude + delta),\(near.latitude - delta)"))
            params.append(("bounded", "0"))
        }
        let data = try await HTTP.data(session, for: URLRequest(url: HTTP.url("https://nominatim.openstreetmap.org/search", params)))
        guard let items = try? JSONDecoder().decode([Item].self, from: data) else { throw AppError.parse }
        return items.compactMap { item in
            guard let lat = Double(item.lat), let lon = Double(item.lon) else { return nil }
            // Nominatim liefert [south, north, west, east] als Strings.
            var bbox: BoundingBox?
            if let b = item.boundingbox?.compactMap(Double.init), b.count == 4 {
                bbox = BoundingBox(south: b[0], north: b[1], west: b[2], east: b[3])
            }
            return SearchResult(displayName: item.display_name, lat: lat, lon: lon, boundingBox: bbox)
        }
    }

    private struct Item: Decodable {
        let display_name: String
        let lat: String
        let lon: String
        let boundingbox: [String]?
    }
}
