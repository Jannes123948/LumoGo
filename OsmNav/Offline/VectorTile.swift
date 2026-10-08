import Foundation

/**
 * Minimaler Decoder für Mapbox-Vektorkacheln (MVT 2.1, Protobuf) — gerade genug, um aus den
 * OpenFreeMap-Kacheln (OpenMapTiles-Schema) Straßennetz und Suchdaten zu lesen. Kein externes
 * Package: das Format besteht nur aus Varints, Längen-Feldern und Geometrie-Befehlen.
 */
struct VectorTile {

    enum Value: Equatable {
        case string(String)
        case double(Double)
        case int(Int64)
        case bool(Bool)

        var string: String? {
            switch self {
            case .string(let s): return s
            case .int(let i): return String(i)
            case .double(let d): return String(d)
            case .bool(let b): return b ? "yes" : "no"
            }
        }

        var int: Int64? {
            switch self {
            case .int(let i): return i
            case .double(let d): return Int64(d)
            case .string(let s): return Int64(s)
            case .bool(let b): return b ? 1 : 0
            }
        }
    }

    enum GeometryType: Int {
        case unknown = 0, point = 1, line = 2, polygon = 3
    }

    struct Feature {
        let id: UInt64?
        let type: GeometryType
        let properties: [String: Value]
        /** Teil-Geometrien in Kachelkoordinaten (0…extent; Puffer darüber hinaus möglich). */
        let geometry: [[(x: Int32, y: Int32)]]
    }

    struct Layer {
        let name: String
        let extent: Int
        let features: [Feature]
    }

    let layers: [String: Layer]

    /** [onlyLayers] = nur diese Layer dekodieren (spart Zeit bei großen Kacheln). */
    init(data: Data, onlyLayers: Set<String>? = nil) throws {
        let bytes = [UInt8](data)
        var reader = ProtoReader(bytes, 0, bytes.count)
        var layers: [String: Layer] = [:]
        while let (field, wire) = try reader.nextField() {
            if field == 3 && wire == 2 {
                let (start, end) = try reader.lengthDelimited()
                if let layer = try Self.decodeLayer(bytes, start, end, onlyLayers: onlyLayers) {
                    layers[layer.name] = layer
                }
            } else {
                try reader.skip(wire)
            }
        }
        self.layers = layers
    }

    private static func decodeLayer(_ bytes: [UInt8], _ start: Int, _ end: Int, onlyLayers: Set<String>?) throws -> Layer? {
        var reader = ProtoReader(bytes, start, end)
        var name = ""
        var extent = 4096
        var keys: [String] = []
        var values: [Value] = []
        var featureRanges: [(Int, Int)] = []
        while let (field, wire) = try reader.nextField() {
            switch (field, wire) {
            case (1, 2): name = try reader.string()
            case (2, 2): featureRanges.append(try reader.lengthDelimited())
            case (3, 2): keys.append(try reader.string())
            case (4, 2):
                let (vs, ve) = try reader.lengthDelimited()
                values.append(try decodeValue(bytes, vs, ve))
            case (5, 0): extent = Int(try reader.varint())
            default: try reader.skip(wire)
            }
        }
        if let onlyLayers, !onlyLayers.contains(name) { return nil }
        let features = try featureRanges.map { try decodeFeature(bytes, $0.0, $0.1, keys: keys, values: values) }
        return Layer(name: name, extent: extent, features: features)
    }

    private static func decodeValue(_ bytes: [UInt8], _ start: Int, _ end: Int) throws -> Value {
        var reader = ProtoReader(bytes, start, end)
        var value = Value.string("")
        while let (field, wire) = try reader.nextField() {
            switch (field, wire) {
            case (1, 2): value = .string(try reader.string())
            case (2, 5): value = .double(Double(Float(bitPattern: try reader.fixed32())))
            case (3, 1): value = .double(Double(bitPattern: try reader.fixed64()))
            case (4, 0): value = .int(Int64(bitPattern: try reader.varint()))
            case (5, 0): value = .int(Int64(bitPattern: try reader.varint()))
            case (6, 0): value = .int(ProtoReader.zigzag(try reader.varint()))
            case (7, 0): value = .bool(try reader.varint() != 0)
            default: try reader.skip(wire)
            }
        }
        return value
    }

    private static func decodeFeature(_ bytes: [UInt8], _ start: Int, _ end: Int, keys: [String], values: [Value]) throws -> Feature {
        var reader = ProtoReader(bytes, start, end)
        var id: UInt64?
        var type = GeometryType.unknown
        var tags: [UInt32] = []
        var commands: [UInt32] = []
        while let (field, wire) = try reader.nextField() {
            switch (field, wire) {
            case (1, 0): id = try reader.varint()
            case (2, 2): tags = try reader.packedUInt32()
            case (3, 0): type = GeometryType(rawValue: Int(try reader.varint())) ?? .unknown
            case (4, 2): commands = try reader.packedUInt32()
            default: try reader.skip(wire)
            }
        }
        var properties: [String: Value] = [:]
        var i = 0
        while i + 1 < tags.count {
            let k = Int(tags[i]), v = Int(tags[i + 1])
            if k < keys.count && v < values.count { properties[keys[k]] = values[v] }
            i += 2
        }
        return Feature(id: id, type: type, properties: properties, geometry: decodeGeometry(commands))
    }

