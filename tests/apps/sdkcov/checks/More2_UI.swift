// sdkcov round 2: WebKit (WebContent, GPU and Networking processes: rendering, JS bridges, custom schemes, cookies and
// storage, canvas / WebGL / WebAssembly), text layout (TextKit 2 vs 1, HTML import, printing), SwiftUI layout /
// animation / Canvas by pixels and timing, accessibility, localization from bundles, notification categories +
// attachments, Core Data batch operations / history / fetched results.
import Foundation
import Synchronization
import SwiftUI
import CoreData
import UserNotifications
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif
#if os(iOS) || os(visionOS)   // WebKit and PDFKit are not in the tvOS / watchOS SDKs
import WebKit
import PDFKit
#endif

// MARK: helpers

#if !os(watchOS)   // watchOS apps have no UIWindow: views go on screen through Runner.overlay
@MainActor private func m2Scene() throws -> UIWindowScene {
    guard let ws = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { throw Fail("no window scene") }
    return ws
}
/// a window above the app's own showing `vc`; the closure takes it down
@MainActor private func m2Show(_ vc: UIViewController) throws -> () -> Void {
    let ws = try m2Scene()
    let w = UIWindow(windowScene: ws); w.frame = ws.coordinateSpace.bounds; w.windowLevel = .normal + 1
    w.rootViewController = vc; w.isHidden = false; w.layoutIfNeeded()
    return { w.isHidden = true; w.rootViewController = nil }
}
#endif
private func m2Pixel(_ img: CGImage, _ x: Int, _ y: Int) -> [Int] {
    let ctx = bitmap(img.width, img.height); ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    return pixel(ctx, x, y).map(Int.init)
}
/// poll `cond` on the main actor every 30 ms for up to `secs`
private func m2WaitMain(_ secs: Double, _ cond: @escaping @MainActor () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(secs)
    while Date() < end { if await MainActor.run(body: { cond() }) { return true }; try? await Task.sleep(for: .milliseconds(30)) }
    return await MainActor.run(body: { cond() })
}
/// run an async body on the main actor
private func m2A<T>(_ f: @escaping @MainActor () async throws -> T) async throws -> T { try await Task { @MainActor in try await f() }.value }
private func m2Near(_ p: [Int], _ q: [Int], _ tol: Int = 12) -> Bool { zip(p.prefix(3), q).allSatisfy { abs($0 - $1) <= tol } }

#if os(iOS) || os(visionOS)
/// a WKWebView in its own window with a navigation delegate, message handlers and a custom URL scheme (sdkcov-x:)
@MainActor private final class M2Web: NSObject, WKNavigationDelegate, WKScriptMessageHandler, WKScriptMessageHandlerWithReply, WKURLSchemeHandler {
    var wv: WKWebView!
    var close: () -> Void = {}
    var nav: CheckedContinuation<Void, Error>?
    var messages: [Any] = []
    var schemeHits: [String] = []
    var schemeFiles: [String: (String, Data)] = [:]
    init(store: WKWebsiteDataStore? = nil, userScript: String? = nil, frame: CGRect = CGRect(x: 0, y: 0, width: 360, height: 640)) throws {
        super.init()
        let cfg = WKWebViewConfiguration()
        if let store { cfg.websiteDataStore = store }
        cfg.setURLSchemeHandler(self, forURLScheme: "sdkcov-x")
        cfg.userContentController.add(self, name: "log")
        cfg.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "math")
        if let userScript { cfg.userContentController.addUserScript(WKUserScript(source: userScript, injectionTime: .atDocumentStart, forMainFrameOnly: true)) }
        wv = WKWebView(frame: frame, configuration: cfg)
        wv.scrollView.contentInsetAdjustmentBehavior = .never   // page (0,0) at the view's top-left, under the status bar
        wv.navigationDelegate = self
        let vc = UIViewController(); vc.view.backgroundColor = .white; vc.view.addSubview(wv)
        close = try m2Show(vc)
    }
    func load(_ go: () -> Void, _ secs: Double = 60) async throws {
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in nav = k; go() }
    }
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) { nav?.resume(); nav = nil }
    func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { nav?.resume(throwing: e); nav = nil }
    func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { nav?.resume(throwing: e); nav = nil }
    func webViewWebContentProcessDidTerminate(_ w: WKWebView) { nav?.resume(throwing: Fail("WebContent process terminated")); nav = nil }
    func userContentController(_ u: WKUserContentController, didReceive m: WKScriptMessage) { messages.append(m.body) }
    func userContentController(_ u: WKUserContentController, didReceive m: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        if let x = m.body as? Int { replyHandler(x * 2, nil) } else { replyHandler(nil, "not a number") }
    }
    func webView(_ w: WKWebView, start t: any WKURLSchemeTask) {
        let path = t.request.url?.path ?? ""
        schemeHits.append(path)
        guard let (mime, data) = schemeFiles[path] else {
            t.didFailWithError(NSError(domain: NSURLErrorDomain, code: NSURLErrorFileDoesNotExist)); return
        }
        t.didReceive(HTTPURLResponse(url: t.request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": mime, "Content-Length": "\(data.count)", "Access-Control-Allow-Origin": "*"])!)
        t.didReceive(data); t.didFinish()
    }
    func webView(_ w: WKWebView, stop t: any WKURLSchemeTask) {}
    func js(_ s: String) async throws -> Any? { try await wv.evaluateJavaScript(s) }
    func teardown() {
        wv.configuration.userContentController.removeAllScriptMessageHandlers()
        wv.removeFromSuperview(); close()
    }
}

#endif

private final class M2NotifDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification) async -> UNNotificationPresentationOptions { [.list, .banner] }
}

/// counts what an Animatable modifier is handed while a SwiftUI animation runs
@MainActor private final class M2AnimModel: ObservableObject {
    @Published var x: CGFloat = 0
    var seen: [CGFloat] = []
}
private struct M2Probe: ViewModifier, Animatable {
    var x: CGFloat
    let model: M2AnimModel
    var animatableData: CGFloat { get { x } set { x = newValue; let v = newValue; let m = model; MainActor.assumeIsolated { m.seen.append(v) } } }
    func body(content: Content) -> some View { content.offset(x: x) }
}
private struct M2AnimView: View {
    @ObservedObject var m: M2AnimModel
    var body: some View { Color.orange.frame(width: 40, height: 40).modifier(M2Probe(x: m.x, model: m)) }
}

/// a custom Layout: children on a diagonal, each at (i*10, i*10)
private struct M2Diagonal: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize { CGSize(width: CGFloat(subviews.count) * 10, height: CGFloat(subviews.count) * 10) }
    func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (i, s) in subviews.enumerated() { s.place(at: CGPoint(x: b.minX + CGFloat(i) * 10, y: b.minY + CGFloat(i) * 10), proposal: ProposedViewSize(width: 10, height: 10)) }
    }
}

