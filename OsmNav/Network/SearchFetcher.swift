import Foundation

/**
 * Ergänzt die Nominatim-Suche um eine POI-/Markennamensuche über Overpass — Nominatim findet
 * Kettenfilialen wie "McDonalds" oft gar nicht (`mcdonalds berlin` → 0 Treffer, obwohl Filialen
 * in OSM erfasst sind). Häufigstes Muster "<Marke> <Ort>": letztes Wort als Ort interpretieren
 * und nur in dessen Bounding Box suchen; sonst [near] als Fallback-Umkreis.
 */
enum PoiSearchClient {

    /** 8 km statt früher 50 km — eine ungefilterte Namens-Regex über eine große Fläche läuft
     *  beim öffentlichen Overpass-Server zuverlässig ins Timeout. */
    private static let fallbackRadiusMeters = 8_000.0
    private static let timeoutSeconds = 7.0

    static func search(_ query: String, near: LatLon?) async -> [SearchResult] {
        await withTimeout(seconds: timeoutSeconds) { await searchInternal(query, near: near) } ?? []
    }

    private static func searchInternal(_ query: String, near: LatLon?) async -> [SearchResult] {
        let words = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if words.count >= 2 {
            let brand = words.dropLast().joined(separator: " ")
            let placeName = words.last!
            if let place = try? await NominatimClient.search(placeName).first(where: { $0.boundingBox != nil }),
               let bbox = place.boundingBox,
               let results = try? await OverpassClient.searchByName(brand, bbox: bbox),
               !results.isEmpty {
                return results.map(toSearchResult)
            }
        }
        guard let near else { return [] }
        let bbox = GeoUtils.bboxAround(near, radiusMeters: fallbackRadiusMeters)
        return ((try? await OverpassClient.searchByName(query, bbox: bbox)) ?? []).map(toSearchResult)
    }

    private static func toSearchResult(_ place: OverpassPlace) -> SearchResult {
        var displayName = place.locality.map { "\(place.name) (\($0))" } ?? place.name
        if let status = place.openStatusText { displayName += " · \(status)" }
        return SearchResult(displayName: displayName, lat: place.lat, lon: place.lon, boundingBox: nil)
    }
}

struct SearchFetchResult {
    let results: [SearchResult]
    let usedOfflineSearch: Bool
}

/**
 * Fragt Nominatim UND parallel die POI-Suche an; schlägt beides fehl (kein Internet), wird in der
 * lokalen Offline-Orte-Datenbank gesucht (befüllt beim Offline-Kartendownload).
 */
enum SearchFetcher {

    /** Die POI-Ergänzung (ohne SLA) darf Nominatim nicht blockieren — die Gnadenfrist gilt ab
     *  Suchbeginn, nicht erst ab Nominatims Antwort (sonst summieren sich beide Wartezeiten). */
    private static let poiGracePeriodSeconds = 2.0

    /**
     * Mit [onPartial] erscheinen Nominatims Treffer SOFORT (~0,4 s), die POI-Ergänzung kommt
     * danach (bis zu 7 s, eigenes Limit im [PoiSearchClient]) im Endergebnis dazu — vorher wartete
     * jede Eingabe bis zu 2 s auf Overpass, bevor überhaupt etwas zu sehen war. Ohne [onPartial]
     * gilt weiter die 2-s-Gnadenfrist.
     */
    static func search(_ query: String, near: LatLon?,
                       onPartial: (@MainActor ([SearchResult]) -> Void)? = nil) async throws -> SearchFetchResult {
        let start = Date()
        let poiTask = Task { await PoiSearchClient.search(query, near: near) }
        func poiResults(waitFully: Bool) async -> [SearchResult] {
            if waitFully { return await poiTask.value }
            let remaining = max(0, poiGracePeriodSeconds - Date().timeIntervalSince(start))
            let result = await withTimeout(seconds: remaining) { await poiTask.value }
            if result == nil { poiTask.cancel() }
            return result ?? []
        }

        let onlineError: Error
        do {
            let nominatim = try await NominatimClient.search(query, near: near)
            if let onPartial {
                if Task.isCancelled { poiTask.cancel(); throw CancellationError() }
                await onPartial(nominatim)
            }
            let poi = await withTaskCancellationHandler {
                await poiResults(waitFully: onPartial != nil)
            } onCancel: {
                poiTask.cancel()
            }
            return SearchFetchResult(results: poi + nominatim, usedOfflineSearch: false)
        } catch {
            if Task.isCancelled { poiTask.cancel(); throw error }
            onlineError = error
        }
        let poi = await poiResults(waitFully: false)
        if !poi.isEmpty { return SearchFetchResult(results: poi, usedOfflineSearch: false) }

        var offline = OfflinePlacesStore.shared.search(query)
        if let near {
            offline.sort { GeoUtils.distanceMeters(near, $0.point) < GeoUtils.distanceMeters(near, $1.point) }
        }
        if !offline.isEmpty { return SearchFetchResult(results: offline, usedOfflineSearch: true) }
        throw onlineError
    }
}
