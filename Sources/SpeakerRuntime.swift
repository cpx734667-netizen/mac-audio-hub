import Foundation

/// Owns the MacSpeaker subsystem inside the combined app. It starts immediately
/// and runs alongside AirMic on its own port, server queue, and audio engine.
@MainActor
final class SpeakerRuntime: ObservableObject {
    let model: SpeakerModel
    let controller: AppController

    init() {
        let speakerModel = SpeakerModel()
        self.model = speakerModel
        self.controller = AppController(model: speakerModel)
        controller.start(checkPermission: true)
    }

    func shutdown() {
        controller.shutdown()
    }
}