    /** Geometrie-Befehle (MoveTo/LineTo/ClosePath, Zickzack-Deltas) → Teil-Linien/Ringe. */
    private static func decodeGeometry(_ commands: [UInt32]) -> [[(x: Int32, y: Int32)]] {
        var parts: [[(x: Int32, y: Int32)]] = []
        var current: [(x: Int32, y: Int32)] = []
        var x: Int32 = 0, y: Int32 = 0
        var i = 0
        while i < commands.count {
            let command = commands[i] & 0x7
            let count = Int(commands[i] >> 3)
            i += 1
            switch command {
            case 1, 2: // MoveTo, LineTo
                for _ in 0..<count where i + 1 < commands.count {
                    x &+= Int32(truncatingIfNeeded: ProtoReader.zigzag(UInt64(commands[i])))
                    y &+= Int32(truncatingIfNeeded: ProtoReader.zigzag(UInt64(commands[i + 1])))
                    i += 2
                    if command == 1 {
                        if !current.isEmpty { parts.append(current) }
                        current = [(x, y)]
                    } else {
                        current.append((x, y))
                    }
                }
            case 7: // ClosePath
                if let first = current.first { current.append(first) }
            default:
                return parts + (current.isEmpty ? [] : [current])
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }
}

/** Protobuf-Leser über einem Byte-Bereich. */
private struct ProtoReader {
    let bytes: [UInt8]
    var position: Int
    let end: Int

    init(_ bytes: [UInt8], _ start: Int, _ end: Int) {
        self.bytes = bytes
        self.position = start
        self.end = end
    }

    enum ReadError: Error { case truncated }

    mutating func nextField() throws -> (Int, Int)? {
        guard position < end else { return nil }
        let key = try varint()
        return (Int(key >> 3), Int(key & 0x7))
    }

    mutating func varint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard position < end else { throw ReadError.truncated }
            let byte = bytes[position]
            position += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            if shift > 63 { throw ReadError.truncated }
        }
    }

    mutating func fixed32() throws -> UInt32 {
        guard position + 4 <= end else { throw ReadError.truncated }
        var v: UInt32 = 0
        for i in 0..<4 { v |= UInt32(bytes[position + i]) << (8 * UInt32(i)) }
        position += 4
        return v
    }

    mutating func fixed64() throws -> UInt64 {
        guard position + 8 <= end else { throw ReadError.truncated }
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(bytes[position + i]) << (8 * UInt64(i)) }
        position += 8
        return v
    }

    mutating func lengthDelimited() throws -> (Int, Int) {
        let length = Int(try varint())
        let start = position
        guard start + length <= end else { throw ReadError.truncated }
        position += length
        return (start, start + length)
    }

    mutating func string() throws -> String {
        let (s, e) = try lengthDelimited()
        return String(decoding: bytes[s..<e], as: UTF8.self)
    }

    mutating func packedUInt32() throws -> [UInt32] {
        let (s, e) = try lengthDelimited()
        var inner = ProtoReader(bytes, s, e)
        var result: [UInt32] = []
        result.reserveCapacity((e - s) / 2)
        while inner.position < e { result.append(UInt32(truncatingIfNeeded: try inner.varint())) }
        return result
    }

    mutating func skip(_ wire: Int) throws {
        switch wire {
        case 0: _ = try varint()
        case 1: position += 8
        case 2: _ = try lengthDelimited()
        case 5: position += 4
        default: throw ReadError.truncated
        }
        guard position <= end else { throw ReadError.truncated }
    }

    static func zigzag(_ v: UInt64) -> Int64 {
        Int64(bitPattern: (v >> 1) ^ (0 &- (v & 1)))
    }
}

/** Entpacken: gzip (Server ohne Content-Encoding) und zlib (MapLibre-Datenbank). */
enum TileDecompression {
    /** Gibt die Daten entpackt zurück — oder unverändert, wenn sie nicht komprimiert sind. */
    static func inflateIfNeeded(_ data: Data) -> Data? {
        let b = [UInt8](data.prefix(16))
        if b.count >= 10 && b[0] == 0x1f && b[1] == 0x8b { return gunzip(data) }
        // zlib-Kopf: CMF 0x78, (CMF*256+FLG) % 31 == 0
        if b.count >= 2 && b[0] == 0x78 && (UInt16(b[0]) << 8 | UInt16(b[1])) % 31 == 0 {
            return rawInflate(data.dropFirst(2).dropLast(4))
        }
        return data
    }

    private static func gunzip(_ data: Data) -> Data? {
        let b = [UInt8](data)
        guard b.count > 18 else { return nil }
        let flags = b[3]
        var i = 10
        if flags & 0x04 != 0, i + 2 <= b.count { i += 2 + (Int(b[i]) | (Int(b[i + 1]) << 8)) }
        if flags & 0x08 != 0 { while i < b.count && b[i] != 0 { i += 1 }; i += 1 }
        if flags & 0x10 != 0 { while i < b.count && b[i] != 0 { i += 1 }; i += 1 }
        if flags & 0x02 != 0 { i += 2 }
        guard i < b.count - 8 else { return nil }
        return rawInflate(data.subdata(in: i..<(b.count - 8)))
    }

    /** Apples `.zlib`-Algorithmus ist reines DEFLATE (ohne Kopf/Prüfsumme). */
    private static func rawInflate(_ data: Data) -> Data? {
        try? (Data(data) as NSData).decompressed(using: .zlib) as Data
    }
}
