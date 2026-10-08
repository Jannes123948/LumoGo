import Foundation

/**
 * Offline-Suchdaten aus den z14-Vektorkacheln (OpenMapTiles-Schema) — mit ADRESSEN, die die frühere
 * Overpass-Abfrage bewusst wegließ (Straßen + Hausnummern waren dem öffentlichen Server zu viel):
 *  - `housenumber`: Hausnummer-Punkte (ohne Straßennamen!) → Straße = nächstes `transportation_name`-
 *    Segment im Umkreis ≈ 60 m → „Wilsdruffer Straße 12“;
 *  - `transportation_name`: Straßennamen (ein Eintrag je ≈ 750 m, damit lange Straßen auffindbar sind,
 *    ohne die Liste zu fluten);
 *  - `place`: Städte, Dörfer, Stadtteile; `poi`: benannte Orte (Geschäfte, Haltestellen, …).
 * Ort in Klammern = nächster `place`-Punkt (Dorf/Stadtteil/Stadt). Öffnungszeiten haben die Kacheln
 * nicht — die holt das Ort-Infoblatt online.
 */
enum TilePlacesBuilder {
    private static let tileExtent = 4096.0
    private static let worldSize = Double(Int64(1) << 26)
    /** Hausnummer → Straße: maximal ≈ 60 m (Rastereinheiten ≈ 0,37 m in Deutschland). */
    private static let houseNumberRadius = 160.0
    /** Mindestabstand zweier Einträge derselben Straße (≈ 750 m). */
    private static let streetSpacing = 2000.0
    private static let cell = 256.0
    private static let blockTiles = 24

    private static let localityClasses: Set<String> = [
        "city", "town", "village", "hamlet", "suburb", "quarter", "neighbourhood", "isolated_dwelling"
    ]

    /** Lädt die Kacheln (zuerst aus MapLibres Datenbank) blockweise und extrahiert die Suchdaten. */
    static func download(_ bbox: BoundingBox, databasePath: String?, preferNetwork: Bool = false,
                         progress: @escaping (Double) -> Void) async throws -> [OverpassPlace] {
        let range = VectorTileSource.tileRange(bbox)
        func starts(_ r: ClosedRange<Int>) -> [Int] { Array(stride(from: r.lowerBound, through: r.upperBound, by: blockTiles)) }
        var blocks: [(xs: ClosedRange<Int>, ys: ClosedRange<Int>)] = []
        for x in starts(range.xs) {
            for y in starts(range.ys) {
                blocks.append((x...min(x + blockTiles - 1, range.xs.upperBound), y...min(y + blockTiles - 1, range.ys.upperBound)))
            }
        }
        let total = blocks.reduce(0) { $0 + $1.xs.count * $1.ys.count }
        var done = 0
        var result: [OverpassPlace] = []
        for block in blocks {
            try Task.checkCancellation()
            let offset = done
            let tiles = try await VectorTileSource.load(block, databasePath: databasePath, preferNetwork: preferNetwork) { loaded, _ in
                progress(0.95 * Double(offset + loaded) / Double(max(total, 1)))
            }
            done += block.xs.count * block.ys.count
            result += extract(tiles)
        }
        progress(1)
        guard !result.isEmpty else { throw AppError.noResults }
        return result
    }

    private struct Point { let x: Double; let y: Double }
    private struct NamedPoint { let name: String; let x: Double; let y: Double }
    private struct Segment { let name: Int; let ax: Double; let ay: Double; let bx: Double; let by: Double }

