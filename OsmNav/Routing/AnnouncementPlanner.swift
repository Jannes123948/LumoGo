import Foundation

/**
 * Entscheidet, wann welche Sprachansage kommt — wie bei Google Maps mit Vorankündigungen:
 *  - Stadt/Landstraße: "In 1 Kilometer …", "In 500 Metern …", "In 200 Metern …"
 *  - ab ~80 km/h (Autobahn): "In 2 Kilometern …", "In 1 Kilometer …", "In 500 Metern …"
 *  - am Manöver selbst (wenn [RouteProgressTracker.advanceIfNeeded] vorrückt): "Jetzt …"
 *  - folgt das übernächste Manöver dicht danach: "… Danach links halten."
 * Pro Manöver kommt jede Stufe höchstens einmal; Stufen, an denen der Fahrer beim Start des
 * Schritts schon vorbei ist, werden übersprungen (kein "In 1 Kilometer" bei 600 m Abstand).
 */
final class AnnouncementPlanner {

    private static let cityStages: [Double] = [1000, 500, 200]
    private static let highwayStages: [Double] = [2000, 1000, 500]
    private static let highwaySpeedMps = 80 / 3.6
    /** Bis zu diesem Abstand wird das übernächste Manöver mit "Danach …" angehängt. */
    private static let chainDistanceMeters = 150.0

    /** „Danach …“ anhängen (Einstellung). */
    var chainEnabled = true

    private var stepIndex = -1
    private var spokenStages = Set<Double>()

    func reset() {
        stepIndex = -1
        spokenStages = []
    }

    /** Ansage beim Erreichen eines Manövers ("Jetzt …"), nil = nichts zu sagen. */
    func maneuverReached(_ tracker: RouteProgressTracker) -> String? {
        let step = tracker.currentStep()
        // Die Ankunft sagt die Navigation selbst an (erst bei < 15 m) — hier nicht doppelt.
        if step.maneuverType == "arrive" { return nil }
        let main = AppLanguage.isEnglish ? EnglishInstructions.now(step.spokenActionShort) : "Jetzt \(step.spokenActionShort)"
        return sentence(main, tracker: tracker, chainFrom: 1)
    }

    /** Vorankündigung fürs nächste Manöver, falls gerade eine Stufe erreicht wurde. */
    func preAnnouncement(_ tracker: RouteProgressTracker, distanceToNext: Double, speedMps: Double) -> String? {
        guard let next = tracker.maneuver(after: 1) else { return nil }
        let stages = speedMps > Self.highwaySpeedMps ? Self.highwayStages : Self.cityStages

        if tracker.currentStepIndex != stepIndex {
            stepIndex = tracker.currentStepIndex
            // Stufen, die beim Start dieses Schritts schon unterschritten sind, überspringen —
            // die nächstkleinere kommt dann zur richtigen Zeit.
            spokenStages = Set(stages.filter { $0 > distanceToNext + 50 })
            spokenStages.formUnion((Self.cityStages + Self.highwayStages).filter { $0 > distanceToNext + 50 })
        }

        // Kleinste erreichte, noch nicht gesagte Stufe (bei einem GPS-Sprung über mehrere Stufen
        // nur die aktuellste ansagen).
        guard let stage = stages.filter({ distanceToNext <= $0 && !spokenStages.contains($0) }).min() else { return nil }
        stages.filter { $0 >= stage }.forEach { spokenStages.insert($0) }
        // Auch Stufen knapp unter der echten Distanz gelten als erledigt — sonst käme nach
        // "In einem Kilometer" (bei 1,1 km) gleich nochmal "In einem Kilometer" (bei 1,0 km).
        stages.filter { $0 >= distanceToNext * 0.85 }.forEach { spokenStages.insert($0) }
        // Zu nah am Manöver: übernimmt gleich die "Jetzt"-Ansage.
        if distanceToNext < 60 { return nil }

        // Normalfall: Stufe gerade erreicht → Stufenwert ("In 500 Metern"). Liegt die echte Distanz
        // deutlich darunter (Tempowechsel Stadt→Autobahn mitten im Abschnitt, GPS-Sprung), die
        // gerundete echte Distanz sagen statt z.B. "In 2 Kilometern" bei 1,2 km.
        let spoken = distanceToNext >= stage * 0.85 ? stage : Self.roundForSpeech(distanceToNext)
        let lead = AppLanguage.isEnglish ? EnglishInstructions.lead(spoken) : "In \(Self.spokenDistance(spoken))"
        if next.maneuverType == "arrive" {
            return "\(lead) \(next.spokenAction)."
        }
        return sentence("\(lead) \(next.spokenAction)", tracker: tracker, chainFrom: stage <= 500 ? 2 : nil)
    }

    /** Hängt "Danach …" an, wenn das Manöver nach [chainFrom] dicht folgt. */
    private func sentence(_ main: String, tracker: RouteProgressTracker, chainFrom offset: Int?) -> String {
        guard chainEnabled, let offset,
              let first = tracker.maneuver(after: offset - 1),
              let following = tracker.maneuver(after: offset),
              first.distance <= Self.chainDistanceMeters else { return main + "." }
        if AppLanguage.isEnglish {
            return following.maneuverType == "arrive"
                ? "\(main). \(EnglishInstructions.thenArrive)"
                : "\(main). \(EnglishInstructions.then(following.spokenActionShort))"
        }
        if following.maneuverType == "arrive" {
            return "\(main). Danach erreichen Sie Ihr Ziel."
        }
        return "\(main). Danach \(following.spokenActionShort)."
    }

    /** Unter 1 km auf 100 m, darüber auf 0,5 km gerundet. */
    static func roundForSpeech(_ meters: Double) -> Double {
        meters < 1000 ? max(100, (meters / 100).rounded() * 100) : (meters / 500).rounded() * 500
    }

    /** "einem Kilometer", "2 Kilometern", "1,5 Kilometern", "500 Metern" (Dativ nach "In"). */
    static func spokenDistance(_ meters: Double) -> String {
        if meters < 1000 { return "\(Int(meters)) Metern" }
        let km = meters / 1000
        if km == 1 { return "einem Kilometer" }
        if km == km.rounded() { return "\(Int(km)) Kilometern" }
        return String(format: "%.1f", km).replacingOccurrences(of: ".", with: ",") + " Kilometern"
    }
}
