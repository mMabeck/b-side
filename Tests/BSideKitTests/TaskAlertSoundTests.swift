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

    // MARK: - Sound file lookup

    @Test("Locate searches directories in order and stops at the first match")
    func locateSearchesDirectoriesInOrder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first = root.appendingPathComponent("first")
        let second = root.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        FileManager.default.createFile(atPath: second.appendingPathComponent("Custom.wav").path, contents: Data())
        #expect(TaskAlertSound.locate(name: "Custom", in: [first, second]) == second.appendingPathComponent("Custom.wav"))

        FileManager.default.createFile(atPath: first.appendingPathComponent("Custom.aiff").path, contents: Data())
        #expect(TaskAlertSound.locate(name: "Custom", in: [first, second]) == first.appendingPathComponent("Custom.aiff"))
    }

    @Test("Locate tries extensions in order within a directory")
    func locateTriesExtensionsInOrder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        FileManager.default.createFile(atPath: dir.appendingPathComponent("Custom.mp3").path, contents: Data())
        #expect(TaskAlertSound.locate(name: "Custom", in: [dir]) == dir.appendingPathComponent("Custom.mp3"))

        FileManager.default.createFile(atPath: dir.appendingPathComponent("Custom.wav").path, contents: Data())
        #expect(TaskAlertSound.locate(name: "Custom", in: [dir]) == dir.appendingPathComponent("Custom.wav"))
    }

    @Test("Locate returns nil when no directory has a matching file")
    func locateReturnsNilWhenNotFound() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(TaskAlertSound.locate(name: "NoSuchSound", in: [dir]) == nil)
    }

    @Test("Search directories are user sounds, then machine sounds, then system sounds")
    func searchDirectoriesOrder() {
        let dirs = TaskAlertSound.searchDirectories()
        #expect(dirs == [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Sounds"),
            URL(fileURLWithPath: "/Library/Sounds"),
            URL(fileURLWithPath: "/System/Library/Sounds"),
        ])
    }

    // MARK: - Defaults

    @Test("Finished defaults to Glass, question defaults to Tink")
    func kindDefaults() {
        #expect(TaskAlertSound.defaultFinished == .glass)
        #expect(TaskAlertSound.defaultQuestion == .tink)
    }

    @Test("Resolving a sound falls back to the kind's default when nothing/unknown is stored, and uses a valid stored name", arguments: [
        (kind: TaskAlertKind.finished, stored: nil, expected: TaskAlertSound.glass),
        (kind: TaskAlertKind.question, stored: nil, expected: TaskAlertSound.tink),
        (kind: TaskAlertKind.finished, stored: "Hero", expected: TaskAlertSound.hero),
        (kind: TaskAlertKind.question, stored: "NotARealSound", expected: TaskAlertSound.tink),
    ])
    func resolvedSound(kind: TaskAlertKind, stored: String?, expected: TaskAlertSound) {
        #expect(TaskAlertSoundPlayer.resolvedSound(for: kind, storedName: stored) == expected)
    }

    @Test("Volume defaults to 70% when nothing is stored, and a stored volume is used as-is", arguments: [(stored: nil, expected: 70.0), (stored: 35.0, expected: 35.0)] as [(Double?, Double)])
    func resolvedVolume(stored: Double?, expected: Double) {
        #expect(TaskAlertSoundPlayer.resolvedVolume(stored: stored) == expected)
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
