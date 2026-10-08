import SwiftUI

enum ActiveSheet: String, Identifiable {
    case settings, favorites, nearby, trips, offline
    var id: String { rawValue }
}

/** Hauptbildschirm: Karte + Suchleiste/Ziele oben, Routen-Panel unten, Knöpfe an den Seiten. */
struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    @State private var sheet: ActiveSheet?

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
                    routeColor: settings.routeColor.hex,
                    puckColor: settings.puckColor.hex,
                    osmRotatable: settings.osmRotatable
                )
            )
            .ignoresSafeArea()

            VStack(spacing: 8) {
                if model.navigationActive {
                    NavHudView()
                } else {
                    SearchPanel()
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
                if model.navigationActive {
                    NavBottomBar()
                } else if !model.waypoints.isEmpty {
                    RoutePanel()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

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
        .onAppear { model.start() }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .settings: SettingsView(openTrips: { self.sheet = .trips })
            case .favorites: FavoritesView()
            case .nearby: NearbyView()
            case .trips: TripHistoryView()
            case .offline: OfflineMapsView()
            }
        }
        .sheet(item: $model.poiSelection) { _ in
            PoiDetailSheet()
        }
        .sheet(item: $model.pendingFavorite) { pending in
            FavoriteNameSheet(pending: pending)
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
            MapButton(symbol: "location.magnifyingglass") { sheet = .nearby }
            MapButton(symbol: "star.fill") { sheet = .favorites }
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
