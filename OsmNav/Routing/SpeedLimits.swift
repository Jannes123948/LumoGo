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
 * Tempolimits und Straßenart entlang einer OSRM-Route. OSRMs Demo-Server kennt die Annotation
 * `maxspeed` nicht (InvalidQuery), liefert aber mit `annotations=nodes` die OSM-Knoten der Route.
 * Damit holt [load] per Overpass die Wege, die diese Knoten enthalten, und ordnet jedem befahrenen
 * Knotenpaar das Limit in Fahrtrichtung zu (`maxspeed:forward`/`:backward`) — dazu, ob der Abschnitt
 * Autobahn oder Tunnel ist (Autobahn-Leiste, Tunnel-Modus). In derselben Abfrage kommen die
 * Autobahn-Ausfahrten (`motorway_junction`), die auf der Route liegen — also genau die in
 * Fahrtrichtung, nicht die der Gegenfahrbahn.
 *
 * Abschnitte liegen in Routenreihenfolge vor; [limit] sucht in einem Fenster um den zuletzt
 * gefundenen Abschnitt (pro GPS-Tick sonst ein Lauf über die ganze Route).
 */
final class SpeedLimitMap {

    struct Segment {
        let a: LatLon
        let b: LatLon
        /** nil = kein Limit eingetragen. */
        let limit: SpeedLimit?
        var tunnel = false
        var motorway = false
    }

    /** Autobahn-Ausfahrt, -Kreuz/-Dreieck oder Rasthof-Abzweig auf der Route. */
    struct Junction: Equatable {
        let id: Int64
        let point: LatLon
        let ref: String?
        let name: String?
    }

    private(set) var segments: [Segment] = []
    private(set) var junctions: [Junction] = []
    /** Gefahrenstellen (Bahnübergänge, Schwellen, `hazard=*`, Schulen am Straßenrand). */
    private(set) var hazards: [Hazard] = []
    private var lastIndex = 0

    var isEmpty: Bool { segments.isEmpty }

    /** Limit am (auf die Route gesnappten) Punkt; nil = unbekannt oder kein Abschnitt in der Nähe. */
    func limit(at point: LatLon, maxDistanceMeters: Double = 25) -> SpeedLimit? {
        segment(at: point, maxDistanceMeters: maxDistanceMeters)?.limit
    }

    /** Abschnitt am Punkt (merkt sich die Stelle für die nächste Suche). */
    func segment(at point: LatLon, maxDistanceMeters: Double = 25) -> Segment? {
        guard let index = find(point, maxDistanceMeters: maxDistanceMeters, from: lastIndex) else { return nil }
        lastIndex = index
        return segments[index]
    }

    /** Wie [segment], ohne die gemerkte Stelle zu verschieben (Blick voraus, Prüfungen). */
    func peekSegment(at point: LatLon, maxDistanceMeters: Double = 25) -> Segment? {
        find(point, maxDistanceMeters: maxDistanceMeters, from: lastIndex).map { segments[$0] }
    }

    private func find(_ point: LatLon, maxDistanceMeters: Double, from hint: Int) -> Int? {
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
        let window = max(0, hint - 20)..<min(segments.count, hint + 300)
        var best = search(window)
        if (best?.1 ?? .greatestFiniteMagnitude) > maxDistanceMeters {
            best = search(0..<segments.count)
        }
        guard let (index, distance) = best, distance <= maxDistanceMeters else { return nil }
        return index
    }

    // MARK: - Laden

    private static let chunkSize = 1200
    private static let roadFilter = "motorway|motorway_link|trunk|trunk_link|primary|primary_link|secondary|secondary_link|tertiary|tertiary_link|unclassified|residential|living_street|service|road"

