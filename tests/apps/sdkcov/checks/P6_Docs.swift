// sdkcov P6: documents and small UI frameworks. PDFKit (PDFView paging by pixels, page overlays, thumbnails, encryption,
// outlines, form widgets), QuickLook (QLPreviewController data source + navigation) and its SwiftUI modifier,
// LinkPresentation (metadata from a loopback page's Open Graph tags, LPLinkView), Charts (bar / sector marks by pixels),
// DeveloperToolsSupport, the dataDetection modifier, MessageUI and ClockKit answers in the simulator, NowPlayingView.
// Verified on Apple's simulator (ref-mac.sh).
import Foundation
import Synchronization
import SwiftUI
import UniformTypeIdentifiers
import ImageIO
#if canImport(UIKit)
import UIKit
#endif
#if canImport(PDFKit)
import PDFKit
#endif
#if canImport(QuickLook)
import QuickLook
#endif
#if canImport(_QuickLook_SwiftUI)
import _QuickLook_SwiftUI
#endif
#if canImport(LinkPresentation)
import LinkPresentation
#endif
#if canImport(Charts)
import Charts
#endif
#if canImport(DeveloperToolsSupport)
import DeveloperToolsSupport
#endif
#if canImport(_DataDetection_SwiftUI)
import _DataDetection_SwiftUI
#endif
#if canImport(MessageUI)
import MessageUI
#endif
#if canImport(ClockKit)
import ClockKit
#endif
#if os(watchOS)
import _WatchKit_SwiftUI
import WatchKit
#endif

/// an N-page PDF (CoreGraphics), page i filled with colours[i] and labelled "page i"
func p6PDF(_ colours: [CGColor], size: CGSize = CGSize(width: 200, height: 300)) -> Data {
    let d = NSMutableData()
    var box = CGRect(origin: .zero, size: size)
    let ctx = CGContext(consumer: CGDataConsumer(data: d)!, mediaBox: &box, nil)!
    for (i, c) in colours.enumerated() {
        ctx.beginPDFPage(nil)
        ctx.setFillColor(c); ctx.fill(box)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "page \(i)", attributes: [kCTFontAttributeName as NSAttributedString.Key: CTFontCreateWithName("Helvetica" as CFString, 18, nil)]))
        ctx.textPosition = CGPoint(x: 20, y: 20); CTLineDraw(line, ctx)
        ctx.endPDFPage()
    }
    ctx.closePDF()
    return d as Data
}
let p6CGRed = CGColor(red: 1, green: 0, blue: 0, alpha: 1), p6CGGreen = CGColor(red: 0, green: 1, blue: 0, alpha: 1), p6CGBlue = CGColor(red: 0, green: 0, blue: 1, alpha: 1)

#if canImport(PDFKit) && !os(watchOS)
final class P6Overlay: NSObject, PDFPageOverlayViewProvider {
    var asked: [Int] = []
    func pdfView(_ v: PDFView, overlayViewFor page: PDFPage) -> UIView? {
        asked.append(page.document?.index(for: page) ?? -1)
        let o = UIView(); o.backgroundColor = .clear; o.accessibilityIdentifier = "p6overlay"; return o
    }
}
#endif
#if canImport(QuickLook) && (os(iOS) || os(visionOS))
final class P6QLSource: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
    let urls: [URL]; let log: P6Log
    init(_ u: [URL], _ l: P6Log) { urls = u; log = l }
    func numberOfPreviewItems(in c: QLPreviewController) -> Int { log.add("count"); return urls.count }
    func previewController(_ c: QLPreviewController, previewItemAt i: Int) -> QLPreviewItem { log.add("item\(i)"); return urls[i] as NSURL }
    func previewControllerWillDismiss(_ c: QLPreviewController) { log.add("willDismiss") }
    func previewControllerDidDismiss(_ c: QLPreviewController) { log.add("didDismiss") }
}
@Observable final class P6QLModel { var url: URL? = nil }
private struct P6QLRoot: View { @Bindable var m: P6QLModel; var body: some View { Color.white.quickLookPreview($m.url) } }
#endif

