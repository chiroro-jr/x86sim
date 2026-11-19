// SDK coverage, round 29: checks for the last [a] gaps (COVERAGE-GAPS.md). Each asserts what Apple's simulator answers
// (ref-mac.sh, inputs.sh on x86Sim).
import Foundation
import SwiftUI
#if canImport(WidgetKit) && !os(tvOS)
import WidgetKit
#endif
#if canImport(FileProvider) && (os(iOS) || os(visionOS))
import FileProvider
#endif
#if canImport(VisionKit) && os(iOS)
import VisionKit
import UIKit
#endif
#if canImport(HealthKit) && (os(iOS) || os(watchOS))
import HealthKit
#endif
#if canImport(PhotosUI) && os(iOS)
import PhotosUI
import AVRouting
import AVKit
#endif

private var p25InputWait: Double { Double(ProcessInfo.processInfo.environment["SDKCOV_INPUT_WAIT"] ?? "") ?? 0 }

extension Registry {
    static var p25: [Check] {
        var c: [Check] = []
        // MARK: RelevanceKit / WidgetKit: the widget extension's relevance() (ext/Widget.swift: the next hour) asked for
        // after WidgetCenter.invalidateRelevance(ofKind:)
        #if canImport(WidgetKit) && !os(tvOS)
        c.append(check("RelevanceKit", "widget-relevance-invalidate", timeout: 90) {
            let placed = ((try? await WidgetCenter.shared.currentConfigurations()) ?? []).filter { $0.kind == "sdkcov.static" }.count
            let t0 = Date()
            WidgetCenter.shared.invalidateRelevance(ofKind: "sdkcov.static")
            let asked = await p3Wait(placed > 0 ? 45 : 30) { !p3Marks("widget-relevance", since: t0).isEmpty }
            let d = "\(placed) placed sdkcov.static widgets; relevance() after invalidateRelevance \(p3Marks("widget-relevance", since: t0).count)"
            // Apple's simulator: asked at once with the widget on the home screen (inputs.sh widget / ref-mac.sh PRE=), never
            // without one
            try expect(asked == (placed > 0), d)
            return d
        })
        #endif
        // MARK: FileProvider: a materialized file evicted (back to dataless, read again = fetched again), reimport of the
        // root, the pending items enumerator
        #if canImport(FileProvider) && (os(iOS) || os(visionOS))
        c.append(check("FileProvider", "evict-reimport-pending", timeout: 150) {
            let since = Date()
            let dom = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier("sdkcov-p25"), displayName: "sdkcov P25")
            try? await NSFileProviderManager.remove(dom)
            try await NSFileProviderManager.add(dom)
            defer { Task { try? await NSFileProviderManager.remove(dom) } }
            guard let m = NSFileProviderManager(for: dom) else { throw Fail("no manager for the domain") }
            let root = try await m.getUserVisibleURL(for: .rootContainer)
            var names: [String] = []
            for _ in 0..<120 {
                names = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
                if names.contains("hello.txt") { break }
                try await Task.sleep(for: .milliseconds(500))
            }
            #if os(visionOS)
            try skipIf(names.isEmpty, "domain added, root lists nothing in 60 s (Apple's visionOS simulator the same)")
            #endif
            try expect(names.contains("hello.txt"), "root lists \(names)")
            let hello = root.appendingPathComponent("hello.txt")
            func dataless() -> String {
                var st = stat(); guard stat(hello.path, &st) == 0 else { return "stat errno \(errno)" }
                return (st.st_flags & 0x40000000) != 0 ? "dataless" : "materialized"
            }
            let s0 = dataless()
            _ = try String(contentsOf: hello, encoding: .utf8)
            let s1 = dataless()
            var steps = ["listed: \(s0)", "read: \(s1)"]
            // (right after the read fileproviderd may still refuse: nonEvictable -2008 while the download settles; retried)
            var refusals = 0, evicted = false
            for _ in 0..<15 {
                do { try await m.evictItem(identifier: NSFileProviderItemIdentifier("hello")); evicted = true; break }
                catch let e as NSError where e.domain == NSFileProviderErrorDomain && e.code == -2008 { refusals += 1; try await Task.sleep(for: .seconds(2)) }
                catch { let e = error as NSError; steps.append("evict error \(e.domain) \(e.code)"); break }
            }
            steps.append(evicted ? "evicted: \(dataless())" : "not evicted")
            let evictedState = steps.last!
            let again = try String(contentsOf: hello, encoding: .utf8)
            steps.append("read again \(again.count) chars: \(dataless())")
            do { try await m.reimportItems(below: .rootContainer); steps.append("reimport ok") }
            catch { let e = error as NSError; steps.append("reimport error \(e.domain) \(e.code)") }
            // the pending set: nothing waits to sync in a read-mostly domain
            let en = m.enumeratorForPendingItems()
            final class Obs: NSObject, NSFileProviderEnumerationObserver, @unchecked Sendable {
                var n = 0; var done = false; var err: Int?
                func didEnumerate(_ items: [NSFileProviderItemProtocol]) { n += items.count }
                func finishEnumerating(upTo nextPage: NSFileProviderPage?) { done = true }
                func finishEnumeratingWithError(_ error: Error) { err = (error as NSError).code; done = true }
            }
            let o = Obs()
            en.enumerateItems(for: o, startingAt: NSFileProviderPage(NSFileProviderPage.initialPageSortedByName as Data))
            _ = await p3Wait(10) { o.done }
            en.invalidate()
            steps.append("pending \(o.done ? (o.err.map { "error \($0)" } ?? "\(o.n) items") : "no answer")")
            steps.append("fetches \(p3Marks("fp-fetch", since: since))")
            let d = steps.joined(separator: "; ") + "; \(refusals) evict refusals first"
            // Apple's iOS 27.2 simulator: the evicted file is dataless again and the next read fetches it again; reimport
            // succeeds; nothing pending
            let fetches = p3Marks("fp-fetch", since: since).filter { $0 == "hello" }.count
            try expect(s0 == "dataless" && s1 == "materialized" && evictedState == "evicted: dataless" && fetches == 2
                       && steps.contains("reimport ok") && steps.contains("pending 0 items") && again.count == 35, "\(d) (\(refusals) refusals)")
            return d
        })
        #endif
        // MARK: VisionKit: Live Text selection on an analyzed image in a window (ImageAnalysisInteraction.selectedRanges,
        // as a user's text drag sets it), the highlighted selectable items and subject lifting
        #if canImport(VisionKit) && os(iOS)
        c.append(check("VisionKit", "interaction-text-selection-subjects", timeout: 90) {
            guard ImageAnalyzer.isSupported else { throw Fail("ImageAnalyzer not supported") }
            let img = textImage("SDKCOV LIVE TEXT", 900, 200, size: 72)
            let a = try await ImageAnalyzer().analyze(img, orientation: .up, configuration: ImageAnalyzer.Configuration([.text]))
            return try await p6A { () async throws -> String in
                let vc = UIViewController()
                let iv = UIImageView(image: UIImage(cgImage: img)); iv.contentMode = .scaleAspectFit; iv.isUserInteractionEnabled = true
                iv.frame = CGRect(x: 0, y: 200, width: 390, height: 87); vc.view.addSubview(iv)
                let (_, done) = try p6Show(vc); defer { done() }
                let ia = ImageAnalysisInteraction(); iv.addInteraction(ia)
                ia.preferredInteractionTypes = .automatic; ia.analysis = a
                try await Task.sleep(for: .milliseconds(500))
                let text = ia.text
                let before = ia.hasActiveTextSelection
                ia.selectedRanges = [text.startIndex..<text.endIndex]
                try await Task.sleep(for: .milliseconds(300))
                let sel = ia.selectedText, active = ia.hasActiveTextSelection
                ia.resetTextSelection()
                let reset = ia.hasActiveTextSelection
                ia.selectableItemsHighlighted = true
                let hl = ia.selectableItemsHighlighted
                let subjects = await ia.subjects
                let d = "text '\(text)', selection before \(before), after selectedRanges \(active) '\(sel)', after reset \(reset); highlighted \(hl); \(subjects.count) subjects, live text button \(ia.liveTextButtonVisible)"
                try expect(text.uppercased().contains("LIVE TEXT") && !before && active && sel == text && !reset && hl, d)
                return d
            }
        })
        #endif
        // MARK: HealthKit: the Health authorization sheet answered by the host (inputs.sh health: Turn On All, Allow;
        // ref-mac.sh INPUT= the same taps): requestAuthorization succeeds and the step count round trip runs authorized
        #if canImport(HealthKit) && (os(iOS) || os(watchOS))
        c.append(check("HealthKit", "input-authorization-round-trip", timeout: 240) {
            let wait = p25InputWait
            let st = HKHealthStore(), steps = HKQuantityType(.stepCount)
            guard wait > 0 else { return "share \(st.authorizationStatus(for: steps).rawValue) (SDKCOV_INPUT_WAIT unset: no sheet answer awaited)" }
            let req = Task { () -> String in
                do { try await st.requestAuthorization(toShare: [steps], read: [steps]); return "ok" } catch { return p5HK(error).map { "HK \($0)" } ?? p5Err(error) }
            }
            // (the status in the app changes only once the request has finished: wait for the request)
            let fin = P6Log()
            Task { _ = await req.value; fin.add("done") }
            let done = await p3Wait(wait + 60) { !fin.all.isEmpty }
            let r = done ? await req.value : "no answer"
            let shared = st.authorizationStatus(for: steps)
            try expect(r == "ok" && shared == .sharingAuthorized, "request \(r), share status \(shared.rawValue) after \(Int(wait + 60)) s")
            let t0 = Date().addingTimeInterval(-600), tag = "sdkcov-\(UUID().uuidString)"
            let s = HKQuantitySample(type: steps, quantity: HKQuantity(unit: .count(), doubleValue: 123), start: t0, end: t0.addingTimeInterval(60), metadata: [HKMetadataKeyExternalUUID: tag])
            let save = await p5HKTry { try await st.save(s); return "saved" }
            let pred = HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeyExternalUUID, allowedValues: [tag])
            let q = await p5HKTry { "\(try await HKSampleQueryDescriptor(predicates: [.quantitySample(type: steps, predicate: pred)], sortDescriptors: []).result(for: st).count) samples" }
            let sum = await p5HKTry { "\(try await HKStatisticsQueryDescriptor(predicate: .quantitySample(type: steps, predicate: pred), options: .cumulativeSum).result(for: st)?.sumQuantity()?.doubleValue(for: .count()) ?? 0)" }
            let del = await p5HKTry { "\(try await st.deleteObjects(of: steps, predicate: pred)) deleted" }
            let d = "request \(r), share \(shared.rawValue); save \(save), query \(q), sum \(sum), delete \(del)"
            try expect(save == "ok saved" && q == "ok 1 samples" && sum == "ok 123.0" && del == "ok 1 deleted", d)
            return d
        })
        #endif
        // MARK: PhotosUI: a photo picked in PHPickerViewController by the host (inputs.sh photopick: a tap on the first
        // grid cell, selection limit 1 finishes at once): the delegate's result loads an image (UIImage through its item
        // provider)
        #if canImport(PhotosUI) && os(iOS)
        c.append(check("PhotosUI", "input-picker-selection", timeout: 120) {
            let wait = p25InputWait
            guard wait > 0 else { return "no input (SDKCOV_INPUT_WAIT unset: no selection awaited)" }
            final class D: NSObject, PHPickerViewControllerDelegate, @unchecked Sendable {
                var results: [PHPickerResult]?
                func picker(_ p: PHPickerViewController, didFinishPicking r: [PHPickerResult]) { results = r; p.dismiss(animated: false) }
            }
            let d = D()
            let done = try await onMain { () throws -> () -> Void in
                var cfg = PHPickerConfiguration(photoLibrary: .shared()); cfg.selectionLimit = 1; cfg.filter = .images
                let pk = PHPickerViewController(configuration: cfg); pk.delegate = d; pk.modalPresentationStyle = .fullScreen
                let vc = UIViewController(); vc.view.backgroundColor = .white
                let (_, close) = try p6Show(vc)
                vc.present(pk, animated: false)
                return close
            }
            defer { Task { @MainActor in done() } }
            let picked = await p3Wait(wait + 20) { await onMain { d.results != nil } }
            let res = await onMain { d.results ?? [] }
            try expect(picked && res.count == 1, "picker results \(picked ? "\(res.count)" : "never")")
            let r = res[0]
            let img = await withCheckedContinuation { (k: CheckedContinuation<String, Never>) in
                guard r.itemProvider.canLoadObject(ofClass: UIImage.self) else { k.resume(returning: "cannot load UIImage"); return }
                r.itemProvider.loadObject(ofClass: UIImage.self) { o, e in
                    k.resume(returning: (o as? UIImage).map { "image \(Int($0.size.width))x\(Int($0.size.height))" } ?? "error \(e.map { "\(($0 as NSError).code)" } ?? "nil")")
                }
            }
            let d2 = "asset id \(r.assetIdentifier == nil ? "nil" : "set"), types \(r.itemProvider.registeredContentTypes.map(\.identifier).prefix(3)), \(img)"
            try expect(img.hasPrefix("image "), d2)
            return d2
        })
        #endif
        // MARK: WidgetKit: the app's control placed in Control Center by the user (inputs.sh control's pre: Control
        // Center opened, +, Add a Control, search "sdkcov", the control; ref-mac.sh PRE= the same touches), then tapped
        // there (send): it is among currentControls; its AppIntent never runs on either simulator
        #if canImport(WidgetKit) && os(iOS)
        c.append(check("WidgetKit", "input-placed-control-perform", timeout: 120) {
            let wait = p25InputWait
            let cur = { ((try? await ControlCenter.shared.currentControls()) ?? []).map(\.kind) }
            guard wait > 0 else { return "\(await cur()) (SDKCOV_INPUT_WAIT unset: no placed control awaited)" }
            let t0 = Date()
            var kinds: [String] = []
            _ = await p3Wait(20) { kinds = await cur(); return kinds.contains("sdkcov.control") }
            try expect(kinds.contains("sdkcov.control"), "no placed sdkcov.control: \(kinds)")
            let ran = await p3Wait(wait) { !p3Marks("control-perform", since: t0).isEmpty }
            let d = "placed \(kinds); perform \(p3Marks("control-perform", since: t0).count)x"
            // Apple's iOS 27.2 simulator: the tap closes Control Center, the intent's perform never runs in the widget
            // extension (the app does not carry the intent type)
            try expect(!ran, "the control's intent ran (Apple's simulator: never): \(d)")
            return d
        })
        #endif
        // MARK: AVRouting: the route picker with a custom routing controller tapped by the host (inputs.sh routepick: the
        // picker in the middle; ext/Discovery.swift would report a TV): discovery start, the controller's delegate events
        // and authorized routes
        #if canImport(PhotosUI) && os(iOS)
        c.append(check("AVRouting", "input-route-picker-discovery", timeout: 120) {
            let wait = p25InputWait
            guard wait > 0 else { return "no input (SDKCOV_INPUT_WAIT unset)" }
            final class D: NSObject, AVCustomRoutingControllerDelegate, @unchecked Sendable {
                let log = P6Log()
                func customRoutingController(_ c: AVCustomRoutingController, handle e: AVCustomRoutingEvent, completionHandler: @escaping (Bool) -> Void) {
                    log.add("\(e.reason.rawValue)"); completionHandler(true)
                }
            }
            let t0 = Date(), d = D()
            let (rc, done) = try await onMain { () throws -> (AVCustomRoutingController, () -> Void) in
                let rc = AVCustomRoutingController(); rc.delegate = d
                let vc = UIViewController(); vc.view.backgroundColor = .white
                let pv = AVRoutePickerView(frame: CGRect(x: 0, y: 0, width: 80, height: 80)); pv.customRoutingController = rc
                pv.center = CGPoint(x: vc.view.bounds.midX, y: vc.view.bounds.midY); pv.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin, .flexibleTopMargin, .flexibleBottomMargin]
                vc.view.addSubview(pv)
                let (_, close) = try p6Show(vc)
                return (rc, close)
            }
            defer { Task { @MainActor in done() } }
            _ = await p3Wait(wait) { !d.log.all.isEmpty }
            let routes = await onMain { rc.authorizedRoutes.map { $0.networkEndpoint.map { "\($0)" } ?? "route" } }
            let starts = p3Marks("discovery-start", since: t0).count
            let r = "discovery start \(starts), reported \(p3Marks("discovery-report", since: t0).count), ext events \(p3Marks("discovery-event", since: t0)); delegate \(d.log.all); authorized \(routes)"
            // Apple's iOS 27.2 simulator: a tap on the picker presents nothing, the discovery extension never starts, no
            // route events (no AirPlay route UI in the simulator)
            try expect(starts == 0 && d.log.all.isEmpty && routes.isEmpty, r)
            return r
        })
        #endif
        return c
    }
}
