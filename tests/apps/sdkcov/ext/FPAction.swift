// sdkcov File Provider UI action extension (iOS: <app>/PlugIns/sdkcovFPAction.appex, com.apple.fileprovider-actionsui):
// the custom action com.x86sim.test.sdkcov.action the Files app offers on the sdkcov File Provider's items
// (NSExtensionFileProviderActions). checks/P10_Extensions.swift finds it registered with its action.
import UIKit
import FileProvider
import FileProviderUI

@objc(SDKCovFPAction)
final class SDKCovFPAction: FPUIActionExtensionViewController {
    override func prepare(forAction actionIdentifier: String, itemIdentifiers: [NSFileProviderItemIdentifier]) {
        sdkcovMark("fpaction-prepare", "\(actionIdentifier) \(itemIdentifiers.map(\.rawValue))")
        extensionContext.completeRequest()
    }
    override func prepare(forError error: Error) {
        sdkcovMark("fpaction-error", "\((error as NSError).domain) \((error as NSError).code)")
        extensionContext.cancelRequest(withError: error)
    }
}