    /**
     * Lädt die Abschnitte abschnittsweise (Routenanfang zuerst) und meldet nach jedem Abschnitt den
     * bisherigen Stand über [onUpdate] — so gibt es vorne schon Schilder, während der Rest lädt.
     * Fehlgeschlagene Abschnitte (Overpass 504) bleiben einfach ohne Daten.
     *
     * [geometry] = Routenlinie (`overview=full`, ein Punkt je Knoten; Etappen teilen sich den
     * Grenzpunkt). Damit werden Knoten mit 11-stelliger ID zugeordnet: OSRM gibt große Zahlen nur mit
     * 10 gültigen Stellen aus („11556072209“ → „11556072210.0“) — ohne Korrektur fehlten an neueren
     * OSM-Knoten Tempolimit und Straßenart.
     */
    static func load(nodeLegs: [[Int64]], geometry: [LatLon] = [], includeHazards: Bool = false,
                     onUpdate: @escaping @MainActor ([Segment], [Junction], [Hazard]) -> Void) async {
        // Routenknoten je Etappe mit Koordinate (falls die Anzahl zur Linie passt).
        let expected = nodeLegs.reduce(0) { $0 + $1.count } - max(nodeLegs.count - 1, 0)
        let coordinatesUsable = geometry.count == expected
        var legPoints: [[LatLon?]] = []
        var offset = 0
        for leg in nodeLegs {
            legPoints.append(leg.indices.map { coordinatesUsable ? geometry[offset + $0] : nil })
            offset += max(leg.count - 1, 0)
        }
        guard nodeLegs.contains(where: { $0.count >= 2 }) else { return }

        // Abfrage nur mit verlässlichen IDs; die übrigen Wege kommen über die Nachbarknoten mit.
        var orderedNodes: [Int64] = []
        var seen = Set<Int64>()
        for leg in nodeLegs {
            for id in leg where !isSuspect(id) && seen.insert(id).inserted { orderedNodes.append(id) }
        }

        var allWays: [WayInfo] = []
        var nodeIndex = NodeIndex()
        var junctions: [Int64: Junction] = [:]
        var junctionOrder: [Int64] = []
        var hazards: [String: Hazard] = [:]

        var start = 0
        while start < orderedNodes.count {
            if Task.isCancelled { return }
            let chunk = orderedNodes[start..<min(start + chunkSize, orderedNodes.count)]
            start += chunkSize
            let ids = chunk.map(String.init).joined(separator: ",")
            // Ausfahrten über die Wege (nicht die Routenknoten), damit auch solche mit großer ID dabei sind.
            let query = """
            [out:json][timeout:25];
            node(id:\(ids))->.r;
            way(bn.r)["highway"~"^(\(roadFilter))$"]->.w;
            .w out geom qt;
            node(w.w)["highway"="motorway_junction"];
            out qt;
            """ + (includeHazards ? """

            node(w.w)[~"^(railway|hazard|traffic_calming)$"~"."];
            out qt;
            nwr["amenity"~"^(school|kindergarten)$"](around.w:60);
            out center tags qt;
            """ : "")
            guard let data = try? await OverpassClient.rawQuery(query, retryCount: 2),
                  let (ways, nodes, foundHazards) = parse(data) else { continue }
            for junction in nodes where junctions[junction.id] == nil {
                junctions[junction.id] = junction
                junctionOrder.append(junction.id)
            }
            for hazard in foundHazards { hazards[hazard.id] = hazard }
            for way in ways {
                allWays.append(way)
                for (id, point) in zip(way.nodes, way.points) { nodeIndex.add(id, point) }
            }

            // Befahrene Knotenpaare in Routenreihenfolge, unsichere IDs über die Koordinate ersetzt.
            var pairs: [PairKey] = []
            for (leg, points) in zip(nodeLegs, legPoints) where leg.count >= 2 {
                let fixed = leg.indices.map { i -> Int64 in
                    guard isSuspect(leg[i]), let point = points[i], let real = nodeIndex.node(near: point) else { return leg[i] }
                    return real
                }
                for i in 0..<(fixed.count - 1) where fixed[i] != fixed[i + 1] {
                    pairs.append(PairKey(fixed[i], fixed[i + 1]))
                }
            }
            let wanted = Set(pairs)
            var found: [PairKey: Segment] = [:]
            for way in allWays {
                for j in 0..<(way.nodes.count - 1) {
                    let n1 = way.nodes[j], n2 = way.nodes[j + 1]
                    let p1 = way.points[j], p2 = way.points[j + 1]
                    if wanted.contains(PairKey(n1, n2)) {
                        found[PairKey(n1, n2)] = Segment(a: p1, b: p2, limit: way.forward, tunnel: way.tunnel, motorway: way.motorway)
                    }
                    if wanted.contains(PairKey(n2, n1)) {
                        found[PairKey(n2, n1)] = Segment(a: p2, b: p1, limit: way.backward, tunnel: way.tunnel, motorway: way.motorway)
                    }
                }
            }
            await onUpdate(pairs.compactMap { found[$0] }, junctionOrder.compactMap { junctions[$0] }, Array(hazards.values))
        }
    }

    /** OSRM gibt ab 11 Stellen gerundete IDs aus — solche IDs sind unzuverlässig. */
    private static func isSuspect(_ id: Int64) -> Bool { id >= 10_000_000_000 }

    /** Wegknoten nach Lage (≈ 11-m-Raster), um gerundete Knoten-IDs zu ersetzen. */
    private struct NodeIndex {
        private var cells: [Int64: [(Int64, LatLon)]] = [:]

        private static func cell(_ lat: Int64, _ lon: Int64) -> Int64 { lat &* 4_000_000 &+ lon }

