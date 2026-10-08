import SwiftUI

// MARK: - Übersicht

/** Einstellungen: Kopfkarte mit App-Infos, darunter je Bereich eine Zeile mit aktuellem Wert. */
struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var confirmReset = false
    let openTrips: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SettingsHeaderCard()
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
                Section {
                    NavigationLink { MapSettingsPage() } label: {
                        SettingsRow(title: "Karte", symbol: "map.fill", color: .green,
                                    value: "\(settings.mapEngine == .vector ? "MapLibre" : "OSM") · \(settings.mapTheme.label)")
                    }
                    NavigationLink { DesignSettingsPage() } label: {
                        HStack {
                            SettingsRow(title: "Design & Farben", symbol: "paintpalette.fill", color: .pink)
                            Spacer()
                            ColorDots(hexes: [settings.accentHex, settings.resolvedHudBackgroundHex, settings.routeHex])
                        }
                    }
                } header: {
                    Text("Aussehen")
                }
                Section {
                    NavigationLink { NavigationSettingsPage() } label: {
                        SettingsRow(title: "Navigation", symbol: "location.north.line.fill", color: .blue, value: settings.routingProfile.label)
                    }
                    NavigationLink { VoiceSettingsPage() } label: {
                        SettingsRow(title: "Sprachausgabe", symbol: "speaker.wave.2.fill", color: .orange, value: settings.voiceEnabled ? "An" : "Aus")
                    }
                    NavigationLink { SpeedSettingsPage() } label: {
                        SettingsRow(title: "Tempolimit", symbol: "gauge.medium", color: .red,
                                    value: settings.showSpeedLimit ? (settings.speedWarning ? "Mit Warnung" : "An") : "Aus")
                    }
                    NavigationLink { SearchSettingsPage() } label: {
                        SettingsRow(title: "Suche & Orte", symbol: "magnifyingglass", color: .purple)
                    }
                } header: {
                    Text("Unterwegs")
                }
                Section {
                    Button {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { openTrips() }
                    } label: {
                        HStack {
                            SettingsRow(title: "Fahrtenbuch", symbol: "book.closed.fill", color: .brown)
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                    }
                    .foregroundStyle(.primary)
                } header: {
                    Text("Daten")
                }
                Section {
                    Button(role: .destructive) { confirmReset = true } label: {
                        SettingsRow(title: "Alle Einstellungen zurücksetzen", symbol: "arrow.counterclockwise", color: .gray)
                            .foregroundStyle(.red)
                    }
                } footer: {
                    Text("Favoriten, Suchverlauf, Fahrtenbuch und Offline-Karten bleiben erhalten.\n\nKartendaten © OpenStreetMap-Mitwirkende · Kacheln: OpenFreeMap · Routing: OSRM · Suche: Nominatim/Overpass")
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

/** Kopf der Einstellungen: App-Symbol, Name, Version — in der gewählten Oberflächenfarbe getönt. */
private struct SettingsHeaderCard: View {
    @EnvironmentObject private var settings: AppSettings

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    var body: some View {
        HStack(spacing: 16) {
            AppIconBadge(size: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text("LumoGo").font(.title2.weight(.bold))
                Text("Version \(version)").font(.subheadline).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Label(settings.routingProfile.label, systemImage: settings.routingProfile.symbol)
                    if settings.fullyOffline || settings.offlineMapsOnly {
                        Label("Offline", systemImage: "wifi.slash")
                    }
                }
                .font(.caption.weight(.medium))
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.tint)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(
            LinearGradient(colors: [settings.accent.opacity(0.22), settings.accent.opacity(0.06)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(settings.accent.opacity(0.25)))
    }
}

/** Nachbau des App-Symbols (leuchtender Pfeil auf dunkelblauem Verlauf). */
struct AppIconBadge: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x123A6B), Color(hex: 0x071A33)], startPoint: .top, endPoint: .bottom))
            Image(systemName: "location.north.fill")
                .font(.system(size: size * 0.5, weight: .bold))
                .foregroundStyle(LinearGradient(colors: [.white, Color(hex: 0x7FE7FF)], startPoint: .top, endPoint: .bottom))
                .rotationEffect(.degrees(20))
                .shadow(color: Color(hex: 0x7FE7FF).opacity(0.8), radius: size * 0.12)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
    }
}

