import Foundation

/** Ein Navigationsschritt mit vorformatiertem Text und Manöver-Standort. */
struct NavStep {
    let instruction: String
    /** Kurze Ansage-Form, siehe [InstructionFormatter.action]. */
    let spokenAction: String
    /** Dasselbe ohne "(Richtung …)" — für "Jetzt …", wo nur noch die Richtung zählt. */
    let spokenActionShort: String
    let maneuverPoint: LatLon
    let maneuverType: String
    let maneuverModifier: String?
    let exit: Int?
    var distance: Double
    var duration: Double
    let lanes: [OsrmLane]?
}

/**
 * Verfolgt den Fortschritt entlang einer berechneten Route (Port von `RouteProgressTracker.kt`):
 * aktueller Schritt, Distanz bis zum nächsten Manöver, Restdistanz/-zeit, Abweichung, Snapping.
 */
final class RouteProgressTracker {

    private let steps: [NavStep]
    private let legIndexForStep: [Int]
    /** Alle Routenpunkte (dicht entlang der gesamten Strecke) — für Abweichungserkennung/Snapping. */
    private let routePoints: [LatLon]
    /** Strecke vom Routenstart bis zum Manöver von Schritt `i` — für die Nachhol-Erkennung. */
    private let cumulativeManeuverDistance: [Double]
    private let averageSpeedMps: Double

    private(set) var currentStepIndex = 0

    init(route: OsrmRoute) {
        let merged = RouteProgressTracker.mergeSteps(route)
        steps = merged.map { $0.0 }
        legIndexForStep = merged.map { $0.1 }
        routePoints = route.geometry
        var sum = 0.0
        cumulativeManeuverDistance = steps.map { step in
            defer { sum += step.distance }
            return sum
        }
        averageSpeedMps = route.duration > 0 ? route.distance / route.duration : 0
    }

    var isFinished: Bool { currentStepIndex >= steps.count - 1 }

    func currentInstruction() -> String { steps[currentStepIndex].instruction }

    /** Der Schritt, dessen Manöver als Nächstes ansteht (für Pfeil-Icon/HUD). */
    func nextManeuver() -> NavStep { isFinished ? steps[steps.count - 1] : steps[currentStepIndex + 1] }

    /** Der aktuelle Schritt (dessen Manöver gerade erreicht wurde). */
    func currentStep() -> NavStep { steps[currentStepIndex] }

    /** Das Manöver [offset] Schritte nach dem aktuellen (1 = nächstes), nil = gibt es nicht. */
    func maneuver(after offset: Int) -> NavStep? {
        let index = currentStepIndex + offset
        return index < steps.count ? steps[index] : nil
    }

    /** Distanz in Metern bis zum nächsten Manöverpunkt (Luftlinie). */
    func distanceToNextManeuver(_ current: LatLon) -> Double {
        GeoUtils.distanceMeters(current, nextManeuver().maneuverPoint)
    }

    /**
     * Rückt zum nächsten Schritt vor, wenn der Fahrer nah genug am nächsten Manöverpunkt ist —
     * oder (Nachhol-Fall) das Manöver entlang der Route bereits überfahren hat, z.B. weil die App
     * im Hintergrund keine Standort-Updates bekam. Gibt true zurück, wenn sich etwas änderte.
     */
    func advanceIfNeeded(_ current: LatLon, thresholdMeters: Double = 40) -> Bool {
        if isFinished { return false }
        let startIndex = currentStepIndex
        while !isFinished && distanceToNextManeuver(current) <= thresholdMeters {
            currentStepIndex += 1
        }
        while !isFinished && hasPassedNextManeuver(current, marginMeters: thresholdMeters) {
            currentStepIndex += 1
        }
        return currentStepIndex != startIndex
    }

    private func hasPassedNextManeuver(_ current: LatLon, marginMeters: Double) -> Bool {
        traveledDistanceAlongRoute(current) > cumulativeManeuverDistance[currentStepIndex + 1] + marginMeters
    }

    /** Entlang der Routenlinie vom Start bis zur Projektion von [current] zurückgelegte Strecke. */
    private func traveledDistanceAlongRoute(_ current: LatLon) -> Double {
        guard routePoints.count >= 2 else { return 0 }
        var accumulated = 0.0
        var traveledAtBest = 0.0
        var bestDistance = Double.greatestFiniteMagnitude
        for i in 0..<(routePoints.count - 1) {
            let a = routePoints[i]
            let b = routePoints[i + 1]
            let candidate = GeoUtils.closestPointOnSegment(current, a, b)
            let d = GeoUtils.distanceMeters(current, candidate)
            if d < bestDistance {
                bestDistance = d
                traveledAtBest = accumulated + GeoUtils.distanceMeters(a, candidate)
            }
            accumulated += GeoUtils.distanceMeters(a, b)
        }
        return traveledAtBest
    }

    func remainingDistance(_ current: LatLon) -> Double {
        let rest = steps.dropFirst(currentStepIndex + 1).reduce(0) { $0 + $1.distance }
        return distanceToNextManeuver(current) + rest
    }

    func remainingDuration(_ current: LatLon) -> Double {
        averageSpeedMps > 0 ? remainingDistance(current) / averageSpeedMps : 0
    }

