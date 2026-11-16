// sdkcov P5: location & maps. CoreLocation against the simulated location run.sh / ref-mac.sh set before the run
// (`x86sim location set` / `simctl location set` 37.3349,-122.0090, Apple Park) with when-in-use authorization granted
// up front (`x86sim privacy` / `simctl privacy grant location`): CLLocationUpdate.liveUpdates, CLMonitor geofences,
// CLLocationManager delegate updates, CLServiceSession, geocoding; MapKit search / directions / geocoding requests / Look
// Around answers (network), overlay renderers and snapshots by pixels, SwiftUI Map on watchOS / visionOS; CoreLocationUI's
// SwiftUI button; RelevanceKit's MapKit contexts; WeatherKit and EnergyKit answers.
import Foundation
import SwiftUI
import Synchronization
import CoreLocation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(MapKit)
import MapKit
#endif
#if canImport(CoreLocationUI)
import CoreLocationUI
#endif
#if canImport(_CoreLocationUI_SwiftUI)
import _CoreLocationUI_SwiftUI
#endif
#if canImport(_MapKit_SwiftUI)
import _MapKit_SwiftUI
#endif
#if canImport(RelevanceKit)
import RelevanceKit
#endif
#if canImport(_RelevanceKit_MapKit)
import _RelevanceKit_MapKit
#endif
#if canImport(WeatherKit)
import WeatherKit
#endif
#if canImport(EnergyKit)
import EnergyKit
#endif

/// the simulated device location run.sh / ref-mac.sh set (Apple Park)
let p5Here = CLLocationCoordinate2D(latitude: 37.3349, longitude: -122.0090)

final class P5LocDelegate: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    let auth = P5Box<Int32>(), loc = P5Box<CLLocation>(), err = P5Box<String>()
    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) { if m.authorizationStatus != .notDetermined { auth.set(m.authorizationStatus.rawValue) } }
    func locationManager(_ m: CLLocationManager, didUpdateLocations l: [CLLocation]) { if let x = l.last { loc.set(x) } }
    func locationManager(_ m: CLLocationManager, didFailWithError e: Error) { err.set(p5Err(e)) }
}
#if canImport(MapKit) && !os(watchOS)
final class P5CompleterDelegate: NSObject, MKLocalSearchCompleterDelegate, @unchecked Sendable {
    let done = P5Box<String>()
    func completerDidUpdateResults(_ c: MKLocalSearchCompleter) { done.set("\(c.results.count) results: \(c.results.prefix(3).map(\.title))") }
    func completer(_ c: MKLocalSearchCompleter, didFailWithError e: Error) { done.set("error \(p5Err(e))") }
}
final class P5MapDelegate: NSObject, MKMapViewDelegate, @unchecked Sendable {
    var rendered = 0, loaded = false
    func mapView(_ m: MKMapView, rendererFor o: MKOverlay) -> MKOverlayRenderer {
        rendered += 1
        if let p = o as? MKPolygon { let r = MKPolygonRenderer(polygon: p); r.fillColor = .red; return r }
        if let c = o as? MKCircle { let r = MKCircleRenderer(circle: c); r.strokeColor = .blue; r.lineWidth = 4; return r }
        return MKOverlayRenderer(overlay: o)
    }
    func mapViewDidFinishLoadingMap(_ m: MKMapView) { loaded = true }
}
#endif
/// distance in metres from the simulated location
func p5Off(_ l: CLLocation) -> Double { l.distance(from: CLLocation(latitude: p5Here.latitude, longitude: p5Here.longitude)) }