/** Farbiges Symbol-Kästchen wie in den iPhone-Einstellungen. */
struct SettingsIcon: View {
    let symbol: String
    let color: Color
    var foreground: Color = .white

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(foreground)
            .frame(width: 29, height: 29)
            .background(
                LinearGradient(colors: [color.opacity(0.85), color], startPoint: .top, endPoint: .bottom),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
    }
}

/** Zeile mit Symbol-Kästchen, Titel und optionalem aktuellen Wert rechts. */
struct SettingsRow: View {
    let title: String
    let symbol: String
    let color: Color
    var value: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            SettingsIcon(symbol: symbol, color: color)
            Text(title)
            if let value {
                Spacer(minLength: 8)
                Text(value).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

/** Schalter mit Symbol-Kästchen. */
private struct SettingToggle: View {
    let title: String
    let symbol: String
    let color: Color
    @Binding var isOn: Bool

    init(_ title: String, symbol: String, color: Color, isOn: Binding<Bool>) {
        self.title = title
        self.symbol = symbol
        self.color = color
        _isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 12) {
                SettingsIcon(symbol: symbol, color: color)
                Text(title)
            }
        }
    }
}

/** Kleine überlappende Farbpunkte (Vorschau der gewählten Farben in der Übersicht). */
private struct ColorDots: View {
    let hexes: [UInt32]

    var body: some View {
        HStack(spacing: -6) {
            ForEach(Array(hexes.enumerated()), id: \.offset) { _, hex in
                Circle()
                    .fill(Color(hex: hex))
                    .frame(width: 18, height: 18)
                    .overlay(Circle().strokeBorder(Color(.systemBackground), lineWidth: 2))
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
            }
        }
    }
}

// MARK: - Karte

private struct MapSettingsPage: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Picker(selection: $settings.mapEngine) {
                    ForEach(MapEngine.allCases) { Text($0.label).tag($0) }
                } label: {
                    SettingsRow(title: "Karte", symbol: "map.fill", color: .green)
                }
                Picker(selection: $settings.mapTheme) {
                    ForEach(MapTheme.allCases) { Text($0.label).tag($0) }
                } label: {
                    SettingsRow(title: "Hell / Dunkel", symbol: "circle.lefthalf.filled", color: .indigo)
                }
            } footer: {
                if settings.mapEngine == .osm {
                    Text("Klassische OpenStreetMap-Karte: flach (ohne 3D-Neigung). Offline-Karten werden hier nicht angezeigt (der OSM-Server erlaubt keine Massen-Downloads) — Offline-Suche und Offline-Routing funktionieren trotzdem.")
                }
            }
            if settings.mapEngine == .osm {
                Section {
                    SettingToggle("Karte drehbar", symbol: "arrow.triangle.2.circlepath", color: .teal, isOn: $settings.osmRotatable)
                    SettingToggle("Kompass-Knopf", symbol: "safari.fill", color: .red, isOn: $settings.showCompassButton)
                } header: {
                    Text("Darstellung")
                } footer: {
                    Text("Drehbar: mit zwei Fingern drehen, in der Navigation zeigt die Karte in Fahrtrichtung. Aus = immer Norden oben. Beschriftungen drehen sich bei dieser Karte mit.")
                }
            }
            if settings.mapEngine == .vector {
                Section("Darstellung") {
                    SettingToggle("3D-Ansicht beim App-Start", symbol: "view.3d", color: .blue, isOn: $settings.start3D)
                    SettingToggle("3D-Gebäude", symbol: "building.2.fill", color: .brown, isOn: $settings.buildings3D)
                    SettingToggle("Straßennamen hervorheben", symbol: "textformat.size", color: .indigo, isOn: $settings.emphasizeStreetNames)
                    SettingToggle("Autobahnen breiter zeichnen", symbol: "road.lanes", color: .orange, isOn: $settings.widerMotorways)
                    SettingToggle("Kompass-Knopf", symbol: "safari.fill", color: .red, isOn: $settings.showCompassButton)
                }
            }
            Section {
                SettingToggle("Nur Offline-Karten verwenden", symbol: "map", color: .gray, isOn: $settings.offlineMapsOnly)
                    .disabled(settings.fullyOffline)
                SettingToggle("Komplett offline", symbol: "wifi.slash", color: .gray, isOn: $settings.fullyOffline)
            } header: {
                Text("Offline")
            } footer: {
                Text(settings.mapEngine == .osm && (settings.offlineMapsOnly || settings.fullyOffline)
                     ? "Achtung: Offline-Pakete gibt es nur für die Vektorkarte (MapLibre) — die OSM-Karte bleibt offline leer. Oben „MapLibre“ wählen."
                     : "Nur Offline-Karten: Die Karte lädt nichts aus dem Internet und zeigt nur heruntergeladene Gebiete (spart Datenvolumen). Komplett offline: auch Routing, Suche und Ort-Infos nur aus den Offline-Daten. Eigene Offline-Downloads funktionieren trotzdem.")
            }
            Section {
                SettingToggle("Position auf Straße einrasten", symbol: "road.lanes.curved.right", color: .blue, isOn: $settings.snapToRoad)
                SettingToggle("Kompass im Stand", symbol: "location.north.circle.fill", color: .teal, isOn: $settings.compassWhenIdle)
            } header: {
                Text("Standort")
            } footer: {
                Text("Einrasten: Der Pfeil sitzt auf der nächsten Straße statt an der ungenauen GPS-Position. Kompass: Im Stand zeigt der Pfeil in die Richtung, in die das iPhone zeigt.")
            }
        }
        .navigationTitle("Karte")
    }
}

