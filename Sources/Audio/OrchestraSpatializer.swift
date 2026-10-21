import AVFoundation
import Accelerate

/// Stage coordinates as seen by the conductor: left −1…right +1, front 0…back 1.
public struct StagePosition: Equatable, Hashable, Sendable {
    public let x: Double
    public let depth: Double

    public init(x: Double, depth: Double) {
        self.x = x.isFinite ? min(1, max(-1, x)) : 0
        self.depth = depth.isFinite ? min(1, max(0, depth)) : 0.35
    }

    /// A common modern (American) seating, rather than audience-facing coordinates.
    public static func orchestral(instrument: Instrument, partName: String) -> Self {
        switch instrument.id {
        case "violin":
            let second = partName.range(of: #"(?i)(?:\b(?:ii|2|second|2nd)\b|第[二2２]|(?:violin|violino|vln|vn)\s*(?:ii|2)$)"#,
                                        options: .regularExpression) != nil
            return Self(x: second ? -0.35 : -0.78, depth: second ? 0.28 : 0.12)
        case "viola": return Self(x: 0.26, depth: 0.22)
        case "cello", "cello_bass": return Self(x: 0.70, depth: 0.15)
        case "contrabass": return Self(x: 0.88, depth: 0.43)
        case "harp": return Self(x: -0.88, depth: 0.48)
        case "flute", "piccolo", "recorder": return Self(x: -0.22, depth: 0.46)
        case "oboe", "english_horn": return Self(x: 0.16, depth: 0.46)
        case "clarinet": return Self(x: -0.20, depth: 0.60)
        case "bassoon": return Self(x: 0.22, depth: 0.60)
        case "horn": return Self(x: -0.58, depth: 0.70)
        case "trumpet", "muted_trumpet": return Self(x: 0.22, depth: 0.74)
        case "trombone": return Self(x: 0.52, depth: 0.80)
        case "tuba": return Self(x: 0.78, depth: 0.82)
        case "timpani": return Self(x: -0.10, depth: 0.92)
        case "choir": return Self(x: 0, depth: 1)
        default:
            if instrument.isDrums || instrument.category == "有音程打楽器" {
                return Self(x: -0.65, depth: 0.88)
            }
            return Self(x: 0, depth: 0.30)
        }
    }

    /// Direction at a listener on the podium; distance narrows the apparent angle.
    var pan: Double {
        let lateral = x * 8
        let forward = 3 + depth * 9
        return lateral / hypot(lateral, forward)
    }
}

/// Deterministic stereo rendering shared by live playback and offline export.
/// The default uses measured CIPIC head/ear impulse responses, including their
/// time, level and spectral cues. The analytic reference remains available for
/// comparison. Both render point sources from stereo soundfont samples; room
/// reflections and distance cues remain adjustable independently of the profile.
final class OrchestraSpatializer {
    private final class Entry {
        let source: AVAudioPCMBuffer // Keep identity alive while the cache key exists.
        let output: AVAudioPCMBuffer
        init(source: AVAudioPCMBuffer, output: AVAudioPCMBuffer) {
            self.source = source
            self.output = output
        }
    }
    private let cache = NSCache<NSString, Entry>()

    init() { cache.totalCostLimit = 24 * 1024 * 1024 }

