import Foundation

/**
 * Straßennetz-Daten fürs Offline-Routing (Ersatz für BRouter, das es nur für Android gibt).
 * Beim Download eines Kartenpakets wird das Straßennetz des Gebiets per Overpass geholt, auf das
 * Nötigste reduziert (Knoten, Kanten, je Weg: Klasse, Name, Tempo, Zugangsrechte je Profil) und
 * kompakt binär gespeichert — siehe [RoadDataStore], [RoadGraph], [OfflineRouter].
 */
enum HighwayClass: UInt8 {
    case motorway, motorwayLink, trunk, trunkLink, primary, primaryLink, secondary, secondaryLink
    case tertiary, tertiaryLink, unclassified, residential, livingStreet, service, road
    case pedestrian, track, path, footway, cycleway, bridleway, steps

    init?(tag: String) {
        switch tag {
        case "motorway": self = .motorway
        case "motorway_link": self = .motorwayLink
        case "trunk": self = .trunk
        case "trunk_link": self = .trunkLink
        case "primary": self = .primary
        case "primary_link": self = .primaryLink
        case "secondary": self = .secondary
        case "secondary_link": self = .secondaryLink
        case "tertiary": self = .tertiary
        case "tertiary_link": self = .tertiaryLink
        case "unclassified": self = .unclassified
        case "residential": self = .residential
        case "living_street": self = .livingStreet
        case "service": self = .service
        case "road": self = .road
        case "pedestrian": self = .pedestrian
        case "track": self = .track
        case "path": self = .path
        case "footway": self = .footway
        case "cycleway": self = .cycleway
        case "bridleway": self = .bridleway
        case "steps": self = .steps
        default: return nil
        }
    }

    var isLink: Bool { [.motorwayLink, .trunkLink, .primaryLink, .secondaryLink, .tertiaryLink].contains(self) }
    var isMotorwayLike: Bool { self == .motorway || self == .trunk }

    /** Realistische Durchschnittsgeschwindigkeit (km/h), wenn kein `maxspeed` getaggt ist. */
    var defaultCarSpeed: Double {
        switch self {
        case .motorway: return 115
        case .motorwayLink: return 55
        case .trunk: return 90
        case .trunkLink: return 50
        case .primary: return 70
        case .primaryLink: return 45
        case .secondary: return 60
        case .secondaryLink: return 40
        case .tertiary: return 50
        case .tertiaryLink: return 35
        case .unclassified: return 40
        case .residential: return 25
        case .livingStreet: return 8
        case .service: return 15
        case .road: return 30
        case .track: return 15
        default: return 10
        }
    }

    var bikeSpeed: Double {
        switch self {
        case .track, .path, .bridleway: return 12
        case .footway, .pedestrian, .livingStreet: return 10
        case .steps: return 3
        default: return 17
        }
    }

    var footSpeed: Double { self == .steps ? 2 : 5 }

    private static let carClasses: Set<HighwayClass> = [
        .motorway, .motorwayLink, .trunk, .trunkLink, .primary, .primaryLink, .secondary, .secondaryLink,
        .tertiary, .tertiaryLink, .unclassified, .residential, .livingStreet, .service, .road
    ]
    var carDefault: Bool { Self.carClasses.contains(self) }
}

/** Zugangsrechte je Profil/Richtung (bezogen auf die Knotenreihenfolge des OSM-Wegs). */
struct RoadAccess: OptionSet {
    let rawValue: UInt8
    static let carForward = RoadAccess(rawValue: 1)
    static let carBackward = RoadAccess(rawValue: 2)
    static let bikeForward = RoadAccess(rawValue: 4)
    static let bikeBackward = RoadAccess(rawValue: 8)
    static let foot = RoadAccess(rawValue: 16)
    /** "Anlieger frei" (`destination`) — nur am Start/Ziel sinnvoll, kein Durchgangsverkehr. */
    static let carDestinationOnly = RoadAccess(rawValue: 32)
}

/** Abbiegeverbot/-gebot aus einer OSM-`restriction`-Relation (nur mit Knoten als `via`). */
struct TurnRestriction: Hashable {
    let fromWay: Int64
    let viaNode: Int64
    let toWay: Int64
    /** true = `only_*` (nur dorthin erlaubt), false = `no_*` (dorthin verboten). */
    let only: Bool
}

