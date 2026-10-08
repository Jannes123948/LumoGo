import SwiftUI

/** Navigations-HUD oben: Manöverpfeil, Distanz, Anweisung, Fahrstreifen. Farben aus Design & Farben. */
struct NavHudView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                ManeuverIcon(icon: model.hud.icon, size: settings.largeHud ? 58 : 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.hud.distanceText)
                        .font(.system(size: settings.largeHud ? 40 : 30, weight: .bold))
                    Text(model.hud.instruction)
                        .font(.system(size: settings.largeHud ? 22 : 17, weight: .medium))
                        .lineLimit(3)
                }
                Spacer(minLength: 0)
            }
            if !model.hud.lanes.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(model.hud.lanes.enumerated()), id: \.offset) { _, lane in
                        let indication = lane.indications.first.flatMap { $0 == "none" ? nil : $0 } ?? "straight"
                        ManeuverIcon(icon: ManeuverIconResolver.resolve(type: "turn", modifier: indication), size: 22)
                            .opacity(lane.valid ? 1 : 0.35)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .foregroundStyle(settings.hudText)
        .padding(16)
        .glassPanel(tint: settings.hudBackground.opacity(settings.hudOpacity))
    }
}

struct ManeuverIcon: View {
    let icon: ManeuverIconResolver.Icon
    let size: CGFloat

    var body: some View {
        Image(systemName: icon.symbolName)
            .font(.system(size: size, weight: .bold))
            .frame(width: size * 1.25, height: size * 1.25)
            .rotationEffect(.degrees(icon.rotationDegrees))
            .scaleEffect(x: icon.mirrored ? -1 : 1, y: 1)
    }
}

/** Untere Leiste während der Navigation: Ankunftszeit, Restdistanz/-zeit, Beenden. */
struct NavBottomBar: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Ankunft \(model.hud.etaText)").font(settings.largeHud ? .title2.weight(.bold) : .title3.weight(.bold))
                Text(model.hud.summaryText).font(settings.largeHud ? .headline : .subheadline)
            }
            Spacer()
            Button {
                model.openAlongRoute()
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.headline)
                    .frame(width: 42, height: 42)
                    .background(settings.hudText.opacity(0.18), in: Circle())
            }
            .accessibilityLabel("Auf der Route suchen")
            Button {
                model.shareEta()
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.headline)
                    .frame(width: 42, height: 42)
                    .background(settings.hudText.opacity(0.18), in: Circle())
            }
            .accessibilityLabel("Ankunftszeit teilen")
            Button(role: .destructive) {
                model.stopNavigation()
            } label: {
                Label("Beenden", systemImage: "xmark")
                    .font(.headline)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.red, in: Capsule())
                    .foregroundStyle(.white)
            }
        }
        .foregroundStyle(settings.hudText)
        .padding(16)
        .glassPanel(tint: settings.hudBackground.opacity(settings.hudOpacity))
    }
}

/** Hinweis, wenn sich die geteilte Ankunftszeit um mehr als 5 Minuten verschoben hat. */
struct EtaShiftBanner: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    let newEta: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.badge.exclamationmark")
            Text("Ankunft jetzt \(newEta)").font(.subheadline.weight(.semibold))
            Spacer(minLength: 4)
            Button("Neu teilen") { model.shareEta() }
                .font(.subheadline.weight(.bold))
            Button {
                model.dismissEtaShift()
            } label: {
                Image(systemName: "xmark").font(.footnote.weight(.bold))
            }
            .accessibilityLabel("Hinweis schließen")
        }
        .foregroundStyle(settings.hudText)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassPanel(tint: settings.hudBackground.opacity(settings.hudOpacity), cornerRadius: 14)
    }
}

/** Tempolimit-Schild + aktuelle Geschwindigkeit (unten links während der Navigation). */
struct SpeedIndicator: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(spacing: 8) {
            if settings.showSpeedLimit, let limit = model.speedLimit {
                SpeedLimitSign(limit: limit)
                    .transition(.scale.combined(with: .opacity))
            }
            if settings.showCurrentSpeed, let kmh = model.speedKmh {
                VStack(spacing: -2) {
                    Text("\(kmh)").font(.system(size: 24, weight: .bold, design: .rounded)).monospacedDigit()
                    Text("km/h").font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(model.isSpeeding ? Color(hex: HexColor.contrastText(on: settings.speedingHex)) : .primary)
                .frame(width: 60, height: 54)
                .glassSurface(RoundedRectangle(cornerRadius: 14, style: .continuous),
                              tint: model.isSpeeding ? Color(hex: settings.speedingHex).opacity(0.85) : nil,
                              fallback: model.isSpeeding ? AnyShapeStyle(Color(hex: settings.speedingHex)) : AnyShapeStyle(.regularMaterial))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.speedLimit)
        .animation(.easeInOut(duration: 0.2), value: model.isSpeeding)
    }
}

/** Verkehrszeichen: rot umrandetes Limit bzw. „Ende aller Streckenverbote“ bei unbegrenzt. */
struct SpeedLimitSign: View {
    let limit: SpeedLimit
    var size: CGFloat = 60
    @AppStorage(ColorKeys.speedSign) private var ringHex = Int(ColorKeys.defaultSpeedSign)

    var body: some View {
        ZStack {
            Circle().fill(.white)
            switch limit {
            case .kmh(let value):
                Circle().strokeBorder(Color(hex: UInt32(max(ringHex, 0))), lineWidth: size * 0.12)
                Text("\(value)")
                    .font(.system(size: size * (value >= 100 ? 0.34 : 0.4), weight: .bold, design: .rounded))
                    .foregroundStyle(.black)
            case .unlimited:
                Circle().strokeBorder(Color.gray.opacity(0.6), lineWidth: 1.5)
                // Schräge Striche von rechts oben nach links unten.
                ForEach(-2..<3) { i in
                    Rectangle()
                        .fill(Color.black.opacity(0.75))
                        .frame(width: size * 0.9, height: 2.2)
                        .offset(y: CGFloat(i) * size * 0.08)
                        .rotationEffect(.degrees(-45))
                }
                .clipShape(Circle())
            }
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
        .accessibilityLabel(limit.kmhValue.map { "Tempolimit \($0)" } ?? "Kein Tempolimit")
    }
}