extension Registry {
    static var p5_location: [Check] {
        var c: [Check] = []

        // MARK: CoreLocation
        c.append(check("CoreLocation", "authorization-delegate-update", timeout: 40) {
            // run.sh / ref-mac.sh grant when-in-use up front: the manager reports it at once and a requested location
            // is the simulated one
            let d = P5LocDelegate()
            let m = await onMain { () -> CLLocationManager in let m = CLLocationManager(); m.delegate = d; m.desiredAccuracy = kCLLocationAccuracyBest; return m }
            let st = await d.auth.wait(10) ?? -1
            #if os(tvOS) || os(visionOS)
            let ok: [Int32] = [CLAuthorizationStatus.authorizedWhenInUse.rawValue]
            #else
            let ok: [Int32] = [CLAuthorizationStatus.authorizedWhenInUse.rawValue, CLAuthorizationStatus.authorizedAlways.rawValue]
            #endif
            try expect(ok.contains(st), "authorization \(st) (run.sh / ref-mac.sh grant when-in-use: x86sim privacy / simctl privacy grant location)")
            await onMain { m.requestLocation() }
            guard let l = await d.loc.wait(20) else { throw Fail("no location in 20 s; error \(d.err.value ?? "none") (is a simulated location set? x86sim location set 37.3349,-122.0090)") }
            try expect(p5Off(l) < 200, "location \(l.coordinate) is \(Int(p5Off(l))) m from the simulated one")
            await onMain { m.delegate = nil }
            let acc = await onMain { m.accuracyAuthorization.rawValue }
            return "authorization \(st), accuracy authorization \(acc), location \(String(format: "%.4f,%.4f", l.coordinate.latitude, l.coordinate.longitude)) ±\(Int(l.horizontalAccuracy)) m"
        })
        c.append(check("CoreLocation", "live-updates-simulated", timeout: 40) {
            let r = await p5Within(25) { @MainActor () async throws -> String in
                var seen: [String] = []
                let ups = CLLocationUpdate.liveUpdates(.default)
                for try await u in ups {
                    if let l = u.location {
                        try expect(p5Off(l) < 200, "live update \(l.coordinate), \(Int(p5Off(l))) m off")
                        return "location after \(seen.count) other updates \(seen), \(String(format: "%.4f,%.4f", l.coordinate.latitude, l.coordinate.longitude)), stationary \(u.stationary)"
                    }
                    seen.append(u.authorizationDenied ? "denied" : u.authorizationRequestInProgress ? "request in progress" : u.locationUnavailable ? "unavailable" : "other")
                    if seen.count > 20 { break }
                }
                throw Fail("no location in the live updates: \(seen)")
            }
            guard let r, r.hasPrefix("ok: ") else { throw Fail(r ?? "no live update in 25 s") }
            return String(r.dropFirst(4))
        })
        #if os(iOS)   // CLMonitor: iOS only
        c.append(check("CoreLocation", "monitor-circular-conditions", timeout: 50) {
            // CLMonitor: a condition around the simulated location becomes satisfied, one around Paris unsatisfied
            let name = "sdkcovp5\(Int(Date().timeIntervalSince1970))"   // alphanumeric only (else NSInternalInconsistencyException)
            let r = await p5Within(40) { () async throws -> String in
                let mon = await CLMonitor(name)
                await mon.add(CLMonitor.CircularGeographicCondition(center: p5Here, radius: 300), identifier: "here", assuming: .unknown)
                await mon.add(CLMonitor.CircularGeographicCondition(center: CLLocationCoordinate2D(latitude: 48.8584, longitude: 2.2945), radius: 300), identifier: "paris", assuming: .unknown)
                let ids = await mon.identifiers
                try expect(ids.sorted() == ["here", "paris"], "identifiers \(ids)")
                // Apple's simulator delivers no geofence events for a simulated location (none in 40 s there either):
                // events within 8 s are reported, not required
                let states = Mutex<[String: String]>([:])
                let t = Task { for try await ev in await mon.events { states.withLock { $0[ev.identifier] = "\(ev.state)" } } }
                try await Task.sleep(for: .seconds(8)); t.cancel()
                let rec = await mon.record(for: "here"), recP = await mon.record(for: "paris")
                try expect(rec?.condition is CLMonitor.CircularGeographicCondition && recP != nil, "records \(String(describing: rec)) \(String(describing: recP))")
                let c = rec?.condition as? CLMonitor.CircularGeographicCondition
                try expect(c?.radius == 300 && abs((c?.center.latitude ?? 0) - p5Here.latitude) < 1e-9, "condition \(String(describing: c))")
                await mon.remove("here"); await mon.remove("paris")
                let after = await mon.identifiers
                try expect(after.isEmpty, "identifiers after remove \(after)")
                return "2 conditions added / recorded / removed; events in 8 s \(states.withLock { $0 }), last state \(rec.map { "\($0.lastEvent.state)" } ?? "none")"
            }
            guard let r, r.hasPrefix("ok: ") else { throw Fail(r ?? "CLMonitor did not answer in 40 s") }
            return String(r.dropFirst(4))
        })
        #endif
        c.append(check("CoreLocation", "service-session-availability", timeout: 30) {
            // CLServiceSession: with when-in-use granted its diagnostics carry no denial; capability answers of a simulator
            let s = CLServiceSession(authorization: .whenInUse)
            let first = await p5Within(5) { () async throws -> String in
                for try await d in s.diagnostics { return "denied \(d.authorizationDenied), denied globally \(d.authorizationDeniedGlobally), restricted \(d.authorizationRestricted), in progress \(d.authorizationRequestInProgress), insufficiently in use \(d.insufficientlyInUse)" }
                return "no diagnostics"
            } ?? "no diagnostic in 5 s"
            s.invalidate()
            try expect(!first.contains("denied true"), "service session: \(first)")
            var caps: [String] = []
            #if !os(tvOS)
            caps.append("heading \(CLLocationManager.headingAvailable())")
            try expect(!CLLocationManager.headingAvailable(), "heading available in a simulator (Apple's: false)")
            #endif
            #if os(iOS) || os(visionOS)
            caps.append("significant changes \(CLLocationManager.significantLocationChangeMonitoringAvailable())")
            #endif
            #if os(iOS)
            caps.append("ranging \(CLLocationManager.isRangingAvailable())")
            caps.append("circular regions \(CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self))")
            #endif
            #if os(iOS) || os(watchOS)
            let bg = CLBackgroundActivitySession(); bg.invalidate()
            caps.append("background activity session ok")
            #endif
            return "\(first.replacingOccurrences(of: "ok: ", with: "")); \(caps.joined(separator: ", "))"
        })
        c.append(check("CoreLocation", "geocoder-answers", timeout: 60) {
            // CLGeocoder (deprecated in 26 for MapKit's requests, still shipped): reverse and forward over the network
            let g = CLGeocoder()
            let rev = try await g.reverseGeocodeLocation(CLLocation(latitude: p5Here.latitude, longitude: p5Here.longitude))
            guard let p = rev.first else { throw Fail("no placemark") }
            try expect(p.locality == "Cupertino" && p.isoCountryCode == "US", "reverse: \(p.locality ?? "nil") \(p.isoCountryCode ?? "nil")")
            let fwd = try await g.geocodeAddressString("1 Infinite Loop, Cupertino, CA")
            guard let f = fwd.first?.location else { throw Fail("forward: no location") }
            try expect(abs(f.coordinate.latitude - 37.33) < 0.05 && abs(f.coordinate.longitude + 122.03) < 0.05, "forward \(f.coordinate)")
            return "reverse \(p.name ?? "?"), \(p.locality!); forward \(String(format: "%.3f,%.3f", f.coordinate.latitude, f.coordinate.longitude))"
        })

        // MARK: MapKit
        #if canImport(MapKit)
        c.append(check("MapKit", "local-search", timeout: 60) {
            let req = MKLocalSearch.Request()
            req.naturalLanguageQuery = "coffee"
            req.region = MKCoordinateRegion(center: p5Here, latitudinalMeters: 5000, longitudinalMeters: 5000)
            req.resultTypes = .pointOfInterest
            let resp = try await MKLocalSearch(request: req).start()
            try expect(!resp.mapItems.isEmpty, "no coffee near Apple Park")
            let near = resp.mapItems.filter { p5Off($0.location) < 20_000 }
            try expect(!near.isEmpty, "results all far away: \(resp.mapItems.prefix(3).map { $0.location.coordinate })")
            var comp = "n/a"
            #if !os(watchOS)
            let d = P5CompleterDelegate()
            let cmp = await onMain { () -> MKLocalSearchCompleter in let c = MKLocalSearchCompleter(); c.delegate = d; c.region = req.region; c.queryFragment = "Apple Pa"; return c }
            comp = await d.done.wait(20) ?? "no completer answer in 20 s"
            await onMain { cmp.cancel() }
            try expect(comp.contains(" results") && !comp.hasPrefix("0 "), "completer: \(comp)")
            #endif
            return "\(resp.mapItems.count) items (\(resp.mapItems.first?.name ?? "?")); completer \(comp)"
        })
        c.append(check("MapKit", "directions-eta", timeout: 60) {
            let req = MKDirections.Request()
            req.source = MKMapItem(location: CLLocation(latitude: p5Here.latitude, longitude: p5Here.longitude), address: nil)
            req.destination = MKMapItem(location: CLLocation(latitude: 37.4220, longitude: -122.0841), address: nil)
            req.transportType = .automobile
            let resp = try await MKDirections(request: req).calculate()
            guard let r = resp.routes.first else { throw Fail("no route") }
            try expect(r.distance > 10_000 && r.distance < 30_000 && r.expectedTravelTime > 300 && r.polyline.pointCount > 10, "route \(r.distance) m, \(r.expectedTravelTime) s, \(r.polyline.pointCount) points")
            let eta = try await MKDirections(request: req).calculateETA()
            try expect(eta.expectedTravelTime > 300 && eta.distance > 10_000, "ETA \(eta.expectedTravelTime) s \(eta.distance) m")
            return "route \(Int(r.distance)) m in \(Int(r.expectedTravelTime)) s, \(r.steps.count) steps; ETA \(Int(eta.expectedTravelTime)) s"
        })
        c.append(check("MapKit", "geocoding-requests", timeout: 60) {
            guard let rev = MKReverseGeocodingRequest(location: CLLocation(latitude: p5Here.latitude, longitude: p5Here.longitude)) else { throw Fail("no reverse request") }
            let items = try await rev.mapItems
            guard let a = items.first?.address else { throw Fail("reverse: \(items.count) items, no address") }
            try expect(a.fullAddress.contains("Cupertino"), "reverse address \(a.fullAddress)")
            guard let fwd = MKGeocodingRequest(addressString: "1 Infinite Loop, Cupertino, CA") else { throw Fail("no forward request") }
            let f = try await fwd.mapItems
            guard let l = f.first?.location else { throw Fail("forward: no item") }
            try expect(p5Off(l) < 5_000, "forward \(l.coordinate)")
            return "reverse '\(a.fullAddress.replacingOccurrences(of: "\n", with: ", "))'; forward \(String(format: "%.4f,%.4f", l.coordinate.latitude, l.coordinate.longitude))"
        })
        #if !os(watchOS) && !os(tvOS)
        c.append(check("MapKit", "look-around-scene", timeout: 60) {
            // Look Around imagery of a covered street (Apple Park Way): a scene, or nil where there is none (Apple's answer pinned)
            let scene = try await MKLookAroundSceneRequest(coordinate: CLLocationCoordinate2D(latitude: 37.3318, longitude: -122.0054)).scene
            let ocean = try await MKLookAroundSceneRequest(coordinate: CLLocationCoordinate2D(latitude: 30, longitude: -140)).scene
            try expect(ocean == nil, "a Look Around scene in the middle of the Pacific")
            return "Apple Park Way scene \(scene != nil), Pacific nil"
        })
        #endif
        #if !os(watchOS)
        c.append(check("MapKit", "overlay-renderers-pixels", timeout: 30) {
            // overlay renderers draw into a context like MapKit's tiles: a red polygon covers the middle of its map rect
            try await onMain { () throws -> String in
                var pts = [CLLocationCoordinate2D(latitude: 37.34, longitude: -122.02), CLLocationCoordinate2D(latitude: 37.34, longitude: -122.00),
                           CLLocationCoordinate2D(latitude: 37.33, longitude: -122.00), CLLocationCoordinate2D(latitude: 37.33, longitude: -122.02)]
                let poly = MKPolygon(coordinates: &pts, count: 4)
                let r = MKPolygonRenderer(polygon: poly); r.fillColor = .red; r.strokeColor = .clear
                let mr = poly.boundingMapRect
                let w = 100, h = Int(100 * mr.size.height / mr.size.width)
                let zoom = MKZoomScale(Double(w) / mr.size.width)
                let ctx = bitmap(w, max(h, 1))
                ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)   // map rects grow down, as UIKit
                ctx.scaleBy(x: zoom, y: zoom)   // renderer points: map points from the overlay's bounding rect origin
                r.draw(mr, zoomScale: zoom, in: ctx)
                let p = pixel(ctx, w / 2, h / 2)
                try expect(p[0] > 200 && p[1] < 40 && p[2] < 40 && p[3] > 200, "polygon middle pixel \(p)")
                // a circle renderer's path and a map view taking overlays
                let circle = MKCircle(center: p5Here, radius: 500)
                let mv = MKMapView(frame: CGRect(x: 0, y: 0, width: 300, height: 300)); let d = P5MapDelegate(); mv.delegate = d
                mv.addOverlays([poly, circle])
                mv.setRegion(MKCoordinateRegion(center: p5Here, latitudinalMeters: 4000, longitudinalMeters: 4000), animated: false)
                let pt = mv.convert(p5Here, toPointTo: mv)
                try expect(mv.overlays.count == 2 && abs(pt.x - 150) < 2 && abs(pt.y - 150) < 2, "map view: \(mv.overlays.count) overlays, centre at \(pt)")
                let back = mv.convert(CGPoint(x: 150, y: 150), toCoordinateFrom: mv)
                try expect(abs(back.latitude - p5Here.latitude) < 1e-4, "point -> coordinate \(back)")
                mv.removeOverlays(mv.overlays); mv.delegate = nil
                _ = d
                return "polygon fill \(p), map view converts centre \(pt)"
            }
        })
        c.append(check("MapKit", "snapshot-pixels", timeout: 90) {
            // a map snapshot is a drawn map (many colours, not a blank), and point(for:) projects into it
            let o = MKMapSnapshotter.Options()
            o.region = MKCoordinateRegion(center: p5Here, latitudinalMeters: 3000, longitudinalMeters: 3000)
            o.size = CGSize(width: 200, height: 200)
            #if !os(visionOS)
            o.scale = 1
            #endif
            let s = try await MKMapSnapshotter(options: o).start()
            let pt = s.point(for: p5Here)
            try expect(abs(pt.x - 100) < 2 && abs(pt.y - 100) < 2, "centre projects to \(pt)")
            guard let cg = s.image.cgImage else { throw Fail("no CGImage") }
            let ctx = bitmap(cg.width, cg.height); ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            var colours = Set<Int>()
            for y in stride(from: 0, to: cg.height, by: 4) { for x in stride(from: 0, to: cg.width, by: 4) { let p = pixel(ctx, x, y); colours.insert(((Int(p[0]) >> 3) << 10) | ((Int(p[1]) >> 3) << 5) | (Int(p[2]) >> 3)) } }
            try expect(colours.count > 8, "snapshot has \(colours.count) colours (blank?)")
            return "\(cg.width)x\(cg.height) px, \(colours.count) colours, centre at \(pt)"
        })
        #endif
        #endif

