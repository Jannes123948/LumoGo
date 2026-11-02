import Foundation

struct RouteFetchResult {
    let routes: [OsrmRoute]
    let usedOfflineRouting: Bool
    /** Hinweis zu „Route meiden“ (z.B. Maut nicht vermeidbar); nil = alles wie gewünscht. */
    var avoidNote: String? = nil
}

/**
 * Online zuerst (OSRM), bei Fehlschlag (kein Internet) automatisch Offline-Routing über das
 * heruntergeladene Straßennetz ([OfflineRouter]) — Pendant zu `RouteFetcher.kt` mit BRouter.
 * Von Routenberechnung UND Re-Routing genutzt.
 */
enum RouteFetcher {
    static func getRoutes(_ points: [LatLon], alternatives: Bool, profile: RoutingProfile,
                          avoid: RouteAvoidOptions = .none) async throws -> RouteFetchResult {
        var avoidNote: String?
        if avoid.isActive, profile == .car {
            do {
                return try await getAvoidingRoute(points, avoid: avoid)
            } catch {
                if Task.isCancelled { throw error }
                // Valhalla nicht erreichbar o.ä.: normale Route statt gar keiner — mit Hinweis.
                avoidNote = String(localized: "Meiden gerade nicht möglich – normale Route berechnet.")
            }
        }
        do {
            let routes = try await OsrmClient.getRoutes(points, alternatives: alternatives, profile: profile)
            guard !routes.isEmpty else { throw AppError.noResults }
            return RouteFetchResult(routes: routes, usedOfflineRouting: false, avoidNote: avoidNote)
        } catch {
            if Task.isCancelled { throw error }
            // Nur ausweichen, wenn OSRM nicht erreichbar war — eine echte Antwort wie „NoRoute“
            // (Ziel unerreichbar) soll nicht still durch eine Offline-Route ersetzt werden.
            guard isConnectivityError(error), await OfflineRouter.shared.hasAnyData else { throw error }
            let route = try await OfflineRouter.shared.route(points, profile: profile)
            return RouteFetchResult(routes: [route], usedOfflineRouting: true,
                                    avoidNote: avoid.isActive && profile == .car
                                        ? String(localized: "Offline wird „Meiden“ nicht berücksichtigt.") : nil)
        }
    }

    /**
     * Route, die Maut/Autobahn/Fähren meidet: Valhalla liefert den Verlauf, daraus werden Zwischenpunkte
     * (höchstens ≈ 45 je Route, mind. 3 km Abstand), durch die OSRM die Route mit allen Hinweisen
     * rechnet. Die Zwischenpunkte verschwinden danach wieder (keine „Ziel erreicht“-Ansage dort).
     */
    private static func getAvoidingRoute(_ points: [LatLon], avoid: RouteAvoidOptions) async throws -> RouteFetchResult {
        let plan = try await ValhallaClient.plan(points, avoid: avoid)
        let total = plan.legs.reduce(0.0) { sum, leg in
            sum + zip(leg, leg.dropFirst()).reduce(0.0) { $0 + GeoUtils.distanceMeters($1.0, $1.1) }
        }
        let spacing = max(3000, total / 45)
        var expanded: [LatLon] = [points[0]]
        var groups: [Int] = []
        for (index, leg) in plan.legs.enumerated() {
            let via = ValhallaClient.viaPoints(leg, spacing: spacing)
            expanded.append(contentsOf: via)
            expanded.append(points[index + 1])
            groups.append(via.count + 1)
        }
        let routes = try await OsrmClient.getRoutes(expanded, alternatives: false, profile: .car)
        guard let first = routes.first else { throw AppError.noResults }
        var notes: [String] = []
        if avoid.tolls, plan.hasToll { notes.append(String(localized: "Maut ist auf dieser Strecke nicht vermeidbar.")) }
        if avoid.ferries, plan.hasFerry { notes.append(String(localized: "Fähre ist auf dieser Strecke nicht vermeidbar.")) }
        return RouteFetchResult(routes: [first.mergingLegs(groups: groups)], usedOfflineRouting: false,
                                avoidNote: notes.isEmpty ? nil : notes.joined(separator: " "))
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
