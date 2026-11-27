import ActivityKit
import SwiftUI
import WidgetKit

@main
struct GoshuinWidgets: WidgetBundle {
    var body: some Widget { PilgrimageWidget() }
}

struct PilgrimageWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PilgrimageActivity.self) { context in
            VStack(alignment: .leading, spacing: 7) {
                Label(L.t("pilgrimage"), systemImage: "figure.walk")
                Text(L.f("progress.count", context.state.visited, context.state.total))
                    .font(.title2.monospacedDigit().bold())
                ProgressView(value: Double(context.state.visited), total: Double(max(1, context.state.total)))
            }
            .padding()
            .activityBackgroundTint(Color(red: 0.96, green: 0.95, blue: 0.91))
            .widgetURL(URL(string: "goshuin://pilgrimage"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(L.t("pilgrimage"), systemImage: "figure.walk")
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(L.f("progress.count", context.state.visited, context.state.total))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ProgressView(value: Double(context.state.visited), total: Double(max(1, context.state.total)))
                }
            } compactLeading: {
                Image(systemName: "figure.walk")
            } compactTrailing: {
                Text(L.f("progress.count", context.state.visited, context.state.total))
            } minimal: {
                Image(systemName: "figure.walk")
            }
            .widgetURL(URL(string: "goshuin://pilgrimage"))
        }
    }
}
