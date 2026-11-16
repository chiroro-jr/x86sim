// sdkcov notification service extension (iOS: <app>/PlugIns/sdkcovNotifyService.appex,
// com.apple.usernotifications.service): rewrites a remote notification with "mutable-content": 1 before it is shown
// (title prefixed "[sdkcov] ", userInfo sdkcov-service = its pid). checks/P10_Extensions.swift sends one (simctl push /
// x86sim push via inputs.sh) and reads the delivered notification back.
import Foundation
import UserNotifications

@objc(SDKCovNotificationService)
final class SDKCovNotificationService: UNNotificationServiceExtension {
    override func didReceive(_ request: UNNotificationRequest, withContentHandler handler: @escaping (UNNotificationContent) -> Void) {
        sdkcovMark("nservice-receive", "\(request.identifier) \(request.content.title)")
        guard let c = request.content.mutableCopy() as? UNMutableNotificationContent else { handler(request.content); return }
        c.title = "[sdkcov] " + c.title
        c.userInfo["sdkcov-service"] = Int(ProcessInfo.processInfo.processIdentifier)
        handler(c)
    }
    override func serviceExtensionTimeWillExpire() { sdkcovMark("nservice-expire", "1") }
}