    func render(_ source: AVAudioPCMBuffer, at originalPosition: StagePosition,
                settings: HeadphoneSettings = HeadphoneSettings()) -> AVAudioPCMBuffer {
        let position = StagePosition(x: originalPosition.x * settings.width, depth: originalPosition.depth)
        let key = "\(ObjectIdentifier(source))|\(position.x)|\(position.depth)|\(settings.profile.rawValue)|\(settings.room)" as NSString
        if let entry = cache.object(forKey: key) { return entry.output }
        let count = Int(source.frameLength)
        guard count > 0, let input = source.floatChannelData,
              source.format.channelCount == 2,
              source.format.sampleRate == SoundFontPlayer.sampleRate else { return source }
        let rate = source.format.sampleRate
        let pan = position.pan
        if settings.profile != .reference,
           let direction = HeadphoneHRTF.direction(profile: settings.profile, azimuth: asin(pan) * 180 / .pi) {
            let output = renderMeasured(source, position: position, settings: settings, direction: direction)
            cache.setObject(Entry(source: source, output: output), forKey: key,
                            cost: (count + Int(output.frameLength)) * 2 * MemoryLayout<Float>.size)
            return output
        }
        let delay = abs(pan) * 0.00065 * rate
        let reflectionA = Int((0.014 + position.depth * 0.012) * rate)
        let reflectionB = Int((0.027 + position.depth * 0.016) * rate)
        let frames = count + reflectionB + Int(ceil(delay)) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: source.format,
                                           frameCapacity: AVAudioFrameCount(frames)) else { return source }
        output.frameLength = AVAudioFrameCount(frames)
        var mono = [Float](repeating: 0, count: frames)
        mono.withUnsafeMutableBufferPointer { samples in
            vDSP_vadd(input[0], 1, input[1], 1, samples.baseAddress!, 1, vDSP_Length(count))
            var half: Float = 0.5
            vDSP_vsmul(samples.baseAddress!, 1, &half, samples.baseAddress!, 1, vDSP_Length(count))
        }
        let cutoff = 18000 - position.depth * 10000
        let alpha = Float(1 - exp(-2 * Double.pi * cutoff / rate))
        var filtered: Float = 0
        for i in 0..<frames {
            filtered += alpha * (mono[i] - filtered)
            mono[i] = filtered
        }
        let distanceGain = Float(1 / (1 + position.depth * 0.38))
        let gains = [Float(cos((pan + 1) * .pi / 4)), Float(sin((pan + 1) * .pi / 4))]
        for channel in 0..<2 {
            let farEar = (pan > 0 && channel == 0) || (pan < 0 && channel == 1)
            let channelDelay = farEar ? delay : 0
            let integerDelay = Int(channelDelay)
            let fraction = Float(channelDelay - Double(integerDelay))
            let data = output.floatChannelData![channel]
            var shaded: Float = 0
            let earAlpha: Float = farEar ? Float(1 - exp(-2 * Double.pi * (14000 - abs(pan) * 9000) / rate)) : 1
            let reflectionGain = Float((0.05 + position.depth * 0.11) * settings.room)
            for i in 0..<frames {
                let j = i - integerDelay
                let a: Float = j >= 0 ? mono[j] : 0
                let b: Float = j > 0 ? mono[j - 1] : 0
                shaded += earAlpha * ((a * (1 - fraction) + b * fraction) - shaded)
                let earlyA: Float = i >= reflectionA ? mono[i - reflectionA] : 0
                let earlyB: Float = i >= reflectionB ? mono[i - reflectionB] : 0
                data[i] = distanceGain * (shaded * gains[channel]
                    + reflectionGain * (earlyA + earlyB * 0.55))
            }
        }
        cache.setObject(Entry(source: source, output: output), forKey: key,
                        cost: (count + frames) * 2 * MemoryLayout<Float>.size)
        return output
    }
    private func renderMeasured(_ source: AVAudioPCMBuffer, position: StagePosition,
                                settings: HeadphoneSettings, direction: HeadphoneHRTF.Direction) -> AVAudioPCMBuffer {
        let count = Int(source.frameLength)
        let rate = source.format.sampleRate
        // Deliberately mild distance shading; preserve the high-frequency
        // pinna features that the previous steep low-pass could obscure.
        let alpha = Float(1 - exp(-2 * Double.pi * (19000 - position.depth * 5000) / rate))
        let gain = Float(1 / (1 + position.depth * 0.38))
        var mono = [Float](repeating: 0, count: count)
        var low: Float = 0
        for i in 0..<count {
            let sample = (source.floatChannelData![0][i] + source.floatChannelData![1][i]) * 0.5
            low += alpha * (sample - low)
            mono[i] = low * gain
        }
        let ears = [HeadphoneHRTF.convolve(mono, filter: direction.left),
                    HeadphoneHRTF.convolve(mono, filter: direction.right)]
        // Different reflection arrivals at each ear: identical L/R ambience
        // alone does not provide the binaural room cues reported in research.
        let delays = [[0.017, 0.033, 0.057], [0.023, 0.041, 0.071]]
        let tail = settings.room > 0 ? Int((0.071 + position.depth * 0.010) * rate) : 0
        let frames = ears[0].count + tail
        guard let output = AVAudioPCMBuffer(pcmFormat: source.format,
                                           frameCapacity: AVAudioFrameCount(frames)) else { return source }
        output.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<2 {
            let data = output.floatChannelData![channel]
            data.initialize(repeating: 0, count: frames)
            ears[channel].withUnsafeBufferPointer { ear in
                data.update(from: ear.baseAddress!, count: ear.count)
            }
            for reflection in 0..<3 where settings.room > 0 {
                let offset = Int((delays[channel][reflection] + position.depth * 0.010) * rate)
                let amplitude = Float(settings.room * (0.065 + position.depth * 0.12) / Double(reflection + 1))
                // Cross-ear contribution decorrelates reflections without
                // reversing polarity or destroying the direct source's cues.
                let reflected = ears[1 - channel]
                for i in 0..<reflected.count {
                    data[i + offset] += reflected[i] * amplitude
                }
            }
        }
        return output
    }

}
