import AVFoundation

/** Eine auswählbare Stimme (in der App-Sprache) für die Einstellungen. */
struct VoiceOption: Identifiable, Hashable {
    let id: String
    let name: String
    let quality: AVSpeechSynthesisVoiceQuality

    var qualityLabel: String {
        switch quality {
        case .premium: return String(localized: "Premium")
        case .enhanced: return String(localized: "Erweitert")
        default: return String(localized: "Standard")
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

    /** Bevorzugte Sprachvariante: Deutsch = de-DE; Englisch = die des iPhones, falls englisch, sonst en-US. */
    private static var preferredLanguage: String {
        guard AppLanguage.isEnglish else { return "de-DE" }
        let system = AVSpeechSynthesisVoice.currentLanguageCode()
        return system.hasPrefix("en") ? system : "en-US"
    }

    /** Alle installierten Stimmen in der App-Sprache, beste Qualität zuerst. Siri-Stimmen sind für
     *  Apps nicht verfügbar und tauchen hier deshalb nicht auf. */
    static func voices() -> [VoiceOption] {
        let preferred = preferredLanguage
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(AppLanguage.code) }
            .sorted {
                if $0.quality.rawValue != $1.quality.rawValue { return $0.quality.rawValue > $1.quality.rawValue }
                if $0.language != $1.language { return $0.language == preferred }
                return $0.name < $1.name
            }
            .map { VoiceOption(id: $0.identifier, name: $0.language == preferred ? $0.name : "\($0.name) (\($0.language))", quality: $0.quality) }
    }

    /** Gewählte Stimme (nur wenn sie zur App-Sprache passt), sonst die beste installierte. */
    static func resolveVoice(_ identifier: String?) -> AVSpeechSynthesisVoice? {
        if let identifier, let voice = AVSpeechSynthesisVoice(identifier: identifier), voice.language.hasPrefix(AppLanguage.code) {
            return voice
        }
        if let best = voices().first { return AVSpeechSynthesisVoice(identifier: best.id) }
        return AVSpeechSynthesisVoice(language: preferredLanguage)
    }

    /** [interrupt] = laufende/wartende Ansagen verwerfen (z.B. Neuberechnung, Hörprobe); sonst
     *  wird eingereiht, damit "Jetzt …" und eine direkt folgende Vorankündigung sich nicht
     *  gegenseitig abschneiden. */
    func speak(_ text: String, voiceIdentifier: String? = nil, rate: Float = SpeechService.defaultRate,
               volume: Float = 1, duckOthers: Bool = true, interrupt: Bool = false) {
        releaseGeneration += 1
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
        Task { @MainActor in self.scheduleRelease() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.scheduleRelease() }
    }

    // MARK: - Musik wieder lauter

    /** Zählt hoch bei jeder neuen Ansage — eine geplante Freigabe gilt nur, wenn seitdem nichts kam. */
    private var releaseGeneration = 0

    /**
     * Audio-Session freigeben, damit die Musik wieder lauter wird. NICHT direkt im didFinish: dort
     * meldet `isSpeaking` oft noch true (Freigabe wurde übersprungen → Musik blieb leise,
     * Nutzermeldung), und `setActive(false)` scheitert, solange die Ausgabe noch läuft. Deshalb kurz
     * warten, dann prüfen; scheitert es trotzdem, noch zweimal versuchen.
     */
    private func scheduleRelease(attempt: Int = 0) {
        let generation = releaseGeneration
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: attempt == 0 ? 300_000_000 : 700_000_000)
            guard generation == self.releaseGeneration, !self.synthesizer.isSpeaking else { return }
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            } catch {
                if attempt < 2 { self.scheduleRelease(attempt: attempt + 1) }
            }
        }
    }
}