        // MARK: SwiftUI Map on watchOS / visionOS (iOS / tvOS: More_iOS.swift / More_tvOS.swift)
        #if canImport(_MapKit_SwiftUI) && os(visionOS)
        c.append(check("_MapKit_SwiftUI", "map-camera-markers-visionos", timeout: 40) {
            let changes = Mutex(0)
            let v = Map(initialPosition: .region(MKCoordinateRegion(center: p5Here, latitudinalMeters: 2000, longitudinalMeters: 2000))) {
                Marker("sdkcov", coordinate: p5Here)
                MapCircle(center: p5Here, radius: 300).foregroundStyle(.blue.opacity(0.3))
            }.onMapCameraChange(frequency: .onEnd) { ctx in if abs(ctx.region.center.latitude - p5Here.latitude) < 0.01 { changes.withLock { $0 += 1 } } }
            let done = try await onMain { () throws -> () -> Void in try p5Show(UIHostingController(rootView: v.frame(width: 600, height: 400))).1 }
            defer { Task { @MainActor in done() } }
            try expect(await p5Wait(20) { changes.withLock { $0 } > 0 }, "onMapCameraChange never reported the initial region")
            return "\(changes.withLock { $0 }) camera changes at the initial region"
        })
        #endif
        #if canImport(_MapKit_SwiftUI) && os(watchOS)
        c.append(check("_MapKit_SwiftUI", "map-camera-markers-watch", timeout: 40) {
            // on screen through the harness overlay: Map reports its camera once it has laid out
            let changes = Mutex(0)
            await onMain {
                Runner.shared.overlay = AnyView(Map(initialPosition: .region(MKCoordinateRegion(center: p5Here, latitudinalMeters: 2000, longitudinalMeters: 2000))) {
                    Marker("sdkcov", coordinate: p5Here)
                }.onMapCameraChange(frequency: .onEnd) { ctx in if abs(ctx.region.center.latitude - p5Here.latitude) < 0.01 { changes.withLock { $0 += 1 } } })
            }
            defer { Task { @MainActor in Runner.shared.overlay = nil } }
            try expect(await p5Wait(20) { changes.withLock { $0 } > 0 }, "onMapCameraChange never reported the initial region")
            return "\(changes.withLock { $0 }) camera changes at the initial region"
        })
        #endif

