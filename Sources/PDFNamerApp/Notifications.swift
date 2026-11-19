import AppKit
import UserNotifications

/// The notifications for files renamed in watched folders: a click shows the file in the
/// Finder, and Annuler puts its old name back without opening the app.
final class Notifications: NSObject, UNUserNotificationCenterDelegate {
    nonisolated static let renamed = "renamed"
    nonisolated static let entry = "entry"
    private static let undoAction = "undo"
    private static let revealAction = "reveal"

    private weak var model: AppModel?

    @MainActor func start(model: AppModel) {
        self.model = model
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([UNNotificationCategory(
            identifier: Self.renamed,
            actions: [
                UNNotificationAction(identifier: Self.undoAction, title: String(localized: "undo-rename", defaultValue: "Annuler",
                                                                                     comment: "Undo a rename (not Cancel)")),
                UNNotificationAction(identifier: Self.revealAction, title: String(localized: "Afficher dans le Finder")),
            ],
            intentIdentifiers: [])])
        center.requestAuthorization(options: [.alert]) { _, _ in }
    }

    /// Also while the app is in front: the window may be on another page.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions { [.banner, .list] }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let id = response.notification.request.content.userInfo[Self.entry] as? String
        let action = response.actionIdentifier
        await MainActor.run {
            guard let model, let entry = model.recent.first(where: { $0.id.uuidString == id }) else { return }
            switch action {
            case Self.undoAction: model.undo(entry)
            case UNNotificationDefaultActionIdentifier, Self.revealAction: model.reveal(entry.url)
            default: break
            }
        }
    }
}
