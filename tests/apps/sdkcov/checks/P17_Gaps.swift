// SDK coverage, round 21: checks for [a] gaps of covered frameworks (COVERAGE-GAPS.md) and probes. Each asserts what
// Apple's simulator answers (ref-mac.sh).
import Foundation
import Synchronization
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(CallKit) && os(iOS)
import CallKit
#endif
#if canImport(Messages) && os(iOS)
import Messages
#endif
#if canImport(Charts)
import Charts
#endif
#if canImport(WebKit) && (os(iOS) || os(visionOS))
import WebKit
#endif

#if canImport(WebKit) && (os(iOS) || os(visionOS))
/// WebPage's navigation decider: records each action's URL and response's MIME type, cancels sdkcov-blocked: URLs
@MainActor private final class P17Decider: WebPage.NavigationDeciding {
    var log: [String] = []
    func decidePolicy(for action: WebPage.NavigationAction, preferences: inout WebPage.NavigationPreferences) async -> WKNavigationActionPolicy {
        let u = action.request.url?.absoluteString ?? "nil"
        log.append("action \(u.hasPrefix("about:") ? "about" : u)")
        return u.hasPrefix("sdkcov-blocked:") ? .cancel : .allow
    }
    func decidePolicy(for response: WebPage.NavigationResponse) async -> WKNavigationResponsePolicy {
        log.append("response \(response.response.mimeType ?? "nil")")
        return .allow
    }
}
#endif

#if canImport(Charts) && canImport(UIKit) && !os(watchOS)
/// 100 bars over x 0..<100, red for 50..<60 and blue elsewhere, 10 of them visible, scrolled to x = 50 at the start;
/// no axes, no padding: the plot area is the whole frame
private struct P17ScrollChart: View {
    var scroll = true
    var body: some View {
        if scroll { chart.chartScrollableAxes(.horizontal).chartXVisibleDomain(length: 10).chartScrollPosition(initialX: 50.0) }
        else { chart }
    }
    var chart: some View {
        Chart {
            ForEach(0..<100) { i in
                RectangleMark(xStart: .value("x0", Double(i)), xEnd: .value("x1", Double(i + 1)), yStart: .value("y0", 0.0), yEnd: .value("y1", 1.0))
                    .foregroundStyle((50..<60).contains(i) ? Color(red: 1, green: 0, blue: 0) : Color(red: 0, green: 0, blue: 1))
            }
        }
        .chartXScale(domain: 0...100).chartYScale(domain: 0...1)
        .chartXAxis(.hidden).chartYAxis(.hidden).chartLegend(.hidden)
        .frame(width: 400, height: 200).background(Color.white)
    }
}
/// share of the image's pixels that are mostly red / mostly blue
private func p17RedBlue(_ img: CGImage) -> (Double, Double) {
    let w = img.width, h = img.height
    var px = [UInt8](repeating: 0, count: w * h * 4)
    guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return (0, 0) }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    var r = 0, b = 0
    for i in stride(from: 0, to: px.count, by: 4) {
        if px[i] > 200 && px[i + 1] < 60 && px[i + 2] < 60 { r += 1 }
        if px[i + 2] > 200 && px[i] < 60 && px[i + 1] < 60 { b += 1 }
    }
    return (Double(r) / Double(w * h), Double(b) / Double(w * h))
}
#endif

private var p17Wait: Double { Double(ProcessInfo.processInfo.environment["SDKCOV_INPUT_WAIT"] ?? "") ?? 0 }

