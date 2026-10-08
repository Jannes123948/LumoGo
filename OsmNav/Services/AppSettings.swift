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

/** Wählbare UI-Akzentfarbe (gleiche Farbwerte wie die Android-Version). */
enum AccentColor: String, CaseIterable, Identifiable {
    case green, blue, teal, purple, red, orange
    var id: String { rawValue }
    static let `default` = AccentColor.green

    var primary: Color {
        switch self {
        case .green: return Color(hex: 0x2E7D32)
        case .blue: return Color(hex: 0x1565C0)
        case .teal: return Color(hex: 0x00796B)
        case .purple: return Color(hex: 0x6A1B9A)
        case .red: return Color(hex: 0xC62828)
        case .orange: return Color(hex: 0xE65100)
        }
    }

    /** Dunkle Variante — Hintergrund der Navigations-HUD-Leisten. */
    var dark: Color {
        switch self {
        case .green: return Color(hex: 0x1B5E20)
        case .blue: return Color(hex: 0x0D47A1)
        case .teal: return Color(hex: 0x004D40)
        case .purple: return Color(hex: 0x4A148C)
        case .red: return Color(hex: 0x8E0000)
        case .orange: return Color(hex: 0xBF360C)
        }
    }
}

/** Farbe für Routenlinie bzw. Standort-Pfeil (Einstellungen → Design). */
enum MapColor: String, CaseIterable, Identifiable {
    case blue, green, teal, purple, orange, red, pink, black
    var id: String { rawValue }

    var label: String {
        switch self {
        case .blue: return "Blau"
        case .green: return "Grün"
        case .teal: return "Türkis"
        case .purple: return "Lila"
        case .orange: return "Orange"
        case .red: return "Rot"
        case .pink: return "Pink"
        case .black: return "Schwarz"
        }
    }

    var hex: UInt32 {
        switch self {
        case .blue: return 0x2962FF
        case .green: return 0x2E9E3E
        case .teal: return 0x00A3A3
        case .purple: return 0x7B3FE4
        case .orange: return 0xF57C00
        case .red: return 0xD32F2F
        case .pink: return 0xE91E8C
        case .black: return 0x263238
        }
    }

    var color: Color { Color(hex: hex) }
    var uiColor: UIColor { UIColor(color) }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

/** Alle Einstellungen der App, persistiert in UserDefaults. */
final class AppSettings: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var mapEngine: MapEngine { didSet { defaults.set(mapEngine.rawValue, forKey: "map_engine") } }
    @Published var mapTheme: MapTheme { didSet { defaults.set(mapTheme.rawValue, forKey: "map_theme") } }
    @Published var accentColor: AccentColor { didSet { defaults.set(accentColor.rawValue, forKey: "ui_accent_color") } }
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
    @Published var routeColor: MapColor { didSet { defaults.set(routeColor.rawValue, forKey: "route_color") } }
    @Published var puckColor: MapColor { didSet { defaults.set(puckColor.rawValue, forKey: "puck_color") } }
    /** Deckkraft der Navigationsleisten (0,6–1). */
    @Published var hudOpacity: Double { didSet { defaults.set(hudOpacity, forKey: "hud_opacity") } }
    @Published var largeHud: Bool { didSet { defaults.set(largeHud, forKey: "large_hud") } }
    /** Nur wirksam ab iOS 26 (und mit Xcode 26 gebaut), siehe `LiquidGlass`. */
    @Published var liquidGlass: Bool { didSet { defaults.set(liquidGlass, forKey: LiquidGlass.settingsKey) } }

    // Navigation
    @Published var keepScreenOn: Bool { didSet { defaults.set(keepScreenOn, forKey: "keep_screen_on") } }
    @Published var autoZoom: Bool { didSet { defaults.set(autoZoom, forKey: "auto_zoom") } }
    @Published var laneGuidance: Bool { didSet { defaults.set(laneGuidance, forKey: "lane_guidance") } }
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

    // Suche & Orte
    @Published var showOpenStatus: Bool { didSet { defaults.set(showOpenStatus, forKey: "show_open_status") } }

    init() {
        mapEngine = MapEngine(rawValue: defaults.string(forKey: "map_engine") ?? "") ?? .vector
        mapTheme = MapTheme(rawValue: defaults.string(forKey: "map_theme") ?? "") ?? .system
        accentColor = AccentColor(rawValue: defaults.string(forKey: "ui_accent_color") ?? "") ?? .default
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
        routeColor = MapColor(rawValue: defaults.string(forKey: "route_color") ?? "") ?? .blue
        puckColor = MapColor(rawValue: defaults.string(forKey: "puck_color") ?? "") ?? .blue
        hudOpacity = defaults.object(forKey: "hud_opacity") as? Double ?? 0.88
        largeHud = defaults.object(forKey: "large_hud") as? Bool ?? false
        liquidGlass = defaults.object(forKey: LiquidGlass.settingsKey) as? Bool ?? true
        keepScreenOn = defaults.object(forKey: "keep_screen_on") as? Bool ?? true
        autoZoom = defaults.object(forKey: "auto_zoom") as? Bool ?? true
        laneGuidance = defaults.object(forKey: "lane_guidance") as? Bool ?? true
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
    }

    /** Alle Einstellungen auf Werkseinstellung (Favoriten, Verlauf, Fahrtenbuch bleiben). */
    func resetAll() {
        mapEngine = .vector
        mapTheme = .system
        accentColor = .default
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
        routeColor = .blue
        puckColor = .blue
        hudOpacity = 0.88
        largeHud = false
        liquidGlass = true
        keepScreenOn = true
        autoZoom = true
        laneGuidance = true
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
    }
}
