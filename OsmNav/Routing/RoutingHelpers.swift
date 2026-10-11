import Foundation
import CoreLocation

/** Fortbewegungsart — steuert den OSRM-Endpunkt (siehe `OsrmClient`). */
enum RoutingProfile: String, CaseIterable, Identifiable {
    case car, bike, foot
    var id: String { rawValue }

    var label: String {
        switch self {
        case .car: return String(localized: "Auto")
        case .bike: return String(localized: "Fahrrad")
        case .foot: return String(localized: "Zu Fuß")
        }
    }

    var symbol: String {
        switch self {
        case .car: return "car.fill"
        case .bike: return "bicycle"
        case .foot: return "figure.walk"
        }
    }
}

/**
 * Wählt wie bei Google Maps ein zum Manövertyp passendes Icon (SF Symbol). [rotationDegrees] nähert
 * "scharf" an; [mirrored] wird nicht mehr genutzt (eigene Links-Symbole), bleibt für die Anzeige erhalten.
 */
enum ManeuverIconResolver {

    struct Icon: Equatable {
        let symbolName: String
        let rotationDegrees: Double
        let mirrored: Bool
    }

    private static let roundaboutTypes: Set<String> = ["roundabout", "rotary", "roundabout turn", "exit roundabout", "exit rotary"]
    /** Abzweigungen ohne echtes Abbiegen (Gabelung, Auf-/Abfahrt) — schräge Pfeile wie bei Google Maps. */
    private static let branchTypes: Set<String> = ["fork", "off ramp", "on ramp"]

    /**
     * Echte Links-Symbole statt gespiegelter Rechts-Symbole. „end of road“ (T-Kreuzung — bei OSRM
     * sehr häufig) bekommt den normalen Abbiegepfeil; früher zeigte es das Gabel-Symbol, und beim
     * Rechtsabbiegen erschien so ein „anderes Symbol“ (Nutzermeldung).
     */
    static func resolve(type: String, modifier: String?) -> Icon {
        let isLeft = modifier?.contains("left") ?? false
        let isRight = modifier?.contains("right") ?? false
        if modifier == "uturn" { return Icon(symbolName: "arrow.uturn.down", rotationDegrees: 0, mirrored: false) }
        if type == "arrive" { return Icon(symbolName: "flag.checkered", rotationDegrees: 0, mirrored: false) }
        if roundaboutTypes.contains(type) {
            return Icon(symbolName: "arrow.triangle.turn.up.right.circle", rotationDegrees: 0, mirrored: false)
        }
        if type == "merge" { return Icon(symbolName: "arrow.triangle.merge", rotationDegrees: 0, mirrored: false) }
        if branchTypes.contains(type) {
            if isLeft { return Icon(symbolName: "arrow.up.left", rotationDegrees: 0, mirrored: false) }
            if isRight { return Icon(symbolName: "arrow.up.right", rotationDegrees: 0, mirrored: false) }
            return Icon(symbolName: "arrow.up", rotationDegrees: 0, mirrored: false)
        }
        switch modifier {
        case nil, "straight":
            return Icon(symbolName: "arrow.up", rotationDegrees: 0, mirrored: false)
        case "slight left":
            return Icon(symbolName: "arrow.up.left", rotationDegrees: 0, mirrored: false)
        case "slight right":
            return Icon(symbolName: "arrow.up.right", rotationDegrees: 0, mirrored: false)
        case "sharp left":
            return Icon(symbolName: "arrow.turn.up.left", rotationDegrees: -45, mirrored: false)
        case "sharp right":
            return Icon(symbolName: "arrow.turn.up.right", rotationDegrees: 45, mirrored: false)
        default:
            return Icon(symbolName: isLeft ? "arrow.turn.up.left" : "arrow.turn.up.right", rotationDegrees: 0, mirrored: false)
        }
    }
}

/** Zoomstufe während der Navigation abhängig von der Geschwindigkeit. */
enum NavZoom {
    static func forSpeed(_ speedMps: Double) -> Double {
        let kmh = max(speedMps, 0) * 3.6
        switch kmh {
        case ..<20: return 18.5
        case ..<50: return 17.5
        case ..<80: return 16.5
        case ..<120: return 15.5
        default: return 14.5
        }
    }
}

/**
 * Entscheidet, ob ein GPS-Kurswert vertrauenswürdig genug ist, um Kamera/Fahrzeug-Symbol zu
 * drehen — bei geringer Geschwindigkeit (Handy in der Hand, Ampel) ist der Kurs oft Rauschen.
 */
enum BearingFilter {
    private static let minSpeedMps = 2.0
    private static let maxCourseAccuracyDegrees = 45.0

