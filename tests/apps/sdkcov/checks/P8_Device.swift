// sdkcov P8: identity & device management. ManagedApp / ManagedAppDistribution / AutomatedDeviceEnrollment answers
// on an unmanaged device, ClassKit (+UI), IdentityDocumentServices (+UI), SecureElementCredential (+ overlays),
// TrustInsights, ServicesAccountLinking, IdentityLookupUI, Accounts, AutomaticAssessmentConfiguration on visionOS.
// Most of these cannot do their job in a simulator (no MDM, Wallet, Secure Element, entitlements): each check asserts
// the answer Apple's simulator gives (ref-mac.sh), so x86Sim has to give the same one.
import Foundation
import Synchronization
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(ManagedApp)
import ManagedApp
#endif
#if canImport(ManagedAppDistribution)
import ManagedAppDistribution
#endif
#if canImport(_ManagedAppDistribution_SwiftUI)
import _ManagedAppDistribution_SwiftUI
#endif
#if canImport(AutomatedDeviceEnrollment)
import AutomatedDeviceEnrollment
#endif
#if canImport(ClassKit)
import ClassKit
#endif
#if canImport(ClassKitUI)
import ClassKitUI
#endif
#if canImport(IdentityDocumentServices)
import IdentityDocumentServices
#endif
#if canImport(IdentityDocumentServicesUI)
import IdentityDocumentServicesUI
#endif
#if canImport(SecureElementCredential)
import SecureElementCredential
#endif
#if canImport(_SecureElementCredential_SwiftUI)
import _SecureElementCredential_SwiftUI
#endif
#if canImport(_SecureElementCredential_UIKit)
import _SecureElementCredential_UIKit
#endif
#if canImport(TrustInsights) && os(iOS)
import TrustInsights
#endif
#if canImport(ServicesAccountLinking)
import ServicesAccountLinking
#endif
#if canImport(IdentityLookupUI)
import IdentityLookupUI
#endif
#if canImport(IdentityLookup)
import IdentityLookup
#endif
#if canImport(Accounts) && os(iOS)
import Accounts
#endif

/// a hosted SwiftUI view's laid-out size and appearance
#if !os(watchOS) && !os(tvOS)
/// the accessibility elements under `o` (SwiftUI builds them on demand): (label, is a button, element)
/// turn on the app's accessibility runtime (as XCTest / Accessibility Inspector do): SwiftUI then keeps an element tree
@MainActor func p8AXOn(_ on: Bool = true) {
    guard let h = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW), let f = dlsym(h, "_AXSApplicationAccessibilitySetEnabled") else { return }
    unsafeBitCast(f, to: (@convention(c) (Bool) -> Void).self)(on)
}
@MainActor func p8AX(_ o: NSObject, depth: Int = 0) -> [(String, Bool, NSObject)] {
    guard depth < 12 else { return [] }
    var out: [(String, Bool, NSObject)] = []
    var kids: [NSObject] = (o.accessibilityElements as? [NSObject]) ?? []
    if kids.isEmpty { let n = o.accessibilityElementCount(); if n > 0 && n != NSNotFound { kids = (0..<n).compactMap { o.accessibilityElement(at: $0) as? NSObject } } }
    if let v = o as? UIView { kids += v.subviews }
    for k in kids {
        if k.isAccessibilityElement || k.accessibilityLabel != nil { out.append((k.accessibilityLabel ?? "", k.accessibilityTraits.contains(.button), k)) }
        out += p8AX(k, depth: depth + 1)
    }
    return out
}
/// `v` on screen with the accessibility runtime on: the labels of its elements ("[button]" marks buttons), polled for
/// `secs` until `done` holds for them
@MainActor func p8AXLabels<V: View>(_ v: V, secs: Double = 5, until done: ([String]) -> Bool = { !$0.isEmpty }) async throws -> [String] {
    p8AXOn(); defer { p8AXOn(false) }
    let hc = UIHostingController(rootView: v)
    let (w, close) = try p8Show(hc); defer { close() }
    w.layoutIfNeeded()
    let end = Date().addingTimeInterval(secs)
    var l: [String] = []
    repeat { try await Task.sleep(for: .milliseconds(250)); l = p8AX(hc.view).map { "\($0.0)\($0.1 ? "[button]" : "")" } } while !done(l) && Date() < end
    return l
}
@MainActor func p8Host<V: View>(_ v: V, secs: Double = 1) async throws -> (String, CGSize) {
    let hc = UIHostingController(rootView: v)
    let (w, done) = try p8Show(hc); defer { done() }
    w.layoutIfNeeded()
    try await Task.sleep(for: .seconds(secs))
    hc.view.layoutIfNeeded()
    let names = p8Subviews(hc.view).map { "\(type(of: $0))" }
    let fit = hc.sizeThatFits(in: CGSize(width: 400, height: 1000))
    return ("\(names.count) views", fit)
}
#endif
/// whether a symbol is exported by an image already loaded (or loadable) at `path`
func p8Sym(_ path: String, _ sym: String) -> Bool {
    guard let h = dlopen(path, RTLD_NOW) else { return false }
    return dlsym(h, sym) != nil
}