        mutating func add(_ id: Int64, _ point: LatLon) {
            let key = Self.cell(Int64((point.latitude * 1e4).rounded(.down)), Int64((point.longitude * 1e4).rounded(.down)))
            cells[key, default: []].append((id, point))
        }

        /** Knoten innerhalb von 1,5 m. */
        func node(near point: LatLon) -> Int64? {
            let lat = Int64((point.latitude * 1e4).rounded(.down)), lon = Int64((point.longitude * 1e4).rounded(.down))
            var best: (Int64, Double)?
            for dLat in -1...1 {
                for dLon in -1...1 {
                    for (id, p) in cells[Self.cell(lat + Int64(dLat), lon + Int64(dLon))] ?? [] {
                        let d = GeoUtils.distanceMeters(point, p)
                        if d <= 1.5, d < (best?.1 ?? .greatestFiniteMagnitude) { best = (id, d) }
                    }
                }
            }
            return best?.0
        }
    }

    private struct PairKey: Hashable {
        let from: Int64
        let to: Int64
        init(_ from: Int64, _ to: Int64) { self.from = from; self.to = to }
    }

    private struct WayInfo {
        let nodes: [Int64]
        let points: [LatLon]
        let forward: SpeedLimit?
        let backward: SpeedLimit?
        let tunnel: Bool
        let motorway: Bool
    }

    private static func parse(_ data: Data) -> ([WayInfo], [Junction], [Hazard])? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let elements = root["elements"] as? [[String: Any]] else { return nil }
        var junctions: [Junction] = []
        var ways: [WayInfo] = []
        var hazards: [Hazard] = []
        for el in elements {
            guard let tags = el["tags"] as? [String: String] else { continue }
            // Gefahrenstellen: Punkte auf der Straße bzw. Schulen (Fläche → Mittelpunkt).
            if tags["highway"] != "motorway_junction", tags["highway"] == nil || el["type"] as? String == "node",
               let kind = HazardKind.from(tags: tags) {
                let center = el["center"] as? [String: Any]
                if let lat = (el["lat"] as? Double) ?? (center?["lat"] as? Double),
                   let lon = (el["lon"] as? Double) ?? (center?["lon"] as? Double),
                   let id = (el["id"] as? NSNumber)?.int64Value {
                    hazards.append(Hazard(id: "\(el["type"] as? String ?? "")\(id)", kind: kind, point: LatLon(lat, lon)))
                }
                continue
            }
            if el["type"] as? String == "node" {
                guard tags["highway"] == "motorway_junction" else { continue }
                guard let id = (el["id"] as? NSNumber)?.int64Value, let lat = el["lat"] as? Double, let lon = el["lon"] as? Double else { continue }
                func tag(_ key: String) -> String? {
                    guard let v = tags[key]?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return nil }
                    return v
                }
                junctions.append(Junction(id: id, point: LatLon(lat, lon), ref: tag("ref"), name: tag("name") ?? tag("exit_to")))
                continue
            }
            guard el["type"] as? String == "way",
                  let nodes = (el["nodes"] as? [NSNumber])?.map({ $0.int64Value }),
                  let geometry = el["geometry"] as? [[String: Any]],
                  geometry.count == nodes.count, nodes.count >= 2 else { continue }
            let points = geometry.compactMap { g -> LatLon? in
                guard let lat = g["lat"] as? Double, let lon = g["lon"] as? Double else { return nil }
                return LatLon(lat, lon)
            }
            guard points.count == nodes.count else { continue }
            // Ohne `maxspeed` geben oft Typ-Tags die Regel an ("DE:urban", "DE:zone30").
            let general = SpeedLimit.parse(tags["maxspeed"])
                ?? SpeedLimit.parse(tags["maxspeed:type"])
                ?? SpeedLimit.parse(tags["source:maxspeed"])
                ?? SpeedLimit.parse(tags["zone:maxspeed"])
            let tunnel = tags["tunnel"].map { $0 != "no" } ?? false
            ways.append(WayInfo(nodes: nodes, points: points,
                                forward: SpeedLimit.parse(tags["maxspeed:forward"]) ?? general,
                                backward: SpeedLimit.parse(tags["maxspeed:backward"]) ?? general,
                                tunnel: tunnel, motorway: tags["highway"] == "motorway"))
        }
        return (ways, junctions, hazards)
    }

    func replace(_ newSegments: [Segment], junctions newJunctions: [Junction] = [], hazards newHazards: [Hazard] = []) {
        segments = newSegments
        junctions = newJunctions
        hazards = newHazards
        lastIndex = min(lastIndex, max(0, newSegments.count - 1))
    }
}