// MARK: - Design & Farben

private struct DesignSettingsPage: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    @State private var confirmReset = false

    var body: some View {
        Form {
            Section {
                ThemePreview()
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            Section {
                ColorSettingRow(title: "Oberflächenfarbe", symbol: "paintbrush.fill", hex: $settings.accentHex.asOptional)
                ColorSettingRow(title: "Schrift auf Knöpfen", symbol: "textformat", hex: $settings.buttonTextHex,
                                autoHex: HexColor.contrastText(on: settings.accentHex))
                ColorSettingRow(title: "Text & Links", symbol: "link", hex: $settings.textTintHex,
                                autoHex: HexColor.readable(settings.accentHex, dark: colorScheme == .dark))
            } header: {
                Text("Oberfläche")
            } footer: {
                Text("Oberflächenfarbe = gefüllte Knöpfe. „Text & Links“ = Text-Knöpfe wie „Fertig“, Schalter und Auswahl. „Automatisch“ hält alle Schrift lesbar — auch bei Weiß oder Gelb.")
            }
            Section {
                ColorSettingRow(title: "Hintergrund", symbol: "rectangle.fill", hex: $settings.hudBackgroundHex,
                                autoHex: HexColor.darker(settings.accentHex))
                ColorSettingRow(title: "Schriftfarbe", symbol: "character", hex: $settings.hudTextHex,
                                autoHex: HexColor.contrastText(on: settings.resolvedHudBackgroundHex))
                SettingToggle("Große Schrift", symbol: "textformat.size.larger", color: .indigo, isOn: $settings.largeHud)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 12) {
                        SettingsIcon(symbol: "circle.lefthalf.filled", color: .gray)
                        Text("Deckkraft")
                        Spacer()
                        Text("\(Int((settings.hudOpacity * 100).rounded())) %").foregroundStyle(.secondary).monospacedDigit()
                    }
                    Slider(value: $settings.hudOpacity, in: 0.6...1)
                }
            } header: {
                Text("Navigationsleisten")
            }
            Section {
                ColorSettingRow(title: "Routenlinie", symbol: "point.topleft.down.curvedto.point.bottomright.up.fill", hex: $settings.routeHex.asOptional)
                ColorSettingRow(title: "Standort-Pfeil", symbol: "location.north.fill", hex: $settings.puckHex.asOptional)
            } header: {
                Text("Karte")
            }
            if LiquidGlass.isAvailable {
                Section {
                    SettingToggle("Liquid Glass", symbol: "drop.fill", color: .cyan, isOn: $settings.liquidGlass)
                } footer: {
                    Text("Gläserner Look von iOS 26 für Kartenknöpfe, Suchleiste, Panels und Navigationsleisten. Aus = klassischer Look wie unter iOS 16–18.")
                }
            }
            Section {
                Button("Farben zurücksetzen", role: .destructive) { confirmReset = true }
            }
        }
        .navigationTitle("Design & Farben")
        .confirmationDialog("Alle Farben auf Standard zurücksetzen?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Zurücksetzen", role: .destructive) { withAnimation { settings.resetColors() } }
        }
    }
}

