import SwiftUI

/**
 * Spritpreis wie an der Preistafel der Tankstelle: dunkles Schild, Sorte klein darüber,
 * „1,73“ in gelben Leuchtziffern und die dritte Nachkommastelle hochgestellt („⁹“).
 * Mit Einstellung „Preis als Preistafel“ aus → schlichter grüner Text wie früher.
 */
struct FuelPriceView: View {
    let type: FuelType
    /** nil = geschlossen bzw. Sorte nicht im Angebot. */
    let price: Double?

    @AppStorage("fuel_price_sign") private var asSign = true

    var body: some View {
        if asSign {
            sign
        } else {
            Text(plainText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(price != nil ? Color.green : .secondary)
        }
    }

    private var plainText: String {
        guard let price else { return String(localized: "\(type.label) geschlossen") }
        return "\(type.label) " + FormatUtils.decimal(price, digits: 3) + " €"
    }

    /** „1,73“ und „9“ — gerundet auf ganze Zehntelcent, damit 1,7389999 nicht zu 1,73⁸ wird. */
    private var parts: (main: String, tenth: String)? {
        guard let price else { return nil }
        let text = FormatUtils.decimal(price, digits: 3)
        return (String(text.dropLast()), String(text.suffix(1)))
    }

    private var sign: some View {
        VStack(spacing: 1) {
            Text(type.label.uppercased())
                .font(.system(size: 8, weight: .heavy))
                .tracking(0.4)
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let parts {
                HStack(alignment: .top, spacing: 1) {
                    Text(parts.main)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                    Text(parts.tenth)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .padding(.top, 2)
                }
                .monospacedDigit()
                .foregroundStyle(Self.ledYellow)
                .shadow(color: Self.ledYellow.opacity(0.55), radius: 3)
            } else {
                Text("geschlossen")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(height: 24)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .frame(minWidth: 78)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.16), Color(white: 0.06)], startPoint: .top, endPoint: .bottom))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color(white: 0.45), lineWidth: 1)
        )
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(plainText)
    }

    private static let ledYellow = Color(red: 1.0, green: 0.78, blue: 0.0)
}
