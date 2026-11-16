// sdkcov Home extension (iOS 27: <app>/Extensions/sdkcovHome.appex, com.apple.Home.HomeExtension): the troubleshooting
// page the Home app shows for the app's accessories. checks/P10_Extensions.swift finds it on the extension point.
import SwiftUI
import HomeExtensions

@main
struct SDKCovHome: HomeExtension {
    init() { sdkcovMark("home-launch", "pid \(ProcessInfo.processInfo.processIdentifier)") }
    var body: some HomeContent {
        HomeAccessoryTroubleshooting { Text("sdkcov troubleshooting") }
    }
}
