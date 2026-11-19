// sdkcov widget extension (iOS, watchOS, visionOS: <app>/PlugIns/sdkcovWidget.appex, com.apple.widgetkit-extension):
// a static widget (TimelineProvider), an App Intent configured widget (WidgetConfigurationIntent + recommendations),
// on iOS the Live Activity views for SDKCovLiveAttributes (ActivityKit) and a control (ControlWidget). Every provider
// call / view evaluation leaves a mark (Marks.swift) for checks/P3_Extensions.swift.
import WidgetKit
import SwiftUI
import AppIntents
import RelevanceKit
#if os(iOS)
import ActivityKit
#endif

struct SDKCovEntry: TimelineEntry { let date: Date; let n: Int }

struct SDKCovProvider: TimelineProvider {
    func placeholder(in context: Context) -> SDKCovEntry { sdkcovMark("widget-placeholder", "\(context.family)"); return SDKCovEntry(date: .now, n: 0) }
    func getSnapshot(in context: Context, completion: @escaping (SDKCovEntry) -> Void) {
        sdkcovMark("widget-snapshot", "\(context.family) preview \(context.isPreview)")
        completion(SDKCovEntry(date: .now, n: 1))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<SDKCovEntry>) -> Void) {
        sdkcovMark("widget-timeline", "\(context.family)")
        let now = Date()
        completion(Timeline(entries: (0..<3).map { SDKCovEntry(date: now.addingTimeInterval(Double($0) * 60), n: $0) }, policy: .atEnd))
    }
    /// (P25) the widget's relevance (Smart Stack): the next hour; checks/P25_Gaps.swift invalidates it
    func relevance() async -> WidgetRelevance<Void> {
        sdkcovMark("widget-relevance", "static")
        let now = Date()
        return WidgetRelevance([WidgetRelevanceAttribute(context: .date(from: now, to: now.addingTimeInterval(3600)))])
    }
}

struct SDKCovStaticWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "sdkcov.static", provider: SDKCovProvider()) { e in
            let _ = sdkcovMark("widget-view", "static \(e.n)")
            Text("sdkcov \(e.n)").containerBackground(.red, for: .widget)
        }
        .configurationDisplayName("sdkcov")
        .description("sdkcov static widget")
    }
}

struct SDKCovWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "sdkcov widget" }
    @IntentParameter(title: "Count", default: 7) var count: Int
    init() {}
    init(count: Int) { self.count = count }
}

struct SDKCovIntentProvider: AppIntentTimelineProvider {
    func recommendations() -> [AppIntentRecommendation<SDKCovWidgetIntent>] {
        sdkcovMark("widget-recommendations", "1")
        return [AppIntentRecommendation(intent: SDKCovWidgetIntent(count: 3), description: "three")]
    }
    func placeholder(in context: Context) -> SDKCovEntry { SDKCovEntry(date: .now, n: 0) }
    func snapshot(for configuration: SDKCovWidgetIntent, in context: Context) async -> SDKCovEntry {
        sdkcovMark("widget-intent-snapshot", "count \(configuration.count)")
        return SDKCovEntry(date: .now, n: configuration.count)
    }
    func timeline(for configuration: SDKCovWidgetIntent, in context: Context) async -> Timeline<SDKCovEntry> {
        sdkcovMark("widget-intent-timeline", "count \(configuration.count)")
        return Timeline(entries: [SDKCovEntry(date: .now, n: configuration.count)], policy: .never)
    }
}

struct SDKCovIntentWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "sdkcov.intent", intent: SDKCovWidgetIntent.self, provider: SDKCovIntentProvider()) { e in
            Text("count \(e.n)").containerBackground(.blue, for: .widget)
        }
        .configurationDisplayName("sdkcov intent")
    }
}

#if os(iOS)
/// the same type as checks/P3_Extensions.swift's (ActivityKit matches attributes by type name; both are module sdkcov)
struct SDKCovLiveAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable { var step: Int }
    var name: String
}

struct SDKCovLiveWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SDKCovLiveAttributes.self) { ctx in
            let _ = sdkcovMark("live-view", "lock screen \(ctx.attributes.name) step \(ctx.state.step)")
            Text("\(ctx.attributes.name) step \(ctx.state.step)").padding()
        } dynamicIsland: { ctx in
            let _ = sdkcovMark("live-island", "\(ctx.attributes.name) step \(ctx.state.step)")
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Text("sdkcov") }
                DynamicIslandExpandedRegion(.trailing) { Text("\(ctx.state.step)") }
            } compactLeading: { Text("s") } compactTrailing: { Text("\(ctx.state.step)") } minimal: { Text("s") }
        }
    }
}

struct SDKCovControlIntent: AppIntent {
    static var title: LocalizedStringResource { "sdkcov control" }
    init() {}
    func perform() async throws -> some IntentResult { sdkcovMark("control-perform", "1"); return .result() }
}

struct SDKCovControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "sdkcov.control") {
            ControlWidgetButton(action: SDKCovControlIntent()) { Label("sdkcov", systemImage: "checkmark") }
        }
        .displayName("sdkcov control")
    }
}
#endif

@main
struct SDKCovWidgets: WidgetBundle {
    init() { sdkcovMark("widget-launch", "pid \(ProcessInfo.processInfo.processIdentifier)") }
    var body: some Widget {
        SDKCovStaticWidget()
        SDKCovIntentWidget()
        #if os(iOS)
        SDKCovLiveWidget()
        SDKCovControl()
        #endif
    }
}
