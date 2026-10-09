import SwiftUI

/**
 * Karten-Engine wie auf Android: Vektorkarte (MapLibre/OpenFreeMap, 3D) oder klassische
 * OpenStreetMap-Rasterkacheln (2D, immer nordausgerichtet — dort mit osmdroid umgesetzt; auf iOS
 * zeigt MapLibre dieselben tile.openstreetmap.org-Kacheln, damit Route/Navigation nicht doppelt
 * implementiert werden müssen).
 */
enum MapEngine: String, CaseIterable, Identifiable {
    case vector, osm
    var id: String { rawValue }

    var label: String {
        switch self {
        case .vector: return "MapLibre (3D, Vektor)"
        case .osm: return "OpenStreetMap (klassisch)"
        }
    }

    /** Klassische OSM-Karte ist bewusst nur 2D und nordausgerichtet (wie osmdroid auf Android). */
    var supports3D: Bool { self == .vector }
}

enum MapTheme: String, CaseIterable, Identifiable {
    case light, dark, system
    var id: String { rawValue }

    var label: String {
        switch self {
        case .light: return "Hell"
        case .dark: return "Dunkel"
        case .system: return "Systemeinstellung"
        }
    }

    /** Erzwingt das passende Farbschema für die gesamte UI — damit Suchleiste & Co. immer zum
     *  gewählten Kartendesign passen (auf Android war das ein eigener Bug, siehe CLAUDE.md). */
    var colorScheme: ColorScheme? {
        switch self {
        case .light: return .light
        case .dark: return .dark
        case .system: return nil
        }
    }
}

/**
 * Farbpalette für ALLE Farbeinstellungen (Oberfläche, Navigationsleisten, Schrift, Route, Pfeil) —
 * inkl. Weiß und Schwarz; dazu ist jede Farbe über das Farbrad frei wählbar.
 */
enum ColorPalette {
    struct Swatch: Identifiable {
        let name: String
        let hex: UInt32
        var id: UInt32 { hex }
    }

    static let swatches: [Swatch] = [
        Swatch(name: "Weiß", hex: 0xFFFFFF),
        Swatch(name: "Grau", hex: 0x8E8E93),
        Swatch(name: "Schwarz", hex: 0x1C1C1E),
        Swatch(name: "Rot", hex: 0xD32F2F),
        Swatch(name: "Orange", hex: 0xF57C00),
        Swatch(name: "Gelb", hex: 0xFBC02D),
        Swatch(name: "Grün", hex: 0x2E7D32),
        Swatch(name: "Mint", hex: 0x00BFA5),
        Swatch(name: "Türkis", hex: 0x00838F),
        Swatch(name: "Hellblau", hex: 0x29B6F6),
        Swatch(name: "Blau", hex: 0x2962FF),
        Swatch(name: "Indigo", hex: 0x3949AB),
        Swatch(name: "Lila", hex: 0x7B3FE4),
        Swatch(name: "Pink", hex: 0xE91E8C),
        Swatch(name: "Braun", hex: 0x795548),
    ]

    /** Name der Farbe, falls sie in der Palette ist (sonst „Eigene Farbe“). */
    static func name(of hex: UInt32) -> String {
        swatches.first { $0.hex == hex }?.name ?? "Eigene Farbe"
    }
}