extension Registry {
    static var p17: [Check] {
        var c: [Check] = []

        // MARK: UIKit: a second window of the app's scene, shown over the main one (p6Show, which the touch checks use);
        // with SDKCOV_INPUT_WAIT it stays up that long for the host's screenshots
        #if canImport(UIKit) && !os(watchOS)
        c.append(check("UIKit", "input-extra-window-shown", timeout: 120) {
            let wait = max(p17Wait, 1)
            let (w, hide) = try await MainActor.run { () throws -> (UIWindow, () -> Void) in
                let vc = UIViewController(); vc.view.backgroundColor = UIColor(red: 0, green: 0.8, blue: 0, alpha: 1)
                let l = UILabel(); l.text = "SDKCOV EXTRA WINDOW"; l.font = .boldSystemFont(ofSize: 60); l.sizeToFit()
                l.center = CGPoint(x: 400, y: 300); vc.view.addSubview(l)
                return try p6Show(vc)
            }
            try await Task.sleep(for: .seconds(wait))
            let (key, visible, state) = await MainActor.run { () -> (Bool, Bool, String) in
                let r = (w.isKeyWindow, !w.isHidden && w.windowScene != nil, "key \(w.isKeyWindow), level \(w.windowLevel.rawValue), frame \(w.frame); windows: \(p6Windows())")
                hide(); return r
            }
            // on screen over the app's window on both simulators (screenshots: Apple's visionOS 27.2 shows it as the
            // app's window, the main one behind it)
            try expect(key && visible, state)
            return "shown \(Int(wait)) s: \(state)"
        })
        #endif
        // MARK: Charts: a horizontally scrollable chart showing 10 of 100 x units, scrolled to x = 50 at the start
        #if canImport(Charts) && canImport(UIKit) && !os(watchOS)
        c.append(check("Charts", "scrollable-axes-initial-position", timeout: 30) {
            // in a window (scrolling needs a live scroll view), and as ImageRenderer draws it
            let close = try await onMain { try p6HostSwiftUI(P17ScrollChart()) }
            defer { Task { @MainActor in close() } }
            try await Task.sleep(for: .seconds(1))
            let snap = try await onMain { () throws -> CGImage? in
                guard let v = p6LastWindow?.rootViewController?.view else { throw Fail("no hosting view") }
                return p6Snap(v)
            }
            let rend = await onMain { () -> CGImage? in let r = ImageRenderer(content: P17ScrollChart()); r.scale = 1; return r.cgImage }
            let rr = rend.map(p17RedBlue) ?? (0, 0)
            let plain = await onMain { () -> CGImage? in let r = ImageRenderer(content: P17ScrollChart(scroll: false)); r.scale = 1; return r.cgImage }
            let pp = plain.map(p17RedBlue) ?? (0, 0)
            let px: String = plain.map { im in
                var b = [UInt8](repeating: 0, count: 4)
                let ctx = CGContext(data: &b, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                ctx?.draw(im, in: CGRect(x: -200, y: -100, width: im.width, height: im.height)); return "\(b)" } ?? "-"
            guard let snap else { throw Fail("no snapshot") }
            let (red, blue) = p17RedBlue(snap)
            // in the window the chart shows x 50..<60: all red, no blue (both simulators); ImageRenderer draws a
            // scrollable chart empty (both); the plain chart is 10% red
            let area = Double(snap.width * snap.height) / (400 * 200)
            try expect(red * area > 0.9 && blue * area < 0.02, "scrolled chart in the window: red \(red * area), blue \(blue * area) of the chart's area")
            try expect(rr.0 + rr.1 < 0.01, "ImageRenderer drew the scrollable chart: red \(rr.0) blue \(rr.1) (Apple's simulator: empty)")
            try expect(abs(pp.0 - 0.1) < 0.02 && abs(pp.1 - 0.9) < 0.02, "plain chart red \(pp.0) blue \(pp.1)")
            return "window: red \(Int(red * 1000))‰ blue \(Int(blue * 1000))‰ of \(snap.width)x\(snap.height); ImageRenderer: red \(Int(rr.0 * 1000))‰ blue \(Int(rr.1 * 1000))‰; not scrollable: red \(Int(pp.0 * 1000))‰ blue \(Int(pp.1 * 1000))‰ \(plain.map { "\($0.width)x\($0.height)" } ?? "-") center \(px)"
        })
        #endif

        // MARK: _WebKit_SwiftUI: WebPage's navigation decider sees the page's navigations and cancels one
        #if canImport(WebKit) && (os(iOS) || os(visionOS))
        c.append(check("_WebKit_SwiftUI", "webpage-navigation-decider", timeout: 90) {
            let (page, d) = await onMain { () -> (WebPage, P17Decider) in
                let d = P17Decider(); return (WebPage(configuration: WebPage.Configuration(), navigationDecider: d), d)
            }
            var events: [String] = []
            let seq = await MainActor.run { page.load(html: "<html><body><a id=a href='sdkcov-blocked://x'>go</a></body></html>", baseURL: URL(string: "about:blank")!) }
            for try await e in seq { events.append("\(e)") }
            // a navigation the page starts itself: offered to the decider, cancelled (the page stays where it was)
            _ = try await Task { @MainActor in try await page.callJavaScript("document.getElementById('a').click()") }.value
            try await Task.sleep(for: .seconds(2))
            let (log, url) = await onMain { (d.log, page.url?.absoluteString ?? "nil") }
            // Apple's simulator: the load's action and the click's, no response decision for loaded HTML
            try expect(log == ["action about", "action sdkcov-blocked://x"], "decisions \(log) (events \(events))")
            try expect(!url.hasPrefix("sdkcov-blocked"), "page went to \(url)")
            return "decisions \(log), events \(events), url \(url)"
        })
        #endif

        // MARK: Messages: the app's iMessage extension (ext/Messages.swift) registered, an MSMessagesAppViewController
        // hosted in the app (no conversation outside Messages)
        #if canImport(Messages) && os(iOS)
        c.append(check("Messages", "messages-app-extension", timeout: 30) {
            let r = try p10Record("com.x86sim.test.sdkcov.imessage")
            try expect(r.point == "com.apple.message-payload-provider", "extension point \(r.point)")
            let cls = r.nsExtension["NSExtensionPrincipalClass"] as? String ?? "nil"
            let (style, conv, sub) = try await onMain { () throws -> (UInt, Bool, Int) in
                let vc = MSMessagesAppViewController()
                let (_, close) = try p6Show(vc)
                defer { close() }
                vc.requestPresentationStyle(.expanded)
                return (vc.presentationStyle.rawValue, vc.activeConversation != nil, vc.view.subviews.count)
            }
            // Apple's simulator: compact (0), no conversation, an empty view; the expanded request is ignored there
            try expect(!conv && style == 0 && sub == 0, "style \(style), conversation \(conv), subviews \(sub)")
            return "registered (principal \(cls)); hosted view controller: style \(style), conversation \(conv), subviews \(sub)"
        })
        #endif

        // MARK: CallKit: the app's Call Directory extension (ext/CallDirectory.swift) as CXCallDirectoryManager sees it
        #if canImport(CallKit) && os(iOS)
        c.append(check("CallKit", "call-directory-extension", timeout: 60) {
            let id = "com.x86sim.test.sdkcov.calldir", since = Date()
            let r = try p10Record(id)
            try expect(r.point == "com.apple.callkit.call-directory", "extension point \(r.point)")
            let m = CXCallDirectoryManager.sharedInstance
            let status = P3Box<String>()
            m.getEnabledStatusForExtension(withIdentifier: id) { st, err in
                status.put(err.map { "error \(($0 as NSError).domain) \(($0 as NSError).code)" } ?? "status \(st.rawValue)")
            }
            let st = await status.wait(20) ?? "no answer in 20 s"
            let reload = P3Box<String>()
            m.reloadExtension(withIdentifier: id) { err in reload.put(err.map { "error \(($0 as NSError).domain) \(($0 as NSError).code)" } ?? "reloaded") }
            let rl = await reload.wait(30) ?? "no answer in 30 s"
            let marks = p3Marks("calldir-request", since: since)
            // Apple's iOS 27.2 simulator: both refused with CXErrorCodeCallDirectoryManagerError.unknown (0), the
            // extension never asked (no call directory service there)
            try expect(st == "error com.apple.CallKit.error.calldirectorymanager 0", "enabled status: \(st) (Apple's simulator: error 0); reload \(rl), requests \(marks)")
            try expect(rl == "error com.apple.CallKit.error.calldirectorymanager 0", "reload: \(rl) (Apple's simulator: error 0); requests \(marks)")
            return "registered; enabled \(st); reload \(rl); extension requests \(marks)"
        })
        #endif
        return c
    }
}
