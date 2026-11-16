// sdkcov P9: the simulator's answer, asserted. Frameworks whose main API cannot work in Apple's simulator (no
// entitlement, no service, no extension point, no model) and value types whose checks only reported: each check here
// asserts the exact answer Apple's 27.2 simulators give (ref-mac.sh), so x86Sim has to give the same one.
import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(RelevanceKit)
import RelevanceKit
#endif
#if canImport(FoundationModels) && os(watchOS)
import FoundationModels
#endif
#if canImport(SensitiveContentAnalysis) && (os(iOS) || os(visionOS))
import SensitiveContentAnalysis
import AVFoundation
#endif
#if canImport(BrowserKit) && os(iOS)
import BrowserKit
#endif
#if canImport(BrowserEngineKit) && (os(tvOS) || os(visionOS))
import BrowserEngineKit
#endif
#if canImport(ExtensionFoundation) && !os(iOS)
import ExtensionFoundation
#endif
#if canImport(ExtensionKit) && !os(iOS)
import ExtensionKit
#endif

#if os(iOS)
/// func:AccessorySetupKit.session-activate's session: kept for the app's life (invalidating it kills the app in Apple's
/// simulator, More_iOS.swift)
nonisolated(unsafe) var moreIOSASKSession: AnyObject?
#endif

/// a value set once from any thread, awaited with a deadline
final class P9Box<T>: @unchecked Sendable {
    private let lock = NSLock(); private var v: T?
    func set(_ x: T) { lock.withLock { if v == nil { v = x } } }
    var value: T? { lock.withLock { v } }
    func wait(_ secs: Double) async -> T? {
        let end = Date().addingTimeInterval(secs)
        while Date() < end { if let x = value { return x }; try? await Task.sleep(for: .milliseconds(50)) }
        return value
    }
}
func p9Err(_ e: Error) -> String { let n = e as NSError; return "\(n.domain) \(n.code)" }

extension Registry {
    static var p9: [Check] { p9_answers + p9_ports }