/// a Core Data model built in code: Item(name, value, group)
private func m2Model() -> NSManagedObjectModel {
    let m = NSManagedObjectModel(), e = NSEntityDescription(); e.name = "Item"; e.managedObjectClassName = "NSManagedObject"
    func attr(_ n: String, _ t: NSAttributeType) -> NSAttributeDescription { let a = NSAttributeDescription(); a.name = n; a.attributeType = t; a.isOptional = true; return a }
    e.properties = [attr("name", .stringAttributeType), attr("value", .integer64AttributeType), attr("group", .stringAttributeType)]
    m.entities = [e]; return m
}

extension Registry {
    static var more2_ui: [Check] {
        guard more2On else { return [] }
        var c: [Check] = []
        #if os(iOS) || os(visionOS)
        // MARK: WebKit
        c.append(check("WebKit", "css-render-snapshot-createpdf", timeout: 120) {
            let w = try await onMain { try M2Web() }
            defer { Task { @MainActor in w.teardown() } }
            let html = """
            <!doctype html><html><head><meta name=viewport content="width=device-width,initial-scale=1"><style>
            body{margin:0;background:#fff} div{position:absolute;width:100px;height:100px}
            #r{left:0;top:0;background:rgb(255,0,0)} #g{left:100px;top:0;background:rgb(0,255,0)} #b{left:0;top:100px;background:rgb(0,0,255)}
            #grad{left:100px;top:100px;background:linear-gradient(to right,rgb(0,0,0),rgb(255,255,255))}
            #rot{left:200px;top:0;width:60px;height:60px;background:rgb(255,0,255);transform:translate(20px,20px) rotate(45deg);border-radius:8px}
            p{position:absolute;top:260px;left:10px;font:20px -apple-system}
            </style></head><body><div id=r></div><div id=g></div><div id=b></div><div id=grad></div><div id=rot></div><p>x86sim pdf text</p></body></html>
            """
            try await m2A { () async throws in try await w.load { w.wv.loadHTMLString(html, baseURL: URL(string: "https://sdkcov.example/")) } }
            try await Task.sleep(for: .milliseconds(500))
            let img: UIImage = try await m2A { () async throws -> UIImage in
                let cfg = WKSnapshotConfiguration(); cfg.rect = CGRect(x: 0, y: 0, width: 300, height: 300); cfg.snapshotWidth = 300
                return try await w.wv.takeSnapshot(configuration: cfg)
            }
            guard let cg = img.cgImage else { throw Fail("snapshot has no CGImage") }
            let s = Double(cg.width) / 300
            func at(_ x: Double, _ y: Double) -> [Int] { m2Pixel(cg, Int(x * s), Int(y * s)) }
            let r = at(50, 50), g = at(150, 50), b = at(50, 150), gl = at(110, 150), gm = at(150, 150), gr = at(190, 150), rot = at(250, 50), white = at(290, 290)
            try expect(m2Near(r, [255, 0, 0]) && m2Near(g, [0, 255, 0]) && m2Near(b, [0, 0, 255]), "boxes r \(r) g \(g) b \(b) (\(cg.width)x\(cg.height))")
            try expect(gl[0] < 60 && gr[0] > 195 && abs(gm[0] - 128) < 30, "gradient \(gl[0]) \(gm[0]) \(gr[0])")
            try expect(m2Near(rot, [255, 0, 255]) && m2Near(white, [255, 255, 255]), "rotated box \(rot), background \(white)")
            // the page as PDF: one page with its text
            let pdf: Data = try await m2A { () async throws -> Data in try await w.wv.pdf(configuration: WKPDFConfiguration()) }
            guard let doc = PDFDocument(data: pdf) else { throw Fail("createPDF data \(pdf.count) B") }
            try expect(doc.pageCount >= 1 && (doc.string ?? "").contains("x86sim pdf text"), "PDF pages \(doc.pageCount) text \(String(describing: doc.string?.prefix(40)))")
            return "snapshot \(cg.width)x\(cg.height): boxes, gradient \(gl[0])..\(gr[0]), rotated rounded box; PDF \(pdf.count) B"
        })
        c.append(check("WebKit", "js-bridges-user-script-async-reply", timeout: 120) {
            let w = try await onMain { try M2Web(userScript: "window.injected = 7; window.webkit.messageHandlers.log.postMessage({from: 'userscript', a: [1, 2, 3]});") }
            defer { Task { @MainActor in w.teardown() } }
            try await m2A { () async throws in try await w.load { w.wv.loadHTMLString("<html><body><script>window.webkit.messageHandlers.log.postMessage('page ' + window.injected)</script></body></html>", baseURL: nil) } }
            _ = await m2WaitMain(5) { w.messages.count >= 2 }
            let msgs = await onMain { w.messages }
            let first = msgs.first as? [String: Any]
            try expect(msgs.count == 2 && (first?["from"] as? String) == "userscript" && (first?["a"] as? [Int]) == [1, 2, 3] && (msgs.last as? String) == "page 7", "messages \(msgs)")
            // JS awaits a native reply (WKScriptMessageHandlerWithReply), via callAsyncJavaScript with arguments
            let r = try await m2A { () async throws -> Any? in
                try await w.wv.callAsyncJavaScript("const d = await window.webkit.messageHandlers.math.postMessage(n); await new Promise(r => setTimeout(r, 50)); return d + window.injected;", arguments: ["n": 20], contentWorld: .page)
            }
            try expect((r as? Int) == 47, "async reply chain \(String(describing: r))")
            let rej = try? try await m2A { () async throws -> Any? in try await w.wv.callAsyncJavaScript("return await window.webkit.messageHandlers.math.postMessage('x')", contentWorld: .page) }
            try expect(rej == nil, "a rejected reply should throw, got \(String(describing: rej))")
            // a JS exception surfaces as WKError.javaScriptExceptionOccurred; an isolated content world doesn't see the page's globals
            var code = 0
            do { _ = try await m2A { () async throws -> Any? in try await w.js("throw new TypeError('sdkcov')") } } catch { code = (error as NSError).code }
            let iso = try await m2A { () async throws -> Any? in try await w.wv.callAsyncJavaScript("return typeof window.injected", contentWorld: WKContentWorld.world(name: "sdkcov")) }
            try expect(code == WKError.javaScriptExceptionOccurred.rawValue && (iso as? String) == "undefined", "exception code \(code), isolated world sees \(String(describing: iso))")
            return "user script + 2 messages, async reply 47, rejection, exception \(code), isolated world"
        })
        c.append(check("WebKit", "url-scheme-handler-image-fetch", timeout: 120) {
            let w = try await onMain { try M2Web() }
            defer { Task { @MainActor in w.teardown() } }
            let ctx = bitmap(7, 5); ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 7, height: 5))
            let png = try encode(ctx.makeImage()!, .png)
            await onMain {
                w.schemeFiles["/index.html"] = ("text/html", Data("""
                <html><body><img id=i src="img.png"><script>
                window.res = 'pending';
                fetch('data.json').then(r => r.json()).then(j => { window.res = j.who + ':' + j.n; window.webkit.messageHandlers.log.postMessage('fetched'); }).catch(e => { window.res = 'error ' + e; });
                </script></body></html>
                """.utf8))
                w.schemeFiles["/img.png"] = ("image/png", png)
                w.schemeFiles["/data.json"] = ("application/json", Data(#"{"who":"x86sim","n":42}"#.utf8))
            }
            try await m2A { () async throws in try await w.load { w.wv.load(URLRequest(url: URL(string: "sdkcov-x://app/index.html")!)) } }
            _ = await m2WaitMain(10) { w.messages.contains { ($0 as? String) == "fetched" } }
            let r = try await m2A { () async throws -> Any? in try await w.js("[document.getElementById('i').naturalWidth, document.getElementById('i').naturalHeight, window.res, location.protocol].join('|')") }
            let hits = await onMain { w.schemeHits }
            try expect((r as? String) == "7|5|x86sim:42|sdkcov-x:", "page state \(String(describing: r)), scheme requests \(hits)")
            // a missing resource fails the fetch in JS
            let miss = try await m2A { () async throws -> Any? in try await w.wv.callAsyncJavaScript("try { await fetch('nope.txt'); return 'ok' } catch (e) { return 'failed' }", contentWorld: .page) }
            try expect((miss as? String) == "failed", "missing resource \(String(describing: miss))")
            return "custom scheme served \(hits.count) requests: page, 7x5 PNG, JSON via fetch; missing -> error"
        })
        #if canImport(Network)
        c.append(check("WebKit", "loopback-http-cookies-localstorage", timeout: 120) {
            let srv = try More2HTTP { r in
                switch r.path {
                case "/page": return More2Resp("200 OK", [("Content-Type", "text/html"), ("Set-Cookie", "srv=1; Path=/")], Data("<html><head><title>loop</title></head><body style='background:#0f0'>served</body></html>".utf8))
                case "/echo": return .text(r.headers["cookie"] ?? "-")
                default: return More2Resp("404 Not Found")
                }
            }
            let port = try await srv.start(); defer { srv.stop() }
            let store = await onMain { WKWebsiteDataStore.nonPersistent() }
            let pre = HTTPCookie(properties: [.name: "pre", .value: "9", .domain: "127.0.0.1", .path: "/"])!
            try await m2A { () async in await store.httpCookieStore.setCookie(pre) }
            let w = try await onMain { try M2Web(store: store) }
            defer { Task { @MainActor in w.teardown() } }
            try await m2A { () async throws in try await w.load { w.wv.load(URLRequest(url: URL(string: "http://127.0.0.1:\(port)/page")!)) } }
            let title = await onMain { w.wv.title }
            try expect(title == "loop", "title \(String(describing: title))")
            let r = try await m2A { () async throws -> Any? in try await w.wv.callAsyncJavaScript("""
                document.cookie = 'js=2; path=/';
                localStorage.setItem('k', 'x86sim-' + location.port);
                const echo = await (await fetch('/echo')).text();
                return document.cookie + '#' + echo;
                """, contentWorld: .page) }
            let s = (r as? String) ?? ""
            let parts = s.components(separatedBy: "#")
            for want in ["pre=9", "srv=1", "js=2"] { try expect(parts.count == 2 && parts.allSatisfy { $0.contains(want) }, "cookie \(want) missing: document.cookie | server saw: \(s)") }
            let jar = try await m2A { () async in await store.httpCookieStore.allCookies().map(\.name).sorted() }
            try expect(jar == ["js", "pre", "srv"], "cookie store \(jar)")
            // a second web view on the same data store sees the first one's localStorage
            let w2 = try await onMain { try M2Web(store: store) }
            defer { Task { @MainActor in w2.teardown() } }
            try await m2A { () async throws in try await w2.load { w2.wv.load(URLRequest(url: URL(string: "http://127.0.0.1:\(port)/page")!)) } }
            let ls = try await m2A { () async throws -> Any? in try await w2.js("localStorage.getItem('k')") }
            try expect((ls as? String) == "x86sim-\(port)", "localStorage in a second view \(String(describing: ls))")
            return "page over loopback (\(srv.requests.withLock { $0.count }) requests), cookies set natively / by header / by JS all sent, store \(jar), localStorage shared"
        })
        #endif
        c.append(check("WebKit", "canvas-webgl-wasm-crypto-intl-raf", timeout: 120) {
            let w = try await onMain { try M2Web() }
            defer { Task { @MainActor in w.teardown() } }
            try await m2A { () async throws in try await w.load { w.wv.loadHTMLString("<html><body><canvas id=c width=8 height=8></canvas><canvas id=g width=4 height=4></canvas></body></html>", baseURL: URL(string: "https://sdkcov.example/")) } }
            let r = try await m2A { () async throws -> Any? in try await w.wv.callAsyncJavaScript("""
                const out = {};
                const c = document.getElementById('c').getContext('2d');
                c.fillStyle = 'rgb(255,0,0)'; c.fillRect(0, 0, 8, 8); c.fillStyle = 'rgba(0,0,255,0.5)'; c.fillRect(4, 0, 4, 8);
                out.canvas = Array.from(c.getImageData(1, 1, 1, 1).data).concat(Array.from(c.getImageData(6, 1, 1, 1).data)).join(',');
                const gl = document.getElementById('g').getContext('webgl');
                if (gl) { gl.clearColor(0, 1, 0, 1); gl.clear(gl.COLOR_BUFFER_BIT); const px = new Uint8Array(4); gl.readPixels(0, 0, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, px); out.webgl = Array.from(px).join(','); out.renderer = gl.getParameter(gl.VERSION); } else out.webgl = 'none';
                const bytes = new Uint8Array([0,97,115,109,1,0,0,0,1,7,1,96,2,127,127,1,127,3,2,1,0,7,7,1,3,97,100,100,0,0,10,9,1,7,0,32,0,32,1,106,11]);
                const { instance } = await WebAssembly.instantiate(bytes);
                out.wasm = instance.exports.add(40, 2);
                const dg = await crypto.subtle.digest('SHA-256', new TextEncoder().encode('abc'));
                out.sha = Array.from(new Uint8Array(dg)).map(b => b.toString(16).padStart(2, '0')).join('').slice(0, 16);
                out.intl = new Intl.NumberFormat('de-DE', { style: 'currency', currency: 'EUR' }).format(1234.5) + '|' + new Intl.DateTimeFormat('en-US', { timeZone: 'UTC', dateStyle: 'medium' }).format(new Date(Date.UTC(2026, 10, 15)));
                let n = 0; const t0 = performance.now();
                await new Promise(res => { function f() { n++; if (performance.now() - t0 > 500) res(); else requestAnimationFrame(f); } requestAnimationFrame(f); });
                out.raf = n;
                return JSON.stringify(out);
                """, contentWorld: .page) }
            guard let js = (r as? String)?.data(using: .utf8), let o = try JSONSerialization.jsonObject(with: js) as? [String: Any] else { throw Fail("result \(String(describing: r))") }
            try expect((o["canvas"] as? String) == "255,0,0,255,128,0,127,255" || (o["canvas"] as? String) == "255,0,0,255,127,0,128,255", "canvas \(o["canvas"] ?? "-")")
            try expect((o["webgl"] as? String) == "0,255,0,255", "WebGL readPixels \(o["webgl"] ?? "-")")
            try expect((o["wasm"] as? Int) == 42 && (o["sha"] as? String) == "ba7816bf8f01cfea", "wasm \(o["wasm"] ?? "-") sha \(o["sha"] ?? "-")")
            try expect((o["intl"] as? String) == "1.234,50\u{a0}€|Nov 15, 2026", "Intl \(o["intl"] ?? "-")")
            let raf = o["raf"] as? Int ?? 0
            try expect(raf >= 10, "requestAnimationFrame ran \(raf) times in 500 ms")
            return "canvas \(o["canvas"]!), WebGL \(o["renderer"] ?? "?"), wasm 42, subtle SHA-256, Intl, rAF \(raf)/0.5 s"
        })

        #endif

        // MARK: text
        #if !os(watchOS)   // no UITextView / TextKit 1 on watchOS
        c.append(check("UIKit", "textkit2-vs-textkit1-layout-hit-test") {
            try await onMain {
                let text = String(repeating: "x86Sim lays out paragraphs with TextKit 2 the same way TextKit 1 does. ", count: 6) + "\nSecond paragraph: 漢字 and 🦊."
                let font = UIFont.systemFont(ofSize: 16)
                let attr = NSAttributedString(string: text, attributes: [.font: font])
                // TextKit 2
                let cs = NSTextContentStorage(); let lm2 = NSTextLayoutManager(); cs.addTextLayoutManager(lm2)
                let tc2 = NSTextContainer(size: CGSize(width: 240, height: 0)); tc2.lineFragmentPadding = 0; lm2.textContainer = tc2
                cs.attributedString = attr
                lm2.ensureLayout(for: lm2.documentRange)
                var lines2 = 0, paras = 0, maxW: CGFloat = 0, height2: CGFloat = 0
                lm2.enumerateTextLayoutFragments(from: lm2.documentRange.location, options: [.ensuresLayout]) { f in
                    paras += 1; lines2 += f.textLineFragments.count
                    for l in f.textLineFragments { maxW = max(maxW, l.typographicBounds.width) }
                    height2 = max(height2, f.layoutFragmentFrame.maxY); return true
                }
                // TextKit 1
                let ts = NSTextStorage(attributedString: attr); let lm1 = NSLayoutManager(); ts.addLayoutManager(lm1)
                let tc1 = NSTextContainer(size: CGSize(width: 240, height: CGFloat.greatestFiniteMagnitude)); tc1.lineFragmentPadding = 0; lm1.addTextContainer(tc1)
                lm1.ensureLayout(for: tc1)
                var lines1 = 0; var idx = 0; var r = NSRange()
                while idx < lm1.numberOfGlyphs { lm1.lineFragmentRect(forGlyphAt: idx, effectiveRange: &r); idx = NSMaxRange(r); lines1 += 1 }
                let used = lm1.usedRect(for: tc1)
                try expect(paras == 2 && lines2 >= 12 && lines2 == lines1, "TextKit 2: \(paras) paragraphs \(lines2) lines; TextKit 1: \(lines1) lines")
                try expect(maxW <= 240.5 && abs(height2 - used.height) < 2, "widths \(maxW), heights TK2 \(height2) TK1 \(used.height)")
                // hit test: the character under a point on line 2 is in line 2's range
                let ci = lm1.characterIndex(for: CGPoint(x: 5, y: used.height / CGFloat(lines1) * 1.5), in: tc1, fractionOfDistanceBetweenInsertionPoints: nil)
                let gi = lm1.glyphIndexForCharacter(at: ci)
                var lr = NSRange(); lm1.lineFragmentRect(forGlyphAt: gi, effectiveRange: &lr)
                var lr0 = NSRange(); lm1.lineFragmentRect(forGlyphAt: 0, effectiveRange: &lr0)
                try expect(lr.location == NSMaxRange(lr0), "hit test on line 2 gave glyph \(gi) in \(lr), line 1 \(lr0)")
                // a UITextView (TextKit 2 by default) sizes to the same height
                let tv = UITextView(usingTextLayoutManager: true); tv.textContainerInset = .zero; tv.textContainer.lineFragmentPadding = 0
                tv.attributedText = attr; tv.isScrollEnabled = false
                let fit = tv.sizeThatFits(CGSize(width: 240, height: CGFloat.greatestFiniteMagnitude))
                try expect(tv.textLayoutManager != nil && abs(fit.height - used.height) < 3, "UITextView fit \(fit), TK1 \(used.height)")
                return "\(lines2) lines in 240 pt (TK2 = TK1), height \(Int(height2)), hit test, UITextView \(Int(fit.height))"
            }
        })
        #endif
        #if os(iOS) || os(visionOS)   // printing (UIPrintPageRenderer) and PDFKit: not on tvOS / watchOS
        c.append(check("UIKit", "attributed-html-import-print-renderer", timeout: 90) {
            try await onMain {
                // HTML -> NSAttributedString (WebKit's importer): text, bold, colour, link, list
                let html = "<html><body style='font: 14px Helvetica'><p>plain <b>bold</b> <span style='color:#ff0000'>red</span> <a href='https://x86sim.example/a'>link</a></p><ul><li>one</li><li>two</li></ul></body></html>"
                let a = try NSAttributedString(data: Data(html.utf8), options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil)
                let s = a.string as NSString
                try expect(s.contains("plain bold red link") && s.contains("one") && s.contains("two"), "text \(a.string.debugDescription)")
                let fb = a.attribute(.font, at: s.range(of: "bold").location, effectiveRange: nil) as? UIFont
                let col = a.attribute(.foregroundColor, at: s.range(of: "red").location, effectiveRange: nil) as? UIColor
                let link = a.attribute(.link, at: s.range(of: "link").location, effectiveRange: nil)
                var rr: CGFloat = 0, gg: CGFloat = 0, bb: CGFloat = 0, aa: CGFloat = 0; col?.getRed(&rr, green: &gg, blue: &bb, alpha: &aa)
                try expect(fb?.fontDescriptor.symbolicTraits.contains(.traitBold) == true, "bold font \(String(describing: fb))")
                try expect(rr > 0.9 && gg < 0.1 && bb < 0.1, "red colour \(rr) \(gg) \(bb)")
                try expect(((link as? URL)?.absoluteString ?? (link as? String)) == "https://x86sim.example/a", "link \(String(describing: link))")
                // back to HTML keeps the text
                let back = try a.data(from: NSRange(location: 0, length: a.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.html])
                try expect(String(decoding: back, as: UTF8.self).contains("bold"), "export to HTML")
                // printing without a printer: UIPrintPageRenderer + a text formatter -> PDF pages
                let long = (1...200).map { "Line \($0) of the sdkcov print test." }.joined(separator: "\n")
                let pr = UIPrintPageRenderer()
                pr.addPrintFormatter(UISimpleTextPrintFormatter(text: long), startingAtPageAt: 0)
                let paper = CGRect(x: 0, y: 0, width: 612, height: 792)
                pr.setValue(paper, forKey: "paperRect"); pr.setValue(paper.insetBy(dx: 36, dy: 36), forKey: "printableRect")
                let data = NSMutableData()
                UIGraphicsBeginPDFContextToData(data, paper, nil)
                pr.prepare(forDrawingPages: NSRange(location: 0, length: pr.numberOfPages))
                for i in 0..<pr.numberOfPages { UIGraphicsBeginPDFPage(); pr.drawPage(at: i, in: UIGraphicsGetPDFContextBounds()) }
                UIGraphicsEndPDFContext()
                guard let doc = PDFDocument(data: data as Data) else { throw Fail("print PDF") }
                let txt = doc.string ?? ""
                try expect(pr.numberOfPages >= 3 && doc.pageCount == pr.numberOfPages && txt.contains("Line 1 of") && txt.contains("Line 200 of"), "print: \(pr.numberOfPages) pages, PDF \(doc.pageCount), text \(txt.count) chars")
                return "HTML import bold/red/link/list + export; print renderer \(pr.numberOfPages) pages"
            }
        })

        #endif

        // MARK: SwiftUI by pixels and timing
        c.append(check("SwiftUI", "layout-stacks-grid-custom-layout-pixels") {
            try await onMain {
                let v = VStack(spacing: 0) {
                    HStack(spacing: 0) { Color.red.frame(width: 40, height: 30); Color.green.frame(width: 60, height: 30) }
                    Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                        GridRow { Color.blue.frame(width: 50, height: 20); Color.yellow.frame(width: 50, height: 20) }
                        GridRow { Color.black.frame(width: 30, height: 10).gridCellColumns(2) }
                    }
                    ZStack(alignment: .bottomTrailing) { Color.gray.frame(width: 100, height: 40); Color.white.frame(width: 20, height: 10) }
                    HStack(spacing: 0) { M2Diagonal { Color.red; Color.green; Color.blue }; Spacer(minLength: 0) }.frame(width: 100, height: 30)
                    ViewThatFits { Color.purple.frame(width: 300, height: 10); Color.cyan.frame(width: 100, height: 10) }
                    Text("Wg").font(.system(size: 20)).frame(width: 100, height: 30).background(Color.white).padding(.leading, 0)
                }.frame(width: 100).background(Color.white)
                let r = ImageRenderer(content: v); r.scale = 1
                guard let img = r.cgImage else { throw Fail("ImageRenderer") }
                try expect(img.width == 100 && img.height == 170, "size \(img.width)x\(img.height)")
                let probes: [(String, Int, Int, [Int])] = [
                    ("hstack red", 20, 15, [255, 59, 48]), ("hstack green", 70, 15, [52, 199, 89]),
                    ("grid blue", 25, 40, [0, 122, 255]), ("grid yellow", 75, 40, [255, 204, 0]),
                    ("grid span centre black", 50, 55, [0, 0, 0]), ("zstack gray", 10, 70, [142, 142, 147]), ("zstack corner white", 95, 95, [255, 255, 255]),
                    ("diag 0", 5, 105, [255, 59, 48]), ("diag 1", 15, 115, [52, 199, 89]), ("diag 2", 25, 125, [0, 122, 255]), ("diag off", 25, 105, [255, 255, 255]),
                    ("ViewThatFits cyan", 50, 135, [0, 192, 232]),
                ]
                var bad: [String] = []
                for (n, x, y, want) in probes { let p = m2Pixel(img, x, y); if !m2Near(p, want, 30) { bad.append("\(n) \(p.prefix(3))") } }
                try expect(bad.isEmpty, "pixels off: \(bad)")
                // the text row has ink
                var ink = 0; for y in 140..<170 { for x in 0..<100 { if m2Pixel(img, x, y)[0] < 128 { ink += 1 } } }
                try expect(ink > 40, "text ink \(ink)")
                return "100x170: HStack, Grid (+span), ZStack alignment, custom Layout, ViewThatFits, Text \(ink) px"
            }
        })
        c.append(check("SwiftUI", "animation-timing-completion-canvas", timeout: 40) {
            // a 0.4 s linear animation on screen: the Animatable modifier sees intermediate values in order, the
            // completion runs after ~0.4 s
            let m = await onMain { M2AnimModel() }
            #if os(watchOS)
            await onMain { Runner.shared.overlay = AnyView(M2AnimView(m: m)) }
            defer { Task { @MainActor in Runner.shared.overlay = nil } }
            #else
            let close = try await onMain { try m2Show(UIHostingController(rootView: M2AnimView(m: m))) }
            defer { Task { @MainActor in close() } }
            #endif
            try await Task.sleep(for: .milliseconds(400))
            let done = Mutex<Date?>(nil), t0 = Date()
            await onMain { m.seen = []; withAnimation(.linear(duration: 0.4)) { m.x = 100 } completion: { done.withLock { $0 = Date() } } }
            _ = await more2Wait(5) { done.withLock { $0 } != nil }
            let seen = await onMain { m.seen }
            let el = done.withLock { $0 }.map { $0.timeIntervalSince(t0) } ?? -1
            let mid = seen.filter { $0 > 1 && $0 < 99 }
            try expect(el > 0.3 && el < 1.5, "completion after \(el) s")
            try expect(mid.count >= 8 && zip(mid, mid.dropFirst()).allSatisfy { $0 <= $1 } && seen.last == 100, "animated values \(mid.count) intermediate, last \(String(describing: seen.last)): \(seen.prefix(6))")
            // Canvas: a filled circle, a stroked line and a gradient, by pixels
            let img: CGImage = try await onMain {
                let v = Canvas { ctx, size in
                    ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
                    ctx.fill(Path(ellipseIn: CGRect(x: 10, y: 10, width: 60, height: 60)), with: .color(Color(red: 1, green: 0, blue: 0)))
                    ctx.fill(Path(CGRect(x: 0, y: 80, width: 100, height: 20)), with: .linearGradient(Gradient(colors: [Color(red: 0, green: 0, blue: 0), Color(red: 1, green: 1, blue: 1)]), startPoint: CGPoint(x: 0, y: 90), endPoint: CGPoint(x: 100, y: 90)))
                    var p = Path(); p.move(to: CGPoint(x: 80, y: 0)); p.addLine(to: CGPoint(x: 80, y: 70))
                    ctx.stroke(p, with: .color(Color(red: 0, green: 0, blue: 1)), lineWidth: 4)
                }.frame(width: 100, height: 100)
                let r = ImageRenderer(content: v); r.scale = 1
                guard let i = r.cgImage else { throw Fail("Canvas render") }
                return i
            }
            let cen = m2Pixel(img, 40, 40), out = m2Pixel(img, 12, 12), line = m2Pixel(img, 80, 30), g0 = m2Pixel(img, 5, 90), g1 = m2Pixel(img, 95, 90)
            try expect(m2Near(cen, [255, 0, 0]) && m2Near(out, [255, 255, 255]) && m2Near(line, [0, 0, 255]) && g0[0] < 40 && g1[0] > 215, "canvas centre \(cen) corner \(out) line \(line) gradient \(g0[0])..\(g1[0])")
            return "linear 0.4 s: completion at \(String(format: "%.2f", el)) s, \(mid.count) intermediate frames; Canvas circle/line/gradient"
        })

