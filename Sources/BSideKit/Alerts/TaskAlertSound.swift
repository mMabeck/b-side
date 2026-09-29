import AppKit
import AVFoundation

public enum TaskAlertSettingsKeys {
    public static let enabled = "settings.notifications.enabled"
    public static let soundsEnabled = "settings.notifications.playSounds"
    public static let finishedSound = "settings.notifications.finishedSound"
    public static let questionSound = "settings.notifications.questionSound"
    public static let volume = "settings.notifications.volume"
}

public enum TaskAlertSound: String, CaseIterable, Identifiable, Sendable {
    case off = "None"
    case basso = "Basso"
    case glass = "Glass"
    case hero = "Hero"
    case ping = "Ping"
    case pop = "Pop"
    case submarine = "Submarine"
    case tink = "Tink"

    public var id: String { rawValue }

    public static let defaultFinished: TaskAlertSound = .glass
    public static let defaultQuestion: TaskAlertSound = .tink

    @MainActor
    public func play(volume: Double) {
        guard self != .off else { return }
        NormalizedSoundPlayer.play(self, volume: Float(max(0, min(100, volume)) / 100))
    }

    static func searchDirectories(fileManager: FileManager = .default) -> [URL] {
        [
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Sounds"),
            URL(fileURLWithPath: "/Library/Sounds"),
            URL(fileURLWithPath: "/System/Library/Sounds"),
        ]
    }

    static let soundExtensions = ["aiff", "aif", "wav", "caf", "m4a", "mp3"]

    static func locate(name: String, in directories: [URL], fileManager: FileManager = .default) -> URL? {
        for directory in directories {
            for ext in soundExtensions {
                let url = directory.appendingPathComponent(name).appendingPathExtension(ext)
                if fileManager.fileExists(atPath: url.path) {
                    return url
                }
            }
        }
        return nil
    }

    var fileURL: URL? {
        Self.locate(name: rawValue, in: Self.searchDirectories())
    }
}

/// System alert sounds peak 5–14 dB below full scale and `NSSound.volume` tops out at 1.0, so samples are scaled up to `targetPeak` at load.
@MainActor
enum NormalizedSoundPlayer {
    /// −1 dBFS: loud, with a little margin against inter-sample clipping.
    static let targetPeak: Float = 0.89

    private static var cache: [TaskAlertSound: Data] = [:]
    /// `AVAudioPlayer` stops when deallocated, so keep recent ones alive.
    private static var playing: [AVAudioPlayer] = []

    static func play(_ sound: TaskAlertSound, volume: Float) {
        guard let data = normalizedWAV(for: sound),
              let player = try? AVAudioPlayer(data: data)
        else { return }
        player.volume = volume
        playing.removeAll { !$0.isPlaying }
        playing.append(player)
        player.play()
    }

    static func normalizedWAV(for sound: TaskAlertSound) -> Data? {
        if let cached = cache[sound] { return cached }
        guard let url = sound.fileURL,
              let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil,
              let channels = buffer.floatChannelData
        else { return nil }
        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        var interleaved = [Float](repeating: 0, count: frameCount * channelCount)
        for frame in 0..<frameCount {
            for channel in 0..<channelCount {
                interleaved[frame * channelCount + channel] = channels[channel][frame]
            }
        }
        let data = wavData(
            samples: normalized(interleaved, targetPeak: targetPeak),
            channels: channelCount,
            sampleRate: Int(buffer.format.sampleRate)
        )
        cache[sound] = data
        return data
    }

    nonisolated static func normalized(_ samples: [Float], targetPeak: Float) -> [Float] {
        let peak = samples.reduce(0) { max($0, abs($1)) }
        guard peak > 0 else { return samples }
        let gain = targetPeak / peak
        return samples.map { $0 * gain }
    }

    nonisolated static func wavData(samples: [Float], channels: Int, sampleRate: Int) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let bytesPerSample = 2
        let payloadSize = samples.count * bytesPerSample
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + payloadSize))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1)) // PCM
        append(UInt16(channels))
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * channels * bytesPerSample))
        append(UInt16(channels * bytesPerSample))
        append(UInt16(bytesPerSample * 8))
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(payloadSize))
        for sample in samples {
            append(Int16(max(-1, min(1, sample)) * Float(Int16.max)))
        }
        return data
    }
}

/// Reads `UserDefaults` directly (outside SwiftUI); defaults mirror `SettingsView`'s since an unwritten key reads back as absent.
public enum TaskAlertSoundPlayer {
    public static let defaultVolume: Double = 70

    public static func resolvedSound(for kind: TaskAlertKind, storedName: String?) -> TaskAlertSound {
        let fallback = kind == .finished ? TaskAlertSound.defaultFinished : TaskAlertSound.defaultQuestion
        guard let storedName else { return fallback }
        return TaskAlertSound(rawValue: storedName) ?? fallback
    }

    public static func resolvedVolume(stored: Double?) -> Double {
        stored ?? defaultVolume
    }

    @MainActor
    public static func play(kind: TaskAlertKind, defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: TaskAlertSettingsKeys.soundsEnabled) as? Bool ?? true else { return }
        let key = kind == .finished ? TaskAlertSettingsKeys.finishedSound : TaskAlertSettingsKeys.questionSound
        let sound = resolvedSound(for: kind, storedName: defaults.string(forKey: key))
        let volume = resolvedVolume(stored: defaults.object(forKey: TaskAlertSettingsKeys.volume) as? Double)
        sound.play(volume: volume)
    }
}
