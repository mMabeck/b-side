import AppKit
import AVFoundation

/// `settings.notifications.*` `@AppStorage` keys, shared between
/// `SettingsView` and the alert-handling code that reads them outside
/// SwiftUI (`TaskAlertSoundPlayer`, `ProjectsStore`).
public enum TaskAlertSettingsKeys {
    public static let enabled = "settings.notifications.enabled"
    public static let soundsEnabled = "settings.notifications.playSounds"
    public static let finishedSound = "settings.notifications.finishedSound"
    public static let questionSound = "settings.notifications.questionSound"
    public static let volume = "settings.notifications.volume"
}

/// One of the macOS system sounds in `/System/Library/Sounds`, offerable as
/// a per-alert-kind notification sound, plus "Off" to silence a kind
/// without disabling notification sounds altogether. `rawValue` is both the
/// persisted `@AppStorage` string and the name `NSSound(named:)` expects.
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

    var fileURL: URL {
        URL(fileURLWithPath: "/System/Library/Sounds/\(rawValue).aiff")
    }
}

/// Plays alert sounds peak-normalised to just under full scale.
///
/// The system alert sounds peak 5–14 dB below full scale, so even at 100%
/// `NSSound` played them quietly and there was no way to go louder:
/// `NSSound.volume`/`AVAudioPlayer.volume` top out at 1.0. Scaling each
/// sound's samples up to `targetPeak` once, at load, makes 100% as loud as
/// the sound can get without clipping, and levels the sounds against each
/// other.
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
        guard let file = try? AVAudioFile(forReading: sound.fileURL),
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

    /// Scales `samples` so their peak magnitude is `targetPeak`. Silence is
    /// returned unchanged.
    nonisolated static func normalized(_ samples: [Float], targetPeak: Float) -> [Float] {
        let peak = samples.reduce(0) { max($0, abs($1)) }
        guard peak > 0 else { return samples }
        let gain = targetPeak / peak
        return samples.map { $0 * gain }
    }

    /// A 16-bit PCM WAV file holding interleaved `samples`.
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

/// Plays the configured sound for an alert kind, reading settings directly
/// from `UserDefaults` — the alert-handling path runs outside SwiftUI, so it
/// can't read `@AppStorage` bindings the way `SettingsView` does. Defaults
/// mirror the ones `SettingsView`'s `@AppStorage` declares, since a key
/// `@AppStorage` has never written yet reads back as absent, not as its
/// SwiftUI-side default.
public enum TaskAlertSoundPlayer {
    public static let defaultVolume: Double = 70

    /// Pure so it's directly testable: the sound a kind resolves to given
    /// whatever `@AppStorage` string (or `nil`, if never written) is stored
    /// for it.
    public static func resolvedSound(for kind: TaskAlertKind, storedName: String?) -> TaskAlertSound {
        let fallback = kind == .finished ? TaskAlertSound.defaultFinished : TaskAlertSound.defaultQuestion
        guard let storedName else { return fallback }
        return TaskAlertSound(rawValue: storedName) ?? fallback
    }

    /// Pure so it's directly testable: the volume to play at given whatever
    /// `@AppStorage` value (or `nil`, if never written) is stored.
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
