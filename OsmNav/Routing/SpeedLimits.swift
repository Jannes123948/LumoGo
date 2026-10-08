import Foundation

/** Zulässige Höchstgeschwindigkeit eines Straßenabschnitts. */
enum SpeedLimit: Equatable {
    case kmh(Int)
    /** Kein Tempolimit (z.B. Autobahn `maxspeed=none`). */
    case unlimited

    var kmhValue: Int? {
        if case .kmh(let v) = self { return v }
        return nil
    }

    /**
     * Liest OSM-`maxspeed`-Werte: Zahl ("50"), mph ("30 mph"), "none", Länder-Kürzel
     * ("DE:urban" = 50, "DE:rural" = 100, "DE:zone30", "DE:motorway" = unbegrenzt). Unbekannte/
     * variable Angaben ("signals", "walk", …) → nil (Schild wird dann nicht angezeigt).
     */
    static func parse(_ raw: String?) -> SpeedLimit? {
        guard let raw else { return nil }
        let value = raw.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        if value.isEmpty { return nil }
        if let number = Int(value), number > 0 { return .kmh(number) }
        if value.hasSuffix("mph"), let number = Double(value.dropLast(3).trimmingCharacters(in: .whitespaces)) {
            return .kmh(Int((number * 1.609).rounded()))
        }
        if value == "none" { return .unlimited }
        // "DE:30" (z.B. in zone:maxspeed)
        if value.range(of: "^[a-z]{2}:\\d+$", options: .regularExpression) != nil,
           let number = Int(value.filter(\.isNumber)), number > 0 { return .kmh(number) }
        if let range = value.range(of: "zone:?(\\d+)", options: .regularExpression) {
            let digits = value[range].filter(\.isNumber)
            if let number = Int(digits) { return .kmh(number) }
        }
        switch value {
        case "de:urban", "at:urban", "ch:urban", "nl:urban", "fr:urban", "it:urban", "pl:urban", "cz:urban", "dk:urban": return .kmh(50)
        case "de:rural", "at:rural", "pl:rural": return .kmh(100)
        case "ch:rural", "nl:rural", "fr:rural", "dk:rural": return .kmh(80)
        case "cz:rural", "it:rural": return .kmh(90)
        case "de:motorway": return .unlimited
        case "at:motorway", "fr:motorway", "it:motorway", "dk:motorway", "nl:motorway": return .kmh(130)
        case "ch:motorway", "cz:motorway": return .kmh(120)
        case "de:trunk", "ch:trunk": return .kmh(100)
        default: return nil
        }
    }
}

/**
 * Tempolimits entlang einer OSRM-Route. OSRMs Demo-Server kennt die Annotation `maxspeed` nicht
 * (InvalidQuery), liefert aber mit `annotations=nodes` die OSM-Knoten der Route. Damit holt
 * [load] per Overpass die Wege (mit `maxspeed`), die diese Knoten enthalten, und ordnet jedem
 * befahrenen Knotenpaar das Limit in Fahrtrichtung zu (`maxspeed:forward`/`:backward`).
 *
 * Abschnitte liegen in Routenreihenfolge vor; [limit] sucht in einem Fenster um den zuletzt
 * gefundenen Abschnitt (pro GPS-Tick sonst ein Lauf über die ganze Route).
 */
final class SpeedLimitMap {

    struct Segment {
        let a: LatLon
        let b: LatLon
        let limit: SpeedLimit
    }

    private(set) var segments: [Segment] = []
    private var lastIndex = 0

    var isEmpty: Bool { segments.isEmpty }

    /** Limit am (auf die Route gesnappten) Punkt; nil = unbekannt oder kein Abschnitt in der Nähe. */
    func limit(at point: LatLon, maxDistanceMeters: Double = 25) -> SpeedLimit? {
        guard !segments.isEmpty else { return nil }
        func search(_ range: Range<Int>) -> (Int, Double)? {
            var best: (Int, Double)?
            for i in range {
                let s = segments[i]
                let d = GeoUtils.distanceMeters(point, GeoUtils.closestPointOnSegment(point, s.a, s.b))
                if d < (best?.1 ?? .greatestFiniteMagnitude) { best = (i, d) }
            }
            return best
        }
        let window = max(0, lastIndex - 20)..<min(segments.count, lastIndex + 300)
        var best = search(window)
        if (best?.1 ?? .greatestFiniteMagnitude) > maxDistanceMeters {
            best = search(0..<segments.count)
        }
        guard let (index, distance) = best, distance <= maxDistanceMeters else { return nil }
        lastIndex = index
        return segments[index].limit
    }

    // MARK: - Laden

