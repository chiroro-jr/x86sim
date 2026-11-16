// sdkcov P8: Security (SecKey algorithms, access control), CryptoKit (Secure Enclave, ML-KEM / ML-DSA / X-Wing HPKE),
// CryptoTokenKit, LocalAuthentication (+ EmbeddedUI), AuthenticationServices (passkey requests, controller answer,
// credential identity store, SSO provider, ASWebAuthenticationSession through a loopback redirect), DeviceCheck /
// App Attest answers, SecurityUI certificate sheet, Sign in with Apple button on watchOS / visionOS.
import Foundation
import Synchronization
import Security
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(CryptoTokenKit)
import CryptoTokenKit
#endif
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(LocalAuthenticationEmbeddedUI)
import LocalAuthenticationEmbeddedUI
#endif
#if canImport(AuthenticationServices)
import AuthenticationServices
#endif
#if canImport(_AuthenticationServices_SwiftUI)
import _AuthenticationServices_SwiftUI
#endif
#if canImport(DeviceCheck)
import DeviceCheck
#endif
#if canImport(SecurityUI)
import SecurityUI
#endif

// MARK: helpers

#if !os(watchOS)
@MainActor func p8Scene() throws -> UIWindowScene {
    guard let ws = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
        .first(where: { $0.activationState == .foregroundActive }) ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
    else { throw Fail("no window scene") }
    return ws
}
/// a window above the app's own showing `vc`; the closure takes it down
@MainActor func p8Show(_ vc: UIViewController) throws -> (UIWindow, () -> Void) {
    let ws = try p8Scene()
    let w = UIWindow(windowScene: ws); w.frame = ws.coordinateSpace.bounds; w.windowLevel = .normal + 1
    w.rootViewController = vc; w.isHidden = false; w.makeKey(); w.layoutIfNeeded()
    return (w, { w.isHidden = true; w.rootViewController = nil })
}
func p8Subviews(_ v: UIView) -> [UIView] { [v] + v.subviews.flatMap(p8Subviews) }
#endif
/// poll `cond` on the main actor every 30 ms for up to `secs`
func p8WaitMain(_ secs: Double, _ cond: @escaping @MainActor () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(secs)
    while Date() < end { if await MainActor.run(body: { cond() }) { return true }; try? await Task.sleep(for: .milliseconds(30)) }
    return await MainActor.run(body: { cond() })
}

/// a self-signed P-256 certificate, CN=sdkcov.x86sim.test (the one More_tvOS.swift's certificate-sheet shows)
let p8CertB64 = "MIIBkjCCATegAwIBAgIUbtQ1SHWjekvH559fcAl7evKve4IwCgYIKoZIzj0EAwIwHTEbMBkGA1UEAwwSc2RrY292Lng4NnNpbS50ZXN0MCAXDTI2MTExNDA5MDgxOVoYDzIxMjYxMDIxMDkwODE5WjAdMRswGQYDVQQDDBJzZGtjb3YueDg2c2ltLnRlc3QwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAAQOJfkuFPd1F3AV2iKLjzgepMckyeKaC20JwA5V6rVb4EkeI+VoiNM2ornLpK/sP046XLke8x+R1ZNtYhjl1QZVo1MwUTAdBgNVHQ4EFgQUBcbx9mwi8a14lX6VX2j6qFPMVNowHwYDVR0jBBgwFoAUBcbx9mwi8a14lX6VX2j6qFPMVNowDwYDVR0TAQH/BAUwAwEB/zAKBggqhkjOPQQDAgNJADBGAiEAgnMF6lrC3kpppHOkwEr2DsbrfbE6SRPJRKzEUFNp74QCIQDzKlEPktpfRF/EjqLTpa5/sY92FYMUaoq38ntGwE6iBQ=="

#if canImport(SecurityUI)
struct P8CertSheetView: View {
    @State var trust: SecTrust?
    let initial: SecTrust
    let appeared: P8Box<String>
    var body: some View {
        Text("sdkcov certificate").certificateSheet(trust: $trust, title: "sdkcov", message: "x86sim")
            .onAppear { trust = initial; appeared.set("appeared") }
    }
}
#endif

#if canImport(AuthenticationServices)
final class P8AuthDelegate: NSObject, ASAuthorizationControllerDelegate, @unchecked Sendable {
    let r = P8Box<String>()
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization a: ASAuthorization) { r.set("authorized \(type(of: a.credential))") }
    func authorizationController(controller: ASAuthorizationController, didCompleteWithError e: Error) { r.set("error \(p8Err(e))") }
}
#if !os(watchOS)
final class P8Anchor: NSObject, ASAuthorizationControllerPresentationContextProviding {
    let w: UIWindow
    init(_ w: UIWindow) { self.w = w }
    func presentationAnchor(for c: ASAuthorizationController) -> ASPresentationAnchor { w }
}
#if !os(tvOS)
extension P8Anchor: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for s: ASWebAuthenticationSession) -> ASPresentationAnchor { w }
}
#endif
#endif
#endif

