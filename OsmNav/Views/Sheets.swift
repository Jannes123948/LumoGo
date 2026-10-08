import SwiftUI
import UniformTypeIdentifiers

// MARK: - Einstellungen

/** Übersicht wie in der iPhone-Einstellungen-App: je Bereich eine eigene Seite. */
struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var confirmReset = false
    let openTrips: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink { MapSettingsPage() } label: { SettingsRow(title: "Karte", symbol: "map.fill", color: .green) }
                    NavigationLink { DesignSettingsPage() } label: { SettingsRow(title: "Design & Farben", symbol: "paintpalette.fill", color: .pink) }
                    NavigationLink { NavigationSettingsPage() } label: { SettingsRow(title: "Navigation", symbol: "location.north.line.fill", color: .blue) }
                    NavigationLink { VoiceSettingsPage() } label: { SettingsRow(title: "Sprachausgabe", symbol: "speaker.wave.2.fill", color: .orange) }
                    NavigationLink { SpeedSettingsPage() } label: { SettingsRow(title: "Tempolimit", symbol: "gauge.with.dots.needle.67percent", color: .red) }
                    NavigationLink { SearchSettingsPage() } label: { SettingsRow(title: "Suche & Orte", symbol: "magnifyingglass", color: .purple) }
                }
                Section {
                    Button {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { openTrips() }
                    } label: {
                        SettingsRow(title: "Fahrtenbuch", symbol: "book.closed.fill", color: .brown)
                    }
                    .foregroundStyle(.primary)
                }
                Section {
                    Button("Alle Einstellungen zurücksetzen", role: .destructive) { confirmReset = true }
                } footer: {
                    Text("Favoriten, Suchverlauf, Fahrtenbuch und Offline-Karten bleiben erhalten.")
                }
                Section {
                    Text("Kartendaten © OpenStreetMap-Mitwirkende · Kacheln: OpenFreeMap · Routing: OSRM · Suche: Nominatim/Overpass")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Einstellungen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
            .confirmationDialog("Alle Einstellungen auf Standard zurücksetzen?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Zurücksetzen", role: .destructive) { settings.resetAll() }
            }
        }
    }
}

/** Zeile mit farbigem Symbol-Kästchen (wie in den iPhone-Einstellungen). */
struct SettingsRow: View {
    let title: String
    let symbol: String
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(color, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            Text(title)
        }
    }
}

