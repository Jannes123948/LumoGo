import Foundation

enum OfflineRoutingError: LocalizedError {
    case noData
    case notOnRoadNetwork
    case noRoute

    var errorDescription: String? {
        switch self {
        case .noData: return String(localized: "Für dieses Gebiet sind keine Offline-Routingdaten heruntergeladen.")
        case .notOnRoadNetwork: return String(localized: "Start oder Ziel liegt nicht in der Nähe einer offline verfügbaren Straße.")
        case .noRoute: return String(localized: "Offline wurde keine Verbindung gefunden (evtl. liegt die Strecke teilweise außerhalb der heruntergeladenen Gebiete).")
        }
    }
}

/**
 * Offline-Router auf dem heruntergeladenen Straßennetz (siehe [RoadDataBuilder]) — A*-Suche
 * nach der kürzesten Fahrzeit, danach werden aus der Geometrie Abbiegehinweise erzeugt
 * (Abbiegewinkel an Kreuzungen, Straßennamenwechsel, Kreisverkehre mit Ausfahrtzählung,
 * Autobahn-Ausfahrten). Liefert ein ganz normales [OsrmRoute] — Fortschritt, HUD, Ansagen und
 * Re-Routing funktionieren dadurch unverändert, genau wie beim BRouter-Fallback auf Android.
 */
