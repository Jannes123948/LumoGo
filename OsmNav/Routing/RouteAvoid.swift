import Foundation

/** Was die Route meiden soll (nur Profil Auto, nur online). */
struct RouteAvoidOptions: Equatable {
    var tolls = false
    var motorways = false
    var ferries = false

    static let none = RouteAvoidOptions()

    var isActive: Bool { tolls || motorways || ferries }
}

/** Ergebnis einer Valhalla-Anfrage: Streckenverlauf je Etappe + was sich nicht vermeiden ließ. */
struct AvoidPlan {
    let legs: [[LatLon]]
    let hasToll: Bool
    let hasFerry: Bool
}

/**
 * Die öffentlichen OSRM-Server können weder Maut noch Autobahn noch Fähren ausschließen
 * (`exclude=…` → „not supported“). Der FOSSGIS-Valhalla-Server kann es — liefert aber andere
 * Antworten (keine Fahrstreifen, keine OSM-Knoten für die Tempolimits). Deshalb nutzen wir Valhalla
 * nur für den **Streckenverlauf**: daraus werden Zwischenpunkte abgeleitet, durch die OSRM die
 * eigentliche Route (mit allen Hinweisen) rechnet.
 */
enum ValhallaClient {

    private static let url = URL(string: "https://valhalla1.openstreetmap.de/route")!
    private static let session = HTTP.session(requestTimeout: 25)

    static func plan(_ points: [LatLon], avoid: RouteAvoidOptions) async throws -> AvoidPlan {
        var costing: [String: Any] = [:]
        if avoid.tolls { costing["use_tolls"] = 0 }
        if avoid.motorways { costing["use_highways"] = 0 }
        if avoid.ferries { costing["use_ferry"] = 0 }
        let body: [String: Any] = [
            "locations": points.map { ["lat": $0.latitude, "lon": $0.longitude] },
            "costing": "auto",
            "costing_options": ["auto": costing],
            "directions_type": "none"
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data = try await HTTP.data(session, for: request)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let trip = root["trip"] as? [String: Any],
              let legs = trip["legs"] as? [[String: Any]], legs.count == points.count - 1 else {
            throw AppError.parse
        }
        let shapes = legs.compactMap { ($0["shape"] as? String).map(decodePolyline6) }
        guard shapes.count == legs.count, shapes.allSatisfy({ $0.count >= 2 }) else { throw AppError.parse }
        let summary = trip["summary"] as? [String: Any]
        return AvoidPlan(legs: shapes,
                         hasToll: summary?["has_toll"] as? Bool ?? false,
                         hasFerry: summary?["has_ferry"] as? Bool ?? false)
    }

    /** Valhalla-Polyline (Genauigkeit 6 Nachkommastellen). */
    static func decodePolyline6(_ encoded: String) -> [LatLon] {
        let bytes = Array(encoded.utf8)
        var index = 0, lat = 0, lon = 0
        var result: [LatLon] = []

        func nextValue() -> Int? {
            var value = 0, shift = 0
            while index < bytes.count {
                let byte = Int(bytes[index]) - 63
                index += 1
                value |= (byte & 0x1F) << shift
                shift += 5
                if byte < 0x20 { return (value & 1) != 0 ? ~(value >> 1) : value >> 1 }
            }
            return nil
        }

        while index < bytes.count {
            guard let dLat = nextValue(), let dLon = nextValue() else { break }
            lat += dLat
            lon += dLon
            result.append(LatLon(Double(lat) / 1e6, Double(lon) / 1e6))
        }
        return result
    }

    /**
     * Zwischenpunkte entlang [path], etwa alle [spacing] Meter (nicht in den ersten/letzten
     * halben Abstand). Mehr Punkte = OSRM bleibt näher am Valhalla-Verlauf, aber mehr Etappen.
     */
    static func viaPoints(_ path: [LatLon], spacing: Double) -> [LatLon] {
        guard path.count > 2 else { return [] }
        var total = 0.0
        for i in 1..<path.count { total += GeoUtils.distanceMeters(path[i - 1], path[i]) }
        var result: [LatLon] = []
        var sinceLast = 0.0, traveled = 0.0
        for i in 1..<path.count {
            let d = GeoUtils.distanceMeters(path[i - 1], path[i])
            sinceLast += d
            traveled += d
            if sinceLast >= spacing, total - traveled > spacing * 0.5 {
                result.append(path[i])
                sinceLast = 0
            }
        }
        return result
    }
}

extension OsrmRoute {

    /**
     * Fasst die Zwischenpunkt-Etappen wieder zu den Etappen des Nutzers zusammen: [groups] gibt je
     * Nutzer-Etappe an, aus wie vielen OSRM-Etappen sie besteht. Der „Ankunft“-Schritt am Zwischenpunkt
     * entfällt; der „Start“-Schritt der Folgeetappe wird dem vorherigen Schritt zugeschlagen, damit
     * Strecke und Zeit stimmen und nicht „Sie haben Ihr Ziel erreicht“ mitten auf der Strecke kommt.
     */
    func mergingLegs(groups: [Int]) -> OsrmRoute {
        guard groups.reduce(0, +) == legs.count, groups.contains(where: { $0 > 1 }) else { return self }
        var mergedLegs: [OsrmLeg] = []
        var mergedNodes: [[Int64]] = []
        var cursor = 0
        for count in groups {
            var steps: [OsrmStep] = []
            var nodes: [Int64] = []
            for j in cursor..<(cursor + count) {
                var incoming = legs[j].steps
                if j > cursor {
                    if steps.last?.maneuver.type == "arrive" { steps.removeLast() }
                    if let depart = incoming.first, depart.maneuver.type == "depart" {
                        incoming.removeFirst()
                        if let last = steps.popLast() {
                            steps.append(last.extended(distance: depart.distance, duration: depart.duration))
                        }
                    }
                }
                steps.append(contentsOf: incoming)
                if j < nodeLegs.count {
                    let legNodes = nodeLegs[j]
                    nodes.append(contentsOf: (j > cursor && nodes.last == legNodes.first) ? Array(legNodes.dropFirst()) : legNodes)
                }
            }
            mergedLegs.append(OsrmLeg(steps: steps))
            mergedNodes.append(nodes)
            cursor += count
        }
        var merged = OsrmRoute(geometry: geometry, legs: mergedLegs, distance: distance, duration: duration)
        merged.nodeLegs = nodeLegs.isEmpty ? [] : mergedNodes
        return merged
    }
}

private extension OsrmStep {
    func extended(distance extra: Double, duration extraDuration: Double) -> OsrmStep {
        OsrmStep(maneuver: maneuver, name: name, distance: distance + extra, duration: duration + extraDuration,
                 destinations: destinations, exits: exits, lanes: lanes, ref: ref)
    }
}
