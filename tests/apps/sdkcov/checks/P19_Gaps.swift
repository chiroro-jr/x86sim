// SDK coverage, round 23: checks for [a] gaps of covered frameworks (COVERAGE-GAPS.md). Each asserts what Apple's
// simulator answers (ref-mac.sh).
import Foundation
import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif
#if canImport(CreateMLComponents)
import CreateMLComponents
#endif
#if canImport(RealityKit) && !os(watchOS)
import RealityKit
#endif
#if canImport(CoreAudioKit) && (os(iOS) || os(visionOS))
import CoreAudioKit
#endif
#if canImport(IntentsUI) && os(iOS)
import IntentsUI
#endif
#if canImport(ReplayKit) && os(iOS)
import ReplayKit
#endif
#if canImport(Translation) && os(iOS)
import Translation
#endif
#if canImport(Charts) && os(visionOS)
import Charts
#endif
#if canImport(NetworkExtension) && os(visionOS)
import NetworkExtension
#endif
#if canImport(SafariServices) && os(visionOS)
import SafariServices
#endif

#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(LinkPresentation)
import LinkPresentation
#endif
#if canImport(LiveCommunicationKit) && !os(tvOS)
import LiveCommunicationKit
#endif
#if canImport(Photos) && !os(watchOS)
import Photos
#endif
#if canImport(EventKitUI) && (os(iOS) || os(visionOS))
import EventKit
import EventKitUI
#endif
#if canImport(ContactsUI) && (os(iOS) || os(visionOS))
import ContactsUI
#endif
#if canImport(CoreLocation) && os(iOS)
import CoreLocation
#endif
#if canImport(Intents) && canImport(UserNotifications) && !os(tvOS)
import Intents
import UserNotifications
#endif
#if canImport(AuthenticationServices) && (os(iOS) || os(visionOS))
import AuthenticationServices
#endif
#if canImport(QuickLook) && (os(iOS) || os(visionOS))
import QuickLook
#endif

#if canImport(RealityKit) && !os(watchOS)
/// a Reality Composer Pro style material: a MaterialX preview surface whose roughness and base color come from the
/// material's own inputs (Rough, Tint), the parameters ShaderGraphMaterial exposes
let p19MaterialUSDA = """
#usda 1.0
def Xform "Root"
{
    def Material "M"
    {
        float inputs:Rough = 0.5
        color3f inputs:Tint = (1, 0, 0)
        token outputs:mtlx:surface.connect = </Root/M/Surf.outputs:out>

        def Shader "Surf"
        {
            uniform token info:id = "ND_UsdPreviewSurface_surfaceshader"
            color3f inputs:diffuseColor.connect = </Root/M.inputs:Tint>
            float inputs:roughness.connect = </Root/M.inputs:Rough>
            token outputs:out
        }
    }
}
"""
#endif

#if canImport(IntentsUI) && os(iOS)
final class P19VoiceShortcutDelegate: NSObject, INUIAddVoiceShortcutViewControllerDelegate {
    let log = P6Log()
    func addVoiceShortcutViewController(_ c: INUIAddVoiceShortcutViewController, didFinishWith s: INVoiceShortcut?, error: Error?) { log.add("finish \(error.map { "\(($0 as NSError).code)" } ?? "ok")") }
    func addVoiceShortcutViewControllerDidCancel(_ c: INUIAddVoiceShortcutViewController) { log.add("cancel") }
}
#endif


#if canImport(LiveCommunicationKit) && !os(tvOS)
final class P19ConversationDelegate: ConversationManagerDelegate, @unchecked Sendable {
    let log = P6Log()
    func conversationManager(_ m: ConversationManager, conversationChanged c: Conversation) { log.add("changed \(c.state)") }
    func conversationManagerDidBegin(_ m: ConversationManager) { log.add("begin") }
    func conversationManagerDidReset(_ m: ConversationManager) { log.add("reset") }
    func conversationManager(_ m: ConversationManager, perform a: ConversationAction) { log.add("perform \(type(of: a))") }
    func conversationManager(_ m: ConversationManager, timedOutPerforming a: ConversationAction) { log.add("timeout \(type(of: a))") }
    func conversationManager(_ m: ConversationManager, didActivate s: AVAudioSession) { log.add("activate") }
    func conversationManager(_ m: ConversationManager, didDeactivate s: AVAudioSession) { log.add("deactivate") }
}
#endif
#if canImport(EventKitUI) && (os(iOS) || os(visionOS))
final class P19EventEditDelegate: NSObject, EKEventEditViewDelegate {
    let log = P6Log()
    func eventEditViewController(_ c: EKEventEditViewController, didCompleteWith a: EKEventEditViewAction) { log.add("complete \(a.rawValue)"); c.dismiss(animated: false) }
}
#endif
#if canImport(ContactsUI) && (os(iOS) || os(visionOS))
final class P19ContactDelegate: NSObject, CNContactViewControllerDelegate {
    let log = P6Log()
    func contactViewController(_ vc: CNContactViewController, didCompleteWith contact: CNContact?) { log.add("complete \(contact == nil ? "nil" : "contact")") }
}
#endif
#if canImport(CoreLocation) && os(iOS)
final class P19LocationDelegate: NSObject, CLLocationManagerDelegate {
    let log = P6Log()
    func locationManager(_ m: CLLocationManager, didUpdateLocations ls: [CLLocation]) { for l in ls { log.add(String(format: "loc %.4f,%.4f", l.coordinate.latitude, l.coordinate.longitude)) } }
    func locationManager(_ m: CLLocationManager, didFailWithError e: Error) { log.add("fail \((e as NSError).code)") }
    func locationManager(_ m: CLLocationManager, didVisit v: CLVisit) { log.add("visit") }
}
#endif

