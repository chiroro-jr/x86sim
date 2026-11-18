// SDK coverage, round 23: checks for [a] gaps of covered frameworks (COVERAGE-GAPS.md). Each asserts what Apple's
// simulator answers (ref-mac.sh).
import Foundation
import SwiftUI
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
        return c
    }
}
