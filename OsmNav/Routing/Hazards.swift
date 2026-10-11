import Foundation

/** Art einer Gefahrenstelle auf der Route. */
enum HazardKind: String, Equatable {
    case levelCrossing, school, kindergarten, speedBump, animalCrossing, fallingRocks, slippery, curve, dangerousJunction, children, cyclists, generic

    var label: String {
        switch self {
        case .levelCrossing: return String(localized: "Bahnübergang")
        case .school: return String(localized: "Schule")
        case .kindergarten: return String(localized: "Kindergarten")
        case .speedBump: return String(localized: "Bodenschwelle")
        case .animalCrossing: return String(localized: "Wildwechsel")
        case .fallingRocks: return String(localized: "Steinschlag")
        case .slippery: return String(localized: "Rutschgefahr")
        case .curve: return String(localized: "Scharfe Kurve")
        case .dangerousJunction: return String(localized: "Gefährliche Kreuzung")
        case .children: return String(localized: "Kinder")
        case .cyclists: return String(localized: "Radfahrer")
        case .generic: return String(localized: "Gefahrenstelle")
        }
    }

    var symbol: String {
        switch self {
        case .levelCrossing: return "train.side.front.car"
        case .school, .kindergarten, .children: return "figure.and.child.holdinghands"
        case .speedBump: return "car.rear.waves.up"
        case .animalCrossing: return "pawprint.fill"
        case .fallingRocks: return "mountain.2.fill"
        case .slippery: return "drop.fill"
        case .cyclists: return "bicycle"
        case .curve: return "arrow.turn.up.right"
        case .dangerousJunction, .generic: return "exclamationmark.triangle.fill"
        }
    }

    /** Schulen/Kindergärten nur werktags tagsüber ansagen (nachts und am Wochenende stört es nur). */
    func isRelevant(at date: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard self == .school || self == .kindergarten else { return true }
        let weekday = calendar.component(.weekday, from: date) // 1 = Sonntag
        let hour = calendar.component(.hour, from: date)
        return (2...6).contains(weekday) && (6..<18).contains(hour)
    }

    /** OSM-Tags → Art; nil = keine Gefahrenstelle (z.B. `railway=crossing` für Fußgänger). */
    static func from(tags: [String: String]) -> HazardKind? {
        if tags["railway"] == "level_crossing" { return .levelCrossing }
        if let calming = tags["traffic_calming"], ["bump", "hump", "table", "cushion", "yes"].contains(calming) { return .speedBump }
        switch tags["amenity"] {
        case "school": return .school
        case "kindergarten": return .kindergarten
        default: break
        }
        guard let hazard = tags["hazard"] else { return nil }
        switch hazard {
        case "animal_crossing", "deer", "wild_animals": return .animalCrossing
        case "falling_rocks", "rockfall": return .fallingRocks
        case "slippery", "ice", "slippery_road": return .slippery
        case "curve", "curves", "sharp_curve", "dangerous_curve": return .curve
        case "dangerous_junction", "junction": return .dangerousJunction
        case "children", "school_zone": return .children
        case "cyclists", "bicycles": return .cyclists
        default: return .generic
        }
    }
}

/** Gefahrenstelle mit Lage (aus OSM). */
struct Hazard: Equatable {
    let id: String
    let kind: HazardKind
    let point: LatLon
}

/** Gefahrenstelle entlang der Route (Strecke ab Routenstart). */
struct HazardOnRoute: Equatable {
    let id: String
    let kind: HazardKind
    let along: Double
}

/** Anzeige unter der Navi-Leiste. */
struct HazardAhead: Equatable {
    let id: String
    let kind: HazardKind
    let distanceText: String
}

/**
 * Gefahrenstellen auf der Route: OSM-Punkte (Bahnübergänge, Bodenschwellen, `hazard=*`, Schulen und
 * Kindergärten am Straßenrand) und scharfe Kurven, die aus der Routenlinie selbst erkannt werden.
 */
enum HazardDetector {

    /** OSM-Punkte auf die Route legen: Punkte auf der Straße ≤ 20 m, Schulen/Kindergärten ≤ 80 m daneben. */
    static func project(_ hazards: [Hazard], line: [LatLon], cumulative: [Double]) -> [HazardOnRoute] {
        guard line.count >= 2 else { return [] }
        var result: [HazardOnRoute] = []
        for hazard in hazards {
            let (along, offset) = AlongRouteSearch.project(hazard.point, onto: line, cumulative: cumulative)
            let maxOffset = (hazard.kind == .school || hazard.kind == .kindergarten) ? 80.0 : 20.0
            guard offset <= maxOffset else { continue }
            // Gleiche Art dicht hintereinander (zwei Schwellen, Schulgebäude mit mehreren Umrissen) nur einmal.
            if result.contains(where: { $0.kind == hazard.kind && abs($0.along - along) < 150 }) { continue }
            result.append(HazardOnRoute(id: hazard.id, kind: hazard.kind, along: along))
        }
        return result.sorted { $0.along < $1.along }
    }

    /**
     * Scharfe Kurven ohne Abbiegen: Richtungsänderung ≥ 70° innerhalb von 60 m Strecke (Radius unter
     * ≈ 50 m), nicht näher als 80 m an einem Manöver (dort sagt die Navigation ohnehin an), nicht am
     * Routenanfang/-ende.
     */
    static func curves(line: [LatLon], cumulative: [Double], maneuverAlongs: [Double]) -> [HazardOnRoute] {
        guard line.count >= 3, let total = cumulative.last, total > 300 else { return [] }
        let step = 10.0, window = 60.0
        // Richtung je 10 m (Sehne über 20 m — glättet Knickpunkte der Geometrie).
        var bearings: [(along: Double, bearing: Double)] = []
        var d = 0.0
        while d + 20 <= total {
            let a = AlongRouteSearch.point(at: d, on: line, cumulative: cumulative)
            let b = AlongRouteSearch.point(at: d + 20, on: line, cumulative: cumulative)
            bearings.append((d + 10, GeoUtils.bearing(a, b)))
            d += step
        }
        let span = Int(window / step)
        var result: [HazardOnRoute] = []
        var i = 0
        while i + span < bearings.count {
            let turn = angle(bearings[i].bearing, bearings[i + span].bearing)
            let middle = (bearings[i].along + bearings[i + span].along) / 2
            if turn >= 70, middle > 150, middle < total - 150,
               !maneuverAlongs.contains(where: { abs($0 - middle) < 80 }) {
                result.append(HazardOnRoute(id: "curve-\(Int(middle))", kind: .curve, along: bearings[i].along))
                i += span * 2 // Eine Kurve nur einmal
            } else {
                i += 1
            }
        }
        return result
    }

    /** „Achtung, Bahnübergang in 200 Metern.“ / „Caution, level crossing in 200 meters.“ */
    static func sentence(_ kind: HazardKind, meters: Double) -> String {
        let rounded = AnnouncementPlanner.roundForSpeech(meters)
        if AppLanguage.isEnglish {
            return "Caution, \(kind.label.lowercased()) in \(EnglishInstructions.spokenDistance(rounded))."
        }
        return "Achtung, \(kind.label) in \(AnnouncementPlanner.spokenDistance(rounded))."
    }

    private static func angle(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(d, 360 - d)
    }
}
