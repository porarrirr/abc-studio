import AVFoundation
import Accelerate

public enum HeadphoneProfile: String, Codable, CaseIterable, Identifiable, Sendable {
    case a, b, c, reference
    public var id: String { rawValue }
    var label: String {
        switch self {
        case .a: return "候補 A"
        case .b: return "候補 B"
        case .c: return "候補 C"
        case .reference: return "従来の定位"
        }
    }
}

public struct HeadphoneSettings: Codable, Equatable, Hashable, Sendable {
    public let profile: HeadphoneProfile
    public let room: Double
    public let width: Double
    public init(profile: HeadphoneProfile = .a, room: Double = 0.5, width: Double = 1) {
        self.profile = profile
        self.room = room.isFinite ? min(1, max(0, room)) : 0.5
        self.width = width.isFinite ? min(1.25, max(0.75, width)) : 1
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(profile: try values.decode(HeadphoneProfile.self, forKey: .profile),
                  room: try values.decode(Double.self, forKey: .room),
                  width: try values.decode(Double.self, forKey: .width))
    }
    var reverbMix: Float { Float(room * 20) }
}

/// Measured CIPIC HRIRs: 25 horizontal frontal directions, 200 taps, 44.1kHz.
/// Preserve measured ITD/ILD and pinna notches; never add a second synthetic
/// delay/pan on top. Nearest measured direction avoids phase cancellation from
/// interpolating unaligned FIRs. SOFA +azimuth is left; extraction flips to right.
enum HeadphoneHRTF {
    struct Direction: Decodable {
        let azimuth: Double
        let left: [Float]
        let right: [Float]
    }
    private struct Profile: Decodable { let id: String; let directions: [Direction] }
    private struct Database: Decodable { let sampleRate: Double; let profiles: [Profile] }
    private static let database: Database? = {
        guard let url = Bundle.main.url(forResource: "HeadphoneHRTF", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let database = try? JSONDecoder().decode(Database.self, from: data),
              database.sampleRate == SoundFontPlayer.sampleRate,
              database.profiles.count == 3,
              database.profiles.allSatisfy({ profile in
                  profile.directions.count == 25 && profile.directions.allSatisfy {
                      $0.left.count == 200 && $0.right.count == 200
                          && ($0.left + $0.right).allSatisfy(\.isFinite)
                  }
              }) else { return nil }
        return database
    }()
    static var isAvailable: Bool { database != nil }
    static func direction(profile: HeadphoneProfile, azimuth: Double) -> Direction? {
        database?.profiles.first { $0.id == profile.rawValue }?.directions.min {
            abs($0.azimuth - azimuth) < abs($1.azimuth - azimuth)
        }
    }

    /// Full linear convolution; zero padding keeps the complete 199-sample tail.
    static func convolve(_ input: [Float], filter: [Float]) -> [Float] {
        guard !input.isEmpty, !filter.isEmpty else { return [] }
        let padding = filter.count - 1
        let padded = [Float](repeating: 0, count: padding) + input + [Float](repeating: 0, count: padding)
        let resultCount = input.count + padding
        var result = [Float](repeating: 0, count: resultCount)
        padded.withUnsafeBufferPointer { samples in
            filter.withUnsafeBufferPointer { coefficients in
                result.withUnsafeMutableBufferPointer { output in
                    vDSP_conv(samples.baseAddress!, 1, coefficients.baseAddress! + padding, -1,
                              output.baseAddress!, 1, vDSP_Length(resultCount), vDSP_Length(filter.count))
                }
            }
        }
        return result
    }
}

/// The same deterministic broadband burst for every candidate and position.
/// A short raised-cosine envelope prevents clicks; modest fixed gain avoids a
/// loudness-based recommendation. No user microphone data or ear images needed.
enum HeadphoneTrial {
    static let positions = [StagePosition(x: -0.8, depth: 0.2), StagePosition(x: 0, depth: 0.2),
                            StagePosition(x: 0.8, depth: 0.2), StagePosition(x: 0, depth: 0),
                            StagePosition(x: 0, depth: 1)]
    static let labels = ["左前", "正面", "右前", "手前", "舞台奥"]
    static func signal() -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: SoundFontPlayer.sampleRate, channels: 2)!
        let count = 15435
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        var seed: UInt32 = 0x12345678
        var low: Float = 0
        for i in 0..<count {
            seed = seed &* 1664525 &+ 1013904223
            let white = Float(Double(seed) / Double(UInt32.max) * 2 - 1)
            low = low * 0.92 + white * 0.08
            let envelope = Float(min(1, Double(min(i, count - 1 - i)) / 882))
            let value = (low * 0.20 + white * 0.07) * envelope
            buffer.floatChannelData![0][i] = value
            buffer.floatChannelData![1][i] = value
        }
        return buffer
    }
    static func sequence() -> PlaybackSequence {
        let tracks = positions.indices.map { index in
            PlaybackTrack(voiceID: "trial-\(index)", name: labels[index], isPercussion: false,
                          events: [PlaybackEvent(elementID: index, midi: 60, startBeat: Double(index * 2),
                                                 durationBeats: 0.7, velocity: 80)])
        }
        return PlaybackSequence(tracks: tracks, tempoMap: [TempoPoint(beat: 0, quarterNoteBPM: 120)], totalBeats: 10)
    }
}
