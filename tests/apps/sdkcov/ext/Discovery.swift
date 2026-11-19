// sdkcov device discovery extension (iOS: <app>/Extensions/sdkcovDiscovery.appex, com.apple.discovery-extension): the
// media device discovery a DeviceDiscoveryUI / AVRouting host starts. checks/P10_Extensions.swift finds it on the
// extension point.
import Foundation
import ExtensionFoundation
import DeviceDiscoveryExtension
import UniformTypeIdentifiers
import Network

@main
struct SDKCovDiscovery: DDDiscoveryExtension {
    init() { sdkcovMark("discovery-launch", "pid \(ProcessInfo.processInfo.processIdentifier)") }
    func startDiscovery(session: DDDiscoverySession) {
        sdkcovMark("discovery-start", "1")
        // (P25) one device found at once: a TV on loopback, for checks/P25_Gaps.swift's route picker check
        let d = DDDevice(displayName: "sdkcov TV", category: .tv, protocolType: .data, identifier: "sdkcov-tv")
        d.networkEndpoint = .hostPort(host: "127.0.0.1", port: 7000)
        d.state = .activated
        session.report(DDDeviceEvent(eventType: .deviceFound, device: d))
        sdkcovMark("discovery-report", "sdkcov-tv")
    }
    func didReceiveEvent(_ event: DDDeviceEvent) { sdkcovMark("discovery-event", "\(event.eventType.rawValue) \(event.device.identifier)") }
    func stopDiscovery(session: DDDiscoverySession) { sdkcovMark("discovery-stop", "1") }
}