/**
 * Eine Farbeinstellung: zeigt die aktuelle Farbe; aufgeklappt die Palette (inkl. Weiß/Schwarz),
 * „Automatisch“ (wenn [autoHex] gesetzt) und das Farbrad für jede beliebige Farbe.
 */
private struct ColorSettingRow: View {
    let title: String
    let symbol: String
    @Binding var hex: UInt32?
    /** Farbe im Automatik-Modus; nil = Einstellung hat keinen Automatik-Modus. */
    var autoHex: UInt32? = nil
    @State private var expanded = false

    private var current: UInt32 { hex ?? autoHex ?? 0 }
    private var currentName: String { hex == nil ? "Automatisch" : ColorPalette.name(of: current) }
    private let columns = [GridItem(.adaptive(minimum: 38, maximum: 46), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 12) {
                    // Symbol-Kästchen in der gewählten Farbe, Symbol in Kontrastfarbe (auch bei Weiß sichtbar).
                    SettingsIcon(symbol: symbol, color: Color(hex: current), foreground: Color(hex: HexColor.contrastText(on: current)))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Color.primary.opacity(HexColor.isLight(current) ? 0.25 : 0), lineWidth: 0.5))
                    Text(title).foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    Text(currentName).foregroundStyle(.secondary).lineLimit(1)
                    Circle()
                        .fill(Color(hex: current))
                        .frame(width: 24, height: 24)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                LazyVGrid(columns: columns, spacing: 10) {
                    if let autoHex {
                        Swatch(color: Color(hex: autoHex), selected: hex == nil, isAuto: true) { hex = nil }
                    }
                    ForEach(ColorPalette.swatches) { swatch in
                        Swatch(color: Color(hex: swatch.hex), selected: hex == swatch.hex, isAuto: false) { hex = swatch.hex }
                            .accessibilityLabel(swatch.name)
                    }
                }
                ColorPicker(selection: Binding(get: { Color(hex: current) }, set: { hex = $0.hexValue }), supportsOpacity: false) {
                    Label("Eigene Farbe aus dem Farbrad", systemImage: "eyedropper.halffull")
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/** Farbkreis der Palette; Häkchen in Kontrastfarbe, „A“ für Automatisch. */
private struct Swatch: View {
    let color: Color
    let selected: Bool
    let isAuto: Bool
    let action: () -> Void

    var body: some View {
        let hex = color.hexValue
        Button(action: action) {
            ZStack {
                Circle().fill(color)
                Circle().strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5)
                if isAuto {
                    Text("A").font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(hex: HexColor.contrastText(on: hex)))
                } else if selected {
                    Image(systemName: "checkmark").font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color(hex: HexColor.contrastText(on: hex)))
                }
            }
            .frame(width: 36, height: 36)
            .padding(3)
            .overlay(Circle().strokeBorder(selected ? Color.primary : .clear, lineWidth: 2.5))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/** Live-Vorschau: Mini-Karte mit Route und Standort-Pfeil, Navigationsleiste und Knopf in den gewählten Farben. */
private struct ThemePreview: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack(alignment: .top) {
            mapBackground
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.turn.up.right")
                        .font(.system(size: settings.largeHud ? 30 : 24, weight: .bold))
                    VStack(alignment: .leading, spacing: 0) {
                        Text("300 m").font(.system(size: settings.largeHud ? 24 : 20, weight: .bold))
                        Text("Rechts abbiegen auf Hauptstraße").font(.system(size: settings.largeHud ? 15 : 13, weight: .medium))
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(settings.hudText)
                .padding(12)
                .glassPanel(tint: settings.hudBackground.opacity(settings.hudOpacity), cornerRadius: 14)
                .padding(10)
                Spacer()
                HStack {
                    Toggle("", isOn: .constant(true)).labelsHidden().allowsHitTesting(false)
                    Text("Fertig").font(.subheadline.weight(.semibold)).foregroundStyle(.tint)
                    Spacer()
                    Text("Navigation starten")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(settings.buttonText)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(settings.accent, in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.primary.opacity(HexColor.isLight(settings.accentHex) ? 0.2 : 0), lineWidth: 0.5))
                }
                .padding(10)
            }
        }
        .frame(height: 230)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        .animation(.easeInOut(duration: 0.2), value: settings.accentHex)
    }

    /** Stilisierte Karte: Blöcke, Straßen, Route mit Umrandung, Standort-Pfeil. */
    private var mapBackground: some View {
        let dark = colorScheme == .dark
        return Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(dark ? Color(hex: 0x24272B) : Color(hex: 0xF2EFE9)))
            // Häuserblöcke
            let blockColor = dark ? Color(hex: 0x2F3338) : Color(hex: 0xE4DFD6)
            for (x, y, w, h) in [(0.05, 0.42, 0.3, 0.2), (0.45, 0.4, 0.22, 0.25), (0.75, 0.38, 0.22, 0.3), (0.05, 0.74, 0.3, 0.3), (0.72, 0.78, 0.25, 0.25)] {
                context.fill(Path(roundedRect: CGRect(x: x * size.width, y: y * size.height, width: w * size.width, height: h * size.height), cornerRadius: 4),
                             with: .color(blockColor))
            }
            // Straßen
            var streets = Path()
            streets.move(to: CGPoint(x: 0, y: size.height * 0.68))
            streets.addLine(to: CGPoint(x: size.width, y: size.height * 0.7))
            streets.move(to: CGPoint(x: size.width * 0.4, y: 0))
            streets.addLine(to: CGPoint(x: size.width * 0.38, y: size.height))
            streets.move(to: CGPoint(x: size.width * 0.7, y: size.height * 0.7))
            streets.addLine(to: CGPoint(x: size.width * 0.7, y: 0))
            context.stroke(streets, with: .color(dark ? Color(hex: 0x4A4F56) : .white), style: StrokeStyle(lineWidth: 12, lineCap: .round))
            // Route
            var route = Path()
            route.move(to: CGPoint(x: size.width * 0.39, y: size.height * 0.98))
            route.addLine(to: CGPoint(x: size.width * 0.385, y: size.height * 0.69))
            route.addLine(to: CGPoint(x: size.width * 0.7, y: size.height * 0.7))
            route.addLine(to: CGPoint(x: size.width * 0.7, y: size.height * 0.3))
            let routeColor = Color(hex: settings.routeHex)
            context.stroke(route, with: .color(Color(hex: HexColor.darker(settings.routeHex, by: 0.6))),
                           style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round))
            context.stroke(route, with: .color(routeColor), style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
            // Standort-Pfeil
            let center = CGPoint(x: size.width * 0.385, y: size.height * 0.82)
            let r: CGFloat = 13
            let lightPuck = HexColor.isLight(settings.puckHex)
            context.fill(Path(ellipseIn: CGRect(x: center.x - r - 3, y: center.y - r - 3, width: 2 * r + 6, height: 2 * r + 6)),
                         with: .color(lightPuck ? Color(hex: 0x333333) : .white))
            context.fill(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)), with: .color(Color(hex: settings.puckHex)))
            var arrow = Path()
            arrow.move(to: CGPoint(x: center.x, y: center.y - 8))
            arrow.addLine(to: CGPoint(x: center.x + 6, y: center.y + 7))
            arrow.addLine(to: CGPoint(x: center.x, y: center.y + 3))
            arrow.addLine(to: CGPoint(x: center.x - 6, y: center.y + 7))
            arrow.closeSubpath()
            context.fill(arrow, with: .color(Color(hex: HexColor.contrastText(on: settings.puckHex))))
        }
    }
}