/** Ein für das Routing relevanter OSM-Weg (ohne Geometrie). */
struct WayRecord {
    let osmId: Int64
    let access: RoadAccess
    let highway: HighwayClass
    let roundabout: Bool
    let carSpeedKmh: Float
    let name: String
    let ref: String

    /** Wertet die OSM-Tags aus; nil, wenn der Weg für kein Profil befahrbar ist. */
    static func from(osmId: Int64, tags: [String: String]) -> WayRecord? {
        guard let highway = tags["highway"].flatMap(HighwayClass.init(tag:)) else { return nil }
        let no: Set<String> = ["no", "private", "agricultural", "forestry", "delivery", "use_sidepath"]
        let yes: Set<String> = ["yes", "designated", "permissive", "destination"]
        let generalAccess = tags["access"]
        let motorroad = tags["motorroad"] == "yes"
        let roundabout = tags["junction"] == "roundabout" || tags["junction"] == "circular"

        // Einbahnstraßen: explizites oneway, Kreisverkehre und Autobahnen sind implizit einseitig.
        let oneway = tags["oneway"] ?? ""
        var forwardOnly = ["yes", "1", "true"].contains(oneway) || roundabout || highway == .motorway
        var backwardOnly = oneway == "-1"
        if oneway == "no" { forwardOnly = false; backwardOnly = false }

        var access: RoadAccess = []

        // Auto
        let carTag = tags["motorcar"] ?? tags["motor_vehicle"] ?? tags["vehicle"] ?? generalAccess
        let carAllowed = carTag.map { !no.contains($0) } ?? highway.carDefault
        if carAllowed && (highway.carDefault || carTag.map(yes.contains) == true) {
            if !backwardOnly { access.insert(.carForward) }
            if !forwardOnly { access.insert(.carBackward) }
            if carTag == "destination" { access.insert(.carDestinationOnly) }
        }

        // Fahrrad
        let bikeTag = tags["bicycle"] ?? tags["vehicle"] ?? generalAccess
        var bikeAllowed: Bool
        switch highway {
        case .motorway, .motorwayLink: bikeAllowed = false
        case .footway, .pedestrian, .steps: bikeAllowed = bikeTag.map(yes.contains) ?? false
        default: bikeAllowed = bikeTag.map { !no.contains($0) } ?? true
        }
        if motorroad && bikeTag.map(yes.contains) != true { bikeAllowed = false }
        if bikeAllowed {
            let bikeIgnoresOneway = tags["oneway:bicycle"] == "no" || (tags["cycleway"] ?? "").hasPrefix("opposite")
            let bikeForwardOnly = forwardOnly && !bikeIgnoresOneway && highway != .motorway
            let bikeBackwardOnly = backwardOnly && !bikeIgnoresOneway
            if !bikeBackwardOnly { access.insert(.bikeForward) }
            if !bikeForwardOnly { access.insert(.bikeBackward) }
        }

        // Fußgänger (Einbahnstraßen gelten nicht)
        let footTag = tags["foot"] ?? generalAccess
        var footAllowed: Bool
        switch highway {
        case .motorway, .motorwayLink, .trunk, .trunkLink: footAllowed = footTag.map(yes.contains) ?? false
        default: footAllowed = footTag.map { !no.contains($0) } ?? true
        }
        if motorroad && footTag.map(yes.contains) != true { footAllowed = false }
        if footAllowed { access.insert(.foot) }

        guard !access.isEmpty else { return nil }

        var speed = highway.defaultCarSpeed
        if let maxspeed = tags["maxspeed"].flatMap(parseMaxspeed) {
            // Erlaubtes Tempo wird im Schnitt nicht ganz erreicht (Kreuzungen, Verkehr) — und eine
            // Wohnstraße mit "50" fährt sich trotzdem nicht wie eine Bundesstraße.
            speed = min(maxspeed * 0.85, speed * 1.3)
        }
        return WayRecord(
            osmId: osmId,
            access: access,
            highway: highway,
            roundabout: roundabout,
            carSpeedKmh: Float(max(speed, 5)),
            name: tags["name"] ?? "",
            ref: tags["ref"] ?? ""
        )
    }

    private static func parseMaxspeed(_ value: String) -> Double? {
        switch value {
        case "DE:urban", "AT:urban", "CH:urban": return 50
        case "DE:rural", "AT:rural", "CH:rural": return 100
        case "DE:motorway", "none", "DE:autobahn": return 130
        case "walk", "DE:walk", "DE:living_street": return 7
        default:
            let digits = value.prefix { $0.isNumber }
            guard let number = Double(digits), number > 0 else { return nil }
            return value.contains("mph") ? number * 1.609 : number
        }
    }
}

