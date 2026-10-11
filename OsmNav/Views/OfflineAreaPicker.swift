import SwiftUI
import MapLibre

/**
 * Vollbild-Karte zum Festlegen eines eigenen Offline-Bereichs: Karte verschieben/zoomen, Rahmen
 * an den vier Ecken aufziehen. Zeigt live Kachelzahl + grobe Größe für die gewählten Zoomstufen
 * und die Umrisse schon geladener Pakete.
 *
 * Rahmen und Karte liegen im selben (vollflächigen) Koordinatensystem — die Rahmenecken werden
 * direkt über `MLNMapView.convert(_:toCoordinateFrom:)` in Koordinaten umgerechnet. Drehen/Neigen
 * ist hier aus, damit der Rahmen einem achsparallelen Kartenrechteck entspricht.
 */
struct OfflineAreaPickerView: View {
    let initialBounds: BoundingBox?
    let existingPacks: [BoundingBox]
    @Binding var preset: ZoomPreset
    /** Zoombereich für „Benutzerdefiniert“; sonst gilt der des Presets. */
    let customRange: ClosedRange<Int>
    let onPick: (BoundingBox) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var picker = AreaPickerMap()
    @ObservedObject private var manager = OfflineMapsManager.shared
    @State private var rect: CGRect = .zero
    @State private var dragStart: CGRect?

    private var zoomRange: ClosedRange<Int> { preset.range ?? customRange }

    private static let minSide: CGFloat = 70
    private static let tileWarning = 300_000

    var body: some View {
        ZStack {
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    AreaPickerMapView(picker: picker, styleURL: colorScheme == .dark ? MapController.darkStyleURL : MapController.lightStyleURL,
                                      initialBounds: initialBounds, outlines: existingPacks)
                    dimming(size: geo.size)
                    Rectangle()
                        .stroke(Color.accentColor, lineWidth: 3)
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                        .allowsHitTesting(false)
                    ForEach(Corner.allCases, id: \.self) { corner in
                        handle(corner, bounds: geo.size)
                    }
                }
                .onAppear {
                    if rect == .zero {
                        rect = CGRect(x: 28, y: geo.size.height * 0.2,
                                      width: geo.size.width - 56, height: geo.size.height * 0.48)
                    }
                }
            }
            .ignoresSafeArea()

