import Foundation

enum FormatUtils {

    private static let etaFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let decimalFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "de_DE")
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
        return minutes >= 60 ? "\(minutes / 60) Std. \(minutes % 60) Min." : "\(minutes) Min."
    }

    static func formatEta(_ remainingSeconds: Double) -> String {
        etaFormatter.string(from: Date().addingTimeInterval(remainingSeconds))
    }
}
