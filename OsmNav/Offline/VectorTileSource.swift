import Foundation
import SQLite3

/** Eine Vektorkachel (z14) samt Position. */
struct TileData {
    let x: Int
    let y: Int
    let data: Data
}

/**
 * Besorgt die OpenFreeMap-Vektorkacheln (z14, OpenMapTiles-Schema) eines Gebiets — Grundlage für
 * Offline-Straßennetz und Offline-Suche (statt Overpass, der für ganze Gebiete zu langsam und
 * unzuverlässig war: 28 × 33 km per Overpass minutenlang/abgebrochen, als Kacheln 9,8 s).
 *
 * 1. zuerst aus MapLibres Offline-Datenbank (`cache.db`, Tabelle `tiles`) — Pakete mit max. Zoom
 *    ≥ 14 enthalten die Kacheln schon, dann ist gar kein Download nötig;
 * 2. fehlende Kacheln vom OpenFreeMap-CDN (Massen-Downloads ausdrücklich erlaubt), parallel.
 */
enum VectorTileSource {
    static let zoom = 14
    private static let tileJSON = URL(string: "https://tiles.openfreemap.org/planet")!
    private static let session = HTTP.session(requestTimeout: 30)
    private static let parallelDownloads = 8

    /** Kachel-Bereich (x, y) bei z14 für eine Bounding Box. */
    static func tileRange(_ bbox: BoundingBox) -> (xs: ClosedRange<Int>, ys: ClosedRange<Int>) {
        let n = Double(1 << zoom)
        func x(_ lon: Double) -> Int { min(max(Int(floor((lon + 180) / 360 * n)), 0), Int(n) - 1) }
        func y(_ lat: Double) -> Int {
            let r = lat * .pi / 180
            return min(max(Int(floor((1 - log(tan(r) + 1 / cos(r)) / .pi) / 2 * n)), 0), Int(n) - 1)
        }
        return (x(bbox.west)...x(bbox.east), y(bbox.north)...y(bbox.south))
    }

    /**
     * Alle z14-Kacheln des Gebiets. [databasePath] = MapLibres Offline-Datenbank (nil = nur
     * Download). [preferNetwork] = trotzdem alle frisch vom CDN holen (die Datenbank hält den
     * Stand vom Paket-Download; neu eingetragene Adressen fehlen dort) — die Datenbank dient dann
     * nur als Ersatz, wenn eine Kachel nicht aus dem Netz kommt. [progress]: (fertig, gesamt).
     */
    static func load(_ bbox: BoundingBox, databasePath: String?, preferNetwork: Bool = false,
                     progress: @escaping (Int, Int) -> Void) async throws -> [TileData] {
        try await load(tileRange(bbox), databasePath: databasePath, preferNetwork: preferNetwork, progress: progress)
    }

    /** Wie oben, für einen Kachelbereich (z14). */
    static func load(_ range: (xs: ClosedRange<Int>, ys: ClosedRange<Int>), databasePath: String?, preferNetwork: Bool = false,
                     progress: @escaping (Int, Int) -> Void) async throws -> [TileData] {
        var wanted = Set<Int64>()
        for x in range.xs { for y in range.ys { wanted.insert(key(x, y)) } }
        let total = wanted.count

        var cached: [Int64: TileData] = [:]
        if let databasePath {
            for t in readFromDatabase(databasePath, range: range) { cached[key(t.x, t.y)] = t }
        }
        var tiles: [TileData] = []
        if !preferNetwork {
            tiles = Array(cached.values)
            for k in cached.keys { wanted.remove(k) }
        }
        progress(tiles.count, total)
        guard !wanted.isEmpty else { return tiles }

        let template: String
        do {
            template = try await tileTemplate()
        } catch {
            // Kein Netz: mit dem vorhandenen Stand weitermachen, statt ganz zu scheitern.
            if error is CancellationError || cached.isEmpty || !preferNetwork { throw error }
            progress(total, total)
            return Array(cached.values)
        }
        var missing = Array(wanted)
        var done = tiles.count
        // Mit [preferNetwork] darf eine einzelne Kachel scheitern, wenn es sie in der Datenbank gibt.
        let fetch: @Sendable (Int64) async throws -> TileData? = { [cached] k in
            do {
                return try await download(template, k)
            } catch {
                if error is CancellationError { throw error }
                if preferNetwork, let old = cached[k] { return old }
                throw error
            }
        }
        try await withThrowingTaskGroup(of: TileData?.self) { group in
            var inFlight = 0
            func next() -> Int64? { missing.isEmpty ? nil : missing.removeLast() }
            while inFlight < parallelDownloads, let k = next() {
                inFlight += 1
                group.addTask { try await fetch(k) }
            }
            while let result = try await group.next() {
                inFlight -= 1
                if let result { tiles.append(result) }
                done += 1
                progress(done, total)
                if let k = next() {
                    inFlight += 1
                    group.addTask { try await fetch(k) }
                }
            }
        }
        return tiles
    }

