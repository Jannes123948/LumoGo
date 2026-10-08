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

    let settings: AppSettings
    let map = MapController()
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
    /** Zuletzt gefundene Ergebnisse je Suchtext — Rücktaste/erneutes Tippen zeigt sie sofort. */
    private var searchCache: [String: (results: [SearchResult], at: Date)] = [:]

    // Ziele & Route
    @Published private(set) var waypoints: [Waypoint] = []
    @Published private(set) var routeOptions: [OsrmRoute] = []
    @Published private(set) var selectedRouteIndex = 0
    @Published private(set) var lastRoute: OsrmRoute?
    @Published private(set) var instructions: [String] = []
    @Published var showInstructions = false
    @Published private(set) var elevationProfile: ElevationProfile?
    @Published private(set) var routeLoading = false

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

    init(settings: AppSettings) {
        self.settings = settings
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
        if let cached = searchCache[query.lowercased()], Date().timeIntervalSince(cached.at) < 600 {
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
                searchCache[query.lowercased()] = (result.results, Date())
            }
            // Die POI-Ergänzung kann Sekunden später kommen — eine inzwischen geschlossene Liste
            // (Karte angetippt, Ziel gewählt) darf sie nicht wieder aufmachen.
            guard isStillSearching(query, explicit: showErrors) else { return }
            searchResults = result.results
            showSearchResults = !result.results.isEmpty
            if result.results.isEmpty && showErrors { showToast("Keine Ergebnisse gefunden.") }
            if result.usedOfflineSearch { showToast("Offline-Suche verwendet (heruntergeladene Kartenpakete).") }
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
        map.setDestinations(waypoints.map(\.point))
        if navigationActive { stopNavigation() }
        resetRoute()
    }

    private func resetRoute() {
        lastRoute = nil
        elevationProfile = nil
        routeOptions = []
        selectedRouteIndex = 0
        instructions = []
        showInstructions = false
        map.setRoutes([], selected: 0)
    }

    // MARK: - Route

    func calculateRoute() {
        guard !waypoints.isEmpty else {
            showToast("Bitte zuerst ein Ziel wählen.")
            return
        }
        guard let start = currentPosition else {
            showToast("Standort noch nicht verfügbar.")
            return
        }
        if navigationActive { stopNavigation() }
        // OSRM liefert Alternativrouten nur bei genau Start + Ziel (kein Zwischenstopp).
        let points = [start] + waypoints.map(\.point)
        let alternatives = waypoints.count == 1 && settings.alternativeRoutes
        routeLoading = true
        Task {
            defer { routeLoading = false }
            do {
                let result = try await RouteFetcher.getRoutes(points, alternatives: alternatives, profile: settings.routingProfile)
                routeOptions = result.routes
                selectRoute(0)
                fitRouteInView(result.routes[0])
                if result.usedOfflineRouting { showToast("Offline-Route berechnet.") }
            } catch let error as OfflineRoutingError {
                alertMessage = "Keine Internetverbindung – und offline ging es auch nicht:\n\(error.localizedDescription)"
            } catch {
                alertMessage = "Route konnte nicht berechnet werden. Internetverbindung prüfen oder unter „Offline-Karten“ ein Paket für dieses Gebiet herunterladen."
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
        followEnabled = true
        showSearchResults = false
        // Display während der Navigation anlassen + Standort im Hintergrund weiterlaufen lassen.
        UIApplication.shared.isIdleTimerDisabled = settings.keepScreenOn
        location.setNavigating(true)

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
    }

    func stopNavigation() {
        navigationActive = false
        tracker = nil
        northUpNavigation = false
        speedLimitTask?.cancel()
        speedLimits.replace([])
        speedLimit = nil
        isSpeeding = false
        UIApplication.shared.isIdleTimerDisabled = false
        location.setNavigating(false)
        map.ease(pitch: currentTilt(), heading: 0)
    }

    private func logCompletedTrip() {
        guard let route = lastRoute, let destination = waypoints.last?.label else { return }
        TripHistoryStore.add(Trip(
            id: UUID().uuidString,
            destinationName: destination,
            distanceMeters: route.distance,
            durationSeconds: Date().timeIntervalSince(navigationStart),
            timestamp: Date()
        ))
    }

    private func onLocationUpdate(_ loc: CLLocation) {
        lastLocation = loc
        let raw = LatLon(loc.coordinate)

        // "Auf die Straße setzen": während der Navigation auf die Route projizieren, sonst über
        // OSRMs nearest-Dienst. Für Re-Routing bleibt die rohe Position maßgeblich.
        let display: LatLon
        if navigationActive, let snap = tracker?.snapWithBearing(raw) {
            // Auf der Route: Position UND Richtung aus der Route (Straßenrichtung voraus).
            display = snap.point
            navBearing = snap.bearing
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
        map.updatePuck(display, heading: navBearing)

        if !hasCenteredOnFirstFix {
            hasCenteredOnFirstFix = true
            map.ease(center: display, zoom: 16, pitch: currentTilt(), duration: 0)
        }

        guard navigationActive, let tracker else {
            // Freier Modus: nur die eigene Geschwindigkeit (ohne Route gibt es keine Tempolimits).
            updateCurrentSpeed(loc)
            if followEnabled { map.ease(center: display, pitch: currentTilt()) }
            return
        }

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
            stopNavigation()
            return
        }

        if settings.autoReroute && !reroutingInProgress && tracker.distanceFromRoute(raw) > Self.rerouteThresholdMeters {
            reroute(from: raw, legIndex: tracker.currentLegIndex())
        }

        if followEnabled {
            map.ease(center: display, zoom: navZoom(loc.speed), pitch: currentTilt(), heading: cameraHeading())
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

    /** Neue Route ab der aktuellen Position zu den noch nicht erreichten Zielen. */
    /** Kompass dreht den Pfeil nur im freien Modus und nur, wenn gerade kein GPS-Kurs vorliegt. */
    private func onCompassHeading(_ heading: Double) {
        guard !navigationActive, settings.compassWhenIdle, Date().timeIntervalSince(lastReliableCourseAt) > 3,
              let position = lastDisplayPosition else { return }
        navBearing = heading
        map.updatePuck(position, heading: heading)
    }

    private func reroute(from current: LatLon, legIndex: Int) {
        let remaining = waypoints.map(\.point).dropFirst(legIndex)
        guard !remaining.isEmpty else { return }
        reroutingInProgress = true
        say("Route wird neu berechnet.", interrupt: true)
        Task {
            defer { reroutingInProgress = false }
            do {
                let result = try await RouteFetcher.getRoutes([current] + remaining, alternatives: false, profile: settings.routingProfile)
                guard navigationActive, let route = result.routes.first else { return }
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
        let next = tracker.nextManeuver()
        let distanceToNext = tracker.distanceToNextManeuver(current)
        hud = NavHudState(
            distanceText: FormatUtils.formatDistance(distanceToNext),
            instruction: next.instruction,
            icon: ManeuverIconResolver.resolve(type: next.maneuverType, modifier: next.maneuverModifier),
            etaText: FormatUtils.formatEta(remainingDuration),
            summaryText: "\(FormatUtils.formatDistance(remainingDistance)) · \(FormatUtils.formatDuration(remainingDuration))",
            // Spurempfehlung erst kurz vor der Abzweigung (wie Google Maps).
            lanes: settings.laneGuidance && distanceToNext <= 400 ? (next.lanes ?? []) : []
        )
    }

    // MARK: - Sprachausgabe

    private func say(_ text: String, interrupt: Bool = false, force: Bool = false) {
        guard settings.voiceEnabled || force else { return }
        speech.speak(
            text,
            voiceIdentifier: settings.voiceIdentifier.isEmpty ? nil : settings.voiceIdentifier,
            rate: settings.speechRate,
            volume: settings.speechVolume,
            duckOthers: settings.duckMusic,
            interrupt: interrupt
        )
    }

    /** Hörprobe für die Einstellungen (auch wenn Ansagen aus sind). */
    func previewVoice() {
        say("In 300 Metern rechts abbiegen auf Hauptstraße. Danach links halten.", interrupt: true, force: true)
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

    func navigateToFavorite(_ favorite: Favorite) {
        selectSearchResult(SearchResult(displayName: favorite.name, lat: favorite.point.latitude, lon: favorite.point.longitude, boundingBox: nil))
    }
}
