import Foundation

/** Kategorien für „Auf der Route suchen“. */
enum AlongRouteCategory: String, CaseIterable, Identifiable {
    case fuel, restArea, supermarket, toilets, food, parking, charging
    var id: String { rawValue }

    var label: String {
        switch self {
        case .fuel: return String(localized: "Tankstelle")
        case .restArea: return String(localized: "Rastplatz")
        case .supermarket: return String(localized: "Supermarkt")
        case .toilets: return String(localized: "Toilette")
        case .food: return String(localized: "Essen")
        case .parking: return String(localized: "Parken")
        case .charging: return String(localized: "Laden")
        }
    }

    var symbol: String {
        switch self {
        case .fuel: return "fuelpump.fill"
        case .restArea: return "cup.and.saucer.fill"
        case .supermarket: return "cart.fill"
        case .toilets: return "toilet.fill"
        case .food: return "fork.knife"
        case .parking: return "parkingsign.circle.fill"
        case .charging: return "bolt.car.fill"
        }
    }

    var tags: [(String, String)] {
        switch self {
        case .fuel: return [("amenity", "fuel")]
        case .restArea: return [("highway", "rest_area"), ("highway", "services")]
        case .supermarket: return [("shop", "supermarket")]
        case .toilets: return [("amenity", "toilets")]
        case .food: return [("amenity", "fast_food"), ("amenity", "restaurant")]
        case .parking: return [("amenity", "parking")]
        case .charging: return [("amenity", "charging_station")]
        }
    }
}

/** Ein Treffer entlang der Route. */
struct AlongRoutePlace: Identifiable, Hashable {
    let id: String
    let name: String
    let point: LatLon
    /** Strecke entlang der Route bis zur Abzweigung (ab aktueller Position bzw. Start). */
    let alongMeters: Double
    /** Abstand von der Route (Luftlinie zum Lot). */
    let offsetMeters: Double
    /** Zusatz: Preis bei Tankerkönig, sonst Öffnungsstatus. */
    let detail: String?
    let price: Double?
    /** Gesetzt bei Tankerkönig-Treffern → Preistafel statt Textzeile. */
    var fuelType: FuelType? = nil

    /** Geschätzter Umweg: hin und zurück mit ≈ 30 km/h auf Nebenstraßen, mindestens 1 Minute. */
    var detourMinutes: Int { max(1, Int((2 * offsetMeters / 8.3 / 60).rounded())) }
}

/**
 * „Auf der Route suchen“: POIs im Korridor um die vor einem liegende Strecke (Overpass `around` an
 * der Polylinie), mit Spritpreisen über Tankerkönig (Abfragen an Punkten entlang der Strecke).
 * Sortiert nach Entfernung entlang der Route.
 */
enum AlongRouteSearch {

    static func search(_ category: AlongRouteCategory, ahead line: [LatLon], corridorMeters: Double,
                       fuel: (key: String, type: FuelType)?) async throws -> [AlongRoutePlace] {
        guard line.count >= 2 else { return [] }
        let cumulative = cumulativeDistances(line)
        if category == .fuel, let fuel {
            // Fehlt Tankerkönig (Netz/Schlüssel), weiter ohne Preise über OpenStreetMap.
            if let priced = try? await fuelWithPrices(line, cumulative: cumulative, corridor: corridorMeters, key: fuel.key, type: fuel.type),
               !priced.isEmpty {
                return priced
            }
        }
        let simplified = simplify(line, cumulative: cumulative, spacing: max(300, (cumulative.last ?? 0) / 90))
        // Etwas breiter fragen: die vereinfachte Linie schneidet Kurven ab; gefiltert wird danach
        // exakt gegen die echte Route.
        let places = try await OverpassClient.fetchAlongLine(simplified, radiusMeters: Int(corridorMeters + 150),
                                                             tags: category.tags, fallbackName: category.label)
        var seen = Set<String>()
        return places.compactMap { place -> AlongRoutePlace? in
            let p = LatLon(place.lat, place.lon)
            let (along, offset) = project(p, onto: line, cumulative: cumulative)
            // Nur was noch vor einem liegt (nicht schon hinter der Position) und im Korridor.
            guard along > 20, offset <= corridorMeters else { return nil }
            let key = "\(place.name)|\(Int(along / 50))"
            guard seen.insert(key).inserted else { return nil }
            let name = place.locality.map { "\(place.name) (\($0))" } ?? place.name
            return AlongRoutePlace(id: "\(place.lat),\(place.lon)", name: name, point: p, alongMeters: along,
                                   offsetMeters: offset, detail: place.openStatusText, price: nil)
        }
        .sorted { $0.alongMeters < $1.alongMeters }
    }