extension Registry {
    static var p6_docs: [Check] {
        var c: [Check] = []
        #if canImport(PDFKit) && os(tvOS)
        c.append(check("PDFKit", "pdfview-paging-pixels-overlay-thumbnails", timeout: 10) {
            // Apple's tvOS 27.2 simulator: -[PDFView initWithFrame:] raises (PDFViewController sends -[UIEditMenuInteraction
            // initWithDelegate:], which tvOS does not have): not callable from a check
            throw Skip("PDFView init raises on tvOS (UIEditMenuInteraction unavailable), Apple's simulator too")
        })
        #endif
        #if canImport(PDFKit) && !os(watchOS) && !os(tvOS)
        // MARK: PDFKit: PDFView paging, overlays, thumbnails
        c.append(check("PDFKit", "pdfview-paging-pixels-overlay-thumbnails", timeout: 40) {
            let data = p6PDF([p6CGRed, p6CGGreen, p6CGBlue])
            return try await p6A { () async throws -> String in
                guard let doc = PDFDocument(data: data) else { throw Fail("PDFDocument") }
                let pv = PDFView(frame: CGRect(x: 0, y: 0, width: 300, height: 450))
                let ov = P6Overlay(); pv.pageOverlayViewProvider = ov
                pv.displayMode = .singlePage; pv.displayDirection = .vertical; pv.autoScales = true; pv.backgroundColor = .white
                pv.document = doc
                let thumbs = PDFThumbnailView(frame: CGRect(x: 0, y: 460, width: 300, height: 80)); thumbs.pdfView = pv
                thumbs.layoutMode = .horizontal; thumbs.thumbnailSize = CGSize(width: 40, height: 60)
                let vc = UIViewController(); vc.view.backgroundColor = .white; vc.view.addSubview(pv); vc.view.addSubview(thumbs)
                let (_, close) = try p6Show(vc); defer { close(); _ = ov }
                pv.layoutDocumentView()
                try await Task.sleep(for: .milliseconds(500))
                @MainActor func centre() -> [Int] { guard let i = p6Snap(pv) else { return [] }; return p6Px(i, i.width / 2, i.height / 2) }
                let p0 = centre()
                pv.go(to: doc.page(at: 1)!); pv.layoutDocumentView()
                try await Task.sleep(for: .milliseconds(400))
                let i1 = pv.currentPage.map { doc.index(for: $0) }, p1 = centre()
                try expect(pv.canGoToNextPage, "canGoToNextPage on page 1")
                pv.goToNextPage(nil); pv.layoutDocumentView()
                try await Task.sleep(for: .milliseconds(400))
                let i2 = pv.currentPage.map { doc.index(for: $0) }, p2 = centre()
                try expect(i1 == 1 && i2 == 2 && !pv.canGoToNextPage, "current page \(String(describing: i1)) then \(String(describing: i2))")
                // (Apple: device-RGB page colours come out colour-managed: red 255,38,0, green 0,249,0, blue 4,51,255)
                try expect(p6Near(p0, [255, 38, 0], 24) && p6Near(p1, [0, 249, 0], 24) && p6Near(p2, [4, 51, 255], 24), "page pixels \(p0) \(p1) \(p2)")
                // scale: autoScales fits the 200 pt page width into 300 pt
                try expect(abs(pv.scaleFactor - pv.scaleFactorForSizeToFit) < 0.01 && pv.scaleFactor > 1.2, "scale \(pv.scaleFactor) fit \(pv.scaleFactorForSizeToFit)")
                // view <-> page coordinates
                let pt = pv.convert(CGPoint(x: 100, y: 150), from: doc.page(at: 2)!)
                let back = pv.convert(pt, to: doc.page(at: 2)!)
                try expect(abs(back.x - 100) < 0.5 && abs(back.y - 150) < 0.5 && pv.page(for: pt, nearest: false) == doc.page(at: 2), "page coordinates \(pt) -> \(back)")
                // selection by string
                let sel = doc.findString("page 2", withOptions: .caseInsensitive).first
                pv.setCurrentSelection(sel, animate: false)
                try expect(pv.currentSelection?.string == "page 2", "selection \(String(describing: pv.currentSelection?.string))")
                let overlays = ov.asked
                try expect(!overlays.isEmpty, "page overlay provider never asked")
                thumbs.layoutIfNeeded()
                return "pages red/green/blue on screen, scale \(String(format: "%.2f", pv.scaleFactor)), overlays asked for \(overlays), thumbnails \(p6Find(thumbs, UIView.self).count - 1) views"
            }
        })
        #endif
        #if canImport(PDFKit)
        // MARK: PDFKit: encryption, outline, form widgets round trips
        c.append(check("PDFKit", "encrypt-outline-form-widgets-roundtrip", timeout: 40) {
            guard let doc = PDFDocument(data: p6PDF([p6CGRed, p6CGGreen, p6CGBlue])) else { throw Fail("PDFDocument") }
            // outline: two entries pointing at pages 0 and 2
            let root = PDFOutline(); doc.outlineRoot = root
            for (i, (label, page)) in [("Intro", 0), ("End", 2)].enumerated() {
                let o = PDFOutline(); o.label = label; o.destination = PDFDestination(page: doc.page(at: page)!, at: CGPoint(x: 0, y: 300))
                root.insertChild(o, at: i)
            }
            let mem = doc.outlineRoot.map { r in (0..<r.numberOfChildren).compactMap { r.child(at: $0)?.label } } ?? []
            let memDest = doc.outlineRoot?.child(at: 1)?.destination?.page.map { doc.index(for: $0) }
            try expect(mem == ["Intro", "End"] && memDest == 2 && doc.outlineRoot?.child(at: 0)?.parent === doc.outlineRoot, "outline in memory \(mem) -> \(String(describing: memDest))")
            // (written out, the outline does not come back, on Apple's simulator too: counted, not asserted)
            let plainOutline = PDFDocument(data: doc.dataRepresentation() ?? Data())?.outlineRoot?.numberOfChildren ?? -1
            // form widgets on page 0: a text field and a checkbox
            let p0 = doc.page(at: 0)!
            let tf = PDFAnnotation(bounds: CGRect(x: 20, y: 200, width: 150, height: 24), forType: .widget, withProperties: nil)
            tf.widgetFieldType = .text; tf.fieldName = "name"; tf.widgetStringValue = "x86sim"
            let cb = PDFAnnotation(bounds: CGRect(x: 20, y: 160, width: 20, height: 20), forType: .widget, withProperties: nil)
            cb.widgetFieldType = .button; cb.widgetControlType = .checkBoxControl; cb.fieldName = "agree"; cb.buttonWidgetState = .onState
            let note = PDFAnnotation(bounds: CGRect(x: 100, y: 100, width: 20, height: 20), forType: .text, withProperties: nil); note.contents = "sdkcov note"
            p0.addAnnotation(tf); p0.addAnnotation(cb); p0.addAnnotation(note)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("p6-enc.pdf")
            try? FileManager.default.removeItem(at: url)
            let ok = doc.write(to: url, withOptions: [.userPasswordOption: "user", .ownerPasswordOption: "owner"])
            try expect(ok, "write encrypted")
            guard let back = PDFDocument(url: url) else { throw Fail("reopen") }
            try expect(back.isEncrypted && back.isLocked && back.pageCount == 3, "encrypted \(back.isEncrypted) locked \(back.isLocked) pages \(back.pageCount)")
            let bad = back.unlock(withPassword: "nope"), good = back.unlock(withPassword: "user")
            try expect(!bad && good && !back.isLocked, "unlock bad \(bad) good \(good)")
            let reread = back.outlineRoot?.numberOfChildren ?? -1
            let anns = back.page(at: 0)!.annotations
            let rt = anns.first { $0.fieldName == "name" }, rc = anns.first { $0.fieldName == "agree" }, rn = anns.first { $0.type == "Text" }
            try expect(rt?.widgetStringValue == "x86sim" && rt?.widgetFieldType == .text, "text widget \(String(describing: rt?.widgetStringValue))")
            try expect(rc?.buttonWidgetState == .onState && rc?.widgetControlType == .checkBoxControl, "checkbox \(String(describing: rc?.buttonWidgetState.rawValue))")
            try expect(rn?.contents == "sdkcov note", "note \(String(describing: rn?.contents))")
            // owner password: permissions; text of the unlocked document
            let text = back.page(at: 1)?.string ?? ""
            try expect(text.contains("page 1"), "page 1 text '\(text)'")
            return "AES-encrypted write/unlock, outline in memory (re-read: \(plainOutline) / \(reread) children), text + checkbox widgets + note round trip, \(back.dataRepresentation()?.count ?? 0) B"
        })
        #endif

        #if canImport(QuickLook) && (os(iOS) || os(visionOS))
        // MARK: QuickLook: a two-item preview controller on screen
        c.append(check("QuickLook", "preview-controller-datasource-navigation", timeout: 60) {
            let dir = FileManager.default.temporaryDirectory
            let pdf = dir.appendingPathComponent("p6-ql.pdf"), png = dir.appendingPathComponent("p6-ql.png")
            try p6PDF([p6CGRed, p6CGGreen]).write(to: pdf)
            let ctx = bitmap(64, 48); ctx.setFillColor(p6CGBlue); ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
            try encode(ctx.makeImage()!, .png).write(to: png)
            let log = P6Log()
            return try await p6A { () async throws -> String in
                let root = UIViewController(); root.view.backgroundColor = .white
                let (w, close) = try p6Show(root); defer { close() }
                try await Task.sleep(for: .milliseconds(300))
                let src = P6QLSource([pdf, png], log)
                let q = QLPreviewController(); q.dataSource = src; q.delegate = src
                var shown = false
                root.present(q, animated: true) { shown = true }
                try await expect(p6Wait(30) { shown }, "present: completion never ran, \(log.all)")
                try await expect(p6Wait(10) { log.has("item0") }, "data source never asked: \(log.all)")
                try await Task.sleep(for: .seconds(2))
                let i0 = q.currentPreviewItemIndex, cur0 = (q.currentPreviewItem as? NSURL)?.lastPathComponent
                q.currentPreviewItemIndex = 1
                _ = await p6Wait(5) { log.has("item1") }
                try await Task.sleep(for: .seconds(1))
                let i1 = q.currentPreviewItemIndex, cur1 = (q.currentPreviewItem as? NSURL)?.lastPathComponent
                // the preview is a remote view from the Quick Look extension
                var remote: [String] = []
                func walk(_ v: UIView) { let n = NSStringFromClass(type(of: v)); if n.contains("Remote") || n.hasPrefix("_UIRemote") { remote.append(n) }; v.subviews.forEach(walk) }
                if let qw = q.view.window { walk(qw) }
                let canPDF = QLPreviewController.canPreview(pdf as NSURL), canBogus = QLPreviewController.canPreview(URL(fileURLWithPath: "/nonexistent.zzz") as NSURL)
                var gone = false
                q.dismiss(animated: true) { gone = true }
                _ = await p6Wait(5) { gone }
                _ = w
                try expect(i0 == 0 && cur0 == "p6-ql.pdf" && i1 == 1 && cur1 == "p6-ql.png", "items \(i0) \(String(describing: cur0)) -> \(i1) \(String(describing: cur1))")
                try expect(log.has("count") && canPDF, "count asked \(log.has("count")), canPreview pdf \(canPDF)")
                return "data source \(log.all.joined(separator: ",")), remote views \(Set(remote).sorted()), canPreview bogus \(canBogus)"
            }
        })
        #endif
        #if canImport(_QuickLook_SwiftUI) && (os(iOS) || os(visionOS))
        c.append(check("_QuickLook_SwiftUI", "quicklook-preview-modifier-presents", timeout: 40) {
            let pdf = FileManager.default.temporaryDirectory.appendingPathComponent("p6-qls.pdf")
            try p6PDF([p6CGGreen]).write(to: pdf)
            let m = await onMain { P6QLModel() }
            let close = try await onMain { try p6HostSwiftUI(P6QLRoot(m: m)) }
            defer { Task { @MainActor in close() } }
            try await Task.sleep(for: .milliseconds(500))
            let w = await onMain { p6LastWindow }
            await onMain { m.url = pdf }
            @MainActor func qlViews() -> [String] {
                var out: [String] = []
                func walk(_ v: UIView) { let n = NSStringFromClass(type(of: v)); if n.contains("QL") || n.contains("QuickLook") { out.append(n) }; v.subviews.forEach(walk) }
                p6Presented(w).forEach { walk($0.view) }
                return out
            }
            // SwiftUI presents the preview in its own presentation controller; the Quick Look views are inside it
            let shown = await p6Wait(30) { !p6Presented(w).isEmpty && !qlViews().isEmpty }
            let what = await onMain { p6Presented(w).map { "\(type(of: $0))" } }
            let views = await onMain { Set(qlViews()).sorted() }
            await onMain { m.url = nil }
            let gone = await p6Wait(10) { p6Presented(w).isEmpty }
            try expect(shown && gone, "presented \(what), Quick Look views \(views), dismissed on nil \(gone)")
            return "quickLookPreview: \(what) with \(views.prefix(4)), dismissed when the binding cleared"
        })
        #endif

        #if canImport(LinkPresentation) && canImport(Network)
        // MARK: LinkPresentation: metadata from a loopback page's Open Graph tags; LPLinkView
        c.append(check("LinkPresentation", "loopback-fetch-og-tags-linkview", timeout: 60) {
            let ictx = bitmap(40, 30); ictx.setFillColor(p6CGRed); ictx.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
            let img = try encode(ictx.makeImage()!, .png)
            let cctx = bitmap(16, 16); cctx.setFillColor(p6CGBlue); cctx.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
            let icon = try encode(cctx.makeImage()!, .png)
            let srv = try More2HTTP { r in
                switch r.path {
                case "/page": return .text("""
                    <!doctype html><html><head><title>Fallback title</title>
                    <meta property="og:title" content="SDKCov OG Title"><meta property="og:site_name" content="x86Sim">
                    <meta property="og:image" content="/img.png"><link rel="icon" type="image/png" href="/icon.png">
                    </head><body>hello</body></html>
                    """, type: "text/html; charset=utf-8")
                case "/img.png": return More2Resp("200 OK", [("Content-Type", "image/png")], img)
                case "/icon.png", "/favicon.ico": return More2Resp("200 OK", [("Content-Type", "image/png")], icon)
                default: return More2Resp("404 Not Found")
                }
            }
            _ = try await srv.start(); defer { srv.stop() }
            let u = srv.url("/page")
            // bounded: Apple's simulator now and then never calls back (seen on iOS, watchOS, visionOS 27.2)
            let box = P8Box<Result<LPLinkMetadata, Error>>()
            let p = await onMain { () -> LPMetadataProvider in let p = LPMetadataProvider(); p.timeout = 30; return p }
            await onMain { p.startFetchingMetadata(for: u) { md, e in box.set(md.map { .success($0) } ?? .failure(e ?? Fail("no metadata"))) } }
            guard let r = await box.wait(45) else { await onMain { p.cancel() }; throw Fail("LPMetadataProvider never called back in 45 s (requests \(srv.requests.withLock { $0 }))") }
            let md = try r.get()
            let reqs = srv.requests.withLock { $0 }
            try expect(md.title == "SDKCov OG Title", "title \(String(describing: md.title)) (requests \(reqs))")
            try expect(md.url?.path == "/page" && md.originalURL?.path == "/page", "url \(String(describing: md.url))")
            var imgSize = "none"
            if let ip = md.imageProvider {
                let d: Data? = try? await withCheckedThrowingContinuation { k in
                    _ = ip.loadDataRepresentation(for: .image) { d, e in if let d { k.resume(returning: d) } else { k.resume(throwing: e ?? Fail("no data")) } }
                }
                if let d, let s = CGImageSourceCreateWithData(d as CFData, nil), let ci = CGImageSourceCreateImageAtIndex(s, 0, nil) { imgSize = "\(ci.width)x\(ci.height)" }
            }
            try expect(imgSize == "40x30" && reqs.contains("GET /img.png"), "og:image \(imgSize), requests \(reqs)")
            // the page's icon comes through its own provider (the 16x16 <link rel=icon>), apart from the og:image
            var iconSize = "none"
            if let ip = md.iconProvider {
                let d: Data? = try? await withCheckedThrowingContinuation { k in
                    _ = ip.loadDataRepresentation(for: .image) { d, e in if let d { k.resume(returning: d) } else { k.resume(throwing: e ?? Fail("no data")) } }
                }
                if let d, let s = CGImageSourceCreateWithData(d as CFData, nil), let ci = CGImageSourceCreateImageAtIndex(s, 0, nil) { iconSize = "\(ci.width)x\(ci.height)" }
            }
            try expect(iconSize == "16x16", "icon \(iconSize) (og:image \(imgSize)), requests \(reqs)")
            var view = ""
            #if !os(watchOS)
            view = try await p6A { () async throws -> String in
                let lv = LPLinkView(metadata: md)
                let sz = lv.sizeThatFits(CGSize(width: 300, height: 1000))
                lv.frame = CGRect(origin: CGPoint(x: 10, y: 100), size: sz)
                let vc = UIViewController(); vc.view.backgroundColor = .white; vc.view.addSubview(lv)
                let (_, close) = try p6Show(vc); defer { close() }
                try await Task.sleep(for: .milliseconds(800))
                guard let s = p6Snap(lv) else { throw Fail("snapshot") }
                let ctx = bitmap(s.width, s.height); ctx.draw(s, in: CGRect(x: 0, y: 0, width: s.width, height: s.height))
                var ink = 0, red = 0, n = 0
                for y in stride(from: 0, to: s.height, by: 2) { for x in stride(from: 0, to: s.width, by: 2) {
                    let q = pixel(ctx, x, y); n += 1
                    if q.prefix(3).contains(where: { $0 < 200 }) { ink += 1 }
                    if q[0] > 200 && q[1] < 60 && q[2] < 60 { red += 1 }
                } }
                try expect(sz.width > 100 && sz.height > 40 && ink > n / 20, "link view \(sz) ink \(ink)/\(n)")
                return ", LPLinkView \(Int(sz.width))x\(Int(sz.height)) ink \(ink * 100 / max(n, 1))%, image pixels \(red)"
            }
            #endif
            return "og:title, og:image \(imgSize), requests \(reqs)\(view)"
        })
        #endif

        #if canImport(Charts)
        // MARK: Charts: bar height and pie sectors by pixels
        c.append(check("Charts", "bar-scale-sector-pie-pixels", timeout: 30) {
            try await onMain {
                struct Bar: View {
                    var body: some View {
                        Chart { BarMark(x: .value("k", "a"), y: .value("v", 50)).foregroundStyle(Color(red: 1, green: 0, blue: 0)) }
                            .chartYScale(domain: 0...100).chartXAxis(.hidden).chartYAxis(.hidden).chartLegend(.hidden)
                            .chartPlotStyle { $0.background(Color.white) }
                            .frame(width: 100, height: 200).background(Color.white)
                    }
                }
                struct Pie: View {
                    let data: [(String, Double)] = [("r", 50), ("g", 25), ("b", 25)]
                    var body: some View {
                        Chart(data, id: \.0) { d in SectorMark(angle: .value("v", d.1)).foregroundStyle(by: .value("k", d.0)) }
                            .chartForegroundStyleScale(["r": Color(red: 1, green: 0, blue: 0), "g": Color(red: 0, green: 1, blue: 0), "b": Color(red: 0, green: 0, blue: 1)])
                            .chartLegend(.hidden).frame(width: 200, height: 200).background(Color.white)
                    }
                }
                let rb = ImageRenderer(content: Bar()); rb.scale = 1
                let rp = ImageRenderer(content: Pie()); rp.scale = 1
                guard let b = rb.cgImage, let p = rp.cgImage else { throw Fail("no chart image") }
                // the bar: red below half height, white above
                var top = -1
                for y in 0..<b.height { if p6Near(p6Px(b, 50, y), [255, 0, 0], 30) { top = y; break } }
                let low = p6Px(b, 50, 190)
                try expect(abs(top - 100) <= 3 && p6Near(low, [255, 0, 0], 30), "bar top at y \(top) of 200, bottom \(low)")
                // the pie: 50% red from 12 o'clock clockwise (the right half), then green (bottom left), blue (top left)
                let right = p6Px(p, 150, 100), bl = p6Px(p, 60, 140), tl = p6Px(p, 60, 60), corner = p6Px(p, 2, 2)
                try expect(p6Near(right, [255, 0, 0], 30) && p6Near(bl, [0, 255, 0], 30) && p6Near(tl, [0, 0, 255], 30) && p6Near(corner, [255, 255, 255], 30),
                           "sectors right \(right) bottom-left \(bl) top-left \(tl) corner \(corner)")
                return "bar top y \(top)/200; pie sectors red/green/blue where expected"
            }
        })
        #endif

        #if canImport(DeveloperToolsSupport) && !os(tvOS)   // tvOS: More_tvOS.swift has it
        c.append(check("DeveloperToolsSupport", "design-time-values-library", timeout: 10) {
            let i: Int = DeveloperToolsSupport.__designTimeInteger("#sdkcov.1", fallback: 42)
            let bo: Bool = DeveloperToolsSupport.__designTimeBoolean("#sdkcov.2", fallback: true)
            let s: String = DeveloperToolsSupport.__designTimeString("#sdkcov.3", fallback: "x86")
            let f: Double = DeveloperToolsSupport.__designTimeFloat("#sdkcov.4", fallback: 2.5)
            try expect(i == 42 && bo && s == "x86" && f == 2.5, "design-time fallbacks \(i) \(bo) \(s) \(f)")
            let items = [LibraryItem(Text("sdkcov"), title: "sdkcov text", category: .control)]
            return "fallbacks ok, \(items.count) library item"
        })
        #endif

        #if canImport(_DataDetection_SwiftUI) && !os(tvOS)
        // MARK: dataDetection: detected data in Text is styled as links
        c.append(check("_DataDetection_SwiftUI", "text-data-detection", timeout: 30) {
            struct V: View {
                let detect: Bool
                var body: some View {
                    let t = Text("Call 408-555-0199 or mail test@example.com").font(.system(size: 14)).foregroundStyle(Color.black)
                        .frame(width: 180, height: 80, alignment: .topLeading).background(Color.white)
                    if detect { t.dataDetection(.all) } else { t }
                }
            }
            #if os(watchOS)
            // ImageRenderer draws once, before the asynchronous detection: the Text goes on screen (Runner.overlay) and
            // the window is read back as the screen shows it
            func shot(_ d: Bool) async throws -> CGImage {
                await onMain { Runner.shared.overlay = AnyView(V(detect: d).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)) }
                try? await Task.sleep(for: .seconds(3))   // detection runs asynchronously
                return try await onMain { () throws -> CGImage in defer { Runner.shared.overlay = nil }; return try p6WatchWindowShot() }
            }
            let plain = try await shot(false), det = try await shot(true)
            #else
            func shot(_ d: Bool) async throws -> CGImage {
                try await p6A { () async throws -> CGImage in
                    let hc = UIHostingController(rootView: V(detect: d)); hc.view.frame = CGRect(x: 0, y: 100, width: 180, height: 80)
                    let vc = UIViewController(); vc.view.backgroundColor = .white; vc.addChild(hc); vc.view.addSubview(hc.view)
                    let (_, close) = try p6Show(vc); defer { close() }
                    try await Task.sleep(for: .seconds(2))   // detection runs asynchronously
                    guard let i = p6Snap(hc.view) else { throw Fail("snapshot") }
                    return i
                }
            }
            let plain = try await shot(false), det = try await shot(true)
            #endif
            func colored(_ i: CGImage) -> (Int, Int) {
                let ctx = bitmap(i.width, i.height); ctx.draw(i, in: CGRect(x: 0, y: 0, width: i.width, height: i.height))
                var ink = 0, col = 0
                for y in 0..<i.height { for x in 0..<i.width { let q = pixel(ctx, x, y).map(Int.init)
                    if q.prefix(3).contains(where: { $0 < 180 }) { ink += 1; if q.prefix(3).max()! - q.prefix(3).min()! > 60 { col += 1 } } } }
                return (ink, col)
            }
            let (ink0, col0) = colored(plain), (ink1, col1) = colored(det)
            try expect(ink0 > 50 && ink1 > 50, "plain text ink \(ink0) coloured \(col0)")
            #if os(watchOS)
            // watchOS draws detected data in grey, not tinted (Apple's simulator: the black phone number turns grey, dark
            // pixels in the Text's white box 330 -> 128; the address is grey in both, as a link of the Text's own)
            let (dark0, grey0) = p6DarkGrey(plain), (dark1, grey1) = p6DarkGrey(det)
            try expect(dark0 > 100 && Double(dark1) < Double(dark0) * 0.6 && grey1 > grey0, "on screen: dark / grey pixels \(dark0) / \(grey0) -> \(dark1) / \(grey1) with dataDetection (Apple's simulator: 330 / 813 -> 128 / 891, the phone number turns grey)")
            return "on screen: plain dark / grey \(dark0) / \(grey0); with dataDetection \(dark1) / \(grey1): the phone number drawn as a link"
            #else
            // the detected phone number and address are drawn as tinted links
            try expect(col1 > col0 + 150, "no tinted detections: coloured pixels \(col0) -> \(col1)")
            #endif
            return "plain: ink \(ink0) coloured \(col0); with dataDetection: ink \(ink1) coloured \(col1)"
        })
        #endif

