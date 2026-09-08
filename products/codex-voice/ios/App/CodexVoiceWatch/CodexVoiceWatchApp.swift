import SwiftUI
import WidgetKit

@main
struct CodexVoiceWatchApp: App {
    @StateObject private var model: VoiceSessionModel

    init() {
        WatchTelemetry.start()
        let model = VoiceSessionModel()
        _model = StateObject(wrappedValue: model)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .onAppear {
                    WidgetCenter.shared.reloadTimelines(ofKind: "CodexVoiceTalkComplication")
                    model.start()
                }
                .onOpenURL { model.open($0) }
        }
    }
}