actor OfflineRouter {
    static let shared = OfflineRouter()

    private var graph: RoadGraph?
    private var loadedIds: [String] = []

    func invalidate() {
        graph = nil
        loadedIds = []
    }

    var hasAnyData: Bool { !RoadDataStore.list().isEmpty }

    /** Lädt nur die Pakete, die das Gebiet der Anfrage berühren (spart Speicher). */
    private func graph(covering points: [LatLon]) throws -> RoadGraph {
        let margin = 0.05
        let south = points.map(\.latitude).min()! - margin
        let north = points.map(\.latitude).max()! + margin
        let west = points.map(\.longitude).min()! - margin
        let east = points.map(\.longitude).max()! + margin
        let ids = RoadDataStore.list().filter { info in
            let b = info.boundingBox
            return b.south <= north && b.north >= south && b.west <= east && b.east >= west
        }.map(\.id).sorted()
        guard !ids.isEmpty else { throw OfflineRoutingError.noData }
        if ids == loadedIds, let graph { return graph }
        graph = nil // alten Graph vor dem Laden freigeben
        let loaded = try RoadGraph(files: ids.map(RoadDataStore.file))
        graph = loaded
        loadedIds = ids
        return loaded
    }

    func route(_ points: [LatLon], profile: RoutingProfile) throws -> OsrmRoute {
        guard points.count >= 2 else { throw OfflineRoutingError.noRoute }
        let g = try graph(covering: points)
        var legs: [OsrmLeg] = []
        var geometry: [LatLon] = []
        var distance = 0.0
        var duration = 0.0
        for i in 0..<(points.count - 1) {
            let leg = try routeLeg(g, from: points[i], to: points[i + 1], profile: profile)
            legs.append(OsrmLeg(steps: leg.steps))
            geometry.append(contentsOf: geometry.isEmpty ? leg.geometry : Array(leg.geometry.dropFirst()))
            distance += leg.distance
            duration += leg.duration
        }
        return OsrmRoute(geometry: geometry, legs: legs, distance: distance, duration: duration)
    }

    /** Offline-"Snap to road" für den freien Modus (Ersatz für OSRMs nearest-Dienst). */
    func nearestRoadPoint(_ point: LatLon) -> LatLon? {
        nearestRoad(point)?.point
    }

    /** Nächste Straße im Offline-Straßennetz: Punkt + Name (sonst Nummer, z.B. „B 170“). */
    func nearestRoad(_ point: LatLon) -> (point: LatLon, name: String)? {
        guard let g = try? graph(covering: [point]), let snap = nearestEdge(g, point, .car, maxRings: 1) else { return nil }
        return (snap.point, g.displayName(way: Int(g.edgeWay[snap.edge])))
    }

    // MARK: - Einrasten

    private struct Snap {
        let edge: Int
        /** Position auf der Kante: 0 = edgeA, 1 = edgeB. */
        let t: Double
        let point: LatLon
        let distance: Double
    }

    private func nearestEdge(_ g: RoadGraph, _ p: LatLon, _ profile: RoutingProfile, maxRings: Int = 5) -> Snap? {
        let row = RoadGraph.cell(p.latitude)
        let col = RoadGraph.cell(p.longitude)
        var best: Snap?
        for ring in 0...maxRings {
            for r in (row - ring)...(row + ring) {
                for c in (col - ring)...(col + ring) where max(abs(r - row), abs(c - col)) == ring {
                    for e32 in g.grid[RoadGraph.key(r, c)] ?? [] {
                        let e = Int(e32)
                        guard g.isUsable(e, profile) else { continue }
                        let a = g.point(Int(g.edgeA[e]))
                        let b = g.point(Int(g.edgeB[e]))
                        let q = GeoUtils.closestPointOnSegment(p, a, b)
                        let d = GeoUtils.distanceMeters(p, q)
                        if d < (best?.distance ?? .infinity) {
                            let len = GeoUtils.distanceMeters(a, b)
                            best = Snap(edge: e, t: len > 0 ? GeoUtils.distanceMeters(a, q) / len : 0, point: q, distance: d)
                        }
                    }
                }
            }
            // Ein Treffer im inneren Ring kann nicht mehr von weiter außen geschlagen werden,
            // sobald er näher liegt als eine Zellbreite (~700 m in Ost-West-Richtung).
            if let best, best.distance < Double(ring) * 700 + 300 { return best }
        }
        return best
    }

    // MARK: - A*

    private struct Leg {
        let steps: [OsrmStep]
        let geometry: [LatLon]
        let distance: Double
        let duration: Double
    }

    /** Ein Stück der gefundenen Strecke (Kante oder Teilkante am Start/Ziel). */
    private struct Segment {
        let from: LatLon
        let to: LatLon
        let way: Int
        /** Knoten am Ende des Stücks; -1 = virtueller Ziel-Punkt. */
        let endNode: Int
        let length: Double
        let time: Double
    }

    /**
     * Etappe von [start] nach [target]. Liegt der nächste Straßenpunkt auf einem Stück ohne Verbindung
     * zum Rest (Fußgängerzone mit Lieferverkehr, Werksgelände, Rand eines schmalen Routen-Korridors),
     * findet A* nichts — dann die nächstbesten Straßen in der Nähe probieren (anderer Weg, ≤ 400 m).
     * Gefunden an der Pirnaer Altstadt: Rohziel → keine Route, 110 m weiter (OSRMs Einrastpunkt) ging es.
     */
    private func routeLeg(_ g: RoadGraph, from start: LatLon, to target: LatLon, profile: RoutingProfile) throws -> Leg {
        // Kandidaten auf abgeschlossenen „Inseln“ (< 300 erreichbare Knoten) nach hinten.
        func connectedFirst(_ snaps: [Snap]) -> [Snap] {
            snaps.filter { !isIsland(g, $0.edge, profile) } + snaps.filter { isIsland(g, $0.edge, profile) }
        }
        let starts = connectedFirst(nearestEdges(g, start, profile))
        let targets = connectedFirst(nearestEdges(g, target, profile))
        guard let s0 = starts.first, let t0 = targets.first else { throw OfflineRoutingError.notOnRoadNetwork }
        var attempts: [(Snap, Snap)] = [(s0, t0)]
        for t in targets.dropFirst().prefix(2) { attempts.append((s0, t)) }
        for s in starts.dropFirst().prefix(2) { attempts.append((s, t0)) }
        var lastError: Error = OfflineRoutingError.noRoute
        for (s, t) in attempts {
            do {
                return try routeLeg(g, s: s, t: t, target: target, profile: profile)
            } catch {
                lastError = error
            }
        }
        // Ziel liegt in einer Einbahn-„Tasche“ (nur hinaus, nicht hinein befahrbar — gefunden in der
        // Pirnaer Altstadt, auch mit normalen Paketen): bis zum nächsten erreichbaren Punkt ≤ 500 m fahren.
        if let closest = nearestReachable(g, from: s0, to: target, profile: profile) {
            return try routeLeg(g, s: s0, t: closest, target: target, profile: profile)
        }
        throw lastError
    }

    /** Vom Start aus (Fahrtrichtungen beachtet) erreichbarer Straßenknoten, der [target] am nächsten liegt (≤ 500 m). */
    private func nearestReachable(_ g: RoadGraph, from s: Snap, to target: LatLon, profile: RoutingProfile) -> Snap? {
        let sa = Int(g.edgeA[s.edge]), sb = Int(g.edgeB[s.edge])
        var queue: [Int] = []
        var seen = Set<Int>()
        if g.canTraverse(s.edge, from: sa, profile) { queue.append(sb) }
        if g.canTraverse(s.edge, from: sb, profile) { queue.append(sa) }
        seen.formUnion(queue)
        var best: (node: Int, distance: Double)?
        while let u = queue.popLast() {
            let d = GeoUtils.distanceMeters(g.point(u), target)
            if d < (best?.distance ?? 500) { best = (u, d) }
            for k in Int(g.adjStart[u])..<Int(g.adjStart[u + 1]) {
                let e = Int(g.adjEdge[k])
                guard g.canTraverse(e, from: u, profile) else { continue }
                let v = g.other(e, u)
                if seen.insert(v).inserted { queue.append(v) }
            }
        }
        guard let node = best?.node else { return nil }
        // Einrastpunkt genau auf dem Knoten: eine Kante, über die man ihn erreicht.
        for k in Int(g.adjStart[node])..<Int(g.adjStart[node + 1]) {
            let e = Int(g.adjEdge[k])
            let other = g.other(e, node)
            guard seen.contains(other), g.canTraverse(e, from: other, profile) else { continue }
            return Snap(edge: e, t: Int(g.edgeB[e]) == node ? 1 : 0, point: g.point(node), distance: best!.distance)
        }
        return nil
    }

    /** Nächste Kante, dazu bis zu 5 weitere auf ANDEREN Wegen (≤ 400 m) als Ersatz-Einrastpunkte. */
    private func nearestEdges(_ g: RoadGraph, _ p: LatLon, _ profile: RoutingProfile) -> [Snap] {
        guard let first = nearestEdge(g, p, profile) else { return [] }
        var result = [first]
        var usedWays: Set<Int32> = [g.edgeWay[first.edge]]
        let row = RoadGraph.cell(p.latitude), col = RoadGraph.cell(p.longitude)
        var candidates: [Snap] = []
        for r in (row - 1)...(row + 1) {
            for c in (col - 1)...(col + 1) {
                for e32 in g.grid[RoadGraph.key(r, c)] ?? [] {
                    let e = Int(e32)
                    guard g.isUsable(e, profile) else { continue }
                    let a = g.point(Int(g.edgeA[e])), b = g.point(Int(g.edgeB[e]))
                    let q = GeoUtils.closestPointOnSegment(p, a, b)
                    let d = GeoUtils.distanceMeters(p, q)
                    guard d <= 400 else { continue }
                    let len = GeoUtils.distanceMeters(a, b)
                    candidates.append(Snap(edge: e, t: len > 0 ? GeoUtils.distanceMeters(a, q) / len : 0, point: q, distance: d))
                }
            }
        }
        for candidate in candidates.sorted(by: { $0.distance < $1.distance }) where result.count < 6 {
            if usedWays.insert(g.edgeWay[candidate.edge]).inserted { result.append(candidate) }
        }
        return result
    }

    /** Erreicht man von der Kante aus (Richtungen egal) weniger als [limit] Knoten, ist sie eine Insel. */
    private func isIsland(_ g: RoadGraph, _ edge: Int, _ profile: RoutingProfile, limit: Int = 300) -> Bool {
        var seen: Set<Int> = [Int(g.edgeA[edge]), Int(g.edgeB[edge])]
        var queue = Array(seen)
        while let u = queue.popLast() {
            for k in Int(g.adjStart[u])..<Int(g.adjStart[u + 1]) {
                let e = Int(g.adjEdge[k])
                guard g.isUsable(e, profile) else { continue }
                let v = g.other(e, u)
                if seen.insert(v).inserted {
                    if seen.count >= limit { return false }
                    queue.append(v)
                }
            }
        }
        return true
    }

    private func routeLeg(_ g: RoadGraph, s: Snap, t: Snap, target: LatLon, profile: RoutingProfile) throws -> Leg {
        let n = g.nodeCount
        let maxSpeed: Double = profile == .car ? 130 / 3.6 : (profile == .bike ? 17 / 3.6 : 5 / 3.6)
        func h(_ node: Int) -> Double { GeoUtils.distanceMeters(g.point(node), target) / maxSpeed }

        var gScore = [Double](repeating: .infinity, count: n)
        var prevEdge = [Int32](repeating: -1, count: n)
        var heap = MinHeap()

        // Start: vom Einrastpunkt in beide (erlaubten) Richtungen der Kante losfahren.
        let sa = Int(g.edgeA[s.edge]), sb = Int(g.edgeB[s.edge])
        let sCost = g.cost(s.edge, profile)
        if g.canTraverse(s.edge, from: sa, profile) { gScore[sb] = (1 - s.t) * sCost; heap.push(gScore[sb] + h(sb), sb) }
        if g.canTraverse(s.edge, from: sb, profile), s.t * sCost < gScore[sa] { gScore[sa] = s.t * sCost; heap.push(gScore[sa] + h(sa), sa) }

        // Ziel: über einen der beiden Endknoten der Zielkante + Reststück bis zum Einrastpunkt.
        let ta = Int(g.edgeA[t.edge]), tb = Int(g.edgeB[t.edge])
        let tCost = g.cost(t.edge, profile)
        var goalExtra: [Int: Double] = [:]
        if g.canTraverse(t.edge, from: ta, profile) { goalExtra[ta] = t.t * tCost }
        if g.canTraverse(t.edge, from: tb, profile) { goalExtra[tb] = min(goalExtra[tb] ?? .infinity, (1 - t.t) * tCost) }

        var best = Double.infinity
        var bestNode = -1
        // Start und Ziel auf derselben Kante in Fahrtrichtung: direkte Verbindung.
        var direct = false
        if s.edge == t.edge {
            if s.t <= t.t && g.canTraverse(s.edge, from: sa, profile) { best = (t.t - s.t) * sCost; direct = true }
            if s.t >= t.t && g.canTraverse(s.edge, from: sb, profile) && (s.t - t.t) * sCost < best { best = (s.t - t.t) * sCost; direct = true }
        }

        while let (f, u) = heap.pop() {
            if f >= best { break }
            if gScore[u] + h(u) < f - 1e-6 { continue } // veralteter Heap-Eintrag
            if let extra = goalExtra[u], gScore[u] + extra < best {
                best = gScore[u] + extra
                bestNode = u
                direct = false
            }
            let incoming = Int(prevEdge[u])
            for k in Int(g.adjStart[u])..<Int(g.adjStart[u + 1]) {
                let e = Int(g.adjEdge[k])
                guard g.canTraverse(e, from: u, profile) else { continue }
                // Abbiegeverbote gelten fürs Auto. Knotenbasierte Suche = Näherung: ein Verbot
                // wird nur für den jeweils besten Ankunftsweg geprüft — verhindert verbotene
                // Abbiegungen, kann aber in seltenen Fällen eine erlaubte Umfahrung übersehen.
                if profile == .car, incoming >= 0, !g.turnAllowed(at: u, from: incoming, to: e) { continue }
                let v = g.other(e, u)
                var candidate = gScore[u] + g.cost(e, profile)
                if profile == .car, incoming >= 0 {
                    candidate += turnPenalty(g, from: g.other(incoming, u), via: u, to: v)
                }
                if candidate < gScore[v] {
                    gScore[v] = candidate
                    prevEdge[v] = Int32(e)
                    heap.push(candidate + h(v), v)
                }
            }
        }

        guard best < .infinity else { throw OfflineRoutingError.noRoute }

        // Strecke als Stücke zusammensetzen.
        var segments: [Segment] = []
        func add(_ from: LatLon, _ to: LatLon, way: Int, endNode: Int) {
            let length = GeoUtils.distanceMeters(from, to)
            guard length > 0.5 || endNode >= 0 else { return }
            segments.append(Segment(from: from, to: to, way: way, endNode: endNode, length: length, time: length / g.speedMps(way: way, profile)))
        }
        let startWay = Int(g.edgeWay[s.edge])
        let targetWay = Int(g.edgeWay[t.edge])
        if direct {
            add(s.point, t.point, way: startWay, endNode: -1)
        } else {
            var nodes = [bestNode]
            var edges: [Int] = []
            var cursor = bestNode
            while prevEdge[cursor] >= 0 {
                let e = Int(prevEdge[cursor])
                edges.append(e)
                cursor = g.other(e, cursor)
                nodes.append(cursor)
                if nodes.count > n { throw OfflineRoutingError.noRoute } // Schutz vor Zyklen
            }
            nodes.reverse()
            edges.reverse()
            add(s.point, g.point(nodes[0]), way: startWay, endNode: nodes[0])
            for (i, e) in edges.enumerated() {
                add(g.point(nodes[i]), g.point(nodes[i + 1]), way: Int(g.edgeWay[e]), endNode: nodes[i + 1])
            }
            add(g.point(nodes[nodes.count - 1]), t.point, way: targetWay, endNode: -1)
        }
        if segments.isEmpty {
            segments.append(Segment(from: s.point, to: t.point, way: startWay, endNode: -1, length: 0, time: 0))
        }

        let geometry = [segments[0].from] + segments.map(\.to)
        return Leg(
            steps: buildSteps(g, segments, profile),
            geometry: geometry,
            distance: segments.reduce(0) { $0 + $1.length },
            duration: segments.reduce(0) { $0 + $1.time }
        )
    }

    // MARK: - Abbiegehinweise

    private struct Draft {
        var type: String
        var modifier: String?
        var exit: Int?
        let location: LatLon
        var name: String
        var distance = 0.0
        var duration = 0.0
        var angle = 0.0
    }

    private func buildSteps(_ g: RoadGraph, _ segs: [Segment], _ profile: RoutingProfile) -> [OsrmStep] {
        var drafts = [Draft(type: "depart", location: segs[0].from, name: g.displayName(way: segs[0].way))]
        var inRoundabout = false
        var exitCount = 0

        for (i, seg) in segs.enumerated() {
            if i > 0, segs[i - 1].endNode >= 0 {
                let prev = segs[i - 1]
                let node = prev.endNode
                let angle = turnAngle(prev, seg)
                let prevRound = g.wayRoundabout[prev.way]
                let nextRound = g.wayRoundabout[seg.way]

                if inRoundabout {
                    if nextRound {
                        if hasExitOption(g, node, profile) { exitCount += 1 }
                    } else {
                        exitCount += 1
                        drafts[drafts.count - 1].exit = exitCount
                        drafts[drafts.count - 1].name = g.displayName(way: seg.way)
                        inRoundabout = false
                    }
                } else if nextRound && !prevRound {
                    drafts.append(Draft(type: "roundabout", location: prev.to, name: ""))
                    inRoundabout = true
                    exitCount = 0
                } else if prev.way != seg.way, let (type, modifier) = maneuver(g, prev, seg, node, angle) {
                    let name = g.displayName(way: seg.way)
                    // Zwei Abbiegungen dicht hintereinander (z.B. Kreuzung mit getrennten
                    // Fahrbahnen) zu einer zusammenfassen.
                    if let last = drafts.last, last.type == "turn", type == "turn", last.distance < 15 {
                        let combined = last.angle + angle
                        drafts[drafts.count - 1].angle = combined
                        drafts[drafts.count - 1].modifier = Self.modifier(for: combined)
                        drafts[drafts.count - 1].name = name
                        // Heben sich beide Abbiegungen auf (Versatz an einer Kreuzung), ist es
                        // effektiv geradeaus — als stille Fortsetzung markieren statt
                        // "Biegen Sie geradeaus ab" anzusagen.
                        if abs(combined) < 20 { drafts[drafts.count - 1].type = "continue" }
                    } else {
                        drafts.append(Draft(type: type, modifier: modifier, location: prev.to, name: name, angle: angle))
                    }
                }
            }
            drafts[drafts.count - 1].distance += seg.length
            drafts[drafts.count - 1].duration += seg.time
        }
        drafts.append(Draft(type: "arrive", location: segs[segs.count - 1].to, name: g.displayName(way: segs[segs.count - 1].way)))

        return drafts.map { d in
            OsrmStep(
                maneuver: OsrmManeuver(type: d.type, modifier: d.modifier, exit: d.exit, location: d.location),
                name: d.name,
                distance: d.distance,
                duration: d.duration,
                destinations: nil,
                exits: nil,
                lanes: nil
            )
        }
    }

    /** Art des Manövers beim Wechsel auf einen anderen Weg; nil = keine Ansage nötig. */
    private func maneuver(_ g: RoadGraph, _ prev: Segment, _ next: Segment, _ node: Int, _ angle: Double) -> (String, String?)? {
        let fromClass = g.wayHighway[prev.way]
        let toClass = g.wayHighway[next.way]
        let side = angle > 0 ? "right" : "left"
        if toClass.isLink && fromClass.isMotorwayLike { return ("off ramp", "slight \(side)") }
        if toClass.isMotorwayLike && fromClass.isLink { return ("merge", "slight \(side)") }

        let isJunction = g.degree(node) > 2
        let sameRoad = !g.displayName(way: prev.way).isEmpty && g.displayName(way: prev.way) == g.displayName(way: next.way)
        // Nur an echten Kreuzungen ansagen — ein Namenswechsel mitten in einer Kurve ist keine
        // Entscheidung für den Fahrer (gleiches Problem wie bei OSRM, siehe CLAUDE.md).
        guard isJunction else { return nil }
        if abs(angle) >= 35 { return ("turn", Self.modifier(for: angle)) }
        if !sameRoad && abs(angle) >= 20 { return ("fork", Self.modifier(for: angle)) }
        return nil
    }

    /**
     * Zeitaufschlag fürs Abbiegen (wie OSRM): ohne ihn wählt der Router gern Zickzack-Wege durch
     * Nebenstraßen, die rechnerisch ein paar Sekunden schneller sind als die Hauptstraße.
     */
    private func turnPenalty(_ g: RoadGraph, from a: Int, via b: Int, to c: Int) -> Double {
        guard g.degree(b) > 2 else { return 0 }
        let inBearing = Self.bearing(g.point(a), g.point(b))
        let outBearing = Self.bearing(g.point(b), g.point(c))
        let angle = abs((outBearing - inBearing + 540).truncatingRemainder(dividingBy: 360) - 180)
        if angle >= 160 { return 60 } // Wenden
        if angle >= 45 { return 7 }
        if angle >= 20 { return 2 }
        return 1 // Kreuzung geradeaus überqueren (Ampeln, Vorfahrt)
    }

    private func hasExitOption(_ g: RoadGraph, _ node: Int, _ profile: RoutingProfile) -> Bool {
        for k in Int(g.adjStart[node])..<Int(g.adjStart[node + 1]) {
            let e = Int(g.adjEdge[k])
            if !g.wayRoundabout[Int(g.edgeWay[e])] && g.canTraverse(e, from: node, profile) { return true }
        }
        return false
    }

    /** Abbiegewinkel in Grad: positiv = rechts, negativ = links, 0 = geradeaus. */
    private func turnAngle(_ a: Segment, _ b: Segment) -> Double {
        let d = Self.bearing(b.from, b.to) - Self.bearing(a.from, a.to)
        return (d + 540).truncatingRemainder(dividingBy: 360) - 180
    }

    private static func bearing(_ a: LatLon, _ b: LatLon) -> Double {
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return atan2(y, x) * 180 / .pi
    }

    private static func modifier(for angle: Double) -> String {
        let a = abs(angle)
        let side = angle > 0 ? "right" : "left"
        if a < 20 { return "straight" }
        if a < 45 { return "slight \(side)" }
        if a < 135 { return side }
        if a < 170 { return "sharp \(side)" }
        return "uturn"
    }
}