/** Farbwert-Helfer (0xRRGGBB). */
enum HexColor {
    /** Relative Helligkeit 0…1 (WCAG). */
    static func luminance(_ hex: UInt32) -> Double {
        func channel(_ v: UInt32) -> Double {
            let c = Double(v & 0xFF) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(hex >> 16) + 0.7152 * channel(hex >> 8) + 0.0722 * channel(hex)
    }

    static func isLight(_ hex: UInt32) -> Bool { luminance(hex) > 0.45 }

    /** Gut lesbare Schrift auf dieser Farbe: Schwarz auf hellen, Weiß auf dunklen Flächen. */
    static func contrastText(on hex: UInt32) -> UInt32 { isLight(hex) ? 0x1C1C1E : 0xFFFFFF }

    /** Kontrastverhältnis nach WCAG (1…21). */
    static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /** Hellere Variante (Richtung Weiß gemischt). */
    static func lighter(_ hex: UInt32, by amount: Double = 0.2) -> UInt32 {
        func mix(_ v: UInt32) -> UInt32 { UInt32((Double(v & 0xFF) + (255 - Double(v & 0xFF)) * amount).rounded()) }
        return mix(hex >> 16) << 16 | mix(hex >> 8) << 8 | mix(hex)
    }

    /**
     * [hex] als Schrift-/Linkfarbe auf dem Systemhintergrund (hell: Weiß, dunkel: fast Schwarz) gut
     * lesbar gemacht: so lange abdunkeln bzw. aufhellen, bis der Kontrast ≥ 3 ist. Sonst wurden bei
     * weißer/gelber Oberflächenfarbe „Fertig“, „Abbrechen“ & Co. unsichtbar (Nutzermeldung).
     */
    static func readable(_ hex: UInt32, dark: Bool) -> UInt32 {
        let background: UInt32 = dark ? 0x1C1C1E : 0xFFFFFF
        var color = hex
        for _ in 0..<20 where contrast(color, background) < 3 {
            color = dark ? lighter(color) : darker(color, by: 0.85)
        }
        return color
    }

    /** Dunklere Variante (Navigationsleisten im Automatik-Modus). */
    static func darker(_ hex: UInt32, by factor: Double = 0.65) -> UInt32 {
        let r = UInt32(Double((hex >> 16) & 0xFF) * factor), g = UInt32(Double((hex >> 8) & 0xFF) * factor), b = UInt32(Double(hex & 0xFF) * factor)
        return r << 16 | g << 8 | b
    }
}

/** UserDefaults-Schlüssel der Farben (auch von `@AppStorage` in Glass.swift gelesen). */
enum ColorKeys {
    static let accent = "ui_accent_hex"
    static let hudBackground = "hud_background_hex"
    static let hudText = "hud_text_hex"
    static let buttonText = "button_text_hex"
    /** Text-Knöpfe, Links, Schalter (Systemfarbe `tint`); -1 = automatisch lesbar gemachte Oberflächenfarbe. */
    static let textTint = "text_tint_hex"
    static let route = "route_hex"
    static let puck = "puck_hex"
    static let speedSign = "speed_sign_hex"
    static let speeding = "speeding_hex"
    /** Wert für „Automatisch“ bei den optionalen Farben. */
    static let auto = -1

    static let defaultAccent: UInt32 = 0x2E7D32
    static let defaultRoute: UInt32 = 0x2962FF
    static let defaultPuck: UInt32 = 0x2962FF
    /** Rand des Tempolimit-Schilds (Verkehrszeichen-Rot). */
    static let defaultSpeedSign: UInt32 = 0xCC0D0D
    /** Geschwindigkeits-Anzeige bei Überschreitung. */
    static let defaultSpeeding: UInt32 = 0xD32F2F

    /** Schrift auf Knöpfen in Oberflächenfarbe — gewählt oder automatisch passend zur Oberflächenfarbe. */
    static func buttonText(accent: Int, buttonText: Int) -> UInt32 {
        buttonText >= 0 ? UInt32(buttonText) : HexColor.contrastText(on: UInt32(accent))
    }

    /** Alte Einstellungen (feste Farbnamen bis 0.0.1) → Farbwert. */
    static func migrateAccent(_ name: String?) -> UInt32? {
        ["green": 0x2E7D32, "blue": 0x1565C0, "teal": 0x00796B, "purple": 0x6A1B9A, "red": 0xC62828, "orange": 0xE65100][name ?? ""]
    }