    /**
     * Brauchbarer Name für die Suche: mindestens 2 Buchstaben — oder eine Straßennummer wie „B 6“,
     * „A 4“, „S 177“. Nur-Nummern/Kürzel („4“, „Q-3“, „2 h“) sind ohne Zusammenhang nutzlos.
     */
    static func isSearchableName(_ name: String) -> Bool {
        if name.filter(\.isLetter).count >= 2 { return true }
        return name.range(of: #"^[ABKLS] ?\d+[a-z]?$"#, options: .regularExpression) != nil
    }

    /** Suchdaten aus Kacheln; Punkte nur aus der eigenen Kachel (der Kachelpuffer enthält Nachbarteile). */
    static func extract(_ tiles: [TileData]) -> [OverpassPlace] {
        var places: [(name: String, cls: String, p: Point)] = []
        var pois: [NamedPoint] = []
        var houseNumbers: [NamedPoint] = []
        var streetNames: [String] = []
        var streetIndex: [String: Int] = [:]
        var segments: [Segment] = []

        for tile in tiles {
            guard let vt = try? VectorTile(data: tile.data, onlyLayers: ["housenumber", "transportation_name", "place", "poi"]) else { continue }
            let x0 = Double(tile.x) * tileExtent, y0 = Double(tile.y) * tileExtent
            func ownPoint(_ f: VectorTile.Feature, _ layer: VectorTile.Layer) -> Point? {
                guard f.type == .point, let p = f.geometry.first?.first else { return nil }
                let s = tileExtent / Double(layer.extent)
                let x = Double(p.x) * s, y = Double(p.y) * s
                guard x >= 0, y >= 0, x < tileExtent, y < tileExtent else { return nil }
                return Point(x: x0 + x, y: y0 + y)
            }
            if let layer = vt.layers["place"] {
                for f in layer.features {
                    guard let name = f.properties["name"]?.string, !name.isEmpty, let p = ownPoint(f, layer) else { continue }
                    places.append((name, f.properties["class"]?.string ?? "", p))
                }
            }
            if let layer = vt.layers["poi"] {
                for f in layer.features {
                    guard let name = f.properties["name"]?.string, isSearchableName(name), let p = ownPoint(f, layer) else { continue }
                    pois.append(NamedPoint(name: name, x: p.x, y: p.y))
                }
            }
            if let layer = vt.layers["housenumber"] {
                for f in layer.features {
                    guard let number = f.properties["housenumber"]?.string, !number.isEmpty, let p = ownPoint(f, layer) else { continue }
                    houseNumbers.append(NamedPoint(name: number, x: p.x, y: p.y))
                }
            }
            if let layer = vt.layers["transportation_name"] {
                let s = tileExtent / Double(layer.extent)
                for f in layer.features where f.type == .line {
                    // Wege, die nur „4“ oder „C“ heißen (Kleingärten, Gewerbehöfe), kämen sonst als
                    // „4“ bzw. „4 12“ in die Suchergebnisse (Nutzermeldung: nur „Q-3“ und „24“).
                    guard let name = f.properties["name"]?.string, isSearchableName(name) else { continue }
                    let index: Int
                    if let existing = streetIndex[name] {
                        index = existing
                    } else {
                        index = streetNames.count
                        streetIndex[name] = index
                        streetNames.append(name)
                    }
                    for part in f.geometry where part.count >= 2 {
                        for i in 0..<(part.count - 1) {
                            segments.append(Segment(name: index,
                                                    ax: x0 + Double(part[i].x) * s, ay: y0 + Double(part[i].y) * s,
                                                    bx: x0 + Double(part[i + 1].x) * s, by: y0 + Double(part[i + 1].y) * s))
                        }
                    }
                }
            }
        }

        // Segment-Raster für „nächste Straße“.
        var grid: [Int64: [Int32]] = [:]
        func key(_ cx: Int, _ cy: Int) -> Int64 { Int64(cx) << 32 | Int64(UInt32(bitPattern: Int32(cy))) }
        for (i, s) in segments.enumerated() {
            let cx0 = Int((min(s.ax, s.bx) - houseNumberRadius) / cell), cx1 = Int((max(s.ax, s.bx) + houseNumberRadius) / cell)
            let cy0 = Int((min(s.ay, s.by) - houseNumberRadius) / cell), cy1 = Int((max(s.ay, s.by) + houseNumberRadius) / cell)
            guard (cx1 - cx0 + 1) * (cy1 - cy0 + 1) < 400 else { continue } // Ausreißer (Kachelpuffer-Artefakt)
            for cx in cx0...cx1 { for cy in cy0...cy1 { grid[key(cx, cy), default: []].append(Int32(i)) } }
        }
        func nearestStreet(_ p: Point) -> Int? {
            var best: (Int, Double)?
            for i in grid[key(Int(p.x / cell), Int(p.y / cell))] ?? [] {
                let s = segments[Int(i)]
                let dx = s.bx - s.ax, dy = s.by - s.ay
                let len2 = dx * dx + dy * dy
                let t = len2 > 0 ? max(0, min(1, ((p.x - s.ax) * dx + (p.y - s.ay) * dy) / len2)) : 0
                let d = hypot(s.ax + t * dx - p.x, s.ay + t * dy - p.y)
                if d <= houseNumberRadius, d < (best?.1 ?? .greatestFiniteMagnitude) { best = (s.name, d) }
            }
            return best?.0
        }

        let localities = places.filter { localityClasses.contains($0.cls) }
        func locality(_ p: Point, excluding name: String? = nil) -> String? {
            var best: (String, Double)?
            for place in localities where place.name != name {
                let d = hypot(place.p.x - p.x, place.p.y - p.y)
                if d < (best?.1 ?? .greatestFiniteMagnitude) { best = (place.name, d) }
            }
            // Weiter als ≈ 8 km weg: kein sinnvoller Ortsname.
            return best.flatMap { $0.1 < 21_000 ? $0.0 : nil }
        }
        func latLon(_ p: Point) -> (Double, Double) {
            let lon = p.x / worldSize * 360 - 180
            let lat = atan(sinh(.pi * (1 - 2 * p.y / worldSize))) * 180 / .pi
            return (lat, lon)
        }
        func place(_ name: String, _ p: Point, locality: String?) -> OverpassPlace {
            let (lat, lon) = latLon(p)
            return OverpassPlace(name: name, lat: lat, lon: lon, locality: locality, openingHours: nil)
        }

        var result: [OverpassPlace] = []
        for p in places {
            result.append(place(p.name, p.p, locality: localityClasses.contains(p.cls) && p.cls != "city" ? locality(p.p, excluding: p.name) : nil))
        }
        for p in pois {
            let point = Point(x: p.x, y: p.y)
            result.append(place(p.name, point, locality: locality(point)))
        }
        for h in houseNumbers {
            let point = Point(x: h.x, y: h.y)
            guard let street = nearestStreet(point) else { continue }
            result.append(place("\(streetNames[street]) \(h.name)", point, locality: locality(point)))
        }
        // Straßen: ein Eintrag je ≈ 750 m Straßenlänge (Mitte eines Segments).
        var streetPoints: [Int: [Point]] = [:]
        for s in segments {
            let mid = Point(x: (s.ax + s.bx) / 2, y: (s.ay + s.by) / 2)
            guard mid.x >= 0 else { continue }
            let existing = streetPoints[s.name] ?? []
            if existing.allSatisfy({ hypot($0.x - mid.x, $0.y - mid.y) > streetSpacing }) {
                streetPoints[s.name, default: []].append(mid)
                result.append(place(streetNames[s.name], mid, locality: locality(mid)))
            }
        }
        return result
    }
}