private struct MapSettingsPage: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Picker("Karte", selection: $settings.mapEngine) {
                    ForEach(MapEngine.allCases) { Text($0.label).tag($0) }
                }
                Picker("Hell / Dunkel", selection: $settings.mapTheme) {
                    ForEach(MapTheme.allCases) { Text($0.label).tag($0) }
                }
            } footer: {
                if settings.mapEngine == .osm {
                    Text("Klassische OpenStreetMap-Karte: flach (ohne 3D-Neigung). Offline-Karten werden hier nicht angezeigt (der OSM-Server erlaubt keine Massen-Downloads) — Offline-Suche und Offline-Routing funktionieren trotzdem.")
                }
            }
            if settings.mapEngine == .osm {
                Section {
                    Toggle("Karte drehbar", isOn: $settings.osmRotatable)
                    Toggle("Kompass-Knopf", isOn: $settings.showCompassButton)
                } header: {
                    Text("Darstellung")
                } footer: {
                    Text("Drehbar: mit zwei Fingern drehen, in der Navigation zeigt die Karte in Fahrtrichtung. Aus = immer Norden oben. Beschriftungen drehen sich bei dieser Karte mit.")
                }
            }
            if settings.mapEngine == .vector {
                Section("Darstellung") {
                    Toggle("3D-Ansicht beim App-Start", isOn: $settings.start3D)
                    Toggle("3D-Gebäude", isOn: $settings.buildings3D)
                    Toggle("Straßennamen hervorheben", isOn: $settings.emphasizeStreetNames)
                    Toggle("Autobahnen breiter zeichnen", isOn: $settings.widerMotorways)
                    Toggle("Kompass-Knopf", isOn: $settings.showCompassButton)
                }
            }
            Section {
                Toggle("Nur Offline-Karten verwenden", isOn: $settings.offlineMapsOnly)
                    .disabled(settings.fullyOffline)
                Toggle("Komplett offline (auch Suche & Routing)", isOn: $settings.fullyOffline)
            } header: {
                Text("Offline")
            } footer: {
                Text(settings.mapEngine == .osm && (settings.offlineMapsOnly || settings.fullyOffline)
                     ? "Achtung: Offline-Pakete gibt es nur für die Vektorkarte (MapLibre) — die OSM-Karte bleibt offline leer. Oben „MapLibre“ wählen."
                     : "Nur Offline-Karten: Die Karte lädt nichts aus dem Internet und zeigt nur heruntergeladene Gebiete (spart Datenvolumen). Komplett offline: auch Routing, Suche und Ort-Infos nur aus den Offline-Daten. Eigene Offline-Downloads funktionieren trotzdem.")
            }
            Section {
                Toggle("Position auf Straße einrasten", isOn: $settings.snapToRoad)
                Toggle("Kompass im Stand", isOn: $settings.compassWhenIdle)
            } header: {
                Text("Standort")
            } footer: {
                Text("Einrasten: Der Pfeil sitzt auf der nächsten Straße statt an der ungenauen GPS-Position. Kompass: Im Stand zeigt der Pfeil in die Richtung, in die das iPhone zeigt.")
            }
        }
        .navigationTitle("Karte")
    }
}

private struct DesignSettingsPage: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section {
                ColorBubbles(colors: AccentColor.allCases.map { ($0.rawValue, $0.primary) }, selected: settings.accentColor.rawValue) {
                    settings.accentColor = AccentColor(rawValue: $0) ?? .default
                }
            } header: {
                Text("Oberflächenfarbe")
            } footer: {
                Text("Knöpfe, Schalter und die Navigationsleisten.")
            }
            Section("Routenlinie") {
                ColorBubbles(colors: MapColor.allCases.map { ($0.rawValue, $0.color) }, selected: settings.routeColor.rawValue) {
                    settings.routeColor = MapColor(rawValue: $0) ?? .blue
                }
            }
            Section("Standort-Pfeil") {
                ColorBubbles(colors: MapColor.allCases.map { ($0.rawValue, $0.color) }, selected: settings.puckColor.rawValue) {
                    settings.puckColor = MapColor(rawValue: $0) ?? .blue
                }
            }
            if LiquidGlass.isAvailable {
                Section {
                    Toggle("Liquid Glass", isOn: $settings.liquidGlass)
                } footer: {
                    Text("Gläserner Look von iOS 26 für Kartenknöpfe, Suchleiste, Panels und Navigationsleisten. Aus = klassischer Look wie unter iOS 16–18.")
                }
            }
            Section {
                Toggle("Große Schrift", isOn: $settings.largeHud)
                VStack(alignment: .leading) {
                    Text("Deckkraft: \(Int((settings.hudOpacity * 100).rounded())) %")
                    Slider(value: $settings.hudOpacity, in: 0.6...1)
                }
                // Vorschau der Navigationsleiste in den gewählten Farben.
                HStack(spacing: 12) {
                    Image(systemName: "arrow.turn.up.right")
                        .font(.system(size: settings.largeHud ? 34 : 26, weight: .bold))
                    VStack(alignment: .leading, spacing: 0) {
                        Text("300 m").font(.system(size: settings.largeHud ? 28 : 22, weight: .bold))
                        Text("Rechts abbiegen auf Hauptstraße").font(.system(size: settings.largeHud ? 17 : 14, weight: .medium))
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.white)
                .padding(12)
                .glassPanel(tint: settings.accentColor.dark.opacity(settings.hudOpacity), cornerRadius: 14)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            } header: {
                Text("Navigationsleisten")
            }
        }
        .navigationTitle("Design & Farben")
    }
}