        // MARK: CoreLocationUI's SwiftUI LocationButton
        #if canImport(_CoreLocationUI_SwiftUI) && os(iOS)
        c.append(check("_CoreLocationUI_SwiftUI", "location-button-hosted", timeout: 30) {
            // SwiftUI's LocationButton is a CLLocationButton underneath: hosted, it lays out a real control
            let v = VStack { LocationButton(.shareCurrentLocation) {}.labelStyle(.titleAndIcon).symbolVariant(.fill).foregroundColor(.white).tint(.blue) }
            let (hc, done) = try await onMain { () throws -> (UIViewController, () -> Void) in
                let hc = UIHostingController(rootView: AnyView(v)); let (_, d) = try p5Show(hc); return (hc, d)
            }
            defer { Task { @MainActor in done() } }
            try await Task.sleep(for: .seconds(1))
            let (b, fit) = await onMain { () -> (CGSize?, CGSize) in
                hc.view.layoutIfNeeded()
                let b = p5Subviews(hc.view).first { $0 is CLLocationButton }
                return (b?.bounds.size, hc.view.sizeThatFits(CGSize(width: 400, height: 400)))
            }
            guard let b else { throw Fail("no CLLocationButton under the SwiftUI button") }
            try expect(b.width > 40 && b.height > 20, "button \(b), fits \(fit)")
            return "CLLocationButton \(Int(b.width))x\(Int(b.height))"
        })
        #endif
        #if canImport(_CoreLocationUI_SwiftUI) && os(watchOS)
        c.append(check("_CoreLocationUI_SwiftUI", "location-button-ink", timeout: 30) {
            try await onMain { () throws -> String in
                let v = LocationButton(.sendCurrentLocation) {}.labelStyle(.titleAndIcon).tint(.blue)
                let r = ImageRenderer(content: v.frame(width: 180, height: 50)); r.scale = 2
                guard let img = r.cgImage else { throw Fail("no image") }
                let f = watchInked(img)
                try expect(img.width == 360 && f > 0.05, "\(img.width)x\(img.height), \(Int(f * 100))% inked")
                return "\(img.width)x\(img.height), \(Int(f * 100))% inked"
            }
        })
        #endif

