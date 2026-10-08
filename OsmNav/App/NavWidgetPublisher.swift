import Foundation
import WidgetKit

/**
 * Schreibt den Navigationszustand für das Navigations-Widget und stößt dessen Neuzeichnen an.
 * Widgets haben ein Aktualisierungs-Budget — deshalb sofort bei neuem Manöver/Text, sonst höchstens
 * alle [minInterval] Sekunden (die Distanz ändert sich ständig). Wie oft iOS das Widget dann
 * wirklich neu zeichnet, entscheidet das System.
 */
@MainActor
final class NavWidgetPublisher {
    private static let minInterval: TimeInterval = 10
    private var lastPublished: NavWidgetState?
    private var lastReloadAt = Date.distantPast

    func publish(_ state: NavWidgetState) {
        var important = true
        if let last = lastPublished {
            important = last.active != state.active || last.instruction != state.instruction
            if last.symbolName != state.symbolName { important = true }
        }
        guard important || Date().timeIntervalSince(lastReloadAt) >= Self.minInterval else { return }
        guard NavWidgetStore.save(state) else { return }
        lastPublished = state
        lastReloadAt = Date()
        WidgetCenter.shared.reloadTimelines(ofKind: NavWidgetStore.widgetKind)
    }

    func clear() {
        guard lastPublished?.active != false else { return }
        var state = NavWidgetState.inactive
        state.updatedAt = Date()
        NavWidgetStore.save(state)
        lastPublished = state
        lastReloadAt = Date()
        WidgetCenter.shared.reloadTimelines(ofKind: NavWidgetStore.widgetKind)
    }

    /**
     * [points] in Meter relativ zu [origin] umrechnen und so drehen, dass [heading] (Grad, 0 = Norden)
     * nach oben zeigt. Gleichrechteckige Näherung — für ±2 km genau genug.
     */
    static func localMeters(_ points: [LatLon], origin: LatLon, heading: Double) -> [[Double]] {
        let metersPerDegLat = 111_132.0
        let metersPerDegLon = 111_320.0 * cos(origin.latitude * .pi / 180)
        let angle = heading * .pi / 180
        let c = cos(angle), s = sin(angle)
        return points.map { p in
            let east = (p.longitude - origin.longitude) * metersPerDegLon
            let north = (p.latitude - origin.latitude) * metersPerDegLat
            // Um -heading drehen: Fahrtrichtung → +y.
            let x = east * c - north * s
            let y = east * s + north * c
            return [(x * 10).rounded() / 10, (y * 10).rounded() / 10]
        }
    }
}