    static func migrateMapColor(_ name: String?) -> UInt32? {
        ["blue": 0x2962FF, "green": 0x2E9E3E, "teal": 0x00A3A3, "purple": 0x7B3FE4, "orange": 0xF57C00,
         "red": 0xD32F2F, "pink": 0xE91E8C, "black": 0x263238][name ?? ""]
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    /** Farbwert 0xRRGGBB (sRGB, auf 0…1 begrenzt — das Farbrad kann P3-Farben liefern). */
    var hexValue: UInt32 {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        func byte(_ v: CGFloat) -> UInt32 { UInt32((min(max(v, 0), 1) * 255).rounded()) }
        return byte(r) << 16 | byte(g) << 8 | byte(b)
    }
}

/** Alle Einstellungen der App, persistiert in UserDefaults. */
final class AppSettings: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var mapEngine: MapEngine { didSet { defaults.set(mapEngine.rawValue, forKey: "map_engine") } }
    @Published var mapTheme: MapTheme { didSet { defaults.set(mapTheme.rawValue, forKey: "map_theme") } }
    /** Oberflächenfarbe (Knöpfe, Schalter, Auswahl). */
    @Published var accentHex: UInt32 { didSet { defaults.set(Int(accentHex), forKey: ColorKeys.accent) } }
    @Published var routePreviewEnabled: Bool { didSet { defaults.set(routePreviewEnabled, forKey: "route_preview") } }
    @Published var recentSearchesEnabled: Bool { didSet { defaults.set(recentSearchesEnabled, forKey: "recent_searches") } }
    @Published var routingProfile: RoutingProfile { didSet { defaults.set(routingProfile.rawValue, forKey: "routing_profile") } }
    @Published var emphasizeStreetNames: Bool { didSet { defaults.set(emphasizeStreetNames, forKey: "emphasize_street_names") } }
    /** Gewählte Navigationsstimme; leer = automatisch die beste installierte deutsche Stimme. */
    @Published var voiceIdentifier: String { didSet { defaults.set(voiceIdentifier, forKey: "voice_identifier") } }
    @Published var speechRate: Float { didSet { defaults.set(speechRate, forKey: "speech_rate") } }
    /** Tempolimit-Schild + aktuelle Geschwindigkeit während der Navigation. */
    @Published var showSpeedLimit: Bool { didSet { defaults.set(showSpeedLimit, forKey: "show_speed_limit") } }
    /** Ansage „Tempolimit 50“ bei Überschreitung. */
    @Published var speedWarning: Bool { didSet { defaults.set(speedWarning, forKey: "speed_warning") } }
    @Published var showCurrentSpeed: Bool { didSet { defaults.set(showCurrentSpeed, forKey: "show_current_speed") } }
    /** Geschwindigkeit auch ohne laufende Navigation anzeigen. */
    @Published var speedInFreeMode: Bool { didSet { defaults.set(speedInFreeMode, forKey: "speed_free_mode") } }
    /** Erst ab Limit + Toleranz gilt man als zu schnell (km/h). */
    @Published var speedTolerance: Int { didSet { defaults.set(speedTolerance, forKey: "speed_tolerance") } }

    // Karte
    @Published var start3D: Bool { didSet { defaults.set(start3D, forKey: "start_3d") } }
    @Published var buildings3D: Bool { didSet { defaults.set(buildings3D, forKey: "buildings_3d") } }
    @Published var widerMotorways: Bool { didSet { defaults.set(widerMotorways, forKey: "wider_motorways") } }
    @Published var poiTapEnabled: Bool { didSet { defaults.set(poiTapEnabled, forKey: "poi_tap") } }
    @Published var snapToRoad: Bool { didSet { defaults.set(snapToRoad, forKey: "snap_to_road") } }
    @Published var compassWhenIdle: Bool { didSet { defaults.set(compassWhenIdle, forKey: "compass_idle") } }
    @Published var showCompassButton: Bool { didSet { defaults.set(showCompassButton, forKey: "show_compass_button") } }
    @Published var osmRotatable: Bool { didSet { defaults.set(osmRotatable, forKey: "osm_rotatable") } }