        // MARK: RelevanceKit point-of-interest contexts (all platforms)
        #if canImport(_RelevanceKit_MapKit)
        c.append(check("_RelevanceKit_MapKit", "poi-category-contexts") {
            // .airport: nil or a context, varying between runs of Apple's own simulators (GeoServices category data):
            // reported, not asserted
            let airport = RelevantContext.location(category: .airport) != nil
            let cats: [MKPointOfInterestCategory] = [.cafe, .restaurant, .fitnessCenter, .park, .museum]
            let made = cats.map { RelevantContext.location(category: $0) }
            let n = made.compactMap { $0 }.count
            let missing = zip(cats, made).filter { $0.1 == nil }.map { $0.0.rawValue }
            try expect(n == cats.count, "\(n)/\(cats.count) category contexts, nil for \(missing)")
            return "\(n) contexts, airport \(airport): \(String(reflecting: RelevantContext.location(category: .airport)).prefix(300))"
        })
        #endif

        // MARK: WeatherKit: needs a team-signed entitlement (Apple's answer pinned; tvOS: More_tvOS.swift)
        #if canImport(WeatherKit) && !os(tvOS)
        c.append(check("WeatherKit", "service-answer", timeout: 45) {
            let r = await p5Within(35) { () async throws -> String in
                let w = try await WeatherService.shared.weather(for: CLLocation(latitude: p5Here.latitude, longitude: p5Here.longitude), including: .current)
                return "current \(w.temperature)"
            }
            guard let r else { throw Fail("no answer from WeatherService in 35 s") }
            try expect(r.hasPrefix("threw"), "weather without the WeatherKit entitlement: \(r)")
            return r
        })
        #endif

