// SDK coverage, round 22: checks for [a] gaps of covered frameworks (COVERAGE-GAPS.md). Each asserts what Apple's
// simulator answers (ref-mac.sh).
import Foundation
import SwiftUI
#if canImport(Charts)
import Charts
#endif
#if canImport(MapKit)
import MapKit
#endif

#if canImport(Charts)
/// an x axis with labels at 0, 50 and 100 only (no ticks, no grid lines), the y axis hidden, nothing plotted that
/// shows (a clear rule); white background, 400 x 100 points
private struct P18AxisChart: View {
    var body: some View {
        Chart { RuleMark(y: .value("y", 0.5)).foregroundStyle(.clear) }
            .chartXScale(domain: 0...100).chartYScale(domain: 0...1)
            .chartXAxis { AxisMarks(values: [0, 50, 100]) { _ in AxisValueLabel().foregroundStyle(Color.black) } }
            .chartYAxis(.hidden).chartLegend(.hidden)
            .frame(width: 400, height: 100).background(Color.white)
    }
}

/// the dark pixels' column runs (a gap of 6 or more light columns ends a run): (first, last) column and the rows
/// they span
private func p18DarkRuns(_ img: CGImage) -> (runs: [(Int, Int)], rows: (Int, Int)) {
    let w = img.width, h = img.height
    var px = [UInt8](repeating: 0, count: w * h * 4)
    guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return ([], (0, 0)) }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    var cols = [Bool](repeating: false, count: w)
    var top = h, bottom = -1
    for y in 0..<h { for x in 0..<w {
        let i = (y * w + x) * 4
        if px[i + 3] > 128 && Int(px[i]) + Int(px[i + 1]) + Int(px[i + 2]) < 300 { cols[x] = true; top = min(top, y); bottom = max(bottom, y) }
    } }
    var runs: [(Int, Int)] = []
    var start = -1, last = -100
    for x in 0..<w where cols[x] {
        if x - last > 6 { if start >= 0 { runs.append((start, last)) }; start = x }
        last = x
    }
    if start >= 0 { runs.append((start, last)) }
    return (runs, (top, bottom))
}
#endif

extension Registry {
    static var p18: [Check] {
        var c: [Check] = []

        // MARK: Charts: where the x axis draws its value labels, by pixels (ImageRenderer at scale 1)
        #if canImport(Charts)
        c.append(check("Charts", "axis-label-positions-pixels", timeout: 30) {
            let img = await onMain { () -> CGImage? in let r = ImageRenderer(content: P18AxisChart()); r.scale = 1; return r.cgImage }
            guard let img else { throw Fail("ImageRenderer gave no image") }
            let (runs, rows) = p18DarkRuns(img)
            let desc = runs.map { "\($0.0)-\($0.1)" }.joined(separator: ",")
            // the labels "0" and "50" only: "100" at the plot's trailing edge is dropped (both simulators: runs 5-9 and
            // 205-216 of 400, in the bottom strip)
            try expect(runs.count == 2, "\(runs.count) label runs (\(desc)) in \(img.width)x\(img.height) (Apple's simulator: 2, \"100\" dropped)")
            try expect(abs(runs[0].0 - 5) <= 1 && abs(runs[0].1 - 9) <= 1 && abs(runs[1].0 - 205) <= 1 && abs(runs[1].1 - 216) <= 1,
                "label runs \(desc) (Apple's simulator: 5-9,205-216)")
            try expect(rows.0 >= img.height / 2, "labels at rows \(rows.0)-\(rows.1) of \(img.height): not below the plot")
            return "\(img.width)x\(img.height): label runs \(desc), rows \(rows.0)-\(rows.1)"
        })
        #endif

        // MARK: MapKit: an MKMapItemRequest for a place identifier that names no place
        #if canImport(MapKit)
        if #available(iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *) {
            c.append(check("MapKit", "map-item-request-place-id", timeout: 60) {
                guard let id = MKMapItem.Identifier(rawValue: "I0000000000000000") else { throw Fail("MKMapItem.Identifier refused the string") }
                let req = MKMapItemRequest(mapItemIdentifier: id)
                // no such place: MKError 5 (Apple's simulator too)
                do {
                    let item = try await req.mapItem
                    throw Fail("item \(item.name ?? "nil") id \(item.identifier?.rawValue ?? "nil") for a place id that names none")
                } catch let e as NSError where e.domain == MKErrorDomain {
                    try expect(e.code == 5, "MKError \(e.code) (Apple's simulator: 5)")
                    return "error \(e.domain) \(e.code)"
                }
            })
        }
        #endif
        return c
    }
}
