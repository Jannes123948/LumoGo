import Foundation

enum FormatUtils {

    private static let etaFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let decimalFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = AppLanguage.locale
        f.minimumFractionDigits = 1
        f.maximumFractionDigits = 1
        return f
    }()

    /**
     * Rundet auf "glatte" Werte statt exakter Meterzahlen (wie Google Maps: "in 50 m", nicht
     * "in 47 m") — glatte Zahlen lassen sich beim Fahren leichter erfassen.
     */
    static func formatDistance(_ meters: Double) -> String {
        if meters >= 1000 {
            let km = meters / 1000
            if km >= 10 {
                return "\(Int(km.rounded())) km"
            }
            let rounded = (km * 10).rounded() / 10
            return "\(decimalFormatter.string(from: NSNumber(value: rounded)) ?? "\(rounded)") km"
        }
        return "\(roundToNiceMeters(meters)) m"
    }

    private static func roundToNiceMeters(_ meters: Double) -> Int {
        let step: Double = meters < 10 ? 1 : (meters < 100 ? 10 : 50)
        return Int((meters / step).rounded() * step)
    }

    static func formatDuration(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        return minutes >= 60 ? String(localized: "\(minutes / 60) Std. \(minutes % 60) Min.") : String(localized: "\(minutes) Min.")
    }

    /** Zahl mit festen Nachkommastellen im Format der App-Sprache („1,5“ bzw. „1.5“). */
    static func decimal(_ value: Double, digits: Int) -> String {
        value.formatted(.number.precision(.fractionLength(digits)).grouping(.never).locale(AppLanguage.locale))
    }

    static func formatEta(_ remainingSeconds: Double) -> String {
        etaFormatter.string(from: Date().addingTimeInterval(remainingSeconds))
    }
}
