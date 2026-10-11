import Foundation

enum AppError: LocalizedError {
    case http(Int)
    case server(String)
    case parse
    case noResults
    case offlineMode

    var errorDescription: String? {
        switch self {
        case .http(let code): return "HTTP \(code)"
        case .server(let message): return message
        case .parse: return String(localized: "Antwort konnte nicht verarbeitet werden")
        case .noResults: return String(localized: "Keine Ergebnisse")
        case .offlineMode: return String(localized: "Offline-Modus ist an")
        }
    }
}

/** Gemeinsame Netzwerk-Helfer (Ersatz für OkHttp in der Android-Version). */
enum HTTP {

    /** OSM-Dienste (Nominatim, Overpass) verlangen einen eindeutigen User-Agent — Overpass
     *  antwortet ohne ihn sogar mit HTTP 406 (siehe CLAUDE.md, Fallstricke). */
    static let userAgent: String = {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        return "com.jannehorst.osmnav-ios/\(version)"
    }()

    static func session(requestTimeout: TimeInterval) -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = requestTimeout
        config.httpAdditionalHeaders = ["User-Agent": userAgent]
        return URLSession(configuration: config)
    }

    static func data(_ session: URLSession, for request: URLRequest) async throws -> Data {
        // „Komplett offline“: gar nicht erst ins Netz — Aufrufer fallen auf Offline-Daten zurück.
        guard NetworkPolicy.allowsAppRequests else { throw AppError.offlineMode }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AppError.http(http.statusCode)
        }
        return data
    }

    static func url(_ base: String, _ query: [(String, String)]) -> URL {
        var components = URLComponents(string: base)!
        components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        return components.url!
    }
}

/** Führt [operation] mit Zeitlimit aus; liefert nil bei Zeitüberschreitung (bricht die Operation
 *  dann per Task-Cancellation ab — URLSession reagiert darauf sofort). */
func withTimeout<T>(seconds: Double, _ operation: @escaping () async -> T) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await operation() }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}
