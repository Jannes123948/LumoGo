import Foundation
import EventKit
import UserNotifications

/** Ein Kalendertermin mit Ort (für „Ankommen um …“). */
struct CalendarTrip: Identifiable, Hashable {
    let id: String
    let title: String
    let start: Date
    let location: String
    /** Koordinaten, falls der Termin einen Kartenort hat (in Apple Kalender gewählt). */
    let point: LatLon?
}

/**
 * „Ankommen um …“: Losfahrzeit = Ankunft − Fahrzeit − Puffer, Erinnerung als lokale Mitteilung (Tippen
 * startet die Navigation, siehe [NotificationHandler]), Termine mit Ort aus dem Kalender.
 * Fahrzeiten kommen von OSRM ohne Verkehrslage — deshalb der Puffer.
 */
enum DeparturePlanner {
    static let notificationId = "lumogo.departure"
    static let category = "LUMOGO_DEPARTURE"

    /** Losfahrzeit für eine gewünschte Ankunft. */
    static func departure(arrival: Date, durationSeconds: Double, bufferMinutes: Int) -> Date {
        arrival.addingTimeInterval(-durationSeconds - Double(bufferMinutes) * 60)
    }

    /** Erinnerung zur Losfahrzeit (bzw. sofort, wenn die schon vorbei ist); false = Mitteilungen aus. */
    static func scheduleReminder(departure: Date, arrival: Date, destination: String, point: LatLon) async -> Bool {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else { return false }
        center.removePendingNotificationRequests(withIdentifiers: [notificationId])
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Zeit zum Losfahren")
        let time = arrival.formatted(date: .omitted, time: .shortened)
        content.body = String(localized: "Für \(destination) um \(time) jetzt losfahren. Tippen startet die Navigation.")
        content.sound = .default
        content.categoryIdentifier = category
        content.userInfo = ["lat": point.latitude, "lon": point.longitude, "name": destination]
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(departure.timeIntervalSinceNow, 1), repeats: false)
        return (try? await center.add(UNNotificationRequest(identifier: notificationId, content: content, trigger: trigger))) != nil
    }

    static func cancelReminder() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [notificationId])
    }

    /** Geplante Losfahr-Erinnerung (Zeitpunkt), nil = keine. */
    static func pendingReminder() async -> Date? {
        let requests = await UNUserNotificationCenter.current().pendingNotificationRequests()
        guard let request = requests.first(where: { $0.identifier == notificationId }),
              let trigger = request.trigger as? UNTimeIntervalNotificationTrigger else { return nil }
        return trigger.nextTriggerDate()
    }

    // MARK: - Kalender

    private static let store = EKEventStore()

    /** Zugriff auf den Kalender erfragen (iOS 17: „Vollzugriff“, iOS 16: klassisch). */
    static func requestCalendarAccess() async -> Bool {
        if #available(iOS 17.0, *) {
            return (try? await store.requestFullAccessToEvents()) ?? false
        }
        return await withCheckedContinuation { continuation in
            store.requestAccess(to: .event) { granted, _ in continuation.resume(returning: granted) }
        }
    }

    static var hasCalendarAccess: Bool {
        if #available(iOS 17.0, *) { return EKEventStore.authorizationStatus(for: .event) == .fullAccess }
        return EKEventStore.authorizationStatus(for: .event) == .authorized
    }

    /** Termine der nächsten [hours] Stunden mit Ort (ganztägige ausgenommen), früheste zuerst. */
    static func upcomingTrips(hours: Double = 48) -> [CalendarTrip] {
        guard hasCalendarAccess else { return [] }
        let now = Date()
        let predicate = store.predicateForEvents(withStart: now, end: now.addingTimeInterval(hours * 3600), calendars: nil)
        return store.events(matching: predicate)
            .filter { !$0.isAllDay && !($0.location ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.startDate < $1.startDate }
            .prefix(20)
            .map { event in
                let geo = event.structuredLocation?.geoLocation?.coordinate
                return CalendarTrip(id: event.eventIdentifier ?? UUID().uuidString, title: event.title ?? String(localized: "Termin"),
                                    start: event.startDate,
                                    location: event.location?.replacingOccurrences(of: "\n", with: ", ") ?? "",
                                    point: geo.map { LatLon($0) })
            }
    }
}

/** Tippen auf die Losfahr-Mitteilung startet die Navigation; Mitteilungen erscheinen auch bei offener App. */
final class NotificationHandler: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationHandler()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if response.notification.request.content.categoryIdentifier == DeparturePlanner.category,
           let lat = info["lat"] as? Double, let lon = info["lon"] as? Double {
            let name = info["name"] as? String ?? String(localized: "Ziel")
            Task { @MainActor in
                AppModel.current?.navigateNow(to: Favorite(id: "departure", name: name, point: LatLon(lat, lon), isHome: false))
            }
        }
        completionHandler()
    }
}