    static var p9_answers: [Check] {
        var c: [Check] = []

        // MARK: RelevanceKit: what a context says it is (RelevantContext is neither Equatable nor Codable)
        #if canImport(RelevanceKit)
        c.append(check("RelevanceKit", "context-descriptions") {
            let t = Date(timeIntervalSince1970: 1_800_000_000)   // 2027-01-15 08:00:00 UTC
            var cs: [(String, RelevantContext)] = [("date", .date(t)), ("range", .date(from: t, to: t.addingTimeInterval(3600)))]
            #if !os(tvOS)
            cs += [("interval", .date(interval: DateInterval(start: t, duration: 60), kind: .scheduled)),
                   ("home", .location(inferred: .home)), ("headphones", .hardware(headphones: .connected))]
            #endif
            #if os(watchOS)
            cs += [("bedtime", .sleep(.bedtime)), ("workout", .fitness(.workoutActive))]
            #endif
            let ds = cs.map { ($0.0, String(describing: $0.1)) }
            // each wraps its RelevanceKit context object; the date ones carry the date
            try expect(ds.allSatisfy { $0.1.hasPrefix("RelevantContext(rkContext: <") }, "descriptions \(ds)")
            try expect(Set(ds.map(\.1)).count == ds.count, "two contexts describe alike: \(ds)")
            try expect(ds[0].1.contains("<date: 2027-01-15 08:00:00 +0000, priority: default>") && ds[1].1.contains("<date range: 2027-01-15 08:00:00 +0000 to 2027-01-15 09:00:00 +0000"),
                       "date contexts \(ds[0].1) / \(ds[1].1)")
            #if !os(tvOS)
            try expect(ds[2].1.contains("2027-01-15 08:00:00 +0000 to 2027-01-15 08:01:00 +0000") && ds[3].1.contains("<routine: .location(inferred: .home)") && ds[4].1.contains("<routine: .hardware(headphones: .connected)"),
                       "interval / routine contexts \(ds[2...4].map(\.1))")
            #endif
            return ds.map { "\($0.0): \($0.1.dropFirst("RelevantContext(rkContext: ".count).prefix(70))" }.joined(separator: "; ")
        })
        #endif

        // MARK: FoundationModels on watchOS: only Private Cloud Compute (no on-device model), not on a simulated watch
        #if canImport(FoundationModels) && os(watchOS)
        c.append(check("FoundationModels", "watch-pcc-session-refused", timeout: 60) {
            let pcc = PrivateCloudComputeLanguageModel()
            let s = LanguageModelSession(profile: LanguageModelSession.Profile { Instructions("Answer with one word.") }.model(pcc))
            let r = P9Box<String>()
            Task { do { let a = try await s.respond(to: "Reply with the single word: pong"); r.set("answered '\(a.content.prefix(40))'") } catch { r.set("error \(error as NSError)") } }
            let got = await r.wait(40) ?? "no answer in 40 s"
            // Apple's watchOS simulator: the device is not eligible for Private Cloud Compute, generation fails
            try expect(got.hasPrefix("error ") && got.contains("This device does not support Apple Intelligence."), "respond: \(got.prefix(300)) (availability \(pcc.availability); Apple's watchOS simulator: error 'This device does not support Apple Intelligence.')")
            return "availability \(pcc.availability); respond: \(got.prefix(400))"
        })
        #endif

        // MARK: SensitiveContentAnalysis: video analysis under the disabled policy
        #if canImport(SensitiveContentAnalysis) && (os(iOS) || os(visionOS))
        c.append(check("SensitiveContentAnalysis", "video-analysis-disabled-policy", timeout: 120) {
            let an = SCSensitivityAnalyzer()
            let url = p1Tmp("p9-sca.mov"); try await p1Movie(url, frames: 15)
            defer { try? FileManager.default.removeItem(at: url) }
            var file = "?"
            do { let a = try await an.videoAnalysis(forFileAt: url).hasSensitiveContent(); file = "isSensitive \(a.isSensitive)" } catch { file = "error \(p9Err(error))" }
            var stream = "n/a (visionOS)"
            #if os(iOS)
            do { let s = try SCVideoStreamAnalyzer(participantUUID: UUID().uuidString, streamDirection: .incoming); stream = "made, analysis \(String(describing: s.analysis))" } catch { stream = "error \(p9Err(error))" }
            #endif
            // Apple's simulator: no client entitlement, the policy is disabled; video analysis answers like analyzeImage
            try expect(an.analysisPolicy == .disabled && file == "error com.apple.SensitiveContentAnalysis 100", "policy \(an.analysisPolicy.rawValue), video file: \(file) (Apple's simulator: disabled, error 100)")
            #if os(iOS)
            // Apple's iOS simulator: the stream analyzer is refused with error 21
            try expect(stream == "error com.apple.SensitiveContentAnalysis 21", "stream analyzer: \(stream) (Apple's simulator: com.apple.SensitiveContentAnalysis 21)")
            #endif
            return "policy disabled, video file: \(file), stream analyzer: \(stream)"
        })
        #endif

        // MARK: BrowserKit (iOS): content filter and data import without the browser entitlement
        #if canImport(BrowserKit) && os(iOS)
        c.append(check("BrowserKit", "content-filter-import-answers", timeout: 40) {
            let f = BEBrowserContentFilter()
            let blocked = P9Box<Bool>()
            f.evaluateURL(URL(string: "https://example.com/sdkcov")!) { blocked.set($0) }
            let b = await blocked.wait(10)
            let imp = P9Box<String>()
            let im = BEBrowserDataImportManager()
            let meta = BEImportMetadata(supportForImportFromFiles: true)
            im.requestImport(for: meta) { o, e in imp.set(e.map { "error \(p9Err($0))" } ?? "options importFromFiles \(o?.importFromFiles ?? false)") }
            let i = await imp.wait(15) ?? "no answer in 15 s"
            // Apple's iOS simulator (no browser entitlement): the filter blocks nothing, the import request is refused
            // with BrowserDataExchangeError 2 (import)
            try expect(b == false && i == "error com.apple.BrowserKit.BrowserDataExchangeError 2", "filter \(String(describing: b)), import \(i) (Apple's simulator: block false, BrowserDataExchangeError 2)")
            return "content filter: \(b.map { "block \($0)" } ?? "no answer in 10 s"); import request: \(i)"
        })
        #endif

        // MARK: BrowserEngineKit on tvOS / visionOS: only the view / text-input objects (processes are iOS-only API)
        #if canImport(BrowserEngineKit) && (os(tvOS) || os(visionOS))
        c.append(check("BrowserEngineKit", "scroll-view-text-objects", timeout: 20) {
            try await onMain { () throws -> String in
                let sv = BEScrollView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
                sv.contentSize = CGSize(width: 100, height: 400)
                sv.contentOffset = CGPoint(x: 0, y: 150)
                try expect(sv.frame.size == CGSize(width: 100, height: 100) && sv.contentOffset.y == 150 && sv.contentSize.height == 400, "scroll view \(sv.frame) offset \(sv.contentOffset)")
                let sug = BETextSuggestion(inputText: "sdkcov")
                try expect(sug.inputText == "sdkcov", "suggestion \(sug.inputText)")
                return "BEScrollView offset \(sv.contentOffset.y) of \(sv.contentSize.height), suggestion '\(sug.inputText)'"
            }
        })
        #endif

        // MARK: BrowserEngineCore on visionOS: BEMemory only, C-only (unavailable in Swift): through dlsym
        #if os(visionOS)
        c.append(check("BrowserEngineCore", "bememory-symbols", timeout: 20) {
            guard let h = dlopen("/System/Library/Frameworks/BrowserEngineCore.framework/BrowserEngineCore", RTLD_NOW) else { throw Fail("dlopen: \(String(cString: dlerror()))") }
            let names = ["be_memory_inline_jit_restrict_rwx_to_rw_with_witness_impl", "be_memory_inline_jit_restrict_rwx_to_rx_with_witness_impl", "be_memory_inline_jit_restrict_with_witness_supported"]
            let missing = names.filter { dlsym(h, $0) == nil }
            try expect(missing.isEmpty, "missing \(missing)")
            typealias F = @convention(c) () -> Int32
            let sup = unsafeBitCast(dlsym(h, names[2])!, to: F.self)()
            // 1 on Apple silicon (Apple's simulator), 0 on an x86 host: a CPU feature, either is a valid answer
            try expect(sup == 0 || sup == 1, "witness supported \(sup)")
            return "BEMemory symbols present, JIT witness supported \(sup)"
        })
        #endif

        // MARK: ExtensionKit on tvOS / watchOS / visionOS: installd refuses app-defined extension points
        #if canImport(ExtensionKit) && !os(iOS)
        c.append(check("ExtensionKit", "app-defined-point-refused", timeout: 30) {
            // the iOS app's own point (com.x86sim.test.sdkcov.sdkcov-ext) is not installed here (installd: "does not
            // specify an Apple extension point", Apple's simulator too): the point does not resolve
            var e = "resolved"
            do { _ = try AppExtensionPoint(identifier: "com.x86sim.test.sdkcov.sdkcov-ext") } catch { e = "\(error)" }
            // Apple's simulators: NSOSStatusErrorDomain -10814 (kLSApplicationNotFoundErr: no such point registered)
            try expect(e.hasPrefix("Error Domain=NSOSStatusErrorDomain Code=-10814"), "app-defined extension point: \(e.prefix(160)) (Apple's simulator: NSOSStatusErrorDomain -10814)")
            // the extension side's scene configuration is still made from a scene
            let made = await onMain { () -> String in
                let scene = PrimitiveAppExtensionScene(id: "sdkcov") { Text("sdkcov") } onConnection: { _ in false }
                return "\(type(of: AppExtensionSceneConfiguration(scene)))"
            }
            try expect(made == "AppExtensionSceneConfiguration", "scene configuration \(made)")
            return "app-defined point: \(e.prefix(160))"
        })
        #endif
        return c
    }
}
