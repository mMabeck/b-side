import AVFoundation
import Foundation
import Testing

@testable import BSideKit

@Suite("Task alert sounds and settings")
struct TaskAlertSoundTests {
    // MARK: - Sound-name list

    @Test("Every sound name other than Off matches a real system sound file")
    func soundNamesMatchSystemSoundFiles() {
        for sound in TaskAlertSound.allCases where sound != .off {
            let path = "/System/Library/Sounds/\(sound.rawValue).aiff"
            #expect(FileManager.default.fileExists(atPath: path), "missing system sound for \(sound.rawValue)")
        }
    }

    @Test("Off is offered alongside the system sounds")
    func offIsOfferedAsASilentChoice() {
        #expect(TaskAlertSound.allCases.contains(.off))
        #expect(TaskAlertSound.off.rawValue == "None")
    }

    @Test("Sound ids are unique")
    func soundIdsAreUnique() {
        let ids = TaskAlertSound.allCases.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    // MARK: - Defaults

    @Test("Finished defaults to Glass, question defaults to Tink")
    func kindDefaults() {
        #expect(TaskAlertSound.defaultFinished == .glass)
        #expect(TaskAlertSound.defaultQuestion == .tink)
    }

    @Test("Resolving a sound with no stored value falls back to the kind's default")
    func resolvedSoundFallsBackToDefaultWhenNothingStored() {
        #expect(TaskAlertSoundPlayer.resolvedSound(for: .finished, storedName: nil) == .glass)
        #expect(TaskAlertSoundPlayer.resolvedSound(for: .question, storedName: nil) == .tink)
    }

    @Test("Resolving a sound with a valid stored name uses it")
    func resolvedSoundUsesStoredValue() {
        #expect(TaskAlertSoundPlayer.resolvedSound(for: .finished, storedName: "Hero") == .hero)
    }

    @Test("Resolving a sound with a stale/unknown stored name falls back")
    func resolvedSoundFallsBackOnUnknownStoredValue() {
        #expect(TaskAlertSoundPlayer.resolvedSound(for: .question, storedName: "NotARealSound") == .tink)
    }

    @Test("Volume defaults to 70% when nothing is stored")
    func resolvedVolumeDefaults() {
        #expect(TaskAlertSoundPlayer.resolvedVolume(stored: nil) == 70)
    }

    @Test("A stored volume is used as-is")
    func resolvedVolumeUsesStoredValue() {
        #expect(TaskAlertSoundPlayer.resolvedVolume(stored: 35) == 35)
    }

    // MARK: - Settings keys

    @Test("Settings keys live under the settings.notifications namespace")
    func settingsKeysNamespace() {
        #expect(TaskAlertSettingsKeys.enabled == "settings.notifications.enabled")
        #expect(TaskAlertSettingsKeys.soundsEnabled == "settings.notifications.playSounds")
        #expect(TaskAlertSettingsKeys.finishedSound == "settings.notifications.finishedSound")
        #expect(TaskAlertSettingsKeys.questionSound == "settings.notifications.questionSound")
        #expect(TaskAlertSettingsKeys.volume == "settings.notifications.volume")
    }

    // MARK: - Loudness

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