        // MARK: EnergyKit: no energy venues on a simulator
        #if canImport(EnergyKit) && os(iOS)   // tvOS / watchOS / visionOS: every EnergyKit type is unavailable
        c.append(check("EnergyKit", "venues-guidance-answers", timeout: 45) {
            // Apple's simulator: venues() never answers (no energy venues service), guidance ends guidanceUnavailable
            let venues = await p5Within(5) { () async throws -> String in "\(try await EnergyVenue.venues().count) venues" } ?? "no answer in 5 s"
            let guide = await p5Within(15) { () async throws -> String in
                for try await g in ElectricityGuidance.sharedService.guidance(using: .init(suggestedAction: .shift), at: UUID()) { return "guidance \(g.values.count) values" }
                return "finished"
            } ?? "no answer in 15 s"
            try expect(guide.contains("guidanceUnavailable"), "venues: \(venues); guidance: \(guide)")
            // the load-event model is Codable
            let dev = ElectricalLoadDevice(id: "ev1", name: "sdkcov car", type: .electricVehicle)
            let back = try JSONDecoder().decode(ElectricalLoadDevice.self, from: JSONEncoder().encode(dev))
            try expect(back == dev, "device round trip")
            let e = EnergyKitError.venueUnavailable
            return "venues: \(venues); guidance for an unknown venue: \(guide); error text '\(e.errorDescription ?? "")'"
        })
        #endif
        return c
    }
}
