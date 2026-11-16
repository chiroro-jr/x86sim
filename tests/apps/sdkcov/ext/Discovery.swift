// sdkcov device discovery extension (iOS: <app>/Extensions/sdkcovDiscovery.appex, com.apple.discovery-extension): the
// media device discovery a DeviceDiscoveryUI / AVRouting host starts. checks/P10_Extensions.swift finds it on the
// extension point.
import Foundation
import ExtensionFoundation
import DeviceDiscoveryExtension

@main
struct SDKCovDiscovery: DDDiscoveryExtension {
    init() { sdkcovMark("discovery-launch", "pid \(ProcessInfo.processInfo.processIdentifier)") }
    func startDiscovery(session: DDDiscoverySession) { sdkcovMark("discovery-start", "1") }
    func stopDiscovery(session: DDDiscoverySession) { sdkcovMark("discovery-stop", "1") }
}