    // Design
    @Published var routeHex: UInt32 { didSet { defaults.set(Int(routeHex), forKey: ColorKeys.route) } }
    @Published var puckHex: UInt32 { didSet { defaults.set(Int(puckHex), forKey: ColorKeys.puck) } }
    /** Rand des Tempolimit-Schilds (von `SpeedLimitSign` per `@AppStorage` gelesen). */
    @Published var speedSignHex: UInt32 { didSet { defaults.set(Int(speedSignHex), forKey: ColorKeys.speedSign) } }
    /** Farbe der Geschwindigkeits-Anzeige, wenn man zu schnell ist. */
    @Published var speedingHex: UInt32 { didSet { defaults.set(Int(speedingHex), forKey: ColorKeys.speeding) } }
    /** Hintergrund der Navigationsleisten; nil = automatisch (dunklere Oberflächenfarbe). */
    @Published var hudBackgroundHex: UInt32? { didSet { defaults.set(hudBackgroundHex.map(Int.init) ?? ColorKeys.auto, forKey: ColorKeys.hudBackground) } }
    /** Schrift in den Navigationsleisten; nil = automatisch (Kontrast zum Hintergrund). */
    @Published var hudTextHex: UInt32? { didSet { defaults.set(hudTextHex.map(Int.init) ?? ColorKeys.auto, forKey: ColorKeys.hudText) } }
    /** Text-Knöpfe („Fertig“), Links und Schalter; nil = automatisch (Oberflächenfarbe, lesbar gemacht). */
    @Published var textTintHex: UInt32? { didSet { defaults.set(textTintHex.map(Int.init) ?? ColorKeys.auto, forKey: ColorKeys.textTint) } }
    /** Schrift auf Knöpfen in Oberflächenfarbe; nil = automatisch. */
    @Published var buttonTextHex: UInt32? { didSet { defaults.set(buttonTextHex.map(Int.init) ?? ColorKeys.auto, forKey: ColorKeys.buttonText) } }
    /** Deckkraft der Navigationsleisten (0,6–1). */
    @Published var hudOpacity: Double { didSet { defaults.set(hudOpacity, forKey: "hud_opacity") } }
    @Published var largeHud: Bool { didSet { defaults.set(largeHud, forKey: "large_hud") } }
    /** Nur wirksam ab iOS 26 (und mit Xcode 26 gebaut), siehe `LiquidGlass`. */
    @Published var liquidGlass: Bool { didSet { defaults.set(liquidGlass, forKey: LiquidGlass.settingsKey) } }

    // Navigation
    @Published var keepScreenOn: Bool { didSet { defaults.set(keepScreenOn, forKey: "keep_screen_on") } }
    @Published var autoZoom: Bool { didSet { defaults.set(autoZoom, forKey: "auto_zoom") } }
    @Published var laneGuidance: Bool { didSet { defaults.set(laneGuidance, forKey: "lane_guidance") } }
    /** Pfeil gleitet zwischen den GPS-Fixes, Kamera fährt Bild für Bild mit. */
    @Published var smoothPuck: Bool { didSet { defaults.set(smoothPuck, forKey: "smooth_puck") } }
    /** Pfeil in der Navigation weiter unten im Bild (wie Google Maps). */
    @Published var navPuckLow: Bool { didSet { defaults.set(navPuckLow, forKey: "nav_puck_low") } }
    /** Namensleiste der aktuellen Straße unten in der Navigation. */
    @Published var showRoadName: Bool { didSet { defaults.set(showRoadName, forKey: "show_road_name") } }
    @Published var autoReroute: Bool { didSet { defaults.set(autoReroute, forKey: "auto_reroute") } }
    @Published var alternativeRoutes: Bool { didSet { defaults.set(alternativeRoutes, forKey: "alternative_routes") } }
    /** Offline-Straßennetz inkl. reiner Rad-/Fußwege (≈2,7× Daten, deutlich langsamer). */
    @Published var offlinePaths: Bool { didSet { defaults.set(offlinePaths, forKey: "offline_paths") } }
    /** Quelle des Offline-Straßennetzes (Kartenkacheln oder Overpass). */
    @Published var offlineRoadSource: OfflineRoadSource { didSet { defaults.set(offlineRoadSource.rawValue, forKey: OfflineRoadSource.settingsKey) } }
    /** Karte nur aus Offline-Paketen (siehe NetworkPolicy). */
    @Published var offlineMapsOnly: Bool { didSet { defaults.set(offlineMapsOnly, forKey: NetworkPolicy.offlineMapsKey) } }
    /** Gar keine Internetanfragen (Routing/Suche nur offline). */
    @Published var fullyOffline: Bool { didSet { defaults.set(fullyOffline, forKey: NetworkPolicy.fullyOfflineKey) } }

    // Sprachausgabe
    @Published var voiceEnabled: Bool { didSet { defaults.set(voiceEnabled, forKey: "voice_enabled") } }
    @Published var speechVolume: Float { didSet { defaults.set(speechVolume, forKey: "speech_volume") } }
    @Published var preAnnouncements: Bool { didSet { defaults.set(preAnnouncements, forKey: "pre_announcements") } }
    @Published var chainAnnouncements: Bool { didSet { defaults.set(chainAnnouncements, forKey: "chain_announcements") } }
    @Published var duckMusic: Bool { didSet { defaults.set(duckMusic, forKey: "duck_music") } }

