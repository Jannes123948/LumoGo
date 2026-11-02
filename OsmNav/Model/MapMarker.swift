import Foundation

/** Art einer eigenen Markierung auf der Karte. */
enum MarkerKind: String, Codable, CaseIterable, Identifiable {
    case speedCamera, roadworks, danger, parking, note

    var id: String { rawValue }

    var label: String {
        switch self {
        case .speedCamera: return String(localized: "Blitzer")
        case .roadworks: return String(localized: "Baustelle")
        case .danger: return String(localized: "Gefahrenstelle")
        case .parking: return String(localized: "Parkplatz")
        case .note: return String(localized: "Notiz")
        }
    }

    var symbol: String {
        switch self {
        case .speedCamera: return "camera.fill"
        case .roadworks: return "hammer.fill"
        case .danger: return "exclamationmark.triangle.fill"
        case .parking: return "parkingsign"
        case .note: return "mappin"
        }
    }

    var colorHex: Int {
        switch self {
        case .speedCamera: return 0xD32F2F
        case .roadworks: return 0xF57C00
        case .danger: return 0xF9A825
        case .parking: return 0x1565C0
        case .note: return 0x7B3FE4
        }
    }

    /** Welche Warnung auf der Route daraus wird (nil = keine, z.B. Parkplatz). */
    var hazardKind: HazardKind? {
        switch self {
        case .speedCamera: return .speedCamera
        case .roadworks: return .roadworks
        case .danger: return .generic
        case .parking, .note: return nil
        }
    }
}

/** Eigene Markierung (Blitzer, Baustelle, Gefahr, Parkplatz, Notiz) — nur auf diesem Gerät sichtbar. */
struct MapMarker: Codable, Identifiable, Hashable {
    let id: String
    var kind: MarkerKind
    var note: String
    let lat: Double
    let lon: Double
    let createdAt: Date

    var point: LatLon { LatLon(lat, lon) }
    var title: String { note.trimmingCharacters(in: .whitespaces).isEmpty ? kind.label : note }

    /** Als „Favorit“ für die Pin-Ebene der Karte (ID mit Präfix, damit der Tipp erkennbar bleibt). */
    var asMapPin: Favorite {
        Favorite(id: Self.pinPrefix + id, name: title, point: point, isHome: false, symbol: kind.symbol, colorHex: kind.colorHex)
    }

    static let pinPrefix = "marker:"
}
