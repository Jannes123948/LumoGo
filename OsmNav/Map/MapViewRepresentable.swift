import SwiftUI
import MapLibre

/** Bindet die MapLibre-Karte in SwiftUI ein. Die eigentliche Logik steckt im [MapController]. */
struct MapViewRepresentable: UIViewRepresentable {
    let controller: MapController
    let engine: MapEngine
    let dark: Bool
    let appearance: MapAppearance

    func makeUIView(context: Context) -> MLNMapView {
        controller.apply(appearance)
        return controller.makeMapView(engine: engine, dark: dark)
    }

    func updateUIView(_ uiView: MLNMapView, context: Context) {
        controller.setStyle(engine: engine, dark: dark)
        controller.apply(appearance)
    }
}
