// sdkcov P7: Apple Intelligence and translation. FoundationModels (system model availability; with a model: plain,
// guided (dynamic schema), tool-calling and streamed responses and token counts; without: schemas, generated content,
// transcripts and the Private Cloud Compute model's answer), its UIKit / Core Spotlight overlays, ImagePlayground,
// Translation (language availability, an installed-language session, the skip-translation attribute elsewhere) and its
// SwiftUI modifiers. Apple's simulator reaches the model through the host Mac's modelmanagerd
// (com.apple.modelmanager.simulator); right after boot it answers modelNotReady for ~15 s, so availability is polled.
import Foundation
import CoreGraphics
#if canImport(UIKit)
import UIKit
#endif
import SwiftUI
#if canImport(FoundationModels) && !os(tvOS)
import FoundationModels
#endif
#if canImport(_FoundationModels_UIKit) && (os(iOS) || os(visionOS))
import _FoundationModels_UIKit
#endif
#if canImport(_CoreSpotlight_FoundationModels) && (os(iOS) || os(visionOS))
import CoreSpotlight
import _CoreSpotlight_FoundationModels
#endif
#if canImport(ImagePlayground) && (os(iOS) || os(visionOS))
import ImagePlayground
#endif
#if canImport(Translation)
import Translation
#endif
#if canImport(_Translation_SwiftUI) && (os(iOS) || os(visionOS))
import _Translation_SwiftUI
#endif

#if canImport(FoundationModels) && !os(tvOS)
/// a tool without @Generable (no macro plugin in the Linux toolchain): its arguments are a dynamic schema
struct P7WeatherTool: Tool {
    let calls = P7Box<String>()
    var name: String { "cityTemperature" }
    var description: String { "Returns today's temperature in degrees Celsius for a city." }
    var parameters: GenerationSchema {
        try! GenerationSchema(root: DynamicGenerationSchema(name: "Args", properties: [
            .init(name: "city", description: "The city name", schema: DynamicGenerationSchema(type: String.self)),
        ]), dependencies: [])
    }
    func call(arguments: GeneratedContent) async throws -> String {
        let city = (try? arguments.value(String.self, forProperty: "city")) ?? "?"
        calls.set(city)
        return "It is 17 degrees Celsius in \(city) today."
    }
}
/// the schema of { name: String, legs: Int, kind: "mammal" | "bird" | "fish" }
func p7AnimalSchema() throws -> GenerationSchema {
    let kind = DynamicGenerationSchema(name: "Kind", anyOf: ["mammal", "bird", "fish"])
    let animal = DynamicGenerationSchema(name: "Animal", description: "An animal", properties: [
        .init(name: "name", schema: DynamicGenerationSchema(type: String.self)),
        .init(name: "legs", description: "number of legs", schema: DynamicGenerationSchema(type: Int.self)),
        .init(name: "kind", schema: DynamicGenerationSchema(referenceTo: "Kind")),
    ])
    return try GenerationSchema(root: animal, dependencies: [kind])
}
#if os(iOS) || os(visionOS)
/// the system model, once it is available (Apple's simulator answers modelNotReady for a while after boot)
func p7SystemModel(_ secs: Double) async -> (SystemLanguageModel, String) {
    let m = SystemLanguageModel.default
    let end = Date().addingTimeInterval(secs)
    while Date() < end { if case .available = m.availability { return (m, "available") }; try? await Task.sleep(for: .milliseconds(500)) }
    return (m, "\(m.availability)")
}
#endif
#endif

