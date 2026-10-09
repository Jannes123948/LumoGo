import SwiftUI
import CoreLocation
import MapLibre

/** Zustand der Navigations-HUD-Anzeige (oben + unten). */
struct NavHudState {
    var distanceText = ""
    var instruction = ""
    var icon = ManeuverIconResolver.Icon(symbolName: "arrow.up", rotationDegrees: 0, mirrored: false)
    var etaText = ""
    var summaryText = ""
    var lanes: [OsrmLane] = []
    /** Aktuelle Straße für die Namensleiste unten; nil = ausblenden. */
    var roadName: String?
}

/**
 * Zentrale App-Logik — Pendant zu `MainActivity.kt` ohne die Android-UI: Suche, Ziele,
 * Routenberechnung, Navigation (Fortschritt, Ansagen, Re-Routing), Favoriten, Fahrtenbuch.
 */
@MainActor
final class AppModel: ObservableObject {

    static let rerouteThresholdMeters = 50.0
    static let navTilt = 60.0
    static let idle3DTilt = 45.0

    /** Die laufende Instanz — für Siri-Kurzbefehle (App Intents laufen im App-Prozess). */
    static weak var current: AppModel?

    let settings: AppSettings
    let map = MapController()
    private let liveActivity = LiveActivityController()
    private let navWidget = NavWidgetPublisher()
    let location = LocationService()
    private let speech = SpeechService()
    private let roadSnapper = RoadSnapper()
    private let announcer = AnnouncementPlanner()
    private let speedLimits = SpeedLimitMap()
    private var speedLimitTask: Task<Void, Never>?
    private var speedingSince: Date?
    /** Vorheriger GPS-Fix — Geschwindigkeit selbst berechnen, wenn das iPhone keine liefert. */
    private var previousFix: CLLocation?
    private var lastSpeedAt = Date.distantPast
    /** Zeitpunkt des letzten GPS-Fixes — bleibt er aus, steht man (Standort-Updates kommen erst
     *  ab 3 m Bewegung, `distanceFilter`). */
    private var lastFixAt = Date.distantPast
    private var speedWatchdog: Timer?
    private var lastSpeedWarning: (limit: Int, at: Date)?

    // Suche
    @Published var searchText = "" { didSet { onSearchTextChanged() } }
    @Published var searchResults: [SearchResult] = []
    @Published var showSearchResults = false
    @Published var searchFocused = false { didSet { if searchFocused { showRecentSearchesIfEmpty() } } }
    private var searchTask: Task<Void, Never>?
    private var suppressSearch = false
    /** Läuft gerade eine Suche (Ladekreis in der Suchleiste). */
    @Published private(set) var searching = false
    /** Zuletzt gefundene Ergebnisse je Suchtext + grober Position — Rücktaste/erneutes Tippen zeigt
     *  sie sofort, an einem anderen Ort wird neu gesucht (Treffer sind nach Nähe sortiert). */
    private var searchCache: [String: (results: [SearchResult], at: Date)] = [:]

    // Ziele & Route
    @Published private(set) var waypoints: [Waypoint] = []
    @Published private(set) var routeOptions: [OsrmRoute] = []
    @Published private(set) var selectedRouteIndex = 0
    @Published private(set) var lastRoute: OsrmRoute?
    @Published private(set) var instructions: [PreviewInstruction] = []
    @Published var showInstructions = false
    @Published private(set) var elevationProfile: ElevationProfile?
    @Published private(set) var routeLoading = false
    /** Wetter entlang der Route (Open-Meteo), nil = keins/lädt. */
    @Published private(set) var routeWeather: RouteWeather?
    /** Laufende GPX-Tour (nil = normale Ziele). */
    @Published private(set) var activeTour: Tour?
    /** Index des nächsten noch nicht erreichten Durchgangspunkts der Tour. */
    private var tourProgress = 0
    /** Unterwegs eingefügter Halt während einer Tour (danach geht die Tour weiter). */
    private var tourStop: Waypoint?
    /**
     * Wie viele [waypoints] vor dem Start der aktuellen Route schon erreicht waren. Die Etappen der
     * Route zählen ab dort — ohne diesen Versatz schickte eine zweite Neuberechnung nach einem
     * erreichten Zwischenziel wieder zu diesem zurück.
     */
    private var waypointOffset = 0

    // Navigation
    @Published private(set) var navigationActive = false
    @Published private(set) var hud = NavHudState()
    @Published private(set) var followEnabled = true
    /** Tempolimit an der aktuellen Position (nil = unbekannt) und GPS-Geschwindigkeit. */
    @Published private(set) var speedLimit: SpeedLimit?
    @Published private(set) var speedKmh: Int?
    @Published private(set) var isSpeeding = false
    @Published private(set) var is3DEnabled = true
    /** Aktuelle Kartenrichtung in Grad (0 = Norden oben), für den Kompass-Knopf. */
    @Published private(set) var mapDirection = 0.0
    /** Navigation mit genordeter Karte statt in Fahrtrichtung (Antippen des Kompasses). */
    @Published private(set) var northUpNavigation = false
    @Published var pickingFavoriteLocation = false
    /** Blatt, das ein Deep Link/Kurzbefehl öffnen will; `.some(nil)` = alle Blätter schließen.
     *  ContentView setzt es nach dem Anwenden wieder auf nil. */
    @Published var requestedSheet: ActiveSheet??
    /** Route zum gesetzten Ziel berechnen + Navigation starten, sobald der erste Standort da ist. */
    private var pendingAutoNavigation = false
    /** Geteilte Ankunftszeit hat sich um > 5 min verschoben → Knopf „Neue Ankunftszeit teilen“. */
    @Published private(set) var etaShiftedTo: String?

    // Meldungen
    @Published var toast: String?
    @Published var alertMessage: String?
    private var toastTask: Task<Void, Never>?

    private(set) var lastLocation: CLLocation?
    private var hasCenteredOnFirstFix = false
    /** Richtung des Standort-Pfeils (und der Kamera in der Vektorkarte während der Navigation). */
    private var navBearing = 0.0
    private var lastReliableCourseAt = Date.distantPast
    private var lastDisplayPosition: LatLon?
    private var tracker: RouteProgressTracker?
    private var reroutingInProgress = false
    private var navigationStart = Date()
    /** Gefahrene Strecke der laufenden Navigation (Fahrtenbuch, GPX). */
    private var trackPoints: [TrackPoint] = []
    private var trackMaxKmh = 0.0
    /** Voraussichtliche Ankunft (aus dem HUD) und die zuletzt geteilte. */
    private var arrivalDate: Date?
    private var sharedArrival: Date?

    init(settings: AppSettings) {
        self.settings = settings
        Self.current = self
        is3DEnabled = settings.start3D
        map.onLongPress = { [weak self] point in self?.onMapLongPress(point) }
        map.onTap = { [weak self] tap in self?.onMapTap(tap) }
        map.onDirectionChange = { [weak self] direction in
            guard let self else { return }
            // Nur spürbare Änderungen veröffentlichen — sonst zeichnet SwiftUI bei jedem Frame neu.
            let delta = abs(direction - self.mapDirection).truncatingRemainder(dividingBy: 360)
            if min(delta, 360 - delta) >= 1 || (direction == 0) != (self.mapDirection == 0) {
                self.mapDirection = direction
            }
        }
        map.onUserGesture = { [weak self] in
            guard let self else { return }
            // Karte verschieben schließt Suchliste + Tastatur (wie bei Google/Apple Maps).
            if self.showSearchResults || self.searchFocused { self.dismissSearch() }
            if self.followEnabled { self.followEnabled = false }
        }
        location.onLocation = { [weak self] loc in
            Task { @MainActor in self?.onLocationUpdate(loc) }
        }
        location.onHeading = { [weak self] heading in
            Task { @MainActor in self?.onCompassHeading(heading) }
        }
    }

