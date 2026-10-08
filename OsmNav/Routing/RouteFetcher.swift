import Foundation

struct RouteFetchResult {
    let routes: [OsrmRoute]
    let usedOfflineRouting: Bool
}

/**
 * Online zuerst (OSRM), bei Fehlschlag (kein Internet) automatisch Offline-Routing über das
 * heruntergeladene Straßennetz ([OfflineRouter]) — Pendant zu `RouteFetcher.kt` mit BRouter.
 * Von Routenberechnung UND Re-Routing genutzt.
 */
enum RouteFetcher {
    static func getRoutes(_ points: [LatLon], alternatives: Bool, profile: RoutingProfile) async throws -> RouteFetchResult {
        do {
            let routes = try await OsrmClient.getRoutes(points, alternatives: alternatives, profile: profile)
            guard !routes.isEmpty else { throw AppError.noResults }
            return RouteFetchResult(routes: routes, usedOfflineRouting: false)
        } catch {
            if Task.isCancelled { throw error }
            guard await OfflineRouter.shared.hasAnyData else { throw error }
            let route = try await OfflineRouter.shared.route(points, profile: profile)
            return RouteFetchResult(routes: [route], usedOfflineRouting: true)
        }
    }
}
