import Foundation

/**
 * Baut das Offline-Straßennetz aus z14-Vektorkacheln (OpenMapTiles-Schema: Layer `transportation`,
 * Namen aus `transportation_name`) — im selben Binärformat wie früher der Overpass-Download, damit
 * [RoadGraph] und [OfflineRouter] unverändert bleiben.
 *
 * Was die Kacheln NICHT haben und hier fehlt: Abbiegeverbote, `maxspeed` (→ Tempo nach Straßenklasse,
 * innerorts 50 über bebaute `landuse`-Flächen + Gebäudedichte), Kreisverkehr-Markierung (→ Form-Erkennung),
 * Wohn-/Anliegerstraßen-Unterscheidung (`minor` → innerorts residential, außerorts unclassified).
 *
 * Koordinaten: global ganzzahlig im z14-Raster (Kachel × 4096 + Kachelkoordinate, ≈ 0,4 m in
 * Deutschland). Gleiche OSM-Knoten liegen dadurch in allen Kacheln auf demselben Rasterpunkt.
 * Schritte:
 *  1. jede Linie exakt auf IHRE Kachel zuschneiden (der Puffer jeder Kachel enthält Teile der
 *     Nachbarn — sonst doppelte bzw. halbe Stücke), Randpunkte benachbarter Kacheln verschmelzen;
 *  2. „Knoten ergänzen": OpenFreeMap vereinfacht gerade Linien und entfernt dabei Kreuzungspunkte
 *     (Dresden-Testkachel: 218 von 1.179 Einmündungen ohne gemeinsamen Punkt) — Punkte, die auf
 *     einem fremden Segment liegen, und echte Schnittpunkte werden eingefügt, aber nur bei gleicher
 *     Ebene (`layer`, Brücke/Tunnel), damit Brücken nicht mit der Straße darunter verbunden werden;
 *  3. Namen per Nähe + Richtung aus `transportation_name`; 4. Kreisverkehre = kurze Einbahn-Ringe.
 */
enum TileRoadBuilder {
    private static let tileExtent: Int64 = 4096
    private static let worldSize = Double(Int64(1) << 26) // 2^14 Kacheln × 4096
    /** Kachel-Puffer-Linien liegen exakt auf dem Rand; Kreuzungen werden bis hierhin ergänzt (Rastereinheiten). */
    private static let snapTolerance = 2.0
    private static let cellSize: Int64 = 64
    /** Kachel-IDs haben keine OSM-IDs — Bit 62 markiert die synthetischen (nie Kollision mit OSM). */
    private static let syntheticFlag: Int64 = 1 << 62

    private struct Feature {
        let tags: [String: String]
        let layerKey: Int
        let className: String
    }

    private struct Run {
        let feature: Int32
        var nodes: [Int64]
    }

    private struct NameSegment {
        let ax: Double, ay: Double, bx: Double, by: Double
        let name: Int32
    }

    /** Ein fertig gebauter Block des Straßennetzes (eigene Datei in [RoadDataStore]). */
    struct Part {
        let boundingBox: BoundingBox
        let data: Data
        let nodeCount: Int
    }

    /** Blockgröße in Kacheln: ≈ 600 Kacheln ≈ 35 × 35 km brauchen beim Bauen ≈ 250 MB — ein ganzes
     *  Gebiet auf einmal (Test 1.073 Kacheln: 440 MB) würde bei Bundesländern das iPhone sprengen. */
    private static let blockTiles = 24

    /**
     * Lädt die Kacheln eines Gebiets (zuerst aus MapLibres Datenbank [databasePath]) und baut das
     * Straßennetz blockweise. Nachbarblöcke überlappen um eine Kachelreihe: deren Knoten-IDs (aus
     * dem globalen Raster) sind in beiden Blöcken gleich, [RoadGraph] verbindet die Blöcke darüber.
     * [progress]: Text für die Paketliste + Anteil 0…1 (Prozentanzeige neben der Suchleiste).
     */
    static func download(_ bbox: BoundingBox, includePaths: Bool, databasePath: String?, preferNetwork: Bool = false,
                         progress: @escaping (String, Double) -> Void) async throws -> [Part] {
        let range = VectorTileSource.tileRange(bbox)
        func starts(_ r: ClosedRange<Int>) -> [Int] {
            stride(from: r.lowerBound, through: max(r.lowerBound, r.upperBound - 1), by: blockTiles - 1).map { $0 }
        }
        var blocks: [(xs: ClosedRange<Int>, ys: ClosedRange<Int>)] = []
        for x in starts(range.xs) {
            for y in starts(range.ys) {
                blocks.append((x...min(x + blockTiles - 1, range.xs.upperBound), y...min(y + blockTiles - 1, range.ys.upperBound)))
            }
        }
        let totalTiles = blocks.reduce(0) { $0 + $1.xs.count * $1.ys.count }
        var doneTiles = 0
        var parts: [Part] = []
        for (i, block) in blocks.enumerated() {
            try Task.checkCancellation()
            let offset = doneTiles
            let tiles = try await VectorTileSource.load(block, databasePath: databasePath, preferNetwork: preferNetwork) { done, _ in
                // Laden ≈ 70 %, Bauen ≈ 30 % der Zeit.
                progress("Kacheln \(offset + done)/\(totalTiles)", 0.7 * Double(offset + done) / Double(max(totalTiles, 1)))
            }
            doneTiles += block.xs.count * block.ys.count
            progress(blocks.count > 1 ? "Block \(i + 1)/\(blocks.count) wird gebaut …" : "wird gebaut …",
                     0.7 + 0.3 * Double(i) / Double(blocks.count))
            // Leerer Block (Meer, Grenzgebiet ohne Straßen) ist kein Fehler.
            guard let (data, nodes) = try? build(tiles, includePaths: includePaths) else { continue }
            parts.append(Part(boundingBox: boundingBox(block), data: data, nodeCount: nodes))
        }
        guard !parts.isEmpty else { throw AppError.noResults }
        return parts
    }