    /** Navigation auf Sperrbildschirm + Dynamic Island (Live-Aktivität). */
    @Published var liveActivityEnabled: Bool { didSet { defaults.set(liveActivityEnabled, forKey: "live_activity") } }
    /** Nach dem Teilen der Ankunftszeit erinnern, wenn sie sich um > 5 min verschiebt. */
    @Published var etaSharePrompt: Bool { didSet { defaults.set(etaSharePrompt, forKey: "eta_share_prompt") } }
    /** „Auf der Route suchen“: wie weit voraus (km) und wie weit neben der Route (m). */
    @Published var alongRouteKm: Int { didSet { defaults.set(alongRouteKm, forKey: "along_route_km") } }
    @Published var alongRouteCorridor: Int { didSet { defaults.set(alongRouteCorridor, forKey: "along_route_corridor") } }
    /** Wetter entlang der Route im Routen-Panel (Open-Meteo). */
    @Published var routeWeather: Bool { didSet { defaults.set(routeWeather, forKey: "route_weather") } }
    /** Wetter-Knopf rechts auf der Karte (hier jetzt/in 1 Stunde + auf der Strecke). */
    @Published var weatherButton: Bool { didSet { defaults.set(weatherButton, forKey: "weather_button") } }
    /** Originalspur einer GPX-Tour gestrichelt auf der Karte. */
    @Published var showTourTrack: Bool { didSet { defaults.set(showTourTrack, forKey: "show_tour_track") } }
    /** Navigations-Widget (Homescreen) mit Daten versorgen — Ersatz für Bild-im-Bild. */
    @Published var navWidgetEnabled: Bool { didSet { defaults.set(navWidgetEnabled, forKey: "nav_widget") } }
    /** Gefahrene Strecke + Tempo im Fahrtenbuch speichern (GPX-Export). */
    @Published var recordTracks: Bool { didSet { defaults.set(recordTracks, forKey: "record_tracks") } }
    /** Ansagen in der Stadt etwas leiser, auf der Autobahn voll laut. */
    @Published var speedAdaptiveVolume: Bool { didSet { defaults.set(speedAdaptiveVolume, forKey: "speed_volume") } }

    // Suche & Orte
    @Published var showOpenStatus: Bool { didSet { defaults.set(showOpenStatus, forKey: "show_open_status") } }
    /** Eigener Tankerkönig-API-Schlüssel; leer = Tankstellen ohne Preise (OpenStreetMap). */
    @Published var tankerkoenigKey: String { didSet { defaults.set(tankerkoenigKey, forKey: "tankerkoenig_key") } }
    @Published var fuelType: FuelType { didSet { defaults.set(fuelType.rawValue, forKey: "fuel_type") } }
    @Published var fuelSortByPrice: Bool { didSet { defaults.set(fuelSortByPrice, forKey: "fuel_sort_price") } }

