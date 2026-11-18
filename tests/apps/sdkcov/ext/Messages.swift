// sdkcov iMessage app extension (iOS: <app>/PlugIns/sdkcovMessages.appex, com.apple.message-payload-provider): an
// MSMessagesAppViewController that marks its lifecycle. checks/P17_Gaps.swift finds it registered (Messages, which
// would host it, is not in the simulator).
import UIKit
import Messages

@objc(SDKCovMessagesVC)
final class SDKCovMessagesVC: MSMessagesAppViewController {
    override func viewDidLoad() { super.viewDidLoad(); sdkcovMark("imessage-load", "") }
    override func willBecomeActive(with conversation: MSConversation) { sdkcovMark("imessage-active", "") }
}
