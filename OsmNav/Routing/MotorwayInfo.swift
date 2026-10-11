import Foundation

/** Eintrag der Autobahn-Leiste: Ausfahrt, Kreuz/Dreieck oder Rastanlage auf der Route. */
struct MotorwayPoi: Identifiable, Equatable {
    enum Kind: Equatable { case exit, interchange, services, restArea }

    let id: String
    let kind: Kind
    /** „Dresden-Altstadt“, „Dreieck Dresden-West“, „Rasthof Dresdner Tor“. */
    let title: String
    /** Ausfahrtnummer („78“), nur bei Ausfahrten. */
    let ref: String?
    /** Strecke ab Routenstart. */
    let along: Double
    /** Hier verlässt die Route die Autobahn (bzw. wechselt sie). */
    var isOurExit = false

    var symbol: String {
        switch kind {
        case .exit: return "arrow.up.right"
        case .interchange: return "arrow.triangle.branch"
        case .services: return "fuelpump.fill"
        case .restArea: return "parkingsign"
        }
    }
}

/** Was die Leiste anzeigt: Eintrag + Entfernung ab der aktuellen Position. */
struct MotorwayAheadItem: Identifiable, Equatable {
    let poi: MotorwayPoi
    let distanceText: String
    var id: String { poi.id }
}

/**
 * Autobahn-Leiste: Ausfahrten kommen aus den OSM-Knoten der Route (`motorway_junction`, siehe
 * [SpeedLimitMap]) — damit nur die in Fahrtrichtung. Rastanlagen/Parkplätze ohne eigenen
 * Ausfahrt-Knoten holt [restAreas] per Overpass entlang der Route.
 */
enum MotorwayInfo {

    /** Manöver, bei denen man die Autobahn verlässt oder wechselt. */
    private static let leavingTypes: Set<String> = ["off ramp", "fork", "turn", "end of road", "roundabout", "rotary"]

    static func kind(forJunctionName name: String?) -> MotorwayPoi.Kind {
        let n = (name ?? "").lowercased()
        if n.contains("rasthof") || n.contains("raststätte") || n.contains("rastanlage") || n.contains("tank & rast") || n.contains("autohof") {
            return .services
        }
        if n.contains("rastplatz") || n.contains("parkplatz") { return .restArea }
        if n.contains("kreuz") || n.contains("dreieck") || n.contains("knoten") || n.contains("interchange") { return .interchange }
        return .exit
    }

    /** Ausfahrt-Knoten → Einträge mit Lage entlang der Route; markiert die Ausfahrt, an der die Route abbiegt. */
    static func junctionPois(_ junctions: [SpeedLimitMap.Junction], tracker: RouteProgressTracker,
                             line: [LatLon], cumulative: [Double]) -> [MotorwayPoi] {
        guard line.count >= 2 else { return [] }
        let maneuvers = (1..<max(tracker.stepCount, 1)).compactMap { i -> Double? in
            leavingTypes.contains(tracker.step(i).maneuverType) ? tracker.maneuverAlong(i) : nil
        }
        return junctions.compactMap { junction -> MotorwayPoi? in
            let (along, offset) = AlongRouteSearch.project(junction.point, onto: line, cumulative: cumulative)
            // Der Knoten liegt auf der Route — größere Abstände = Fehlzuordnung.
            // Ohne Namen und Nummer sagt der Eintrag nichts (z.B. Betriebsausfahrten).
            guard offset < 30, junction.name != nil || junction.ref != nil else { return nil }
            var kind = kind(forJunctionName: junction.name)
            // In Deutschland haben echte Ausfahrten eine Nummer — ohne Nummer ist es meist ein
            // Parkplatz/eine Rastanlage („Am Steinberg“); [mergeRestAreas] präzisiert das.
            if kind == .exit, junction.ref == nil { kind = .restArea }
            let title = junction.name ?? (kind == .exit ? String(localized: "Ausfahrt") : String(localized: "Abzweig"))
            // OSRMs Abfahrt-Manöver liegt am Ausfahrt-Knoten oder kurz dahinter.
            let ours = maneuvers.contains { $0 >= along - 50 && $0 <= along + 300 }
            return MotorwayPoi(id: "j\(junction.id)", kind: kind, title: title, ref: kind == .exit ? junction.ref : nil,
                               along: along, isOurExit: ours)
        }
        .sorted { $0.along < $1.along }
    }

    /** Roher Treffer der Rastanlagen-Abfrage. */
    struct RestAreaPlace: Equatable {
        let id: String
        let name: String?
        let point: LatLon
        let services: Bool
    }

