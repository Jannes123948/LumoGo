import Foundation

struct ElevationPoint: Identifiable {
    var id: Double { distanceMeters }
    let distanceMeters: Double
    let elevationMeters: Double
}

struct ElevationProfile {
    let points: [ElevationPoint]
    let ascentMeters: Double
    let descentMeters: Double
}

/** Höhendaten vom öffentlichen Open-Elevation-Server (OSRM liefert keine Höhen). */
enum ElevationClient {
    private static let session = HTTP.session(requestTimeout: 20)

    static func fetchElevations(_ points: [LatLon]) async throws -> [Double] {
        var request = URLRequest(url: URL(string: "https://api.open-elevation.com/api/v1/lookup")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = ["locations": points.map { ["latitude": $0.latitude, "longitude": $0.longitude] }]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data = try await HTTP.data(session, for: request)
        struct Response: Decodable {
            struct Item: Decodable { let elevation: Double }
            let results: [Item]
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { throw AppError.parse }
        return response.results.map(\.elevation)
    }
}

/** Grobes Höhenprofil aus 30 gleichmäßig über die Streckenlänge verteilten Stichproben. */
enum ElevationProfileBuilder {
    private static let sampleCount = 30

    static func samplePoints(_ routePoints: [LatLon]) -> [(LatLon, Double)] {
        guard routePoints.count >= 2 else { return routePoints.map { ($0, 0) } }
        var cumulative = [0.0]
        for i in 1..<routePoints.count {
            cumulative.append(cumulative[i - 1] + GeoUtils.distanceMeters(routePoints[i - 1], routePoints[i]))
        }
        let total = cumulative[cumulative.count - 1]
        guard total > 0 else { return [(routePoints[0], 0)] }

        var result: [(LatLon, Double)] = []
        var searchIndex = 0
        for step in 0..<sampleCount {
            let target = total * Double(step) / Double(sampleCount - 1)
            while searchIndex < cumulative.count - 2 && cumulative[searchIndex + 1] < target { searchIndex += 1 }
            result.append((routePoints[searchIndex], target))
        }
        return result
    }

    static func build(_ samples: [(LatLon, Double)], _ elevations: [Double]) -> ElevationProfile {
        let points = zip(samples, elevations).map { ElevationPoint(distanceMeters: $0.0.1, elevationMeters: $0.1) }
        var ascent = 0.0
        var descent = 0.0
        for i in points.indices.dropFirst() {
            let delta = points[i].elevationMeters - points[i - 1].elevationMeters
            if delta > 0 { ascent += delta } else { descent -= delta }
        }
        return ElevationProfile(points: points, ascentMeters: ascent, descentMeters: descent)
    }
}