/** Auswahl-Kreise für Farben; die gewählte bekommt einen Rand. */
private struct ColorBubbles: View {
    let colors: [(id: String, color: Color)]
    let selected: String
    let onSelect: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(colors, id: \.id) { item in
                    Circle()
                        .fill(item.color)
                        .frame(width: 36, height: 36)
                        .overlay(Circle().stroke(Color.primary, lineWidth: selected == item.id ? 3 : 0).padding(-4))
                        .overlay {
                            if selected == item.id {
                                Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                            }
                        }
                        .onTapGesture { onSelect(item.id) }
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
        }
    }
}

private struct NavigationSettingsPage: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Picker("Standard-Profil", selection: $settings.routingProfile) {
                    ForEach(RoutingProfile.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
                }
                Toggle("Alternativrouten anbieten", isOn: $settings.alternativeRoutes)
                Toggle("Routenvorschau (Anweisungen, Höhenprofil)", isOn: $settings.routePreviewEnabled)
            } header: {
                Text("Route")
            }
            Section {
                Toggle("Display bleibt an", isOn: $settings.keepScreenOn)
                Toggle("Zoom passt sich dem Tempo an", isOn: $settings.autoZoom)
                Toggle("Fahrstreifen-Empfehlung", isOn: $settings.laneGuidance)
                Toggle("Automatisch neu berechnen", isOn: $settings.autoReroute)
            } header: {
                Text("Während der Navigation")
            } footer: {
                Text("Neu berechnen: Weicht man mehr als 50 m von der Route ab, wird automatisch eine neue Route gesucht.")
            }
            Section {
                Picker("Straßennetz aus", selection: $settings.offlineRoadSource) {
                    ForEach(OfflineRoadSource.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Rad- und Fußwege mitladen", isOn: $settings.offlinePaths)
            } header: {
                Text("Offline-Routing")
            } footer: {
                Text("Kartenkacheln: in Sekunden fertig, auch für große Gebiete, ohne Abbiegeverbote und echte Tempolimits (Tempo nach Straßenart, innerorts 50). Overpass: genauere OSM-Daten, aber der Server ist oft überlastet — klappt eine Quelle nicht, wird automatisch die andere versucht. Rad- und Fußwege aus: nur Straßen, kleiner und schneller, reicht fürs Auto; an: auch Feld-, Rad- und Fußwege fürs Fahrrad oder zu Fuß. Gilt für neu geladene Routing-Daten (Paket-Menü → „Routing-Daten aktualisieren“).")
            }
        }
        .navigationTitle("Navigation")
    }
}

