import Foundation
import UserNotifications
import WidgetKit

/** Wo das Auto steht („Wo hab ich geparkt?“). */
struct ParkedCar: Codable, Equatable {
    var lat: Double
    var lon: Double
    var date: Date
    /** Adresse (Nominatim), kommt nach dem Speichern dazu. */
    var address: String?
    /** Eigene Notiz („Parkdeck 3, Platz 112“). */
    var note: String?
    /** Parkzeit-Erinnerung, nil = keine. */
    var reminder: Date?

    var point: LatLon { LatLon(lat, lon) }
}

/** Parkplatz in UserDefaults + Erinnerung als lokale Mitteilung. */
enum ParkingStore {
    private static let key = "osmnav_parked_car"
    private static let reminderId = "lumogo.parking.reminder"

    static func load() -> ParkedCar? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(ParkedCar.self, from: data)
    }

    static func save(_ car: ParkedCar) {
        guard let data = try? JSONEncoder().encode(car) else { return }
        UserDefaults.standard.set(data, forKey: key)
        CloudSync.localChanged(key)
        publish(car)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
        CloudSync.localChanged(key)
        cancelReminder()
        publish(nil)
    }

    /** Antwort für Siri „Wo ist mein Auto?“ — [position] = eigener Standort (falls bekannt). */
    static func spokenLocation(from position: LatLon?) -> String {
        guard let car = load() else { return String(localized: "Es ist kein Parkplatz gemerkt.") }
        let time = car.date.formatted(date: Calendar.current.isDateInToday(car.date) ? .omitted : .abbreviated, time: .shortened)
        var text = car.address.map { String(localized: "Dein Auto steht in \($0), geparkt um \(time).") }
            ?? String(localized: "Dein Auto steht an der gemerkten Stelle, geparkt um \(time).")
        if let position {
            text += " " + String(localized: "Es ist etwa \(FormatUtils.formatDistance(GeoUtils.distanceMeters(position, car.point))) entfernt.")
        }
        if let note = car.note { text += " " + note }
        return text
    }

    /** Für das Widget „Mein Auto“ (App Group). */
    static func publish(_ car: ParkedCar?) {
        ParkedCarShared.save(car.map { ParkedCarSnapshot(latitude: $0.lat, longitude: $0.lon, date: $0.date,
                                                         address: $0.address, note: $0.note, reminder: $0.reminder) })
        WidgetCenter.shared.reloadTimelines(ofKind: ParkedCarShared.widgetKind)
    }

    /** Erinnerung zum Zeitpunkt [date]; false = Mitteilungen nicht erlaubt. */
    static func scheduleReminder(at date: Date, address: String?) async -> Bool {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else { return false }
        center.removePendingNotificationRequests(withIdentifiers: [reminderId])
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Parkzeit läuft ab")
        content.body = address.map { String(localized: "Dein Auto steht: \($0)") } ?? String(localized: "Zeit, zum Auto zurückzugehen.")
        content.sound = .default
        let seconds = max(date.timeIntervalSinceNow, 1)
        let request = UNNotificationRequest(identifier: reminderId, content: content,
                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false))
        return (try? await center.add(request)) != nil
    }

    static func cancelReminder() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [reminderId])
    }
}
