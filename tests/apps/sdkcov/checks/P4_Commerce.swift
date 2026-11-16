// sdkcov P4: commerce and advertising. StoreKit 2 without a StoreKit configuration (the simulator's App Store sandbox:
// no products, no transactions), the original StoreKit API, SKAdNetwork / external purchase answers; the StoreKit and
// PassKit SwiftUI views on every platform; PassKit payment requests, the payment sheet, pass parsing, identity
// documents; AdAttributionKit / AdServices / AdSupport / AppTrackingTransparency / iAd answers; MarketplaceKit and
// FinanceKit (+ their UI) outside the EU / without Wallet data.
import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import StoreKit
#if canImport(_StoreKit_SwiftUI)
import _StoreKit_SwiftUI
#endif
#if canImport(PassKit)
import PassKit
#endif
#if canImport(_PassKit_SwiftUI)
import _PassKit_SwiftUI
#endif
#if canImport(AdAttributionKit) && os(iOS)
import AdAttributionKit
#endif
#if canImport(_AdAttributionKit_StoreKit) && os(iOS)
import _AdAttributionKit_StoreKit
#endif
#if canImport(AdServices) && (os(iOS) || os(visionOS))
import AdServices
#endif
#if canImport(AdSupport)
import AdSupport
#endif
#if canImport(AppTrackingTransparency)
import AppTrackingTransparency
#endif
#if canImport(MarketplaceKit) && os(iOS)
import MarketplaceKit
#endif
#if canImport(_MarketplaceKit_UIKit) && os(iOS)
import _MarketplaceKit_UIKit
#endif
#if canImport(FinanceKit) && os(iOS)
import FinanceKit
#endif
#if canImport(FinanceKitUI) && os(iOS)
import FinanceKitUI
#endif

/// first element of an async sequence within `secs`, or nil (the sequence may never yield)
func p4First<S: AsyncSequence & Sendable>(_ s: S, _ secs: Double) async -> String? where S.Element: Sendable {
    let box = P4Box<String>()
    let t = Task { do { for try await x in s { box.set("\(x)"); return }; box.set("<end>") } catch { box.set("<error \(error)>") } }
    let r = await box.wait(secs); t.cancel(); return r
}

/// `body`'s answer, or "no answer in N s" (the task is left running)
func p4Timed(_ secs: Double, _ body: @escaping @Sendable () async throws -> String) async -> String {
    let box = P4Box<String>()
    Task.detached { do { box.set(try await body()) } catch { box.set("error \(error)") } }
    return await box.wait(secs) ?? "no answer in \(Int(secs)) s"
}

/// put a SwiftUI view on screen (a window on iOS / tvOS / visionOS, Runner.overlay on watchOS) for `secs`; true when it appeared
func p4OnScreen<V: View>(_ v: V, secs: Double = 2) async throws -> String {
    let appeared = P4Box<Bool>()
    let root = v.onAppear { appeared.set(true) }
    #if os(watchOS)
    await onMain { Runner.shared.overlay = AnyView(root) }
    defer { Task { @MainActor in Runner.shared.overlay = nil } }
    try? await Task.sleep(nanoseconds: UInt64(secs * 1e9))
    try expect(await appeared.wait(3) == true, "view never appeared")
    return "appeared"
    #else
    let hc = await onMain { UIHostingController(rootView: root) }
    let close = try await onMain { try p4Show(hc).1 }
    defer { Task { @MainActor in close() } }
    try? await Task.sleep(nanoseconds: UInt64(secs * 1e9))
    try expect(await appeared.wait(3) == true, "view never appeared")
    return "appeared, \(await onMain { p4Views(hc.view).count }) views"
    #endif
}