// MARK: - Binärformat

struct BinaryWriter {
    private(set) var data = Data()

    mutating func write<T: FixedWidthInteger>(_ value: T) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func write(_ value: Double) { write(value.bitPattern) }
    mutating func write(_ value: Float) { write(value.bitPattern) }

    mutating func write(_ value: String) {
        let bytes = Array(value.utf8.prefix(Int(UInt16.max)))
        write(UInt16(bytes.count))
        data.append(contentsOf: bytes)
    }
}

/** Liest das [BinaryWriter]-Format; nur innerhalb von `Data.withUnsafeBytes` verwenden. */
struct BinaryReader {
    let buffer: UnsafeRawBufferPointer
    var offset = 0

    init(_ buffer: UnsafeRawBufferPointer) { self.buffer = buffer }

    mutating func read<T: FixedWidthInteger>(_: T.Type) throws -> T {
        let size = MemoryLayout<T>.size
        guard offset + size <= buffer.count else { throw AppError.parse }
        var value: T = 0
        withUnsafeMutableBytes(of: &value) { $0.copyMemory(from: UnsafeRawBufferPointer(rebasing: buffer[offset..<offset + size])) }
        offset += size
        return T(littleEndian: value)
    }

    mutating func readDouble() throws -> Double { Double(bitPattern: try read(UInt64.self)) }
    mutating func readFloat() throws -> Float { Float(bitPattern: try read(UInt32.self)) }

    mutating func readString() throws -> String {
        let length = Int(try read(UInt16.self))
        guard offset + length <= buffer.count else { throw AppError.parse }
        let string = String(decoding: UnsafeRawBufferPointer(rebasing: buffer[offset..<offset + length]), as: UTF8.self)
        offset += length
        return string
    }
}

// MARK: - Quelle

/** Woher Offline-Straßennetz UND Offline-Suchdaten kommen (Einstellungen → Navigation → Offline-Routing). */
enum OfflineRoadSource: String, CaseIterable, Identifiable {
    /** OpenFreeMap-Vektorkacheln: schnell und zuverlässig, aber ohne Abbiegeverbote/Tempolimits. */
    case tiles
    /** Overpass: echte OSM-Daten inkl. Abbiegeverboten und maxspeed, langsam/oft überlastet. */
    case overpass

    static let settingsKey = "offline_road_source"
    var id: String { rawValue }

    var label: String {
        switch self {
        case .tiles: return "Kartenkacheln (schnell)"
        case .overpass: return "Overpass (genauer)"
        }
    }

    /** Aktuelle Einstellung — direkt aus UserDefaults (auch außerhalb des Main-Threads lesbar). */
    static var current: OfflineRoadSource {
        UserDefaults.standard.string(forKey: settingsKey).flatMap(OfflineRoadSource.init(rawValue:)) ?? .tiles
    }
}

// MARK: - Speicher

struct RoadDataInfo: Codable {
    let id: String
    let boundingBox: BoundingBox
    let nodeCount: Int
    let createdAt: Date
    /** Paket, zu dem dieser Block gehört (Kachel-Straßennetz, mehrere Blöcke je Paket);
     *  nil = ein File für das ganze Paket mit `id` = Paket-ID (Overpass, ältere Daten). */
    var packId: String? = nil

    var owner: String { packId ?? id }
}