private struct VoiceSettingsPage: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var model: AppModel
    @State private var voices = SpeechService.germanVoices()

    var body: some View {
        Form {
            Section {
                Toggle("Sprachansagen", isOn: $settings.voiceEnabled)
            }
            Section {
                Picker("Stimme", selection: $settings.voiceIdentifier) {
                    Text("Automatisch (beste verfügbare)").tag("")
                    ForEach(voices) { voice in
                        Text("\(voice.name) · \(voice.qualityLabel)").tag(voice.id)
                    }
                }
                VStack(alignment: .leading) {
                    Text("Tempo")
                    HStack {
                        Image(systemName: "tortoise").foregroundStyle(.secondary)
                        Slider(value: $settings.speechRate, in: 0.4...0.62)
                        Image(systemName: "hare").foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading) {
                    Text("Lautstärke")
                    HStack {
                        Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                        Slider(value: $settings.speechVolume, in: 0.2...1)
                        Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                    }
                }
                Button {
                    model.previewVoice()
                } label: {
                    Label("Probe anhören", systemImage: "play.circle.fill")
                }
                if settings.speechRate != SpeechService.defaultRate {
                    Button("Tempo zurücksetzen") { settings.speechRate = SpeechService.defaultRate }
                }
            } header: {
                Text("Stimme")
            } footer: {
                Text(voices.contains { $0.quality == .premium }
                     ? "Tipp: Premium-Stimmen klingen am natürlichsten."
                     : "Viel bessere Stimmen gibt es kostenlos: iPhone-Einstellungen → Bedienungshilfen → Gesprochene Inhalte → Stimmen → Deutsch → z.B. „Anna (Premium)“ oder „Helena (Premium)“ laden. Danach erscheinen sie hier.")
            }
            .disabled(!settings.voiceEnabled)
            Section {
                Toggle("Vorankündigungen (1 km, 500 m, 200 m)", isOn: $settings.preAnnouncements)
                Toggle("„Danach …“-Hinweise", isOn: $settings.chainAnnouncements)
                Toggle("Musik während Ansagen leiser", isOn: $settings.duckMusic)
            } header: {
                Text("Ansagen")
            }
            .disabled(!settings.voiceEnabled)
        }
        .onAppear { voices = SpeechService.germanVoices() }
        .navigationTitle("Sprachausgabe")
    }
}

private struct SpeedSettingsPage: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Toggle("Tempolimit-Schild anzeigen", isOn: $settings.showSpeedLimit)
                Toggle("Eigene Geschwindigkeit anzeigen", isOn: $settings.showCurrentSpeed)
                if settings.showCurrentSpeed {
                    Toggle("Geschwindigkeit auch ohne Navigation", isOn: $settings.speedInFreeMode)
                }
            } footer: {
                Text("Unten links. Das Tempolimit-Schild gibt es während der Navigation mit dem Auto. Das Limit stammt aus OpenStreetMap — fehlt es dort, bleibt das Schild weg. Ohne Gewähr, Verkehrszeichen gehen immer vor.")
            }
            Section {
                Toggle("Ansage bei Überschreitung", isOn: $settings.speedWarning)
                Stepper("Toleranz: \(settings.speedTolerance) km/h", value: $settings.speedTolerance, in: 0...15)
            } header: {
                Text("Warnung")
            } footer: {
                Text("Erst ab Limit + Toleranz wird die Geschwindigkeit rot und es kommt „Achtung, Tempolimit …“. GPS misst die echte Geschwindigkeit — der Tacho zeigt meist ein paar km/h mehr.")
            }
            .disabled(!settings.showSpeedLimit)
            Section {
                HStack(spacing: 16) {
                    SpeedLimitSign(limit: .kmh(50), size: 50)
                    SpeedLimitSign(limit: .kmh(100), size: 50)
                    SpeedLimitSign(limit: .unlimited, size: 50)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            } header: {
                Text("So sieht's aus")
            }
        }
        .navigationTitle("Tempolimit")
    }
}

private struct SearchSettingsPage: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var cleared = false

    var body: some View {
        Form {
            Section {
                Toggle("Orte auf der Karte antippbar", isOn: $settings.poiTapEnabled)
                Toggle("„Geöffnet/Geschlossen“ in Listen", isOn: $settings.showOpenStatus)
            } header: {
                Text("Orte")
            } footer: {
                Text("Antippen zeigt Öffnungszeiten, Adresse, Telefon und Website aus OpenStreetMap.")
            }
            Section {
                Toggle("Suchverlauf anzeigen", isOn: $settings.recentSearchesEnabled)
                Button(cleared ? "Suchverlauf gelöscht" : "Suchverlauf löschen", role: .destructive) {
                    RecentSearchesStore.clear()
                    cleared = true
                }
                .disabled(cleared)
            } header: {
                Text("Suche")
            }
        }
        .navigationTitle("Suche & Orte")
    }
}


// MARK: - Favoriten