extension Registry {
    static var p8_security: [Check] {
        var c: [Check] = []

        // MARK: Security
        c.append(check("Security", "seckey-algorithms-exchange-interop", timeout: 60) {
            func gen(_ type: CFString, _ bits: Int) throws -> SecKey {
                var e: Unmanaged<CFError>?
                guard let k = SecKeyCreateRandomKey([kSecAttrKeyType: type, kSecAttrKeySizeInBits: bits] as CFDictionary, &e) else { throw Fail("generate \(type) \(bits): \(e!.takeRetainedValue())") }
                return k
            }
            let msg = Data("x86sim sdkcov P8".utf8)
            var done: [String] = []
            func signVerify(_ k: SecKey, _ alg: SecKeyAlgorithm, _ name: String) throws {
                let pub = SecKeyCopyPublicKey(k)!
                try expect(SecKeyIsAlgorithmSupported(k, .sign, alg), "\(name) not supported for signing")
                var e: Unmanaged<CFError>?
                guard let sig = SecKeyCreateSignature(k, alg, msg as CFData, &e) as Data? else { throw Fail("sign \(name): \(e!.takeRetainedValue())") }
                try expect(SecKeyVerifySignature(pub, alg, msg as CFData, sig as CFData, &e), "verify \(name)")
                var bad = msg; bad[0] ^= 1
                try expect(!SecKeyVerifySignature(pub, alg, bad as CFData, sig as CFData, nil), "\(name) verified a changed message")
                done.append(name)
            }
            func encDec(_ k: SecKey, _ alg: SecKeyAlgorithm, _ name: String) throws {
                let pub = SecKeyCopyPublicKey(k)!
                var e: Unmanaged<CFError>?
                guard let ct = SecKeyCreateEncryptedData(pub, alg, msg as CFData, &e) as Data? else { throw Fail("encrypt \(name): \(e!.takeRetainedValue())") }
                guard let pt = SecKeyCreateDecryptedData(k, alg, ct as CFData, &e) as Data? else { throw Fail("decrypt \(name): \(e!.takeRetainedValue())") }
                try expect(pt == msg && ct != msg, "\(name) round trip")
                done.append(name)
            }
            let rsa = try gen(kSecAttrKeyTypeRSA, 2048)
            try signVerify(rsa, .rsaSignatureMessagePSSSHA256, "RSA-PSS")
            try signVerify(rsa, .rsaSignatureMessagePKCS1v15SHA512, "RSA-PKCS1-SHA512")
            try encDec(rsa, .rsaEncryptionOAEPSHA256, "RSA-OAEP")
            try encDec(rsa, .rsaEncryptionPKCS1, "RSA-PKCS1")
            for (bits, alg) in [(256, SecKeyAlgorithm.ecdsaSignatureMessageX962SHA256), (384, .ecdsaSignatureMessageX962SHA384), (521, .ecdsaSignatureMessageX962SHA512)] {
                let ec = try gen(kSecAttrKeyTypeECSECPrimeRandom, bits)
                try signVerify(ec, alg, "ECDSA-P\(bits)")
                try encDec(ec, .eciesEncryptionCofactorVariableIVX963SHA256AESGCM, "ECIES-P\(bits)")
            }
            // ECDH: both sides derive the same secret
            let a = try gen(kSecAttrKeyTypeECSECPrimeRandom, 256), b = try gen(kSecAttrKeyTypeECSECPrimeRandom, 256)
            let p: [String: Any] = [SecKeyKeyExchangeParameter.requestedSize.rawValue as String: 32, SecKeyKeyExchangeParameter.sharedInfo.rawValue as String: Data("info".utf8)]
            var e: Unmanaged<CFError>?
            let s1 = SecKeyCopyKeyExchangeResult(a, .ecdhKeyExchangeStandardX963SHA256, SecKeyCopyPublicKey(b)!, p as CFDictionary, &e) as Data?
            let s2 = SecKeyCopyKeyExchangeResult(b, .ecdhKeyExchangeStandardX963SHA256, SecKeyCopyPublicKey(a)!, p as CFDictionary, &e) as Data?
            try expect(s1 != nil && s1 == s2 && s1!.count == 32, "ECDH \(s1?.count ?? -1) B, equal \(s1 == s2)")
            done.append("ECDH")
            // external representation round trip + attributes
            let pubA = SecKeyCopyPublicKey(a)!
            guard let x963 = SecKeyCopyExternalRepresentation(pubA, &e) as Data? else { throw Fail("export") }
            let back = SecKeyCreateWithData(x963 as CFData, [kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary, &e)
            try expect(x963.count == 65 && x963[0] == 4 && back != nil, "x963 import \(x963.count)")
            let attrs = SecKeyCopyAttributes(rsa) as? [String: Any]
            try expect((attrs?[kSecAttrKeySizeInBits as String] as? Int) == 2048, "attributes \(String(describing: attrs?[kSecAttrKeySizeInBits as String]))")
            #if canImport(CryptoKit)
            // a SecKey ECDSA signature verifies with CryptoKit and the other way round
            let ck = try P256.Signing.PublicKey(x963Representation: x963)
            let der = SecKeyCreateSignature(a, .ecdsaSignatureMessageX962SHA256, msg as CFData, &e)! as Data
            try expect(ck.isValidSignature(try P256.Signing.ECDSASignature(derRepresentation: der), for: msg), "CryptoKit verify of a SecKey signature")
            let ckPriv = P256.Signing.PrivateKey()
            let secPriv = SecKeyCreateWithData(ckPriv.x963Representation as CFData, [kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeyClass: kSecAttrKeyClassPrivate] as CFDictionary, &e)
            let ckSig = try ckPriv.signature(for: msg).derRepresentation
            try expect(secPriv != nil && SecKeyVerifySignature(SecKeyCopyPublicKey(secPriv!)!, .ecdsaSignatureMessageX962SHA256, msg as CFData, ckSig as CFData, &e), "SecKey verify of a CryptoKit signature")
            done.append("CryptoKit interop")
            #endif
            return done.joined(separator: ", ")
        })
        c.append(check("Security", "access-control-keychain", timeout: 30) {
            // access-control objects for each flag set; items protected by them, read without UI
            var e: Unmanaged<CFError>?
            var made: [String] = []
            let sets: [(String, CFString, SecAccessControlCreateFlags)] = [
                ("userPresence", kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .userPresence),
                ("biometryAny", kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .biometryAny),
                ("devicePasscode|or|biometryCurrentSet", kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, [.devicePasscode, .or, .biometryCurrentSet]),
                ("privateKeyUsage", kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, .privateKeyUsage)]
            for (n, prot, f) in sets {
                guard SecAccessControlCreateWithFlags(nil, prot, f, &e) != nil else { throw Fail("SecAccessControlCreateWithFlags \(n): \(e!.takeRetainedValue())") }
                made.append(n)
            }
            let svc = "sdkcov-p8-acl"
            SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: svc] as CFDictionary)
            defer { SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: svc] as CFDictionary) }
            // userPresence on WhenUnlocked: the add itself needs no UI
            let acl = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .userPresence, nil)!
            let add = SecItemAdd([kSecClass: kSecClassGenericPassword, kSecAttrService: svc, kSecAttrAccount: "presence",
                                  kSecValueData: Data("secret".utf8), kSecAttrAccessControl: acl] as CFDictionary, nil)
            // the passcode-gated class on a device without a passcode
            let acl2 = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .devicePasscode, nil)!
            let add2 = SecItemAdd([kSecClass: kSecClassGenericPassword, kSecAttrService: svc, kSecAttrAccount: "passcode",
                                   kSecValueData: Data("secret".utf8), kSecAttrAccessControl: acl2] as CFDictionary, nil)
            // reading the userPresence item with UI forbidden: attributes without the secret are readable
            var out: CFTypeRef?
            #if canImport(LocalAuthentication) && !os(tvOS)
            let ctx = LAContext(); ctx.interactionNotAllowed = true
            let read = SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrService: svc, kSecAttrAccount: "presence",
                                            kSecReturnData: true, kSecUseAuthenticationContext: ctx] as CFDictionary, &out)
            #else
            let read = SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrService: svc, kSecAttrAccount: "presence",
                                            kSecReturnData: true] as CFDictionary, &out)
            #endif
            var attrsOut: CFTypeRef?
            let attrs = SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrService: svc, kSecAttrAccount: "presence",
                                             kSecReturnAttributes: true] as CFDictionary, &attrsOut)
            try expect(add == errSecSuccess && add2 == errSecSuccess && read == errSecSuccess, "add userPresence \(add), passcode-only \(add2), read \(read) (Apple's: 0, 0, 0)")
            try expect(attrs == errSecSuccess && (attrsOut as? [String: Any])?[kSecAttrAccount as String] as? String == "presence", "attributes \(attrs)")
            return "\(made.count) access controls; add userPresence \(add), add passcode-only \(add2), read without UI \(read), attributes \(attrs)"
        })

        // MARK: CryptoKit
        #if canImport(CryptoKit)
        c.append(check("CryptoKit", "secure-enclave-mlkem-mldsa-xwing", timeout: 30) {
            var out: [String] = []
            let se = SecureEnclave.isAvailable
            out.append("SecureEnclave.isAvailable \(se)")
            // Apple's simulators (all four) emulate the Secure Enclave (ctkd's setoken token): available
            try expect(se, "SecureEnclave.isAvailable false (Apple's 27.2 simulators: true)")
            if se {
                let k = try SecureEnclave.P256.Signing.PrivateKey()
                let sig = try k.signature(for: Data("se".utf8))
                try expect(k.publicKey.isValidSignature(sig, for: Data("se".utf8)), "SE P-256 signature")
                let back = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: k.dataRepresentation)
                try expect(back.publicKey.rawRepresentation == k.publicKey.rawRepresentation, "SE key restore")
                out.append("SE P-256 sign + restore")
            }
            // ML-KEM-768: encapsulate to the public key, decapsulate to the same secret
            let kem = try MLKEM768.PrivateKey()
            let enc = try kem.publicKey.encapsulate()
            let ss = try kem.decapsulate(enc.encapsulated)
            try expect(ss == enc.sharedSecret && enc.encapsulated.count == 1088 && kem.publicKey.rawRepresentation.count == 1184, "ML-KEM-768 encapsulated \(enc.encapsulated.count) B, pk \(kem.publicKey.rawRepresentation.count) B")
            let kem2 = try MLKEM768.PrivateKey(seedRepresentation: kem.seedRepresentation, publicKey: kem.publicKey)
            try expect(try kem2.decapsulate(enc.encapsulated) == ss, "ML-KEM seed restore")
            out.append("ML-KEM-768")
            // ML-DSA-65: sign / verify, with and without a context
            let dsa = try MLDSA65.PrivateKey()
            let m = Data("ml-dsa".utf8)
            let s1 = try dsa.signature(for: m)
            try expect(dsa.publicKey.isValidSignature(s1, for: m) && !dsa.publicKey.isValidSignature(s1, for: Data("x".utf8)), "ML-DSA-65 verify")
            let s2 = try dsa.signature(for: m, context: Data("ctx".utf8))
            try expect(dsa.publicKey.isValidSignature(s2, for: m, context: Data("ctx".utf8)) && !dsa.publicKey.isValidSignature(s2, for: m), "ML-DSA-65 context")
            out.append("ML-DSA-65 (\(s1.count) B signature)")
            // X-Wing (ML-KEM-768 + X25519) HPKE seal / open
            let xk = try XWingMLKEM768X25519.PrivateKey.generate()
            var snd = try HPKE.Sender(recipientKey: xk.publicKey, ciphersuite: .XWingMLKEM768X25519_SHA256_AES_GCM_256, info: Data("p8".utf8))
            let ct = try snd.seal(Data("hybrid".utf8), authenticating: Data("aad".utf8))
            var rcv = try HPKE.Recipient(privateKey: xk, ciphersuite: .XWingMLKEM768X25519_SHA256_AES_GCM_256, info: Data("p8".utf8), encapsulatedKey: snd.encapsulatedKey)
            let pt = try rcv.open(ct, authenticating: Data("aad".utf8))
            try expect(pt == Data("hybrid".utf8), "X-Wing HPKE open")
            out.append("X-Wing HPKE")
            return out.joined(separator: ", ")
        })
        #endif

        // MARK: CryptoTokenKit
        #if canImport(CryptoTokenKit) && (os(iOS) || os(tvOS))   // watchOS / visionOS: their More_ files
        c.append(check("CryptoTokenKit", "secure-element-tokens") {
            // ctkd's secelemtoken extension publishes the Secure Enclave tokens
            let ids = TKTokenWatcher().tokenIDs
            try expect(ids.contains("com.apple.setoken"), "token ids \(ids) (Apple's: com.apple.setoken, com.apple.setoken:aks)")
            return ids.joined(separator: ", ")
        })
        #endif
        #if canImport(CryptoTokenKit)
        c.append(check("CryptoTokenKit", "token-info-smartcard-keychain", timeout: 20) {
            let w = TKTokenWatcher()
            var out: [String] = []
            for id in w.tokenIDs.sorted() {
                let i = w.tokenInfo(forTokenID: id)
                out.append("\(id): driver \(i?.driverName ?? "-"), slot \(i?.slotName ?? "-")")
            }
            // insertion handler: fires for the tokens already there
            let seen = Mutex<[String]>([])
            w.setInsertionHandler { id in seen.withLock { $0.append(id) } }
            _ = await p8WaitMain(3) { !seen.withLock { $0 }.isEmpty }
            let ins = seen.withLock { $0 }
            try expect(Set(ins) == Set(w.tokenIDs), "insertion handler \(ins) vs \(w.tokenIDs)")
            #if os(iOS) || os(visionOS)
            // no smart card readers (and no smartcard entitlement): the slot manager answers nil or an empty list
            let mgr = TKSmartCardSlotManager.default
            out.append("slot manager \(mgr.map { "\($0.slotNames.count) slots" } ?? "nil")")
            try expect(mgr != nil, "no TKSmartCardSlotManager (Apple's: a manager with 0 slots)")
            try expect((mgr?.slotNames ?? []).isEmpty, "slots \(mgr?.slotNames ?? [])")
            #endif
            // keys stored in a token: none in the Secure Enclave token for a fresh app
            var r: CFTypeRef?
            let st = SecItemCopyMatching([kSecClass: kSecClassKey, kSecAttrTokenID: kSecAttrTokenIDSecureEnclave, kSecMatchLimit: kSecMatchLimitAll, kSecReturnAttributes: true] as CFDictionary, &r)
            out.append("SE keychain keys: \(st == errSecSuccess ? "\((r as? [Any])?.count ?? 0)" : "\(st)")")
            return out.joined(separator: "; ")
        })
        #endif

        // MARK: LocalAuthentication
        #if canImport(LocalAuthentication)
        c.append(check("LocalAuthentication", "environment-state") {
            // LAEnvironment (the only LocalAuthentication API on tvOS): the mechanisms the device offers and their state
            let st = LAEnvironment.currentUser.state
            var out: [String] = []
            for m in st.allMechanisms { out.append("\(type(of: m)) '\(m.localizedName)' usable \(m.isUsable) icon \(m.iconSystemName)") }
            if let b = st.biometry { out.append("biometry type \(b.biometryType.rawValue) enrolled \(b.isEnrolled) locked \(b.isLockedOut) hash \(b.stateHash.count) B") }
            if let p = st.userPassword { out.append("passcode set \(p.isSet)") }
            #if os(iOS)
            out.append("\(st.companions.count) companions")
            #endif
            #if os(iOS) || os(visionOS)
            // Apple's: one biometry mechanism (Touch ID on the iPad, Optic ID on Vision Pro), not enrolled, not usable
            try expect(st.biometry != nil && st.biometry!.isEnrolled == false && !st.biometry!.isUsable, "biometry \(String(describing: st.biometry))")
            #else
            // Apple's tvOS / watchOS: no mechanisms at all
            try expect(st.allMechanisms.isEmpty, "mechanisms \(st.allMechanisms)")
            #endif
            let copy = st.copy() as? LAEnvironment.State
            try expect(copy != nil && copy!.allMechanisms.count == st.allMechanisms.count, "state copy")
            try expect(st.userPassword == nil || st.userPassword!.isSet == false || st.userPassword!.isUsable, "passcode set but unusable")
            return out.joined(separator: "; ")
        })
        #endif
        #if canImport(LocalAuthentication) && !os(tvOS)   // tvOS: no LAContext
        c.append(check("LocalAuthentication", "context-evaluate-errors-rights", timeout: 30) {
            var out: [String] = []
            // a simulator without a passcode: device owner authentication fails with passcodeNotSet, without UI
            let ctx = LAContext()
            var e: NSError?
            let can = ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &e)
            out.append("canEvaluate owner \(can) (\(e?.code ?? 0))")
            if !can {
                do { _ = try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "sdkcov"); throw Fail("evaluate succeeded without a passcode") }
                catch let le as LAError { out.append("evaluate \(le.code.rawValue)"); try expect(le.code.rawValue == e?.code, "evaluate error \(le.code.rawValue) vs canEvaluate \(e?.code ?? 0)") }
            }
            // an invalidated context refuses with invalidContext
            let dead = LAContext(); dead.invalidate()
            do { _ = try await dead.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "sdkcov"); throw Fail("invalidated context evaluated") }
            catch let le as LAError { try expect(le.code == .invalidContext || le.code == .passcodeNotSet, "invalidated: \(le.code.rawValue)"); out.append("invalidated \(le.code.rawValue)") }
