import SwiftUI
import WidgetKit

/**
 * Navigations-Widget (Homescreen, klein/mittel/groß) — Ersatz für Androids Bild-im-Bild: verlässt man
 * die App während der Navigation, zeigt es Abbiegen, Entfernung, Ankunft und eine schematische Route.
 * Daten kommen per App Group von der App ([NavWidgetStore]); iOS entscheidet, wie oft neu gezeichnet wird.
 */
struct NavigationWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: NavWidgetStore.widgetKind, provider: NavProvider()) { entry in
            NavWidgetView(entry: entry)
        }
        .configurationDisplayName("LumoGo Navigation")
        .description("Zeigt während der Navigation das nächste Abbiegen und die Route — auch wenn die App nicht offen ist.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct NavEntry: TimelineEntry {
    let date: Date
    let state: NavWidgetState
    /** Schon länger keine Daten mehr von der App (beendet/abgestürzt) → nicht mehr als aktuell zeigen. */
    let stale: Bool

    var showsNavigation: Bool { state.active && !stale }
}

struct NavProvider: TimelineProvider {
    /** Nach so langer Funkstille gilt die Navigation als nicht mehr aktuell. */
    private static let staleAfter: TimeInterval = 180

    func placeholder(in context: Context) -> NavEntry { NavEntry(date: Date(), state: Self.sample, stale: false) }

    func getSnapshot(in context: Context, completion: @escaping (NavEntry) -> Void) {
        // Widget-Galerie: Beispiel zeigen, damit man sieht, wie es während der Navigation aussieht.
        let state = NavWidgetStore.load()
        completion(NavEntry(date: Date(), state: context.isPreview && !state.active ? Self.sample : state, stale: false))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NavEntry>) -> Void) {
        let state = NavWidgetStore.load()
        let now = Date()
        let staleAt = state.updatedAt.addingTimeInterval(Self.staleAfter)
        var entries = [NavEntry(date: now, state: state, stale: state.active && staleAt <= now)]
        if state.active && staleAt > now {
            entries.append(NavEntry(date: staleAt, state: state, stale: true))
        }
        // Neu geladen wird, wenn die App es anstößt.
        completion(Timeline(entries: entries, policy: .never))
    }

    static let sample = NavWidgetState(
        active: true, distanceText: "300 m", instruction: "Rechts abbiegen auf Hauptstraße",
        symbolName: "arrow.turn.up.right", symbolRotation: 0, thenInstruction: "Links halten auf B 6",
        etaText: "17:42", remainingText: "12 km · 18 Min.", destination: "Zuhause", updatedAt: Date(),
        backgroundHex: 0x1B5E20, textHex: 0xFFFFFF, routeHex: 0x2962FF,
        route: [[0, -120], [0, 0], [0, 300], [8, 330], [180, 340], [420, 360]], maneuver: [0, 300]
    )
}

// MARK: - Ansichten

private struct NavWidgetView: View {
    let entry: NavEntry
    @Environment(\.widgetFamily) private var family

    private var background: Color { Color(widgetHex: entry.state.backgroundHex) }
    private var text: Color { Color(widgetHex: entry.state.textHex) }