#if canImport(QuickLook) && (os(iOS) || os(visionOS))
final class P19QLSource: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
    let urls: [URL]; let log = P6Log()
    init(_ u: [URL]) { urls = u }
    func numberOfPreviewItems(in c: QLPreviewController) -> Int { urls.count }
    func previewController(_ c: QLPreviewController, previewItemAt i: Int) -> QLPreviewItem { urls[i] as NSURL }
    func previewController(_ c: QLPreviewController, editingModeFor item: QLPreviewItem) -> QLPreviewItemEditingMode {
        log.add("editingMode \(item.previewItemURL?.pathExtension ?? "?")"); return .createCopy
    }
    func previewController(_ c: QLPreviewController, didSaveEditedCopyOf item: QLPreviewItem, at url: URL) { log.add("savedCopy") }
    func previewController(_ c: QLPreviewController, didUpdateContentsOf item: QLPreviewItem) { log.add("updated") }
}
/// present a QLPreviewController over a fresh window for `urls`; returns it, its source and the take-down
@MainActor func p19PresentQL(_ urls: [URL]) throws -> (QLPreviewController, P19QLSource, () -> Void) {
    let root = UIViewController(); root.view.backgroundColor = .white
    let (_, close) = try p6Show(root)
    let src = P19QLSource(urls), q = QLPreviewController()
    q.dataSource = src; q.delegate = src
    root.present(q, animated: false)
    return (q, src, { root.dismiss(animated: false); close() })
}
#endif

#if os(tvOS)
@MainActor final class P19MenuModel: ObservableObject { @Published var pick = 1; @Published var tool = false }
private struct P19TVMenuRoot: View {
    @ObservedObject var m: P19MenuModel
    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Menu("SDKCovMenu") { Button("One") {}; Button("Two") {} }
                Picker("Flavor", selection: $m.pick) { Text("A").tag(0); Text("B").tag(1); Text("C").tag(2) }.pickerStyle(.menu)
                Text("SDKCovBody").contextMenu { Button("SDKCovCtx") {} }
            }
            .navigationTitle("SDKCov")
            .toolbar { ToolbarItem(placement: .primaryAction) { Button("SDKCovTool") { m.tool = true } } }
        }
    }
}
#endif

