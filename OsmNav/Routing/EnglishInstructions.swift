import Foundation

/**
 * Englische Anweisungen und Ansageformen — Gegenstück zu [InstructionFormatter] und den Sätzen in
 * [AnnouncementPlanner]. Eigene Grammatik statt übersetzter Satzbausteine (Wortstellung, Ordinalzahlen,
 * „In 500 meters, turn right onto …“).
 */
enum EnglishInstructions {

    static func format(_ step: OsrmStep) -> String {
        let m = step.maneuver
        let road = step.name.trimmingCharacters(in: .whitespaces).isEmpty ? "the road" : step.name
        let direction = directionText(m.modifier)

        let base: String
        switch m.type {
        case "depart": base = "Head out on \(road)"
        case "arrive": base = "You have arrived at your destination"
        case "roundabout", "rotary": base = "At the roundabout, take the \(ordinal(m.exit ?? 1)) exit onto \(road)"
        case "turn": base = m.modifier == "uturn" ? "Make a U-turn onto \(road)" : "Turn \(direction) onto \(road)"
        case "merge": base = "Merge onto \(road)"
        case "off ramp": base = "Take the exit\(exitSuffix(step))"
        case "fork": base = "Keep \(direction.isEmpty ? "straight" : direction) onto \(road)"
        case "end of road": base = "At the end of the road, turn \(direction) onto \(road)"
        default:
            base = direction.isEmpty || direction == "straight" ? "Continue onto \(road)" : "Continue \(direction) onto \(road)"
        }
        if m.type != "off ramp" && (step.exits != nil || step.destinations != nil) {
            return base + exitSuffix(step)
        }
        return base
    }

    /** Kurzform für Ansagen: „turn right onto Main Street“ (klein, wird mit „In 500 meters,“ kombiniert). */
    static func action(_ step: OsrmStep, includeDestinations: Bool = true) -> String {
        let m = step.maneuver
        let hasName = !step.name.trimmingCharacters(in: .whitespaces).isEmpty
        let onto = hasName ? " onto \(step.name)" : ""
        let direction = directionText(m.modifier)
        let suffix = includeDestinations && m.type != "off ramp" ? exitSuffix(step) : ""

        let text: String
        switch m.type {
        case "arrive": return "you will reach your destination"
        case "depart": text = hasName ? "head out on \(step.name)" : "set off"
        case "roundabout", "rotary": text = "take the \(ordinal(m.exit ?? 1)) exit at the roundabout\(onto)"
        case "off ramp": text = "take the exit\(includeDestinations ? exitSuffix(step) : "")"
        case "merge": text = hasName ? "merge onto \(step.name)" : "merge"
        case "fork": text = "keep \(direction.isEmpty ? "straight" : direction)\(onto)"
        case "end of road": text = "turn \(direction) at the end of the road\(onto)"
        default:
            if m.modifier == "uturn" {
                text = "make a U-turn"
            } else if m.type == "turn" && !direction.isEmpty && direction != "straight" {
                text = "turn \(direction)\(onto)"
            } else if direction.isEmpty || direction == "straight" {
                text = "continue straight\(onto)"
            } else {
                text = "continue \(direction)\(onto)"
            }
        }
        return text + suffix
    }

    // MARK: - Ansagen

    static func now(_ action: String) -> String { "Now \(action)" }
    static func lead(_ meters: Double) -> String { "In \(spokenDistance(meters)),"}
    static func then(_ action: String) -> String { "Then \(action)." }
    static let thenArrive = "Then you will reach your destination."

    /** „500 meters“, „1 kilometer“, „1.5 kilometers“. */
    static func spokenDistance(_ meters: Double) -> String {
        if meters < 1000 { return "\(Int(meters)) meters" }
        let km = meters / 1000
        if km == 1 { return "1 kilometer" }
        if km == km.rounded() { return "\(Int(km)) kilometers" }
        return String(format: "%.1f kilometers", km)
    }

    static func ordinal(_ n: Int) -> String {
        let suffix: String
        switch (n % 10, n % 100) {
        case (1, let t) where t != 11: suffix = "st"
        case (2, let t) where t != 12: suffix = "nd"
        case (3, let t) where t != 13: suffix = "rd"
        default: suffix = "th"
        }
        return "\(n)\(suffix)"
    }

    private static func exitSuffix(_ step: OsrmStep) -> String {
        let parts = [step.exits.map { "exit \($0)" }, step.destinations.map { "towards \($0)" }].compactMap { $0 }
        return parts.isEmpty ? "" : " (\(parts.joined(separator: ", ")))"
    }

    private static func directionText(_ modifier: String?) -> String {
        switch modifier {
        case "left": return "left"
        case "right": return "right"
        case "slight left": return "slightly left"
        case "slight right": return "slightly right"
        case "sharp left": return "sharp left"
        case "sharp right": return "sharp right"
        case "uturn": return "around"
        case "straight": return "straight"
        default: return ""
        }
    }
}
