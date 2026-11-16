// sdkcov App Clip (iOS: <app>/AppClips/sdkcovClip.app, com.x86sim.test.sdkcov.Clip): a minimal SwiftUI app clip that
// marks its launch and its activation payload. checks/P10_Extensions.swift finds it registered with the app.
import SwiftUI
import AppClip

@main
struct SDKCovClip: App {
    init() { sdkcovMark("clip-launch", "pid \(ProcessInfo.processInfo.processIdentifier)") }
    var body: some Scene {
        WindowGroup {
            Text("sdkcov clip")
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { a in
                    sdkcovMark("clip-activity", "\(a.webpageURL?.absoluteString ?? "-") payload \(a.appClipActivationPayload != nil)")
                }
        }
    }
}
