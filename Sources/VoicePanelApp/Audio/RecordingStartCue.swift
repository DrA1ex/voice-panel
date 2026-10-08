import AppKit
import Foundation

@MainActor
enum RecordingStartCue {
    /// The microphone opens after the short confirmation cue has finished, so
    /// the cue does not become the first sound in the captured recording.
    static func play() async {
        if let sound = NSSound(named: NSSound.Name("Tink")) {
            sound.play()
            let playbackDuration = min(max(sound.duration, 0.08), 0.60)
            try? await Task.sleep(for: .seconds(playbackDuration + 0.04))
        } else {
            NSSound.beep()
            try? await Task.sleep(for: .milliseconds(180))
        }
    }
}
