// sdkcov call / message reporting extension (iOS: <app>/PlugIns/sdkcovClassification.appex,
// com.apple.identitylookup.classification-ui): the UI the Phone / Messages apps show when the user reports a call or
// message as junk. checks/P10_Extensions.swift finds it registered.
import UIKit
import IdentityLookup
import IdentityLookupUI

@objc(SDKCovClassification)
final class SDKCovClassification: ILClassificationUIExtensionViewController {
    override func prepare(for request: ILClassificationRequest) {
        sdkcovMark("classify-prepare", "\(type(of: request))")
        extensionContext.isReadyForClassificationResponse = true
    }
    override func classificationResponse(for request: ILClassificationRequest) -> ILClassificationResponse {
        ILClassificationResponse(action: .reportJunk)
    }
}
