import Foundation
import MapLibre

/** Zusätzlich die Delegate-Variante (schadet nicht, falls MapLibre sie für manche Anfragen nutzt). */
final class MapNetworkGate: NSObject, MLNNetworkConfigurationDelegate {
    static let shared = MapNetworkGate()

    // Selektor explizit: optionale ObjC-Protokollmethode — ein falscher Swift-Name fiele sonst nicht auf.
    @objc(willSendRequest:)
    func willSend(_ request: NSMutableURLRequest) -> NSMutableURLRequest {
        if !NetworkPolicy.allowsMapRequests, let blocked = URL(string: "lumogo-offline://blocked") {
            request.url = blocked
        }
        return request
    }
}