    private static func boundingBox(_ block: (xs: ClosedRange<Int>, ys: ClosedRange<Int>)) -> BoundingBox {
        let n = Double(1 << VectorTileSource.zoom)
        func lon(_ x: Int) -> Double { Double(x) / n * 360 - 180 }
        func lat(_ y: Int) -> Double { atan(sinh(.pi * (1 - 2 * Double(y) / n))) * 180 / .pi }
        return BoundingBox(south: lat(block.ys.upperBound + 1), north: lat(block.ys.lowerBound),
                           west: lon(block.xs.lowerBound), east: lon(block.xs.upperBound + 1))
    }

    /** [includePaths] = auch Feld-, Rad- und Fußwege (wie beim Overpass-Download, Einstellung `offline_paths`). */
    static func build(_ tiles: [TileData], includePaths: Bool = true) throws -> (Data, Int) {
        var features: [Feature] = []
        var runs: [Run] = []
        var borderNodes = Set<Int64>()
        var names: [(name: String, ref: String)] = []
        var nameSegments: [NameSegment] = []
        var urbanCells = Set<Int64>()
        var buildingCells: [Int64: Double] = [:]

        for tile in tiles {
            guard let vt = try? VectorTile(data: tile.data, onlyLayers: ["transportation", "transportation_name", "landuse", "building"]) else { continue }
            let x0 = Int64(tile.x) * tileExtent, y0 = Int64(tile.y) * tileExtent
            if let layer = vt.layers["landuse"] {
                rasterizeUrban(layer, x0: x0, y0: y0, into: &urbanCells)
            }
            if let layer = vt.layers["building"] {
                countBuildings(layer, x0: x0, y0: y0, into: &buildingCells)
            }
            if let layer = vt.layers["transportation"] {
                let scale = Double(tileExtent) / Double(layer.extent)
                for f in layer.features where f.type == .line {
                    guard let tags = synthesizeTags(f.properties),
                          includePaths || !pathHighways.contains(tags["highway"] ?? "") else { continue }
                    let featureIndex = Int32(features.count)
                    features.append(Feature(tags: tags, layerKey: layerKey(f.properties), className: f.properties["class"]?.string ?? ""))
                    for part in f.geometry where part.count >= 2 {
                        let pts = part.map { (Double(x0) + Double($0.x) * scale, Double(y0) + Double($0.y) * scale) }
                        clipPart(pts, x0: Double(x0), y0: Double(y0), feature: featureIndex, runs: &runs, borderNodes: &borderNodes)
                    }
                }
            }
            if let layer = vt.layers["transportation_name"] {
                let scale = Double(tileExtent) / Double(layer.extent)
                for f in layer.features where f.type == .line {
                    // Autobahnen haben oft nur `ref` („A 4“), keinen Namen.
                    let name = f.properties["name"]?.string ?? "", ref = f.properties["ref"]?.string ?? ""
                    guard !name.isEmpty || !ref.isEmpty else { continue }
                    let nameIndex = Int32(names.count)
                    names.append((name, ref))
                    for part in f.geometry where part.count >= 2 {
                        for i in 0..<(part.count - 1) {
                            nameSegments.append(NameSegment(
                                ax: Double(x0) + Double(part[i].x) * scale, ay: Double(y0) + Double(part[i].y) * scale,
                                bx: Double(x0) + Double(part[i + 1].x) * scale, by: Double(y0) + Double(part[i + 1].y) * scale,
                                name: nameIndex))
                        }
                    }
                }
            }
        }
        guard !runs.isEmpty else { throw AppError.noResults }

        mergeBorderNodes(&runs, borderNodes: borderNodes)
        addMissingJunctions(&runs, features: features)

        // Wege + Koordinaten fürs Binärformat.
        let runNames = assignNames(runs, names: names, segments: nameSegments)
        let roundabouts = detectRoundabouts(runs, features: features)
        let carIslands = isolatedCarRuns(runs, features: features, tiles: tiles)
        var ways: [Int64: (WayRecord, [Int64])] = [:]
        var coordinates: [Int64: (Double, Double)] = [:]
        for (i, run) in runs.enumerated() where run.nodes.count >= 2 {
            var tags = features[Int(run.feature)].tags
            if let n = runNames[i] {
                if !names[Int(n)].name.isEmpty { tags["name"] = names[Int(n)].name }
                if !names[Int(n)].ref.isEmpty { tags["ref"] = names[Int(n)].ref }
            }
            if roundabouts.contains(i) { tags["junction"] = "roundabout" }
            applyUrbanSpeed(&tags, urban: isUrban(run, urbanCells, buildingCells))
            if carIslands.contains(i) { tags["motor_vehicle"] = "no" }
            let id = syntheticWayId(run.nodes)
            guard let record = WayRecord.from(osmId: id, tags: tags) else { continue }
            let nodeIds = run.nodes.map { syntheticFlag | $0 }
            ways[id] = (record, nodeIds)
            for (k, nodeId) in zip(run.nodes, nodeIds) where coordinates[nodeId] == nil {
                coordinates[nodeId] = latLon(k)
            }
        }
        guard !ways.isEmpty else { throw AppError.noResults }
        return (RoadDataBuilder.encode(ways: ways, coordinates: coordinates, restrictions: []), coordinates.count)
    }