// MARK: - Navigation

private struct NavigationSettingsPage: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Picker(selection: $settings.routingProfile) {
                    ForEach(RoutingProfile.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
                } label: {
                    SettingsRow(title: "Standard-Profil", symbol: settings.routingProfile.symbol, color: .blue)
                }
                SettingToggle("Alternativrouten anbieten", symbol: "arrow.triangle.branch", color: .teal, isOn: $settings.alternativeRoutes)
                SettingToggle("Routenvorschau", symbol: "list.bullet.rectangle.fill", color: .indigo, isOn: $settings.routePreviewEnabled)
            } header: {
                Text("Route")
            } footer: {
                Text("Routenvorschau: Anweisungsliste und Höhenprofil vor dem Start.")
            }
            Section {
                SettingToggle("Display bleibt an", symbol: "sun.max.fill", color: .yellow, isOn: $settings.keepScreenOn)
                SettingToggle("Zoom passt sich dem Tempo an", symbol: "plus.magnifyingglass", color: .green, isOn: $settings.autoZoom)
                SettingToggle("Fahrstreifen-Empfehlung", symbol: "arrow.up.and.down.and.arrow.left.and.right", color: .blue, isOn: $settings.laneGuidance)
                SettingToggle("Automatisch neu berechnen", symbol: "arrow.clockwise", color: .orange, isOn: $settings.autoReroute)
                SettingToggle("Sperrbildschirm & Dynamic Island", symbol: "lock.iphone", color: .indigo, isOn: $settings.liveActivityEnabled)
                SettingToggle("Navigations-Widget", symbol: "rectangle.3.group.fill", color: .purple, isOn: $settings.navWidgetEnabled)
                SettingToggle("Erinnern, wenn sich die geteilte Ankunft verschiebt", symbol: "clock.badge.exclamationmark", color: .teal, isOn: $settings.etaSharePrompt)
            } header: {
                Text("Während der Navigation")
            } footer: {
                Text("Neu berechnen: Weicht man mehr als 50 m von der Route ab, wird automatisch eine neue Route gesucht. Sperrbildschirm: nächstes Abbiegen, Entfernung und Ankunft ohne Entsperren — braucht in den iPhone-Einstellungen → LumoGo „Live-Aktivitäten“. Navigations-Widget (Ersatz für Bild-im-Bild): Homescreen lange drücken → „+“ → LumoGo → „LumoGo Navigation“ (klein, mittel, groß); zeigt Abbiegen, Ankunft und eine schematische Route, iOS aktualisiert es etwa alle 10 Sekunden. Ankunft teilen: Knopf in der unteren Navi-Leiste; verschiebt sich die Ankunft danach um mehr als 5 Minuten, erscheint „Neu teilen“.")
            }
            Section {
                SettingToggle("Strecke aufzeichnen", symbol: "point.topleft.down.curvedto.point.bottomright.up", color: .brown, isOn: $settings.recordTracks)
            } header: {
                Text("Fahrtenbuch")
            } footer: {
                Text("Speichert bei Ankunft die gefahrene Strecke mit Ø- und Höchstgeschwindigkeit — im Fahrtenbuch mit Karte und als GPX-Datei teilbar.")
            }
            Section {
                Label("„Hey Siri, mit LumoGo nach Hause“", systemImage: "house.fill")
                Label("„Navigiere mit LumoGo zu <Favorit>“", systemImage: "star.fill")
                Label("„Tankstellen in der Nähe mit LumoGo“", systemImage: "fuelpump.fill")
            } header: {
                Text("Siri & Widget")
            } footer: {
                Text("Funktioniert ohne Einrichtung, auch in der Kurzbefehle-App. Widget: Homescreen lange drücken → „+“ → LumoGo (auch für den Sperrbildschirm). „Nach Hause“ braucht ein gespeichertes Zuhause in den Favoriten.")
            }
            Section {
                Picker(selection: $settings.offlineRoadSource) {
                    ForEach(OfflineRoadSource.allCases) { Text($0.label).tag($0) }
                } label: {
                    SettingsRow(title: "Offline-Daten aus", symbol: "point.3.connected.trianglepath.dotted", color: .purple)
                }
                SettingToggle("Rad- und Fußwege mitladen", symbol: "figure.walk", color: .green, isOn: $settings.offlinePaths)
            } header: {
                Text("Offline-Routing")
            } footer: {
                Text("Gilt für Offline-Routing UND Offline-Suche. Kartenkacheln: in Sekunden fertig, auch für große Gebiete, Suche mit Adressen und Straßen; Routing ohne Abbiegeverbote und echte Tempolimits (Tempo nach Straßenart, innerorts 50). Overpass: genauere Routing-Daten, Suche nur mit benannten Orten (keine Adressen), aber der Server ist oft überlastet — klappt eine Quelle nicht, wird automatisch die andere versucht. Rad- und Fußwege aus: nur Straßen, kleiner und schneller, reicht fürs Auto; an: auch Feld-, Rad- und Fußwege fürs Fahrrad oder zu Fuß. Gilt für neu geladene Routing-Daten (Paket-Menü → „Routing-Daten aktualisieren“).")
            }
        }
        .navigationTitle("Navigation")
    }
}