            VStack {
                topBar
                Spacer()
                bottomPanel
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Rahmen

    private enum Corner: CaseIterable { case topLeft, topRight, bottomLeft, bottomRight }

    /** Abdunklung außerhalb des Rahmens (gerade-ungerade-Füllung: Bildschirm minus Rahmen). */
    private func dimming(size: CGSize) -> some View {
        Path { path in
            path.addRect(CGRect(origin: .zero, size: size))
            path.addRect(rect)
        }
        .fill(Color.black.opacity(0.35), style: FillStyle(eoFill: true))
        .allowsHitTesting(false)
    }

    private func handle(_ corner: Corner, bounds: CGSize) -> some View {
        let point: CGPoint
        switch corner {
        case .topLeft: point = CGPoint(x: rect.minX, y: rect.minY)
        case .topRight: point = CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeft: point = CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomRight: point = CGPoint(x: rect.maxX, y: rect.maxY)
        }
        return Circle()
            .fill(Color.white)
            .overlay(Circle().stroke(Color.accentColor, lineWidth: 4))
            .frame(width: 26, height: 26)
            .shadow(color: .black.opacity(0.3), radius: 3)
            .frame(width: 48, height: 48)
            .contentShape(Rectangle())
            .position(point)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let start = dragStart ?? rect
                        if dragStart == nil { dragStart = rect }
                        rect = Self.resized(start, corner: corner, by: value.translation, bounds: bounds)
                    }
                    .onEnded { _ in dragStart = nil }
            )
    }

    /** Neuer Rahmen beim Ziehen einer Ecke — Mindestgröße, innerhalb des Bildschirms. */
    private static func resized(_ start: CGRect, corner: Corner, by t: CGSize, bounds: CGSize) -> CGRect {
        var minX = start.minX, maxX = start.maxX, minY = start.minY, maxY = start.maxY
        switch corner {
        case .topLeft: minX += t.width; minY += t.height
        case .topRight: maxX += t.width; minY += t.height
        case .bottomLeft: minX += t.width; maxY += t.height
        case .bottomRight: maxX += t.width; maxY += t.height
        }
        minX = min(max(minX, 4), maxX - minSide)
        maxX = max(min(maxX, bounds.width - 4), minX + minSide)
        minY = min(max(minY, 4), maxY - minSide)
        maxY = max(min(maxY, bounds.height - 4), minY + minSide)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // MARK: - Leisten

    private var topBar: some View {
        HStack {
            Button("Abbrechen") { dismiss() }
                .adaptiveButtonStyle(prominent: false)
            Spacer()
            Text("Bereich wählen").font(.headline)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .glassSurface(Capsule(), fallback: .regularMaterial)
            Spacer()
            // Platzhalter gleicher Breite, damit der Titel mittig bleibt.
            Button("Abbrechen") {}.adaptiveButtonStyle(prominent: false).hidden()
        }
    }

    private var bottomPanel: some View {
        // `revision` ändert sich bei jeder Kartenbewegung → Werte live neu berechnen.
        let _ = picker.revision
        let box = picker.bbox(for: rect)
        let tiles = box.map { TileMath.tileCount($0, minZoom: zoomRange.lowerBound, maxZoom: zoomRange.upperBound) } ?? 0
        let bytes = Double(tiles) * manager.averageBytesPerTile

        return VStack(alignment: .leading, spacing: 10) {
            Text("Karte verschieben und zoomen, Ecken ziehen, um den Bereich anzupassen.")
                .font(.footnote).foregroundStyle(.secondary)
            HStack {
                Text("Zoomstufen")
                Spacer()
                Picker("Zoomstufen", selection: $preset) {
                    ForEach(ZoomPreset.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
            }
            if let box {
                HStack(spacing: 6) {
                    Image(systemName: "square.dashed")
                    Text("\(Self.areaText(box)) · ≈ \(tiles.formatted()) Kacheln · ca. \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tiles > Self.tileWarning ? .red : .primary)
                if tiles > Self.tileWarning {
                    Text("Sehr großer Bereich — der kostenlose Kachelserver kann dabei hängen bleiben. Bereich verkleinern oder weniger Zoomstufen wählen.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Button {
                if let box {
                    onPick(box)
                    dismiss()
                }
            } label: {
                Label("Diesen Bereich verwenden", systemImage: "checkmark.circle.fill").frame(maxWidth: .infinity)
            }
            .adaptiveButtonStyle(prominent: true)
            .controlSize(.large)
            .disabled(box == nil)
        }
        .padding(14)
        .card()
    }

    /** "ca. 12 × 8 km" aus der Bounding Box. */
    private static func areaText(_ box: BoundingBox) -> String {
        let midLat = (box.north + box.south) / 2
        let width = GeoUtils.distanceMeters(LatLon(midLat, box.west), LatLon(midLat, box.east)) / 1000
        let height = GeoUtils.distanceMeters(LatLon(box.south, box.west), LatLon(box.north, box.west)) / 1000
        func f(_ km: Double) -> String { km < 10 ? FormatUtils.decimal(km, digits: 1) : "\(Int(km.rounded()))" }
        return "\(f(width)) × \(f(height)) km"
    }
}

/** Hält die Auswahl-Karte und rechnet Bildschirm-Rahmen in Koordinaten um. Wie beim
 *  [MapController] ohne Actor-Bindung — MapLibre ruft den Delegate auf dem Main-Thread auf. */
final class AreaPickerMap: NSObject, ObservableObject, MLNMapViewDelegate {
    private static let outlineSourceId = "offline-outlines"

    weak var mapView: MLNMapView?
    /** Erhöht sich bei jeder Kamerabewegung — Auslöser zum Neuberechnen der Anzeige. */
    @Published private(set) var revision = 0
    var outlines: [BoundingBox] = []

    func bbox(for rect: CGRect) -> BoundingBox? {
        guard let mapView, rect.width > 0, rect.height > 0 else { return nil }
        let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                       CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)]
            .map { mapView.convert($0, toCoordinateFrom: mapView) }
        let lats = corners.map(\.latitude)
        let lons = corners.map(\.longitude)
        guard let south = lats.min(), let north = lats.max(), let west = lons.min(), let east = lons.max(),
              north > south, east > west else { return nil }
        return BoundingBox(south: max(south, -85), north: min(north, 85), west: max(west, -180), east: min(east, 180))
    }

    func mapViewRegionIsChanging(_ mapView: MLNMapView) {
        revision += 1
    }

    func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
        revision += 1
    }

    func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
        drawOutlines(style)
    }

    /** Gestrichelte Umrisse schon heruntergeladener Pakete. */
    private func drawOutlines(_ style: MLNStyle) {
        guard !outlines.isEmpty else { return }
        let lines: [MLNPolylineFeature] = outlines.map { box in
            var coords = [
                CLLocationCoordinate2D(latitude: box.south, longitude: box.west),
                CLLocationCoordinate2D(latitude: box.south, longitude: box.east),
                CLLocationCoordinate2D(latitude: box.north, longitude: box.east),
                CLLocationCoordinate2D(latitude: box.north, longitude: box.west),
                CLLocationCoordinate2D(latitude: box.south, longitude: box.west)
            ]
            return MLNPolylineFeature(coordinates: &coords, count: UInt(coords.count))
        }
        let source = MLNShapeSource(identifier: Self.outlineSourceId, shape: MLNShapeCollectionFeature(shapes: lines), options: nil)
        style.addSource(source)
        let layer = MLNLineStyleLayer(identifier: Self.outlineSourceId + "-layer", source: source)
        layer.lineColor = NSExpression(forConstantValue: UIColor.systemOrange)
        layer.lineWidth = NSExpression(forConstantValue: 2.5)
        layer.lineDashPattern = NSExpression(forConstantValue: [2, 1.5])
        style.addLayer(layer)
    }
}

private struct AreaPickerMapView: UIViewRepresentable {
    let picker: AreaPickerMap
    let styleURL: URL
    let initialBounds: BoundingBox?
    let outlines: [BoundingBox]

    func makeUIView(context: Context) -> MLNMapView {
        let mapView = MLNMapView(frame: UIScreen.main.bounds, styleURL: styleURL)
        mapView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        mapView.isRotateEnabled = false
        mapView.isPitchEnabled = false
        mapView.compassView.compassVisibility = .hidden
        mapView.showsUserLocation = true
        picker.outlines = outlines
        mapView.delegate = picker
        if let box = initialBounds {
            let bounds = MLNCoordinateBounds(sw: CLLocationCoordinate2D(latitude: box.south, longitude: box.west),
                                             ne: CLLocationCoordinate2D(latitude: box.north, longitude: box.east))
            mapView.setVisibleCoordinateBounds(bounds, animated: false)
        } else {
            mapView.setCenter(CLLocationCoordinate2D(latitude: 51.1657, longitude: 10.4515), zoomLevel: 5, animated: false)
        }
        picker.mapView = mapView
        return mapView
    }

    func updateUIView(_ uiView: MLNMapView, context: Context) {}
}
