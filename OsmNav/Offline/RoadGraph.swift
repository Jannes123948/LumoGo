import Foundation

/**
 * Straßennetz im Speicher, zusammengesetzt aus einem oder mehreren Region-Files (gleiche
 * OSM-Knoten werden über ihre ID verbunden, damit Routen auch über Paketgrenzen hinweg gehen).
 * Kompakte Arrays statt Objekte: auch ein Landkreis mit einigen 100.000 Knoten bleibt klein.
 */
final class RoadGraph {
    private(set) var lat: [Double] = []
    private(set) var lon: [Double] = []

    private(set) var wayOsmId: [Int64] = []
    private(set) var wayAccess: [RoadAccess] = []
    private(set) var wayHighway: [HighwayClass] = []
    private(set) var wayRoundabout: [Bool] = []
    private(set) var waySpeed: [Float] = []
    private(set) var wayName: [String] = []
    private(set) var wayRef: [String] = []

    private(set) var edgeA: [Int32] = []
    private(set) var edgeB: [Int32] = []
    private(set) var edgeWay: [Int32] = []
    private(set) var edgeLength: [Float] = []

    /** Adjazenz im CSR-Format: Kanten von Knoten `u` = `adjEdge[adjStart[u]..<adjStart[u+1]]`. */
    private(set) var adjStart: [Int32] = []
    private(set) var adjEdge: [Int32] = []

    /** Abbiegeverbote je Kreuzungsknoten: (von OSM-Weg, nach OSM-Weg, nur-erlaubt). */
    private(set) var restrictions: [Int32: [(from: Int64, to: Int64, only: Bool)]] = [:]

    /** Räumlicher Index (~1 km-Zellen) für das Einrasten von Start/Ziel auf die nächste Straße. */
    static let cellDegrees = 0.01
    private(set) var grid: [Int64: [Int32]] = [:]

    var nodeCount: Int { lat.count }

    init(files: [URL]) throws {
        var nodeIndex: [Int64: Int32] = [:]
        var seenEdges = Set<EdgeKey>()
        let dedupe = files.count > 1

        for url in files {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            try data.withUnsafeBytes { buffer in
                var reader = BinaryReader(buffer)
                guard try reader.read(UInt32.self) == RoadDataStore.magic,
                      try reader.read(UInt8.self) == RoadDataStore.version else { throw AppError.parse }

                let wayOffset = Int32(wayAccess.count)
                let wayCount = Int(try reader.read(UInt32.self))
                var wayOsmIds: [Int64] = []
                wayOsmIds.reserveCapacity(wayCount)
                for _ in 0..<wayCount {
                    let osmId = try reader.read(Int64.self)
                    wayOsmIds.append(osmId)
                    wayOsmId.append(osmId)
                    wayAccess.append(RoadAccess(rawValue: try reader.read(UInt8.self)))
                    wayHighway.append(HighwayClass(rawValue: try reader.read(UInt8.self)) ?? .road)
                    wayRoundabout.append(try reader.read(UInt8.self) == 1)
                    waySpeed.append(try reader.readFloat())
                    wayName.append(try reader.readString())
                    wayRef.append(try reader.readString())
                }

                let nodeTotal = Int(try reader.read(UInt32.self))
                var localToGlobal = [Int32](repeating: 0, count: nodeTotal)
                var localOsmIds = [Int64](repeating: 0, count: nodeTotal)
                for i in 0..<nodeTotal {
                    let osmId = try reader.read(Int64.self)
                    let la = try reader.readDouble()
                    let lo = try reader.readDouble()
                    localOsmIds[i] = osmId
                    if let existing = nodeIndex[osmId] {
                        localToGlobal[i] = existing
                    } else {
                        let index = Int32(lat.count)
                        nodeIndex[osmId] = index
                        lat.append(la)
                        lon.append(lo)
                        localToGlobal[i] = index
                    }
                }

                let edgeTotal = Int(try reader.read(UInt32.self))
                for _ in 0..<edgeTotal {
                    let a = Int(try reader.read(UInt32.self))
                    let b = Int(try reader.read(UInt32.self))
                    let w = Int(try reader.read(UInt32.self))
                    guard a < nodeTotal, b < nodeTotal, w < wayCount else { throw AppError.parse }
                    if dedupe {
                        // Überlappende Pakete enthalten dieselben Wege doppelt.
                        guard seenEdges.insert(EdgeKey(way: wayOsmIds[w], a: localOsmIds[a], b: localOsmIds[b])).inserted else { continue }
                    }
                    let ga = localToGlobal[a]
                    let gb = localToGlobal[b]
                    edgeA.append(ga)
                    edgeB.append(gb)
                    edgeWay.append(wayOffset + Int32(w))
                    edgeLength.append(Float(GeoUtils.distanceMeters(point(Int(ga)), point(Int(gb)))))
                }

                let restrictionCount = Int(try reader.read(UInt32.self))
                var seenRestrictions = Set<String>()
                for _ in 0..<restrictionCount {
                    let from = try reader.read(Int64.self)
                    let via = try reader.read(Int64.self)
                    let to = try reader.read(Int64.self)
                    let only = try reader.read(UInt8.self) == 1
                    guard let node = nodeIndex[via], seenRestrictions.insert("\(from)-\(via)-\(to)").inserted else { continue }
                    restrictions[node, default: []].append((from, to, only))
                }
            }
        }
        buildAdjacency()
        buildGrid()
    }

