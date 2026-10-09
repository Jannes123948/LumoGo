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
    /** Strecke vom Routenstart bis zu Routenpunkt `i`. */
    private let cumulativePointDistance: [Double]
    private let averageSpeedMps: Double
    /** Straßenname je Abschnitt (aus den UNzusammengefassten Schritten — die Zusammenfassung
     *  verschluckt Namenswechsel ohne Abbiegen), mit Startstrecke ab Routenbeginn. */
    private let roadNames: [(start: Double, name: String)]

    /** Lage einer Position relativ zur Routenlinie (Lot, Segment, Abstand, zurückgelegte Strecke). */
    private struct Located {
        let point: LatLon
        let segment: Int
        let distance: Double
        let traveled: Double
    }

    /** Ergebnis für die zuletzt gefragte Position (pro GPS-Fix wird dieselbe mehrfach gebraucht);
     *  die nächste Suche beginnt im Fenster um dessen Segment. */
    private var lastLocated: (input: LatLon, result: Located)?
    /** Fenster um den letzten Treffer (Routenpunkte zurück/voraus) — statt bei jedem Fix alle
     *  Punkte einer langen Route abzusuchen. */
    private static let windowBack = 50
    private static let windowAhead = 400
    /** Liegt der beste Treffer im Fenster weiter weg, wird doch die ganze Route durchsucht
     *  (GPS-Sprung, Rückkehr aus dem Hintergrund, Abweichung). */
    private static let windowAcceptMeters = 30.0
    /** Im Fenster zählt ein Sprung entlang der Route über [jumpFreeMeters] als Strafabstand
     *  ([jumpPenalty] m je m) — sonst rastet der Pfeil auf Hin-und-zurück-Strecken (gleiche Straße
     *  in beide Richtungen) zufällig auf der Gegenrichtung ein und bleibt dort. */
    private static let jumpFreeMeters = 100.0
    private static let jumpPenalty = 0.2

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
        var pointSum = 0.0
        var pointDistances = [0.0]
        for i in routePoints.indices.dropFirst() {
            pointSum += GeoUtils.distanceMeters(routePoints[i - 1], routePoints[i])
            pointDistances.append(pointSum)
        }
        cumulativePointDistance = routePoints.isEmpty ? [] : pointDistances
        averageSpeedMps = route.duration > 0 ? route.distance / route.duration : 0
        var roadStart = 0.0
        roadNames = route.legs.flatMap(\.steps).compactMap { step in
            defer { roadStart += step.distance }
            guard step.maneuver.type != "arrive" else { return nil }
            return (roadStart, RouteProgressTracker.roadLabel(step))
        }
    }

    /** „Leipziger Straße“, „A 4“ oder „B 6 · Leipziger Straße“; leer = unbenannt. */
    static func roadLabel(_ step: OsrmStep) -> String {
        let name = step.name.trimmingCharacters(in: .whitespaces)
        let ref = (step.ref ?? "").components(separatedBy: ";").first?.trimmingCharacters(in: .whitespaces) ?? ""
        if name.isEmpty { return ref }
        if ref.isEmpty || name.contains(ref) { return name }
        return "\(ref) · \(name)"
    }

    /** Straße, auf der man gerade fährt (wie die Namensleiste unten bei Google Maps); nil = unbenannt. */
    func currentRoadName(_ current: LatLon) -> String? {
        let traveled = traveledDistanceAlongRoute(current)
        // 5 m Puffer: erst NACH dem Abbiegen den neuen Namen zeigen.
        let entry = roadNames.last { $0.start + 5 <= traveled } ?? roadNames.first
        guard let name = entry?.name, !name.isEmpty else { return nil }
        return name
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

    /**
     * Manöver für die Anzeige (Pfeil, Text, Distanz): [advanceIfNeeded] schaltet schon 40 m VOR dem
     * Manöver weiter (für die „Jetzt …“-Ansage) — die Anzeige soll aber das Abbiegen zeigen, bis man
     * wirklich durch ist (Nutzermeldung: beim Rechtsabbiegen stand schon das nächste Symbol da).
     * Gezeigt wird deshalb das gerade erreichte Manöver, bis es entlang der Route [passedMeters]
     * überfahren ist.
     */
    func displayedManeuver(_ current: LatLon, passedMeters: Double = 8) -> (step: NavStep, distance: Double) {
        if currentStepIndex > 0, steps[currentStepIndex].maneuverType != "arrive",
           traveledDistanceAlongRoute(current) < cumulativeManeuverDistance[currentStepIndex] + passedMeters {
            let step = steps[currentStepIndex]
            return (step, GeoUtils.distanceMeters(current, step.maneuverPoint))
        }
        return (nextManeuver(), distanceToNextManeuver(current))
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
        locate(current)?.traveled ?? 0
    }

    /**
     * Nächster Punkt auf der Routenlinie (echtes Lot auf jedes Segment). Sucht zuerst im Fenster um
     * den letzten Treffer — das folgt auch Routen, die dieselbe Straße hin und zurück nutzen, dem
     * richtigen Abschnitt — und nur ohne nahen Treffer dort die ganze Route.
     */
    private func locate(_ current: LatLon) -> Located? {
        guard routePoints.count >= 2 else { return nil }
        if let cached = lastLocated, cached.input == current { return cached.result }
        let lastIndex = routePoints.count - 2
        var result: Located?
        if let last = lastLocated?.result {
            let windowed = scan(current, max(0, last.segment - Self.windowBack)...min(lastIndex, last.segment + Self.windowAhead),
                                previousTraveled: last.traveled)
            if windowed.distance <= Self.windowAcceptMeters { result = windowed }
        }
        let located = result ?? scan(current, 0...lastIndex)
        lastLocated = (current, located)
        return located
    }

    /** Bester Treffer in [segments]; mit [previousTraveled] werden große Sprünge entlang der Route bestraft. */
    private func scan(_ current: LatLon, _ segments: ClosedRange<Int>, previousTraveled: Double? = nil) -> Located {
        var best = Located(point: routePoints[segments.lowerBound], segment: segments.lowerBound,
                           distance: .greatestFiniteMagnitude, traveled: 0)
        var bestScore = Double.greatestFiniteMagnitude
        for i in segments {
            let candidate = GeoUtils.closestPointOnSegment(current, routePoints[i], routePoints[i + 1])
            let d = GeoUtils.distanceMeters(current, candidate)
            // Ohne Strafe kann kein Treffer besser werden als sein Abstand — schnell überspringen.
            if d >= bestScore { continue }
            let traveled = cumulativePointDistance[i] + GeoUtils.distanceMeters(routePoints[i], candidate)
            let score = previousTraveled.map { d + max(0, abs(traveled - $0) - Self.jumpFreeMeters) * Self.jumpPenalty } ?? d
            if score < bestScore {
                bestScore = score
                best = Located(point: candidate, segment: i, distance: d, traveled: traveled)
            }
        }
        return best
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

    /** Nächster Punkt auf der Routenlinie. */
    private func closestRoutePoint(_ current: LatLon) -> LatLon {
        locate(current)?.point ?? routePoints.first ?? current
    }

    /**
     * Wie [snapToRoute], liefert aber zusätzlich die Fahrtrichtung der Route an dieser Stelle —
     * gemessen zu einem Punkt [lookAheadMeters] voraus, damit Kurven weich durchfahren werden.
     * Zuverlässiger als der GPS-Kurs: stimmt auch im Stand (Ampel, Navigationsstart) und hinkt
     * in Kurven nicht hinterher. nil, wenn der Fahrer weiter als [maxSnapMeters] neben der Route ist.
     */
    func snapWithBearing(_ current: LatLon, maxSnapMeters: Double = 30, lookAheadMeters: Double = 20) -> (point: LatLon, bearing: Double)? {
        guard let located = locate(current), located.distance <= maxSnapMeters else { return nil }
        let point = located.point, segment = located.segment
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

    /** In welcher Etappe (0 = aktuelle Route ab Start) liegt der Punkt [aheadMeters] vor [current]? */
    func legIndex(aheadMeters: Double, from current: LatLon) -> Int {
        let target = traveledDistanceAlongRoute(current) + aheadMeters
        var legEnd: [Int: Double] = [:]
        for (i, step) in steps.enumerated() {
            legEnd[legIndexForStep[i]] = max(legEnd[legIndexForStep[i]] ?? 0, cumulativeManeuverDistance[i] + step.distance)
        }
        let legs = legEnd.keys.sorted()
        return legs.first { (legEnd[$0] ?? 0) >= target } ?? (legs.last ?? 0)
    }

    /**
     * Routenlinie um die aktuelle Position: [behindMeters] zurück bis [aheadMeters] voraus (für die
     * schematische Ansicht im Navigations-Widget). Beginnt/endet mit Zwischenpunkten auf der Linie.
     */
    func geometryAround(_ current: LatLon, behindMeters: Double = 150, aheadMeters: Double = 1500) -> [LatLon] {
        guard let located = locate(current) else { return routePoints }
        let from = max(0, located.traveled - behindMeters), to = located.traveled + aheadMeters
        var result: [LatLon] = []
        for i in 0..<(routePoints.count - 1) {
            let a = routePoints[i], b = routePoints[i + 1]
            let da = cumulativePointDistance[i], db = cumulativePointDistance[i + 1]
            if db < from { continue }
            if da > to { break }
            func at(_ d: Double) -> LatLon {
                let f = db > da ? (d - da) / (db - da) : 0
                return LatLon(a.latitude + (b.latitude - a.latitude) * f, a.longitude + (b.longitude - a.longitude) * f)
            }
            if result.isEmpty { result.append(da < from ? at(from) : a) }
            result.append(db > to ? at(to) : b)
        }
        return result
    }

    func distanceFromRoute(_ current: LatLon) -> Double {
        locate(current)?.distance ?? 0
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

    /** Anweisungen für die Routenvorschau — dieselbe Zusammenfassung wie während der Navigation. */
    static func previewInstructions(_ route: OsrmRoute) -> [PreviewInstruction] {
        var startMeters = 0.0
        return mergeSteps(route).map { step, _ in
            let item = PreviewInstruction(
                text: step.instruction,
                icon: ManeuverIconResolver.resolve(type: step.maneuverType, modifier: step.maneuverModifier),
                startMeters: startMeters,
                distance: step.distance
            )
            startMeters += step.distance
            return item
        }
    }
}

/** Eine Zeile der Anweisungsliste: Symbol, Text, Position auf der Route und Strecke bis zum nächsten Manöver. */
struct PreviewInstruction {
    let text: String
    let icon: ManeuverIconResolver.Icon
    /** Entfernung vom Routenstart bis zu diesem Manöver. */
    let startMeters: Double
    /** Strecke ab diesem Manöver bis zum nächsten. */
    let distance: Double
}