/** Straßennetz-Files (eins oder mehrere Blöcke pro Offline-Kartenpaket) plus ein kleiner Index (Bounding Boxes). */
enum RoadDataStore {
    static let magic: UInt32 = 0x4F535247 // "OSRG"
    static let version: UInt8 = 2

    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("offline_routing", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static var indexFile: URL { directory.appendingPathComponent("index.json") }
    private static let lock = NSLock()

    static func file(_ id: String) -> URL { directory.appendingPathComponent("\(id).bin") }

    static func list() -> [RoadDataInfo] {
        lock.lock(); defer { lock.unlock() }
        return readIndex()
    }

    /** Hat das Paket [packId] ein Straßennetz (egal ob ein File oder Blöcke)? */
    static func has(_ packId: String) -> Bool { list().contains { $0.owner == packId } }

    /** Ersetzt das komplette Straßennetz eines Pakets durch [parts] (Paket-ID = [packId]). */
    static func replace(packId: String, parts: [(info: RoadDataInfo, data: Data)]) throws {
        for part in parts { try part.data.write(to: file(part.info.id), options: .atomic) }
        let newIds = Set(parts.map(\.info.id))
        lock.lock(); defer { lock.unlock() }
        let index = readIndex()
        for old in index where old.owner == packId && !newIds.contains(old.id) {
            try? FileManager.default.removeItem(at: file(old.id))
        }
        writeIndex(index.filter { $0.owner != packId } + parts.map(\.info))
    }

    static func save(_ info: RoadDataInfo, data: Data) throws {
        try replace(packId: info.owner, parts: [(info, data)])
    }

    /** Löscht alle Straßennetz-Files des Pakets [packId]. */
    static func delete(_ packId: String) {
        lock.lock(); defer { lock.unlock() }
        let index = readIndex()
        for info in index where info.owner == packId { try? FileManager.default.removeItem(at: file(info.id)) }
        writeIndex(index.filter { $0.owner != packId })
    }

    private static func readIndex() -> [RoadDataInfo] {
        guard let data = try? Data(contentsOf: indexFile) else { return [] }
        return (try? JSONDecoder().decode([RoadDataInfo].self, from: data)) ?? []
    }

    private static func writeIndex(_ infos: [RoadDataInfo]) {
        try? JSONEncoder().encode(infos).write(to: indexFile, options: .atomic)
    }
}

// MARK: - Download

/**
 * Lädt das Straßennetz eines Gebiets per Overpass — kachelweise, weil eine große Abfrage beim
 * öffentlichen Server (ohne SLA) zuverlässig mit HTTP 504 abbricht. Kacheln starten bei 0,1°
 * (≈ 11×7 km); scheitert eine (Großstadt mit vielen Fußwegen), wird sie automatisch geviertelt.
 * Wege, die über Kachelgrenzen reichen, kommen vollständig zurück und werden per OSM-ID dedupliziert.
 */
enum RoadDataBuilder {
    private static let chunkDegrees = 0.1
    private static let minChunkDegrees = 0.02
    /** Mit Autos befahrbare Straßen — reicht fürs Auto-Routing (Rad/Fuß nutzen sie ebenfalls). */
    private static let roadClasses = "motorway|motorway_link|trunk|trunk_link|primary|primary_link|secondary|secondary_link|tertiary|tertiary_link|unclassified|residential|living_street|service|road"
    /** Reine Rad-/Fuß-/Feldwege: machen eine Kachel ~2,7× so groß (Dresden 0,1°: 14,7 statt 5,5 MB,
     *  11 statt 3,3 s) — nur auf Wunsch (Einstellung „Rad- und Fußwege mitladen“). */
    private static let pathClasses = "pedestrian|track|path|footway|cycleway|bridleway|steps"
    /** Gleichzeitige Overpass-Anfragen: der Server erlaubt 4 je Client (`/api/status`), 2 lassen
     *  Platz für Suchdaten-Download und Live-Funktionen (POI-Suche, Tempolimits). */
    private static let maxParallel = 2

    private enum ChunkResult {
        case data(Data)
        case split(BoundingBox)
    }

    static func chunks(_ bbox: BoundingBox, size: Double = chunkDegrees) -> [BoundingBox] {
        var result: [BoundingBox] = []
        var south = bbox.south
        while south < bbox.north {
            let north = min(south + size, bbox.north)
            var west = bbox.west
            while west < bbox.east {
                let east = min(west + size, bbox.east)
                result.append(BoundingBox(south: south, north: north, west: west, east: east))
                west = east
            }
            south = north
        }
        return result
    }

