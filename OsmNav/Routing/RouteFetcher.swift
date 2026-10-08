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
            // Nur ausweichen, wenn OSRM nicht erreichbar war — eine echte Antwort wie „NoRoute“
            // (Ziel unerreichbar) soll nicht still durch eine Offline-Route ersetzt werden.
            guard isConnectivityError(error), await OfflineRouter.shared.hasAnyData else { throw error }
            let route = try await OfflineRouter.shared.route(points, profile: profile)
            return RouteFetchResult(routes: [route], usedOfflineRouting: true)
        }
    }

    /** Kein Netz, Zeitüberschreitung, Offline-Modus, Server überlastet/kaputt (5xx, 429) oder eine
     *  unlesbare Antwort (z.B. WLAN-Anmeldeseite) — nicht aber eine gültige OSRM-Fehlerantwort. */
    static func isConnectivityError(_ error: Error) -> Bool {
        switch error {
        case is URLError: return true
        case AppError.offlineMode, AppError.parse: return true
        case AppError.http(let code): return code >= 500 || code == 429
        default: return false
        }
    }
}