    private struct EdgeKey: Hashable {
        let way: Int64
        let a: Int64
        let b: Int64
    }

    private func buildAdjacency() {
        var degree = [Int32](repeating: 0, count: nodeCount + 1)
        for e in edgeA.indices {
            degree[Int(edgeA[e])] += 1
            degree[Int(edgeB[e])] += 1
        }
        adjStart = [Int32](repeating: 0, count: nodeCount + 1)
        for u in 0..<nodeCount { adjStart[u + 1] = adjStart[u] + degree[u] }
        var fill = adjStart
        adjEdge = [Int32](repeating: 0, count: edgeA.count * 2)
        for e in edgeA.indices {
            let a = Int(edgeA[e]), b = Int(edgeB[e])
            adjEdge[Int(fill[a])] = Int32(e); fill[a] += 1
            adjEdge[Int(fill[b])] = Int32(e); fill[b] += 1
        }
    }

    private func buildGrid() {
        for e in edgeA.indices {
            let a = Int(edgeA[e]), b = Int(edgeB[e])
            let rows = Self.cell(min(lat[a], lat[b]))...Self.cell(max(lat[a], lat[b]))
            let cols = Self.cell(min(lon[a], lon[b]))...Self.cell(max(lon[a], lon[b]))
            for r in rows { for c in cols { grid[Self.key(r, c), default: []].append(Int32(e)) } }
        }
    }

    static func cell(_ degrees: Double) -> Int { Int(floor(degrees / cellDegrees)) }
    static func key(_ row: Int, _ col: Int) -> Int64 { (Int64(row) << 32) | Int64(UInt32(bitPattern: Int32(truncatingIfNeeded: col))) }

    func point(_ node: Int) -> LatLon { LatLon(lat[node], lon[node]) }

    /** Anzahl angrenzender Straßenstücke — >2 heißt Kreuzung/Abzweig. */
    func degree(_ node: Int) -> Int { Int(adjStart[node + 1] - adjStart[node]) }

    func other(_ edge: Int, _ node: Int) -> Int { Int(edgeA[edge]) == node ? Int(edgeB[edge]) : Int(edgeA[edge]) }

    /** Darf [edge] mit [profile] von [node] aus befahren werden? */
    func canTraverse(_ edge: Int, from node: Int, _ profile: RoutingProfile) -> Bool {
        let access = wayAccess[Int(edgeWay[edge])]
        let forward = Int(edgeA[edge]) == node
        switch profile {
        case .car: return access.contains(forward ? .carForward : .carBackward)
        case .bike: return access.contains(forward ? .bikeForward : .bikeBackward)
        case .foot: return access.contains(.foot)
        }
    }

    func isUsable(_ edge: Int, _ profile: RoutingProfile) -> Bool {
        canTraverse(edge, from: Int(edgeA[edge]), profile) || canTraverse(edge, from: Int(edgeB[edge]), profile)
    }

    /** Erlaubt ein Abbiegeverbot am Knoten [node] den Wechsel von [fromEdge] auf [toEdge]? */
    func turnAllowed(at node: Int, from fromEdge: Int, to toEdge: Int) -> Bool {
        guard let rules = restrictions[Int32(node)] else { return true }
        let fromWay = wayOsmId[Int(edgeWay[fromEdge])]
        let toWay = wayOsmId[Int(edgeWay[toEdge])]
        for rule in rules where rule.from == fromWay {
            if rule.only ? rule.to != toWay : rule.to == toWay { return false }
        }
        return true
    }

    func speedMps(way: Int, _ profile: RoutingProfile) -> Double {
        switch profile {
        case .car: return Double(waySpeed[way]) / 3.6
        case .bike: return wayHighway[way].bikeSpeed / 3.6
        case .foot: return wayHighway[way].footSpeed / 3.6
        }
    }

    /** Fahrzeit in Sekunden für die ganze Kante. */
    func cost(_ edge: Int, _ profile: RoutingProfile) -> Double {
        let way = Int(edgeWay[edge])
        let time = Double(edgeLength[edge]) / speedMps(way: way, profile)
        // Anliegerstraßen nicht als Abkürzung nutzen (wie OSRM) — hoher Aufschlag statt Verbot,
        // damit Start/Ziel in einer solchen Straße weiterhin erreichbar bleiben.
        if profile == .car && wayAccess[way].contains(.carDestinationOnly) { return time * 10 + 60 }
        return time
    }

    /** Name für Ansagen: Straßenname, sonst Straßennummer (z.B. "B 170"). */
    func displayName(way: Int) -> String { wayName[way].isEmpty ? wayRef[way] : wayName[way] }
}