    private static let chunkSize = 1200
    private static let roadFilter = "motorway|motorway_link|trunk|trunk_link|primary|primary_link|secondary|secondary_link|tertiary|tertiary_link|unclassified|residential|living_street|service|road"

    /**
     * Lädt die Limits abschnittsweise (Routenanfang zuerst) und meldet nach jedem Abschnitt den
     * bisherigen Stand über [onUpdate] — so gibt es vorne schon Schilder, während der Rest lädt.
     * Fehlgeschlagene Abschnitte (Overpass 504) bleiben einfach ohne Limit.
     */
    static func load(nodeLegs: [[Int64]], onUpdate: @escaping @MainActor ([Segment]) -> Void) async {
        // Befahrene Knotenpaare in Routenreihenfolge.
        var pairs: [(Int64, Int64)] = []
        for leg in nodeLegs where leg.count >= 2 {
            for i in 0..<(leg.count - 1) where leg[i] != leg[i + 1] {
                pairs.append((leg[i], leg[i + 1]))
            }
        }
        guard !pairs.isEmpty else { return }

        var found: [PairKey: Segment] = [:]
        var orderedNodes: [Int64] = []
        var seen = Set<Int64>()
        for (a, b) in pairs {
            if seen.insert(a).inserted { orderedNodes.append(a) }
            if seen.insert(b).inserted { orderedNodes.append(b) }
        }
        let wanted = Set(pairs.map { PairKey($0.0, $0.1) })

        var start = 0
        while start < orderedNodes.count {
            if Task.isCancelled { return }
            let chunk = orderedNodes[start..<min(start + chunkSize, orderedNodes.count)]
            start += chunkSize
            let ids = chunk.map(String.init).joined(separator: ",")
            let query = "[out:json][timeout:25];\nnode(id:\(ids));\nway(bn)[\"highway\"~\"^(\(roadFilter))$\"];\nout geom qt;"
            guard let data = try? await OverpassClient.rawQuery(query, retryCount: 2),
                  let ways = parseWays(data) else { continue }
            for way in ways {
                for j in 0..<(way.nodes.count - 1) {
                    let n1 = way.nodes[j], n2 = way.nodes[j + 1]
                    let p1 = way.points[j], p2 = way.points[j + 1]
                    if wanted.contains(PairKey(n1, n2)), let limit = way.forward {
                        found[PairKey(n1, n2)] = Segment(a: p1, b: p2, limit: limit)
                    }
                    if wanted.contains(PairKey(n2, n1)), let limit = way.backward {
                        found[PairKey(n2, n1)] = Segment(a: p2, b: p1, limit: limit)
                    }
                }
            }
            let ordered = pairs.compactMap { found[PairKey($0.0, $0.1)] }
            await onUpdate(ordered)
        }
    }

    private struct PairKey: Hashable {
        let from: Int64
        let to: Int64
        init(_ from: Int64, _ to: Int64) { self.from = from; self.to = to }
    }

    private struct WayLimits {
        let nodes: [Int64]
        let points: [LatLon]
        let forward: SpeedLimit?
        let backward: SpeedLimit?
    }

    private static func parseWays(_ data: Data) -> [WayLimits]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let elements = root["elements"] as? [[String: Any]] else { return nil }
        return elements.compactMap { el in
            guard el["type"] as? String == "way",
                  let tags = el["tags"] as? [String: String],
                  let nodes = (el["nodes"] as? [NSNumber])?.map({ $0.int64Value }),
                  let geometry = el["geometry"] as? [[String: Any]],
                  geometry.count == nodes.count, nodes.count >= 2 else { return nil }
            let points = geometry.compactMap { g -> LatLon? in
                guard let lat = g["lat"] as? Double, let lon = g["lon"] as? Double else { return nil }
                return LatLon(lat, lon)
            }
            guard points.count == nodes.count else { return nil }
            // Ohne `maxspeed` geben oft Typ-Tags die Regel an ("DE:urban", "DE:zone30").
            let general = SpeedLimit.parse(tags["maxspeed"])
                ?? SpeedLimit.parse(tags["maxspeed:type"])
                ?? SpeedLimit.parse(tags["source:maxspeed"])
                ?? SpeedLimit.parse(tags["zone:maxspeed"])
            let forward = SpeedLimit.parse(tags["maxspeed:forward"]) ?? general
            let backward = SpeedLimit.parse(tags["maxspeed:backward"]) ?? general
            if forward == nil && backward == nil { return nil }
            return WayLimits(nodes: nodes, points: points, forward: forward, backward: backward)
        }
    }

    func replace(_ newSegments: [Segment]) {
        segments = newSegments
        lastIndex = min(lastIndex, max(0, newSegments.count - 1))
    }
}
