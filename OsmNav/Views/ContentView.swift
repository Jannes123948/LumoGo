import SwiftUI

enum ActiveSheet: String, Identifiable {
    case settings, favorites, nearby, trips, offline, alongRoute, weather, parking, arrivalPlanner, markers
    var id: String { rawValue }
}

/** Hauptbildschirm: Karte + Suchleiste/Ziele oben, Routen-Panel unten, Knöpfe an den Seiten. */
struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var sheet: ActiveSheet?

    /** Pfeil steht fest unten im Bild → Namensleiste direkt darunter; sonst über der Ankunftsleiste. */
    private var roadNameUnderPuck: Bool { settings.navPuckLow && model.followEnabled }

    /** Namensleiste ohne Navigation: nur solange die Karte dem Pfeil folgt (Pfeil in der Bildmitte). */
    private var freeRoadName: String? {
        guard !model.navigationActive, settings.roadNameFreeMode, model.followEnabled, model.waypoints.isEmpty,
              !model.showSearchResults else { return nil }
        return model.freeRoadName
    }

    var body: some View {
        ZStack {
            MapViewRepresentable(
                controller: model.map,
                engine: settings.mapEngine,
                dark: colorScheme == .dark,
                appearance: MapAppearance(
                    emphasizeStreetNames: settings.emphasizeStreetNames,
                    widerMotorways: settings.widerMotorways,
                    buildings3D: settings.buildings3D,
                    routeColor: settings.routeHex,
                    puckColor: settings.puckHex,
                    osmRotatable: settings.osmRotatable
                )
            )
            .ignoresSafeArea()

            VStack(spacing: 8) {
                if model.navigationActive {
                    NavHudView()
                    if let hazard = model.hazardAhead {
                        HazardPill(hazard: hazard)
                            .transition(.opacity)
                    }
                    if let reckoning = model.deadReckoning {
                        DeadReckoningPill(inTunnel: reckoning.inTunnel)
                            .transition(.opacity)
                    }
                    if !model.motorwayAhead.isEmpty {
                        MotorwayBar()
                            .frame(maxWidth: 340)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                } else {
                    SearchPanel(onOpenDownloads: { sheet = .offline })
                    if settings.offlineMapsOnly || settings.fullyOffline {
                        Label(settings.fullyOffline ? "Komplett offline" : "Nur Offline-Karten", systemImage: "wifi.slash")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .glassSurface(Capsule(), fallback: .thinMaterial, shadowRadius: 0)
                    }
                    if model.pickingFavoriteLocation {
                        Label("Lange auf die Karte drücken, um den Favoriten zu setzen", systemImage: "hand.tap")
                            .font(.footnote)
                            .padding(10)
                            .glassSurface(Capsule(), fallback: .thinMaterial, shadowRadius: 0)
                    }
                }
                Spacer(minLength: 0)
                HStack(alignment: .bottom) {
                    if !model.navigationActive {
                        VStack(alignment: .leading, spacing: 10) {
                            if settings.showCurrentSpeed && settings.speedInFreeMode && model.speedKmh != nil {
                                SpeedIndicator()
                            }
                            leftButtons
                        }
                    } else if settings.showSpeedLimit || settings.showCurrentSpeed {
                        SpeedIndicator()
                    }
                    Spacer()
                    rightButtons
                }
                if model.navigationActive, let newEta = model.etaShiftedTo {
                    EtaShiftBanner(newEta: newEta)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if model.navigationActive, !roadNameUnderPuck, let road = model.hud.roadName {
                    RoadNamePill(name: road)
                        .frame(maxWidth: .infinity)
                        .transition(.opacity)
                }
                if model.navigationActive {
                    NavBottomBar()
                } else if !model.waypoints.isEmpty {
                    RoutePanel()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // Straßenname direkt unter dem Pfeil (wie Google Maps) — die Kamera hält den Pfeil beim
            // Folgen fest an derselben Bildschirmstelle (MapController.setPuckLow).
            if model.navigationActive, roadNameUnderPuck, let road = model.hud.roadName {
                GeometryReader { geo in
                    RoadNamePill(name: road)
                        .frame(maxWidth: geo.size.width - 120)
                        .fixedSize(horizontal: false, vertical: true)
                        .position(x: geo.size.width / 2,
                                  y: geo.size.height * MapController.puckLowScreenFraction + MapController.puckLabelOffset + 18)
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .transition(.opacity)
            }

            // Ohne Navigation steht der Pfeil beim Folgen in der Bildmitte.
            if let road = freeRoadName {
                GeometryReader { geo in
                    RoadNamePill(name: road)
                        .frame(maxWidth: geo.size.width - 120)
                        .fixedSize(horizontal: false, vertical: true)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2 + MapController.puckLabelOffset + 18)
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .transition(.opacity)
            }

            if let toast = model.toast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .glassSurface(Capsule(), tint: Color.black.opacity(0.55), fallback: Color.black.opacity(0.8), shadowRadius: 0)
                        .padding(.bottom, 140)
                }
                .transition(.opacity)
                .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.toast)
        .animation(.easeInOut(duration: 0.2), value: model.navigationActive)
        .animation(.easeInOut(duration: 0.2), value: showCompass)
        .animation(.easeInOut(duration: 0.25), value: model.etaShiftedTo)
        .animation(.easeInOut(duration: 0.25), value: model.motorwayAhead.isEmpty)
        .animation(.easeInOut(duration: 0.2), value: model.deadReckoning)
        .animation(.easeInOut(duration: 0.2), value: model.hazardAhead?.id)
        .animation(.easeInOut(duration: 0.2), value: model.parkedCar == nil)
        .animation(.easeInOut(duration: 0.2), value: freeRoadName)
        .onAppear {
            model.start()
            model.checkSharedInbox()
        }
        // Ort aus einer anderen App geteilt, während LumoGo im Hintergrund war.
        .onChange(of: scenePhase) { phase in
            if phase == .active { model.checkSharedInbox() }
        }
        .onChange(of: settings.parkingMemory) { _ in model.parkingSettingChanged() }
        .onChange(of: settings.favoritesOnMap) { _ in model.refreshFavoriteMarkers() }
        // Widget, Live-Aktivität (lumogo://…) und Siri-Kurzbefehle.
        .onOpenURL { model.handle($0) }
        .onChange(of: model.requestedSheet) { request in
            guard let request else { return }
            sheet = request
            model.requestedSheet = nil
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .settings: SettingsView(openTrips: { self.sheet = .trips })
            case .favorites: FavoritesView()
            case .nearby: NearbyView()
            case .trips: TripHistoryView()
            case .offline: OfflineMapsView()
            case .alongRoute: AlongRouteSheet()
            case .weather: WeatherSheet()
            case .parking: ParkingSheet()
            case .arrivalPlanner: ArrivalPlannerSheet()
            case .markers: MarkersSheet()
            }
        }
        .sheet(item: $model.poiSelection) { _ in
            PoiDetailSheet()
        }
        .sheet(item: $model.pendingFavorite) { pending in
            FavoriteNameSheet(pending: pending)
        }
        .confirmationDialog(model.selectedMarker?.title ?? "", isPresented: Binding(get: { model.selectedMarker != nil }, set: { if !$0 { model.selectedMarker = nil } }), titleVisibility: .visible, presenting: model.selectedMarker) { marker in
            Button("Hierhin navigieren") {
                model.navigateNow(to: Favorite(id: marker.id, name: marker.title, point: marker.point, isHome: false))
            }
            Button("Markierung löschen", role: .destructive) { model.removeMarker(id: marker.id) }
            Button("Abbrechen", role: .cancel) {}
        } message: { marker in
            Text(marker.kind.label)
        }
        .alert("Hinweis", isPresented: Binding(get: { model.alertMessage != nil }, set: { if !$0 { model.alertMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alertMessage ?? "")
        }
    }

    private var leftButtons: some View {
        GlassGroup {
        VStack(spacing: 10) {
            if settings.parkingMemory, model.parkedCar != nil {
                MapButton(symbol: "car.fill") { sheet = .parking }
                    .accessibilityLabel("Mein Auto")
                    .transition(.scale.combined(with: .opacity))
            }
            MapButton(symbol: "location.magnifyingglass") { sheet = .nearby }
            MapButton(symbol: "star.fill") { sheet = .favorites }
            MapButton(symbol: "mappin.and.ellipse") { sheet = .markers }
                .accessibilityLabel("Markierungen")
            MapButton(symbol: "icloud.and.arrow.down") { sheet = .offline }
            MapButton(symbol: "gearshape.fill") { sheet = .settings }
        }
        }
    }

    /** Kompass nur in der drehbaren Vektorkarte: frei bei gedrehter Karte, in der Navigation immer. */
    private var showCompass: Bool {
        settings.showCompassButton && model.mapRotatable &&
            (model.navigationActive || abs(model.mapDirection) >= 1 && abs(model.mapDirection - 360) >= 1)
    }

    private var rightButtons: some View {
        GlassGroup {
        VStack(spacing: 10) {
            if showCompass {
                CompassButton(direction: model.mapDirection, northUp: model.northUpNavigation) { model.compassTapped() }
                    .transition(.scale.combined(with: .opacity))
            }
            if settings.weatherButton {
                MapButton(symbol: "cloud.sun.fill") { sheet = .weather }
                    .accessibilityLabel("Wetter")
            }
            if settings.mapEngine.supports3D {
                MapButton(text: model.is3DEnabled ? "2D" : "3D") { model.toggle3D() }
            }
            if !model.followEnabled {
                MapButton(symbol: "location.fill") { model.recenter() }
            }
        }
        }
    }
}

/** Kompass-Knopf: Nadel zeigt nach Norden; in „Norden oben“ während der Navigation hervorgehoben. */
struct CompassButton: View {
    let direction: Double
    let northUp: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Image(systemName: "location.north.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(northUp ? Color.accentColor : Color.red)
                    .rotationEffect(.degrees(-direction))
                Text("N")
                    .font(.system(size: 9, weight: .heavy))
                    .offset(y: -17)
                    .rotationEffect(.degrees(-direction))
            }
            .frame(width: 48, height: 48)
            .glassCircle()
        }
        .accessibilityLabel(northUp ? "Kompass, Norden oben" : "Kompass")
    }
}

/** Runder, schwebender Kartenknopf (Pendant zu den FABs der Android-Version). */
struct MapButton: View {
    var symbol: String?
    var text: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 18, weight: .semibold))
                } else {
                    Text(text ?? "").font(.system(size: 15, weight: .bold))
                }
            }
            .frame(width: 48, height: 48)
            .glassCircle()
        }
    }
}

extension View {
    /** Abgerundete "Karte" als Hintergrund für Panels über der Karte — Liquid Glass ab iOS 26. */
    func card() -> some View { glassCard() }
}
