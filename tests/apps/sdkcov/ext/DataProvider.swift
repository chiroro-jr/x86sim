// sdkcov accessory data provider (iOS: <app>/Extensions/sdkcovDataProvider.appex, com.apple.accessory-data-provider)
// implementing AccessoryNotifications' NotificationsForwarding: forwards the iPhone's notifications to the app's
// accessory once the user allows it for an accessory paired through AccessorySetupKit (none in a simulator).
// checks/P10_Extensions.swift finds it on the extension point with the capability.
import Foundation
import ExtensionFoundation
import AccessoryTransportExtension
import AccessoryNotifications

struct SDKCovForwarding: NotificationsForwarding.AccessoryNotificationsHandler {
    func didActivate(for session: NotificationsForwarding.Session) { sdkcovMark("dataprovider-activate", "session") }
    func didInvalidate() { sdkcovMark("dataprovider-invalidate", "") }
    func addNotification(_ notification: AccessoryNotification, alertingContext: AlertingContext) async throws -> Bool {
        sdkcovMark("dataprovider-add", notification.title ?? "")
        return false
    }
    func updateNotification(_ notification: AccessoryNotification) {}
    func removeNotification(identifier: AccessoryNotification.Identifier) {}
    func removeAllNotifications() {}
    func messageHandler(_ message: TransportMessage) {}
}

@main
struct SDKCovDataProvider: AccessoryDataProvider {
    init() { sdkcovMark("dataprovider-launch", "pid \(ProcessInfo.processInfo.processIdentifier)") }
    @AppExtensionPoint.Bind
    var extensionPoint: AppExtensionPoint {
        AppExtensionPoint.Identifier("com.apple.accessory-data-provider")
        Implementing { NotificationsForwarding { SDKCovForwarding() } }
    }
}