// MARK: - Sprachausgabe

private struct VoiceSettingsPage: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var model: AppModel
    @State private var voices = SpeechService.germanVoices()

    var body: some View {
        Form {
            Section {
                SettingToggle("Sprachansagen", symbol: "speaker.wave.2.fill", color: .orange, isOn: $settings.voiceEnabled)
            }
            Section {
                Picker(selection: $settings.voiceIdentifier) {
                    Text("Automatisch (beste verfügbare)").tag("")
                    ForEach(voices) { voice in
                        Text("\(voice.name) · \(voice.qualityLabel)").tag(voice.id)
                    }
                } label: {
                    SettingsRow(title: "Stimme", symbol: "person.wave.2.fill", color: .pink)
                }
                SliderRow(title: "Tempo", symbol: "speedometer", color: .blue, minIcon: "tortoise", maxIcon: "hare") {
                    Slider(value: $settings.speechRate, in: 0.4...0.62)
                }
                SliderRow(title: "Lautstärke", symbol: "speaker.fill", color: .gray, minIcon: "speaker.fill", maxIcon: "speaker.wave.3.fill") {
                    Slider(value: $settings.speechVolume, in: 0.2...1)
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
                SettingToggle("Vorankündigungen", symbol: "megaphone.fill", color: .orange, isOn: $settings.preAnnouncements)
                SettingToggle("„Danach …“-Hinweise", symbol: "arrow.turn.down.right", color: .teal, isOn: $settings.chainAnnouncements)
                SettingToggle("Musik während Ansagen leiser", symbol: "music.note", color: .red, isOn: $settings.duckMusic)
                SettingToggle("Lautstärke passt sich dem Tempo an", symbol: "speaker.wave.3.fill", color: .blue, isOn: $settings.speedAdaptiveVolume)
            } header: {
                Text("Ansagen")
            } footer: {
                Text("Vorankündigungen: in 1 km, 500 m und 200 m (auf der Autobahn 2 km, 1 km, 500 m). Lautstärke nach Tempo: in der Stadt etwas leiser, ab 100 km/h volle eingestellte Lautstärke — lauter als die iPhone-Lautstärke geht nicht.")
            }
            .disabled(!settings.voiceEnabled)
        }
        .onAppear { voices = SpeechService.germanVoices() }
        .navigationTitle("Sprachausgabe")
    }
}