        #if canImport(MessageUI) && (os(iOS) || os(visionOS))
        c.append(check("MessageUI", "simulator-answers-composers", timeout: 20) {
            let mail = MFMailComposeViewController.canSendMail(), text = MFMessageComposeViewController.canSendText()
            let subj = MFMessageComposeViewController.canSendSubject(), att = MFMessageComposeViewController.canSendAttachments()
            let uti = MFMessageComposeViewController.isSupportedAttachmentUTI(UTType.jpeg.identifier)
            // the simulator has no Mail account and no Messages: every capability is off
            try expect(!mail && !text && !subj && !att, "mail \(mail) text \(text) subject \(subj) attachments \(att)")
            return "canSendMail/Text/Subject/Attachments false, jpeg attachment UTI \(uti)"
        })
        #endif

        #if canImport(ClockKit) && os(iOS)
        c.append(check("ClockKit", "watch-face-library-errors", timeout: 30) {
            let lib = CLKWatchFaceLibrary()
            func add(_ u: URL) async -> String {
                await withCheckedContinuation { k in
                    lib.addWatchFace(at: u) { e in k.resume(returning: e.map { "\(($0 as NSError).domain) \(($0 as NSError).code)" } ?? "ok") }
                }
            }
            let web = await add(URL(string: "https://example.com/face.watchface")!)
            let junk = FileManager.default.temporaryDirectory.appendingPathComponent("p6.watchface")
            try Data("not a face".utf8).write(to: junk)
            let bad = await add(junk)
            try expect(web == "\(CLKWatchFaceLibrary.ErrorDomain) 1", "remote URL: \(web)")
            try expect(bad.hasPrefix(CLKWatchFaceLibrary.ErrorDomain), "invalid file: \(bad)")
            return "remote URL -> \(web); junk file -> \(bad)"
        })
        #endif

