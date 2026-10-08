import AVFoundation

/** Eine auswählbare deutsche Stimme für die Einstellungen. */
struct VoiceOption: Identifiable, Hashable {
    let id: String
    let name: String
    let quality: AVSpeechSynthesisVoiceQuality

    var qualityLabel: String {
        switch quality {
        case .premium: return "Premium"
        case .enhanced: return "Erweitert"
        default: return "Standard"
        }
    }
}

/**
 * Deutsche Sprachausgabe (Pendant zu Androids TextToSpeech). Die Audio-Session wird nur fürs
 * Sprechen aktiviert und senkt andere Audioquellen (Musik) währenddessen ab ("ducking").
 *
 * Ohne eigene Wahl wird die BESTE installierte deutsche Stimme genommen (Premium > Erweitert >
 * Standard) — `AVSpeechSynthesisVoice(language: "de-DE")` liefert sonst meist die blecherne
 * "kompakte" Variante, auch wenn bessere Stimmen auf dem Gerät liegen.
 *
 * `@MainActor`: `AVSpeechSynthesizerDelegate` macht die Klasse implizit `Sendable`, der
 * Synthesizer selbst ist es aber nicht — ohne feste Actor-Bindung meldet der Compiler das
 * (in Swift 6 als Fehler). Der Delegate-Callback ist `nonisolated` und nutzt nur seine Parameter.
 */
@MainActor
final class SpeechService: NSObject, AVSpeechSynthesizerDelegate {

    /** Standard-Sprechtempo — etwas zügiger als iOS' Vorgabe (0,5), wirkt beim Fahren natürlicher. */
    nonisolated static let defaultRate: Float = 0.52

    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /** Alle installierten deutschen Stimmen, beste Qualität zuerst. Siri-Stimmen sind für Apps
     *  nicht verfügbar und tauchen hier deshalb nicht auf. */
    static func germanVoices() -> [VoiceOption] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("de") }
            .sorted {
                if $0.quality.rawValue != $1.quality.rawValue { return $0.quality.rawValue > $1.quality.rawValue }
                if $0.language != $1.language { return $0.language == "de-DE" }
                return $0.name < $1.name
            }
            .map { VoiceOption(id: $0.identifier, name: $0.language == "de-DE" ? $0.name : "\($0.name) (\($0.language))", quality: $0.quality) }
    }

    /** Gewählte Stimme, sonst die beste installierte deutsche. */
    static func resolveVoice(_ identifier: String?) -> AVSpeechSynthesisVoice? {
        if let identifier, let voice = AVSpeechSynthesisVoice(identifier: identifier) { return voice }
        if let best = germanVoices().first { return AVSpeechSynthesisVoice(identifier: best.id) }
        return AVSpeechSynthesisVoice(language: "de-DE")
    }

    /** [interrupt] = laufende/wartende Ansagen verwerfen (z.B. Neuberechnung, Hörprobe); sonst
     *  wird eingereiht, damit "Jetzt …" und eine direkt folgende Vorankündigung sich nicht
     *  gegenseitig abschneiden. */
    func speak(_ text: String, voiceIdentifier: String? = nil, rate: Float = SpeechService.defaultRate,
               volume: Float = 1, duckOthers: Bool = true, interrupt: Bool = false) {
        if interrupt && synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        // [duckOthers] = Musik während der Ansage leiser, sonst nur darüber mischen.
        let options: AVAudioSession.CategoryOptions = duckOthers
            ? [.duckOthers, .interruptSpokenAudioAndMixWithOthers]
            : [.mixWithOthers, .interruptSpokenAudioAndMixWithOthers]
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .voicePrompt, options: options)
        try? AVAudioSession.sharedInstance().setActive(true)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.resolveVoice(voiceIdentifier)
        utterance.rate = rate
        utterance.volume = volume
        utterance.prefersAssistiveTechnologySettings = false
        synthesizer.speak(utterance)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        guard !synthesizer.isSpeaking else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
