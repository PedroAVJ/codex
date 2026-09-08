import SwiftUI
import WidgetKit

private let talkURL = URL(string: "codexvoice://talk")!

private struct CodexVoiceEntry: TimelineEntry {
    let date: Date
}

private struct CodexVoiceProvider: TimelineProvider {
    func placeholder(in context: Context) -> CodexVoiceEntry {
        CodexVoiceEntry(date: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (CodexVoiceEntry) -> Void) {
        completion(CodexVoiceEntry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CodexVoiceEntry>) -> Void) {
        let now = Date()
        let refresh = Calendar.current.date(byAdding: .hour, value: 6, to: now)
            ?? now.addingTimeInterval(6 * 60 * 60)
        completion(Timeline(entries: [CodexVoiceEntry(date: now)], policy: .after(refresh)))
    }
}

@main
struct CodexVoiceComplicationBundle: WidgetBundle {
    init() {
        ComplicationTelemetry.start()
    }

    var body: some Widget {
        CodexVoiceComplication()
    }
}

private struct CodexVoiceComplication: Widget {
    let kind = "CodexVoiceTalkComplication"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CodexVoiceProvider()) { _ in
            CodexVoiceComplicationView()
                .containerBackground(for: .widget) { Color.clear }
                .widgetURL(talkURL)
        }
        .configurationDisplayName("Pedro Voice Agent")
        .description("Open Voice Relay. Listening starts automatically.")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryCorner,
            .accessoryRectangular,
            .accessoryInline,
        ])
        .contentMarginsDisabled()
    }
}

private struct CodexVoiceComplicationView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCorner:
            relayMark(size: 32)
        case .accessoryRectangular:
            HStack(spacing: 7) {
                relayMark(size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Relay")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text("Voice agent")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.72))
                }
                Spacer(minLength: 0)
            }
        case .accessoryInline:
            Label {
                Text("Relay")
            } icon: {
                Image(systemName: "waveform")
            }
            .labelStyle(.titleAndIcon)
            .foregroundStyle(.white)
            .widgetAccentable()
        default:
            relayMark(size: 32)
        }
    }

    private func relayMark(size: CGFloat) -> some View {
        Image(systemName: "waveform")
            .resizable()
            .scaledToFit()
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .widgetAccentable()
            .accessibilityLabel("Pedro Voice Agent")
    }
}

#Preview("Relay circular", as: .accessoryCircular) {
    CodexVoiceComplication()
} timeline: {
    CodexVoiceEntry(date: .now)
}

#Preview("Relay corner", as: .accessoryCorner) {
    CodexVoiceComplication()
} timeline: {
    CodexVoiceEntry(date: .now)
}

#Preview("Relay rectangular", as: .accessoryRectangular) {
    CodexVoiceComplication()
} timeline: {
    CodexVoiceEntry(date: .now)
}

#Preview("Relay inline", as: .accessoryInline) {
    CodexVoiceComplication()
} timeline: {
    CodexVoiceEntry(date: .now)
}
