import Foundation

/** OSRM liefert keinen Freitext, nur strukturierte Felder — Anweisungen werden hier auf Deutsch
 *  zusammengesetzt (Port von `InstructionFormatter.kt`). */
enum InstructionFormatter {

    static func format(_ step: OsrmStep) -> String {
        if AppLanguage.isEnglish { return EnglishInstructions.format(step) }
        let m = step.maneuver
        let road = step.name.trimmingCharacters(in: .whitespaces).isEmpty ? "der Straße" : step.name

        let base: String
        switch m.type {
        case "depart": base = "Los geht's auf \(road)"
        case "arrive": base = "Sie haben Ihr Ziel erreicht"
        case "roundabout", "rotary": base = "Nehmen Sie die \(m.exit ?? 1). Ausfahrt am Kreisverkehr auf \(road)"
        case "turn": base = "Biegen Sie \(directionText(m.modifier)) ab auf \(road)"
        case "merge": base = "Einfädeln auf \(road)"
        case "off ramp": base = "Nehmen Sie die Ausfahrt\(exitSuffix(step))"
        case "fork": base = "Halten Sie sich \(directionText(m.modifier)) auf \(road)"
        case "end of road": base = "Am Ende der Straße \(directionText(m.modifier)) abbiegen auf \(road)"
        // OSRM stuft spürbare Richtungsänderungen manchmal als "new name"/"continue" ein —
        // modifier trotzdem mit ansagen, sonst verschluckt die App echte Abbiegungen.
        default: base = continueText(road, m.modifier)
        }

        if m.type != "off ramp" && (step.exits != nil || step.destinations != nil) {
            return base + exitSuffix(step)
        }
        return base
    }

    /**
     * Kurze Navi-Form fürs Ansagen ("rechts abbiegen auf Hauptstraße") — wird mit "In 500 Metern"
     * bzw. "Jetzt" kombiniert, siehe [AnnouncementPlanner]. Bei "arrive" ein vollständiger Satzteil.
     */
    static func action(_ step: OsrmStep, includeDestinations: Bool = true) -> String {
        if AppLanguage.isEnglish { return EnglishInstructions.action(step, includeDestinations: includeDestinations) }
        let m = step.maneuver
        let hasName = !step.name.trimmingCharacters(in: .whitespaces).isEmpty
        let onto = hasName ? " auf \(step.name)" : ""
        let direction = directionText(m.modifier)
        let suffix = includeDestinations && m.type != "off ramp" ? exitSuffix(step) : ""

        let text: String
        switch m.type {
        case "arrive": return "erreichen Sie Ihr Ziel"
        case "depart": text = hasName ? "starten auf \(step.name)" : "losfahren"
        case "roundabout", "rotary": text = "im Kreisverkehr die \(m.exit ?? 1). Ausfahrt nehmen\(onto)"
        case "off ramp": text = "die Ausfahrt nehmen\(includeDestinations ? exitSuffix(step) : "")"
        case "merge": text = hasName ? "auf \(step.name) einfädeln" : "einfädeln"
        case "fork": text = "\(direction.isEmpty ? "geradeaus" : direction) halten\(onto)"
        case "end of road": text = "am Ende der Straße \(direction) abbiegen\(onto)"
        default:
            if m.modifier == "uturn" {
                text = "wenden"
            } else if m.type == "turn" && !direction.isEmpty && direction != "geradeaus" {
                text = "\(direction) abbiegen\(onto)"
            } else if direction.isEmpty || direction == "geradeaus" {
                text = "geradeaus weiter\(onto)"
            } else {
                text = "\(direction) weiterfahren\(onto)"
            }
        }
        return text + suffix
    }

    private static func continueText(_ road: String, _ modifier: String?) -> String {
        let direction = directionText(modifier)
        return direction.isEmpty || direction == "geradeaus" ? "Weiter auf \(road)" : "Weiter \(direction) auf \(road)"
    }

    private static func exitSuffix(_ step: OsrmStep) -> String {
        let parts = [step.exits.map { "Ausfahrt \($0)" }, step.destinations.map { "Richtung \($0)" }].compactMap { $0 }
        return parts.isEmpty ? "" : " (\(parts.joined(separator: ", ")))"
    }

    private static func directionText(_ modifier: String?) -> String {
        switch modifier {
        case "left": return "links"
        case "right": return "rechts"
        case "slight left": return "leicht links"
        case "slight right": return "leicht rechts"
        case "sharp left": return "scharf links"
        case "sharp right": return "scharf rechts"
        case "uturn": return "wenden"
        case "straight": return "geradeaus"
        default: return ""
        }
    }
}
