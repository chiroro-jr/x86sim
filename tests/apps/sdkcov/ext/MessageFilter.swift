// sdkcov SMS / MMS message filter extension (iOS: <app>/PlugIns/sdkcovMessageFilter.appex,
// com.apple.identitylookup.message-filter): files a message from an unknown sender containing "sdkcov-junk" as junk.
// checks/P10_Extensions.swift finds it registered.
import Foundation
import IdentityLookup

@objc(SDKCovMessageFilter)
final class SDKCovMessageFilter: ILMessageFilterExtension, ILMessageFilterQueryHandling {
    func handle(_ request: ILMessageFilterQueryRequest, context: ILMessageFilterExtensionContext, completion: @escaping (ILMessageFilterQueryResponse) -> Void) {
        sdkcovMark("filter-query", "\(request.sender ?? "-")")
        let r = ILMessageFilterQueryResponse()
        r.action = request.messageBody?.contains("sdkcov-junk") == true ? .junk : .allow
        completion(r)
    }
}
