// sdkcov P6: WebKit depth on iOS/iPadOS and visionOS against a loopback HTTP server (More2HTTP): navigation delegate
// call order incl. redirects and cancelled navigations, WKUIDelegate JavaScript panels and window.open, content rule
// lists blocking loads, WKDownload to a file, find-in-page, website data records; the SwiftUI WebView / WebPage API on
// visionOS (iOS has it in More_iOS.swift). Verified on Apple's simulator (ref-mac.sh).
import Foundation
import Synchronization
import SwiftUI
#if os(iOS) || os(visionOS)
import UIKit
import WebKit
#endif
#if os(visionOS)
import _WebKit_SwiftUI
#endif

#if os(iOS) || os(visionOS)
@MainActor final class P6Web: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    var wv: WKWebView!
    var close: () -> Void = {}
    let log = P6Log()
    var nav: CheckedContinuation<Void, Error>?
    var cancelPaths: Set<String> = []
    var downloadPaths: Set<String> = []
    var downloadDir: URL?
    var downloaded: URL?
    var downloadDone: String?
    var confirmAnswer = true, promptAnswer = "from native"
    var opened: WKWebView?
    init(store: WKWebsiteDataStore = .nonPersistent()) throws {
        super.init()
        let cfg = WKWebViewConfiguration(); cfg.websiteDataStore = store
        wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 360, height: 600), configuration: cfg)
        wv.navigationDelegate = self; wv.uiDelegate = self
        let vc = UIViewController(); vc.view.backgroundColor = .white; vc.view.addSubview(wv)
        let (_, c) = try p6Show(vc); close = c
    }
    func load(_ go: () -> Void) async throws { try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in nav = k; go() } }
    func js(_ s: String) async throws -> Any? { try await wv.evaluateJavaScript(s) }
    // navigation delegate
    func webView(_ w: WKWebView, decidePolicyFor a: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let p = a.request.url?.path ?? ""
        log.add("action \(p)")
        if cancelPaths.contains(p) { decisionHandler(.cancel); nav?.resume(); nav = nil; return }
        decisionHandler(.allow)
    }
    func webView(_ w: WKWebView, decidePolicyFor r: WKNavigationResponse, decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        let p = r.response.url?.path ?? ""
        log.add("response \(p) \((r.response as? HTTPURLResponse)?.statusCode ?? 0)")
        decisionHandler(downloadPaths.contains(p) ? .download : .allow)
    }
    func webView(_ w: WKWebView, didStartProvisionalNavigation n: WKNavigation!) { log.add("start") }
    func webView(_ w: WKWebView, didReceiveServerRedirectForProvisionalNavigation n: WKNavigation!) { log.add("redirect") }
    func webView(_ w: WKWebView, didCommit n: WKNavigation!) { log.add("commit") }
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) { log.add("finish"); nav?.resume(); nav = nil }
    func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { log.add("fail \((e as NSError).code)"); nav?.resume(throwing: e); nav = nil }
    func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) {
        log.add("failProvisional \((e as NSError).code)")
        if downloadDone != nil || downloaded != nil || (e as NSError).code == 102 { nav?.resume(); nav = nil } else { nav?.resume(throwing: e); nav = nil }
    }
    func webView(_ w: WKWebView, navigationResponse r: WKNavigationResponse, didBecome d: WKDownload) { log.add("becameDownload"); d.delegate = self; nav?.resume(); nav = nil }
    // UI delegate
    func webView(_ w: WKWebView, runJavaScriptAlertPanelWithMessage m: String, initiatedByFrame f: WKFrameInfo) async { log.add("alert \(m)") }
    func webView(_ w: WKWebView, runJavaScriptConfirmPanelWithMessage m: String, initiatedByFrame f: WKFrameInfo) async -> Bool { log.add("confirm \(m)"); return confirmAnswer }
    func webView(_ w: WKWebView, runJavaScriptTextInputPanelWithPrompt p: String, defaultText: String?, initiatedByFrame f: WKFrameInfo) async -> String? { log.add("prompt \(p) \(defaultText ?? "")"); return promptAnswer }
    func webView(_ w: WKWebView, createWebViewWith cfg: WKWebViewConfiguration, for a: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        log.add("createWebView \(a.request.url?.path ?? "")")
        let o = WKWebView(frame: CGRect(x: 0, y: 0, width: 200, height: 200), configuration: cfg); opened = o; return o
    }
    func webViewDidClose(_ w: WKWebView) { log.add("didClose") }
    // download delegate
    func download(_ d: WKDownload, decideDestinationUsing r: URLResponse, suggestedFilename: String) async -> URL? {
        log.add("destination \(suggestedFilename)")
        let u = (downloadDir ?? FileManager.default.temporaryDirectory).appendingPathComponent(suggestedFilename)
        try? FileManager.default.removeItem(at: u); downloaded = u; return u
    }
    func downloadDidFinish(_ d: WKDownload) { log.add("downloadFinish"); downloadDone = "ok" }
    func download(_ d: WKDownload, didFailWithError e: Error, resumeData: Data?) { log.add("downloadFail \((e as NSError).code)"); downloadDone = "error \((e as NSError).code)" }
    func teardown() { wv.stopLoading(); wv.removeFromSuperview(); close() }
}

