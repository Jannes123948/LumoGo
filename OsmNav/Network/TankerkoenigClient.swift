import Foundation

/** Kraftstoffsorte für die Spritpreise (Tankerkönig-`type`). */
enum FuelType: String, CaseIterable, Identifiable {
    case e5, e10, diesel
    var id: String { rawValue }

    var label: String {
        switch self {
        case .e5: return "Super E5"
        case .e10: return "Super E10"
        case .diesel: return "Diesel"
        }
    }
}

/** Eine Tankstelle mit aktuellem Preis (nil = geschlossen bzw. Sorte nicht im Angebot). */
struct FuelStation: Identifiable, Hashable {
    let id: String
    let name: String
    let place: String?
    let lat: Double
    let lon: Double
    let distanceKm: Double
    let price: Double?
    let isOpen: Bool

    /** „1,739 €“ — Tankerkönig liefert drei Nachkommastellen wie die Preistafeln. */
    var priceText: String? {
        price.map { String(format: "%.3f €", $0).replacingOccurrences(of: ".", with: ",") }
    }
}

/**
 * Aktuelle Spritpreise in Deutschland über die Tankerkönig-API (Daten der Markttransparenzstelle
 * MTS-K, Lizenz CC BY 4.0 — Quellenangabe in den Einstellungen). Braucht einen kostenlosen eigenen
 * API-Schlüssel (creativecommons.tankerkoenig.de); der öffentliche Demo-Schlüssel liefert echte
 * Tankstellen, aber Fantasiepreise. Ein falscher Schlüssel kommt als HTTP 200 mit `ok: false`.
 */
enum TankerkoenigClient {
    static let demoKey = "00000000-0000-0000-0000-000000000002"
    static let signupURL = URL(string: "https://creativecommons.tankerkoenig.de")!
    private static let session = HTTP.session(requestTimeout: 15)
    /** Größter erlaubter Suchradius der API. */
    static let maxRadiusKm = 25.0

    static func stations(near center: LatLon, radiusKm: Double, fuel: FuelType, sortByPrice: Bool,
                         apiKey: String) async throws -> [FuelStation] {
        let url = HTTP.url("https://creativecommons.tankerkoenig.de/json/list.php", [
            ("lat", String(center.latitude)),
            ("lng", String(center.longitude)),
            ("rad", String(min(radiusKm, maxRadiusKm))),
            ("sort", sortByPrice ? "price" : "dist"),
            ("type", fuel.rawValue),
            ("apikey", apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
        ])
        let data = try await HTTP.data(session, for: URLRequest(url: url))
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { throw AppError.parse }
        guard response.ok else { throw AppError.server(response.message ?? "Tankerkönig: unbekannter Fehler") }
        return (response.stations ?? []).map { s in
            FuelStation(
                id: s.id,
                name: Self.displayName(brand: s.brand, name: s.name),
                place: s.place.map(Self.titleCased),
                lat: s.lat,
                lon: s.lng,
                distanceKm: s.dist ?? 0,
                price: s.isOpen ? s.price?.value : nil,
                isOpen: s.isOpen
            )
        }
    }

    /** Marke reicht meist („ARAL“ → „Aral“); sonst der Name. */
    private static func displayName(brand: String?, name: String) -> String {
        let brand = brand?.trimmingCharacters(in: .whitespaces) ?? ""
        let base = brand.isEmpty ? name : brand
        // Viele Marken kommen in Großbuchstaben („ARAL“ → „Aral“); Kürzel (BFT, OMV, JET, HEM) bleiben so.
        return base == base.uppercased() && base.count >= 4 ? titleCased(base) : base
    }

    private static func titleCased(_ text: String) -> String {
        text.lowercased().split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    private struct Response: Decodable {
        let ok: Bool
        let message: String?
        let stations: [Station]?
    }

    private struct Station: Decodable {
        let id: String
        let name: String
        let brand: String?
        let place: String?
        let lat: Double
        let lng: Double
        let dist: Double?
        let price: FlexiblePrice?
        let isOpen: Bool
    }

    /** `price` ist eine Zahl, bei geschlossenen Tankstellen aber `null` oder `false`. */
    private struct FlexiblePrice: Decodable {
        let value: Double?
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            value = try? container.decode(Double.self)
        }
    }
}