extension Registry {
    static var p19: [Check] {
        var c: [Check] = []

        // MARK: CreateMLComponents: a composed estimator (min-max then standard scaler) fitted, written and read back
        #if canImport(CreateMLComponents)
        c.append(check("CreateMLComponents", "pipeline-append-write-read", timeout: 60) {
            let xs: [Double] = [2, 4, 4, 4, 5, 5, 7, 9]
            let est = MinMaxScaler<Double>().appending(StandardScaler<Double>())
            let fitted = try await est.fitted(to: xs)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("sdkcov-p19-pipeline")
            try? FileManager.default.removeItem(at: url)
            try est.write(fitted, to: url)
            let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? -1
            let back = try est.read(from: url)
            var outs: [String] = []
            for x in [2.0, 5.5, 9.0] {
                let a = try await fitted.applied(to: x), b = try await back.applied(to: x)
                try expect(abs(a - b) < 1e-12, "\(x): fitted \(a), read back \(b)")
                outs.append(String(format: "%.4f", a))
            }
            // min-max to [0, 1] (5.5 -> 0.5), then centred on the scaled mean 3/7 = 0.4286
            let mid = try await back.applied(to: 5.5)
            let sd = try await StandardScaler<Double>().fitted(to: xs.map { ($0 - 2) / 7 }).standardDeviation
            try expect(abs(mid - (0.5 - 3.0 / 7) / sd) < 1e-9, "5.5 -> \(mid), want \((0.5 - 3.0 / 7) / sd)")
            // Apple's simulator (all four): -1.4031, 0.2339, 1.8708
            try expect(outs == ["-1.4031", "0.2339", "1.8708"], "outputs \(outs) (Apple's simulator: -1.4031, 0.2339, 1.8708)")
            try? FileManager.default.removeItem(at: url)
            return "written \(size) B, read back: \(outs.joined(separator: ", "))"
        })
        #endif

        // MARK: RealityKit: a ShaderGraphMaterial loaded from USDA data, its inputs as parameters
        #if canImport(RealityKit) && !os(watchOS)
        c.append(check("RealityKit", "shader-graph-material", timeout: 60) {
            var m = try await ShaderGraphMaterial(named: "/Root/M", from: Data(p19MaterialUSDA.utf8))
            let names = m.parameterNames.sorted()
            try expect(names.contains("Rough") && names.contains("Tint"), "parameters \(names)")
            try m.setParameter(name: "Rough", value: .float(0.25))
            let got: String
            if case .float(let f)? = m.getParameter(name: "Rough") { got = "\(f)" } else { got = "\(String(describing: m.getParameter(name: "Rough")))" }
            try expect(got == "0.25", "Rough after set: \(got)")
            var unknown = "accepted"
            do { try m.setParameter(name: "NoSuchInput", value: .float(1)) } catch { unknown = "\(error)" }
            var missing = "loaded"
            do { _ = try await ShaderGraphMaterial(named: "/Root/Nope", from: Data(p19MaterialUSDA.utf8)) } catch { missing = "\(error)" }
            let e = await onMain { ModelEntity(mesh: .generateBox(size: 0.1), materials: [m]) }
            let n = await onMain { e.model?.materials.count ?? 0 }
            // Apple's simulator (iOS, tvOS, visionOS): parameterNameNotFound for an unknown input, invalidTypeFound for a path
            // that names no material
            try expect(n == 1 && unknown == "parameterNameNotFound" && missing == "invalidTypeFound", "entity materials \(n), unknown parameter \(unknown), missing material \(missing) (Apple's simulator: parameterNameNotFound, invalidTypeFound)")
            return "parameters \(names), Rough 0.25, unknown parameter: \(unknown.prefix(80)), missing material: \(missing.prefix(80))"
        })
        #endif

        // MARK: CoreAudioKit: the Bluetooth MIDI view controllers load their views (no Bluetooth in a simulator)
        #if canImport(CoreAudioKit) && (os(iOS) || os(visionOS))
        c.append(check("CoreAudioKit", "bt-midi-view-controllers-load", timeout: 30) {
            try await onMain { () -> String in
                let p = CABTMIDILocalPeripheralViewController(), cvc = CABTMIDICentralViewController()
                p.loadViewIfNeeded(); cvc.loadViewIfNeeded()
                let (w, close) = try p6Show(UINavigationController(rootViewController: cvc)); defer { close() }
                w.layoutIfNeeded()
                let rows = (0..<cvc.tableView.numberOfSections).map { cvc.tableView.numberOfRows(inSection: $0) }
                let pv = "\(type(of: p.view!)) \(p.view.subviews.count) subviews"
                // Apple's simulator (iOS, visionOS): both table views, the central one with 1 section of 1 row (no devices)
                try expect(p.view is UITableView && rows == [1] && cvc.title == "Bluetooth MIDI Devices", "peripheral \(pv), central rows \(rows) title \(cvc.title ?? "nil")")
                return "peripheral \(pv); central \(type(of: cvc.view!)) sections/rows \(rows), title \(cvc.title ?? cvc.navigationItem.title ?? "nil")"
            }
        })
        #endif

        // MARK: IntentsUI: the add-voice-shortcut sheet presented and dismissed
        #if canImport(IntentsUI) && os(iOS)
        c.append(check("IntentsUI", "add-voice-shortcut-present", timeout: 40) {
            let d = P19VoiceShortcutDelegate()
            let (root, close) = try await onMain { () -> (UIViewController, () -> Void) in
                let vc = UIViewController(); vc.view.backgroundColor = .white
                let (_, close) = try p6Show(vc); return (vc, close)
            }
            defer { Task { @MainActor in close() } }
            let sc = INShortcut(userActivity: NSUserActivity(activityType: "com.x86sim.test.sdkcov.activity"))
            let vc = await onMain { () -> INUIAddVoiceShortcutViewController in
                let v = INUIAddVoiceShortcutViewController(shortcut: sc); v.delegate = d
                root.present(v, animated: false); return v
            }
            let shown = await p6Wait(10) { root.presentedViewController === vc && vc.viewIfLoaded?.window != nil }
            _ = await p6Wait(15) { !d.log.all.isEmpty }
            let state = await onMain { "presented \(root.presentedViewController.map { "\(type(of: $0))" } ?? "nil"), children \(vc.children.map { "\(type(of: $0))" })" }
            await onMain { root.dismiss(animated: false) }
            let gone = await p6Wait(5) { root.presentedViewController == nil }
            // Apple's simulator: presented, the remote host child loads, then the delegate hears error 7000 (the shortcut made
            // from a user activity without a title is invalid)
            try expect(shown && gone && d.log.all == ["finish 7000"], "shown \(shown) gone \(gone): \(state), events \(d.log.all)")
            return "\(state); events \(d.log.all)"
        })
        #endif

        // MARK: ReplayKit: the broadcast service picker (no broadcast extension installed)
        #if canImport(ReplayKit) && os(iOS)
        c.append(check("ReplayKit", "broadcast-activity-load", timeout: 30) {
            let r = P8Box<String>()
            RPBroadcastActivityViewController.load { vc, e in
                r.set(e.map { "error \(($0 as NSError).domain) \(($0 as NSError).code)" } ?? (vc.map { "controller \(type(of: $0))" } ?? "nothing"))
            }
            guard let res = await r.wait(20) else { throw Fail("load never answered in 20 s") }
            try expect(res == "controller RPBroadcastActivityViewController", "\(res) (Apple's simulator: a controller)")
            return res
        })
        #endif

        // MARK: Translation: a batch and prepareTranslation without installed languages
        #if canImport(Translation) && os(iOS)
        c.append(check("Translation", "batch-prepare-not-installed", timeout: 60) {
            let s = TranslationSession(installedSource: Locale.Language(identifier: "en"), target: Locale.Language(identifier: "de"))
            var batch = "translated"
            do {
                let rs = try await s.translations(from: [.init(sourceText: "Good morning", clientIdentifier: "1"), .init(sourceText: "Good night", clientIdentifier: "2")])
                batch = "translated \(rs.map { "\($0.clientIdentifier ?? "?")=\($0.targetText)" })"
            } catch { batch = "error \(String(describing: error).prefix(100))" }
            var prep = "prepared"
            do { try await s.prepareTranslation() } catch { prep = "error \(String(describing: error).prefix(100))" }
            // Apple's simulator: both refused, unsupportedLanguagePairing (no installed languages)
            let want = "error TranslationError(cause: Translation.TranslationError.Cause.unsupportedLanguagePairing"
            try expect(batch.hasPrefix(want) && prep.hasPrefix(want), "batch \(batch); prepare \(prep) (Apple's simulator: unsupportedLanguagePairing)")
            return "batch: \(batch); prepare: \(prep)"
        })
        #endif

        // MARK: Charts: a Chart3D of points (visionOS) rendered by ImageRenderer
        #if canImport(Charts) && os(visionOS)
        c.append(check("Charts", "chart3d-points-render", timeout: 40) {
            struct V: View {
                var body: some View {
                    Chart3D { ForEach(0..<8, id: \.self) { i in PointMark(x: .value("x", Double(i % 2)), y: .value("y", Double(i / 2 % 2)), z: .value("z", Double(i / 4))) } }
                        .frame(width: 200, height: 200)
                }
            }
            let img = await onMain { () -> CGImage? in let r = ImageRenderer(content: V()); r.scale = 1; return r.cgImage }
            guard let img else { return "ImageRenderer gave no image" }
            let ctx = bitmap(img.width, img.height); ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
            var ink = 0
            for y in stride(from: 0, to: img.height, by: 2) { for x in stride(from: 0, to: img.width, by: 2) where pixel(ctx, x, y)[3] > 0 { ink += 1 } }
            // Apple's visionOS simulator: every sample inked
            try expect(img.width == 200 && img.height == 200 && ink == 10000, "\(img.width)x\(img.height), \(ink) inked (Apple's simulator: 200x200, 10000)")
            return "\(img.width)x\(img.height), \(ink) inked samples"
        })
        #endif

        // MARK: NetworkExtension: a hotspot configuration applied (visionOS)
        #if canImport(NetworkExtension) && os(visionOS)
        c.append(check("NetworkExtension", "hotspot-configuration-apply", timeout: 30) {
            let r = P8Box<String>()
            let conf = NEHotspotConfiguration(ssid: "sdkcov", passphrase: "sdkcov-pass", isWEP: false)
            conf.joinOnce = true
            NEHotspotConfigurationManager.shared.apply(conf) { e in r.set(e.map { "error \(($0 as NSError).domain) \(($0 as NSError).code)" } ?? "applied") }
            guard let res = await r.wait(20) else { throw Fail("apply never answered in 20 s") }
            let ssids = P8Box<[String]>()
            NEHotspotConfigurationManager.shared.getConfiguredSSIDs { ssids.set($0) }
            let list = await ssids.wait(10)
            // Apple's visionOS simulator: NEHotspotConfigurationErrorDomain 8 (internal), nothing configured
            try expect(res == "error NEHotspotConfigurationErrorDomain 8" && list == [], "apply \(res), configured \(String(describing: list)) (Apple's simulator: error 8, [])")
            return "apply: \(res); configured \(list.map { "\($0)" } ?? "no answer")"
        })
        #endif

        // MARK: SafariServices: adding to the Reading List on visionOS
        #if canImport(SafariServices) && os(visionOS)
        c.append(check("SafariServices", "reading-list-add-xros", timeout: 20) {
            let u = URL(string: "https://example.com/sdkcov")!
            let ok = SSReadingList.supportsURL(u), bad = SSReadingList.supportsURL(URL(string: "file:///tmp/x")!)
            try expect(ok && !bad, "supportsURL https \(ok) file \(bad)")
            guard let rl = SSReadingList.default() else { return "no default reading list (supports https \(ok))" }
            var res = "added"
            do { try rl.addItem(with: u, title: "SDKCov", previewText: "sdkcov") } catch { res = "error \((error as NSError).domain) \((error as NSError).code)" }
            try expect(res == "added", "addItem \(res) (Apple's visionOS simulator: added)")
            return "supports https \(ok), file \(bad); addItem \(res)"
        })
        #endif

        // MARK: SwiftUI: a DatePicker on watchOS, drawn by ImageRenderer
        #if os(watchOS)
        c.append(check("SwiftUI", "watch-date-picker-render", timeout: 30) {
            struct V: View {
                @State var d = Date(timeIntervalSince1970: 1_700_000_000)
                var body: some View { DatePicker("When", selection: $d, displayedComponents: .date).frame(width: 180, height: 60).background(Color.white) }
            }
            let img = await onMain { () -> CGImage? in let r = ImageRenderer(content: V()); r.scale = 1; return r.cgImage }
            guard let img else { throw Fail("ImageRenderer gave no image") }
            let ctx = bitmap(img.width, img.height); ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
            var dark = 0
            for y in 0..<img.height { for x in 0..<img.width { let p = pixel(ctx, x, y); if p[3] > 128 && Int(p[0]) + Int(p[1]) + Int(p[2]) < 600 { dark += 1 } } }
            // Apple's watchOS simulator: 180x60, 639 non-white pixels (the label and the date)
            try expect(img.width == 180 && img.height == 60 && (450...850).contains(dark), "\(img.width)x\(img.height), \(dark) non-white (Apple's simulator: 180x60, 639)")
            return "\(img.width)x\(img.height), \(dark) non-white pixels"
        })
        #endif
        // MARK: SwiftUI on tvOS: Menu, a menu-style Picker, a contextMenu and a toolbar item: their UIKit counterparts
        #if os(tvOS)
        c.append(check("SwiftUI", "tv-menu-picker-toolbar", timeout: 40) {
            let m = await onMain { P19MenuModel() }
            let close = try await onMain { try p6HostSwiftUI(P19TVMenuRoot(m: m)) }
            defer { Task { @MainActor in close() } }
            try await Task.sleep(for: .milliseconds(800))
            guard let w = await onMain({ p6LastWindow }) else { throw Fail("no window") }
            let info = await onMain { () -> String in
                let bars = p6Find(w, UINavigationBar.self).compactMap { $0.topItem }.map { "title \($0.title ?? "nil") right \($0.rightBarButtonItems?.count ?? 0)" }
                let menus = p6Find(w, UIButton.self).filter { $0.menu != nil }.map { "\($0.menu!.children.count) items\($0.showsMenuAsPrimaryAction ? " primary" : "")" }
                let ctx = p6Find(w, UIView.self).filter { $0.interactions.contains { $0 is UIContextMenuInteraction } }.count
                let labels = p6Find(w, UILabel.self).compactMap(\.text).filter { $0.hasPrefix("SDKCov") }
                return "bars \(bars), menu buttons \(menus), context menu views \(ctx), labels \(labels)"
            }
            // Apple's tvOS simulator: the toolbar item as the bar's right item; Menu, Picker and the contextMenu Text each
            // carry a UIContextMenuInteraction (no UIButton menus)
            try expect(info.hasPrefix("bars [\"title SDKCov right 1\"], menu buttons [], context menu views 3"), "\(info) (Apple's simulator: bars [title SDKCov right 1], menu buttons [], context menu views 3)")
            return info
        })
        #endif

        // MARK: AVFAudio: route-change / interruption notifications around a category change and activation
        #if canImport(AVFoundation)
        c.append(check("AVFAudio", "session-route-change-notifications", timeout: 40) {
            let s = AVAudioSession.sharedInstance(), log = P6Log()
            let o1 = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { n in
                log.add("route \((n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) ?? 99)") }
            let o2 = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { n in
                log.add("interruption \((n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) ?? 99)") }
            defer { NotificationCenter.default.removeObserver(o1); NotificationCenter.default.removeObserver(o2) }
            var steps: [String] = []
            func step(_ name: String, _ f: () throws -> Void) { do { try f(); steps.append(name) } catch { steps.append("\(name): \(p8Err(error))") } }
            #if os(iOS) || os(visionOS)
            step("playAndRecord") { try s.setCategory(.playAndRecord) }
            #else
            step("playback") { try s.setCategory(.playback) }
            #endif
            step("active") { try s.setActive(true) }
            try await Task.sleep(for: .seconds(1))
            #if os(iOS)
            step("speaker") { try s.overrideOutputAudioPort(.speaker) }
            try await Task.sleep(for: .seconds(1))
            step("no override") { try s.overrideOutputAudioPort(.none) }
            #endif
            try await Task.sleep(for: .seconds(1))
            let outs = s.currentRoute.outputs.map(\.portType.rawValue)
            step("inactive") { try s.setActive(false, options: .notifyOthersOnDeactivation) }
            step("soloAmbient") { try s.setCategory(.soloAmbient) }
            try await Task.sleep(for: .seconds(1))
            // Apple's simulator (all four): every step accepted, no route-change or interruption notification, the
            // output route the speaker
            try expect(!steps.contains { $0.contains(":") } && log.all.isEmpty && outs == ["Speaker"], "steps \(steps), events \(log.all), outputs \(outs) (Apple's simulator: all accepted, no events, [Speaker])")
            return "steps \(steps), events \(log.all), outputs \(outs)"
        })
        #endif

        // MARK: LinkPresentation: a loopback page whose Open Graph tags name a video
        #if canImport(LinkPresentation) && canImport(Network)
        c.append(check("LinkPresentation", "loopback-og-video", timeout: 120) {
            #if os(watchOS)   // no AVAssetWriter: an mp4's leading ftyp box and filler
            let mov = Data([0, 0, 0, 24] + Array("ftypisom".utf8) + [0, 0, 2, 0] + Array("isommp41".utf8)) + Data(count: 4096)
            #else
            let mu = FileManager.default.temporaryDirectory.appendingPathComponent("sdkcov-p19-og.mp4")
            try await p1Movie(mu, frames: 30, size: 64, type: .mp4)
            let mov = try Data(contentsOf: mu); try? FileManager.default.removeItem(at: mu)
            #endif
            let srv = try More2HTTP { r in
                switch r.path {
                case "/vpage": return .text("""
                    <!doctype html><html><head><title>Fallback</title>
                    <meta property="og:title" content="SDKCov Video"><meta property="og:type" content="video.other">
                    <meta property="og:video" content="/v.mp4"><meta property="og:video:type" content="video/mp4">
                    <meta property="og:video:width" content="64"><meta property="og:video:height" content="64">
                    </head><body>video</body></html>
                    """, type: "text/html; charset=utf-8")
                case "/v.mp4": return More2Resp("200 OK", [("Content-Type", "video/mp4")], mov)
                default: return More2Resp("404 Not Found")
                }
            }
            _ = try await srv.start(); defer { srv.stop() }
            let box = P8Box<Result<LPLinkMetadata, Error>>()
            let p = await onMain { () -> LPMetadataProvider in let p = LPMetadataProvider(); p.timeout = 30; return p }
            await onMain { p.startFetchingMetadata(for: srv.url("/vpage")) { md, e in box.set(md.map { .success($0) } ?? .failure(e ?? Fail("no metadata"))) } }
            guard let r = await box.wait(45) else { await onMain { p.cancel() }; throw Fail("LPMetadataProvider never called back in 45 s") }
            let md = try r.get()
            var video = "no video provider"
            if let vp = md.videoProvider {
                let d: Data? = try? await withCheckedThrowingContinuation { k in
                    _ = vp.loadDataRepresentation(for: .movie) { d, e in if let d { k.resume(returning: d) } else { k.resume(throwing: e ?? Fail("no data")) } }
                }
                video = "video provider \(d?.count ?? -1) B (served \(mov.count) B)"
            }
            let reqs = srv.requests.withLock { $0 }
            // Apple's simulator (all four): the page's title, but no remote video URL and no video provider for og:video
            try expect(md.title == "SDKCov Video" && md.remoteVideoURL == nil && md.videoProvider == nil, "title \(md.title ?? "nil"), remote video \(md.remoteVideoURL?.path ?? "nil"), \(video) (Apple's simulator: title, no video)")
            return "title \(md.title ?? "nil"), remote video \(md.remoteVideoURL?.path ?? "nil"), \(video), requests \(reqs)"
        })
        #endif

        // MARK: LiveCommunicationKit: an incoming conversation reported
        #if canImport(LiveCommunicationKit) && !os(tvOS)
        c.append(check("LiveCommunicationKit", "report-incoming-conversation", timeout: 40) {
            let cfg = ConversationManager.Configuration(ringtoneName: nil, iconTemplateImageData: nil, maximumConversationGroups: 1, maximumConversationsPerConversationGroup: 1,
                                                        includesConversationInRecents: false, supportsVideo: false, supportedHandleTypes: [.generic])
            let m = ConversationManager(configuration: cfg), d = P19ConversationDelegate()
            m.delegate = d
            defer { m.invalidate() }
            let id = UUID()
            var r = "reported"
            do { try await m.reportNewIncomingConversation(uuid: id, update: Conversation.Update(members: [Handle(type: .generic, value: "sdkcov", displayName: "SDKCov")])) }
            catch { r = "error \(p8Err(error)) \(error)".prefix(160).description }
            try await Task.sleep(for: .seconds(2))
            let convs = m.conversations.map { "\($0.uuid == id ? "this" : "other") \($0.state)" }
            #if os(iOS)
            // Apple's iOS simulator: reported, the conversation idle, the system ends it at once (EndConversationAction)
            try expect(r == "reported" && convs == ["this idle"] && d.log.all.contains("perform EndConversationAction"), "report \(r), conversations \(convs), delegate \(d.log.all) (Apple's simulator: reported, [this idle], EndConversationAction)")
            #else
            // Apple's watchOS / visionOS simulators: CallKit error 0, no conversation
            try expect(r.hasPrefix("error com.apple.CallKit.error 0") && convs.isEmpty, "report \(r), conversations \(convs) (Apple's simulator: CallKit error 0, none)")
            #endif
            return "report: \(r); conversations \(convs); delegate \(d.log.all)"
        })
        #endif

        // MARK: Photos: a live photo from a still + movie pair that does not belong together
        #if canImport(Photos) && !os(watchOS)
        c.append(check("Photos", "live-photo-request-unpaired", timeout: 90) {
            let dir = FileManager.default.temporaryDirectory
            let ju = dir.appendingPathComponent("sdkcov-p19-live.jpg"), mu = dir.appendingPathComponent("sdkcov-p19-live.mov")
            let ctx = bitmap(64, 64); ctx.setFillColor(p6CGRed); ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            try encode(ctx.makeImage()!, .jpeg).write(to: ju)
            try await p1Movie(mu, frames: 30, size: 64)
            defer { try? FileManager.default.removeItem(at: ju); try? FileManager.default.removeItem(at: mu) }
            let log = P6Log()
            let req = PHLivePhoto.request(withResourceFileURLs: [ju, mu], placeholderImage: nil, targetSize: .zero, contentMode: .aspectFit) { lp, info in
                let deg = (info[PHLivePhotoInfoIsDegradedKey] as? Bool) == true
                let err = (info[PHLivePhotoInfoErrorKey] as? Error).map { p8Err($0) } ?? "none"
                log.add("\(lp == nil ? "nil" : "live photo")\(deg ? " degraded" : "") error \(err)")
            }
            _ = await p6Wait(15) { log.all.contains { !$0.contains("degraded") } }
            try await Task.sleep(for: .milliseconds(500))
            // Apple's simulator: a degraded live photo first, then nil without an error (the pair does not belong together)
            try expect(log.all == ["live photo degraded error none", "nil error none"], "callbacks \(log.all) (Apple's simulator: degraded live photo, then nil)")
            return "request \(req), callbacks \(log.all)"
        })
        #endif

        // MARK: EventKitUI: an event edit sheet cancelled through the edit view delegate
        #if canImport(EventKitUI) && (os(iOS) || os(visionOS))
        c.append(check("EventKitUI", "event-edit-cancel-delegate", timeout: 90) {
            let d = P19EventEditDelegate()
            let store = EKEventStore()
            let (root, close) = try await onMain { () -> (UIViewController, () -> Void) in
                let vc = UIViewController(); vc.view.backgroundColor = .white
                let (_, close) = try p6Show(vc); return (vc, close)
            }
            defer { Task { @MainActor in close() } }
            let vc = await onMain { () -> EKEventEditViewController in
                let ev = EKEvent(eventStore: store); ev.title = "SDKCov edit"; ev.startDate = Date(timeIntervalSince1970: 1_900_000_000); ev.endDate = ev.startDate.addingTimeInterval(3600)
                let v = EKEventEditViewController(); v.eventStore = store; v.event = ev; v.editViewDelegate = d
                root.present(v, animated: false); return v
            }
            let shown = await p6Wait(10) { root.presentedViewController === vc && vc.viewIfLoaded?.window != nil }
            // the editor is out of process (EKEventEditViewControllerOOPImpl): cancel until its delegate answers (Apple's
            // simulator: its view service comes up slowly on a fresh device)
            for _ in 0..<15 where d.log.all.isEmpty {
                await onMain { vc.cancelEditing() }
                _ = await p6Wait(2) { !d.log.all.isEmpty }
            }
            let gone = await p6Wait(5) { root.presentedViewController == nil }
            let kids = await onMain { (vc.children.map { "\(type(of: $0))" }, vc.topViewController.map { "\(type(of: $0)) \($0.children.map { "\(type(of: $0))" })" } ?? "nil") }
            // Apple's simulator (iOS, visionOS): the out-of-process editor cancels, the delegate hears .canceled (0)
            try expect(shown && d.log.all.first == "complete 0" && gone, "shown \(shown), delegate \(d.log.all), dismissed \(gone), children \(kids) (Apple's simulator: complete 0, dismissed)")
            return "shown \(shown), delegate \(d.log.all), dismissed \(gone), children \(kids)"
        })
        #endif

        // MARK: ContactsUI: the new-contact view controller cancelled through its bar button
        #if canImport(ContactsUI) && (os(iOS) || os(visionOS))
        c.append(check("ContactsUI", "new-contact-cancel-delegate", timeout: 90) {
            let d = P19ContactDelegate()
            let (root, close) = try await onMain { () -> (UIViewController, () -> Void) in
                let vc = UIViewController(); vc.view.backgroundColor = .white
                let (_, close) = try p6Show(vc); return (vc, close)
            }
            defer { Task { @MainActor in close() } }
            let vc = await onMain { () -> CNContactViewController in
                let v = CNContactViewController(forNewContact: nil); v.delegate = d
                root.present(UINavigationController(rootViewController: v), animated: false); return v
            }
            let shown = await p6Wait(10) { vc.viewIfLoaded?.window != nil }
            // the bar items come from the out-of-process contact view (CNContactViewHostViewController): Apple's simulator
            // brings its view service up slowly on a fresh device
            _ = await p6Wait(40) { vc.navigationItem.leftBarButtonItem != nil }
            let items = await onMain { () -> String in
                let l = vc.navigationItem.leftBarButtonItems ?? [], r = vc.navigationItem.rightBarButtonItems ?? []
                return "left \(l.map { $0.title ?? "\($0.action.map { NSStringFromSelector($0) } ?? "nil")" }) right \(r.map { $0.title ?? "\($0.action.map { NSStringFromSelector($0) } ?? "nil")" })"
            }
            let sent = await onMain { () -> Bool in
                guard let it = vc.navigationItem.leftBarButtonItem, let a = it.action else { return false }
                return UIApplication.shared.sendAction(a, to: it.target, from: it, for: nil)
            }
            _ = await p6Wait(8) { !d.log.all.isEmpty }
            await onMain { root.dismiss(animated: false) }
            let kids = await onMain { vc.children.map { "\(type(of: $0))" } }
            // Apple's simulator (iOS, visionOS): Cancel (editCancel:) / Done from the contact view service; Cancel completes
            // with no contact
            try expect(shown && sent && d.log.all == ["complete nil"], "shown \(shown), items \(items), cancel sent \(sent), delegate \(d.log.all) (Apple's simulator: complete nil)")
            return "shown \(shown), items \(items), cancel sent \(sent), delegate \(d.log.all), children \(kids)"
        })
        #endif

        // MARK: CoreLocation: location updates, significant-change and visit monitoring started and stopped
        #if canImport(CoreLocation) && os(iOS)
        c.append(check("CoreLocation", "updates-significant-change-visits", timeout: 40) {
            let d = P19LocationDelegate()
            let m = await onMain { () -> CLLocationManager in let m = CLLocationManager(); m.delegate = d; m.desiredAccuracy = kCLLocationAccuracyBest; m.startUpdatingLocation(); return m }
            _ = await p6Wait(15) { d.log.all.contains { $0.hasPrefix("loc") } }
            await onMain { m.stopUpdatingLocation() }
            let updates = d.log.all
            let sig = CLLocationManager.significantLocationChangeMonitoringAvailable()
            await onMain { m.startMonitoringSignificantLocationChanges() }
            try await Task.sleep(for: .seconds(3))
            await onMain { m.stopMonitoringSignificantLocationChanges(); m.startMonitoringVisits() }
            try await Task.sleep(for: .seconds(2))
            await onMain { m.stopMonitoringVisits() }
            let later = Array(d.log.all.dropFirst(updates.count))
            // Apple's simulator: the simulated location (Apple Park), significant-change monitoring available, nothing
            // more while monitoring changes and visits
            try expect(updates.first == "loc 37.3349,-122.0090" && sig && later.isEmpty, "updates \(updates), significant \(sig), after \(later) (Apple's simulator: Apple Park, true, none)")
            return "updates \(updates.prefix(3)) (\(updates.count)), significant-change available \(sig), after: \(later.prefix(5)) (\(later.count))"
        })
        #endif

        // MARK: UserNotifications: notification content updated from a message intent (communication notifications)
        #if canImport(Intents) && canImport(UserNotifications) && !os(tvOS)
        c.append(check("UserNotifications", "communication-content-from-intent") {
            let sender = INPerson(personHandle: INPersonHandle(value: "ada@example.com", type: .emailAddress), nameComponents: nil, displayName: "Ada", image: nil, contactIdentifier: nil, customIdentifier: "ada")
            let intent = INSendMessageIntent(recipients: nil, outgoingMessageType: .outgoingMessageText, content: "hi", speakableGroupName: nil,
                                             conversationIdentifier: "sdkcov-conv", serviceName: nil, sender: sender, attachments: nil)
            let content = UNMutableNotificationContent(); content.title = "orig"; content.body = "hi"
            do {
                let up = try content.updating(from: intent)
                let r = "updated: title '\(up.title)' subtitle '\(up.subtitle)' body '\(up.body)' thread '\(up.threadIdentifier)' \(type(of: up))"
                // Apple's simulator (iOS, watchOS, visionOS): the content comes back as it was (no communication notification
                // capability in the app)
                try expect(r == "updated: title 'orig' subtitle '' body 'hi' thread '' UNMutableNotificationContent", "\(r) (Apple's simulator: unchanged)")
                return r
            } catch { throw Fail("error \(p8Err(error)) (Apple's simulator: updated)") }
        })
        #endif

        // MARK: AuthenticationServices: the credential provider (AutoFill extension) side objects in the app
        #if canImport(AuthenticationServices) && os(visionOS)   // iOS: Apple's simulator never answers the identity store's state (hung 90 s)
        c.append(check("AuthenticationServices", "credential-provider-objects", timeout: 30) {
            let vcInfo = await onMain { () -> String in
                let vc = ASCredentialProviderViewController(); vc.loadViewIfNeeded()
                return "provider vc context \(type(of: vc.extensionContext as AnyObject?))"
            }
            let id = ASPasswordCredentialIdentity(serviceIdentifier: ASCredentialServiceIdentifier(identifier: "example.com", type: .domain), user: "ada", recordIdentifier: "sdkcov-1")
            let st = await ASCredentialIdentityStore.shared.state()
            var save = "saved"
            do { try await ASCredentialIdentityStore.shared.saveCredentialIdentities([id]) } catch { save = "error \(p8Err(error))" }
            let cred = ASPasswordCredential(user: "ada", password: "pw")
            // Apple's simulator (iOS, visionOS): no AutoFill provider enabled, saving refused with error 0
            try expect(!st.isEnabled && !st.supportsIncrementalUpdates && save == "error ASCredentialIdentityStoreErrorDomain 0", "enabled \(st.isEnabled), save \(save) (Apple's simulator: false, error 0)")
            return "\(vcInfo); store enabled \(st.isEnabled) incremental \(st.supportsIncrementalUpdates); save \(save); credential \(cred.user)"
        })
        #endif

        // MARK: UIKit on tvOS: a UIMenu tree, a button's primary action, UITextInput on a text field
        #if os(tvOS)
        c.append(check("UIKit", "tv-menu-tree-text-input", timeout: 30) {
            try await p6A { () async throws -> String in
                var fired: [String] = []
                let a1 = UIAction(title: "Bold", state: .on) { _ in fired.append("bold") }
                let a2 = UIAction(title: "Delete", attributes: .destructive) { _ in fired.append("delete") }
                let m = UIMenu(title: "Format", children: [a1, UIMenu(title: "", options: .displayInline, children: [a2])])
                let m2 = m.replacingChildren([a2])
                let b = UIButton(type: .system); b.addAction(UIAction(title: "Go") { _ in fired.append("go") }, for: .primaryActionTriggered)
                b.sendActions(for: .primaryActionTriggered)
                let mb = UIButton(type: .system); mb.menu = m; mb.showsMenuAsPrimaryAction = true
                try expect(m.children.count == 2 && m2.children.count == 1 && fired == ["go"] && mb.menu?.title == "Format", "menu tree / primary action \(fired)")
                let vc = UIViewController()
                let tf = UITextField(frame: CGRect(x: 100, y: 100, width: 600, height: 60)); tf.text = "hello world"; vc.view.addSubview(tf)
                let (_, close) = try p6Show(vc); defer { close() }
                guard let st = tf.position(from: tf.beginningOfDocument, offset: 6), let en = tf.position(from: st, offset: 5), let r = tf.textRange(from: st, to: en) else { throw Fail("positions") }
                let word = tf.text(in: r)
                tf.replace(r, withText: "x86sim")
                let caret0 = tf.caretRect(for: tf.beginningOfDocument), caret6 = tf.caretRect(for: tf.position(from: tf.beginningOfDocument, offset: 6)!)
                // Apple's tvOS simulator: world, replaced, the caret moves right (0 -> 87)
                try expect(word == "world" && tf.text == "hello x86sim" && caret6.minX > caret0.minX + 40, "text(in:) \(word ?? "nil"), text \(tf.text ?? ""), carets \(caret0.minX) \(caret6.minX)")
                return "menu tree + primary action; text(in:) \(word ?? "nil"), replaced -> '\(tf.text ?? "")', caret 0 x \(Int(caret0.minX)) 6 x \(Int(caret6.minX)), secure \(tf.isSecureTextEntry)"
            }
        })
        #endif

        // MARK: QuickLook: the app's own document type previewed by its Quick Look preview extension
        #if canImport(QuickLook) && (os(iOS) || os(visionOS))
        c.append(check("QuickLook", "preview-extension-own-type", timeout: 60) {
            let u = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("sample.sdkcovql")
            try Data("sdkcov ql sample".utf8).write(to: u)
            let t0 = Date()
            let can = QLPreviewController.canPreview(u as NSURL)
            // the app's exported type as Launch Services resolves it
            let ut = UTType(filenameExtension: "sdkcovql").map { "\($0.identifier) declared \($0.isDeclared) dynamic \($0.isDynamic)" } ?? "nil"
            let rv = (try? u.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.identifier ?? "nil"
            let (q, src, close) = try await onMain { try p19PresentQL([u]) }
            defer { Task { @MainActor in close() } }
            _ = await p6Wait(30) { !p3Marks("qlpreview-prepare", since: t0).isEmpty }
            try await Task.sleep(for: .milliseconds(500))
            let prep = p3Marks("qlpreview-prepare", since: t0), load = p3Marks("qlpreview-load", since: t0)
            let shown = await onMain { q.viewIfLoaded?.window != nil }
            // Apple's simulator (iOS, visionOS): the type is the app's declared one, the preview controller shows, but no
            // third-party preview extension runs in 30 s (canPreview varies from run to run there: not asserted)
            try expect(ut.hasPrefix("com.x86sim.test.sdkcov.qlsample declared true") && shown && prep.isEmpty && src.log.all == ["editingMode sdkcovql"],
                "type \(ut), shown \(shown), extension prepare \(prep), delegate \(src.log.all) (Apple's simulator: declared, shown, no extension run, editingMode once)")
            return "type \(ut) (url \(rv)), canPreview \(can), shown \(shown), extension: load \(load.count) prepare \(prep), delegate \(src.log.all)"
        })
        // MARK: QuickLook: the editing mode a QLPreviewController asks its delegate for (an image: markup as a copy)
        c.append(check("QuickLook", "preview-editing-mode", timeout: 40) {
            let u = FileManager.default.temporaryDirectory.appendingPathComponent("sdkcov-p19-edit.png")
            let ctx = bitmap(80, 60); ctx.setFillColor(p6CGBlue); ctx.fill(CGRect(x: 0, y: 0, width: 80, height: 60))
            try encode(ctx.makeImage()!, .png).write(to: u)
            let (q, src, close) = try await onMain { try p19PresentQL([u]) }
            defer { Task { @MainActor in close() } }
            _ = await p6Wait(15) { !src.log.all.isEmpty }
            try await Task.sleep(for: .seconds(1))
            @MainActor func barItems() -> [String] {
                func bars(_ v: UIView) -> [UINavigationBar] { ((v as? UINavigationBar).map { [$0] } ?? []) + v.subviews.flatMap(bars) }
                guard let w = q.view.window else { return ["no window"] }
                return bars(w).flatMap { b in (b.topItem?.rightBarButtonItems ?? []) + (b.topItem?.leftBarButtonItems ?? []) }.map { $0.accessibilityLabel ?? $0.title ?? $0.image?.description.prefix(30).description ?? "item" }
            }
            // the preview's UI comes from Quick Look's view service (QLRemoteUIHostViewController, its own bars); until it
            // connects a local placeholder shows the bar items (Apple's fresh simulator: still the placeholder at 1 s)
            let remote = await p6Wait(30) { (q.children.first as? UINavigationController)?.topViewController.map { "\(type(of: $0))" } == "QLRemoteUIHostViewController" }
            let items = await onMain { barItems() }
            let diag = await onMain { () -> String in
                func all<T>(_ v: UIView, _ t: T.Type) -> [T] { ((v as? T).map { [$0] } ?? []) + v.subviews.flatMap { all($0, t) } }
                guard let w = q.view.window else { return "no window" }
                let nb = all(w, UINavigationBar.self).map { "bar[\($0.items?.count ?? 0) items, top \($0.topItem?.title ?? "nil") L\($0.topItem?.leftBarButtonItems?.count ?? 0) R\($0.topItem?.rightBarButtonItems?.count ?? 0) hidden \($0.isHidden)]" }
                let tb = all(w, UIToolbar.self).map { "toolbar[\($0.items?.count ?? 0) hidden \($0.isHidden)]" }
                let qi = "q.navItem L\(q.navigationItem.leftBarButtonItems?.count ?? 0) R\(q.navigationItem.rightBarButtonItems?.count ?? 0) toolbarItems \(q.toolbarItems?.count ?? 0) nav \(q.navigationController.map { "\(type(of: $0))" } ?? "nil") children \(q.children.map { "\(type(of: $0))" })"
                let nc = (q.children.first as? UINavigationController).map { n in "nc hidden \(n.isNavigationBarHidden) bar in window \(n.navigationBar.window != nil) super \(n.navigationBar.superview.map { "\(type(of: $0))" } ?? "nil") top \(n.topViewController.map { "\(type(of: $0)) L\($0.navigationItem.leftBarButtonItems?.count ?? 0) R\($0.navigationItem.rightBarButtonItems?.count ?? 0)" } ?? "nil") vcs \(n.viewControllers.count)" } ?? "no nc"
                return "\(nb) \(tb) \(qi) \(nc)"
            }
            let asks = src.log.all
            // Apple's simulator: asked for the image's editing mode (iOS 3 bar items, visionOS none) once; x86Sim's visionOS
            // asked it 19 times in a second in r23, once in every r25 run: counted, not asserted
            try expect(Set(asks) == ["editingMode png"], "delegate \(asks) (Apple's simulator: editingMode png)")
            #if os(iOS)
            try expect(remote, "no Quick Look view service in 30 s: \(diag)")
            #endif
            return "\(diag); delegate asked \(Set(asks).sorted()) \(asks.count == 1 ? "once" : "\(asks.count) times"), bar items \(items.count)"
        })
        #endif
        return c
    }
}