    /**
     * Weg-ID aus der Geometrie (erster, zweiter, letzter Punkt) statt fortlaufend: dieselbe Straße
     * bekommt in überlappenden Paketen dieselbe ID → [RoadGraph] erkennt die Kanten als doppelt.
     * SplitMix64 statt `Hasher` (der ist je Prozess zufällig geseedet).
     */
    private static func syntheticWayId(_ nodes: [Int64]) -> Int64 {
        var h: UInt64 = 0x9E37_79B9_7F4A_7C15
        for k in [nodes[0], nodes[1], nodes[nodes.count - 1]] {
            h ^= UInt64(bitPattern: k)
            h = (h ^ (h >> 30)) &* 0xBF58_476D_1CE4_E5B9
            h = (h ^ (h >> 27)) &* 0x94D0_49BB_1331_11EB
            h ^= h >> 31
        }
        return syntheticFlag | Int64(bitPattern: h & 0x3FFF_FFFF_FFFF_FFFF)
    }

    // MARK: - Attribute

    /** Ohne „Rad- und Fußwege mitladen“ weggelassen (wie `pathClasses` beim Overpass-Download). */
    private static let pathHighways: Set<String> = ["track", "footway", "cycleway", "pedestrian", "steps", "bridleway", "path"]

    /** OpenMapTiles-Attribute → OSM-artige Tags für [WayRecord.from]; nil = nicht routbar. */
    private static func synthesizeTags(_ p: [String: VectorTile.Value]) -> [String: String]? {
        if p["indoor"]?.int == 1 { return nil }
        let cls = p["class"]?.string ?? ""
        let subclass = p["subclass"]?.string ?? ""
        let ramp = p["ramp"]?.int == 1
        let highway: String
        switch cls {
        case "motorway", "trunk", "primary", "secondary", "tertiary":
            highway = ramp ? "\(cls)_link" : cls
        case "minor":
            highway = "road"
        case "service":
            if ["parking_aisle", "driveway", "drive-through"].contains(p["service"]?.string ?? "") { return nil }
            highway = "service"
        case "track":
            highway = "track"
        case "path":
            guard ["footway", "cycleway", "pedestrian", "steps", "bridleway", "path"].contains(subclass) else { return nil }
            highway = subclass
        default:
            return nil // rail, transit, ferry, pier, bridge, busway, raceway, aerialway …
        }
        var tags = ["highway": highway]
        switch p["oneway"]?.int {
        case 1: tags["oneway"] = "yes"
        case -1: tags["oneway"] = "-1"
        default: break
        }
        if p["access"]?.string == "no" { tags["access"] = "no" }
        if let b = p["bicycle"]?.string, b != "unknown" { tags["bicycle"] = b }
        if let f = p["foot"]?.string, f != "unknown" { tags["foot"] = f }
        return tags
    }

    /** Ebene: `layer` + Brücke/Tunnel — nur gleiche Ebenen werden beim Knotenergänzen verbunden. */
    private static func layerKey(_ p: [String: VectorTile.Value]) -> Int {
        let layer = Int(p["layer"]?.int ?? 0)
        switch p["brunnel"]?.string {
        case "bridge": return layer * 10 + 1
        case "tunnel": return layer * 10 + 2
        default: return layer * 10
        }
    }

    // MARK: - Ortschaften

    /** Bebaute Flächen (`landuse`) — dort gilt innerorts Tempo 50 bzw. sind Nebenstraßen Wohnstraßen. */
    private static let urbanLanduse: Set<String> = [
        "residential", "commercial", "industrial", "retail", "garages", "suburb", "quarter", "neighbourhood",
        "hospital", "school", "university", "college", "kindergarten"
    ]
    /** Rasterzelle der Ortschafts-Erkennung (Rastereinheiten, ≈ 48 m in Deutschland). */
    private static let urbanCell: Int64 = 128
    /** Rasterzelle der Gebäudezählung (≈ 190 m). */
    private static let buildingCell: Int64 = 512

