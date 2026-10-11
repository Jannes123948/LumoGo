import Foundation

/** Kreuzungsansicht für ein bevorstehendes, kniffliges Manöver. */
struct JunctionState: Equatable {
    let stepIndex: Int
    /** 0 = gerade begonnen, 1 = am Manöver (Fortschrittsbalken). */
    let progress: Double
    let lanes: [OsrmLane]
}

/**
 * Kreuzungsansicht (wie bei Google/Apple Maps): vor kniffligen Stellen — Autobahnausfahrt, Gabelung,
 * Kreisverkehr, Fahrstreifen-Angaben, zwei Manöver kurz hintereinander — zoomt die Karte heran, die
 * Fahrstreifen werden groß gezeigt. Dazu der Abbiegepfeil auf der Karte ([arrow]).
 */
enum JunctionView {

    private static let complexTypes: Set<String> = [
        "fork", "off ramp", "on ramp", "roundabout", "rotary", "roundabout turn", "exit roundabout", "exit rotary", "merge"
    ]

    /** Ist das Manöver [index] knifflig genug für die Kreuzungsansicht? */
    static func isComplex(_ tracker: RouteProgressTracker, _ index: Int) -> Bool {
        guard index > 0, index < tracker.stepCount else { return false }
        let step = tracker.step(index)
        if step.maneuverType == "arrive" || step.maneuverType == "depart" { return false }
        if complexTypes.contains(step.maneuverType) { return true }
        // Echte Fahrstreifen-Wahl: mehrere Spuren, aber nicht alle passen.
        if let lanes = step.lanes, lanes.count >= 2, lanes.contains(where: { !$0.valid }) { return true }
        // Gleich danach das nächste Manöver (z.B. abbiegen und sofort wieder abbiegen).
        if index + 1 < tracker.stepCount, tracker.step(index + 1).maneuverType != "arrive",
           tracker.maneuverAlong(index + 1) - tracker.maneuverAlong(index) <= 100 {
            return true
        }
        return false
    }

    /** Ab welcher Entfernung die Ansicht beginnt: ≈ 12 s vorher, 180–600 m. */
    static func triggerDistance(speedMps: Double) -> Double {
        min(max(speedMps * 12, 180), 600)
    }

    /**
     * Zustand für die aktuelle Position. [sticky] = laufende Ansicht (Manöver + Startentfernung) —
     * sie bleibt, bis das Manöver durchfahren ist, auch wenn man vor der Ausfahrt abbremst (sonst
     * würde die Startentfernung schrumpfen und die Ansicht mittendrin verschwinden).
     */
    static func state(_ tracker: RouteProgressTracker, current: LatLon, speedMps: Double,
                      sticky: (index: Int, trigger: Double)?) -> (state: JunctionState, trigger: Double)? {
        guard let index = tracker.junctionManeuverIndex(current), isComplex(tracker, index) else { return nil }
        let toGo = tracker.maneuverAlong(index) - tracker.traveled(current)
        let trigger = sticky?.index == index ? sticky!.trigger : triggerDistance(speedMps: speedMps)
        guard toGo <= trigger else { return nil }
        let progress = min(max(1 - toGo / trigger, 0), 1)
        return (JunctionState(stepIndex: index, progress: progress, lanes: tracker.step(index).lanes ?? []), trigger)
    }

    /** Für den Abbiegepfeil: Manöver in höchstens [maxMeters] (oder gerade erst durchfahren). */
    static func arrowManeuver(_ tracker: RouteProgressTracker, current: LatLon, maxMeters: Double = 400) -> Int? {
        guard let index = tracker.junctionManeuverIndex(current, passedMeters: 20), index > 0 else { return nil }
        let type = tracker.step(index).maneuverType
        guard type != "arrive", type != "depart" else { return nil }
        return tracker.maneuverAlong(index) - tracker.traveled(current) <= maxMeters ? index : nil
    }

    /**
     * Linie für den Abbiegepfeil: ein Stück vor dem Manöver bis kurz danach (bei Kreisverkehren bis
     * zur Ausfahrt). Bei höherem Tempo länger, damit der Pfeil im weiteren Zoom nicht winzig ist.
     */
    static func arrow(_ tracker: RouteProgressTracker, index: Int, speedMps: Double) -> [LatLon] {
        let along = tracker.maneuverAlong(index)
        let step = tracker.step(index)
        let before = min(max(speedMps * 3, 25), 70)
        var after = min(max(speedMps * 2.5, 22), 50)
        if ["roundabout", "rotary", "roundabout turn"].contains(step.maneuverType) {
            after = min(step.distance + 20, 160)
        }
        return tracker.geometry(fromAlong: max(0, along - before), toAlong: along + after)
    }
}
