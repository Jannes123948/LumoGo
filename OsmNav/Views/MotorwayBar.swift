import SwiftUI

/** Autobahn-Leiste: die nächsten Ausfahrten und Rastanlagen mit Entfernung (unter der Navi-Anzeige). */
struct MotorwayBar: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(model.motorwayAhead) { item in
                MotorwayRow(item: item)
            }
        }
        .foregroundStyle(settings.hudText)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .glassPanel(tint: settings.hudBackground.opacity(settings.hudOpacity), cornerRadius: 16)
        .animation(.easeInOut(duration: 0.25), value: model.motorwayAhead.map(\.id))
    }
}

/** Eine Zeile: Symbol im Autobahn-Blau, Nummer wie auf dem Schild, Name, Entfernung. */
struct MotorwayRow: View {
    let item: MotorwayAheadItem
    @EnvironmentObject private var settings: AppSettings

    /** Blau der deutschen Autobahnschilder. */
    static let signBlue = Color(red: 0.0, green: 0.31, blue: 0.62)

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.poi.symbol)
                .font(.system(size: settings.largeHud ? 15 : 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Self.signBlue, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            if let ref = item.poi.ref {
                Text(ref)
                    .font(.system(size: settings.largeHud ? 15 : 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Self.signBlue, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(.white, lineWidth: 1))
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(item.poi.title)
                    .font(.system(size: settings.largeHud ? 18 : 15, weight: item.poi.isOurExit ? .bold : .semibold))
                    .lineLimit(1)
                if item.poi.isOurExit {
                    Text("Deine Ausfahrt")
                        .font(.system(size: 11, weight: .heavy))
                        .textCase(.uppercase)
                        .opacity(0.85)
                }
            }
            Spacer(minLength: 6)
            Text(item.distanceText)
                .font(.system(size: settings.largeHud ? 18 : 15, weight: .bold))
                .monospacedDigit()
        }
        .padding(.vertical, item.poi.isOurExit ? 3 : 0)
        .padding(.horizontal, item.poi.isOurExit ? 6 : 0)
        .background(item.poi.isOurExit ? settings.hudText.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/** Hinweis im Tunnel-Modus: Position wird geschätzt. */
struct DeadReckoningPill: View {
    let inTunnel: Bool
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Label(inTunnel ? "Tunnel – Position geschätzt" : "Kein GPS – Position geschätzt",
              systemImage: inTunnel ? "road.lanes" : "location.slash.fill")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(settings.hudText)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .glassSurface(Capsule(), tint: settings.hudBackground.opacity(settings.hudOpacity),
                          fallback: settings.hudBackground.opacity(settings.hudOpacity), shadowRadius: 2)
    }
}
