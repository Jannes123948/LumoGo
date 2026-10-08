import UIKit

/** iOS-Teilen-Menü direkt über UIKit — anders als SwiftUIs `ShareLink` mit Rückmeldung, ob geteilt wurde. */
enum ShareSheet {
    @MainActor
    static func present(items: [Any], completion: @escaping (Bool) -> Void) {
        guard let root = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow })
            .first?.rootViewController else { return }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, _ in completion(completed) }
        // iPad: Popover braucht einen Anker.
        controller.popoverPresentationController?.sourceView = top.view
        controller.popoverPresentationController?.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.maxY - 80, width: 1, height: 1)
        top.present(controller, animated: true)
    }
}
