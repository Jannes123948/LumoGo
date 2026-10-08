import Foundation

/**
 * Offline-Sperre für ALLE Netzwerkanfragen von MapLibre (Kacheln, Stile, Schriften, Sprites,
 * Offline-Paket-Downloads): steckt als erstes `URLProtocol` in MapLibres
 * `sessionConfiguration`. `canInit` wird für jede einzelne Anfrage gefragt — im Offline-Modus
 * übernimmt dieses Protokoll die Anfrage und scheitert sofort mit „keine Internetverbindung“;
 * MapLibre nimmt dann, was in der Offline-Datenbank liegt (Pakete, Cache).
 *
 * Erst versucht über `MLNNetworkConfigurationDelegate.willSendRequest` (URL umbiegen) — das griff
 * laut Nutzer nicht („holt sich auch map daten im komplett offline modus“). MapLibre iOS hat kein
 * `setConnected` wie Android.
 */
final class OfflineBlockingURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        guard let scheme = request.url?.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        return !NetworkPolicy.allowsMapRequests
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}
}