    /** Füllt die bebauten Flächen einer Kachel ins globale Zellraster (Scanline, gerade-ungerade-Regel
     *  über alle Ringe → Löcher bleiben frei). */
    private static func rasterizeUrban(_ layer: VectorTile.Layer, x0: Int64, y0: Int64, into cells: inout Set<Int64>) {
        let scale = Double(tileExtent) / Double(layer.extent)
        let perTile = tileExtent / urbanCell
        for f in layer.features where f.type == .polygon && urbanLanduse.contains(f.properties["class"]?.string ?? "") {
            let rings = f.geometry.map { $0.map { (Double($0.x) * scale, Double($0.y) * scale) } }
            for row in 0..<perTile {
                let y = (Double(row) + 0.5) * Double(urbanCell)
                var xs: [Double] = []
                for ring in rings where ring.count >= 3 {
                    for i in ring.indices {
                        let a = ring[i], b = ring[(i + 1) % ring.count]
                        if (a.1 <= y) != (b.1 <= y) { xs.append(a.0 + (y - a.1) / (b.1 - a.1) * (b.0 - a.0)) }
                    }
                }
                guard xs.count >= 2 else { continue }
                xs.sort()
                var i = 0
                while i + 1 < xs.count {
                    let c0 = max(0, Int64(((xs[i] / Double(urbanCell)) - 0.5).rounded(.up)))
                    let c1 = min(perTile - 1, Int64(((xs[i + 1] / Double(urbanCell)) - 0.5).rounded(.down)))
                    if c0 <= c1 {
                        for c in c0...c1 { cells.insert(key(x0 / urbanCell + c, y0 / urbanCell + row)) }
                    }
                    i += 2
                }
            }
        }
    }

    /**
     * Gebäudegrundfläche je Zelle (Rastereinheiten², je Ring der Zelle seines Mittelpunkts
     * zugeschlagen; nur Zellen der eigenen Kachel). Fläche statt Anzahl, und ALLE Ringe: die Kacheln
     * fassen hunderte Gebäude zu einem Multipolygon zusammen (Dresden-Löbtau: 46 Objekte, 1.030 Ringe).
     * Vorzeichenbehaftet: Außenringe positiv, Innenhöfe (Löcher) negativ.
     */
    private static func countBuildings(_ layer: VectorTile.Layer, x0: Int64, y0: Int64, into cells: inout [Int64: Double]) {
        let scale = Double(tileExtent) / Double(layer.extent)
        for f in layer.features where f.type == .polygon {
            for ring in f.geometry where ring.count >= 3 {
                let cx = ring.reduce(0.0) { $0 + Double($1.x) } / Double(ring.count) * scale
                let cy = ring.reduce(0.0) { $0 + Double($1.y) } / Double(ring.count) * scale
                guard cx >= 0, cy >= 0, cx < Double(tileExtent), cy < Double(tileExtent) else { continue }
                var area = 0.0
                for i in ring.indices {
                    let a = ring[i], b = ring[(i + 1) % ring.count]
                    area += Double(a.x) * Double(b.y) - Double(b.x) * Double(a.y)
                }
                cells[key((x0 + Int64(cx)) / buildingCell, (y0 + Int64(cy)) / buildingCell), default: 0] += area / 2 * scale * scale
            }
        }
    }

    /**
     * Bebaut = in `landuse`-Fläche ODER ≥ 2 % Gebäudegrundfläche in den 3 × 3 Gebäudezellen ringsum
     * (≈ 580 × 580 m; Stadt 15–40 %, Dorf um 2 %, Feld mit Einzelhof < 0,5 %).
     * Viele Innenstädte haben keine `landuse=residential`-Flächen; der große Umkreis erfasst auch
     * breite Stadtstraßen an Parks/Bahnanlagen (Test Antonstraße Dresden), Einzelhöfe bleiben außerorts.
     */
    private static func isUrbanPoint(_ x: Int64, _ y: Int64, _ cells: Set<Int64>, _ buildings: [Int64: Double]) -> Bool {
        if cells.contains(key(x / urbanCell, y / urbanCell)) { return true }
        let bx = x / buildingCell, by = y / buildingCell
        let threshold = 0.02 * Double(9 * buildingCell * buildingCell)
        var area = 0.0
        for dx in -1...1 {
            for dy in -1...1 {
                area += buildings[key(bx + Int64(dx), by + Int64(dy))] ?? 0
                if area >= threshold { return true }
            }
        }
        return false
    }

    /** Liegt der Weg überwiegend (nach Länge) in bebautem Gebiet? Stichproben alle ≈ 48 m. */
    private static func isUrban(_ run: Run, _ cells: Set<Int64>, _ buildings: [Int64: Double]) -> Bool {
        guard !cells.isEmpty || !buildings.isEmpty else { return false }
        var inside = 0.0, total = 0.0
        for i in 0..<(run.nodes.count - 1) {
            let (ax, ay) = coords(run.nodes[i]), (bx, by) = coords(run.nodes[i + 1])
            let len = hypot(Double(bx - ax), Double(by - ay))
            let samples = max(1, Int(len / Double(urbanCell)))
            for s in 0..<samples {
                let t = (Double(s) + 0.5) / Double(samples)
                let x = Int64(Double(ax) + t * Double(bx - ax)), y = Int64(Double(ay) + t * Double(by - ay))
                if isUrbanPoint(x, y, cells, buildings) { inside += len / Double(samples) }
            }
            total += len
        }
        return total > 0 && inside / total > 0.5
    }

