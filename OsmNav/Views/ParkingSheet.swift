import SwiftUI

/** „Mein Auto“: wo es steht, seit wann, Notiz, Parkzeit-Erinnerung, zu Fuß hinführen. */
struct ParkingSheet: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""
    @State private var confirmForget = false

    private static let reminderOptions = [15, 30, 60, 90, 120, 180, 240]

    var body: some View {
        NavigationStack {
            Form {
                if let car = model.parkedCar {
                    Section {
                        HStack(spacing: 14) {
                            Image(systemName: "car.fill")
                                .font(.title2)
                                .foregroundStyle(.white)
                                .frame(width: 52, height: 52)
                                .background(Color(red: 0.08, green: 0.4, blue: 0.85), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(car.address ?? String(localized: "Adresse wird gesucht …"))
                                    .font(.headline)
                                    .foregroundStyle(car.address == nil ? .secondary : .primary)
                                Text(parkedSince(car.date))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                if let distance = distanceText(car) {
                                    Text(distance).font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    Section {
                        Button {
                            model.walkToCar()
                        } label: {
                            Label("Zu Fuß hinführen", systemImage: "figure.walk")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                        }
                        .adaptiveButtonStyle(prominent: true)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                        Button {
                            model.showParkedCar()
                        } label: {
                            Label("Auf der Karte zeigen", systemImage: "map")
                        }
                    }

                    Section {
                        TextField("z. B. Parkdeck 3, Platz 112", text: $note, axis: .vertical)
                            .lineLimit(1...3)
                            .onSubmit { model.setParkingNote(note) }
                    } header: {
                        Text("Notiz")
                    }

                    Section {
                        Picker(selection: Binding(
                            get: { car.reminder.map { _ in -1 } ?? 0 },
                            set: { minutes in
                                // -1 = die schon gesetzte Erinnerung, nichts ändern.
                                if minutes != -1 { model.setParkingReminder(minutes: minutes > 0 ? minutes : nil) }
                            }
                        )) {
                            Text("Aus").tag(0)
                            if let reminder = car.reminder {
                                Text("um \(reminder.formatted(date: .omitted, time: .shortened))").tag(-1)
                            }
                            ForEach(Self.reminderOptions, id: \.self) { minutes in
                                Text(minutes < 60 ? "in \(minutes) min" : minutes % 60 == 0 ? "in \(minutes / 60) h" : "in \(minutes / 60) h \(minutes % 60) min").tag(minutes)
                            }
                        } label: {
                            SettingsRow(title: "Parkzeit-Erinnerung", symbol: "timer", color: .orange)
                        }
                    } footer: {
                        Text("Eine Mitteilung erinnert dich, wenn der Parkschein abläuft.")
                    }

                    Section {
                        Button("Hier geparkt (aktueller Standort)") { model.rememberParkingHere() }
                        Button("Parkplatz vergessen", role: .destructive) { confirmForget = true }
                    } footer: {
                        Text("Der Parkplatz wird automatisch gemerkt, wenn du mit dem Auto am Ziel ankommst (oder die Navigation kurz davor beendest). Fährst du am Auto los, wird er wieder vergessen.")
                    }
                } else {
                    Section {
                        Label("Kein Parkplatz gemerkt", systemImage: "car")
                        Button("Hier geparkt (aktueller Standort)") { model.rememberParkingHere() }
                    } footer: {
                        Text("Kommst du mit dem Auto am Ziel an, merkt sich LumoGo automatisch, wo es steht.")
                    }
                }
            }
            .navigationTitle("Mein Auto")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") {
                        model.setParkingNote(note)
                        dismiss()
                    }
                }
            }
            .confirmationDialog("Parkplatz vergessen?", isPresented: $confirmForget, titleVisibility: .visible) {
                Button("Vergessen", role: .destructive) {
                    model.forgetParking()
                    dismiss()
                }
            }
            .onAppear { note = model.parkedCar?.note ?? "" }
            .onDisappear { model.setParkingNote(note) }
        }
        .presentationDetents([.medium, .large])
    }

    private func parkedSince(_ date: Date) -> String {
        let minutes = Int(Date().timeIntervalSince(date) / 60)
        let time = date.formatted(date: Calendar.current.isDateInToday(date) ? .omitted : .abbreviated, time: .shortened)
        let ago: String
        if minutes < 1 { ago = String(localized: "gerade eben") }
        else if minutes < 60 { ago = String(localized: "vor \(minutes) min") }
        else if minutes < 24 * 60 { ago = String(localized: "vor \(minutes / 60) h \(minutes % 60) min") }
        else { ago = String(localized: "vor \(minutes / (24 * 60)) Tagen") }
        return String(localized: "Geparkt \(time) · \(ago)")
    }

    private func distanceText(_ car: ParkedCar) -> String? {
        guard let position = model.currentPosition else { return nil }
        let meters = GeoUtils.distanceMeters(position, car.point)
        if meters < 25 { return String(localized: "Du bist am Auto") }
        // Gehtempo ≈ 4,5 km/h, Umwege grob mit 1,3 eingerechnet.
        let minutes = max(1, Int((meters * 1.3 / 1.25 / 60).rounded()))
        return String(localized: "\(FormatUtils.formatDistance(meters)) Luftlinie · ca. \(minutes) min zu Fuß")
    }
}