/** Binärer Min-Heap (Priorität, Knoten) für die A*-Suche. */
private struct MinHeap {
    private var priorities: [Double] = []
    private var nodes: [Int] = []

    mutating func push(_ priority: Double, _ node: Int) {
        priorities.append(priority)
        nodes.append(node)
        var i = priorities.count - 1
        while i > 0 {
            let parent = (i - 1) / 2
            guard priorities[i] < priorities[parent] else { break }
            priorities.swapAt(i, parent)
            nodes.swapAt(i, parent)
            i = parent
        }
    }

    mutating func pop() -> (Double, Int)? {
        guard !priorities.isEmpty else { return nil }
        let top = (priorities[0], nodes[0])
        let lastP = priorities.removeLast()
        let lastN = nodes.removeLast()
        if !priorities.isEmpty {
            priorities[0] = lastP
            nodes[0] = lastN
            var i = 0
            while true {
                let l = 2 * i + 1, r = l + 1
                var smallest = i
                if l < priorities.count && priorities[l] < priorities[smallest] { smallest = l }
                if r < priorities.count && priorities[r] < priorities[smallest] { smallest = r }
                if smallest == i { break }
                priorities.swapAt(i, smallest)
                nodes.swapAt(i, smallest)
                i = smallest
            }
        }
        return top
    }
}