#if !os(watchOS)
            ctx.localizedCancelTitle = "No"; ctx.touchIDAuthenticationAllowableReuseDuration = 10
            try expect(ctx.localizedCancelTitle == "No", "localizedCancelTitle")
            let ds = ctx.domainState
            out.append("domainState biometry \(ds.biometry.biometryType.rawValue) hash \(ds.biometry.stateHash?.count ?? 0) B")
            #endif
            #if os(iOS) || os(visionOS)
            // LARight: a right gated by device owner authentication; without a passcode it cannot be authorized
            let right = LARight(requirement: .default)
            try expect(right.state == .unknown, "new right state \(right.state.rawValue)")
            var ca = "can authorize", sl = "store returned a right"
            do { try await right.checkCanAuthorize() } catch { ca = p8Err(error) }
            do { _ = try await LARightStore.shared.right(forIdentifier: "sdkcov-p8-none") } catch { sl = p8Err(error) }
            // Apple's: biometryNotEnrolled (-1020) and notFound (-1019)
            try expect(ca == "com.apple.LocalAuthentication -1020" && sl == "com.apple.LocalAuthentication -1019", "right \(ca), store \(sl)")
            out.append("right checkCanAuthorize \(ca), store lookup \(sl)")
            #endif
            return out.joined(separator: ", ")
        })
        #endif

        // MARK: AuthenticationServices
        #if canImport(AuthenticationServices)
        c.append(check("AuthenticationServices", "passkey-requests-controller", timeout: 40) {
            var out: [String] = []
            let challenge = Data((0..<32).map { UInt8($0) })
            #if !os(watchOS)
            let p = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: "example.com")
            let reg = p.createCredentialRegistrationRequest(challenge: challenge, name: "ada", userID: Data("user-1".utf8))
            reg.userVerificationPreference = .required
            #if !os(tvOS)
            reg.attestationPreference = .none
            #endif
            reg.displayName = "Ada Lovelace"
            try expect(reg.relyingPartyIdentifier == "example.com" && reg.name == "ada" && reg.userID == Data("user-1".utf8) && reg.challenge == challenge, "registration request")
            let asr = p.createCredentialAssertionRequest(challenge: challenge)
            asr.allowedCredentials = [ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: Data([1, 2, 3]))]
            try expect(asr.allowedCredentials.first?.credentialID == Data([1, 2, 3]), "assertion request")
            out.append("platform passkey requests")
            #if os(iOS)
            let sk = ASAuthorizationSecurityKeyPublicKeyCredentialProvider(relyingPartyIdentifier: "example.com")
            let skr = sk.createCredentialRegistrationRequest(challenge: challenge, displayName: "Ada", name: "ada", userID: Data("u".utf8))
            skr.credentialParameters = [ASAuthorizationPublicKeyCredentialParameters(algorithm: .ES256)]
            try expect(skr.credentialParameters.first?.algorithm == .ES256, "security key params")
            out.append("security key request")
            #endif
            #endif
            #if os(iOS)
            // iOS: not performed. Apple's iPad simulator puts up its passkey sheet for an app without associated domains and
            // the app stopped answering for minutes (ref-mac.sh ipad, 2 of 3 runs: the run's watchdog killed it)
            out.append("controller not performed on iOS")
            #else
            // the controller with a request this app cannot satisfy (no associated domains): an error, not a hang
            let pw = ASAuthorizationPasswordProvider().createRequest()
            #if !os(watchOS)
            let reqs: [ASAuthorizationRequest] = [asr]
            #else
            let reqs: [ASAuthorizationRequest] = [pw]
            #endif
            let d = P8AuthDelegate()
            let ctrl = ASAuthorizationController(authorizationRequests: reqs)
            #if os(visionOS) || os(tvOS)
            let (anchor, done) = try await onMain { () -> (P8Anchor, () -> Void) in
                let (w, done) = try p8Show(UIViewController()); return (P8Anchor(w), done)
            }
            defer { Task { @MainActor in done() } }
            await onMain { ctrl.presentationContextProvider = anchor; ctrl.delegate = d; ctrl.performRequests() }
            #else
            _ = pw
            await onMain { ctrl.delegate = d; ctrl.performRequests() }
            #endif
            var r2 = await d.r.wait(20)
            #if !os(watchOS)
            // cancel without waiting for the main thread (a passkey sheet up can keep it busy)
            if r2 == nil { Task { @MainActor in ctrl.cancel() }; if let x = await d.r.wait(5) { r2 = "after cancel: \(x)" } }
            #endif
            // Apple's tvOS / watchOS simulators never answer in 25 s (their passkey UI), visionOS answers 1004 after cancel()
            // either is an answer; an immediate failure (no AuthenticationServicesAgent: NSCocoaErrorDomain 4099) is not
            let res = r2 ?? "pending (no answer in 25 s)"
            try expect(!res.hasPrefix("authorized") && !res.hasPrefix("error NSCocoaErrorDomain"), "controller answered \(res)")
            out.append("controller \(res)")
            #endif
            // single sign-on provider: no MDM-configured extension
            #if os(iOS) || os(visionOS)
            // each on its own task with a deadline (on Apple's iPad simulator one of these once blocked for minutes after
            // the LocalAuthenticationEmbeddedUI check)
            let sso = try await more2Stage("SSO provider", 15) { ASAuthorizationSingleSignOnProvider(identityProvider: URL(string: "https://sso.example.com")!).canPerformAuthorization }
            out.append("SSO canPerform \(sso)")
            try expect(!sso, "SSO provider can perform without a profile")
            let st = try await more2Stage("identity store state", 15) { let st = await ASCredentialIdentityStore.shared.state(); return (st.isEnabled, st.supportsIncrementalUpdates) }
            out.append("identity store enabled \(st.0), incremental \(st.1)")
            try expect(!st.0, "credential identity store enabled for an app without an AutoFill extension")
            #endif
            return out.joined(separator: ", ")
        })
        #endif
        #if canImport(AuthenticationServices) && os(iOS)
        c.append(check("AuthenticationServices", "web-auth-loopback-callback", timeout: 60) {
            // an ephemeral session (no consent alert) loads a loopback page that redirects to sdkcov-p8://callback
            let srv = try p8HTTP(); let port = try await srv.start(); defer { srv.stop() }
            let url = URL(string: "http://127.0.0.1:\(port)/auth?client=sdkcov")!
            let r = P8Box<String>()
            let (s, done) = try await onMain { () -> (ASWebAuthenticationSession, () -> Void) in
                let (w, done) = try p8Show(UIViewController())
                let s = ASWebAuthenticationSession(url: url, callback: .customScheme("sdkcov-p8")) { cb, e in r.set(cb?.absoluteString ?? "error \(p8Err(e))") }
                s.prefersEphemeralWebBrowserSession = true
                let a = P8Anchor(w); s.presentationContextProvider = a
                objc_setAssociatedObject(s, "p8anchor", a, .OBJC_ASSOCIATION_RETAIN)
                return (s, done)
            }
            defer { Task { @MainActor in done() } }
            let started = await onMain { s.start() }
            try expect(started, "start() false")
            let res = await r.wait(45)
            if res == nil { await onMain { s.cancel() } }
            try expect(res == "sdkcov-p8://callback?code=42&state=x86", "callback \(res ?? "none in 45 s") (served \(srv.requests.withLock { $0 }))")
            return "callback \(res!) after \(srv.requests.withLock { $0.count }) request(s)"
        })
        #endif
        #if canImport(_AuthenticationServices_SwiftUI) && os(visionOS)
        c.append(check("_AuthenticationServices_SwiftUI", "sign-in-button", timeout: 20) {
            try await onMain {
                let v = SignInWithAppleButton(.continue, onRequest: { $0.requestedScopes = [.email] }, onCompletion: { _ in })
                    .signInWithAppleButtonStyle(.black).frame(width: 280, height: 50)
                let hc = UIHostingController(rootView: v.padding(40))
                let (w, done) = try p8Show(hc); defer { done() }
                w.layoutIfNeeded(); hc.view.layoutIfNeeded()
                let names = p8Subviews(hc.view).map { "\(type(of: $0))" }
                let btn = p8Subviews(hc.view).first { "\(type(of: $0))".contains("ASAuthorizationAppleIDButton") }
                try expect(btn != nil, "no ASAuthorizationAppleIDButton in \(names.count) views")
                try expect(btn!.bounds.width >= 200 && btn!.bounds.height >= 40, "button size \(btn!.bounds.size)")
                return "button \(btn!.bounds.size)"
            }
        })
        #endif
        #if canImport(_AuthenticationServices_SwiftUI) && os(watchOS)
        c.append(check("_AuthenticationServices_SwiftUI", "sign-in-button", timeout: 20) {
            // on screen through Runner.overlay; its laid-out size comes back through onGeometryChange
            let size = P8Box<CGSize>()
            await onMain {
                Runner.shared.overlay = AnyView(SignInWithAppleButton(.signIn, onRequest: { $0.requestedScopes = [.fullName] }, onCompletion: { _ in })
                    .signInWithAppleButtonStyle(.white).frame(height: 44)
                    .onGeometryChange(for: CGSize.self, of: { $0.size }) { s in if s.width > 0 { size.set(s) } })
            }
            defer { Task { @MainActor in Runner.shared.overlay = nil } }
            guard let s = await size.wait(10) else { throw Fail("the button never laid out") }
            try expect(s.height == 44 && s.width > 100, "size \(s)")
            return "laid out \(Int(s.width))x\(Int(s.height))"
        })
        #endif

        // MARK: DeviceCheck / App Attest
        #if canImport(DeviceCheck)
        c.append(check("DeviceCheck", "unsupported-errors", timeout: 30) {
            // Apple's simulator: neither DeviceCheck nor App Attest is supported; both answer featureUnsupported
            let dc = DCDevice.current
            try expect(!dc.isSupported, "DCDevice supported in a simulator")
            var out: [String] = []
            do { _ = try await dc.generateToken(); throw Fail("generateToken succeeded") }
            catch let e as DCError { try expect(e.code == .featureUnsupported, "generateToken \(e.code.rawValue) \(e)"); out.append("generateToken featureUnsupported") }
            #if !os(watchOS) || true
            let aa = DCAppAttestService.shared
            try expect(!aa.isSupported, "App Attest supported in a simulator")
            do { _ = try await aa.generateKey(); throw Fail("generateKey succeeded") }
            catch let e as DCError { try expect(e.code == .featureUnsupported, "generateKey \(e.code.rawValue)"); out.append("App Attest generateKey featureUnsupported") }
            do { _ = try await aa.attestKey("none", clientDataHash: Data(count: 32)); throw Fail("attestKey succeeded") }
            catch let e as DCError { out.append("attestKey \(e.code.rawValue)") }
            #endif
            return out.joined(separator: ", ")
        })
        #endif

        // MARK: SecurityUI
        #if canImport(SecurityUI) && (os(iOS) || os(visionOS))
        c.append(check("SecurityUI", "certificate-sheet", timeout: 30) {
            guard let der = Data(base64Encoded: p8CertB64), let cert = SecCertificateCreateWithData(nil, der as CFData) else { throw Fail("certificate") }
            var tr: SecTrust?
            try expect(SecTrustCreateWithCertificates(cert, SecPolicyCreateBasicX509(), &tr) == errSecSuccess, "trust")
            let summary = SecCertificateCopySubjectSummary(cert) as String?
            let appeared = P8Box<String>()
            let (hc, done) = try await onMain { () -> (UIViewController, () -> Void) in
                let hc = UIHostingController(rootView: P8CertSheetView(initial: tr!, appeared: appeared))
                let (_, done) = try p8Show(hc); return (hc, done)
            }
            defer { Task { @MainActor in done() } }
            let up = await p8WaitMain(10) { hc.presentedViewController != nil }
            let name = await onMain { hc.presentedViewController.map { "\(type(of: $0))" } ?? "-" }
            await onMain { hc.presentedViewController?.dismiss(animated: false) }
            _ = await p8WaitMain(3) { hc.presentedViewController == nil }
            try expect(up, "no sheet presented (appeared \(appeared.value ?? "no"))")
            return "sheet \(name) for '\(summary ?? "?")'"
        })
        #endif
        #if canImport(SecurityUI) && os(watchOS)
        c.append(check("SecurityUI", "certificate-sheet", timeout: 30) {
            // watchOS has only the SwiftUI modifier: the view with the sheet goes on screen through Runner.overlay
            guard let der = Data(base64Encoded: p8CertB64), let cert = SecCertificateCreateWithData(nil, der as CFData) else { throw Fail("certificate") }
            var tr: SecTrust?
            try expect(SecTrustCreateWithCertificates(cert, SecPolicyCreateBasicX509(), &tr) == errSecSuccess, "trust")
            let appeared = P8Box<String>()
            await onMain { Runner.shared.overlay = AnyView(P8CertSheetView(initial: tr!, appeared: appeared)) }
            defer { Task { @MainActor in Runner.shared.overlay = nil } }
            guard await appeared.wait(10) != nil else { throw Fail("view never appeared") }
            // UIKit is private on watchOS: the presented controller through the runtime
            try await Task.sleep(for: .seconds(2))
            let presented = await onMain { () -> String in
                guard let app = (NSClassFromString("UIApplication") as? NSObject.Type)?.value(forKey: "sharedApplication") as? NSObject,
                      let wins = app.value(forKey: "windows") as? [NSObject] else { return "no UIApplication" }
                for w in wins { if let p = (w.value(forKey: "rootViewController") as? NSObject)?.value(forKey: "presentedViewController") as? NSObject { return "\(type(of: p))" } }
                return "none (\(wins.count) windows)"
            }
            return "certificate sheet view appeared, presented \(presented)"
        })
        #endif
        return c
    }
}

