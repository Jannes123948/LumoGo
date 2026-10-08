import ActivityKit
import Foundation

/**
 * Startet/aktualisiert/beendet die Live-Aktivität der Navigation (Sperrbildschirm + Dynamic Island,
 * Anzeige in der Widget-Erweiterung `LumoGoWidgets`). Lokale Updates aus der App — die läuft während
 * der Navigation ohnehin im Hintergrund weiter (Standort). Aktualisiert nur, wenn sich die Anzeige
 * ändert, sonst drosselt iOS die Updates.
 */
@MainActor
final class LiveActivityController {
    private var activity: Activity<NavActivityAttributes>?
    private var lastState: NavActivityAttributes.ContentState?

    /** Neue Live-Aktivität (beendet eine ältere, z.B. nach einem Absturz liegen gebliebene). */
    func start(destination: String, backgroundHex: UInt32, textHex: UInt32, state: NavActivityAttributes.ContentState) {
        endAll()
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attributes = NavActivityAttributes(destinationName: destination, backgroundHex: Int(backgroundHex), textHex: Int(textHex))
        activity = try? Activity.request(attributes: attributes, content: ActivityContent(state: state, staleDate: nil), pushType: nil)
        lastState = state
    }

    func update(_ state: NavActivityAttributes.ContentState) {
        guard let activity, state != lastState else { return }
        lastState = state
        Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
    }

    /** [arrived] = „Angekommen“ noch eine Minute stehen lassen, sonst sofort weg. */
    func end(arrived: Bool) {
        guard let activity else { return }
        self.activity = nil
        var final = lastState
        final?.arrived = arrived
        lastState = nil
        let content = final.map { ActivityContent(state: $0, staleDate: nil) }
        Task {
            await activity.end(content, dismissalPolicy: arrived ? .after(Date().addingTimeInterval(60)) : .immediate)
        }
    }

    private func endAll() {
        activity = nil
        lastState = nil
        for leftover in Activity<NavActivityAttributes>.activities {
            Task { await leftover.end(nil, dismissalPolicy: .immediate) }
        }
    }
}