        // MARK: accessibility
        #if !os(watchOS)   // UIKit views and UIAccessibilityCustomAction targets: not on watchOS
        c.append(check("UIKit", "accessibility-elements-actions-swiftui-tree", timeout: 40) {
            final class Target: NSObject { var hits = 0; @objc func act(_ a: UIAccessibilityCustomAction) -> Bool { hits += 1; return true } }
            return try await m2A { () async throws -> String in
                let t = Target()
                let vc = UIViewController(); vc.view.backgroundColor = .white
                let b = UIButton(type: .system); b.setTitle("Play", for: .normal); b.frame = CGRect(x: 20, y: 100, width: 100, height: 44)
                #if os(tvOS)   // no UISwitch on tvOS: a second (focusable) button
                let sw = UIButton(type: .system); sw.setTitle("Mute", for: .normal); sw.frame = CGRect(x: 20, y: 160, width: 100, height: 44)
                #else
                let sw = UISwitch(frame: CGRect(x: 20, y: 160, width: 60, height: 30)); sw.isOn = true
                #endif
                let lbl = UILabel(frame: CGRect(x: 20, y: 200, width: 200, height: 30)); lbl.text = "Volume"; lbl.accessibilityValue = "11"
                lbl.accessibilityCustomActions = [UIAccessibilityCustomAction(name: "Louder", target: t, selector: #selector(Target.act(_:)))]
                let hidden = UILabel(); hidden.text = "secret"; hidden.isAccessibilityElement = false
                [b, sw, lbl, hidden].forEach { vc.view.addSubview($0) }
                // SwiftUI content with an explicit label, a hint and a header trait
                let host = UIHostingController(rootView: VStack { Button("Go") {}.accessibilityLabel("Start game").accessibilityHint("Begins"); Text("Scores").accessibilityAddTraits(.isHeader) })
                host.view.frame = CGRect(x: 0, y: 300, width: 300, height: 200); vc.addChild(host); vc.view.addSubview(host.view)
                let close = try m2Show(vc); defer { close() }
                try await Task.sleep(for: .milliseconds(500))
                // (UIKit's own labels / values for controls come from its accessibility bundle, loaded only while an
                // assistive technology runs: not asserted)
                try expect(b.accessibilityTraits.contains(.button) && sw.accessibilityTraits.contains(.button), "button traits \(b.accessibilityTraits) switch \(sw.accessibilityTraits)")
                try expect(lbl.accessibilityValue == "11" && !hidden.isAccessibilityElement, "label \(String(describing: lbl.accessibilityLabel)) value \(String(describing: lbl.accessibilityValue))")
                let order = (vc.view.accessibilityElements ?? vc.view.subviews).compactMap { ($0 as? NSObject)?.isAccessibilityElement == true ? $0 : nil }.count
                _ = lbl.accessibilityCustomActions?.first.map { a in t.perform(#selector(Target.act(_:)), with: a) }
                try expect(t.hits == 1, "custom action ran \(t.hits)")
                // walk the SwiftUI host's accessibility elements
                func walk(_ o: Any, _ out: inout [(String, UIAccessibilityTraits, String)]) {
                    guard let n = o as? NSObject else { return }
                    if n.isAccessibilityElement { out.append((n.accessibilityLabel ?? "", n.accessibilityTraits, n.accessibilityHint ?? "")) }
                    let kids: [Any] = n.accessibilityElements ?? ((n as? UIView)?.subviews ?? []) + (0..<max(0, n.accessibilityElementCount())).compactMap { n.accessibilityElement(at: $0) }
                    for k in kids { walk(k, &out) }
                }
                var els: [(String, UIAccessibilityTraits, String)] = []
                walk(host.view!, &els)
                let start = els.first { $0.0 == "Start game" }, header = els.first { $0.0 == "Scores" }
                UIAccessibility.post(notification: .screenChanged, argument: b)
                if els.isEmpty { return "UIKit button/label + custom action, \(order) elements in the view; SwiftUI exposes no elements while no assistive technology runs" }
                try expect(start?.1.contains(.button) == true && start?.2 == "Begins" && header?.1.contains(.header) == true, "SwiftUI elements \(els.map { "\($0.0)/\($0.1.rawValue)/\($0.2)" })")
                return "UIKit button/label + custom action; SwiftUI \(els.count) elements: Start game (button, hint), Scores (header)"
            }
        })

        #endif

        // MARK: localization
        c.append(check("Foundation", "bundle-localization-stringsdict-plurals") {
            let fm = FileManager.default, root = try more2Dir("loc").appendingPathComponent("Loc.bundle")
            func lproj(_ l: String, strings: String, plural: [String: String]) throws {
                let d = root.appendingPathComponent("\(l).lproj"); try fm.createDirectory(at: d, withIntermediateDirectories: true)
                try Data(strings.utf8).write(to: d.appendingPathComponent("Localizable.strings"))
                let sd: [String: Any] = ["items %lld": ["NSStringLocalizedFormatKey": "%#@n@", "n": ["NSStringFormatSpecTypeKey": "NSStringPluralRuleType", "NSStringFormatValueTypeKey": "lld"].merging(plural) { $1 }]]
                try PropertyListSerialization.data(fromPropertyList: sd, format: .xml, options: 0).write(to: d.appendingPathComponent("Localizable.stringsdict"))
            }
            try lproj("en", strings: "\"greet\" = \"Hello\";\n\"bye\" = \"Bye\";", plural: ["one": "%lld item", "other": "%lld items"])
            try lproj("fr", strings: "\"greet\" = \"Bonjour\";", plural: ["one": "%lld élément", "other": "%lld éléments"])
            try lproj("ru", strings: "\"greet\" = \"Привет\";", plural: ["one": "%lld предмет", "few": "%lld предмета", "many": "%lld предметов", "other": "%lld предмета"])
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.x86sim.sdkcov.loc", "CFBundleDevelopmentRegion": "en"], format: .xml, options: 0).write(to: root.appendingPathComponent("Info.plist"))
            guard let b = Bundle(url: root) else { throw Fail("bundle") }
            try expect(Set(b.localizations) == ["en", "fr", "ru"], "localizations \(b.localizations)")
            try expect(Bundle.preferredLocalizations(from: b.localizations, forPreferences: ["fr-CA", "en"]).first == "fr" && Bundle.preferredLocalizations(from: b.localizations, forPreferences: ["de-DE"]).first == "en", "preferred localization")
            func sub(_ l: String) throws -> Bundle { guard let p = b.path(forResource: l, ofType: "lproj"), let s = Bundle(path: p) else { throw Fail("\(l).lproj") }; return s }
            let en = try sub("en"), fr = try sub("fr"), ru = try sub("ru")
            try expect(fr.localizedString(forKey: "greet", value: nil, table: nil) == "Bonjour" && ru.localizedString(forKey: "greet", value: nil, table: nil) == "Привет", "greet")
            try expect(fr.localizedString(forKey: "bye", value: "fallback", table: nil) == "fallback", "missing key falls back to the value")
            func plural(_ bd: Bundle, _ l: String, _ n: Int) -> String { String(format: bd.localizedString(forKey: "items %lld", value: nil, table: nil), locale: Locale(identifier: l), n) }
            let got = [plural(en, "en", 1), plural(en, "en", 5), plural(fr, "fr", 0), plural(fr, "fr", 2), plural(ru, "ru", 1), plural(ru, "ru", 3), plural(ru, "ru", 5), plural(ru, "ru", 21)]
            try expect(got == ["1 item", "5 items", "0 élément", "2 éléments", "1 предмет", "3 предмета", "5 предметов", "21 предмет"], "plurals \(got)")
            // locale-sensitive formatting through ICU
            let fmt = [
                (1234.5).formatted(.number.locale(Locale(identifier: "fr_FR"))),
                (1234.5).formatted(.currency(code: "EUR").locale(Locale(identifier: "de_DE"))),
                (0.256).formatted(.percent.locale(Locale(identifier: "tr_TR"))),
                Date(timeIntervalSince1970: 1_763_164_800).formatted(Date.FormatStyle(date: .complete, time: .omitted, locale: Locale(identifier: "ja_JP"), timeZone: TimeZone(identifier: "UTC")!)),
                ["a", "b", "c"].formatted(.list(type: .and).locale(Locale(identifier: "es_ES"))),
                Measurement(value: 5, unit: UnitLength.kilometers).formatted(.measurement(width: .wide).locale(Locale(identifier: "en_GB"))),
            ]
            try expect(fmt == ["1\u{202f}234,5", "1.234,50\u{a0}€", "%25,6", "2025年11月15日 土曜日", "a, b y c", "3.1 miles"], "formatted \(fmt.map { $0.unicodeScalars.map { $0.value > 127 ? String(format: "\\u{%x}", $0.value) : String($0) }.joined() })")
            return "en/fr/ru bundle, preferred localization, plurals \(got.joined(separator: ", ")), ICU formats"
        })

        // MARK: notifications
        #if !os(tvOS)   // tvOS has no notification categories, actions or attachments (badges only)
        c.append(check("UserNotifications", "categories-actions-attachment-delivered", timeout: 180) {
            let nc = UNUserNotificationCenter.current()
            let granted = try await more2Stage("requestAuthorization", 100) { try await nc.requestAuthorization(options: [.alert, .sound, .badge, .provisional]) }
            try expect(granted, "authorization refused")
            let reply = UNTextInputNotificationAction(identifier: "reply", title: "Reply", options: [], textInputButtonTitle: "Send", textInputPlaceholder: "…")
            let like = UNNotificationAction(identifier: "like", title: "Like", options: [.foreground], icon: UNNotificationActionIcon(systemImageName: "heart"))
            #if os(watchOS)   // no hidden-previews placeholder on watchOS
            let cat = UNNotificationCategory(identifier: "sdkcov.msg", actions: [like, reply], intentIdentifiers: [], options: [.customDismissAction])
            #else
            let cat = UNNotificationCategory(identifier: "sdkcov.msg", actions: [like, reply], intentIdentifiers: [], hiddenPreviewsBodyPlaceholder: "hidden", options: [.customDismissAction])
            #endif
            nc.setNotificationCategories([cat])
            var cats: Set<UNNotificationCategory> = []
            for _ in 0..<20 { cats = await nc.notificationCategories(); if cats.contains(where: { $0.identifier == "sdkcov.msg" }) { break }; try await Task.sleep(for: .milliseconds(100)) }
            guard let back = cats.first(where: { $0.identifier == "sdkcov.msg" }) else { throw Fail("categories back: \(cats.map(\.identifier))") }
            try expect(back.actions.map(\.identifier) == ["like", "reply"] && back.actions.last is UNTextInputNotificationAction && back.options.contains(.customDismissAction), "category \(back.actions.map(\.identifier)) \(back.options)")
            // a notification with an image attachment; the attachment file moves into the notification store
            let f = try more2Dir("notif").appendingPathComponent("att.png")
            let ctx = bitmap(64, 64); ctx.setFillColor(CGColor(red: 0, green: 0.5, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            try encode(ctx.makeImage()!, .png).write(to: f)
            let att = try UNNotificationAttachment(identifier: "img", url: f, options: [UNNotificationAttachmentOptionsTypeHintKey: UTType.png.identifier])
            let ct = UNMutableNotificationContent(); ct.title = "sdkcov more2"; ct.body = "with attachment"; ct.categoryIdentifier = "sdkcov.msg"; ct.threadIdentifier = "t1"
            ct.attachments = [att]; ct.userInfo = ["k": "v"]; ct.interruptionLevel = .timeSensitive; ct.relevanceScore = 0.7
            let id = "sdkcov-more2-\(Int(Date().timeIntervalSince1970))"
            func deliver(_ id: String, _ ct: UNNotificationContent) async throws -> UNNotification? {
                // Apple's simulator can refuse adds for a few seconds right after a provisional grant (2003, status
                // Denied), as func:UserNotifications.provisional-deliver-local found: retried, then SKIP
                var addErr: Error?
                for _ in 0..<8 {
                    do { try await more2Stage("add", 20) { try await nc.add(UNNotificationRequest(identifier: id, content: ct, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false))) }; addErr = nil; break }
                    catch { addErr = error; if (error as NSError).code != 2003 { break }; try await Task.sleep(for: .seconds(1)) }
                }
                if let addErr { if (addErr as NSError).code == 2003 { throw Skip("add refused 2003 (Source is not authorized) for 8 s after a provisional grant: Apple's simulator does this too") }; throw addErr }
                for _ in 0..<60 { if let n = await nc.deliveredNotifications().first(where: { $0.request.identifier == id }) { return n }; try await Task.sleep(for: .milliseconds(250)) }
                return nil
            }
            // foreground: the delegate presents them (in the list), as an app does to see them while active
            let dlg = M2NotifDelegate(); let oldDlg = nc.delegate; nc.delegate = dlg
            defer { nc.delegate = oldDlg }
            let plain = UNMutableNotificationContent(); plain.title = "sdkcov more2 plain"
            let pn = try await deliver(id + "-plain", plain)
            nc.removeDeliveredNotifications(withIdentifiers: [id + "-plain"])
            let got = try await deliver(id, ct)
            let pend = await nc.pendingNotificationRequests().map(\.identifier)
            guard let n = got else { throw Fail("with attachment: not delivered in 15 s (plain one delivered \(pn != nil); pending \(pend); attachment file still at its path \(FileManager.default.fileExists(atPath: f.path)))") }
            try expect(pn != nil, "a plain notification was not delivered in 15 s")
            nc.removeDeliveredNotifications(withIdentifiers: [id])
            let a = n.request.content.attachments.first
            try expect(a?.identifier == "img" && a?.type == UTType.png.identifier && n.request.content.categoryIdentifier == "sdkcov.msg" && n.request.content.threadIdentifier == "t1" && (n.request.content.userInfo["k"] as? String) == "v", "delivered content: attachment \(String(describing: a)) category \(n.request.content.categoryIdentifier)")
            try expect(!FileManager.default.fileExists(atPath: f.path), "the attachment file stays where it was (should move into the store)")
            #if os(watchOS)   // watchOS apps have no badge
            nc.setNotificationCategories([])
            return "category with text input round trip, attachment moved into the store, delivered"
            #else
            try await nc.setBadgeCount(2); try await nc.setBadgeCount(0)
            nc.setNotificationCategories([])
            return "category with text input round trip, attachment moved into the store, delivered, badge"
            #endif
        })

        #endif

        // MARK: Core Data
        c.append(check("CoreData", "batch-insert-update-delete-history-frc", timeout: 60) {
            let dir = try more2Dir("coredata")
            let pc = NSPersistentContainer(name: "M2", managedObjectModel: m2Model())
            let d = NSPersistentStoreDescription(url: dir.appendingPathComponent("m2.sqlite"))
            d.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
            d.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
            pc.persistentStoreDescriptions = [d]
            var le: Error?; pc.loadPersistentStores { _, e in le = e }
            if let le { throw le }
            let view = pc.viewContext; view.automaticallyMergesChangesFromParent = true
            // batch insert 3000 rows from a background context
            let bg = pc.newBackgroundContext()
            let inserted: Int = try await bg.perform {
                var i = 0
                let req = NSBatchInsertRequest(entityName: "Item") { (o: NSManagedObject) -> Bool in
                    if i == 3000 { return true }
                    o.setValue("item \(i)", forKey: "name"); o.setValue(Int64(i), forKey: "value"); o.setValue(["a", "b", "c"][i % 3], forKey: "group"); i += 1
                    return false
                }
                req.resultType = .count
                return (try bg.execute(req) as? NSBatchInsertResult)?.result as? Int ?? -1
            }
            try expect(inserted == 3000, "batch insert \(inserted)")
            // aggregate sum through a dictionary fetch with an expression
            let sum: Int64 = try await view.perform {
                let f = NSFetchRequest<NSDictionary>(entityName: "Item"); f.resultType = .dictionaryResultType
                let e = NSExpressionDescription(); e.name = "total"; e.expression = NSExpression(forFunction: "sum:", arguments: [NSExpression(forKeyPath: "value")]); e.expressionResultType = .integer64AttributeType
                f.propertiesToFetch = [e]
                return (try view.fetch(f).first?["total"] as? Int64) ?? -1
            }
            try expect(sum == 4_498_500, "sum \(sum)")
            // fetched results controller: sections by group, sorted
            let frcInfo: (Int, [Int], String) = try await view.perform {
                let f = NSFetchRequest<NSManagedObject>(entityName: "Item"); f.sortDescriptors = [NSSortDescriptor(key: "group", ascending: true), NSSortDescriptor(key: "value", ascending: false)]
                f.fetchBatchSize = 50
                let frc = NSFetchedResultsController(fetchRequest: f, managedObjectContext: view, sectionNameKeyPath: "group", cacheName: nil)
                try frc.performFetch()
                let secs = frc.sections ?? []
                return (secs.count, secs.map(\.numberOfObjects), (frc.object(at: IndexPath(row: 0, section: 1)).value(forKey: "name") as? String) ?? "")
            }
            try expect(frcInfo.0 == 3 && frcInfo.1 == [1000, 1000, 1000] && frcInfo.2 == "item 2998", "FRC sections \(frcInfo)")
            // batch update + batch delete with object IDs merged into the view context
            let upd: Int = try await bg.perform {
                let u = NSBatchUpdateRequest(entityName: "Item"); u.predicate = NSPredicate(format: "group == %@", "b"); u.propertiesToUpdate = ["group": "B"]; u.resultType = .updatedObjectsCountResultType
                return (try bg.execute(u) as? NSBatchUpdateResult)?.result as? Int ?? -1
            }
            let del: Int = try await bg.perform {
                let fr = NSFetchRequest<NSFetchRequestResult>(entityName: "Item"); fr.predicate = NSPredicate(format: "value < 500")
                let r = NSBatchDeleteRequest(fetchRequest: fr)
                r.resultType = .resultTypeObjectIDs
                let ids = ((try bg.execute(r) as? NSBatchDeleteResult)?.result as? [NSManagedObjectID]) ?? []
                NSManagedObjectContext.mergeChanges(fromRemoteContextSave: [NSDeletedObjectsKey: ids], into: [view])
                return ids.count
            }
            let (left, bigB): (Int, Int) = try await view.perform {
                (try view.count(for: NSFetchRequest<NSManagedObject>(entityName: "Item")),
                 try view.count(for: { let f = NSFetchRequest<NSManagedObject>(entityName: "Item"); f.predicate = NSPredicate(format: "group == 'B'"); return f }()))
            }
            try expect(upd == 1000 && del == 500 && left == 2500 && bigB == 833, "update \(upd), delete \(del), left \(left), B \(bigB)")
            // a regular save on a child context, then the persistent history lists all transactions
            try await bg.perform { let o = NSEntityDescription.insertNewObject(forEntityName: "Item", into: bg); o.setValue("saved", forKey: "name"); o.setValue(Int64(-1), forKey: "value"); try bg.save() }
            let txs: Int = try await bg.perform {
                let r = NSPersistentHistoryChangeRequest.fetchHistory(after: .distantPast); r.resultType = .transactionsAndChanges
                return ((try bg.execute(r) as? NSPersistentHistoryResult)?.result as? [NSPersistentHistoryTransaction])?.count ?? -1
            }
            try expect(txs >= 4, "history transactions \(txs)")
            let seen: Int = await view.perform { (try? view.count(for: { let f = NSFetchRequest<NSManagedObject>(entityName: "Item"); f.predicate = NSPredicate(format: "name == 'saved'"); return f }())) ?? 0 }
            try expect(seen == 1, "background save merged into the view context: \(seen)")
            return "batch insert 3000, sum \(sum), FRC 3 sections, batch update 1000 / delete 500 merged, \(txs) history transactions"
        })
        return c
    }
}