    /** Tankerkönig kennt nur Umkreise: Abfragen an Punkten entlang der Strecke, dann auf den Korridor filtern. */
    private static func fuelWithPrices(_ line: [LatLon], cumulative: [Double], corridor: Double,
                                       key: String, type: FuelType) async throws -> [AlongRoutePlace] {
        let total = cumulative.last ?? 0
        let spacing = max(8_000, total / 10)
        let radiusKm = min(spacing / 2 / 1000 + corridor / 1000 + 0.5, TankerkoenigClient.maxRadiusKm)
        var centers: [LatLon] = []
        var next = 0.0
        while next <= total + 1 {
            centers.append(point(at: min(next, total), on: line, cumulative: cumulative))
            next += spacing
        }
        var stations: [String: FuelStation] = [:]
        for center in centers {
            for station in try await TankerkoenigClient.stations(near: center, radiusKm: radiusKm, fuel: type,
                                                                 sortByPrice: false, apiKey: key) {
                stations[station.id] = station
            }
        }
        return stations.values.compactMap { station -> AlongRoutePlace? in
            let p = LatLon(station.lat, station.lon)
            let (along, offset) = project(p, onto: line, cumulative: cumulative)
            guard along > 20, offset <= corridor else { return nil }
            let name = station.place.map { "\(station.name) (\($0))" } ?? station.name
            let detail = station.priceText.map { "\(type.label) \($0)" } ?? String(localized: "geschlossen")
            return AlongRoutePlace(id: station.id, name: name, point: p, alongMeters: along,
                                   offsetMeters: offset, detail: detail, price: station.price, fuelType: type)
        }
        .sorted { $0.alongMeters < $1.alongMeters }
    }

    // MARK: - Geometrie

    static func cumulativeDistances(_ line: [LatLon]) -> [Double] {
        var result = [0.0]
        for i in line.indices.dropFirst() { result.append(result[i - 1] + GeoUtils.distanceMeters(line[i - 1], line[i])) }
        return result
    }

    /** Entfernung entlang der Linie bis zum Lot und Abstand zur Linie. */
    static func project(_ p: LatLon, onto line: [LatLon], cumulative: [Double]) -> (along: Double, offset: Double) {
        var best = (along: 0.0, offset: Double.greatestFiniteMagnitude)
        for i in 0..<(line.count - 1) {
            let foot = GeoUtils.closestPointOnSegment(p, line[i], line[i + 1])
            let d = GeoUtils.distanceMeters(p, foot)
            if d < best.offset { best = (cumulative[i] + GeoUtils.distanceMeters(line[i], foot), d) }
        }
        return best
    }

    static func point(at distance: Double, on line: [LatLon], cumulative: [Double]) -> LatLon {
        guard let i = cumulative.lastIndex(where: { $0 <= distance }), i < line.count - 1 else { return line.last! }
        let segment = cumulative[i + 1] - cumulative[i]
        let f = segment > 0 ? (distance - cumulative[i]) / segment : 0
        return LatLon(line[i].latitude + (line[i + 1].latitude - line[i].latitude) * f,
                      line[i].longitude + (line[i + 1].longitude - line[i].longitude) * f)
    }

    /** Ein Punkt je [spacing] Meter (plus Anfang/Ende) — hält die Overpass-Abfrage klein. */
    static func simplify(_ line: [LatLon], cumulative: [Double], spacing: Double) -> [LatLon] {
        var result = [line[0]]
        var lastKept = 0.0
        for i in line.indices.dropFirst() where cumulative[i] - lastKept >= spacing {
            result.append(line[i])
            lastKept = cumulative[i]
        }
        if result.last != line.last { result.append(line.last!) }
        return result
    }
}