extension Registry {
    static var p7_ai: [Check] {
        var c: [Check] = []
        #if canImport(FoundationModels) && !os(tvOS)
        c.append(check("FoundationModels", "schemas-content-transcript") {
            // no model needed: dynamic schemas, generated content <-> JSON, transcripts, options
            let s = try p7AnimalSchema()
            let js = String(data: try JSONEncoder().encode(s), encoding: .utf8) ?? ""
            try expect(js.contains("legs") && js.contains("mammal"), "schema JSON \(js.prefix(200))")
            let gc = try GeneratedContent(json: #"{"name":"Heron","legs":2,"kind":"bird"}"#)
            try expect(try gc.value(String.self, forProperty: "name") == "Heron" && gc.value(Int.self, forProperty: "legs") == 2, "content \(gc.jsonString)")
            guard case .structure(let props, let keys) = gc.kind else { throw Fail("kind \(gc.kind)") }
            try expect(Set(keys) == ["name", "legs", "kind"] && props.count == 3, "keys \(keys)")
            let back = try GeneratedContent(json: gc.jsonString)
            try expect(back == gc, "JSON round trip")
            let made = GeneratedContent(properties: ["a": 1, "b": "x"])
            try expect(try made.value(Int.self, forProperty: "a") == 1, "properties init")
            let opts = GenerationOptions(samplingMode: .greedy, temperature: 0.2, maximumResponseTokens: 32)
            try expect(opts.maximumResponseTokens == 32 && opts.temperature == 0.2, "options")
            let t = Transcript(entries: [.instructions(Transcript.Instructions(segments: [.text(.init(content: "Be brief."))], toolDefinitions: [])),
                                         .prompt(Transcript.Prompt(segments: [.text(.init(content: "Hi"))]))])
            try expect(t.count == 2, "transcript \(t.count) entries")
            let td = Transcript.ToolDefinition(tool: P7WeatherTool())
            try expect(td.name == "cityTemperature", "tool definition \(td.name)")
            return "schema \(js.count) B JSON; content round trip; transcript \(t.count) entries"
        })
        #if os(iOS) || os(visionOS)
        c.append(check("FoundationModels", "system-model-respond-guided-tools-stream", timeout: 240) {
            let (m, av) = await p7SystemModel(30)
            let langs = m.supportedLanguages.count
            try expect(langs > 0 && m.supportsLocale(Locale(identifier: "en_US")), "\(langs) languages")
            guard av == "available" else {
                // x86Sim: no modelmanagerd / host bridge (com.apple.modelmanager.simulator) yet - see COVERAGE-GAPS.md
                throw Skip("system model \(av) after 30 s (Apple's simulator uses the host Mac's Apple Intelligence); \(langs) languages")
            }
            let s = LanguageModelSession(instructions: "Answer with as few words as possible.")
            let r: LanguageModelSession.Response<String>
            do { r = try await s.respond(to: "Reply with the single word: pong", options: GenerationOptions(samplingMode: .greedy)) }
            catch where "\(error as NSError)".contains("ModelManagerError Code=1026") {
                // Apple's visionOS (and watchOS) simulators: the model reports available, generation is refused (1026)
                throw Skip("model available but generation refused: ModelManagerError 1026 (as in Apple's visionOS simulator)")
            }
            try expect(r.content.lowercased().contains("pong"), "answer '\(r.content)'")
            // guided generation against a dynamic schema
            let g = try await LanguageModelSession().respond(to: "Describe a duck.", schema: try p7AnimalSchema(), options: GenerationOptions(samplingMode: .greedy))
            let kind = try g.content.value(String.self, forProperty: "kind"), legs = try g.content.value(Int.self, forProperty: "legs")
            try expect(["mammal", "bird", "fish"].contains(kind) && legs >= 0, "guided \(g.content.jsonString)")
            // a tool call
            let tool = P7WeatherTool()
            let ts = LanguageModelSession(tools: [tool], instructions: "Use the cityTemperature tool to answer questions about temperature.")
            let tr = try await ts.respond(to: "What is the temperature in Lisbon today?")
            let called = tool.calls.value
            try expect(called != nil && tr.content.contains("17"), "tool called with \(String(describing: called)), answer '\(tr.content.prefix(80))'")
            // streaming
            var snaps = 0, last = ""
            for try await snap in LanguageModelSession().streamResponse(to: "Count from one to five in words.") { snaps += 1; last = snap.content }
            try expect(snaps >= 1 && !last.isEmpty, "\(snaps) snapshots")
            let tc = try await m.tokenCount(for: "Count from one to five in words.")
            let ctx = try await m.contextSize
            return "'\(r.content.prefix(20))', guided \(g.content.jsonString.prefix(60)), tool(\(called!)), \(snaps) stream snapshots, \(tc) tokens, context \(ctx)"
        })
        #endif
        c.append(check("FoundationModels", "private-cloud-compute-model", timeout: 30) {
            // Private Cloud Compute needs an Apple Account and the network service: what the simulator reports
            let p = PrivateCloudComputeLanguageModel()
            let q = p.quotaUsage
            let av = "\(p.availability)"
            // Apple's simulators: watchOS deviceNotEligible; iOS / visionOS follow the host Mac's account and network
            // state (available, or systemNotReady while it is not ready); quota below its limit either way
            #if os(watchOS)
            try expect(av.hasSuffix(".deviceNotEligible)") && !p.isAvailable, "availability \(av) (Apple's watchOS simulator: deviceNotEligible)")
            #else
            try expect((av == "available" && p.isAvailable) || (av.hasSuffix(".systemNotReady)") && !p.isAvailable), "availability \(av), isAvailable \(p.isAvailable) (Apple's simulator: available or systemNotReady)")
            #endif
            try expect("\(q.status)".contains("belowLimit"), "quota \(q.status) (Apple's simulator: below limit)")
            return "availability \(p.availability), available \(p.isAvailable), quota \(q)"
        })
        #endif
        #if canImport(_FoundationModels_UIKit) && (os(iOS) || os(visionOS))
        c.append(check("_FoundationModels_UIKit", "uiimage-attachment-prompt") {
            let ctx = bitmap(32, 32); ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
            let ui = UIImage(cgImage: ctx.makeImage()!)
            let a = Attachment(ui, orientation: .up).label("blue square")
            let b = Attachment(ctx.makeImage()!)
            let p = Prompt { "What colour is this?"; a }
            _ = b.promptRepresentation
            return "prompt with a UIImage attachment: \(String(describing: p).prefix(60))"
        })
        #endif
        #if canImport(_CoreSpotlight_FoundationModels) && (os(iOS) || os(visionOS))
        c.append(check("_CoreSpotlight_FoundationModels", "spotlight-search-tool") {
            var cfg = SpotlightSearchTool.Configuration(sources: [.coreSpotlight, .files], guide: .complete)
            cfg.maximumResponseSize = 2000
            let tool = SpotlightSearchTool(configuration: cfg)
            try expect(!tool.name.isEmpty && !tool.description.isEmpty, "tool \(tool.name)")
            let sch = String(data: try JSONEncoder().encode(tool.parameters), encoding: .utf8) ?? ""
            return "tool '\(tool.name)', \(cfg.sources.count) sources, parameters \(sch.count) B"
        })
        #endif
        #if canImport(ImagePlayground) && (os(iOS) || os(visionOS))
        c.append(check("ImagePlayground", "image-creator-unavailable", timeout: 60) {
            // Image Playground needs Apple Intelligence image models: Apple's simulator has none
            let ui = await onMain { ImagePlaygroundViewController.isAvailable }
            var r = "?"
            do {
                let ic = try await ImageCreator()
                let styles = ic.availableStyles
                r = "creator with \(styles.count) styles"
                if !ui { throw Fail("ImageCreator made while ImagePlaygroundViewController.isAvailable is false") }
            } catch let e as ImageCreator.Error { r = "ImageCreator.Error.\(e)" }
            let concepts: [ImagePlaygroundConcept] = [.text("a red bicycle"), .extracted(from: "A cat on a mat.", title: "cat")]
            try expect(concepts.count == 2, "concepts")
            if !ui { try expect(r.hasPrefix("ImageCreator.Error."), "unavailable but \(r)") }
            return "view controller available \(ui); \(r)"
        })
        #endif
        #if canImport(Translation) && os(iOS)
        c.append(check("Translation", "availability-session", timeout: 90) {
            let la = LanguageAvailability()
            let langs = await la.supportedLanguages
            try expect(langs.count > 5, "\(langs.count) supported languages")
            let en = Locale.Language(identifier: "en"), de = Locale.Language(identifier: "de"), xx = Locale.Language(identifier: "tlh")
            let st = await la.status(from: en, to: de)
            let bad = await la.status(from: en, to: xx)
            try expect(bad == .unsupported, "en->tlh \(bad)")
            let pairs = await [("en-US", "de-DE"), ("en", "fr"), ("es", "en")].p7AsyncMap { p in "\(p.0)->\(p.1) \(await la.status(from: Locale.Language(identifier: p.0), to: Locale.Language(identifier: p.1)))" }
            var detected = "?"
            do { detected = "\(try await la.status(for: "Der Simulator läuft unter Linux.", to: en))" } catch { detected = "\(error)".prefix(80).description }
            var tr = "not installed"
            let s = TranslationSession(installedSource: en, target: de)
            do { let resp = try await s.translate("Good morning"); tr = "'\(resp.targetText)'" } catch { tr = "translate: \(String(describing: error).prefix(80))" }
            if st == .installed { try expect(tr.hasPrefix("'"), "installed but \(tr)") }
            else { try expect(tr.hasPrefix("translate: "), "not installed but translated \(tr)") }
            return "\(langs.count) languages, en->de \(st), \(pairs), detected-German->en \(detected), \(tr)"
        })
        #endif
        #if canImport(Translation)
        c.append(check("Translation", "skip-translation-attribute") {
            var s = AttributedString("Keep x86Sim as is")
            if let r = s.range(of: "x86Sim") { s[r].translation.skipsTranslation = true }
            let runs = s.runs.filter { $0.translation.skipsTranslation == true }.map { String(s[$0.range].characters) }
            try expect(runs == ["x86Sim"], "runs \(runs)")
            // the attribute follows the text through edits
            s.insert(AttributedString("Please "), at: s.startIndex)
            var tail = AttributedString(" today"); tail.translation.skipsTranslation = false
            s.append(tail)
            let after = s.runs.filter { $0.translation.skipsTranslation == true }.map { String(s[$0.range].characters) }
            try expect(after == ["x86Sim"] && String(s.characters) == "Please Keep x86Sim as is today", "after edits \(after)")
            return "skipsTranslation stays on 'x86Sim' through edits"
        })
        #endif
        #if canImport(_Translation_SwiftUI) && os(iOS)
        c.append(check("_Translation_SwiftUI", "translation-task-presentation", timeout: 60) {
            let ran = P7Box<String>()
            let v = Text("Bonjour").translationTask(source: Locale.Language(identifier: "fr"), target: Locale.Language(identifier: "en")) { s in
                let ready = await s.isReady, dl = await s.canRequestDownloads
                ran.set("session ready \(ready), can download \(dl)")
            }.translationPresentation(isPresented: .constant(false), text: "Bonjour")
            let views = try await p7Main { () async throws -> Int in
                let hc = UIHostingController(rootView: v.frame(width: 300, height: 100))
                let done = try p7Show(hc); defer { done() }
                try await Task.sleep(for: .seconds(1))
                return p7Subviews(hc.view).count
            }
            let r = await ran.wait(20)
            try expect(r != nil, "translationTask action never ran")
            return "\(views) views; \(r!)"
        })
        #endif
        return c
    }
}


extension Array {
    func p7AsyncMap<T>(_ f: (Element) async -> T) async -> [T] { var r: [T] = []; for x in self { r.append(await f(x)) }; return r }
}
