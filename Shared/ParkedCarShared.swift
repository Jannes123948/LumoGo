import Foundation

/**
 * Geparktes Auto für das Widget „Mein Auto“ (die Erweiterung kennt die App-Daten nicht): die App legt
 * Adresse/Zeit/Lage als JSON im Container der App Group ab, das Widget liest sie.
 */
struct ParkedCarSnapshot: Codable, Equatable {
    var latitude: Double
    var longitude: Double
    var date: Date
    var address: String?
    var note: String?
    var reminder: Date?
}

enum ParkedCarShared {
    static let widgetKind = "LumoGoParkedCar"

    private static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: NavWidgetStore.appGroup)?
            .appendingPathComponent("parked_car.json")
    }

    static func load() -> ParkedCarSnapshot? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ParkedCarSnapshot.self, from: data)
    }

    /** nil = kein Auto geparkt (Datei weg). */
    static func save(_ snapshot: ParkedCarSnapshot?) {
        guard let url = fileURL else { return }
        if let snapshot, let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: url, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
