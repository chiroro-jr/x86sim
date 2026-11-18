// sdkcov Call Directory extension (iOS: <app>/PlugIns/sdkcovCallDirectory.appex, com.apple.callkit.call-directory):
// one blocked number and one identification label. checks/P17_Gaps.swift asks CXCallDirectoryManager for its enabled
// status and to reload it (the request reaching beginRequest leaves a mark).
import Foundation
import CallKit

@objc(SDKCovCallDirectory)
final class SDKCovCallDirectory: CXCallDirectoryProvider {
    override func beginRequest(with context: CXCallDirectoryExtensionContext) {
        sdkcovMark("calldir-request", "incremental \(context.isIncremental)")
        context.addBlockingEntry(withNextSequentialPhoneNumber: 15550100)
        context.addIdentificationEntry(withNextSequentialPhoneNumber: 15550101, label: "sdkcov")
        context.completeRequest()
    }
}