    /**
     * Die Kacheln haben kein `maxspeed`: innerorts bekommen Hauptstraßen „DE:urban“ (sonst rechnete
     * der Router mit 70 km/h quer durch die Stadt und mied die Autobahn), Nebenstraßen (`minor`)
     * werden innerorts Wohnstraßen (25 km/h), außerorts Gemeindeverbindungen (40 km/h).
     */
    private static func applyUrbanSpeed(_ tags: inout [String: String], urban: Bool) {
        switch tags["highway"] ?? "" {
        case "road":
            tags["highway"] = urban ? "residential" : "unclassified"
        case "trunk", "trunk_link", "primary", "primary_link", "secondary", "secondary_link", "tertiary", "tertiary_link":
            if urban { tags["maxspeed"] = "DE:urban" }
        default:
            break
        }
    }

    // MARK: - Zuschneiden

    private static func key(_ x: Int64, _ y: Int64) -> Int64 { x << 32 | y }
    private static func coords(_ k: Int64) -> (Int64, Int64) { (k >> 32, k & 0xFFFF_FFFF) }

    private static func latLon(_ k: Int64) -> (Double, Double) {
        let (x, y) = coords(k)
        let lon = Double(x) / worldSize * 360 - 180
        let lat = atan(sinh(.pi * (1 - 2 * Double(y) / worldSize))) * 180 / .pi
        return (lat, lon)
    }

    /** Schneidet eine Linie auf die eigene Kachel [x0, x0+4096]² zu und hängt die Stücke an [runs]. */
    private static func clipPart(_ pts: [(Double, Double)], x0: Double, y0: Double, feature: Int32,
                                 runs: inout [Run], borderNodes: inout Set<Int64>) {
        let x1 = x0 + Double(tileExtent), y1 = y0 + Double(tileExtent)
        var current: [Int64] = []
        func close() {
            if current.count >= 2 { runs.append(Run(feature: feature, nodes: current)) }
            current = []
        }
        for i in 0..<(pts.count - 1) {
            guard let (a, b, aOnBorder, bOnBorder) = clipSegment(pts[i], pts[i + 1], x0, y0, x1, y1) else {
                close()
                continue
            }
            if aOnBorder { borderNodes.insert(a) }
            if bOnBorder { borderNodes.insert(b) }
            if a == b { continue }
            if current.last != a { close(); current = [a] }
            current.append(b)
            if bOnBorder { close() }
        }
        close()
    }

