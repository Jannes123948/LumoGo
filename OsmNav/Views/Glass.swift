import SwiftUI

/**
 * Liquid Glass ab iOS 26, auf iOS 16–25 bleibt der bisherige Look (Material/Farbflächen).
 *
 * Zwei Bedingungen müssen erfüllt sein: Die App wurde mit dem iOS-26-SDK gebaut (Xcode 26,
 * Swift ≥ 6.2 — mit Xcode 16 wird der Glass-Code per `#if compiler` gar nicht erst kompiliert)
 * UND sie läuft auf iOS 26 oder neuer. Zusätzlich lässt es sich in den Einstellungen abschalten
 * (`liquid_glass`, gleicher Schlüssel wie `AppSettings.liquidGlass`).
 *
 * Systemelemente (Blätter, Navigationsleisten, Formulare, Alerts) bekommen Liquid Glass mit dem
 * iOS-26-SDK automatisch; diese Helfer betreffen nur die eigenen Elemente über der Karte.
 */
enum LiquidGlass {
    static let settingsKey = "liquid_glass"

    /** Gerät + Build können Liquid Glass (unabhängig von der Einstellung). */
    static var isAvailable: Bool {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) { return true }
        #endif
        return false
    }
}

/** Glas-Fläche in [shape]; ohne Liquid Glass: [fallback] als Hintergrund + Schatten. */
private struct GlassSurface<S: Shape>: ViewModifier {
    @AppStorage(LiquidGlass.settingsKey) private var enabled = true
    let shape: S
    let tint: Color?
    let interactive: Bool
    let fallback: AnyShapeStyle
    let shadowRadius: CGFloat

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if enabled {
            if #available(iOS 26.0, *) {
                content.glassEffect(glass, in: shape)
            } else {
                legacy(content)
            }
        } else {
            legacy(content)
        }
        #else
        legacy(content)
        #endif
    }

    #if compiler(>=6.2)
    @available(iOS 26.0, *)
    private var glass: Glass {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return glass
    }
    #endif

    private func legacy(_ content: Content) -> some View {
        content
            .background(fallback, in: shape)
            .shadow(color: .black.opacity(shadowRadius > 0 ? 0.22 : 0), radius: shadowRadius, y: shadowRadius > 0 ? 2 : 0)
    }
}

/** Knopfstil: Glas bzw. hervorgehobenes Glas ab iOS 26, sonst bordered/borderedProminent.
 *  Hervorgehobene Knöpfe bekommen die eingestellte Knopfschrift (sonst weiße Schrift auf weißem Knopf). */
private struct AdaptiveButtonStyle: ViewModifier {
    @AppStorage(LiquidGlass.settingsKey) private var enabled = true
    @AppStorage(ColorKeys.accent) private var accent = Int(ColorKeys.defaultAccent)
    @AppStorage(ColorKeys.buttonText) private var buttonText = ColorKeys.auto
    let prominent: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if prominent {
            // Eigener Stil statt .borderedProminent/.glassProminent: die nehmen die Systemfarbe `tint`
            // (jetzt die lesbare Textfarbe) als Füllung und überschreiben teils die Schriftfarbe.
            content.buttonStyle(ProminentButtonStyle(fill: Color(hex: UInt32(max(accent, 0))),
                                                     text: Color(hex: ColorKeys.buttonText(accent: accent, buttonText: buttonText)),
                                                     glass: enabled && LiquidGlass.isAvailable))
        } else {
            styled(content)
        }
    }

    @ViewBuilder
    private func styled(_ content: Content) -> some View {
        #if compiler(>=6.2)
        if enabled {
            if #available(iOS 26.0, *) {
                content.buttonStyle(.glass)
            } else {
                content.buttonStyle(.bordered)
            }
        } else {
            content.buttonStyle(.bordered)
        }
        #else
        content.buttonStyle(.bordered)
        #endif
    }
}

/** Gefüllter Knopf in genau der gewählten Oberflächenfarbe mit genau der gewählten Knopfschrift. */
private struct ProminentButtonStyle: ButtonStyle {
    let fill: Color
    let text: Color
    let glass: Bool
    @Environment(\.controlSize) private var controlSize
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let large = controlSize == .large
        let label = configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(text)
            .padding(.horizontal, large ? 16 : 12)
            .padding(.vertical, large ? 14 : 8)
        Group {
            #if compiler(>=6.2)
            if glass {
                if #available(iOS 26.0, *) {
                    label.glassEffect(.regular.tint(fill).interactive(), in: Capsule())
                } else {
                    solid(label, large: large, pressed: configuration.isPressed)
                }
            } else {
                solid(label, large: large, pressed: configuration.isPressed)
            }
            #else
            solid(label, large: large, pressed: configuration.isPressed)
            #endif
        }
        .opacity(isEnabled ? 1 : 0.45)
    }

    private func solid(_ label: some View, large: Bool, pressed: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: large ? 12 : 8, style: .continuous)
        return label
            .background(fill, in: shape)
            // Weiße Fläche auf hellem Grund: dünner Rand, sonst ist der Knopf nicht zu erkennen.
            .overlay(shape.strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
            .opacity(pressed ? 0.75 : 1)
    }
}

/** Fasst Glas-Elemente zusammen, damit sie ab iOS 26 ineinanderfließen; sonst wirkungslos. */
struct GlassGroup<Content: View>: View {
    @AppStorage(LiquidGlass.settingsKey) private var enabled = true
    var spacing: CGFloat = 10
    @ViewBuilder let content: Content

    var body: some View {
        #if compiler(>=6.2)
        if enabled {
            if #available(iOS 26.0, *) {
                GlassEffectContainer(spacing: spacing) { content }
            } else {
                content
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

extension View {
    /** Panel über der Karte (Suchleiste, Routen-Panel, Ergebnisliste). */
    func glassCard(cornerRadius: CGFloat = 16) -> some View {
        modifier(GlassSurface(shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous), tint: nil,
                              interactive: false, fallback: AnyShapeStyle(Color(.systemBackground)), shadowRadius: 6))
    }

    /** Runder Kartenknopf. */
    func glassCircle() -> some View {
        modifier(GlassSurface(shape: Circle(), tint: nil, interactive: true,
                              fallback: AnyShapeStyle(.regularMaterial), shadowRadius: 3))
    }

    /** Eingefärbte Fläche (Navigationsleisten): Glas mit Farbton, sonst die Farbe selbst. */
    func glassPanel(tint: Color, cornerRadius: CGFloat = 18) -> some View {
        modifier(GlassSurface(shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous), tint: tint,
                              interactive: false, fallback: AnyShapeStyle(tint), shadowRadius: 6))
    }

    /** Beliebige Form mit optionalem Farbton und eigenem Rückfall-Hintergrund. */
    func glassSurface<S: Shape>(_ shape: S, tint: Color? = nil, fallback: some ShapeStyle, shadowRadius: CGFloat = 3) -> some View {
        modifier(GlassSurface(shape: shape, tint: tint, interactive: false, fallback: AnyShapeStyle(fallback), shadowRadius: shadowRadius))
    }

    func adaptiveButtonStyle(prominent: Bool) -> some View {
        modifier(AdaptiveButtonStyle(prominent: prominent))
    }
}