    func currentLegIndex() -> Int {
        currentStepIndex < legIndexForStep.count ? legIndexForStep[currentStepIndex] : (legIndexForStep.last ?? 0)
    }

    /** Nächster Punkt auf der gesamten Routenlinie (echtes Lot auf jedes Segment). */
    private func closestRoutePoint(_ current: LatLon) -> LatLon {
        closestOnRoute(current)?.point ?? routePoints.first ?? current
    }

    private func closestOnRoute(_ current: LatLon) -> (point: LatLon, segment: Int)? {
        guard routePoints.count >= 2 else { return nil }
        var best = (point: routePoints[0], segment: 0)
        var bestDistance = Double.greatestFiniteMagnitude
        for i in 0..<(routePoints.count - 1) {
            let candidate = GeoUtils.closestPointOnSegment(current, routePoints[i], routePoints[i + 1])
            let d = GeoUtils.distanceMeters(current, candidate)
            if d < bestDistance {
                bestDistance = d
                best = (candidate, i)
            }
        }
        return best
    }

    /**
     * Wie [snapToRoute], liefert aber zusätzlich die Fahrtrichtung der Route an dieser Stelle —
     * gemessen zu einem Punkt [lookAheadMeters] voraus, damit Kurven weich durchfahren werden.
     * Zuverlässiger als der GPS-Kurs: stimmt auch im Stand (Ampel, Navigationsstart) und hinkt
     * in Kurven nicht hinterher. nil, wenn der Fahrer weiter als [maxSnapMeters] neben der Route ist.
     */
    func snapWithBearing(_ current: LatLon, maxSnapMeters: Double = 30, lookAheadMeters: Double = 20) -> (point: LatLon, bearing: Double)? {
        guard let (point, segment) = closestOnRoute(current),
              GeoUtils.distanceMeters(current, point) <= maxSnapMeters else { return nil }
        var remaining = lookAheadMeters
        var cursor = point
        var target = routePoints[segment + 1]
        var index = segment + 1
        while index < routePoints.count {
            let next = routePoints[index]
            let d = GeoUtils.distanceMeters(cursor, next)
            if d >= remaining && d > 0 {
                let f = remaining / d
                target = LatLon(cursor.latitude + (next.latitude - cursor.latitude) * f,
                                cursor.longitude + (next.longitude - cursor.longitude) * f)
                break
            }
            remaining -= d
            cursor = next
            target = next
            index += 1
        }
        if GeoUtils.distanceMeters(point, target) < 1 {
            // Am Routenende: Richtung des letzten Segments.
            return (point, GeoUtils.bearing(routePoints[routePoints.count - 2], routePoints[routePoints.count - 1]))
        }
        return (point, GeoUtils.bearing(point, target))
    }

    func distanceFromRoute(_ current: LatLon) -> Double {
        GeoUtils.distanceMeters(current, closestRoutePoint(current))
    }

    /** "Setzt den Fahrer auf die Straße": Projektion auf die Routenlinie, sofern innerhalb von
     *  [maxSnapMeters] — echte Abweichungen bleiben für das Re-Routing sichtbar. */
    func snapToRoute(_ current: LatLon, maxSnapMeters: Double = 30) -> LatLon {
        let closest = closestRoutePoint(current)
        return GeoUtils.distanceMeters(current, closest) <= maxSnapMeters ? closest : current
    }

    // MARK: - Schritt-Zusammenfassung

    /**
     * OSRM erzeugt an jeder Straßennamensänderung einen eigenen "new name"/"continue"-Schritt,
     * auch ohne echte Kreuzung. Solche richtungslosen Fortsetzungen werden in den vorherigen
     * Schritt eingerechnet, damit keine sinnlosen "Weiter auf ..."-Ansagen kommen.
     */
    private static func isSilentContinuation(_ step: NavStep) -> Bool {
        (step.maneuverType == "new name" || step.maneuverType == "continue") &&
            (step.maneuverModifier == nil || step.maneuverModifier == "straight")
    }

    private static func mergeSteps(_ route: OsrmRoute) -> [(NavStep, Int)] {
        var merged: [(NavStep, Int)] = []
        for (legIndex, leg) in route.legs.enumerated() {
            for step in leg.steps {
                let navStep = NavStep(
                    instruction: InstructionFormatter.format(step),
                    spokenAction: InstructionFormatter.action(step),
                    spokenActionShort: InstructionFormatter.action(step, includeDestinations: false),
                    maneuverPoint: step.maneuver.location,
                    maneuverType: step.maneuver.type,
                    maneuverModifier: step.maneuver.modifier,
                    exit: step.maneuver.exit,
                    distance: step.distance,
                    duration: step.duration,
                    lanes: step.lanes
                )
                if !merged.isEmpty && isSilentContinuation(navStep) {
                    merged[merged.count - 1].0.distance += navStep.distance
                    merged[merged.count - 1].0.duration += navStep.duration
                } else {
                    merged.append((navStep, legIndex))
                }
            }
        }
        return merged
    }

    /** Anweisungstexte für die Routenvorschau — dieselbe Zusammenfassung wie während der Navigation. */
    static func previewInstructions(_ route: OsrmRoute) -> [String] {
        mergeSteps(route).map { $0.0.instruction }
    }
}
