import Foundation

/**
 * Ruft den öffentlichen OSRM-Demo-Server auf (Auto) bzw. die FOSSGIS-Instanzen (Fahrrad/Fuß).
 * Unauthentifiziert, rate-limited, ohne SLA — nur zum Testen geeignet.
 */
enum OsrmClient {

    private static let session = HTTP.session(requestTimeout: 15)

    private static func baseUrl(_ profile: RoutingProfile) -> String {
        switch profile {
        case .car: return "https://router.project-osrm.org/route/v1/driving/"
        case .bike: return "https://routing.openstreetmap.de/routed-bike/route/v1/bike/"
        case .foot: return "https://routing.openstreetmap.de/routed-foot/route/v1/foot/"
        }
    }

    /**
     * [points] enthält Start, optionale Zwischenziele und das Endziel. [alternatives] wirkt bei
     * OSRM nur bei genau zwei Punkten (Start + Ziel ohne Zwischenstopps).
     */
    static func getRoutes(_ points: [LatLon], alternatives: Bool, profile: RoutingProfile) async throws -> [OsrmRoute] {
        let coordinates = points.map { "\($0.longitude),\($0.latitude)" }.joined(separator: ";")
        var query = [
            ("overview", "full"),
            ("geometries", "geojson"),
            ("steps", "true"),
            ("alternatives", alternatives ? "true" : "false")
        ]
        // OSM-Knoten der Route → Tempolimits (SpeedLimitMap); `maxspeed` kennt der Demo-Server nicht.
        if profile == .car { query.append(("annotations", "nodes")) }
        let url = HTTP.url(baseUrl(profile) + coordinates, query)
        let data = try await HTTP.data(session, for: URLRequest(url: url))
        let response: RouteResponse
        do {
            response = try JSONDecoder().decode(RouteResponse.self, from: data)
        } catch {
            throw AppError.parse
        }
        guard response.code == "Ok", let routes = response.routes else {
            throw AppError.server(response.code)
        }
        return routes.map { $0.toModel() }
    }

    /** OSRMs `nearest`-Dienst: nächstgelegener Punkt auf dem Straßennetz ("Snap to road"). */
    static func getNearestRoadPoint(_ point: LatLon) async throws -> LatLon {
        let url = HTTP.url("https://router.project-osrm.org/nearest/v1/driving/\(point.longitude),\(point.latitude)", [("number", "1")])
        let data = try await HTTP.data(session, for: URLRequest(url: url))
        guard let response = try? JSONDecoder().decode(NearestResponse.self, from: data) else { throw AppError.parse }
        guard response.code == "Ok", let location = response.waypoints?.first?.location, location.count == 2 else {
            throw AppError.server(response.code)
        }
        return LatLon(location[1], location[0])
    }

    // MARK: - DTOs

    private struct NearestResponse: Decodable {
        let code: String
        let waypoints: [NearestWaypoint]?
    }

    private struct NearestWaypoint: Decodable {
        let location: [Double]
    }

    private struct RouteResponse: Decodable {
        let code: String
        let routes: [RouteDTO]?
    }

    private struct RouteDTO: Decodable {
        let geometry: GeometryDTO
        let legs: [LegDTO]
        let distance: Double
        let duration: Double

        func toModel() -> OsrmRoute {
            OsrmRoute(
                geometry: geometry.coordinates.map { LatLon($0[1], $0[0]) },
                legs: legs.map { OsrmLeg(steps: $0.steps.map { $0.toModel() }) },
                distance: distance,
                duration: duration,
                nodeLegs: legs.map { $0.annotation?.nodes ?? [] }
            )
        }
    }

    private struct GeometryDTO: Decodable {
        let coordinates: [[Double]]
    }

    private struct LegDTO: Decodable {
        let steps: [StepDTO]
        let annotation: AnnotationDTO?
    }

    private struct AnnotationDTO: Decodable {
        let nodes: [Int64]?
    }

    private struct StepDTO: Decodable {
        let maneuver: ManeuverDTO
        let name: String?
        let distance: Double
        let duration: Double
        let destinations: String?
        let exits: String?
        let intersections: [IntersectionDTO]?

        func toModel() -> OsrmStep {
            // Fahrstreifen liegen in der ersten `intersections`-Eintragung des Schritts — das ist
            // per Spezifikation der Manöverpunkt dieses Schritts selbst.
            let lanes = intersections?.first?.lanes?.map { OsrmLane(indications: $0.indications, valid: $0.valid ?? false) }
            return OsrmStep(
                maneuver: OsrmManeuver(
                    type: maneuver.type,
                    modifier: maneuver.modifier,
                    exit: maneuver.exit,
                    location: LatLon(maneuver.location[1], maneuver.location[0])
                ),
                name: name ?? "",
                distance: distance,
                duration: duration,
                destinations: destinations,
                exits: exits,
                lanes: lanes
            )
        }
    }

    private struct ManeuverDTO: Decodable {
        let type: String
        let modifier: String?
        let exit: Int?
        let location: [Double]
    }

    private struct IntersectionDTO: Decodable {
        let lanes: [LaneDTO]?
    }

    private struct LaneDTO: Decodable {
        let indications: [String]
        let valid: Bool?
    }
}