    /**
     * Liang-Barsky-Zuschnitt. Deterministisch: gerechnet wird immer vom lexikografisch kleineren
     * Endpunkt aus, damit Nachbarkacheln für dasselbe Segment denselben Randpunkt erhalten.
     * Liefert gerundete Rasterpunkte; „OnBorder" = durch den Schnitt entstanden.
     */
    private static func clipSegment(_ p: (Double, Double), _ q: (Double, Double),
                                    _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> (Int64, Int64, Bool, Bool)? {
        let swapped = (q.0, q.1) < (p.0, p.1)
        let s = swapped ? q : p, e = swapped ? p : q
        let dx = e.0 - s.0, dy = e.1 - s.1
        var t0 = 0.0, t1 = 1.0
        for (pp, qq) in [(-dx, s.0 - x0), (dx, x1 - s.0), (-dy, s.1 - y0), (dy, y1 - s.1)] {
            if pp == 0 {
                if qq < 0 { return nil }
            } else {
                let r = qq / pp
                if pp < 0 { if r > t1 { return nil }; if r > t0 { t0 = r } }
                else { if r < t0 { return nil }; if r < t1 { t1 = r } }
            }
        }
        if t0 >= t1 { return nil }
        func point(_ t: Double) -> Int64 {
            var x = s.0 + t * dx, y = s.1 + t * dy
            // Auf dem Rand: die Randkoordinate exakt setzen (sonst Rundungsdrift zwischen Kacheln).
            for border in [x0, x1] where abs(x - border) < 1e-6 { x = border }
            for border in [y0, y1] where abs(y - border) < 1e-6 { y = border }
            return key(Int64(x.rounded()), Int64(y.rounded()))
        }
        let ks = point(t0), ke = point(t1)
        let sBorder = t0 > 0, eBorder = t1 < 1
        return swapped ? (ke, ks, eBorder, sBorder) : (ks, ke, sBorder, eBorder)
    }

    /**
     * Randpunkte derselben Straße aus zwei Nachbarkacheln können um eine Rastereinheit abweichen
     * (eine Kachel kennt den echten Endpunkt, die andere nur den vom Kachel-Generator gekappten).
     * Punkte auf derselben Randlinie mit ≤ 2 Einheiten Abstand werden verschmolzen.
     */
    private static func mergeBorderNodes(_ runs: inout [Run], borderNodes: Set<Int64>) {
        var vertical: [Int64: [Int64]] = [:]   // x-Randlinie → y-Werte
        var horizontal: [Int64: [Int64]] = [:] // y-Randlinie → x-Werte
        for k in borderNodes {
            let (x, y) = coords(k)
            if x % tileExtent == 0 { vertical[x, default: []].append(y) }
            if y % tileExtent == 0 { horizontal[y, default: []].append(x) }
        }
        var remap: [Int64: Int64] = [:]
        for (x, ys) in vertical {
            var anchor: Int64?
            for y in ys.sorted() {
                if let a = anchor, y - a <= 2 { remap[key(x, y)] = key(x, a) } else { anchor = y }
            }
        }
        for (y, xs) in horizontal {
            var anchor: Int64?
            for x in xs.sorted() {
                if let a = anchor, x - a <= 2 { remap[key(x, y)] = remap[key(a, y)] ?? key(a, y) } else { anchor = x }
            }
        }
        guard !remap.isEmpty else { return }
        for i in runs.indices {
            var out: [Int64] = []
            for k in runs[i].nodes {
                let m = remap[k] ?? k
                if out.last != m { out.append(m) }
            }
            runs[i].nodes = out
        }
    }

    // MARK: - Fehlende Kreuzungen ergänzen

    private static func addMissingJunctions(_ runs: inout [Run], features: [Feature]) {
        // Segmente indizieren (Raster ~24 m).
        var segRun: [Int32] = [], segPos: [Int32] = []
        var grid: [Int64: [Int32]] = [:]
        for (r, run) in runs.enumerated() where run.nodes.count >= 2 {
            for i in 0..<(run.nodes.count - 1) {
                let s = Int32(segRun.count)
                segRun.append(Int32(r)); segPos.append(Int32(i))
                let (ax, ay) = coords(run.nodes[i]), (bx, by) = coords(run.nodes[i + 1])
                let cx0 = (min(ax, bx) - 3) / cellSize, cx1 = (max(ax, bx) + 3) / cellSize
                let cy0 = (min(ay, by) - 3) / cellSize, cy1 = (max(ay, by) + 3) / cellSize
                for cx in cx0...cx1 { for cy in cy0...cy1 { grid[key(cx, cy), default: []].append(s) } }
            }
        }
        // Ebenen je Knoten (ein Knoten kann zu mehreren Wegen gehören).
        var nodeLayers: [Int64: Set<Int>] = [:]
        for run in runs {
            let lk = features[Int(run.feature)].layerKey
            for k in run.nodes { nodeLayers[k, default: []].insert(lk) }
        }

        var splits: [Int32: [(t: Double, k: Int64)]] = [:]
        func segEnds(_ s: Int32) -> (Int64, Int64) {
            let run = runs[Int(segRun[Int(s)])], i = Int(segPos[Int(s)])
            return (run.nodes[i], run.nodes[i + 1])
        }

        // (a) Knoten, die auf dem Inneren eines fremden Segments liegen (vereinfachte Einmündung).
        for (k, layers) in nodeLayers {
            let (px, py) = coords(k)
            guard let candidates = grid[key(px / cellSize, py / cellSize)] else { continue }
            for s in candidates {
                let lk = features[Int(runs[Int(segRun[Int(s)])].feature)].layerKey
                guard layers.contains(lk) else { continue }
                let (a, b) = segEnds(s)
                if a == k || b == k { continue }
                let (ax, ay) = coords(a), (bx, by) = coords(b)
                let dx = Double(bx - ax), dy = Double(by - ay)
                let len2 = dx * dx + dy * dy
                guard len2 > 0 else { continue }
                let t = (Double(px - ax) * dx + Double(py - ay) * dy) / len2
                guard t > 0.0001 && t < 0.9999 else { continue }
                let d = hypot(Double(ax) + t * dx - Double(px), Double(ay) + t * dy - Double(py))
                if d <= snapTolerance { splits[s, default: []].append((t, k)) }
            }
        }

        // (b) Echte Schnittpunkte zweier Segmente gleicher Ebene ohne gemeinsamen Punkt.
        for (cell, segs) in grid where segs.count > 1 {
            for i in 0..<segs.count {
                for j in (i + 1)..<segs.count {
                    let s1 = segs[i], s2 = segs[j]
                    guard segRun[Int(s1)] != segRun[Int(s2)] else { continue }
                    let f1 = features[Int(runs[Int(segRun[Int(s1)])].feature)], f2 = features[Int(runs[Int(segRun[Int(s2)])].feature)]
                    guard f1.layerKey == f2.layerKey else { continue }
                    let (a, b) = segEnds(s1), (c, d) = segEnds(s2)
                    if a == c || a == d || b == c || b == d { continue }
                    let (ax, ay) = coords(a), (bx, by) = coords(b), (cx, cy) = coords(c), (dx2, dy2) = coords(d)
                    let r = (Double(bx - ax), Double(by - ay)), q = (Double(dx2 - cx), Double(dy2 - cy))
                    let denom = r.0 * q.1 - r.1 * q.0
                    guard abs(denom) > 1e-9 else { continue }
                    let w = (Double(cx - ax), Double(cy - ay))
                    let t = (w.0 * q.1 - w.1 * q.0) / denom
                    let u = (w.0 * r.1 - w.1 * r.0) / denom
                    guard t > 0.001 && t < 0.999 && u > 0.001 && u < 0.999 else { continue }
                    let ix = Double(ax) + t * r.0, iy = Double(ay) + t * r.1
                    // Nur in der Zelle des Schnittpunkts zählen (Segmente liegen in mehreren Zellen).
                    guard key(Int64(ix) / cellSize, Int64(iy) / cellSize) == cell else { continue }
                    let k = key(Int64(ix.rounded()), Int64(iy.rounded()))
                    splits[s1, default: []].append((t, k))
                    splits[s2, default: []].append((u, k))
                }
            }
        }
        guard !splits.isEmpty else { return }

        // Teilungspunkte in die Wege einfügen.
        var bySegmentRun: [Int32: [(pos: Int32, points: [(t: Double, k: Int64)])]] = [:]
        for (s, points) in splits { bySegmentRun[segRun[Int(s)], default: []].append((segPos[Int(s)], points)) }
        for (r, entries) in bySegmentRun {
            let lookup = Dictionary(entries.map { ($0.pos, $0.points) }, uniquingKeysWith: +)
            let old = runs[Int(r)].nodes
            var out: [Int64] = [old[0]]
            for i in 0..<(old.count - 1) {
                for p in (lookup[Int32(i)] ?? []).sorted(by: { $0.t < $1.t }) where out.last != p.k {
                    out.append(p.k)
                }
                if out.last != old[i + 1] { out.append(old[i + 1]) }
            }
            runs[Int(r)].nodes = out
        }
    }

    // MARK: - Namen

    /** Name je Weg: nächstes Segment aus `transportation_name` (≤ 8 Einheiten ≈ 3 m, Richtung ±25°). */
    private static func assignNames(_ runs: [Run], names: [(name: String, ref: String)], segments: [NameSegment]) -> [Int: Int32] {
        var grid: [Int64: [Int32]] = [:]
        for (i, s) in segments.enumerated() {
            let cx0 = Int64(min(s.ax, s.bx) - 8) / cellSize, cx1 = Int64(max(s.ax, s.bx) + 8) / cellSize
            let cy0 = Int64(min(s.ay, s.by) - 8) / cellSize, cy1 = Int64(max(s.ay, s.by) + 8) / cellSize
            for cx in cx0...cx1 { for cy in cy0...cy1 { grid[key(cx, cy), default: []].append(Int32(i)) } }
        }
        var result: [Int: Int32] = [:]
        for (r, run) in runs.enumerated() where run.nodes.count >= 2 {
            // Längstes Segment des Wegs als Stichprobe.
            var best = 0, bestLen = -1.0
            for i in 0..<(run.nodes.count - 1) {
                let (ax, ay) = coords(run.nodes[i]), (bx, by) = coords(run.nodes[i + 1])
                let len = hypot(Double(bx - ax), Double(by - ay))
                if len > bestLen { bestLen = len; best = i }
            }
            let (ax, ay) = coords(run.nodes[best]), (bx, by) = coords(run.nodes[best + 1])
            let mx = Double(ax + bx) / 2, my = Double(ay + by) / 2
            let angle = atan2(Double(by - ay), Double(bx - ax))
            var choice: (Int32, Double)?
            for i in grid[key(Int64(mx) / cellSize, Int64(my) / cellSize)] ?? [] {
                let s = segments[Int(i)]
                let dx = s.bx - s.ax, dy = s.by - s.ay
                let len2 = dx * dx + dy * dy
                guard len2 > 0 else { continue }
                let t = max(0, min(1, ((mx - s.ax) * dx + (my - s.ay) * dy) / len2))
                let d = hypot(s.ax + t * dx - mx, s.ay + t * dy - my)
                guard d <= 8 else { continue }
                var diff = abs(atan2(dy, dx) - angle).truncatingRemainder(dividingBy: .pi)
                if diff > .pi / 2 { diff = .pi - diff }
                guard diff <= 25 * .pi / 180 else { continue }
                if d < (choice?.1 ?? .greatestFiniteMagnitude) { choice = (s.name, d) }
            }
            if let choice { result[r] = choice.0 }
        }
        return result
    }

    // MARK: - Auto-Inseln

    /** Klassen, die [WayRecord.from] für Autos freigibt (ohne `access=no`). */
    private static let carHighways: Set<String> = [
        "motorway", "motorway_link", "trunk", "trunk_link", "primary", "primary_link", "secondary",
        "secondary_link", "tertiary", "tertiary_link", "road", "service"
    ]

    /**
     * Kleine, vom Hauptnetz getrennte Auto-Netzstücke (Park-/Werks-/Privatwege — die Kacheln kennen
     * nur `access=no`, nicht `private`). Landet Start/Ziel darauf, findet der Router keinen Weg
     * (Test Großer Garten Dresden). Stücke < 150 Knoten, die den Rand des geladenen Gebiets nicht
     * berühren (könnten außerhalb weitergehen), werden für Autos gesperrt; Fuß/Rad bleiben.
     */
    private static func isolatedCarRuns(_ runs: [Run], features: [Feature], tiles: [TileData]) -> Set<Int> {
        guard let minTX = tiles.map(\.x).min(), let maxTX = tiles.map(\.x).max(),
              let minTY = tiles.map(\.y).min(), let maxTY = tiles.map(\.y).max() else { return [] }
        let margin: Int64 = 64
        let minX = Int64(minTX) * tileExtent + margin, maxX = Int64(maxTX + 1) * tileExtent - margin
        let minY = Int64(minTY) * tileExtent + margin, maxY = Int64(maxTY + 1) * tileExtent - margin

        var parent: [Int64: Int64] = [:]
        func find(_ k: Int64) -> Int64 {
            var k = k
            while let p = parent[k], p != k { parent[k] = parent[p] ?? p; k = p }
            return k
        }
        func union(_ a: Int64, _ b: Int64) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }
        var carRuns: [Int] = []
        for (i, run) in runs.enumerated() where run.nodes.count >= 2 {
            let tags = features[Int(run.feature)].tags
            guard carHighways.contains(tags["highway"] ?? ""), tags["access"] != "no" else { continue }
            carRuns.append(i)
            for k in run.nodes where parent[k] == nil { parent[k] = k }
            for i in 1..<run.nodes.count { union(run.nodes[i - 1], run.nodes[i]) }
        }
        var size: [Int64: Int] = [:]
        var touchesBorder = Set<Int64>()
        for k in parent.keys {
            let root = find(k)
            size[root, default: 0] += 1
            let (x, y) = coords(k)
            if x < minX || x > maxX || y < minY || y > maxY { touchesBorder.insert(root) }
        }
        var result = Set<Int>()
        for i in carRuns {
            let root = find(runs[i].nodes[0])
            if (size[root] ?? 0) < 150 && !touchesBorder.contains(root) { result.insert(i) }
        }
        return result
    }