    init() {
        mapEngine = MapEngine(rawValue: defaults.string(forKey: "map_engine") ?? "") ?? .vector
        mapTheme = MapTheme(rawValue: defaults.string(forKey: "map_theme") ?? "") ?? .system
        accentHex = Self.storedColor(ColorKeys.accent, legacy: ColorKeys.migrateAccent(defaults.string(forKey: "ui_accent_color")), default: ColorKeys.defaultAccent)
        routePreviewEnabled = defaults.object(forKey: "route_preview") as? Bool ?? true
        recentSearchesEnabled = defaults.object(forKey: "recent_searches") as? Bool ?? true
        routingProfile = RoutingProfile(rawValue: defaults.string(forKey: "routing_profile") ?? "") ?? .car
        emphasizeStreetNames = defaults.object(forKey: "emphasize_street_names") as? Bool ?? true
        voiceIdentifier = defaults.string(forKey: "voice_identifier") ?? ""
        speechRate = defaults.object(forKey: "speech_rate") as? Float ?? SpeechService.defaultRate
        showSpeedLimit = defaults.object(forKey: "show_speed_limit") as? Bool ?? true
        speedWarning = defaults.object(forKey: "speed_warning") as? Bool ?? true
        showCurrentSpeed = defaults.object(forKey: "show_current_speed") as? Bool ?? true
        speedInFreeMode = defaults.object(forKey: "speed_free_mode") as? Bool ?? true
        speedTolerance = defaults.object(forKey: "speed_tolerance") as? Int ?? 3
        start3D = defaults.object(forKey: "start_3d") as? Bool ?? true
        buildings3D = defaults.object(forKey: "buildings_3d") as? Bool ?? true
        widerMotorways = defaults.object(forKey: "wider_motorways") as? Bool ?? true
        poiTapEnabled = defaults.object(forKey: "poi_tap") as? Bool ?? true
        snapToRoad = defaults.object(forKey: "snap_to_road") as? Bool ?? true
        compassWhenIdle = defaults.object(forKey: "compass_idle") as? Bool ?? true
        showCompassButton = defaults.object(forKey: "show_compass_button") as? Bool ?? true
        osmRotatable = defaults.object(forKey: "osm_rotatable") as? Bool ?? true
        routeHex = Self.storedColor(ColorKeys.route, legacy: ColorKeys.migrateMapColor(defaults.string(forKey: "route_color")), default: ColorKeys.defaultRoute)
        puckHex = Self.storedColor(ColorKeys.puck, legacy: ColorKeys.migrateMapColor(defaults.string(forKey: "puck_color")), default: ColorKeys.defaultPuck)
        speedSignHex = Self.storedColor(ColorKeys.speedSign, legacy: nil, default: ColorKeys.defaultSpeedSign)
        speedingHex = Self.storedColor(ColorKeys.speeding, legacy: nil, default: ColorKeys.defaultSpeeding)
        hudBackgroundHex = Self.optionalColor(ColorKeys.hudBackground)
        hudTextHex = Self.optionalColor(ColorKeys.hudText)
        buttonTextHex = Self.optionalColor(ColorKeys.buttonText)
        textTintHex = Self.optionalColor(ColorKeys.textTint)
        hudOpacity = defaults.object(forKey: "hud_opacity") as? Double ?? 0.88
        largeHud = defaults.object(forKey: "large_hud") as? Bool ?? false
        liquidGlass = defaults.object(forKey: LiquidGlass.settingsKey) as? Bool ?? true
        keepScreenOn = defaults.object(forKey: "keep_screen_on") as? Bool ?? true
        autoZoom = defaults.object(forKey: "auto_zoom") as? Bool ?? true
        laneGuidance = defaults.object(forKey: "lane_guidance") as? Bool ?? true
        smoothPuck = defaults.object(forKey: "smooth_puck") as? Bool ?? true
        navPuckLow = defaults.object(forKey: "nav_puck_low") as? Bool ?? true
        showRoadName = defaults.object(forKey: "show_road_name") as? Bool ?? true
        autoReroute = defaults.object(forKey: "auto_reroute") as? Bool ?? true
        alternativeRoutes = defaults.object(forKey: "alternative_routes") as? Bool ?? true
        offlinePaths = defaults.object(forKey: "offline_paths") as? Bool ?? false
        offlineRoadSource = OfflineRoadSource.current
        offlineMapsOnly = defaults.bool(forKey: NetworkPolicy.offlineMapsKey)
        fullyOffline = defaults.bool(forKey: NetworkPolicy.fullyOfflineKey)
        voiceEnabled = defaults.object(forKey: "voice_enabled") as? Bool ?? true
        speechVolume = defaults.object(forKey: "speech_volume") as? Float ?? 1
        preAnnouncements = defaults.object(forKey: "pre_announcements") as? Bool ?? true
        chainAnnouncements = defaults.object(forKey: "chain_announcements") as? Bool ?? true
        duckMusic = defaults.object(forKey: "duck_music") as? Bool ?? true
        showOpenStatus = defaults.object(forKey: "show_open_status") as? Bool ?? true
        liveActivityEnabled = defaults.object(forKey: "live_activity") as? Bool ?? true
        etaSharePrompt = defaults.object(forKey: "eta_share_prompt") as? Bool ?? true
        recordTracks = defaults.object(forKey: "record_tracks") as? Bool ?? true
        navWidgetEnabled = defaults.object(forKey: "nav_widget") as? Bool ?? true
        alongRouteKm = defaults.object(forKey: "along_route_km") as? Int ?? 50
        alongRouteCorridor = defaults.object(forKey: "along_route_corridor") as? Int ?? 600
        routeWeather = defaults.object(forKey: "route_weather") as? Bool ?? true
        weatherButton = defaults.object(forKey: "weather_button") as? Bool ?? true
        showTourTrack = defaults.object(forKey: "show_tour_track") as? Bool ?? true
        speedAdaptiveVolume = defaults.object(forKey: "speed_volume") as? Bool ?? true
        tankerkoenigKey = defaults.string(forKey: "tankerkoenig_key") ?? ""
        fuelType = FuelType(rawValue: defaults.string(forKey: "fuel_type") ?? "") ?? .e10
        fuelSortByPrice = defaults.object(forKey: "fuel_sort_price") as? Bool ?? true
    }