struct FavoritesView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var favorites = FavoritesStore.list()
    @State private var exporting = false
    @State private var importing = false

    var body: some View {
        NavigationStack {
            List {
                if favorites.isEmpty {
                    Text("Noch keine Favoriten gespeichert.").foregroundStyle(.secondary)
                }
                ForEach(favorites) { favorite in
                    Button {
                        model.navigateToFavorite(favorite)
                        dismiss()
                    } label: {
                        Label(favorite.name, systemImage: favorite.isHome ? "house.fill" : "star.fill")
                            .foregroundStyle(.primary)
                    }
                }
                .onDelete { offsets in
                    offsets.map { favorites[$0].id }.forEach(FavoritesStore.remove)
                    favorites = FavoritesStore.list()
                }

                Section("Neuen Favoriten speichern") {
                    Button {
                        dismiss()
                        model.saveCurrentPositionAsFavorite()
                    } label: { Label("Aktuelle Position", systemImage: "location") }
                    Button {
                        model.pickingFavoriteLocation = true
                        dismiss()
                    } label: { Label("Auf der Karte wählen", systemImage: "hand.tap") }
                    Text("Tipp: Über den Stern neben einem Suchergebnis lässt sich auch eine Adresse speichern.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Sichern") {
                    Button { exporting = true } label: { Label("Exportieren", systemImage: "square.and.arrow.up") }
                    Button { importing = true } label: { Label("Importieren", systemImage: "square.and.arrow.down") }
                }
            }
            .navigationTitle("Favoriten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
            .fileExporter(isPresented: $exporting, document: JSONFile(data: FavoritesStore.exportJson()), contentType: .json, defaultFilename: "osmnav_favoriten") { result in
                if case .success = result { model.showToast("Favoriten exportiert.") }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                guard case .success(let url) = result else { return }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url), let count = try? FavoritesStore.importJson(data) {
                    favorites = FavoritesStore.list()
                    model.showToast("\(count) Favoriten importiert.")
                } else {
                    model.showToast("Import fehlgeschlagen.")
                }
            }
        }
    }
}

struct JSONFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct FavoriteNameSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let pending: AppModel.PendingFavorite
    @State private var name = ""
    @State private var asHome = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                Toggle("Als Zuhause festlegen", isOn: $asHome)
            }
            .navigationTitle("Favorit speichern")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Speichern") {
                        model.confirmFavorite(name: name, point: pending.point, asHome: asHome)
                        dismiss()
                    }
                }
            }
            .onAppear { name = pending.name }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - In der Nähe

struct NearbyView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(NearbyCategory.allCases) { category in
                Button {
                    model.searchNearby(category)
                    dismiss()
                } label: {
                    Label(category.label, systemImage: category.symbol).foregroundStyle(.primary)
                }
            }
            .navigationTitle("In der Nähe suchen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Fahrtenbuch

struct TripHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var trips = TripHistoryStore.list()

    var body: some View {
        NavigationStack {
            List {
                if trips.isEmpty {
                    Text("Noch keine Fahrten. Fahrten werden nur bei tatsächlicher Ankunft gespeichert.")
                        .foregroundStyle(.secondary)
                }
                ForEach(trips) { trip in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(trip.destinationName).font(.headline).lineLimit(2)
                        Text("\(trip.timestamp.formatted(date: .abbreviated, time: .shortened)) · \(FormatUtils.formatDistance(trip.distanceMeters)) · \(FormatUtils.formatDuration(trip.durationSeconds))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .onDelete { offsets in
                    offsets.map { trips[$0].id }.forEach(TripHistoryStore.remove)
                    trips = TripHistoryStore.list()
                }
            }
            .navigationTitle("Fahrtenbuch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } }
                ToolbarItem(placement: .destructiveAction) {
                    Button("Alle löschen", role: .destructive) {
                        TripHistoryStore.clear()
                        trips = []
                    }
                    .disabled(trips.isEmpty)
                }
            }
        }
    }
}
