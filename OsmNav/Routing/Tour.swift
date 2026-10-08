import Foundation

/**
 * Eine importierte GPX-Tour (Komoot, Strava, Outdooractive …). Abgefahren wird sie über eine normale
 * Route durch ≈ 30 Durchgangspunkte der Spur ([vias]) — so gibt es echte Abbiegeansagen; die
 * Zwischenankünfte an den Durchgangspunkten werden mit [mergeViaLegs] entfernt.
 */
struct Tour: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    /** Originalspur (für die Anzeige auf der Karte). */
    let track: [LatLon]
    /** Durchgangspunkte für das Routing (erster = Start, letzter = Ziel). */
    let vias: [LatLon]

    var lengthMeters: Double { AlongRouteSearch.cumulativeDistances(track).last ?? 0 }

    /** Höchstens so viele Durchgangspunkte — OSRM nimmt mehr, aber jeder Punkt kann einen kleinen
     *  Schlenker erzwingen, wenn er neben der Straße liegt. */
    static let maxVias = 30

    init(id: String = UUID().uuidString, name: String, track: [LatLon]) {
        self.id = id
        self.name = name
        self.track = track
        vias = Self.selectVias(track)
    }

    /** Gleichmäßig über die Länge verteilt, mindestens 400 m auseinander, Start und Ziel immer dabei. */
    static func selectVias(_ track: [LatLon]) -> [LatLon] {
        guard track.count >= 2 else { return track }
        let cumulative = AlongRouteSearch.cumulativeDistances(track)
        let total = cumulative.last ?? 0
        let spacing = max(400, total / Double(maxVias - 1))
        var result = [track[0]]
        var next = spacing
        for i in track.indices.dropFirst() where cumulative[i] >= next {
            result.append(track[i])
            next = cumulative[i] + spacing
        }
        // Ziel exakt; ein zu dicht davor liegender Punkt fliegt raus.
        if let last = result.last, GeoUtils.distanceMeters(last, track.last!) < spacing / 2, result.count > 1 { result.removeLast() }
        result.append(track.last!)
        return result
    }

    /**
     * Fasst die Etappen zwischen Durchgangspunkten zu durchgehenden Etappen zusammen: Ankunft am
     * Durchgangspunkt + folgendes „Losfahren“ fallen weg. Etappen in [keepArrivalAfter] (echte
     * Zwischenstopps) behalten ihre Ankunft. nodeLegs (Tempolimits) bleiben unverändert.
     */
    static func mergeViaLegs(_ route: OsrmRoute, keepArrivalAfter: Set<Int> = []) -> OsrmRoute {
        guard route.legs.count > 1 else { return route }
        var legs: [OsrmLeg] = []
        var current: [OsrmStep] = []
        for (index, leg) in route.legs.enumerated() {
            var steps = leg.steps
            let isLast = index == route.legs.count - 1
            let previousKept = index > 0 && keepArrivalAfter.contains(index - 1)
            if index > 0 && !previousKept, steps.first?.maneuver.type == "depart" { steps.removeFirst() }
            let keep = isLast || keepArrivalAfter.contains(index)
            if !keep, steps.last?.maneuver.type == "arrive" { steps.removeLast() }
            current += steps
            if keep {
                legs.append(OsrmLeg(steps: current))
                current = []
            }
        }
        return OsrmRoute(geometry: route.geometry, legs: legs, distance: route.distance, duration: route.duration, nodeLegs: route.nodeLegs)
    }
}

/** Liest Track- (`trkpt`) und Routenpunkte (`rtept`) samt Namen aus einer GPX-Datei. */
final class GPXReader: NSObject, XMLParserDelegate {
    private var points: [LatLon] = []
    private var routePoints: [LatLon] = []
    private var name: String?
    private var inName = false
    private var nameDepthOk = true
    private var text = ""

    /** nil = keine Punkte gefunden bzw. keine gültige GPX-Datei. */
    static func read(_ data: Data, fallbackName: String) -> Tour? {
        let reader = GPXReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse() else { return nil }
        // Tracks bevorzugt (echte Spur), sonst Routenpunkte.
        let track = reader.points.count >= 2 ? reader.points : reader.routePoints
        guard track.count >= 2 else { return nil }
        let name = reader.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Tour(name: (name?.isEmpty == false ? name! : fallbackName), track: track)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        switch elementName {
        case "trkpt", "rtept":
            if let lat = attributes["lat"].flatMap(Double.init), let lon = attributes["lon"].flatMap(Double.init),
               (-90...90).contains(lat), (-180...180).contains(lon) {
                if elementName == "trkpt" { points.append(LatLon(lat, lon)) } else { routePoints.append(LatLon(lat, lon)) }
            }
            nameDepthOk = false // Namen einzelner Punkte ignorieren
        case "name":
            if name == nil && nameDepthOk { inName = true; text = "" }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inName { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName {
        case "name" where inName:
            inName = false
            name = text
        case "trkpt", "rtept":
            nameDepthOk = true
        default:
            break
        }
    }
}