    // MARK: - Farben

    var accent: Color { Color(hex: accentHex) }
    var resolvedHudBackgroundHex: UInt32 { hudBackgroundHex ?? HexColor.darker(accentHex) }
    var hudBackground: Color { Color(hex: resolvedHudBackgroundHex) }
    var hudText: Color { Color(hex: hudTextHex ?? HexColor.contrastText(on: resolvedHudBackgroundHex)) }
    /** Farbe für Text-Knöpfe/Links/Schalter im jeweiligen Farbschema. */
    func textTintHex(dark: Bool) -> UInt32 { textTintHex ?? HexColor.readable(accentHex, dark: dark) }
    var buttonText: Color { Color(hex: ColorKeys.buttonText(accent: Int(accentHex), buttonText: buttonTextHex.map(Int.init) ?? ColorKeys.auto)) }

    func resetColors() {
        accentHex = ColorKeys.defaultAccent
        routeHex = ColorKeys.defaultRoute
        puckHex = ColorKeys.defaultPuck
        speedSignHex = ColorKeys.defaultSpeedSign
        speedingHex = ColorKeys.defaultSpeeding
        hudBackgroundHex = nil
        hudTextHex = nil
        buttonTextHex = nil
        textTintHex = nil
    }

    /** Gespeicherte Farbe; beim ersten Start nach dem Update aus der alten Farbnamen-Einstellung
     *  übernommen und sofort gespeichert (damit `@AppStorage`-Leser denselben Wert sehen). */
    private static func storedColor(_ key: String, legacy: UInt32?, default fallback: UInt32) -> UInt32 {
        let defaults = UserDefaults.standard
        if let value = defaults.object(forKey: key) as? Int, value >= 0 { return UInt32(value) }
        let value = legacy ?? fallback
        defaults.set(Int(value), forKey: key)
        return value
    }

    private static func optionalColor(_ key: String) -> UInt32? {
        guard let value = UserDefaults.standard.object(forKey: key) as? Int, value >= 0 else { return nil }
        return UInt32(value)
    }

    /** Alle Einstellungen auf Werkseinstellung (Favoriten, Verlauf, Fahrtenbuch, Tankerkönig-Schlüssel bleiben). */
    func resetAll() {
        mapEngine = .vector
        mapTheme = .system
        resetColors()
        routePreviewEnabled = true
        recentSearchesEnabled = true
        routingProfile = .car
        emphasizeStreetNames = true
        voiceIdentifier = ""
        speechRate = SpeechService.defaultRate
        showSpeedLimit = true
        speedWarning = true
        showCurrentSpeed = true
        speedInFreeMode = true
        speedTolerance = 3
        start3D = true
        buildings3D = true
        widerMotorways = true
        poiTapEnabled = true
        snapToRoad = true
        compassWhenIdle = true
        showCompassButton = true
        osmRotatable = true
        hudOpacity = 0.88
        largeHud = false
        liquidGlass = true
        keepScreenOn = true
        autoZoom = true
        laneGuidance = true
        smoothPuck = true
        navPuckLow = true
        showRoadName = true
        autoReroute = true
        alternativeRoutes = true
        offlinePaths = false
        offlineRoadSource = .tiles
        offlineMapsOnly = false
        fullyOffline = false
        voiceEnabled = true
        speechVolume = 1
        preAnnouncements = true
        chainAnnouncements = true
        duckMusic = true
        showOpenStatus = true
        liveActivityEnabled = true
        etaSharePrompt = true
        recordTracks = true
        navWidgetEnabled = true
        alongRouteKm = 50
        alongRouteCorridor = 600
        routeWeather = true
        weatherButton = true
        showTourTrack = true
        speedAdaptiveVolume = true
        fuelType = .e10
        fuelSortByPrice = true
        // Der Tankerkönig-Schlüssel bleibt (ist eher ein Zugangsdatum als eine Einstellung).
    }
}
