// sdkcov accessory transport extension (iOS: <app>/Extensions/sdkcovTransport.appex,
// com.apple.accessory-transport-extension): refuses every session (no accessory). checks/P10_Extensions.swift finds it
// on the extension point.
import Foundation
import ExtensionFoundation
import AccessoryTransportExtension

@main
struct SDKCovTransport: AccessoryTransportAppExtension {
    init() { sdkcovMark("transport-launch", "pid \(ProcessInfo.processInfo.processIdentifier)") }
    func accept(sessionRequest: AccessoryTransportSession.Request) -> AccessoryTransportSession.Request.Decision {
        sdkcovMark("transport-request", "\(sessionRequest.session)")
        return sessionRequest.reject(error: nil)
    }
}
