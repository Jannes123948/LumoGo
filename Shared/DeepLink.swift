import Foundation

/**
 * `lumogo://`-Links — vom Widget, aus der Live-Aktivität und intern von Siri-Kurzbefehlen genutzt.
 * Das URL-Schema steht in `OsmNav-Info.plist` (CFBundleURLTypes).
 */
enum DeepLink: Equatable {
    case home
    case favorite(id: String)
    case favorites
    case search
    case nearbyFuel
    case open

    static let scheme = "lumogo"

    var url: URL {
        switch self {
        case .home: return URL(string: "lumogo://home")!
        case .favorite(let id):
            var components = URLComponents(string: "lumogo://favorite")!
            components.queryItems = [URLQueryItem(name: "id", value: id)]
            return components.url!
        case .favorites: return URL(string: "lumogo://favorites")!
        case .search: return URL(string: "lumogo://search")!
        case .nearbyFuel: return URL(string: "lumogo://fuel")!
        case .open: return URL(string: "lumogo://open")!
        }
    }

    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme else { return nil }
        switch url.host?.lowercased() {
        case "home": self = .home
        case "favorite":
            guard let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "id" })?.value else { return nil }
            self = .favorite(id: id)
        case "favorites": self = .favorites
        case "search": self = .search
        case "fuel": self = .nearbyFuel
        case "open", nil: self = .open
        default: return nil
        }
    }
}
