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

/** Knopfstil: Glas bzw. hervorgehobenes Glas ab iOS 26, sonst bordered/borderedProminent. */
private struct AdaptiveButtonStyle: ViewModifier {
    @AppStorage(LiquidGlass.settingsKey) private var enabled = true
    let prominent: Bool

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if enabled {
            if #available(iOS 26.0, *) {
                if prominent {
                    content.buttonStyle(.glassProminent)
                } else {
                    content.buttonStyle(.glass)
                }
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

    @ViewBuilder
    private func legacy(_ content: Content) -> some View {
        if prominent {
            content.buttonStyle(.borderedProminent)
        } else {
            content.buttonStyle(.bordered)
        }
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
