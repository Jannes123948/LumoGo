import ActivityKit
import SwiftUI
import WidgetKit

/** Navigation auf dem Sperrbildschirm und in der Dynamic Island (Live-Aktivität). */
struct NavLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NavActivityAttributes.self) { context in
            LockScreenNavView(attributes: context.attributes, state: context.state)
                .activityBackgroundTint(Color(widgetHex: context.attributes.backgroundHex).opacity(0.92))
                .activitySystemActionForegroundColor(Color(widgetHex: context.attributes.textHex))
                .widgetURL(DeepLink.open.url)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ManeuverSymbol(state: state, size: 34)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(state.arrived ? "Da" : state.etaText).font(.headline).monospacedDigit()
                        Text("Ankunft").font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(state.arrived ? "Angekommen" : state.distanceText)
                        .font(.title2.weight(.bold)).monospacedDigit()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 2) {
                        Text(state.arrived ? context.attributes.destinationName : state.instruction)
                            .font(.subheadline.weight(.medium)).lineLimit(2).multilineTextAlignment(.center)
                        if !state.arrived {
                            Text(state.remainingText).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } compactLeading: {
                ManeuverSymbol(state: state, size: 16)
            } compactTrailing: {
                Text(state.arrived ? "Da" : state.distanceText)
                    .font(.caption.weight(.semibold)).monospacedDigit()
                    .frame(maxWidth: 64)
            } minimal: {
                ManeuverSymbol(state: state, size: 14)
            }
            .widgetURL(DeepLink.open.url)
            .keylineTint(Brand.glow)
        }
    }
}

/** Sperrbildschirm: großer Pfeil, Distanz, Anweisung, Ankunft — Farben wie die Navi-Leisten der App. */
private struct LockScreenNavView: View {
    let attributes: NavActivityAttributes
    let state: NavActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 14) {
            ManeuverSymbol(state: state, size: 40)
                .frame(width: 54)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.arrived ? "Angekommen" : state.distanceText)
                    .font(.system(size: 28, weight: .bold)).monospacedDigit()
                Text(state.arrived ? attributes.destinationName : state.instruction)
                    .font(.subheadline.weight(.medium)).lineLimit(2)
                if !state.arrived {
                    Text("Ankunft \(state.etaText) · \(state.remainingText)")
                        .font(.caption).opacity(0.8)
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color(widgetHex: attributes.textHex))
        .padding(16)
    }
}

private struct ManeuverSymbol: View {
    let state: NavActivityAttributes.ContentState
    let size: CGFloat

    var body: some View {
        Image(systemName: state.arrived ? "flag.checkered" : state.symbolName)
            .font(.system(size: size, weight: .bold))
            .rotationEffect(.degrees(state.arrived ? 0 : state.symbolRotation))
    }
}