#if !os(watchOS)
/// SKProductsRequest's answer, through its delegate
final class P4ProductsDelegate: NSObject, SKProductsRequestDelegate, @unchecked Sendable {
    let done = P4Box<String>()
    func productsRequest(_ request: SKProductsRequest, didReceive response: SKProductsResponse) {
        done.set("products \(response.products.count), invalid \(response.invalidProductIdentifiers.sorted())")
    }
    func request(_ request: SKRequest, didFailWithError error: Error) { done.set("error \((error as NSError).domain) \((error as NSError).code)") }
}
#endif

extension Registry {
    static var p4commerce: [Check] {
        var c: [Check] = []

        // MARK: StoreKit
        c.append(check("StoreKit", "transactions-entitlements-subscriptions", timeout: 60) {
            // no StoreKit configuration and no purchases: every transaction sequence is empty, subscription status too
            let ent = await p4First(Transaction.currentEntitlements, 8)
            try expect(ent == "<end>", "currentEntitlements yielded \(ent ?? "nothing in 8 s")")
            let unf = await p4First(Transaction.unfinished, 8)
            try expect(unf == "<end>", "unfinished yielded \(unf ?? "nothing in 8 s")")
            let all = await p4First(Transaction.all, 8)
            try expect(all == "<end>", "all yielded \(all ?? "nothing in 8 s")")
            let latest = await Transaction.latest(for: "com.x86sim.test.sdkcov.none")
            try expect(latest == nil, "latest(for:) \(String(describing: latest))")
            let upd = await p4First(Transaction.updates, 2)
            try expect(upd == nil, "updates yielded \(upd ?? "")")
            var subs = "?"
            do { let s = try await Product.SubscriptionInfo.status(for: "sdkcov-group"); subs = "\(s.count) statuses"; try expect(s.isEmpty, "statuses \(s.count)") }
            catch let e as Fail { throw e } catch { subs = "error \(error)" }
            let intro = await Product.SubscriptionInfo.isEligibleForIntroOffer(for: "sdkcov-group")
            return "entitlements/unfinished/all empty, latest nil, no updates, subscription \(subs), intro eligible \(intro)"
        })
        c.append(check("StoreKit", "app-transaction-sync-legacy-request", timeout: 60) {
            // AppTransaction.shared and the original API's product request: what the simulator's sandbox answers
            var at = "?"
            do {
                switch try await AppTransaction.shared {
                case .verified(let t): at = "verified \(t.environment.rawValue) \(t.bundleID)"
                case .unverified(let t, let e): at = "unverified \(t.environment.rawValue) (\(e))"
                }
            } catch { at = "error \((error as NSError).domain) \((error as NSError).code)" }
            // Apple's simulator without a StoreKit configuration: StoreKitError 1 (unknown)
            try expect(at.hasPrefix("error"), "AppTransaction.shared: \(at) (Apple's: StoreKitError 1)")
            #if !os(watchOS)
            try expect(SKPaymentQueue.canMakePayments() == AppStore.canMakePayments, "canMakePayments disagree")
            let d = P4ProductsDelegate()
            let req = SKProductsRequest(productIdentifiers: ["com.x86sim.test.sdkcov.none"]); req.delegate = d; req.start()
            let r = await d.done.wait(30)
            try expect(r == "products 0, invalid [\"com.x86sim.test.sdkcov.none\"]", "SKProductsRequest: \(r ?? "no answer in 30 s")")
            let q = SKPaymentQueue.default()
            try expect(q.transactions.isEmpty, "\(q.transactions.count) queued transactions")
            #else
            let r: String? = "n/a"
            #endif
            return "AppTransaction \(at); SKProductsRequest \(r ?? "")"
        })
        #if os(iOS)
        c.append(check("StoreKit", "adnetwork-external-purchase", timeout: 40) {
            // SKAdNetwork postback update and the external purchase APIs: an app without the entitlements / not EU
            let pb = P4Box<String>()
            SKAdNetwork.updatePostbackConversionValue(3, coarseValue: .medium, lockWindow: false) { e in pb.set(e.map { "\(($0 as NSError).domain) \(($0 as NSError).code)" } ?? "ok") }
            let p = await pb.wait(15)
            try expect(p == "SKANErrorDomain 10", "postback update: \(p ?? "no answer") (Apple's: SKANErrorDomain 10)")
            let ep = await ExternalPurchase.canPresent, el = await ExternalPurchaseLink.canOpen, ela = await ExternalLinkAccount.canOpen
            try expect(!ep && !el && !ela, "external purchase without entitlement: canPresent \(ep) link \(el) account \(ela)")
            return "postback update \(p ?? "no answer"), external purchase / link / account false"
        })
        #endif
        #if !os(tvOS)   // tvOS: More_tvOS.swift
        c.append(check("_StoreKit_SwiftUI", "product-store-views", timeout: 40) {
            // no StoreKit configuration or App Store account: the views show their unavailable state, no crash
            let v = VStack {
                ProductView(id: "com.x86sim.test.sdkcov.none")
                StoreView(ids: ["com.x86sim.test.sdkcov.none"])
                SubscriptionStoreView(groupID: "sdkcov-group")
            }
            return try await p4OnScreen(v, secs: 3)
        })
        #endif

        // MARK: PassKit
        #if canImport(PassKit)
        c.append(check("PassKit", "payment-request-sheet", timeout: 60) {
            let req = PKPaymentRequest()
            req.merchantIdentifier = "merchant.com.x86sim.test.sdkcov"; req.countryCode = "US"; req.currencyCode = "USD"
            req.supportedNetworks = [.visa, .masterCard, .amex]; req.merchantCapabilities = [.threeDSecure]
            req.paymentSummaryItems = [PKPaymentSummaryItem(label: "Widget", amount: 9.99), PKPaymentSummaryItem(label: "sdkcov", amount: 9.99)]
            req.requiredShippingContactFields = [.emailAddress]
            req.shippingMethods = [{ let m = PKShippingMethod(label: "Free", amount: 0); m.identifier = "free"; return m }()]
            try expect(req.paymentSummaryItems.last?.amount == 9.99 && req.shippingMethods?.first?.identifier == "free", "request")
            let can = PKPaymentAuthorizationController.canMakePayments()
            let canNet = PKPaymentAuthorizationController.canMakePayments(usingNetworks: req.supportedNetworks)
            #if os(watchOS)
            return "canMakePayments \(can), with networks \(canNet)"
            #else
            // the payment sheet (the simulator's Apple Pay sandbox): presented, then dismissed
            let ctl = PKPaymentAuthorizationController(paymentRequest: req)
            let shown: Bool = await withCheckedContinuation { k in Task { @MainActor in ctl.present { k.resume(returning: $0) } } }
            if shown {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await withCheckedContinuation { k in Task { @MainActor in ctl.dismiss { k.resume() } } }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            #if os(visionOS)   // Apple's visionOS simulator: canMakePayments true, but present() answers false at once
            try expect(can && !shown, "payment sheet presented \(shown), canMakePayments \(can) (Apple's visionOS simulator: true / not presented)")
            #else
            try expect(can && shown, "payment sheet presented \(shown), canMakePayments \(can) (Apple's simulator: both true, the Apple Pay sandbox)")
            #endif
            return "canMakePayments \(can), with networks \(canNet), sheet presented \(shown)"
            #endif
        })
        #if os(iOS) || os(visionOS)
        c.append(check("PassKit", "pass-parsing-library-identity", timeout: 40) {
            // an unsigned pass is refused; the library and add-passes controller answer; identity documents (iOS)
            var perr = "parsed"
            do { _ = try PKPass(data: Data("not a pass".utf8)) } catch { perr = "\((error as NSError).domain) \((error as NSError).code)" }
            try expect(perr.hasPrefix(PKPassKitErrorDomain), "PKPass(data: junk): \(perr)")
            let lib = PKPassLibrary()
            let passes = lib.passes()
            let canAdd = PKAddPassesViewController.canAddPasses()
            // PKIdentityAuthorizationController.checkCanRequestDocument is not called: without the in-app identity entitlement
            // Apple's simulator ends the app ("called an API it is not entitled to use")
            let idDoc = "identity documents not asked (entitlement)"
            return "junk pass: \(perr); \(passes.count) passes, library \(PKPassLibrary.isPassLibraryAvailable()), canAddPasses \(canAdd); \(idDoc)"
        })
        #endif
        #if !os(iOS) && !os(tvOS) && canImport(_PassKit_SwiftUI)   // iOS: More_iOS.swift
        c.append(check("_PassKit_SwiftUI", "wallet-pay-buttons", timeout: 30) {
            #if os(watchOS)   // watchOS: the pay button only
            let v = PayWithApplePayButton(.buy) {}.frame(height: 44)
            #else
            let v = VStack(spacing: 10) {
                PayWithApplePayButton(.buy) {}.frame(height: 44)
                AddPassToWalletButton {}.frame(height: 44)
            }
            #endif
            return try await p4OnScreen(v, secs: 2)
        })
        #endif
        #endif

        // MARK: advertising / attribution
        #if canImport(AdSupport) && canImport(AppTrackingTransparency)
        c.append(check("AdSupport", "idfa-zero-unless-authorized") {
            // the IDFA is all zeros unless tracking is authorized (the simulator never asks on its own)
            let st = ATTrackingManager.trackingAuthorizationStatus
            let id = ASIdentifierManager.shared().advertisingIdentifier.uuidString
            if st == .authorized { try expect(id != "00000000-0000-0000-0000-000000000000", "authorized but zeroed") }
            else { try expect(id == "00000000-0000-0000-0000-000000000000", "IDFA \(id) with tracking status \(st.rawValue)") }
            return "tracking status \(st.rawValue), IDFA \(st == .authorized ? "set" : "zeroed")"
        })
        #endif
        #if canImport(AppTrackingTransparency)
        c.append(check("AppTrackingTransparency", "not-determined-on-fresh-install") {
            // a fresh install: not determined (asking shows the system prompt, which this run does not answer)
            let st = ATTrackingManager.trackingAuthorizationStatus
            // Apple's simulator (iOS 27.2): notDetermined. Restricted (1) here meant ManagedConfiguration's profiled was missing
            try expect(st == .notDetermined, "status \(st.rawValue) (Apple's: 0, not determined)")
            return "status \(st.rawValue)"
        })
        #endif
        #if canImport(AdServices) && (os(iOS) || os(visionOS))
        c.append(check("AdServices", "attribution-token-sim-error", timeout: 20) {
            // Apple's simulator has no attribution token: AAAttributionErrorCode.platformNotSupported (3)
            do { let t = try AAAttribution.attributionToken(); return "token \(t.count) chars" }
            catch {
                let e = error as NSError
                try expect(e.domain == AAAttributionErrorDomain && e.code == 3, "error \(e.domain) \(e.code)")
                return "platformNotSupported (\(e.code))"
            }
        })
        #endif
        #if canImport(AdAttributionKit) && os(iOS)
        c.append(check("AdAttributionKit", "impression-postback-answers", timeout: 40) {
            var jws = "parsed"
            do { _ = try await AppImpression(compactJWS: "not.a.jws") } catch let e as AdAttributionKitError { jws = "\(e)" } catch { jws = "other \(error)" }
            // Apple's simulator: AdAttributionKit is unsupported there, every call fails NSCocoaErrorDomain 3328
            try expect(jws.contains("NSCocoaErrorDomain Code=3328"), "AppImpression(compactJWS: junk): \(jws) (Apple's: NSCocoaErrorDomain 3328)")
            try expect(!AppImpression.isSupported && !Postback.isSupported, "isSupported (Apple's: false)")
            let upd = PostbackUpdate(fineConversionValue: 12, lockPostback: false, coarseConversionValue: .high, conversionTypes: [.install])
            try expect(upd.fineConversionValue == 12 && upd.coarseConversionValue == .high, "PostbackUpdate")
            try expect(CoarseConversionValue(rawValue: "medium") == .medium, "CoarseConversionValue raw")
            var pb = "ok"
            do { try await Postback.updateConversionValue(upd) } catch { pb = "\(error)" }
            try expect(pb.contains("NSCocoaErrorDomain Code=3328"), "Postback.updateConversionValue: \(pb) (Apple's: NSCocoaErrorDomain 3328)")
            return "junk JWS: \(jws); impressions supported \(AppImpression.isSupported), postbacks \(Postback.isSupported), update: \(pb)"
        })
        #endif
        #if canImport(_AdAttributionKit_StoreKit) && os(iOS)
        c.append(check("_AdAttributionKit_StoreKit", "overlay-configuration-impression") {
            let cfg = SKOverlay.AppConfiguration(appIdentifier: "1234567890", position: .bottom)
            try expect(cfg.appImpression == nil, "default impression")
            cfg.adAttributionReengagementURL = URL(string: "sdkcov://reengage")
            try expect(cfg.appIdentifier == "1234567890", "appIdentifier")
            // Apple's simulator keeps no re-engagement URL (AdAttributionKit unsupported there): reads back nil
            try expect(cfg.adAttributionReengagementURL == nil, "re-engagement URL kept (Apple's: nil)")
            return "appImpression nil, re-engagement URL \(cfg.adAttributionReengagementURL?.absoluteString ?? "nil")"
        })
        #endif
        #if os(iOS)
        c.append(check("iAd", "client-attribution-obsolete", timeout: 20) {
            // ADClient is obsoleted in Swift since iOS 18: called through the runtime as an old app would
            guard dlopen("/System/Library/Frameworks/iAd.framework/iAd", RTLD_NOW) != nil, let cls = NSClassFromString("ADClient") as? NSObject.Type else {
                return "no ADClient class (removed)"
            }
            // Apple's simulator (iOS 27.2): the class is there, sharedClient is nil (obsoleted)
            guard let cl = (cls as AnyObject).perform(NSSelectorFromString("sharedClient"))?.takeUnretainedValue() as? NSObject else { return "ADClient.sharedClient nil (as Apple's)" }
            let got = P4Box<String>()
            let blk: @convention(block) (NSDictionary?, NSError?) -> Void = { d, e in got.set(e.map { "error \($0.domain) \($0.code)" } ?? "details \(d?.count ?? 0) keys") }
            _ = cl.perform(NSSelectorFromString("requestAttributionDetailsWithBlock:"), with: blk as AnyObject)
            let r = await got.wait(10)
            try expect(r?.hasPrefix("error") == true, "requestAttributionDetails: \(r ?? "no answer")")
            return r!
        })
        #endif

        // MARK: MarketplaceKit / FinanceKit (iOS)
        #if canImport(MarketplaceKit) && os(iOS)
        c.append(check("MarketplaceKit", "distributor-requirements", timeout: 40) {
            // AppDistributor.current for an app installed by simctl / x86sim install (not from a store); the install
            // requirements a marketplace checks. (AppLibrary.current is not touched: on Apple's simulator its main-actor
            // properties block the main thread for good outside a marketplace app)
            // Apple's simulator never answers these two for a simctl-installed app ("no answer"); x86Sim answers at once
            let dist = await p4Timed(15) { () async throws -> String in
                switch try await AppDistributor.current {
                case .appStore: return "appStore"; case .testFlight: return "testFlight"; case .marketplace(let m): return "marketplace \(m)"
                case .web: return "web"; case .other: return "other"; @unknown default: return "unknown"
                }
            }
            let region = await p4Timed(15) { await AppDistributor.eligibilityRegion ?? "nil" }
            // InstallRequirements: Codable round trip (satisfiedByDevice() is not called: on Apple's simulator it never returns)
            var req = InstallRequirements(); req.minimumSystemVersion = "26.0"; req.requiredDeviceCapabilities = ["arm64"]; req.expectedInstallSize = 1 << 20
            let rj = try JSONEncoder().encode(req)
            let rb = try JSONDecoder().decode(InstallRequirements.self, from: rj)
            try expect(rb.minimumSystemVersion == "26.0" && rb.requiredDeviceCapabilities == ["arm64"] && rb.expectedInstallSize == 1 << 20, "InstallRequirements round trip")
            let v = AppVersion(appleItemID: 42, appleVersionID: 7)
            try expect(v.appleItemID == 42, "AppVersion")
            // Apple's simulator never answers either for a simctl-installed app (no store / marketplace install record)
            try expect(dist.hasPrefix("no answer") && region.hasPrefix("no answer"), "distributor \(dist), eligibility region \(region) (Apple's simulator: no answer in 15 s to either)")
            return "distributor \(dist), eligibility region \(region), requirements \(rj.count) B JSON"
        })
        #endif
        #if canImport(_MarketplaceKit_UIKit) && os(iOS)
        c.append(check("_MarketplaceKit_UIKit", "install-metadata-display-options", timeout: 30) {
            // the value types a marketplace's ActionButton takes. ActionButton itself is not made: on Apple's simulator
            // its init blocks the main thread for good outside a marketplace app
            let pkg = URL(string: "https://example.com/app.adp")!
            let md = InstallMetadata(account: "ada", appleItemID: 42, alternativeDistributionPackage: pkg, isUpdate: false, appShareURL: nil, requestAgeException: true)
            try expect(md.appleItemID == 42 && md.requestAgeException && !md.isUpdate, "InstallMetadata")
            let cfg = InstallConfiguration(install: md) { .cancel }
            try expect(cfg.install.account == "ada", "InstallConfiguration")
            let r = await cfg.confirmInstall()
            guard case .cancel = r else { throw Fail("confirmInstall") }
            let opts: [MarketplaceDisplayOption] = [.productPage(appleItemID: 42, appleVersionID: 7), .searchResults(query: "maps"), .authentication(account: "ada")]
            let js = try JSONEncoder().encode(opts)
            let back = try JSONDecoder().decode([MarketplaceDisplayOption].self, from: js)
            guard back.count == 3, case .searchResults(let q) = back[1], q == "maps" else { throw Fail("display options round trip") }
            try expect(ActionButton.ButtonImagePlacement(rawValue: 1) == .leading, "ButtonImagePlacement")
            return "InstallMetadata / InstallConfiguration, display options \(js.count) B JSON"
        })
        #endif
        #if canImport(FinanceKit) && os(iOS)
        c.append(check("FinanceKit", "availability-authorization", timeout: 30) {
            let fin = FinanceStore.isDataAvailable(.financialData), ord = FinanceStore.isDataAvailable(.orders)
            try expect(fin && ord, "isDataAvailable financialData \(fin) orders \(ord) (Apple's simulator: both true)")
            // authorizationStatus() traps ("Process is not entitled") without the FinanceKit entitlement: not called
            let auth = "not asked (no entitlement)"
            // no queries: without the FinanceKit entitlement FinanceStore's store setup traps
            return "financial data available \(fin), orders \(ord), authorization \(auth)"
        })
        #endif
        #if canImport(FinanceKitUI) && os(iOS)
        c.append(check("FinanceKitUI", "transaction-picker-order-button", timeout: 30) {
            let v = VStack {
                TransactionPicker(selection: .constant([])) { Text("Pick transactions") }
                AddOrderToWalletButton(signedArchive: Data()) { _ in }.frame(height: 44)
            }
            return try await p4OnScreen(v, secs: 2)
        })
        #endif
        return c
    }
}