/** Schieberegler-Zeile mit Symbol-Kästchen und Symbolen an den Enden. */
private struct SliderRow<S: View>: View {
    let title: String
    let symbol: String
    let color: Color
    let minIcon: String
    let maxIcon: String
    @ViewBuilder let slider: S

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                SettingsIcon(symbol: symbol, color: color)
                Text(title)
            }
            HStack {
                Image(systemName: minIcon).foregroundStyle(.secondary)
                slider
                Image(systemName: maxIcon).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Tempolimit

private struct SpeedSettingsPage: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    SpeedLimitSign(limit: .kmh(50), size: 50)
                    SpeedLimitSign(limit: .kmh(100), size: 50)
                    SpeedLimitSign(limit: .unlimited, size: 50)
                    // So sieht die eigene Geschwindigkeit aus, wenn man zu schnell ist.
                    VStack(spacing: -2) {
                        Text("57").font(.system(size: 22, weight: .bold, design: .rounded))
                        Text("km/h").font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(Color(hex: HexColor.contrastText(on: settings.speedingHex)))
                    .frame(width: 54, height: 50)
                    .background(Color(hex: settings.speedingHex), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            Section {
                SettingToggle("Tempolimit-Schild anzeigen", symbol: "exclamationmark.octagon.fill", color: .red, isOn: $settings.showSpeedLimit)
                SettingToggle("Eigene Geschwindigkeit anzeigen", symbol: "speedometer", color: .blue, isOn: $settings.showCurrentSpeed)
                if settings.showCurrentSpeed {
                    SettingToggle("Auch ohne Navigation", symbol: "car.fill", color: .gray, isOn: $settings.speedInFreeMode)
                }
            } footer: {
                Text("Unten links. Das Tempolimit-Schild gibt es während der Navigation mit dem Auto. Das Limit stammt aus OpenStreetMap — fehlt es dort, bleibt das Schild weg. Ohne Gewähr, Verkehrszeichen gehen immer vor.")
            }
            Section {
                ColorSettingRow(title: "Rand des Schilds", symbol: "circle.circle", hex: $settings.speedSignHex.asOptional)
                ColorSettingRow(title: "Anzeige bei „zu schnell“", symbol: "gauge.high", hex: $settings.speedingHex.asOptional)
            } header: {
                Text("Farben")
            }
            Section {
                SettingToggle("Ansage bei Überschreitung", symbol: "speaker.badge.exclamationmark.fill", color: .orange, isOn: $settings.speedWarning)
                Stepper(value: $settings.speedTolerance, in: 0...15) {
                    SettingsRow(title: "Toleranz", symbol: "plusminus", color: .gray, value: "\(settings.speedTolerance) km/h")
                }
            } header: {
                Text("Warnung")
            } footer: {
                Text("Erst ab Limit + Toleranz wird die Geschwindigkeit eingefärbt und es kommt „Achtung, Tempolimit …“. GPS misst die echte Geschwindigkeit — der Tacho zeigt meist ein paar km/h mehr.")
            }
            .disabled(!settings.showSpeedLimit)
        }
        .navigationTitle("Tempolimit")
    }
}