    // MARK: - Kreisverkehre

    /**
     * Die Kacheln markieren keine Kreisverkehre. Erkannt werden kurze, runde Ringe aus Einbahn-
     * Wegen (Straßen, keine Autobahn): von jedem Einbahn-Weg aus bis 250 m in Fahrtrichtung weiter —
     * führt das zum Startpunkt zurück und ist der Ring fast kreisförmig (Kompaktheit 4πA/U² > 0,7,
     * ≥ 6 Stützpunkte), gilt er als Kreisverkehr. Einbahn-Häuserblöcke sind größer und eckig.
     */
    private static func detectRoundabouts(_ runs: [Run], features: [Feature]) -> Set<Int> {
        func isCandidate(_ r: Int) -> Bool {
            let f = features[Int(runs[r].feature)]
            guard runs[r].nodes.count >= 2, f.tags["oneway"] == "yes" else { return false }
            return ["primary", "secondary", "tertiary", "minor", "service", "trunk"].contains(f.className)
        }
        var byStart: [Int64: [Int]] = [:]
        var lengths: [Int: Double] = [:]
        for r in runs.indices where isCandidate(r) {
            byStart[runs[r].nodes[0], default: []].append(r)
            var len = 0.0
            for i in 0..<(runs[r].nodes.count - 1) {
                let (ax, ay) = coords(runs[r].nodes[i]), (bx, by) = coords(runs[r].nodes[i + 1])
                len += hypot(Double(bx - ax), Double(by - ay))
            }
            lengths[r] = len * 0.375 // Rastereinheit ≈ 0,375 m in Mitteleuropa
        }
        func isRound(_ path: [Int]) -> Bool {
            var pts: [(Double, Double)] = []
            for r in path { for k in runs[r].nodes.dropLast() { let (x, y) = coords(k); pts.append((Double(x), Double(y))) } }
            guard pts.count >= 6 else { return false }
            var area = 0.0, perimeter = 0.0
            for i in pts.indices {
                let a = pts[i], b = pts[(i + 1) % pts.count]
                area += a.0 * b.1 - b.0 * a.1
                perimeter += hypot(b.0 - a.0, b.1 - a.1)
            }
            area = abs(area) / 2
            return perimeter > 0 && 4 * .pi * area / (perimeter * perimeter) > 0.7
        }
        var found = Set<Int>()
        for start in lengths.keys where !found.contains(start) {
            let origin = runs[start].nodes[0]
            // Tiefensuche mit Längenbudget.
            var stack: [(run: Int, path: [Int], length: Double)] = [(start, [start], lengths[start] ?? 0)]
            var steps = 0
            while let (run, path, length) = stack.popLast(), steps < 200 {
                steps += 1
                let end = runs[run].nodes.last!
                if end == origin {
                    if length >= 25 && isRound(path) { found.formUnion(path) }
                    break
                }
                for next in byStart[end] ?? [] where !path.contains(next) {
                    let total = length + (lengths[next] ?? 0)
                    if total <= 250 && path.count < 12 { stack.append((next, path + [next], total)) }
                }
            }
        }
        return found
    }
}