/// the loopback site the WebKit checks load
func p6Site() throws -> More2HTTP {
    let ctx = bitmap(7, 5); ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 7, height: 5))
    let png = try encode(ctx.makeImage()!, .png)
    let file = Data((0..<20_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
    return try More2HTTP { r in
        switch r.path {
        case "/": return .text("<html><head><title>p6 home</title></head><body><p>needle in a haystack, another needle</p></body></html>", type: "text/html")
        case "/redirect": return More2Resp("302 Found", [("Location", "/")])
        case "/blocked": return .text("<html><body>should not load</body></html>", type: "text/html")
        case "/images": return .text("<html><body><img id=a src='/ok.png'><img id=b src='/ads/banner.png'><script>window.loaded = 0; for (const i of document.images) i.onload = i.onerror = () => window.loaded++;</script></body></html>", type: "text/html")
        case "/ok.png", "/ads/banner.png": return More2Resp("200 OK", [("Content-Type", "image/png")], png)
        case "/file.bin": return More2Resp("200 OK", [("Content-Type", "application/octet-stream"), ("Content-Disposition", "attachment; filename=\"p6-file.bin\"")], file)
        case "/store": return .text("<html><body><script>localStorage.setItem('k', 'v'); document.cookie = 'c=1; max-age=600';</script></body></html>", type: "text/html")
        case "/popup": return .text("<html><head><title>popup</title></head><body>popup</body></html>", type: "text/html")
        default: return More2Resp("404 Not Found")
        }
    }
}
#endif

extension Registry {
    static var p6_web: [Check] {
        var c: [Check] = []
        #if os(iOS) || os(visionOS)
        c.append(check("WebKit", "navigation-delegate-order-ui-panels", timeout: 240) {
            let t0 = Date(); var stages: [String] = []
            func stage(_ n: String) { stages.append("\(n) \(String(format: "%.1f", Date().timeIntervalSince(t0)))") }
            let srv = try p6Site(); _ = try await srv.start(); defer { srv.stop() }
            let w = try await onMain { try P6Web() }
            defer { Task { @MainActor in w.teardown() } }
            // a plain load: action -> start -> response -> commit -> finish
            try await p6A { () async throws in try await w.load { w.wv.load(URLRequest(url: srv.url("/"))) } }
            let plain = w.log.all; w.log.clear(); stage("load")
            try expect(plain == ["action /", "start", "response / 200", "commit", "finish"], "load order \(plain)")
            _ = await p6Wait(3) { w.wv.title == "p6 home" }   // (the title can land just after didFinish)
            let title = await onMain { w.wv.title }
            try expect(title == "p6 home", "title \(String(describing: title))")
            // a server redirect
            try await p6A { () async throws in try await w.load { w.wv.load(URLRequest(url: srv.url("/redirect"))) } }
            let redir = w.log.all; w.log.clear(); stage("redirect")
            try expect(redir.first == "action /redirect" && redir.contains("redirect") && redir.contains("action /") && redir.last == "finish" && redir.contains("response / 200"), "redirect order \(redir)")
            let u = await onMain { w.wv.url?.path }
            try expect(u == "/", "url after redirect \(String(describing: u))")
            // a cancelled navigation goes nowhere
            await onMain { w.cancelPaths = ["/blocked"] }
            try await p6A { () async throws in try await w.load { w.wv.load(URLRequest(url: srv.url("/blocked"))) } }
            try await Task.sleep(for: .milliseconds(300))
            let canc = w.log.all; w.log.clear(); stage("cancel")
            let reqs = srv.requests.withLock { $0 }
            try expect(canc == ["action /blocked"] && !reqs.contains("GET /blocked"), "cancelled: \(canc), server saw \(reqs)")
            // JavaScript panels go to the UI delegate; answers come back to the page
            _ = try await p6A { () async throws -> Any? in try await w.js("alert('hi from js'); 1") }
            let conf = try await p6A { () async throws -> Any? in try await w.js("confirm('sure?')") }
            let prm = try await p6A { () async throws -> Any? in try await w.js("prompt('name?', 'def')") }
            stage("panels"); await onMain { w.confirmAnswer = false }
            let conf2 = try await p6A { () async throws -> Any? in try await w.js("confirm('again?')") }
            try expect((conf as? Bool) == true && (conf2 as? Bool) == false && (prm as? String) == "from native", "panel answers \(String(describing: conf)) \(String(describing: conf2)) \(String(describing: prm))")
            // window.open asks the UI delegate for a web view, which loads the page
            await onMain { w.wv.configuration.preferences.javaScriptCanOpenWindowsAutomatically = true }
            _ = try await p6A { () async throws -> Any? in try await w.js("window.open('/popup'); 1") }
            let opened = await p6Wait(10) { w.opened?.title == "popup" }
            let panels = w.log.all; stage("popup")
            try expect(panels.starts(with: ["alert hi from js", "confirm sure?", "prompt name? def", "confirm again?"]) && panels.contains("createWebView /popup") && opened, "UI delegate \(panels), popup loaded \(opened)")
            return "load \(plain.count) callbacks in order, redirect, cancel, panels \(panels.count), window.open; s: \(stages.joined(separator: " "))"
        })
        c.append(check("WebKit", "content-rules-download-find-data-store", timeout: 200) {
            let t0 = Date(); var stages: [String] = []
            func stage(_ n: String) { stages.append("\(n) \(String(format: "%.1f", Date().timeIntervalSince(t0)))") }
            let srv = try p6Site(); _ = try await srv.start(); defer { srv.stop() }
            // content rule list: block anything under /ads/
            let rules = #"[{"trigger":{"url-filter":".*/ads/.*"},"action":{"type":"block"}}]"#
            let store = WKContentRuleListStore.default()!
            let list = try await p6A { () async throws -> WKContentRuleList? in try await store.compileContentRuleList(forIdentifier: "p6-block-ads", encodedContentRuleList: rules) }
            guard let list else { throw Fail("compile returned nil") }
            let ids = try await p6A { () async throws -> [String]? in await store.availableIdentifiers() } ?? []
            let w = try await onMain { try P6Web() }
            defer { Task { @MainActor in w.teardown() } }
            await onMain { w.wv.configuration.userContentController.add(list) }
            try await p6A { () async throws in try await w.load { w.wv.load(URLRequest(url: srv.url("/images"))) } }
            for _ in 0..<50 {   // both images settle (one loads, one is blocked: onerror)
                if let n = try? await p6A({ () async throws -> Any? in try await w.js("window.loaded") }) as? Int, n >= 2 { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            let widths = try await p6A { () async throws -> Any? in try await w.js("[document.getElementById('a').naturalWidth, document.getElementById('b').naturalWidth, window.loaded]") } as? [Int]
            let reqs = srv.requests.withLock { $0 }
            try expect(widths?.prefix(2) == [7, 0] && reqs.contains("GET /ok.png") && !reqs.contains("GET /ads/banner.png") && ids.contains("p6-block-ads"),
                       "rule list: widths \(String(describing: widths)), requests \(reqs), ids \(ids)")
            try await p6A { () async throws in try await store.removeContentRuleList(forIdentifier: "p6-block-ads") }
            stage("rules")
            // find in page
            try await p6A { () async throws in try await w.load { w.wv.load(URLRequest(url: srv.url("/"))) } }
            let found = try await p6A { () async throws -> Bool in try await w.wv.find("needle").matchFound }
            let notFound = try await p6A { () async throws -> Bool in try await w.wv.find("x86sim-absent").matchFound }
            try expect(found && !notFound, "find: needle \(found), absent \(notFound)")
            stage("find")
            // a download: the response policy turns the navigation into a WKDownload written where the delegate says
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("p6dl", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // (from a second server: a fresh connection, not one WebKit keeps alive from the pages above)
            let srv2 = try p6Site(); _ = try await srv2.start(); defer { srv2.stop() }
            await onMain { w.downloadPaths = ["/file.bin"]; w.downloadDir = dir; w.log.clear() }
            do { try await p6A { () async throws in try await w.load { w.wv.load(URLRequest(url: srv2.url("/file.bin"))) } } }
            catch { throw Fail("download navigation: \(p8Err(error)); server saw \(srv2.requests.withLock { $0 }); delegate \(w.log.all); s: \(stages)") }
            try await expect(p6Wait(20) { w.downloadDone != nil }, "download never finished: \(w.log.all)")
            let (dl, st) = await onMain { (w.downloaded, w.downloadDone) }
            let bytes = dl.flatMap { try? Data(contentsOf: $0) } ?? Data()
            try expect(st == "ok" && bytes.count == 20_000 && bytes[1] == 31 && dl?.lastPathComponent == "p6-file.bin", "download \(String(describing: st)) \(bytes.count) B at \(String(describing: dl?.lastPathComponent)); \(w.log.all)")
            let dlEvents = w.log.all; stage("download")
            // website data: a page stores localStorage + a cookie; the store lists and removes the records
            let ds = await onMain { w.wv.configuration.websiteDataStore }
            try await p6A { () async throws in try await w.load { w.wv.load(URLRequest(url: srv.url("/store"))) } }
            try await Task.sleep(for: .milliseconds(500))
            let types = WKWebsiteDataStore.allWebsiteDataTypes()
            let recs = await p6A2 { await ds.dataRecords(ofTypes: types) }
            let names = recs.map(\.displayName)
            let kinds = recs.flatMap(\.dataTypes)
            await p6A2 { await ds.removeData(ofTypes: types, for: recs) }
            let after = await p6A2 { await ds.dataRecords(ofTypes: types) }
            try expect(names.contains("127.0.0.1") && kinds.contains(WKWebsiteDataTypeLocalStorage) && after.isEmpty, "records \(names) \(Set(kinds)), after removal \(after.count)")
            stage("records")
            return "rule list blocked /ads/, find, download \(dlEvents.joined(separator: ",")), data records \(Set(kinds).count) types removed; s: \(stages.joined(separator: " "))"
        })
        #endif
        #if os(visionOS)
        c.append(check("_WebKit_SwiftUI", "webpage-webview-javascript", timeout: 120) {
            let page = await onMain { WebPage() }
            let close = try await onMain { try p6HostSwiftUI(WebView(page)) }
            defer { Task { @MainActor in close() } }
            var events: [String] = []
            let seq = await MainActor.run { page.load(html: "<html><head><title>sdkcov</title></head><body><p id=p>x86</p></body></html>") }
            for try await e in seq { events.append("\(e)") }
            let title = await onMain { page.title }
            try expect(title == "sdkcov", "title \(title) after \(events)")
            let r = try await Task { @MainActor in try await page.callJavaScript("return document.getElementById('p').textContent + a * 2", arguments: ["a": 21]) }.value
            try expect(r as? String == "x8642", "callJavaScript \(String(describing: r))")
            return "events \(events.joined(separator: ",")), JS \(r!)"
        })
        #endif
        return c
    }
}
/// run a non-throwing async body on the main actor
func p6A2<T>(_ f: @escaping @MainActor () async -> T) async -> T { await Task { @MainActor in await f() }.value }