extension Registry {
    /// P8 checks that run after all the others: LARight's embedded authorization UI can leave Apple's iPad simulator's main
    /// thread busy for minutes (the next check hung there, ref-mac.sh ipad)
    static var p8_last: [Check] {
        var c: [Check] = []
        #if canImport(LocalAuthenticationEmbeddedUI) && (os(iOS) || os(visionOS))
        c.append(check("LocalAuthenticationEmbeddedUI", "right-authorize-in-window", timeout: 30) {
            // LARight.authorize(localizedReason:in:) presents in the app's window; with no passcode / biometry
            // enrolled it answers with an error (Apple's code pinned by ref-mac.sh)
            let right = LARight()
            let r = P8Box<String>()
            let done = try await onMain { () -> () -> Void in
                let (w, done) = try p8Show(UIViewController())
                right.authorize(localizedReason: "sdkcov checks embedded UI", in: w) { e in r.set(p8Err(e)) }
                return done
            }
            defer { Task { @MainActor in done() } }
            guard let res = await r.wait(20) else { throw Fail("no completion in 20 s (state \(right.state.rawValue))") }
            try expect(res == "com.apple.LocalAuthentication -1020", "authorize -> \(res) (Apple's: biometryNotEnrolled -1020)")
            return "authorize -> \(res), state \(right.state.rawValue)"
        })
        #endif
        return c
    }
}
