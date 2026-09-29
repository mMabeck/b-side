import AVFoundation
import Foundation
import Testing

@testable import BSideKit

@Suite("Task alert sounds and settings")
struct TaskAlertSoundTests {

    @Test("Resolving a sound falls back to the kind's default when nothing/unknown is stored, and uses a valid stored name", arguments: [
        (kind: TaskAlertKind.finished, stored: nil, expected: TaskAlertSound.glass),
        (kind: TaskAlertKind.question, stored: nil, expected: TaskAlertSound.tink),
        (kind: TaskAlertKind.finished, stored: "Hero", expected: TaskAlertSound.hero),
        (kind: TaskAlertKind.question, stored: "NotARealSound", expected: TaskAlertSound.tink),
    ])
    func resolvedSound(kind: TaskAlertKind, stored: String?, expected: TaskAlertSound) {
        #expect(TaskAlertSoundPlayer.resolvedSound(for: kind, storedName: stored) == expected)
    }


    @Test("normalising scales the peak to the target and leaves silence alone")
    func normalisationHitsTargetPeak() {
        let scaled = NormalizedSoundPlayer.normalized([0.1, -0.25, 0.05], targetPeak: 0.9)
        #expect(abs(scaled.map(abs).max()! - 0.9) < 0.0001)
        #expect(abs(scaled[0] - 0.36) < 0.0001)
        #expect(NormalizedSoundPlayer.normalized([0, 0], targetPeak: 0.9) == [0, 0])
    }

    @Test("every offered sound loads as a playable WAV peaking at the target")
    @MainActor
    func everySoundNormalisesToTargetPeak() throws {
        for sound in TaskAlertSound.allCases where sound != .off {
            let data = try #require(NormalizedSoundPlayer.normalizedWAV(for: sound), "\(sound.rawValue)")
            _ = try AVAudioPlayer(data: data)

            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
            try data.write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            let file = try AVAudioFile(forReading: url)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
            try file.read(into: buffer)
            let channels = try #require(buffer.floatChannelData)
            var peak: Float = 0
            for channel in 0..<Int(buffer.format.channelCount) {
                for frame in 0..<Int(buffer.frameLength) { peak = max(peak, abs(channels[channel][frame])) }
            }
            #expect(abs(peak - NormalizedSoundPlayer.targetPeak) < 0.01, "\(sound.rawValue) peaked at \(peak)")
        }
    }
}