    var body: some View {
        Group {
            if entry.showsNavigation {
                switch family {
                case .systemSmall: small
                case .systemMedium: medium
                default: large
                }
            } else {
                IdleNavView(stale: entry.state.active && entry.stale, compact: family == .systemSmall)
            }
        }
        .widgetURL(DeepLink.open.url)
        .navWidgetBackground(entry.showsNavigation
                             ? AnyShapeStyle(background)
                             : AnyShapeStyle(LinearGradient(colors: [Brand.top, Brand.bottom], startPoint: .top, endPoint: .bottom)))
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 6) {
                maneuverIcon(size: 30)
                Text(entry.state.distanceText)
                    .font(.system(size: 24, weight: .bold)).monospacedDigit()
                    .minimumScaleFactor(0.6).lineLimit(1)
            }
            Text(entry.state.instruction)
                .font(.system(size: 13, weight: .semibold)).lineLimit(3)
            Spacer(minLength: 0)
            Text("Ankunft \(entry.state.etaText)").font(.caption.weight(.semibold)).opacity(0.85)
        }
        .foregroundStyle(text)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(14)
    }

    private var medium: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    maneuverIcon(size: 32)
                    Text(entry.state.distanceText)
                        .font(.system(size: 26, weight: .bold)).monospacedDigit()
                        .minimumScaleFactor(0.6).lineLimit(1)
                }
                Text(entry.state.instruction).font(.subheadline.weight(.semibold)).lineLimit(2)
                Spacer(minLength: 0)
                Text("Ankunft \(entry.state.etaText)").font(.caption.weight(.bold))
                Text(entry.state.remainingText).font(.caption2).opacity(0.8)
            }
            .foregroundStyle(text)
            .frame(maxWidth: .infinity, alignment: .leading)
            RouteSchematic(state: entry.state, metersAhead: 450)
                .frame(width: 130)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .padding(12)
    }

    private var large: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                maneuverIcon(size: 40)
                VStack(alignment: .leading, spacing: 0) {
                    Text(entry.state.distanceText).font(.system(size: 30, weight: .bold)).monospacedDigit()
                    Text(entry.state.instruction).font(.headline).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(text)
            RouteSchematic(state: entry.state, metersAhead: 600)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            if let then = entry.state.thenInstruction {
                Label("Danach: \(then)", systemImage: "arrow.turn.down.right")
                    .font(.footnote.weight(.semibold)).lineLimit(1)
                    .foregroundStyle(text.opacity(0.9))
            }
            HStack {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Ankunft \(entry.state.etaText)").font(.headline)
                    Text(entry.state.remainingText).font(.caption).opacity(0.8)
                }
                Spacer()
                Label(entry.state.destination, systemImage: "flag.checkered")
                    .font(.caption.weight(.semibold)).lineLimit(1)
            }
            .foregroundStyle(text)
        }
        .padding(14)
    }

    private func maneuverIcon(size: CGFloat) -> some View {
        Image(systemName: entry.state.symbolName)
            .font(.system(size: size, weight: .bold))
            .rotationEffect(.degrees(entry.state.symbolRotation))
    }
}

/** Ohne laufende Navigation (oder App beendet): Hinweis + Abkürzung „Nach Hause“. */
private struct IdleNavView: View {
    let stale: Bool
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: stale ? "exclamationmark.triangle.fill" : "location.north.line.fill")
                .font(.system(size: compact ? 24 : 28, weight: .bold)).foregroundStyle(Brand.glow)
            Text(stale ? "Navigation nicht aktuell" : "Keine Navigation").font(.headline).foregroundStyle(.white)
            Text(stale ? "LumoGo öffnen, um weiterzufahren." : "Startet die Navigation, erscheint sie hier.")
                .font(.caption).foregroundStyle(.white.opacity(0.75)).lineLimit(3)
            Spacer(minLength: 0)
            if !compact {
                Link(destination: DeepLink.home.url) {
                    Label("Nach Hause", systemImage: "house.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Brand.bottom)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Brand.glow, in: Capsule())
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(14)
    }
}

/**
 * Schematische Route (keine echte Karte — die gibt es im Hintergrund nicht): Fahrtrichtung oben,
 * eigener Pfeil unten in der Mitte, [metersAhead] Meter voraus bis zum oberen Rand.
 */
private struct RouteSchematic: View {
    let state: NavWidgetState
    let metersAhead: Double

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let origin = CGPoint(x: size.width / 2, y: size.height * 0.78)
            let scale = origin.y / metersAhead
            let toPoint: ([Double]) -> CGPoint = { p in
                CGPoint(x: origin.x + p[0] * scale, y: origin.y - p[1] * scale)
            }
            ZStack {
                Color.black.opacity(0.22)
                RouteLine(points: state.route.map(toPoint))
                    .stroke(Color.white.opacity(0.85), style: StrokeStyle(lineWidth: 11, lineCap: .round, lineJoin: .round))
                RouteLine(points: state.route.map(toPoint))
                    .stroke(Color(widgetHex: state.routeHex), style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
                if let maneuver = state.maneuver {
                    Circle()
                        .fill(Color.white)
                        .overlay(Circle().stroke(Color(widgetHex: state.routeHex), lineWidth: 3))
                        .frame(width: 14, height: 14)
                        .position(toPoint(maneuver))
                }
                PuckArrow()
                    .fill(Color.white)
                    .overlay(PuckArrow().stroke(Color.black.opacity(0.6), lineWidth: 1.5))
                    .frame(width: 20, height: 24)
                    .position(origin)
            }
        }
    }
}

private struct RouteLine: Shape {
    let points: [CGPoint]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        points.dropFirst().forEach { path.addLine(to: $0) }
        return path
    }
}

/** Navigationspfeil, Spitze oben. */
private struct PuckArrow: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - rect.height * 0.28))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private extension View {
    /** Ab iOS 17 verlangt WidgetKit `containerBackground`. */
    @ViewBuilder
    func navWidgetBackground(_ style: AnyShapeStyle) -> some View {
        if #available(iOSApplicationExtension 17.0, *) {
            containerBackground(style, for: .widget)
        } else {
            background(style)
        }
    }
}
