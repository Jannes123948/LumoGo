import Foundation

/** Infos zu einem angetippten Ort (aus den OSM-Tags), angezeigt im Detail-Blatt. */
struct PoiDetails {
    let name: String
    let point: LatLon
    let category: String?
    let address: String?
    let openingHoursRaw: String?
    let phone: String?
    let website: URL?

    var openingHours: OpeningHours? { openingHoursRaw.flatMap(OpeningHours.parse) }

    init(name: String, point: LatLon, tags: [String: String]) {
        func tag(_ key: String) -> String? {
            guard let v = tags[key]?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return nil }
            return v
        }
        self.name = name
        self.point = point
        category = PoiCategoryNames.label(tags)
        let street = tag("addr:street").map { s in tag("addr:housenumber").map { "\(s) \($0)" } ?? s }
        let city = tag("addr:city") ?? tag("addr:town") ?? tag("addr:village") ?? tag("addr:suburb")
        let place = [tag("addr:postcode"), city].compactMap { $0 }.joined(separator: " ")
        let joined = [street, place.isEmpty ? nil : place].compactMap { $0 }.joined(separator: ", ")
        address = joined.isEmpty ? nil : joined
        openingHoursRaw = tag("opening_hours")
        // Mehrere Nummern sind per ";" getrennt — die erste reicht zum Anrufen.
        phone = (tag("phone") ?? tag("contact:phone"))?.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) }
        website = (tag("website") ?? tag("contact:website") ?? tag("url")).flatMap { raw in
            URL(string: raw.hasPrefix("http") ? raw : "https://\(raw)")
        }
    }
}

/**
 * Lädt die OSM-Tags eines angetippten Orts per Overpass: entweder per Name rund um die
 * Antippstelle (Vektorkarte liefert den Namen des POI-Symbols mit) oder — Rasterkarte/dunkler
 * Stil ohne POI-Symbole — den nächstgelegenen benannten Ort im Umkreis.
 */
enum PoiDetailsClient {

    private static let timeoutSeconds = 20.0
    private static let poiKeys = "amenity|shop|tourism|leisure|healthcare|office|craft|historic|railway|public_transport|aeroway"

    /** Sucht den Ort mit genau diesem Namen nahe [near]; nil, wenn Overpass nichts findet. */
    static func fetch(name: String, near: LatLon) async throws -> PoiDetails? {
        let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let around = "around:80,\(near.latitude),\(near.longitude)"
        return try await query("nwr[\"name\"=\"\(escaped)\"](\(around));", near: near)
    }

    /** Nächster benannter POI im Umkreis von [radiusMeters] um [near]. */
    static func fetchNearest(_ near: LatLon, radiusMeters: Int) async throws -> PoiDetails? {
        let around = "around:\(radiusMeters),\(near.latitude),\(near.longitude)"
        return try await query("nwr[\"name\"][~\"^(\(poiKeys))$\"~\".\"](\(around));", near: near)
    }

    private static func query(_ statement: String, near: LatLon) async throws -> PoiDetails? {
        let q = "[out:json][timeout:12];\n\(statement)\nout tags center 20;"
        let result: Result<Data, Error>? = await withTimeout(seconds: timeoutSeconds) {
            do { return .success(try await OverpassClient.rawQuery(q, retryCount: 2)) } catch { return .failure(error) }
        }
        guard let result else { throw AppError.server(String(localized: "Zeitüberschreitung")) }
        let data = try result.get()

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let elements = root["elements"] as? [[String: Any]] else { throw AppError.parse }
        let candidates: [PoiDetails] = elements.compactMap { el in
            guard let tags = el["tags"] as? [String: String], let name = tags["name"] else { return nil }
            let lat = (el["lat"] as? Double) ?? ((el["center"] as? [String: Any])?["lat"] as? Double)
            let lon = (el["lon"] as? Double) ?? ((el["center"] as? [String: Any])?["lon"] as? Double)
            guard let lat, let lon else { return nil }
            return PoiDetails(name: name, point: LatLon(lat, lon), tags: tags)
        }
        // Nächster Treffer; bei Gleichstand der mit mehr Infos (Gebäude-Umriss vs. Eingangs-Knoten).
        return candidates.min { a, b in
            let da = GeoUtils.distanceMeters(near, a.point) - (a.openingHoursRaw != nil ? 15 : 0)
            let db = GeoUtils.distanceMeters(near, b.point) - (b.openingHoursRaw != nil ? 15 : 0)
            return da < db
        }
    }
}

/** Deutsche Bezeichnungen für häufige OSM-Kategorien; sonst der Rohwert lesbar gemacht. */
enum PoiCategoryNames {