    func start() {
        location.start()
        // Ohne neue Fixes (Stillstand, z.B. an der Ampel) bliebe sonst die letzte Geschwindigkeit
        // stehen — nach 4 s ohne Fix gilt 0 km/h.
        speedWatchdog?.invalidate()
        speedWatchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.lastLocation != nil, Date().timeIntervalSince(self.lastFixAt) > 4 else { return }
                if self.speedKmh != 0 { self.speedKmh = 0 }
                if self.isSpeeding { self.isSpeeding = false }
                self.speedingSince = nil
            }
        }
    }

    var currentPosition: LatLon? { lastLocation.map { LatLon($0.coordinate) } }

    // MARK: - Meldungen

    func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if !Task.isCancelled { toast = nil }
        }
    }

    // MARK: - Suche

    private func onSearchTextChanged() {
        if suppressSearch { return }
        searchTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespaces)
        if query.count < 2 {
            searching = false
            showRecentSearchesIfEmpty()
            return
        }
        if let cached = searchCache[searchCacheKey(query)], Date().timeIntervalSince(cached.at) < 600 {
            searching = false
            searchResults = cached.results
            showSearchResults = !cached.results.isEmpty
            return
        }
        searching = true
        // Live-Vorschläge, gedrosselt (Nominatim: max. ~1 Anfrage/Sekunde).
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled { return }
            await performSearch(showErrors: false)
        }
    }

    /** Suchtext + Standort-Zelle von 0,05° (≈ 5 km). */
    private func searchCacheKey(_ query: String) -> String {
        let cell = currentPosition.map { "\(Int(($0.latitude / 0.05).rounded(.down))),\(Int(($0.longitude / 0.05).rounded(.down)))" } ?? "-"
        return "\(query.lowercased())|\(cell)"
    }

    func submitSearch() {
        searchTask?.cancel()
        searchTask = Task { await performSearch(showErrors: true) }
    }

    private func showRecentSearchesIfEmpty() {
        guard searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let recent = settings.recentSearchesEnabled ? RecentSearchesStore.list() : []
        searchResults = recent
        showSearchResults = !recent.isEmpty
    }

    private func performSearch(showErrors: Bool) async {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        let cacheKey = searchCacheKey(query)
        searching = true
        defer { if !Task.isCancelled { searching = false } }
        do {
            let result = try await SearchFetcher.search(query, near: currentPosition) { [weak self] partial in
                // Nominatim-Treffer sofort zeigen, die Marken-/POI-Suche kommt danach dazu.
                guard let self, !partial.isEmpty, self.isStillSearching(query, explicit: showErrors) else { return }
                self.searchResults = partial
                self.showSearchResults = true
                // Ergebnisse sind da — die Marken-Ergänzung läuft still im Hintergrund weiter.
                self.searching = false
            }
            if Task.isCancelled { return }
            if !result.usedOfflineSearch {
                if searchCache.count > 50 { searchCache.removeAll() }
                searchCache[cacheKey] = (result.results, Date())
            }
            // Die POI-Ergänzung kann Sekunden später kommen — eine inzwischen geschlossene Liste
            // (Karte angetippt, Ziel gewählt) darf sie nicht wieder aufmachen.
            guard isStillSearching(query, explicit: showErrors) else { return }
            searchResults = result.results
            showSearchResults = !result.results.isEmpty
            if result.results.isEmpty && showErrors { showToast("Keine Ergebnisse gefunden.") }
            if result.usedOfflineSearch { showToast("Treffer aus den Offline-Daten (heruntergeladene Kartenpakete).") }
        } catch {
            if Task.isCancelled { return }
            if showErrors { showToast("Suche fehlgeschlagen. Internetverbindung prüfen.") }
        }
    }

    func selectSearchResult(_ result: SearchResult) {
        RecentSearchesStore.add(result)
        addDestination(result.point, label: result.displayName)
        map.ease(center: result.point, zoom: 15)
        suppressSearch = true
        searchText = result.displayName
        suppressSearch = false
        dismissSearch()
    }

    /** Schließt Ergebnisliste UND Tastatur und bricht eine laufende Suche ab, damit späte
     *  Ergebnisse die Liste nicht wieder öffnen. */
    func dismissSearch() {
        searchTask?.cancel()
        searching = false
        showSearchResults = false
        searchFocused = false
        // Direkt über UIKit — der Umweg über @FocusState griff nicht immer.
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    /** Gehört eine (späte) Antwort noch zur aktuellen Suche und ist die Liste noch erwünscht? */
    private func isStillSearching(_ query: String, explicit: Bool) -> Bool {
        searchText.trimmingCharacters(in: .whitespaces) == query && (explicit || searchFocused || showSearchResults)
    }

    func clearSearch() {
        searchTask?.cancel()
        searching = false
        suppressSearch = true
        searchText = ""
        suppressSearch = false
        showSearchResults = false
    }

    func searchNearby(_ category: NearbyCategory) {
        guard let center = currentPosition else {
            showToast("Standort noch nicht verfügbar.")
            return
        }
        showToast("Suche in der Nähe …")
        Task {
            if category == .fuel, !settings.tankerkoenigKey.trimmingCharacters(in: .whitespaces).isEmpty,
               await showFuelPrices(center: center) {
                return
            }
            do {
                let places = try await OverpassClient.fetchNearby(center: center, radiusMeters: 15_000, tags: category.tags, fallbackName: category.label)
                let sorted = places.sorted {
                    GeoUtils.distanceMeters(center, LatLon($0.lat, $0.lon)) < GeoUtils.distanceMeters(center, LatLon($1.lat, $1.lon))
                }.prefix(30)
                if sorted.isEmpty {
                    showToast("Nichts in der Nähe gefunden.")
                    return
                }
                searchResults = sorted.map { place in
                    let distance = FormatUtils.formatDistance(GeoUtils.distanceMeters(center, LatLon(place.lat, place.lon)))
                    let name = place.locality.map { "\(place.name) (\($0))" } ?? place.name
                    let parts = [name, distance, place.openStatusText].compactMap { $0 }
                    return SearchResult(displayName: parts.joined(separator: " · "), lat: place.lat, lon: place.lon, boundingBox: nil)
                }
                showSearchResults = true
                toast = nil
            } catch AppError.offlineMode {
                showToast("„In der Nähe“ braucht Internet (Offline-Modus ist an).")
            } catch {
                showToast("Umkreissuche fehlgeschlagen.")
            }
        }
    }

    /**
     * Tankstellen mit aktuellem Preis (Tankerkönig, 10 km). false = ging nicht (Schlüssel falsch,
     * kein Netz) — dann sucht [searchNearby] wie ohne Schlüssel in OpenStreetMap.
     */
    private func showFuelPrices(center: LatLon) async -> Bool {
        do {
            let stations = try await TankerkoenigClient.stations(near: center, radiusKm: 10, fuel: settings.fuelType,
                                                                 sortByPrice: settings.fuelSortByPrice, apiKey: settings.tankerkoenigKey)
            guard !stations.isEmpty else { return false }
            // Bei „nach Preis“ liefert die API nur offene Tankstellen mit Preis; geschlossene ans Ende.
            let sorted = stations.filter { $0.price != nil } + stations.filter { $0.price == nil }
            searchResults = sorted.prefix(30).map { station in
                let name = station.place.map { "\(station.name) (\($0))" } ?? station.name
                let price = station.priceText.map { "\(settings.fuelType.label) \($0)" } ?? "geschlossen"
                let distance = FormatUtils.formatDistance(station.distanceKm * 1000)
                return SearchResult(displayName: "\(name) · \(distance) · \(price)", lat: station.lat, lon: station.lon, boundingBox: nil)
            }
            showSearchResults = true
            showToast(settings.tankerkoenigKey.trimmingCharacters(in: .whitespaces) == TankerkoenigClient.demoKey
                      ? "Demo-Schlüssel: Tankstellen echt, Preise nicht." : "Preise: Tankerkönig (MTS-K)")
            return true
        } catch AppError.server(let message) {
            showToast("Tankerkönig: \(message) — zeige Tankstellen ohne Preise.")
        } catch {
            showToast("Spritpreise nicht erreichbar — zeige Tankstellen ohne Preise.")
        }
        // Meldung kurz stehen lassen, bevor die OSM-Suche ihren eigenen Hinweis zeigt.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        return false
    }

    // MARK: - Ort-Infos (Tipp auf die Karte)

    /** Angetippter Ort fürs Detail-Blatt; [details] kommt asynchron per Overpass nach. */
    struct PoiSelection: Identifiable {
        let id = UUID()
        let name: String
        let point: LatLon
        var details: PoiDetails?
        var loading = true
        var failed = false
    }

    @Published var poiSelection: PoiSelection? {
        didSet { if poiSelection == nil { poiTask?.cancel(); map.setSelectedPoi(nil) } }
    }
    private var poiTask: Task<Void, Never>?

    private func onMapTap(_ tap: MapTap) {
        guard !navigationActive, !pickingFavoriteLocation else { return }
        // Erster Tipp schließt nur Suchliste/Tastatur.
        if showSearchResults || searchFocused {
            dismissSearch()
            return
        }
        guard settings.poiTapEnabled else { return }
        if let name = tap.poiName, let point = tap.poiPoint {
            poiSelection = PoiSelection(name: name, point: point)
            loadPoiDetails()
        } else if !tap.hasPoiSymbols {
            // Karte ohne POI-Symbole: nächsten benannten Ort suchen, Blatt erst bei Treffer öffnen.
            poiTask?.cancel()
            poiTask = Task {
                do {
                    guard let details = try await PoiDetailsClient.fetchNearest(tap.point, radiusMeters: tap.radiusMeters) else {
                        if !Task.isCancelled { showToast("Hier ist kein Ort mit Namen eingetragen.") }
                        return
                    }
                    if Task.isCancelled { return }
                    var selection = PoiSelection(name: details.name, point: details.point)
                    selection.details = details
                    selection.loading = false
                    poiSelection = selection
                    map.setSelectedPoi(details.point)
                } catch {
                    if !Task.isCancelled {
                        showToast(NetworkPolicy.fullyOffline ? "Ort-Infos brauchen Internet (Offline-Modus ist an)." : "Ort-Infos konnten nicht geladen werden.")
                    }
                }
            }
        }
    }

    /** Lädt die Details zum aktuell gewählten Ort (auch für „Erneut versuchen“). */
    func loadPoiDetails() {
        guard var selection = poiSelection else { return }
        map.setSelectedPoi(selection.point)
        selection.loading = true
        selection.failed = false
        poiSelection = selection
        let id = selection.id
        poiTask?.cancel()
        poiTask = Task {
            let details: PoiDetails?
            let failed: Bool
            do {
                details = try await PoiDetailsClient.fetch(name: selection.name, near: selection.point)
                failed = false
            } catch {
                details = nil
                failed = true
            }
            guard !Task.isCancelled, poiSelection?.id == id else { return }
            poiSelection?.details = details
            poiSelection?.loading = false
            poiSelection?.failed = failed
        }
    }

    func routeToPoi(_ selection: PoiSelection) {
        let label = selection.details?.address.map { "\(selection.name), \($0)" } ?? selection.name
        let point = selection.details?.point ?? selection.point
        poiSelection = nil
        addDestination(point, label: label)
        calculateRoute()
    }

    func savePoiAsFavorite(_ selection: PoiSelection) {
        let point = selection.details?.point ?? selection.point
        poiSelection = nil
        // Zweites Blatt erst öffnen, wenn das Detail-Blatt zu ist (sonst zeigt SwiftUI es nicht).
        Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            pendingFavorite = PendingFavorite(name: selection.name, point: point)
        }
    }

    // MARK: - Ziele

    private func onMapLongPress(_ point: LatLon) {
        if pickingFavoriteLocation {
            pickingFavoriteLocation = false
            pendingFavorite = PendingFavorite(name: Self.defaultLabel(point), point: point)
        } else {
            addDestination(point)
        }
    }

    static func defaultLabel(_ point: LatLon) -> String {
        String(format: "Kartenpunkt (%.4f, %.4f)", point.latitude, point.longitude)
    }

    func addDestination(_ point: LatLon, label: String? = nil) {
        waypoints.append(Waypoint(point: point, label: label ?? Self.defaultLabel(point)))
        // Ziel wurde bewusst gewählt — Nachführen soll nicht zur eigenen Position zurückspringen.
        followEnabled = false
        waypointsChanged()
    }

    func removeWaypoints(at offsets: IndexSet) {
        waypoints.remove(atOffsets: offsets)
        waypointsChanged()
    }

    func moveWaypoints(from source: IndexSet, to destination: Int) {
        waypoints.move(fromOffsets: source, toOffset: destination)
        waypointsChanged()
    }

    func clearDestinations() {
        waypoints.removeAll()
        waypointsChanged()
    }

    private func waypointsChanged() {
        // Selbst geänderte Ziele beenden eine GPX-Tour.
        if activeTour != nil { endTour() }
        map.setDestinations(waypoints.map(\.point))
        if navigationActive { stopNavigation() }
        resetRoute()
    }

    /** Ziele, die die Karte markiert (bei einer Tour: Halt + Tourende). */
    private func refreshDestinationMarkers() {
        map.setDestinations((tourStop.map { [$0.point] } ?? []) + waypoints.map(\.point))
    }

    private func resetRoute() {
        lastRoute = nil
        elevationProfile = nil
        routeWeather = nil
        waypointOffset = 0
        routeOptions = []
        selectedRouteIndex = 0
        instructions = []
        showInstructions = false
        map.setRoutes([], selected: 0)
    }

    // MARK: - Route

    /** [startNavigationAfter] = gleich losnavigieren (Widget/Siri „Nach Hause“). */
    func calculateRoute(startNavigationAfter: Bool = false) {
        guard !waypoints.isEmpty else {
            showToast("Bitte zuerst ein Ziel wählen.")
            return
        }
        guard let start = currentPosition else {
            showToast("Standort noch nicht verfügbar.")
            return
        }
        if navigationActive { stopNavigation() }
        waypointOffset = 0
        let request = routeRequest(from: start)
        // OSRM liefert Alternativrouten nur bei genau Start + Ziel (kein Zwischenstopp, keine Tour).
        let alternatives = request.points.count == 2 && activeTour == nil && settings.alternativeRoutes
        routeLoading = true
        Task {
            defer { routeLoading = false }
            do {
                let result = try await RouteFetcher.getRoutes(request.points, alternatives: alternatives, profile: settings.routingProfile)
                routeOptions = result.routes.map(request.finish)
                selectRoute(0)
                fitRouteInView(routeOptions[0])
                if result.usedOfflineRouting { showToast("Offline-Route berechnet.") }
                if startNavigationAfter { startNavigation() }
            } catch let error as OfflineRoutingError {
                alertMessage = "Keine Internetverbindung – und offline ging es auch nicht:\n\(error.localizedDescription)"
            } catch {
                alertMessage = RouteFetcher.isConnectivityError(error)
                    ? "Route konnte nicht berechnet werden. Internetverbindung prüfen oder unter „Offline-Karten“ ein Paket für dieses Gebiet herunterladen."
                    : "Keine Route gefunden. Ist das Ziel mit „\(settings.routingProfile.label)“ erreichbar?"
            }
        }
    }

    func selectRoute(_ index: Int) {
        guard routeOptions.indices.contains(index) else { return }
        selectedRouteIndex = index
        let route = routeOptions[index]
        lastRoute = route
        map.setRoutes(routeOptions.map(\.geometry), selected: index)
        instructions = RouteProgressTracker.previewInstructions(route)
        updateElevationProfile(route)
        updateRouteWeather(route)
    }

    /**
     * Routenpunkte für den aktuellen Zustand + Nachbearbeitung der Antwort:
     *  - normal: Start + noch offene Ziele (ab [waypointOffset]);
     *  - GPX-Tour: Start + ggf. eingefügter Halt + restliche Durchgangspunkte; die Etappen zwischen
     *    Durchgangspunkten werden zusammengefasst (keine Ankunft an jedem Punkt), der Halt behält seine.
     */
    private func routeRequest(from start: LatLon) -> (points: [LatLon], finish: (OsrmRoute) -> OsrmRoute) {
        guard let tour = activeTour else {
            return ([start] + waypoints.map(\.point).dropFirst(waypointOffset), { $0 })
        }
        let vias = Array(tour.vias.dropFirst(min(tourProgress, tour.vias.count - 1)))
        let stop = tourStop.map { [$0.point] } ?? []
        let keep: Set<Int> = tourStop == nil ? [] : [0]
        return ([start] + stop + vias, { Tour.mergeViaLegs($0, keepArrivalAfter: keep) })
    }

    /** Wetter zur voraussichtlichen Durchfahrtszeit — eine späte Antwort für eine verworfene Route zählt nicht. */
    private func updateRouteWeather(_ route: OsrmRoute) {
        routeWeather = nil
        guard settings.routeWeather else { return }
        Task {
            guard let weather = try? await WeatherClient.forecast(along: route.geometry, durationSeconds: route.duration),
                  lastRoute == route else { return }
            routeWeather = weather
        }
    }

    private func fitRouteInView(_ route: OsrmRoute) {
        guard let mapView = map.mapView, !route.geometry.isEmpty else { return }
        var coords = route.geometry.map(\.coordinate)
        let camera = mapView.cameraThatFitsShape(
            MLNPolyline(coordinates: &coords, count: UInt(coords.count)),
            direction: 0,
            edgePadding: UIEdgeInsets(top: 160, left: 50, bottom: 320, right: 50)
        )
        mapView.setCamera(camera, animated: true)
    }

    /** Grobes Höhenprofil (Open-Elevation) — eine verspätete Antwort für eine bereits
     *  verworfene Route wird ignoriert. */
    private func updateElevationProfile(_ route: OsrmRoute) {
        elevationProfile = nil
        guard settings.routePreviewEnabled else { return }
        let samples = ElevationProfileBuilder.samplePoints(route.geometry)
        Task {
            guard let elevations = try? await ElevationClient.fetchElevations(samples.map(\.0)),
                  elevations.count == samples.count,
                  lastRoute == route else { return }
            elevationProfile = ElevationProfileBuilder.build(samples, elevations)
        }
    }

    // MARK: - Navigation

    func startNavigation() {
        guard let route = lastRoute else {
            showToast("Bitte zuerst eine Route berechnen.")
            return
        }
        let newTracker = RouteProgressTracker(route: route)
        tracker = newTracker
        navigationActive = true
        navigationStart = Date()
        trackPoints = []
        trackMaxKmh = 0
        followEnabled = true
        showSearchResults = false
        // Display während der Navigation anlassen + Standort im Hintergrund weiterlaufen lassen.
        UIApplication.shared.isIdleTimerDisabled = settings.keepScreenOn
        location.setNavigating(true)
        map.setPuckLow(settings.navPuckLow)

        announcer.reset()
        say(newTracker.currentInstruction(), interrupt: true)
        loadSpeedLimits(route)
        if let loc = lastLocation {
            var current = LatLon(loc.coordinate)
            // Richtung sofort aus der Route nehmen — im Stand gibt es keinen GPS-Kurs, die Kamera
            // stand sonst beim Start nach Norden statt in Fahrtrichtung.
            if let snap = newTracker.snapWithBearing(current) {
                current = snap.point
                navBearing = snap.bearing
                map.updatePuck(current, heading: navBearing)
            }
            updateHud(current, newTracker)
            map.ease(center: current, zoom: navZoom(loc.speed), pitch: currentTilt(), heading: cameraHeading())
        }
        if settings.liveActivityEnabled {
            liveActivity.start(destination: waypoints.last.map { $0.label.components(separatedBy: ",").first ?? $0.label } ?? "Ziel",
                               backgroundHex: settings.resolvedHudBackgroundHex,
                               textHex: settings.hudTextHex ?? HexColor.contrastText(on: settings.resolvedHudBackgroundHex),
                               state: liveActivityState())
        }
    }

    /** Zustand fürs Navigations-Widget: HUD-Texte + schematische Route um die Position (Fahrtrichtung oben). */
    private func navWidgetState(_ current: LatLon, _ tracker: RouteProgressTracker, displayed: NavStep) -> NavWidgetState {
        // „Danach“: das Manöver nach dem gerade angezeigten.
        let shownIsNext = displayed.maneuverPoint == tracker.nextManeuver().maneuverPoint
        let then = tracker.maneuver(after: shownIsNext ? 2 : 1)
        let route = NavWidgetPublisher.localMeters(tracker.geometryAround(current), origin: current, heading: navBearing)
        let maneuver = NavWidgetPublisher.localMeters([displayed.maneuverPoint], origin: current, heading: navBearing).first
        let background = settings.resolvedHudBackgroundHex
        return NavWidgetState(
            active: true,
            distanceText: hud.distanceText,
            instruction: hud.instruction,
            symbolName: hud.icon.symbolName,
            symbolRotation: hud.icon.rotationDegrees,
            thenInstruction: then.flatMap { $0.maneuverType == "arrive" ? "Ziel erreichen" : $0.instruction },
            etaText: hud.etaText,
            remainingText: hud.summaryText,
            destination: waypoints.last.map { $0.label.components(separatedBy: ",").first ?? $0.label } ?? "Ziel",
            updatedAt: Date(),
            backgroundHex: Int(background),
            textHex: Int(settings.hudTextHex ?? HexColor.contrastText(on: background)),
            routeHex: Int(settings.routeHex),
            route: route,
            maneuver: maneuver
        )
    }

    /** Anzeige für Sperrbildschirm/Dynamic Island — dieselben Texte wie das HUD. */
    private func liveActivityState() -> NavActivityAttributes.ContentState {
        let instruction = hud.instruction.isEmpty ? (tracker?.currentInstruction() ?? "") : hud.instruction
        return NavActivityAttributes.ContentState(
            distanceText: hud.distanceText,
            instruction: instruction,
            symbolName: hud.icon.symbolName,
            symbolRotation: hud.icon.rotationDegrees,
            etaText: hud.etaText,
            remainingText: hud.summaryText,
            arrived: false
        )
    }

    /** [arrived] = am Ziel angekommen (Sperrbildschirm zeigt dann noch kurz „Angekommen“). */
    func stopNavigation(arrived: Bool = false) {
        liveActivity.end(arrived: arrived)
        navWidget.clear()
        navigationActive = false
        arrivalDate = nil
        sharedArrival = nil
        etaShiftedTo = nil
        tracker = nil
        northUpNavigation = false
        speedLimitTask?.cancel()
        speedLimits.replace([])
        speedLimit = nil
        isSpeeding = false
        UIApplication.shared.isIdleTimerDisabled = false
        location.setNavigating(false)
        map.setPuckLow(false)
        map.ease(pitch: currentTilt(), heading: 0)
    }

    private func logCompletedTrip() {
        guard let route = lastRoute, let destination = waypoints.last?.label else { return }
        let duration = Date().timeIntervalSince(navigationStart)
        var trip = Trip(
            id: UUID().uuidString,
            destinationName: destination,
            distanceMeters: route.distance,
            durationSeconds: duration,
            timestamp: Date()
        )
        if settings.recordTracks, trackPoints.count >= 2 {
            let driven = zip(trackPoints, trackPoints.dropFirst()).reduce(0) { $0 + GeoUtils.distanceMeters($1.0.point, $1.1.point) }
            trip.drivenMeters = driven
            trip.averageKmh = duration > 0 ? driven / duration * 3.6 : nil
            trip.maxKmh = trackMaxKmh
            trip.hasTrack = true
            TripTrackStore.save(tripId: trip.id, points: trackPoints)
        }
        TripHistoryStore.add(trip)
    }

    /** Tour: erreichte Durchgangspunkte abhaken; Halt erreicht (zweite Etappe begonnen) → vergessen. */
    private func updateTourProgress(_ position: LatLon, _ tracker: RouteProgressTracker) {
        guard let tour = activeTour else { return }
        while tourProgress < tour.vias.count - 1, GeoUtils.distanceMeters(position, tour.vias[tourProgress]) < 80 {
            tourProgress += 1
        }
        if tourStop != nil, tracker.currentLegIndex() > 0 {
            tourStop = nil
            refreshDestinationMarkers()
        }
    }

    /** Streckenpunkt für das Fahrtenbuch: nur genaue Fixes, frühestens alle 10 m. */
    private func recordTrackPoint(_ loc: CLLocation) {
        guard settings.recordTracks, loc.horizontalAccuracy >= 0, loc.horizontalAccuracy < 50 else { return }
        let kmh = loc.speed >= 0 ? loc.speed * 3.6 : nil
        // Höchstgeschwindigkeit nur aus gemessener Geschwindigkeit (GPS-Sprünge würden sonst Spitzen erzeugen).
        if let kmh, loc.speedAccuracy >= 0, loc.speedAccuracy < 3 { trackMaxKmh = max(trackMaxKmh, kmh) }
        let point = TrackPoint(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude,
                               time: loc.timestamp.timeIntervalSince1970, kmh: kmh)
        if let last = trackPoints.last, GeoUtils.distanceMeters(last.point, point.point) < 10 { return }
        trackPoints.append(point)
    }

    private func onLocationUpdate(_ loc: CLLocation) {
        lastLocation = loc
        let raw = LatLon(loc.coordinate)

        // "Auf die Straße setzen": während der Navigation auf die Route projizieren, sonst über
        // OSRMs nearest-Dienst. Für Re-Routing bleibt die rohe Position maßgeblich.
        let display: LatLon
        if navigationActive, let snap = tracker?.snapWithBearing(raw) {
            // Auf der Route: Position aus der Route, Richtung aus der Route (Straßenrichtung voraus,
            // weich in Kurven, stimmt auch im Stand) — AUSSER man fährt erkennbar anders als die Route
            // (Wenden, Gegenrichtung beim Start, andere Fahrbahn): dann hat die echte Fahrtrichtung
            // Vorrang, sonst zeigte die Ansicht entgegen der Fahrtrichtung (Nutzermeldung).
            display = snap.point
            if BearingFilter.isReliable(loc), Self.angleDifference(loc.course, snap.bearing) > 60 {
                navBearing = loc.course
            } else {
                navBearing = snap.bearing
            }
            if BearingFilter.isReliable(loc) { lastReliableCourseAt = Date() }
        } else {
            display = navigationActive || !settings.snapToRoad ? raw : roadSnapper.snap(raw)
            if BearingFilter.isReliable(loc) {
                navBearing = loc.course
                lastReliableCourseAt = Date()
            } else if !navigationActive, settings.compassWhenIdle, Date().timeIntervalSince(lastReliableCourseAt) > 3,
                      let compass = location.compassHeading {
                // Freier Modus im Stand: Telefonausrichtung (während der Navigation nie, siehe CLAUDE.md).
                navBearing = compass
            }
        }
        lastDisplayPosition = display
        // Der Pfeil zeigt in BEIDEN Karten die echte Richtung — nur die Kamera bleibt in der
        // OSM-Karte genordet (cameraHeading()).
        map.smoothPuck = settings.smoothPuck
        map.updatePuck(display, heading: navBearing)

        if !hasCenteredOnFirstFix {
            hasCenteredOnFirstFix = true
            map.ease(center: display, zoom: 16, pitch: currentTilt(), duration: 0)
        }
        if pendingAutoNavigation {
            pendingAutoNavigation = false
            calculateRoute(startNavigationAfter: true)
        }

        guard navigationActive, let tracker else {
            // Freier Modus: nur die eigene Geschwindigkeit (ohne Route gibt es keine Tempolimits).
            updateCurrentSpeed(loc)
            if followEnabled { map.followPuck(pitch: currentTilt()) }
            return
        }

        recordTrackPoint(loc)
        updateTourProgress(display, tracker)
        announcer.chainEnabled = settings.chainAnnouncements
        if tracker.advanceIfNeeded(display) {
            if let text = announcer.maneuverReached(tracker) { say(text) }
        }
        updateHud(display, tracker)
        updateSpeed(display, loc)
        if !reroutingInProgress, settings.preAnnouncements,
           let text = announcer.preAnnouncement(tracker, distanceToNext: tracker.distanceToNextManeuver(display), speedMps: max(loc.speed, 0)) {
            say(text)
        }

        if tracker.isFinished && tracker.distanceToNextManeuver(display) < 15 {
            say("Sie haben Ihr Ziel erreicht.")
            logCompletedTrip()
            stopNavigation(arrived: true)
            return
        }

        if settings.autoReroute && !reroutingInProgress && tracker.distanceFromRoute(raw) > Self.rerouteThresholdMeters {
            reroute(from: raw, legIndex: tracker.currentLegIndex())
        }

        if followEnabled {
            map.followPuck(zoom: navZoom(loc.speed), pitch: currentTilt(), heading: cameraHeading())
        }
    }

    // MARK: - Tempolimit

    private func loadSpeedLimits(_ route: OsrmRoute) {
        speedLimitTask?.cancel()
        speedLimits.replace([])
        speedLimit = nil
        guard !route.nodeLegs.isEmpty else { return }
        let routeId = route.id
        speedLimitTask = Task {
            await SpeedLimitMap.load(nodeLegs: route.nodeLegs) { [weak self] segments in
                guard let self, self.navigationActive, self.lastRoute?.id == routeId else { return }
                self.speedLimits.replace(segments)
            }
        }
    }

    /**
     * Geschwindigkeit in km/h: `CLLocation.speed`, falls gültig — iOS meldet oft -1 (Stand,
     * schwaches GPS, Gebäude). Dann aus Strecke/Zeit seit dem letzten Fix berechnen; bei kurzen
     * Aussetzern bleibt der letzte Wert bis zu 5 s stehen, danach 0 (Anzeige verschwindet nie).
     */
    private func updateCurrentSpeed(_ loc: CLLocation) {
        defer {
            previousFix = loc
            lastFixAt = Date()
        }
        var mps: Double?
        if loc.speed >= 0 {
            mps = loc.speed
        } else if let prev = previousFix, loc.horizontalAccuracy >= 0, loc.horizontalAccuracy < 50,
                  prev.horizontalAccuracy >= 0, prev.horizontalAccuracy < 50 {
            let dt = loc.timestamp.timeIntervalSince(prev.timestamp)
            if dt >= 0.5 && dt <= 10 { mps = loc.distance(from: prev) / dt }
        }
        if let mps {
            speedKmh = Int((mps * 3.6).rounded())
            lastSpeedAt = Date()
        } else if speedKmh == nil || Date().timeIntervalSince(lastSpeedAt) > 5 {
            // Keine verwertbare Messung — meist Stillstand oder drinnen: 0 statt ausblenden.
            speedKmh = 0
        }
    }

    private func updateSpeed(_ position: LatLon, _ loc: CLLocation) {
        updateCurrentSpeed(loc)
        speedLimit = speedLimits.limit(at: position)
        // Kleine Toleranz: GPS misst die echte Geschwindigkeit, Tachos zeigen eher etwas mehr an.
        let over: Bool
        if let limit = speedLimit?.kmhValue, let kmh = speedKmh {
            over = kmh > limit + settings.speedTolerance
        } else {
            over = false
        }
        isSpeeding = over
        guard over, let limit = speedLimit?.kmhValue else {
            speedingSince = nil
            return
        }
        let now = Date()
        if speedingSince == nil { speedingSince = now }
        // Erst nach 3 s Überschreitung warnen; dasselbe Limit höchstens alle 2 Minuten.
        guard settings.showSpeedLimit, settings.speedWarning,
              now.timeIntervalSince(speedingSince!) >= 3 else { return }
        if let last = lastSpeedWarning, last.limit == limit, now.timeIntervalSince(last.at) < 120 { return }
        lastSpeedWarning = (limit, now)
        say("Achtung, Tempolimit \(limit).")
    }

    /** Kompass dreht den Pfeil nur im freien Modus und nur, wenn gerade kein GPS-Kurs vorliegt. */
    private func onCompassHeading(_ heading: Double) {
        guard !navigationActive, settings.compassWhenIdle, Date().timeIntervalSince(lastReliableCourseAt) > 3,
              let position = lastDisplayPosition else { return }
        navBearing = heading
        map.updatePuck(position, heading: heading)
    }

    /**
     * Neue Route ab der aktuellen Position zu den noch nicht erreichten Zielen. [legIndex] = Etappe
     * der bisherigen Route, in der man gerade ist (alles davor gilt als erreicht).
     */
    private func reroute(from current: LatLon, legIndex: Int, announce: Bool = true) {
        if activeTour == nil {
            waypointOffset = min(waypointOffset + legIndex, max(waypoints.count - 1, 0))
        } else if legIndex > 0 {
            tourStop = nil // Halt schon erreicht
        }
        let request = routeRequest(from: current)
        guard request.points.count >= 2 else { return }
        reroutingInProgress = true
        if announce { say("Route wird neu berechnet.", interrupt: true) }
        Task {
            defer { reroutingInProgress = false }
            do {
                let result = try await RouteFetcher.getRoutes(request.points, alternatives: false, profile: settings.routingProfile)
                guard navigationActive, let raw = result.routes.first else { return }
                let route = request.finish(raw)
                lastRoute = route
                routeOptions = [route]
                selectedRouteIndex = 0
                map.setRoutes([route.geometry], selected: 0)
                let newTracker = RouteProgressTracker(route: route)
                tracker = newTracker
                instructions = RouteProgressTracker.previewInstructions(route)
                announcer.reset()
                say(newTracker.currentInstruction())
                loadSpeedLimits(route)
            } catch {
                showToast("Neuberechnung fehlgeschlagen.")
            }
        }
    }

    private func updateHud(_ current: LatLon, _ tracker: RouteProgressTracker) {
        let remainingDistance = tracker.remainingDistance(current)
        let remainingDuration = tracker.remainingDuration(current)
        // Das gerade angesagte Manöver bleibt sichtbar, bis man es durchfahren hat.
        let (next, distanceToNext) = tracker.displayedManeuver(current)
        let arrival = Date().addingTimeInterval(remainingDuration)
        arrivalDate = arrival
        if settings.etaSharePrompt, let shared = sharedArrival, abs(arrival.timeIntervalSince(shared)) > 5 * 60 {
            let text = FormatUtils.formatEta(remainingDuration)
            if etaShiftedTo != text { etaShiftedTo = text }
        }
        hud = NavHudState(
            distanceText: FormatUtils.formatDistance(distanceToNext),
            instruction: next.instruction,
            icon: ManeuverIconResolver.resolve(type: next.maneuverType, modifier: next.maneuverModifier),
            etaText: FormatUtils.formatEta(remainingDuration),
            summaryText: "\(FormatUtils.formatDistance(remainingDistance)) · \(FormatUtils.formatDuration(remainingDuration))",
            // Spurempfehlung erst kurz vor der Abzweigung (wie Google Maps).
            lanes: settings.laneGuidance && distanceToNext <= 400 ? (next.lanes ?? []) : [],
            roadName: settings.showRoadName ? tracker.currentRoadName(current) : nil
        )
        if navigationActive {
            liveActivity.update(liveActivityState())
            if settings.navWidgetEnabled { navWidget.publish(navWidgetState(current, tracker, displayed: next)) }
        }
    }

    // MARK: - Ankunftszeit teilen

    /** „Ich bin voraussichtlich um 17:42 in … (noch 12 km).“ + Kartenlink zum Ziel. */
    private func etaShareText() -> String? {
        guard navigationActive, let arrival = arrivalDate, let destination = waypoints.last else { return nil }
        let time = arrival.formatted(date: .omitted, time: .shortened)
        let name = destination.label.components(separatedBy: ",").first ?? destination.label
        let rest = hud.summaryText.components(separatedBy: " · ").first.map { " (noch \($0))" } ?? ""
        let p = destination.point
        let link = String(format: "https://www.openstreetmap.org/?mlat=%.5f&mlon=%.5f#map=17/%.5f/%.5f", p.latitude, p.longitude, p.latitude, p.longitude)
        return "Ich bin voraussichtlich um \(time) in \(name)\(rest).\n\(link)"
    }

    /** Teilen-Menü; nur wenn wirklich geteilt wurde, gilt die Zeit als „geteilt“ (für den Verschiebe-Hinweis). */
    func shareEta() {
        guard let text = etaShareText() else { return }
        let arrival = arrivalDate
        ShareSheet.present(items: [text]) { [weak self] completed in
            guard let self, completed else { return }
            self.sharedArrival = arrival
            self.etaShiftedTo = nil
        }
    }

    func dismissEtaShift() {
        // Hinweis weg; erst bei weiteren 5 Minuten Verschiebung (ab jetzt) wieder.
        sharedArrival = arrivalDate
        etaShiftedTo = nil
    }

    // MARK: - Sprachausgabe

    private func say(_ text: String, interrupt: Bool = false, force: Bool = false) {
        guard settings.voiceEnabled || force else { return }
        speech.speak(
            text,
            voiceIdentifier: settings.voiceIdentifier.isEmpty ? nil : settings.voiceIdentifier,
            rate: settings.speechRate,
            volume: settings.speechVolume * (force ? 1 : speedVolumeFactor),
            duckOthers: settings.duckMusic,
            interrupt: interrupt
        )
    }

    /**
     * Lautstärke nach Tempo (nur Navigation): Apps können die Systemlautstärke nicht anheben —
     * deshalb unter 30 km/h 75 % der eingestellten Lautstärke, ab 100 km/h 100 %, dazwischen gleitend.
     */
    private var speedVolumeFactor: Float {
        guard settings.speedAdaptiveVolume, navigationActive, let kmh = speedKmh else { return 1 }
        return Self.speedVolumeFactor(kmh: kmh)
    }

    static func speedVolumeFactor(kmh: Int) -> Float {
        let t = min(max((Float(kmh) - 30) / 70, 0), 1)
        return 0.75 + 0.25 * t
    }

    /** Hörprobe für die Einstellungen (auch wenn Ansagen aus sind). */
    func previewVoice() {
        say("In 300 Metern rechts abbiegen auf Hauptstraße. Danach links halten.", interrupt: true, force: true)
    }

    /** Kleinster Winkel zwischen zwei Richtungen (0…180°). */
    private static func angleDifference(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(d, 360 - d)
    }

    /** Zoomstufe während der Navigation: nach Tempo oder fest. */
    private func navZoom(_ speedMps: Double) -> Double {
        settings.autoZoom ? NavZoom.forSpeed(speedMps) : 17
    }

    // MARK: - Kamera

    func recenter() {
        followEnabled = true
        guard let loc = lastLocation else { return }
        let center = tracker?.snapToRoute(LatLon(loc.coordinate)) ?? LatLon(loc.coordinate)
        if navigationActive {
            map.ease(center: center, zoom: navZoom(loc.speed), pitch: currentTilt(), heading: cameraHeading(), duration: 0.8)
        } else {
            map.ease(center: center, pitch: currentTilt(), duration: 0.8)
        }
    }

    func toggle3D() {
        is3DEnabled.toggle()
        map.ease(pitch: currentTilt(), duration: 0.4)
    }

    /** Kamera dreht nur in der Vektorkarte mit der Fahrtrichtung; die klassische OSM-Karte bleibt
     *  nordausgerichtet (wie osmdroid auf Android) — dort zeigt nur der Pfeil die Richtung. */
    private func cameraHeading() -> Double {
        mapRotatable && !northUpNavigation ? navBearing : 0
    }

    /** Vektorkarte immer drehbar, die OSM-Karte nur mit Einstellung „Karte drehbar“. */
    var mapRotatable: Bool {
        settings.mapEngine.supports3D || settings.osmRotatable
    }

    /** Kompass-Knopf: frei = Karte nach Norden drehen; Navigation = „Norden oben“ umschalten. */
    func compassTapped() {
        if navigationActive {
            northUpNavigation.toggle()
            showToast(northUpNavigation ? "Norden oben" : "In Fahrtrichtung")
            map.ease(heading: cameraHeading(), duration: 0.5)
        } else {
            map.ease(heading: 0, duration: 0.5)
        }
    }

    private func currentTilt() -> Double {
        if !is3DEnabled || !settings.mapEngine.supports3D { return 0 }
        return navigationActive ? Self.navTilt : Self.idle3DTilt
    }

    // MARK: - Favoriten

    struct PendingFavorite: Identifiable {
        let id = UUID()
        var name: String
        let point: LatLon
    }

    @Published var pendingFavorite: PendingFavorite?

    func saveCurrentPositionAsFavorite() {
        guard let pos = currentPosition else {
            showToast("Standort noch nicht verfügbar.")
            return
        }
        pendingFavorite = PendingFavorite(name: "Mein Standort", point: pos)
    }

    func saveSearchResultAsFavorite(_ result: SearchResult) {
        pendingFavorite = PendingFavorite(name: result.displayName, point: result.point)
    }

    func confirmFavorite(name: String, point: LatLon, asHome: Bool) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let finalName = trimmed.isEmpty ? Self.defaultLabel(point) : trimmed
        if asHome {
            FavoritesStore.setHome(name: finalName, point: point)
        } else {
            FavoritesStore.add(name: finalName, point: point)
        }
        showToast(asHome ? "Als Zuhause gespeichert." : "Favorit gespeichert.")
    }

    // MARK: - Auf der Route suchen

    /** „Auf der Route suchen“ öffnen (aus Routen-Panel und Navi-Leiste). */
    func openAlongRoute() {
        guard lastRoute != nil else { return }
        requestedSheet = .some(.alongRoute)
    }

    func openWeather() { requestedSheet = .some(.weather) }

    /** Für das Wetter-Blatt: Strecke, die noch vor einem liegt, + Fahrzeit dafür; nil = keine Route. */
    func weatherRoute() -> (line: [LatLon], duration: Double)? {
        if navigationActive, let tracker, let position = lastDisplayPosition {
            let remaining = tracker.remainingDistance(position)
            return (tracker.geometryAround(position, behindMeters: 0, aheadMeters: remaining + 50), tracker.remainingDuration(position))
        }
        guard let route = lastRoute else { return nil }
        return (route.geometry, route.duration)
    }

    /** Strecke, die noch vor einem liegt (Navigation: ab Position, sonst ab Routenstart), höchstens [meters]. */
    func routeAhead(meters: Double) -> [LatLon] {
        if navigationActive, let tracker, let position = lastDisplayPosition {
            return tracker.geometryAround(position, behindMeters: 0, aheadMeters: meters)
        }
        guard let route = lastRoute, let start = route.geometry.first else { return [] }
        return RouteProgressTracker(route: route).geometryAround(start, behindMeters: 0, aheadMeters: meters)
    }

    func searchAlongRoute(_ category: AlongRouteCategory) async throws -> [AlongRoutePlace] {
        let line = routeAhead(meters: Double(settings.alongRouteKm) * 1000)
        guard line.count >= 2 else { return [] }
        let key = settings.tankerkoenigKey.trimmingCharacters(in: .whitespaces)
        return try await AlongRouteSearch.search(category, ahead: line, corridorMeters: Double(settings.alongRouteCorridor),
                                                 fuel: key.isEmpty ? nil : (key, settings.fuelType))
    }

    /** Ort von „Auf der Route“ als nächsten Halt in der passenden Etappe einfügen und neu berechnen. */
    func addStopOnRoute(_ place: AlongRoutePlace) {
        let stop = Waypoint(point: place.point, label: place.name)
        if activeTour != nil {
            tourStop = stop
            refreshDestinationMarkers()
            if navigationActive, let raw = lastLocation.map({ LatLon($0.coordinate) }) {
                reroute(from: raw, legIndex: 0, announce: false)
                say("Zwischenstopp \(place.name) hinzugefügt.", interrupt: true)
            } else {
                calculateRoute()
            }
        } else if navigationActive, let tracker, let position = lastDisplayPosition,
                  let raw = lastLocation.map({ LatLon($0.coordinate) }) {
            // In die Etappe einfügen, in der der Ort liegt (könnte hinter dem nächsten Ziel sein).
            let leg = tracker.legIndex(aheadMeters: place.alongMeters, from: position)
            waypoints.insert(stop, at: min(waypointOffset + leg, waypoints.count - 1))
            refreshDestinationMarkers()
            reroute(from: raw, legIndex: tracker.currentLegIndex(), announce: false)
            say("Zwischenstopp \(place.name) hinzugefügt.", interrupt: true)
        } else {
            let leg = lastRoute.flatMap { route in route.geometry.first.map { RouteProgressTracker(route: route).legIndex(aheadMeters: place.alongMeters, from: $0) } } ?? 0
            var updated = waypoints
            updated.insert(stop, at: min(leg, max(updated.count - 1, 0)))
            waypoints = updated
            waypointsChanged()
            calculateRoute()
        }
        showToast("„\(place.name)“ als Zwischenstopp eingefügt.")
    }

    // MARK: - GPX-Touren & gespeicherte Routen

    /** Tour laden: Spur auf die Karte, Route zum Tourstart und durch die Tour berechnen. */
    func startTour(_ tour: Tour) {
        if navigationActive { stopNavigation() }
        clearSearch()
        activeTour = tour
        tourProgress = 0
        tourStop = nil
        waypoints = [Waypoint(point: tour.vias.last ?? tour.track.last!, label: tour.name)]
        refreshDestinationMarkers()
        map.setTourTrack(settings.showTourTrack ? tour.track : [])
        resetRoute()
        followEnabled = false
        calculateRoute()
    }

    private func endTour() {
        activeTour = nil
        tourStop = nil
        tourProgress = 0
        map.setTourTrack([])
    }

    /** GPX-Datei einlesen, als gespeicherte Tour ablegen und sofort laden. */
    func importGPX(_ data: Data, fileName: String) -> Bool {
        let fallback = (fileName as NSString).deletingPathExtension
        guard let tour = GPXReader.read(data, fallbackName: fallback.isEmpty ? "GPX-Tour" : fallback) else { return false }
        TourStore.save(tour)
        SavedRoutesStore.add(SavedRoute(id: UUID().uuidString, name: tour.name, stops: [], profile: settings.routingProfile.rawValue,
                                        tourId: tour.id, createdAt: Date()))
        startTour(tour)
        showToast("Tour „\(tour.name)“ (\(FormatUtils.formatDistance(tour.lengthMeters))) geladen.")
        return true
    }

    /** Aktuelle Ziele (oder die laufende Tour) unter [name] speichern. */
    func saveCurrentRoute(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if let tour = activeTour {
            var renamed = tour
            renamed.name = trimmed.isEmpty ? tour.name : trimmed
            TourStore.save(renamed)
            SavedRoutesStore.add(SavedRoute(id: UUID().uuidString, name: renamed.name, stops: [],
                                            profile: settings.routingProfile.rawValue, tourId: renamed.id, createdAt: Date()))
        } else {
            guard !waypoints.isEmpty else { return }
            let stops = waypoints.map { SavedStop(label: $0.label, lat: $0.point.latitude, lon: $0.point.longitude) }
            SavedRoutesStore.add(SavedRoute(id: UUID().uuidString, name: trimmed.isEmpty ? (waypoints.last?.label ?? "Route") : trimmed,
                                            stops: stops, profile: settings.routingProfile.rawValue, tourId: nil, createdAt: Date()))
        }
        showToast("Route gespeichert.")
    }

    /** Gespeicherte Route/Tour laden und berechnen. */
    func loadSavedRoute(_ saved: SavedRoute) {
        if let profile = RoutingProfile(rawValue: saved.profile) { settings.routingProfile = profile }
        if let tourId = saved.tourId {
            guard let tour = TourStore.load(id: tourId) else {
                showToast("Die Tour-Datei fehlt.")
                return
            }
            startTour(tour)
            return
        }
        if navigationActive { stopNavigation() }
        clearSearch()
        waypoints = saved.stops.map { Waypoint(point: $0.point, label: $0.label) }
        waypointsChanged()
        followEnabled = false
        calculateRoute()
    }

    // MARK: - Widget, Live-Aktivität, Siri

    /** `lumogo://…` aus Widget oder Live-Aktivität. */
    func handle(_ url: URL) {
        guard let link = DeepLink(url: url) else { return }
        handle(link)
    }

    func handle(_ link: DeepLink) {
        switch link {
        case .home:
            guard let home = FavoritesStore.home() else {
                showToast("Noch kein Zuhause gespeichert — in den Favoriten festlegen.")
                requestedSheet = .some(.favorites)
                return
            }
            navigateNow(to: home)
        case .favorite(let id):
            guard let favorite = FavoritesStore.list().first(where: { $0.id == id }) else {
                showToast("Diesen Favoriten gibt es nicht mehr.")
                return
            }
            navigateNow(to: favorite)
        case .favorites:
            requestedSheet = .some(.favorites)
        case .search:
            if navigationActive { return }
            requestedSheet = .some(nil)
            searchFocused = true
        case .nearbyFuel:
            if navigationActive { return }
            searchNearby(.fuel)
        case .open:
            break
        }
    }

    /** Ziel ersetzen, Route berechnen und sofort losnavigieren (Widget „Nach Hause“, Siri). */
    func navigateNow(to favorite: Favorite) {
        if navigationActive { stopNavigation() }
        requestedSheet = .some(nil)
        clearSearch()
        waypoints = []
        addDestination(favorite.point, label: favorite.name)
        if currentPosition == nil {
            pendingAutoNavigation = true
            showToast("Warte auf den Standort …")
        } else {
            calculateRoute(startNavigationAfter: true)
        }
    }

    func navigateToFavorite(_ favorite: Favorite) {
        selectSearchResult(SearchResult(displayName: favorite.name, lat: favorite.point.latitude, lon: favorite.point.longitude, boundingBox: nil))
    }
}