    /** Lädt + baut die Binärdaten. [progress] bekommt (fertige Kacheln, Kacheln gesamt) — die
     *  Gesamtzahl kann wachsen, wenn Kacheln geteilt werden müssen. */
    static func download(_ bbox: BoundingBox, includePaths: Bool = false, progress: @escaping (Int, Int) -> Void) async throws -> (Data, Int) {
        var pending = chunks(bbox)
        var done = 0
        var ways: [Int64: (WayRecord, [Int64])] = [:]
        var coordinates: [Int64: (Double, Double)] = [:]
        var restrictions = Set<TurnRestriction>()

        // Bis zu [maxParallel] Kacheln gleichzeitig laden; geparst wird nacheinander hier.
        try await withThrowingTaskGroup(of: ChunkResult.self) { group in
            var inFlight = 0
            while inFlight < maxParallel, !pending.isEmpty {
                let part = pending.removeFirst()
                inFlight += 1
                group.addTask { try await fetchChunk(part, includePaths: includePaths) }
            }
            progress(done, done + pending.count + inFlight)
            while let result = try await group.next() {
                inFlight -= 1
                switch result {
                case .data(let data):
                    try parse(data, into: &ways, coordinates: &coordinates, restrictions: &restrictions)
                    done += 1
                case .split(let part):
                    pending.insert(contentsOf: chunks(part, size: max((part.north - part.south) / 2, minChunkDegrees)), at: 0)
                }
                while inFlight < maxParallel, !pending.isEmpty {
                    let part = pending.removeFirst()
                    inFlight += 1
                    group.addTask { try await fetchChunk(part, includePaths: includePaths) }
                }
                progress(done, done + pending.count + inFlight)
            }
        }
        progress(done, done)

        // Nur Knoten behalten, die von befahrbaren Wegen genutzt werden.
        var used: [Int64: (Double, Double)] = [:]
        for (_, nodeIds) in ways.values {
            for id in nodeIds { if let c = coordinates[id] { used[id] = c } }
        }
        guard !ways.isEmpty, !used.isEmpty else { throw AppError.noResults }
        let relevant = restrictions.filter { used[$0.viaNode] != nil && ways[$0.fromWay] != nil && ways[$0.toWay] != nil }
        return (encode(ways: ways, coordinates: used, restrictions: Array(relevant)), used.count)
    }

    /**
     * Lädt eine Kachel. 504/429/Netzfehler = Server ausgelastet → DIESELBE Kachel nach einer Pause
     * erneut (Teilen hilft da nicht, es macht nur mehr Anfragen — so im Test erlebt). Geteilt wird
     * nur, wenn Overpass die Abfrage selbst abbricht (`remark: runtime error …` = zu groß; die
     * Antwort ist dann unvollständig und darf nicht übernommen werden).
     */
    private static func fetchChunk(_ part: BoundingBox, includePaths: Bool) async throws -> ChunkResult {
        let isSmall = part.north - part.south <= minChunkDegrees * 1.01 && part.east - part.west <= minChunkDegrees * 1.01
        let q = query(part, includePaths: includePaths)
        var lastError: Error = AppError.parse
        for attempt in 0...backoffSeconds.count {
            do {
                let data = try await OverpassClient.rawQuery(q, retryCount: 1)
                if hasRuntimeError(data) {
                    if !isSmall { return .split(part) }
                    throw AppError.server("Overpass: Abfrage abgebrochen")
                }
                return .data(data)
            } catch {
                lastError = error
                try Task.checkCancellation()
                if attempt < backoffSeconds.count {
                    // Meldet der Server eine konkrete Wartezeit (429), mindestens so lange warten.
                    let suggested = min(await OverpassClient.suggestedWaitSeconds() ?? 0, 60)
                    try await Task.sleep(nanoseconds: max(suggested, backoffSeconds[attempt]) * 1_000_000_000)
                }
            }
        }
        throw lastError
    }

    /** Pausen zwischen Versuchen derselben Kachel (zusammen ~100 s, früher bis zu 200 s). */
    private static let backoffSeconds: [UInt64] = [4, 8, 15, 30, 45]

    /** Overpass hängt bei Zeit-/Speicherüberschreitung `"remark": "runtime error: …"` an. */
    private static func hasRuntimeError(_ data: Data) -> Bool {
        guard let range = data.range(of: Data("\"remark\"".utf8), options: .backwards) else { return false }
        let tail = data[range.lowerBound...].prefix(300)
        return String(decoding: tail, as: UTF8.self).contains("runtime error")
    }

    private static func query(_ part: BoundingBox, includePaths: Bool) -> String {
        let b = "\(part.south),\(part.west),\(part.north),\(part.east)"
        let highwayRegex = "^(\(roadClasses)\(includePaths ? "|" + pathClasses : ""))$"
        // Wege mit Knoten-IDs + Knotenkoordinaten einmal separat (`>; out skel`) — kompakter als
        // `out geom`, das die Koordinaten pro Weg wiederholt. Kleine Limits (`timeout:25`, 128 MB)
        // statt timeout:90: Overpass lässt „kleine“ Anfragen unter Last eher durch (Test: 3/6 statt
        // 1/6 erfolgreich); reicht es nicht, meldet der Server „runtime error“ → Kachel wird geteilt.
        return """
        [out:json][timeout:25][maxsize:134217728];
        way["highway"~"\(highwayRegex)"]["area"!="yes"]["service"!~"^(parking_aisle|driveway|drive-through)$"](\(b));
        out body qt;
        >;
        out skel qt;
        rel["type"="restriction"](\(b));
        out body qt;
        """
    }

