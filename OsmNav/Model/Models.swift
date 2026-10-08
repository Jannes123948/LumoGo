import Foundation
import CoreLocation

/** Engine-unabhängiger Koordinatentyp (Port von `model/LatLon.kt`). Geteilte Logik (Routing,
 *  Fortschritt, Distanzen) arbeitet nur hiermit; die Karte konvertiert an ihren Rändern. */
struct LatLon: Codable, Hashable {
    var latitude: Double
    var longitude: Double

    init(_ latitude: Double, _ longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    init(_ coordinate: CLLocationCoordinate2D) {
        self.init(coordinate.latitude, coordinate.longitude)
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/** Rechteckiger Kartenausschnitt (WGS84-Grad) — z.B. Nominatims `boundingbox`-Feld. */
struct BoundingBox: Codable, Hashable {
    var south: Double
    var north: Double
    var west: Double
    var east: Double
}

struct SearchResult: Codable, Hashable, Identifiable {
    var id: String { "\(displayName)|\(lat)|\(lon)" }
    let displayName: String
    let lat: Double
    let lon: Double
    /** Nur für Verwaltungsgebiete sinnvoll gefüllt — Grundlage für Offline-Kartendownloads. */
    let boundingBox: BoundingBox?

    var point: LatLon { LatLon(lat, lon) }
}

/** Ein Ziel/Zwischenstopp der aktuellen Route (Port von `Waypoint` aus `WaypointsAdapter.kt`). */
struct Waypoint: Identifiable, Hashable {
    let id = UUID()
    let point: LatLon
    let label: String
}

/** Gespeicherter Ort — [isHome] markiert höchstens einen Eintrag als "Zuhause". */
struct Favorite: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let point: LatLon
    let isHome: Bool
}

/** Eine abgeschlossene Fahrt (nur bei tatsächlicher Ankunft geloggt, nicht bei Abbruch). */
struct Trip: Codable, Identifiable, Hashable {
    let id: String
    let destinationName: String
    let distanceMeters: Double
    let durationSeconds: Double
    let timestamp: Date
}

// MARK: - OSRM

/** Relevante Felder der OSRM-`/route`-Antwort (Port von `OsrmModels.kt`). */
struct OsrmRoute: Identifiable, Equatable {
    let id = UUID()
    /** Dichte Routengeometrie (`overview=full`). */
    let geometry: [LatLon]
    let legs: [OsrmLeg]
    let distance: Double
    let duration: Double
    /** OSM-Knoten-IDs je Etappe (OSRM `annotations=nodes`, nur Auto) — für die Tempolimits.
     *  Leer bei Offline-Routen. */
    var nodeLegs: [[Int64]] = []

    static func == (lhs: OsrmRoute, rhs: OsrmRoute) -> Bool { lhs.id == rhs.id }
}

struct OsrmLeg {
    let steps: [OsrmStep]
}

struct OsrmStep {
    let maneuver: OsrmManeuver
    let name: String
    let distance: Double
    let duration: Double
    /** Nur bei Autobahnausfahrten/-verzweigungen vorhanden. */
    let destinations: String?
    let exits: String?
    /** Fahrstreifen an der Kreuzung dieses Schritts (links->rechts), nur bei `turn:lanes` in OSM. */
    let lanes: [OsrmLane]?
}

struct OsrmLane: Hashable {
    let indications: [String]
    let valid: Bool
}

struct OsrmManeuver {
    let type: String
    let modifier: String?
    let exit: Int?
    let location: LatLon
}