    /**
     * Rastanlagen (`highway=services`) und Parkplätze (`highway=rest_area`) im Umkreis der Route.
     * [line] = ganze Routenlinie; wird für die Abfrage vereinfacht.
     */
    static func fetchRestAreas(line: [LatLon], cumulative: [Double]) async throws -> [RestAreaPlace] {
        guard line.count >= 2 else { return [] }
        let total = cumulative.last ?? 0
        // ≈ 150 Punkte: mit deutlich mehr bricht der öffentliche Server die Abfrage ab.
        let simplified = AlongRouteSearch.simplify(line, cumulative: cumulative, spacing: max(400, total / 150))
        let coords = simplified.map { String(format: "%.5f,%.5f", $0.latitude, $0.longitude) }.joined(separator: ",")
        let query = """
        [out:json][timeout:40];
        nwr["highway"~"^(services|rest_area)$"](around:500,\(coords));
        out tags center qt;
        """
        let data = try await OverpassClient.rawQuery(query, retryCount: 2)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let elements = root["elements"] as? [[String: Any]] else { throw AppError.parse }
        return elements.compactMap { el in
            guard let tags = el["tags"] as? [String: String], let type = el["type"] as? String,
                  let id = (el["id"] as? NSNumber)?.int64Value,
                  tags["atmotorway"] != "no" else { return nil } // Autohöfe hinter der Ausfahrt
            let lat = (el["lat"] as? Double) ?? ((el["center"] as? [String: Any])?["lat"] as? Double)
            let lon = (el["lon"] as? Double) ?? ((el["center"] as? [String: Any])?["lon"] as? Double)
            guard let lat, let lon else { return nil }
            let name = tags["name"].flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            return RestAreaPlace(id: "\(type)\(id)", name: name, point: LatLon(lat, lon), services: tags["highway"] == "services")
        }
    }

    /**
     * Ergänzt [junctions] um Rastanlagen, die zur eigenen Fahrtrichtung gehören: höchstens 350 m
     * neben einem Autobahn-Abschnitt der Route und RECHTS davon (Rechtsverkehr — die der Gegenfahrbahn
     * liegen links). Gibt es dafür schon einen Ausfahrt-Knoten kurz davor („Rasthof …“, „Am Steinberg“),
     * wird nur dessen Art übernommen (Rastanlage mit Tankstelle oder Parkplatz).
     */
    static func mergeRestAreas(_ places: [RestAreaPlace], into junctions: [MotorwayPoi], line: [LatLon], cumulative: [Double],
                               isMotorway: (LatLon) -> Bool) -> [MotorwayPoi] {
        guard line.count >= 2 else { return junctions }
        var result = junctions
        var added: [MotorwayPoi] = []
        // Rastanlagen zuerst (bei Doppeltreffern gewinnt die Rastanlage gegen den Parkplatz).
        for place in places.sorted(by: { $0.services && !$1.services }) {
            let (along, offset) = AlongRouteSearch.project(place.point, onto: line, cumulative: cumulative)
            guard offset <= 350 else { continue }
            let foot = AlongRouteSearch.point(at: along, on: line, cumulative: cumulative)
            guard isMotorway(foot) else { continue }
            let a = AlongRouteSearch.point(at: max(0, along - 40), on: line, cumulative: cumulative)
            let b = AlongRouteSearch.point(at: along + 40, on: line, cumulative: cumulative)
            guard isRightOf(place.point, from: a, to: b) else { continue }
            // Ausfahrt-Knoten liegt kurz vor der Anlage.
            if let i = result.firstIndex(where: { ($0.kind == .services || $0.kind == .restArea) && along - $0.along > -300 && along - $0.along < 2000 }) {
                if place.services, result[i].kind == .restArea {
                    let old = result[i]
                    result[i] = MotorwayPoi(id: old.id, kind: .services, title: old.title, ref: nil, along: old.along, isOurExit: old.isOurExit)
                }
                continue
            }
            if added.contains(where: { abs($0.along - along) < 800 }) { continue }
            added.append(MotorwayPoi(id: place.id, kind: place.services ? .services : .restArea,
                                     title: place.name ?? (place.services ? String(localized: "Rastanlage") : String(localized: "Parkplatz")), ref: nil, along: along))
        }
        return (result + added).sorted { $0.along < $1.along }
    }

    /** Liegt [p] rechts der Richtung a → b? (lokale Ebene, x = Ost, y = Nord) */
    static func isRightOf(_ p: LatLon, from a: LatLon, to b: LatLon) -> Bool {
        let k = cos(a.latitude * .pi / 180)
        let dx = (b.longitude - a.longitude) * k, dy = b.latitude - a.latitude
        let px = (p.longitude - a.longitude) * k, py = p.latitude - a.latitude
        return dx * py - dy * px < 0
    }

    /** Die nächsten [limit] Einträge vor [traveled] (höchstens [maxAhead] voraus). */
    static func upcoming(_ pois: [MotorwayPoi], traveled: Double, limit: Int = 3, maxAhead: Double = 80_000) -> [MotorwayAheadItem] {
        // Nach der eigenen Ausfahrt ist die Autobahn zu Ende — was danach kommt, interessiert nicht.
        let ownExit = pois.filter { $0.isOurExit && $0.along > traveled + 10 }.map(\.along).min() ?? .greatestFiniteMagnitude
        return pois.filter { $0.along > traveled + 10 && $0.along - traveled <= maxAhead && $0.along <= ownExit }
            .sorted { $0.along < $1.along }
            .prefix(limit)
            .map { MotorwayAheadItem(poi: $0, distanceText: FormatUtils.formatDistance($0.along - traveled)) }
    }
}