// MARK: - Suche & Orte

private struct SearchSettingsPage: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var cleared = false

    var body: some View {
        Form {
            Section {
                SettingToggle("Orte auf der Karte antippbar", symbol: "hand.tap.fill", color: .purple, isOn: $settings.poiTapEnabled)
                SettingToggle("„Geöffnet/Geschlossen“ in Listen", symbol: "clock.fill", color: .green, isOn: $settings.showOpenStatus)
            } header: {
                Text("Orte")
            } footer: {
                Text("Antippen zeigt Öffnungszeiten, Adresse, Telefon und Website aus OpenStreetMap.")
            }
            Section {
                SettingToggle("Suchverlauf anzeigen", symbol: "clock.arrow.circlepath", color: .blue, isOn: $settings.recentSearchesEnabled)
                Button(role: .destructive) {
                    RecentSearchesStore.clear()
                    cleared = true
                } label: {
                    SettingsRow(title: cleared ? "Suchverlauf gelöscht" : "Suchverlauf löschen", symbol: "trash.fill", color: .red)
                        .foregroundStyle(cleared ? Color.secondary : Color.red)
                }
                .disabled(cleared)
            } header: {
                Text("Suche")
            }
            FuelPriceSection()
        }
        .navigationTitle("Suche & Orte")
    }
}

/** Spritpreise über Tankerkönig: eigener Schlüssel, Sorte, Sortierung. */
private struct FuelPriceSection: View {
    @EnvironmentObject private var settings: AppSettings

    private var hasKey: Bool { !settings.tankerkoenigKey.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        Section {
            HStack(spacing: 12) {
                SettingsIcon(symbol: "key.fill", color: .orange)
                TextField("API-Schlüssel (kostenlos)", text: $settings.tankerkoenigKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.footnote.monospaced())
                if hasKey {
                    Button { settings.tankerkoenigKey = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
            }
            if !hasKey {
                Link(destination: TankerkoenigClient.signupURL) {
                    Label("Kostenlosen Schlüssel holen", systemImage: "arrow.up.right.square")
                }
                Button {
                    settings.tankerkoenigKey = TankerkoenigClient.demoKey
                } label: {
                    Label("Zum Ausprobieren: Demo-Schlüssel", systemImage: "testtube.2")
                }
            }
            Picker(selection: $settings.fuelType) {
                ForEach(FuelType.allCases) { Text($0.label).tag($0) }
            } label: {
                SettingsRow(title: "Sorte", symbol: "fuelpump.fill", color: .green)
            }
            .disabled(!hasKey)
            SettingToggle("Günstigste zuerst", symbol: "eurosign.circle.fill", color: .blue, isOn: $settings.fuelSortByPrice)
                .disabled(!hasKey)
        } header: {
            Text("Spritpreise")
        } footer: {
            Text("„In der Nähe“ → Tankstelle zeigt dann die aktuellen Preise (10 km, nur Deutschland). Ohne Schlüssel: Tankstellen aus OpenStreetMap ohne Preise. Der Demo-Schlüssel liefert echte Tankstellen, aber Fantasiepreise. Daten: Tankerkönig / MTS-K, Lizenz CC BY 4.0.")
        }
    }
}

private extension Binding where Value == UInt32 {
    /** Pflichtfarbe als optionale Bindung (die Zeile bietet dann kein „Automatisch“ an). */
    var asOptional: Binding<UInt32?> {
        Binding<UInt32?>(get: { wrappedValue }, set: { if let value = $0 { wrappedValue = value } })
    }
}