        #if os(watchOS)
        c.append(check("_WatchKit_SwiftUI", "now-playing-view-hosted", timeout: 30) {
            let log = P6Log()
            let close = try await onMain {
                try p6HostSwiftUI(NowPlayingView().onAppear { log.add("appear") }
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { log.add("size \(Int($0.width))x\(Int($0.height))") })
            }
            defer { Task { @MainActor in close() } }
            try await expect(p6Wait(10) { log.has("appear") && log.all.contains { $0.hasPrefix("size ") } }, "NowPlayingView: \(log.all)")
            let sz = log.all.last { $0.hasPrefix("size ") } ?? ""
            let screen = WKInterfaceDevice.current().screenBounds.size
            let dims = sz.dropFirst(5).split(separator: "x").compactMap { Int($0) }
            try expect(dims.count == 2 && dims[0] > Int(screen.width) / 2 && dims[1] > Int(screen.height) / 3, "laid out \(sz) on a \(screen) screen")
            return "NowPlayingView on screen: \(log.all.joined(separator: ","))"
        })
        #endif
        return c
    }
}

#if os(watchOS)
/// inside the white box (the bounding box of pure white pixels): pixels drawn dark (text) and grey (links, antialiasing)
func p6DarkGrey(_ i: CGImage) -> (Int, Int) {
    let ctx = bitmap(i.width, i.height); ctx.draw(i, in: CGRect(x: 0, y: 0, width: i.width, height: i.height))
    var x0 = Int.max, y0 = Int.max, x1 = -1, y1 = -1
    for y in 0..<i.height { for x in 0..<i.width where pixel(ctx, x, y).prefix(3).allSatisfy({ $0 > 250 }) { x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y) } }
    guard x1 >= 0 else { return (0, 0) }
    var dark = 0, grey = 0
    for y in y0...y1 { for x in x0...x1 { let m = Int(pixel(ctx, x, y).prefix(3).max()!); if m < 90 { dark += 1 } else if m <= 200 { grey += 1 } } }
    return (dark, grey)
}
/// the app's window as the screen shows it, scale 1: UIKit is private on watchOS, so through the runtime
/// (drawViewHierarchyInRect:afterScreenUpdates: into a context pushed with UIGraphicsPushContext)
@MainActor func p6WatchWindowShot() throws -> CGImage {
    guard let app = (NSClassFromString("UIApplication") as? NSObject.Type)?.value(forKey: "sharedApplication") as? NSObject,
          let w = (app.value(forKey: "keyWindow") as? NSObject) ?? (app.value(forKey: "windows") as? [NSObject])?.first else { throw Fail("no UIApplication window") }
    guard let b = w.value(forKey: "bounds") as? CGRect, b.width >= 1, b.height >= 1 else { throw Fail("window bounds \(String(describing: w.value(forKey: "bounds")))") }
    let rtld = UnsafeMutableRawPointer(bitPattern: -2)   // RTLD_DEFAULT
    guard let push = dlsym(rtld, "UIGraphicsPushContext"), let pop = dlsym(rtld, "UIGraphicsPopContext") else { throw Fail("no UIGraphicsPushContext") }
    let sel = NSSelectorFromString("drawViewHierarchyInRect:afterScreenUpdates:")
    guard let imp = class_getMethodImplementation(type(of: w), sel) else { throw Fail("no drawViewHierarchyInRect:") }
    let ctx = bitmap(Int(b.width), Int(b.height))
    ctx.translateBy(x: 0, y: b.height); ctx.scaleBy(x: 1, y: -1)   // UIKit's flipped coordinates
    unsafeBitCast(push, to: (@convention(c) (CGContext) -> Void).self)(ctx)
    let ok = unsafeBitCast(imp, to: (@convention(c) (AnyObject, Selector, CGRect, Bool) -> Bool).self)(w, sel, b, true)
    unsafeBitCast(pop, to: (@convention(c) () -> Void).self)()
    guard ok, let img = ctx.makeImage() else { throw Fail("drawViewHierarchy \(ok)") }
    return img
}
#endif
