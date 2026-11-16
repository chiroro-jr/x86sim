// sdkcov notification content extension (iOS: <app>/PlugIns/sdkcovNotifyContent.appex,
// com.apple.usernotifications.content-extension, category sdkcov.content): the custom view the system shows for an
// expanded notification of that category. checks/P10_Extensions.swift finds it registered and reads its marks.
import UIKit
import UserNotifications
import UserNotificationsUI

@objc(SDKCovNotificationContent)
final class SDKCovNotificationContent: UIViewController, UNNotificationContentExtension {
    private let label = UILabel()
    override func viewDidLoad() {
        super.viewDidLoad()
        sdkcovMark("ncontent-load", "pid \(ProcessInfo.processInfo.processIdentifier)")
        label.frame = view.bounds.insetBy(dx: 8, dy: 8); label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(label)
    }
    func didReceive(_ notification: UNNotification) {
        sdkcovMark("ncontent-receive", "\(notification.request.identifier) \(notification.request.content.categoryIdentifier)")
        label.text = "sdkcov: \(notification.request.content.body)"
    }
}
