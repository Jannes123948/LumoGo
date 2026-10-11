import Foundation

/**
 * „Route offline sichern“: Korridor entlang einer Route als Folge kleiner Rechtecke (je ≈ 8 km Strecke,
 * ± [bufferMeters] daneben, überlappend). Daraus werden Kartenpaket (Form statt Rechteck), Suchdaten
 * und Straßennetz geladen — statt des riesigen Rechtecks um eine lange Route.
 */
enum RouteCorridor {

    static func chunks(_ line: [LatLon], segmentMeters: Double = 8_000, bufferMeters: Double = 2_000) -> [BoundingBox] {
        guard line.count >= 2 else { return [] }
        var boxes: [BoundingBox] = []
        var current: [LatLon] = [line[0]]
        var length = 0.0
        for i in 1..<line.count {
            current.append(line[i])
            length += GeoUtils.distanceMeters(line[i - 1], line[i])
            if length >= segmentMeters {
                boxes.append(box(current, bufferMeters))
                current = [line[i]] // Abschnitte überlappen am Grenzpunkt
                length = 0
            }
        }
        if current.count >= 2 || boxes.isEmpty { boxes.append(box(current, bufferMeters)) }
        return boxes
    }

    /** Umschließendes Rechteck aller Abschnitte (für die Paketliste). */
    static func bounds(_ boxes: [BoundingBox]) -> BoundingBox? {
        guard let first = boxes.first else { return nil }
        return boxes.dropFirst().reduce(first) {
            BoundingBox(south: min($0.south, $1.south), north: max($0.north, $1.north),
                        west: min($0.west, $1.west), east: max($0.east, $1.east))
        }
    }

    /** Kacheln, die der Korridor in [minZoom]…[maxZoom] grob braucht (Rechtecke einzeln gezählt, Überlappung doppelt). */
    static func tileCount(_ boxes: [BoundingBox], minZoom: Int, maxZoom: Int) -> Int {
        boxes.reduce(0) { $0 + TileMath.tileCount($1, minZoom: minZoom, maxZoom: maxZoom) }
    }

    private static func box(_ points: [LatLon], _ buffer: Double) -> BoundingBox {
        let lats = points.map(\.latitude), lons = points.map(\.longitude)
        let midLat = (lats.min()! + lats.max()!) / 2
        let dLat = buffer / 111_320
        let dLon = buffer / (111_320 * max(cos(midLat * .pi / 180), 0.1))
        return BoundingBox(south: lats.min()! - dLat, north: lats.max()! + dLat, west: lons.min()! - dLon, east: lons.max()! + dLon)
    }
}
