// sdkcov persistent token extension (iOS: <app>/PlugIns/sdkcovToken.appex, com.apple.ctk-tokens, class id
// com.x86sim.test.sdkcov.token): a TKTokenDriver whose tokens are the configurations the app adds
// (TKTokenDriver.Configuration); their keychain items are what the app put in the configuration.
// checks/P22_Gaps.swift (func:CryptoTokenKit.persistent-token-keychain) drives it.
import Foundation
import CryptoTokenKit

@objc(SDKCovTokenDriver)
final class SDKCovTokenDriver: TKTokenDriver, TKTokenDriverDelegate {
    override init() { super.init(); delegate = self }
    func tokenDriver(_ driver: TKTokenDriver, tokenFor configuration: TKToken.Configuration) throws -> TKToken {
        sdkcovMark("token-create", "\(configuration.instanceID) items \(configuration.keychainItems.count)")
        return SDKCovToken(tokenDriver: driver, instanceID: configuration.instanceID)
    }
}

final class SDKCovToken: TKToken, TKTokenDelegate {
    override init(tokenDriver: TKTokenDriver, instanceID: String) {
        super.init(tokenDriver: tokenDriver, instanceID: instanceID)
        delegate = self
    }
    func createSession(_ token: TKToken) throws -> TKTokenSession {
        sdkcovMark("token-session", token.tokenDriver.description)
        let s = SDKCovTokenSession(token: token); s.delegate = s; return s
    }
}

final class SDKCovTokenSession: TKTokenSession, TKTokenSessionDelegate {
    func tokenSession(_ session: TKTokenSession, supports operation: TKTokenOperation, keyObjectID: TKToken.ObjectID, algorithm: TKTokenKeyAlgorithm) -> Bool { false }
}