    private static let names: [String: String] = [
        "restaurant": String(localized: "Restaurant"), "fast_food": String(localized: "Fast Food"), "cafe": String(localized: "Café"), "bar": String(localized: "Bar"), "pub": String(localized: "Kneipe"),
        "biergarten": String(localized: "Biergarten"), "ice_cream": String(localized: "Eisdiele"), "fuel": String(localized: "Tankstelle"), "parking": String(localized: "Parkplatz"),
        "charging_station": String(localized: "Ladesäule"), "pharmacy": String(localized: "Apotheke"), "hospital": String(localized: "Krankenhaus"), "doctors": String(localized: "Arztpraxis"),
        "dentist": String(localized: "Zahnarzt"), "bank": String(localized: "Bank"), "atm": String(localized: "Geldautomat"), "post_office": String(localized: "Post"), "school": String(localized: "Schule"),
        "kindergarten": String(localized: "Kindergarten"), "university": String(localized: "Universität"), "library": String(localized: "Bibliothek"), "police": String(localized: "Polizei"),
        "townhall": String(localized: "Rathaus"), "theatre": String(localized: "Theater"), "cinema": String(localized: "Kino"), "place_of_worship": String(localized: "Gotteshaus"),
        "toilets": String(localized: "Toiletten"), "car_wash": String(localized: "Autowäsche"), "car_rental": String(localized: "Autovermietung"), "fire_station": String(localized: "Feuerwehr"),
        "supermarket": String(localized: "Supermarkt"), "bakery": String(localized: "Bäckerei"), "butcher": String(localized: "Metzgerei"), "convenience": String(localized: "Lebensmittel"),
        "kiosk": String(localized: "Kiosk"), "clothes": String(localized: "Bekleidung"), "shoes": String(localized: "Schuhe"), "hairdresser": String(localized: "Friseur"), "chemist": String(localized: "Drogerie"),
        "doityourself": String(localized: "Baumarkt"), "hardware": String(localized: "Eisenwaren"), "electronics": String(localized: "Elektronik"), "furniture": String(localized: "Möbel"),
        "car": String(localized: "Autohaus"), "car_repair": String(localized: "Autowerkstatt"), "bicycle": String(localized: "Fahrradladen"), "florist": String(localized: "Blumen"),
        "optician": String(localized: "Optiker"), "beverages": String(localized: "Getränkemarkt"), "department_store": String(localized: "Kaufhaus"), "mall": String(localized: "Einkaufszentrum"),
        "books": String(localized: "Buchhandlung"), "gift": String(localized: "Geschenke"), "jewelry": String(localized: "Schmuck"), "mobile_phone": String(localized: "Handyladen"),
        "hotel": String(localized: "Hotel"), "guest_house": String(localized: "Pension"), "hostel": String(localized: "Hostel"), "camp_site": String(localized: "Campingplatz"),
        "museum": String(localized: "Museum"), "attraction": String(localized: "Sehenswürdigkeit"), "viewpoint": String(localized: "Aussichtspunkt"),
        "information": String(localized: "Touristeninformation"), "zoo": String(localized: "Zoo"), "theme_park": String(localized: "Freizeitpark"),
        "park": String(localized: "Park"), "playground": String(localized: "Spielplatz"), "sports_centre": String(localized: "Sportzentrum"), "swimming_pool": String(localized: "Schwimmbad"),
        "fitness_centre": String(localized: "Fitnessstudio"), "pitch": String(localized: "Sportplatz"), "stadium": String(localized: "Stadion"),
        "station": String(localized: "Bahnhof"), "halt": String(localized: "Haltepunkt"), "tram_stop": String(localized: "Straßenbahnhaltestelle"),
        "castle": String(localized: "Burg/Schloss"), "monument": String(localized: "Denkmal"), "memorial": String(localized: "Gedenkstätte"), "ruins": String(localized: "Ruine"),
        "aerodrome": String(localized: "Flugplatz")
    ]

    static func label(_ tags: [String: String]) -> String? {
        if tags["amenity"] == "place_of_worship" {
            switch tags["religion"] {
            case "christian": return String(localized: "Kirche")
            case "muslim": return String(localized: "Moschee")
            case "jewish": return String(localized: "Synagoge")
            default: break
            }
        }
        for key in ["amenity", "shop", "tourism", "leisure", "healthcare", "office", "craft", "historic", "railway", "aeroway"] {
            guard let value = tags[key], value != "yes" else { continue }
            if let name = names[value] { return name }
            let readable = value.replacingOccurrences(of: "_", with: " ")
            return readable.prefix(1).uppercased() + readable.dropFirst()
        }
        return nil
    }
}