#if canImport(IdentityDocumentServicesUI)
@MainActor final class P8IDAnchor: IdentityDocumentPresentmentControllerPresentationContextProviding {
    let w: UIWindow
    init(_ w: UIWindow) { self.w = w }
    func presentationAnchorForPresentmentController(_ c: any IdentityDocumentPresentmentControlling) -> IdentityDocumentPresentationAnchor? { w }
}
#endif

extension Registry {
    static var p8_device: [Check] {
        var c: [Check] = []

        // MARK: managed apps
        #if canImport(ManagedApp) && os(iOS)   // visionOS: More_visionOS.swift
        c.append(check("ManagedApp", "configuration-provider") {
            // an unmanaged app: Apple's simulator never yields on the configuration stream (managedappsd has nothing to
            // send); a stream that yields nil at once means managedappsd was not reachable
            struct Cfg: Decodable { let x: Int? }
            let got = P8Box<String>()
            let t = Task { for await c in await ManagedAppConfigurationProvider().configurations(Cfg.self) { got.set(c == nil ? "nil" : "a configuration"); break } }
            let v = await got.wait(10); t.cancel()
            if let v { throw Fail("the stream yielded \(v) for an unmanaged app (Apple's yields nothing: managedappsd unreachable?)") }
            return "no configuration in 10 s (unmanaged app, as on Apple's simulator)"
        })
        #endif
        #if canImport(ManagedAppDistribution)
        c.append(check("ManagedAppDistribution", "libraries-unmanaged-device", timeout: 40) {
            // the app and package libraries of an unmanaged device: first element of each stream (or none)
            func first<S: AsyncSequence & Sendable>(_ s: S) async -> String where S.Element: Sendable {
                let b = P8Box<String>()
                let t = Task { do { for try await x in s { b.set("\(x)"); break }; b.set("finished") } catch { b.set("threw \(error)") } }
                let r = await b.wait(12); t.cancel()
                return r ?? "nothing in 12 s"
            }
            let apps = await first(ManagedAppLibrary.currentDistributor.availableApps)
            let e = ManagedAppDistributionError.deviceNotManaged
            try expect(!e.description.isEmpty && e.errorDescription != nil, "error description")
            let enc = try JSONEncoder().encode(e)
            try expect(try JSONDecoder().decode(ManagedAppDistributionError.self, from: enc).description == e.description, "error Codable")
            // Apple's iOS / visionOS 27.2 simulators: the app library yields failure(unsupportedPlatform)
            try expect(apps.hasPrefix("failure(") && apps.contains("unsupported"), "apps \(apps)")
            try expect(ManagedApp.Platform.iOS != ManagedApp.Platform.visionOS && "\(ManagedApp.Platform.visionOS)" != "", "platforms")
            return "apps: \(apps); deviceNotManaged '\(e.errorDescription ?? "")'"
        })
        #endif
        #if canImport(_ManagedAppDistribution_SwiftUI) && os(visionOS)
        c.append(check("_ManagedAppDistribution_SwiftUI", "managed-content-view", timeout: 20) {
            let tapped = P8Box<String>()
            let states: [ManagedContentOfferState] = [.neverInstalled, .notInstalled, .installed, .noninteractive, .installing(progress: 0.5), .custom(title: "Open")]
            try expect(Set(states).count == 6 && ManagedContentOfferState.installing(progress: 0.5) == .installing(progress: 0.5), "offer states")
            let (views, size, ax) = try await Task { @MainActor () async throws -> (Int, CGSize, [String]) in
                p8AXOn(); defer { p8AXOn(false) }
                let hc = UIHostingController(rootView: VStack {
                    ManagedContentView(primaryLabel: "sdkcov", secondaryLabel: "x86Sim", offerState: .notInstalled, offerAction: { s in tapped.set("\(s)") }) { Image(systemName: "app") }
                        .managedContentStyle(.compact)
                    ManagedContentView(primaryLabel: "sdkcov 2", offerState: .installing(progress: 0.3), offerAction: { _ in }) { Image(systemName: "app") }
                        .managedContentStyle(.header)
                }.frame(width: 400))
                let (w, done) = try p8Show(hc); defer { done() }
                w.layoutIfNeeded()
                // the element tree fills in asynchronously: polled until the offer button has its label (5 s)
                var els = p8AX(hc.view)
                for _ in 0..<25 where !els.contains(where: { $0.1 && !$0.0.isEmpty }) { try await Task.sleep(for: .milliseconds(200)); els = p8AX(hc.view) }
                // the offer button of the first view: activating it runs offerAction with its offer state
                let buttons = els.filter { $0.1 }
                if let b = buttons.first { _ = b.2.accessibilityActivate() }
                try await Task.sleep(for: .milliseconds(500))
                return (p8Subviews(hc.view).count, hc.sizeThatFits(in: CGSize(width: 400, height: 1000)), els.map { "\($0.0)\($0.1 ? "[button]" : "")" })
            }.value
            let tap = await tapped.wait(2)
            // Apple's visionOS 27.2 simulator: the labels joined ("sdkcov, x86Sim"), the not-installed offer button titled
            // Redownload, the second view's label and its (progress) button; activating the first button calls offerAction
            try expect(size.height > 20, "laid-out height \(size)")
            try expect(ax == ["sdkcov, x86Sim", "Redownload[button]", "sdkcov 2", "[button]"], "accessibility elements \(ax) (Apple's simulator: sdkcov, x86Sim / Redownload button / sdkcov 2 / button)")
            try expect(tap?.contains("notInstalled") == true, "offerAction on activating the button: \(tap ?? "not called")")
            return "\(views) views, \(Int(size.width))x\(Int(size.height)); labels and the Redownload offer button read back, its activation ran offerAction(.notInstalled)"
        })
        #endif
        #if canImport(AutomatedDeviceEnrollment) && os(iOS)
        c.append(check("AutomatedDeviceEnrollment", "addition-modifier", timeout: 30) {
            // the whole public API: a modifier presenting the enrollment-addition extension UI; with isPresented false it
            // must leave the view alone, presented on an unmanaged simulator it shows (or refuses) the system UI
            struct V: View { @State var on = false; let flag: P8Box<String>
                var body: some View { Text("sdkcov ADE").automatedDeviceEnrollmentAddition(isPresented: $on).onAppear { flag.set("appeared") } } }
            let flag = P8Box<String>()
            let hc = await onMain { UIHostingController(rootView: V(flag: flag)) }
            let done = try await onMain { try p8Show(hc).1 }
            defer { Task { @MainActor in done() } }
            try expect(await flag.wait(5) == "appeared", "view never appeared")
            let presented = await onMain { hc.presentedViewController.map { "\(type(of: $0))" } ?? "none" }
            try expect(presented == "none", "presented \(presented) with isPresented false")
            return "modifier hosted, nothing presented while false"
        })
        #endif

        // MARK: AutomaticAssessmentConfiguration on visionOS
        #if os(visionOS)
        c.append(check("AutomaticAssessmentConfiguration", "visionos-availability") {
            // visionOS ships the framework with every class marked unavailable: the binary loads, the classes exist at
            // runtime (Apple's answer pinned by ref-mac.sh xros)
            let path = "/System/Library/Frameworks/AutomaticAssessmentConfiguration.framework/AutomaticAssessmentConfiguration"
            try expect(dlopen(path, RTLD_NOW) != nil, "dlopen: \(String(cString: dlerror()))")
            let cls = ["AEAssessmentSession", "AEAssessmentConfiguration", "AEAssessmentApplication", "AEAssessmentParticipantConfiguration"].map { "\($0) \(NSClassFromString($0) != nil)" }
            return cls.joined(separator: ", ")
        })
        #endif

        // MARK: ClassKit
        #if canImport(ClassKit) && os(visionOS)   // iOS: More_iOS.swift
        c.append(check("ClassKit", "main-app-context") {
            let ctx = CLSDataStore.shared.mainAppContext
            try expect(!ctx.identifier.isEmpty, "empty identifier")
            return "context \(ctx.identifier) type \(ctx.type.rawValue)"
        })
        #endif
        #if canImport(ClassKit) && (os(iOS) || os(visionOS))
        c.append(check("ClassKit", "context-tree-activity-save", timeout: 30) {
            // a context tree under the main app context with an activity; saving needs the ClassKit entitlement
            // (com.apple.developer.ClassKit-environment), so save / fetch answer with an error (Apple's code pinned)
            let main = CLSDataStore.shared.mainAppContext
            let unit = CLSContext(type: .chapter, identifier: "p8-unit", title: "Unit 1")
            let quiz = CLSContext(type: .quiz, identifier: "p8-quiz", title: "Quiz")
            quiz.topic = .math; quiz.displayOrder = 2; quiz.summary = "sdkcov"
            quiz.addProgressReportingCapabilities([CLSProgressReportingCapability(kind: .percent, details: nil)])
            main.addChildContext(unit); unit.addChildContext(quiz)
            try expect(quiz.parent === unit && unit.parent === main && quiz.identifierPath == [main.identifier, "p8-unit", "p8-quiz"], "tree \(quiz.identifierPath)")
            let act = quiz.createNewActivity()
            act.start(); act.addProgressRange(fromStart: 0, toEnd: 0.5)
            let score = CLSScoreItem(identifier: "score", title: "Score", score: 8, maxScore: 10)
            act.primaryActivityItem = score
            act.addAdditionalActivityItem(CLSQuantityItem(identifier: "hints", title: "Hints"))
            act.stop()
            try expect(act.progress == 0.5 && (act.primaryActivityItem as? CLSScoreItem)?.score == 8 && act.additionalActivityItems.count == 1, "activity progress \(act.progress)")
            let saveErr = P8Box<String>()
            CLSDataStore.shared.save { e in saveErr.set(p8Err(e)) }
            let s = await saveErr.wait(15) ?? "no answer in 15 s"
            let fetch = P8Box<String>()
            CLSDataStore.shared.contexts(matching: NSPredicate(format: "identifier == %@", "p8-quiz")) { cs, e in fetch.set(e.map { p8Err($0) } ?? "\(cs.count) contexts") }
            let f = await fetch.wait(15) ?? "no answer in 15 s"
            unit.removeFromParent()
            // Apple's: without the ClassKit entitlement both fail with CLSErrorCodeInternal... 100
            try expect(s == "com.apple.ClassKit 100" && f == "com.apple.ClassKit 100", "save \(s), fetch \(f)")
            return "tree + activity built; save \(s); fetch \(f)"
        })
        #endif
        #if canImport(ClassKitUI) && (os(iOS) || os(visionOS))
        c.append(check("ClassKitUI", "assigned-document-views", timeout: 20) {
            let doc = FileManager.default.temporaryDirectory.appendingPathComponent("sdkcov-assigned.txt")
            try Data("x86".utf8).write(to: doc)
            let (views, size) = try await Task { @MainActor () async throws -> (String, CGSize) in
                try await p8Host(VStack {
                    AssignedDocumentLabel(role: .status, documentURL: doc)
                    AssignedDocumentLabel(role: .date, documentURL: doc)
                    AssignedDocumentSubmissionButton(documentURL: doc).onAssignedDocumentWillSubmit { _ in false }
                }.frame(width: 300))
            }.value
            let roles: Set<AssignedDocumentLabel.Role> = [.status, .date]
            let menu = await onMain { AssignedDocumentDeferredMenuElement(documentURL: doc) }
            try expect(roles.count == 2, "roles")
            return "\(views), size \(Int(size.width))x\(Int(size.height)), deferred menu \(type(of: menu))"
        })
        #endif

        // MARK: identity documents, Secure Element credentials
        #if canImport(IdentityDocumentServices) && os(iOS)
        c.append(check("IdentityDocumentServices", "registration-store-requests", timeout: 30) {
            // no Wallet IDs / provider extension in the simulator: the registration store's state and errors,
            // plus ISO 18013-5 request objects and the raw request validator
            let store = IdentityDocumentProviderRegistrationStore()
            var st = "-", regs = "-"
            do { st = "\(try await store.status)" } catch { st = "threw \(error)" }
            do { regs = "\(try await store.registrations.count)" } catch { regs = "threw \(error)" }
            var add = "-"
            do {
                try await store.addRegistration(MobileDocumentRegistration(mobileDocumentType: "org.iso.18013.5.1.mDL", supportedAuthorityKeyIdentifiers: [], documentIdentifier: "p8-doc"))
                add = "added"
            } catch { add = "\(error)" }
            let req = ISO18013MobileDocumentRequest(presentmentRequests: [
                .init(documentRequestSets: [.init(requests: [.init(documentType: "org.iso.18013.5.1.mDL",
                    namespaces: ["org.iso.18013.5.1": ["family_name": .init(isRetaining: false), "age_over_21": .init(isRetaining: true)]])])], isMandatory: true)],
                requestAuthentications: [])
            try expect(req.presentmentRequests.first?.documentRequestSets.first?.requests.first?.namespaces["org.iso.18013.5.1"]?.count == 2, "request object")
            var val = "-"
            do { _ = try IdentityDocumentWebPresentmentRawRequestValidator().validateISO18013MobileDocumentRequest(Data([0xa0]), origin: URL(string: "https://example.com")!); val = "accepted" }
            catch { val = "\(error)" }
            try expect(val.contains("invalidRequest"), "validator: \(val)")
            try expect(st == "notSupported" && add == "notAuthorized", "status \(st), add \(add) (Apple's: notSupported, notAuthorized)")
            return "status \(st), registrations \(regs), add: \(add); validator: \(val)"
        })
        #endif
        #if canImport(IdentityDocumentServicesUI) && os(iOS)
        c.append(check("IdentityDocumentServicesUI", "web-presentment-controller", timeout: 30) {
            // the web presentment controller refuses an app without the entitlement (Apple's error pinned)
            let req = ISO18013MobileDocumentRequest(presentmentRequests: [.init(documentRequestSets: [.init(requests: [
                .init(documentType: "org.iso.18013.5.1.mDL", namespaces: ["org.iso.18013.5.1": ["age_over_21": .init(isRetaining: false)]])])], isMandatory: true)],
                requestAuthentications: [])
            let r = try await Task { @MainActor () async throws -> String in
                let (w, done) = try p8Show(UIViewController()); defer { done() }
                let ctl = IdentityDocumentWebPresentmentController()
                let a = P8IDAnchor(w); ctl.presentationContextProvider = a
                do { _ = try await ctl.performRequests([req], origin: URL(string: "https://example.com")!); return "response" }
                catch { return "\(error)" }
            }.value
            try expect(r.contains("invalidRequest"), "performRequests -> \(r) (Apple's: invalidRequest, no delegate available)")
            return "performRequests -> \(r)"
        })
        #endif
        #if canImport(SecureElementCredential) && os(iOS)
        c.append(check("SecureElementCredential", "session-eligibility", timeout: 30) {
            // no Secure Element / NFC in the simulator: not eligible, a session does not start
            var el = false, elErr = "-"
            do { el = try await CredentialSession.isEligible } catch { elErr = "\(error)" }
            try expect(!el, "eligible in a simulator")
            var s = "-"
            do { let sess = try await CredentialSession.startSession(); s = "started, state \(await sess.state)"; try? await sess.invalidate() }
            catch { s = "\(error)" }
            try expect(elErr == "featureUnavailable" && s == "featureUnavailable", "isEligible \(elErr), startSession \(s) (Apple's: featureUnavailable both)")
            return "isEligible false (\(elErr)), startSession: \(s)"
        })
        #endif
        #if canImport(_SecureElementCredential_UIKit) && os(iOS)
        c.append(check("_SecureElementCredential_UIKit", "window-scene-events") {
            // the UIKit overlay's scene event type (Codable) and the connection-options extension on a live scene
            let evs: [CredentialSessionWindowSceneEvent] = [.readerDetected, .presentation]
            let d = try JSONEncoder().encode(evs)
            let back = try JSONDecoder().decode([CredentialSessionWindowSceneEvent].self, from: d)
            try expect(back == evs && evs.map(\.description).allSatisfy { !$0.isEmpty }, "events \(back)")
            return "events \(evs.map(\.description)) via \(d.count) B JSON"
        })
        #endif
        #if canImport(_SecureElementCredential_SwiftUI) && os(iOS)
        c.append(check("_SecureElementCredential_SwiftUI", "transaction-task-modifier", timeout: 20) {
            // .transactionTask(nil) hosts without starting anything; with no session there is no configuration
            let ran = P8Box<String>()
            let (views, _) = try await Task { @MainActor () async throws -> (String, CGSize) in
                try await p8Host(Text("sdkcov SE").transactionTask(nil) { _ in ran.set("ran") })
            }.value
            try expect(ran.value == nil, "transaction action ran with a nil configuration")
            return "\(views), no transaction for a nil configuration"
        })
        #endif

        // MARK: TrustInsights
        #if canImport(TrustInsights) && os(iOS)
        c.append(check("TrustInsights", "evaluator-authorization", timeout: 30) {
            let ctx = InsightEvaluator.InsightContext(operationCategory: .payment, requestedEvaluations: (IsLikelyBeingCoachedInsight.request(schema: .version1)))
            try expect(ctx.operationCategory == .payment && IsLikelyBeingCoachedInsight.typeIdentifier.count > 0, "context")
            let ev = InsightEvaluator()
            var auth = "-", eval = "-"
            do { auth = "\(try await ev.authorizationStatus(for: ctx))" } catch { auth = "threw \(error)" }
            do { let r = try await ev.requestEvaluation(context: ctx); eval = "evaluation \(r.eventID)" } catch { eval = "\(error)" }
            try expect(auth == "threw notAvailable" && eval == "notAvailable", "authorization \(auth), evaluation \(eval) (Apple's: notAvailable)")
            return "type \(IsLikelyBeingCoachedInsight.typeIdentifier), authorization \(auth), evaluation \(eval)"
        })
        #endif
        #if os(visionOS)
        c.append(check("TrustInsights", "visionos-unavailable") {
            // every TrustInsights API is unavailable on visionOS: the binary is there, its evaluator type is exported
            let path = "/System/Library/Frameworks/TrustInsights.framework/TrustInsights"
            let loaded = dlopen(path, RTLD_NOW) != nil
            let sym = p8Sym(path, "$s13TrustInsights16InsightEvaluatorCMa")
            try expect(loaded, "dlopen \(path)")
            return "loaded, InsightEvaluator metadata accessor \(sym)"
        })
        #endif

        // MARK: ServicesAccountLinking
        #if canImport(ServicesAccountLinking) && os(iOS)
        c.append(check("ServicesAccountLinking", "register-token-not-eligible", timeout: 40) {
            // not an authorized channel partner (and no media account): registration fails with a RegistrationError
            var r = "-"
            do { try await ResellerAccount.registerToken("sdkcov-p8-token"); r = "registered" }
            catch let e as RegistrationError { r = "RegistrationError \(e.code.rawValue)" }
            catch { r = "\(p8Err(error))" }
            try expect(r == "RegistrationError 1", "registerToken -> \(r) (Apple's: RegistrationError.failed, 1)")
            try expect(RegistrationErrorDomain == "SALRegistrationErrorDomain" && RegistrationErrorRetryAfterKey == "retryAfter", "constants")
            return "registerToken -> \(r)"
        })
        #endif

        // MARK: IdentityLookupUI
        #if canImport(IdentityLookupUI) && (os(iOS) || os(visionOS))
        c.append(check("IdentityLookupUI", "classification-view-controller") {
            // the extension's view controller outside an extension: builds, no context, not ready for a response
            try await onMain {
                let vc = ILClassificationUIExtensionViewController()
                vc.loadViewIfNeeded()
                // (extensionContext is non-optional in Swift: outside an extension it must not be touched)
                vc.view.frame = CGRect(x: 0, y: 0, width: 320, height: 200); vc.view.layoutIfNeeded()
                try expect(vc.isViewLoaded && vc.view.bounds.width == 320, "view")
                return "controller \(type(of: vc)), view \(type(of: vc.view!))"
            }
        })
        #endif

        // MARK: Accounts (deprecated)
        #if canImport(Accounts) && os(iOS)
        c.append(check("Accounts", "account-types-access", timeout: 30) {
            // the deprecated social account types: their access requests are refused
            let st = ACAccountStore()
            var out: [String] = []
            for id in [ACAccountTypeIdentifierTwitter, ACAccountTypeIdentifierFacebook, ACAccountTypeIdentifierSinaWeibo, ACAccountTypeIdentifierTencentWeibo] {
                let t = st.accountType(withAccountTypeIdentifier: id)
                out.append("\(id.split(separator: ".").last ?? ""): \(t == nil ? "nil" : "type, granted \(t!.accessGranted)")")
            }
            let r = P8Box<String>()
            if let tw = st.accountType(withAccountTypeIdentifier: ACAccountTypeIdentifierTwitter) {
                st.requestAccessToAccounts(with: tw, options: nil) { g, e in r.set("granted \(g) \(p8Err(e))") }
                out.append("request \(await r.wait(15) ?? "no answer in 15 s")")
            }
            let accts = (st.accounts as? [ACAccount] ?? []).map { "\($0.accountType?.identifier ?? "?") '\($0.username ?? "")'" }
            out.append("accounts \(accts)")
            // Apple's iPad simulator: the four types still resolve, the access request is refused (ACErrorDomain 7,
            // ACErrorPermissionDenied... as com.apple.accounts 7) and the store lists the local App Store account (a device
            // that used StoreKit sandbox also has com.apple.account.iTunesStore.sandbox 'local')
            try expect(r.value == "granted false com.apple.accounts 7", "request \(r.value ?? "none")")
            try expect(accts.contains("com.apple.account.iTunesStore 'local'"), "accounts \(accts)")
            return out.joined(separator: ", ")
        })
        #endif
        return c
    }
}