    private static func parse(_ data: Data, into ways: inout [Int64: (WayRecord, [Int64])], coordinates: inout [Int64: (Double, Double)], restrictions: inout Set<TurnRestriction>) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let elements = root["elements"] as? [[String: Any]] else { throw AppError.parse }
        for element in elements {
            guard let id = (element["id"] as? NSNumber)?.int64Value else { continue }
            if element["type"] as? String == "node" {
                if let lat = element["lat"] as? Double, let lon = element["lon"] as? Double { coordinates[id] = (lat, lon) }
                continue
            }
            if element["type"] as? String == "relation" {
                if let restriction = parseRestriction(element) { restrictions.insert(restriction) }
                continue
            }
            guard ways[id] == nil,
                  let tags = element["tags"] as? [String: String],
                  let nodes = element["nodes"] as? [NSNumber], nodes.count >= 2,
                  let record = WayRecord.from(osmId: id, tags: tags) else { continue }
            ways[id] = (record, nodes.map(\.int64Value))
        }
    }

    /** Nur Verbote für Autos (`restriction` oder `restriction:motorcar`), Ausnahmen wie
     *  `except=motorcar` werden respektiert. Relationen mit Weg als `via` werden ignoriert. */
    private static func parseRestriction(_ element: [String: Any]) -> TurnRestriction? {
        guard let tags = element["tags"] as? [String: String],
              let value = tags["restriction"] ?? tags["restriction:motorcar"] ?? tags["restriction:motor_vehicle"],
              !(tags["except"] ?? "").contains("motorcar"),
              let members = element["members"] as? [[String: Any]] else { return nil }
        let only = value.hasPrefix("only_")
        guard only || value.hasPrefix("no_") else { return nil }
        func member(_ role: String, _ type: String) -> Int64? {
            let matches = members.filter { $0["role"] as? String == role && $0["type"] as? String == type }
            guard matches.count == 1 else { return nil }
            return (matches[0]["ref"] as? NSNumber)?.int64Value
        }
        guard let from = member("from", "way"), let via = member("via", "node"), let to = member("to", "way") else { return nil }
        return TurnRestriction(fromWay: from, viaNode: via, toWay: to, only: only)
    }

    static func encode(ways: [Int64: (WayRecord, [Int64])], coordinates: [Int64: (Double, Double)], restrictions: [TurnRestriction]) -> Data {
        var writer = BinaryWriter()
        writer.write(RoadDataStore.magic)
        writer.write(RoadDataStore.version)

        let wayList = Array(ways.values)
        writer.write(UInt32(wayList.count))
        for (record, _) in wayList {
            writer.write(record.osmId)
            writer.write(record.access.rawValue)
            writer.write(record.highway.rawValue)
            writer.write(UInt8(record.roundabout ? 1 : 0))
            writer.write(record.carSpeedKmh)
            writer.write(record.name)
            writer.write(record.ref)
        }

        var nodeIndex: [Int64: UInt32] = [:]
        nodeIndex.reserveCapacity(coordinates.count)
        writer.write(UInt32(coordinates.count))
        for (osmId, (lat, lon)) in coordinates {
            nodeIndex[osmId] = UInt32(nodeIndex.count)
            writer.write(osmId)
            writer.write(lat)
            writer.write(lon)
        }

        var edges: [(UInt32, UInt32, UInt32)] = []
        for (wayIdx, (_, nodeIds)) in wayList.enumerated() {
            for i in 0..<(nodeIds.count - 1) {
                guard let a = nodeIndex[nodeIds[i]], let b = nodeIndex[nodeIds[i + 1]], a != b else { continue }
                edges.append((a, b, UInt32(wayIdx)))
            }
        }
        writer.write(UInt32(edges.count))
        for (a, b, w) in edges {
            writer.write(a)
            writer.write(b)
            writer.write(w)
        }

        writer.write(UInt32(restrictions.count))
        for r in restrictions {
            writer.write(r.fromWay)
            writer.write(r.viaNode)
            writer.write(r.toWay)
            writer.write(UInt8(r.only ? 1 : 0))
        }
        return writer.data
    }
}