    private static func key(_ x: Int, _ y: Int) -> Int64 { Int64(x) << 32 | Int64(y) }

    /** Aktuelle Kachel-URL aus dem TileJSON (OpenFreeMap versioniert die Pfade). */
    private static func tileTemplate() async throws -> String {
        let data = try await HTTP.data(session, for: URLRequest(url: tileJSON))
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let template = (json["tiles"] as? [String])?.first else { throw AppError.parse }
        return template
    }

    /** Eine Kachel laden; nil bei 404/leer (Meer o. ä.). Wiederholt bei Netzfehlern. */
    private static func download(_ template: String, _ k: Int64) async throws -> TileData? {
        let x = Int(k >> 32), y = Int(k & 0xFFFF_FFFF)
        let urlString = template.replacingOccurrences(of: "{z}", with: "\(zoom)")
            .replacingOccurrences(of: "{x}", with: "\(x)").replacingOccurrences(of: "{y}", with: "\(y)")
        guard let url = URL(string: urlString) else { return nil }
        var lastError: Error = AppError.parse
        for attempt in 0..<3 {
            do {
                let raw = try await HTTP.data(session, for: URLRequest(url: url))
                guard !raw.isEmpty, let data = TileDecompression.inflateIfNeeded(raw) else { return nil }
                return TileData(x: x, y: y, data: data)
            } catch AppError.http(let code) where code == 404 || code == 204 {
                return nil
            } catch {
                lastError = error
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: UInt64(attempt + 1) * 1_000_000_000)
            }
        }
        throw lastError
    }

    /** Kacheln aus MapLibres `cache.db` (nur lesend; MapLibre selbst nutzt sie parallel weiter). */
    private static func readFromDatabase(_ path: String, range: (xs: ClosedRange<Int>, ys: ClosedRange<Int>)) -> [TileData] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }
        // MapLibre schreibt evtl. gerade (journal_mode DELETE, kein exklusiver Lock) — kurz warten statt aufgeben.
        sqlite3_busy_timeout(db, 3000)
        let sql = """
        SELECT x, y, data, compressed FROM tiles
        WHERE z = ? AND x BETWEEN ? AND ? AND y BETWEEN ? AND ? AND url_template LIKE '%openfreemap%' AND data IS NOT NULL
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(zoom))
        sqlite3_bind_int(statement, 2, Int32(range.xs.lowerBound))
        sqlite3_bind_int(statement, 3, Int32(range.xs.upperBound))
        sqlite3_bind_int(statement, 4, Int32(range.ys.lowerBound))
        sqlite3_bind_int(statement, 5, Int32(range.ys.upperBound))

        var result: [Int64: TileData] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let x = Int(sqlite3_column_int(statement, 0)), y = Int(sqlite3_column_int(statement, 1))
            guard let blob = sqlite3_column_blob(statement, 2) else { continue }
            let raw = Data(bytes: blob, count: Int(sqlite3_column_bytes(statement, 2)))
            // `compressed = 1`: MapLibre hat zlib-komprimiert; inflateIfNeeded erkennt das am Kopf.
            guard let data = TileDecompression.inflateIfNeeded(raw), !data.isEmpty else { continue }
            result[key(x, y)] = TileData(x: x, y: y, data: data)
        }
        return Array(result.values)
    }
}
