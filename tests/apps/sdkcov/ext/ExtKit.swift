// sdkcov ExtensionKit extension (all four platforms: <app>/Extensions/sdkcovExt.appex): it binds to the extension point
// the app defines (<app>/Extensions/sdkcov.appexpt: com.x86sim.test.sdkcov.sdkcov-ext) and answers an XPC echo; on iOS
// it also offers a SwiftUI scene ("sdkcov-scene") that the app hosts in an EXHostViewController.
// checks/P3_Extensions.swift: AppExtensionPoint.Monitor discovery, AppExtensionProcess + XPC, EXHostViewController.
import Foundation
import ExtensionFoundation
import ExtensionKit
import SwiftUI

/// the XPC interface (the app declares the same protocol: matched by its Objective-C name)
@objc(SDKCovExtService) protocol SDKCovExtService {
    func echo(_ text: String, reply: @escaping (String) -> Void)
}

final class SDKCovExtServer: NSObject, SDKCovExtService {
    func echo(_ text: String, reply: @escaping (String) -> Void) {
        sdkcovMark("ext-echo", text)
        reply("ext \(Bundle.main.bundleIdentifier ?? "?") pid \(ProcessInfo.processInfo.processIdentifier): \(text)")
    }
}

func sdkcovAccept(_ c: NSXPCConnection) -> Bool {
    sdkcovMark("ext-connection", "pid \(c.processIdentifier)")
    c.exportedInterface = NSXPCInterface(with: SDKCovExtService.self)
    c.exportedObject = SDKCovExtServer()
    c.resume()
    return true
}

/// ConnectionHandler is iOS / macOS only: the same, as our own configuration (tvOS, watchOS, visionOS)
struct SDKCovExtConfiguration: AppExtensionConfiguration {
    nonisolated func accept(connection: NSXPCConnection) -> Bool { sdkcovAccept(connection) }
}

@main
struct SDKCovExt: AppExtension {
    @AppExtensionPoint.Bind var extensionPoint: AppExtensionPoint {
        AppExtensionPoint.Identifier(host: "com.x86sim.test.sdkcov", name: "sdkcov-ext")
    }
    init() { sdkcovMark("ext-launch", "pid \(ProcessInfo.processInfo.processIdentifier)") }
    #if os(iOS)
    var configuration: AppExtensionSceneConfiguration {
        AppExtensionSceneConfiguration(PrimitiveAppExtensionScene(id: "sdkcov-scene") {
            let _ = sdkcovMark("ext-scene", "body")
            Color(red: 1, green: 0, blue: 0).overlay(Text("sdkcov extension").foregroundStyle(.white))
        } onConnection: { c in sdkcovAccept(c) }, configuration: SDKCovExtConfiguration())
    }
    #else
    var configuration: SDKCovExtConfiguration { SDKCovExtConfiguration() }
    #endif
}