    static func isReliable(_ location: CLLocation) -> Bool {
        guard location.course >= 0, location.speed > minSpeedMps else { return false }
        // courseAccuracy < 0 = vom Gerät nicht geliefert → nur die Geschwindigkeit zählt.
        return location.courseAccuracy < 0 || location.courseAccuracy <= maxCourseAccuracyDegrees
    }
}

/** Feste POI-Kategorien für den "In der Nähe"-Button (Overpass-Tagsuche). */
enum NearbyCategory: String, CaseIterable, Identifiable {
    case fuel, parking, charging, restArea, fastFood
    var id: String { rawValue }

    var label: String {
        switch self {
        case .fuel: return String(localized: "Tankstelle")
        case .parking: return String(localized: "Parkplatz")
        case .charging: return String(localized: "Ladesäule")
        case .restArea: return String(localized: "Rastplatz")
        case .fastFood: return String(localized: "Fast Food")
        }
    }

    var symbol: String {
        switch self {
        case .fuel: return "fuelpump.fill"
        case .parking: return "parkingsign.circle.fill"
        case .charging: return "bolt.car.fill"
        case .restArea: return "cup.and.saucer.fill"
        case .fastFood: return "takeoutbag.and.cup.and.straw.fill"
        }
    }

    var tags: [(String, String)] {
        switch self {
        case .fuel: return [("amenity", "fuel")]
        case .parking: return [("amenity", "parking")]
        case .charging: return [("amenity", "charging_station")]
        case .restArea: return [("highway", "rest_area"), ("highway", "services")]
        case .fastFood: return [("amenity", "fast_food")]
        }
    }
}

/**
 * "Auf die Straße setzen" außerhalb der Navigation: fragt gedrosselt (3s/15m) OSRMs
 * `nearest`-Dienst ab und liefert bis zur nächsten Antwort die zuletzt gesnappte Position.
 * Ohne Internet wird auf das heruntergeladene Straßennetz eingerastet ([OfflineRouter]).
 */
@MainActor
final class RoadSnapper {
    private static let minInterval: TimeInterval = 3
    private static let minDistanceMeters = 15.0

    private var lastQueriedAt = Date.distantPast
    private var lastQueriedPoint: LatLon?
    private var lastSnappedPoint: LatLon?
    /** Rohposition, für die [lastSnappedPoint] berechnet wurde. */
    private var lastSnappedFor: LatLon?
    private var lastRoadName = ""
    private var fetchInProgress = false

    /** Name der Straße, auf der man gerade ist (Namensleiste ohne Navigation); nil = unbekannt/unbenannt. */
    func roadName(near raw: LatLon) -> String? {
        guard let base = lastSnappedFor, GeoUtils.distanceMeters(raw, base) < 60, !lastRoadName.isEmpty else { return nil }
        return lastRoadName
    }

    /** Nur Straße/Namen aktualisieren, ohne die Position einzurasten (Einrasten ausgeschaltet). */
    func observe(_ raw: LatLon) { maybeRefresh(raw) }

    /**
     * Überträgt die zuletzt ermittelte Korrektur (Versatz zur Straße) auf die AKTUELLE Position,
     * statt bis zur nächsten Antwort den veralteten Punkt zu zeigen — sonst blieb der Pfeil bei
     * Fahrt bis zu 3 s stehen und sprang dann nach vorn.
     */
    func snap(_ raw: LatLon) -> LatLon {
        maybeRefresh(raw)
        guard let snapped = lastSnappedPoint, let base = lastSnappedFor,
              GeoUtils.distanceMeters(raw, base) < 60 else { return raw }
        return LatLon(raw.latitude + snapped.latitude - base.latitude,
                      raw.longitude + snapped.longitude - base.longitude)
    }

    func reset() {
        lastSnappedPoint = nil
        lastSnappedFor = nil
        lastQueriedPoint = nil
        lastRoadName = ""
    }

    private func maybeRefresh(_ raw: LatLon) {
        if fetchInProgress { return }
        let movedEnough = lastQueriedPoint.map { GeoUtils.distanceMeters(raw, $0) > Self.minDistanceMeters } ?? true
        let timeElapsed = Date().timeIntervalSince(lastQueriedAt) > Self.minInterval
        guard movedEnough || timeElapsed else { return }

        lastQueriedAt = Date()
        lastQueriedPoint = raw
        fetchInProgress = true
        Task {
            if let road = try? await OsrmClient.getNearestRoad(raw) {
                lastSnappedPoint = road.point
                lastSnappedFor = raw
                lastRoadName = road.name
            } else if let road = await OfflineRouter.shared.nearestRoad(raw) {
                // Kein Internet: auf das heruntergeladene Straßennetz einrasten.
                lastSnappedPoint = road.point
                lastSnappedFor = raw
                lastRoadName = road.name
            }
            fetchInProgress = false
        }
    }
}
