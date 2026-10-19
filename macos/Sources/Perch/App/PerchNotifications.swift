import AppKit
import UserNotifications

/// What one system notification says and what clicking it does.
struct PerchNotice: Equatable {
    enum Action: Equatable {
        /// Bring the conversation's client forward.
        case openSession(accountID: String, sessionID: String)
        /// Copy the finished handoff document and open the target.
        case continueHandoff(UUID)

        var userInfo: [String: String] {
            switch self {
            case .openSession(let account, let session): return ["action": "openSession", "account": account, "session": session]
            case .continueHandoff(let id): return ["action": "continueHandoff", "handoff": id.uuidString]
            }
        }

        init?(userInfo: [AnyHashable: Any]) {
            switch userInfo["action"] as? String {
            case "openSession":
                guard let account = userInfo["account"] as? String, let session = userInfo["session"] as? String else { return nil }
                self = .openSession(accountID: account, sessionID: session)
            case "continueHandoff":
                guard let id = (userInfo["handoff"] as? String).flatMap(UUID.init(uuidString:)) else { return nil }
                self = .continueHandoff(id)
            default:
                return nil
            }
        }
    }

    let title: String
    let body: String
    /// Without an action, clicking opens the panel.
    var action: Action?
}

/// One exit for background events. A failed/disabled delivery returns to the panel.
final class PerchNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = PerchNotifications()
    var openPanel: (() -> Void)?
    /// Runs a clicked notification's action; returns false when the panel should open instead.
    var perform: ((PerchNotice.Action) -> Bool)?

    private var center: UNUserNotificationCenter? {
        // UNUserNotificationCenter cannot run from an unbundled command-line binary.
        guard Bundle.main.bundleIdentifier == "com.omnis.perch",
              Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        return UNUserNotificationCenter.current()
    }

    func configure(openPanel: @escaping () -> Void, perform: @escaping (PerchNotice.Action) -> Bool) {
        self.openPanel = openPanel
        self.perform = perform
        center?.delegate = self
    }

    /// Read-only runtime evidence for `--diagnose`; never requests permission or sends a notification.
    func diagnose() {
        guard let center else { print("notificationStatus=unbundled"); return }
        center.getNotificationSettings { settings in
            print("notificationAuthorization=\(settings.authorizationStatus.rawValue) notificationAlerts=\(settings.alertSetting.rawValue)")
        }
    }

    func send(_ notice: PerchNotice, completion: @escaping (Bool) -> Void) {
        guard let center else { completion(false); return }
        center.getNotificationSettings { settings in
            let deliver = {
                let content = UNMutableNotificationContent()
                content.title = notice.title
                content.body = notice.body
                content.sound = .default
                if let action = notice.action { content.userInfo = action.userInfo }
                let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
                center.add(request) { error in completion(error == nil) }
            }
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                    if granted && error == nil { deliver() } else { completion(false) }
                }
            case .authorized, .provisional:
                if settings.alertSetting == .enabled { deliver() } else { completion(false) }
            default:
                completion(false)
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = PerchNotice.Action(userInfo: response.notification.request.content.userInfo)
        DispatchQueue.main.async { [weak self] in
            if let action, self?.perform?(action) == true {} else { self?.openPanel?() }
            completionHandler()
        }
    }
}
