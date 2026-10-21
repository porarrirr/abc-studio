import Foundation
import AVFoundation
import Accelerate

/// Turns bundled soundfont directories (`<dir>/<NoteName>.m4a`, C4=60) into
/// ready-to-schedule AVAudioPCMBuffers: the nearest available sample is decoded,
/// pitch-shifted by linear resampling, truncated to the note length with a
/// baked release fade, and scaled by velocity.
///
/// The bundled samples are rendered per-note from the FluidR3_GM soundfont by
/// `scripts/render_soundfont.swift` and normalised per instrument (~0.8 peak),
/// so `volumeMultiplier` only needs to undo the velocity scaling, not rescue
/// a quiet source.
public final class SoundFontPlayer {
    public static let sampleRate: Double = 44100
    public let format = AVAudioFormat(standardFormatWithSampleRate: SoundFontPlayer.sampleRate,
                                      channels: 2)!

    /// Overall gain. The rendered samples are already loud (~0.8 peak), so
    /// anything above ~1.2 just pushes the mix into the limiter.
    public var volumeMultiplier: Float = 1.0
    /// Fade baked into the tail of every generated buffer (abcjs fadeLength = 120ms).
    public var releaseFade: TimeInterval = 0.12
    /// Extra seconds the sample may ring out past the note's end, so sustained
    /// tones decay naturally instead of stopping dead at the note boundary.
    public var sustainTail: TimeInterval = 1.0
    /// Very short notes (grace notes, 32nds) still need enough sample to speak.
    public var minimumDuration: TimeInterval = 0.30
    /// Caps per-event buffer memory (8s stereo ≈ 2.8MB per event).
    public var maximumDuration: TimeInterval = 8.0
    /// Soft-clip knee/limit: samples below `knee` pass through untouched, above
    /// it the curve approaches `clipLevel` asymptotically (no harsh hard clip).
    public var clipKnee: Float = 0.7
    public var clipLevel: Float = 0.98

    private struct DirIndex {
        var midis: [Int]                 // sorted
        var fileNames: [Int: String]     // midi → file name on disk
    }
    private var dirIndex: [String: DirIndex] = [:]
    private var dirURLs: [String: URL?] = [:]
    private var missingDirs = Set<String>()
    /// Decoded (format-converted) source samples, keyed "dir|fileMidi".
    private let decodedCache = NSCache<NSString, AVAudioPCMBuffer>()
    private final class PitchedSample {
        let buffer: AVAudioPCMBuffer
        let peak: Float
        init(_ buffer: AVAudioPCMBuffer) {
            self.buffer = buffer
            var maximum: Float = 0
            for channel in 0..<Int(buffer.format.channelCount) {
                var value: Float = 0
                vDSP_maxmgv(buffer.floatChannelData![channel], 1, &value,
                            vDSP_Length(buffer.frameLength))
                maximum = max(maximum, value)
            }
            peak = maximum
        }
    }
    /// Pitch-shifted samples and their peaks, keyed "dir|targetMidi".
    private let pitchedCache = NSCache<NSString, PitchedSample>()
    /// Final buffers are immutable after creation and can be shared by repeated
    /// notes, seeks and loops. Both entries and memory remain bounded.
    private let eventCache = NSCache<NSString, AVAudioPCMBuffer>()
    private final class FadeEnvelope {
        let values: [Float]
        init(count: Int) {
            values = (0..<count).map {
                Float(0.5 * (1 + cos(Double.pi * Double($0) / Double(count))))
            }
        }
    }
    private let fadeCache = NSCache<NSNumber, FadeEnvelope>()
    private let lock = NSLock()

    public init() {
        // Rendered notes can run long (piano decay ≈ 10 s ≈ 3.5 MB stereo);
        // bound the caches by bytes so heavy tunes can't balloon memory.
        decodedCache.totalCostLimit = 300 * 1024 * 1024
        pitchedCache.totalCostLimit = 300 * 1024 * 1024
        eventCache.totalCostLimit = 16 * 1024 * 1024
        eventCache.countLimit = 256
        fadeCache.totalCostLimit = 8 * 1024 * 1024
    }

    // MARK: - Public API

    /// Builds a buffer for one event: `seconds` long (in output time), velocity gain.
    /// Returns nil when the soundfont dir is missing or undecodable.
    /// Returned buffers are shared and must be treated as read-only.
    public func makeBuffer(dir: String, midi: Int, seconds: TimeInterval, velocity: Double)
        -> AVAudioPCMBuffer? {
        guard let sample = pitchedBuffer(dir: dir, midi: midi) else { return nil }
        let source = sample.buffer
        let clamped = min(max(seconds, minimumDuration), maximumDuration)
        let wanted = max(1, AVAudioFrameCount((clamped * Self.sampleRate).rounded(.up)))
        let tailFrames = AVAudioFrameCount((sustainTail * Self.sampleRate).rounded(.down))
        let frames = min(wanted + tailFrames, source.frameLength)
        var gain = Float(velocity / 127.0) * volumeMultiplier
        let fadeFrames = AVAudioFrameCount((releaseFade * Self.sampleRate).rounded(.down))
        let fadeStart = frames > fadeFrames ? Int(frames - fadeFrames) : 0
        let fadeLen = max(1, Int(frames) - fadeStart)
        let key = "\(dir)|\(midi)|\(frames)|\(gain.bitPattern)|\(fadeLen)|\(clipKnee.bitPattern)|\(clipLevel.bitPattern)" as NSString
        if let cached = eventCache.object(forKey: key) { return cached }
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            return nil
        }
        out.frameLength = frames
        let fadeKey = NSNumber(value: fadeLen)
        let fade: FadeEnvelope
        if let cached = fadeCache.object(forKey: fadeKey) {
            fade = cached
        } else {
            fade = FadeEnvelope(count: fadeLen)
            fadeCache.setObject(fade, forKey: fadeKey, cost: fadeLen * MemoryLayout<Float>.size)
        }
        for channel in 0..<Int(format.channelCount) {
            let src = source.floatChannelData![channel]
            let dst = out.floatChannelData![channel]
            vDSP_vsmul(src, 1, &gain, dst, 1, vDSP_Length(frames))
            // Most notes are below the soft-clip knee. Avoid scalar processing
            // entirely for them; preserve the original curve for louder notes.
            if sample.peak * abs(gain) > clipKnee {
                let limit = clipLevel - clipKnee
                for i in 0..<Int(frames) {
                    let sample = dst[i]
                    let magnitude = abs(sample)
                    if magnitude > clipKnee {
                        let over = magnitude - clipKnee
                        dst[i] = copysign(clipKnee + over * limit / (limit + over), sample)
                    }
                }
            }
            fade.values.withUnsafeBufferPointer { envelope in
                vDSP_vmul(dst + fadeStart, 1, envelope.baseAddress!, 1,
                          dst + fadeStart, 1, vDSP_Length(Int(frames) - fadeStart))
            }
        }
        eventCache.setObject(out, forKey: key, cost: byteSize(of: out))
        return out
    }

    /// Parses a soundfont file stem like "Gb4" → 66 (C4=60). Accepts sharps too.
    public static func midi(forNoteName name: String) -> Int? {
        let chars = Array(name)
        guard !chars.isEmpty else { return nil }
        let base: Int
        switch chars[0].uppercased() {
        case "C": base = 0
        case "D": base = 2
        case "E": base = 4
        case "F": base = 5
        case "G": base = 7
        case "A": base = 9
        case "B": base = 11
        default: return nil
        }
        var semitone = base
        var index = 1
        if index < chars.count {
            if chars[index] == "#" { semitone += 1; index += 1 }
            else if chars[index] == "b" { semitone -= 1; index += 1 }
        }
        guard index < chars.count, let octave = Int(String(chars[index...])) else { return nil }
        return (octave + 1) * 12 + semitone
    }

    // MARK: - Directory lookup

    /// SoundFont/<dir> inside the bundle resources first, bundle root second.
    /// dirURLs/missingDirs は makeBuffer が先読みキューからも呼ばれるため lock で保護する。
    private func directoryURL(_ dir: String) -> URL? {
        lock.lock()
        let cached = dirURLs[dir]
        lock.unlock()
        if let cached { return cached }
        var found: URL?
        if let resources = Bundle.main.resourceURL {
            let nested = resources.appendingPathComponent("SoundFont", isDirectory: true)
                                  .appendingPathComponent(dir, isDirectory: true)
            if FileManager.default.fileExists(atPath: nested.path) {
                found = nested
            } else {
                let root = resources.appendingPathComponent(dir, isDirectory: true)
                if FileManager.default.fileExists(atPath: root.path) { found = root }
            }
        }
        lock.lock()
        dirURLs[dir] = found
        // insert().inserted で初回のみ(見つからなかった dir を index() 側で二重に鳴らさない)
        let shouldLog = found == nil && missingDirs.insert(dir).inserted
        lock.unlock()
        if shouldLog {
            print("[SoundFontPlayer] soundfont directory not found in bundle: \(dir)")
        }
        return found
    }

    private func index(for dir: String) -> DirIndex {
        lock.lock()
        let cached = dirIndex[dir]
        lock.unlock()
        if let cached { return cached }
        var result = DirIndex(midis: [], fileNames: [:])
        if let url = directoryURL(dir),
           let files = try? FileManager.default.contentsOfDirectory(atPath: url.path) {
            for file in files {
                let lower = file.lowercased()
                let stem: String
                if lower.hasSuffix(".m4a") { stem = String(file.dropLast(4)) }
                else if lower.hasSuffix(".mp3") { stem = String(file.dropLast(4)) }
                else { continue }
                if let midi = Self.midi(forNoteName: stem) {
                    result.fileNames[midi] = file
                }
            }
            result.midis = result.fileNames.keys.sorted()
        }
        lock.lock()
        dirIndex[dir] = result
        let shouldLog = result.midis.isEmpty && missingDirs.insert(dir).inserted
        lock.unlock()
        if shouldLog {
            print("[SoundFontPlayer] no usable sample files in \(dir)")
        }
        return result
    }

    // MARK: - Buffer pipeline

    /// Resampled (pitch-shifted) buffer for a target midi, cached per (dir, midi).
    private func pitchedBuffer(dir: String, midi: Int) -> PitchedSample? {
        let key = "\(dir)|\(midi)" as NSString
        lock.lock()
        let hit = pitchedCache.object(forKey: key)
        lock.unlock()
        if let hit = hit { return hit }

        let index = index(for: dir)
        guard let nearest = nearestMidi(to: midi, in: index.midis),
              let decoded = decodedBuffer(dir: dir, fileMidi: nearest, index: index) else {
            return nil
        }
        let semitones = midi - nearest
        let result = semitones == 0 ? decoded : resample(decoded, semitones: semitones)
        let sample = PitchedSample(result)
        lock.lock()
        pitchedCache.setObject(sample, forKey: key, cost: byteSize(of: result))
        lock.unlock()
        return sample
    }

    private func nearestMidi(to target: Int, in midis: [Int]) -> Int? {
        guard !midis.isEmpty else { return nil }
        var lo = 0, hi = midis.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if midis[mid] < target { lo = mid + 1 } else { hi = mid }
        }
        var best = midis[min(lo, midis.count - 1)]
        if lo > 0, target - midis[lo - 1] < abs(best - target) {
            best = midis[lo - 1]
        }
        return best
    }

    /// MP3 file → PCM buffer in `format`, cached per (dir, fileMidi).
    private func decodedBuffer(dir: String, fileMidi: Int, index: DirIndex)
        -> AVAudioPCMBuffer? {
        let key = "\(dir)|\(fileMidi)" as NSString
        lock.lock()
        let hit = decodedCache.object(forKey: key)
        lock.unlock()
        if let hit = hit { return hit }

        guard let fileName = index.fileNames[fileMidi],
              let base = directoryURL(dir) else { return nil }
        let url = base.appendingPathComponent(fileName)
        guard let audioFile = try? AVAudioFile(forReading: url) else {
            print("[SoundFontPlayer] cannot open \(url.lastPathComponent)")
            return nil
        }
        let srcFormat = audioFile.processingFormat
        guard let raw = AVAudioPCMBuffer(pcmFormat: srcFormat,
                                         frameCapacity: AVAudioFrameCount(audioFile.length)) else {
            return nil
        }
        do { try audioFile.read(into: raw) } catch {
            print("[SoundFontPlayer] decode failed for \(url.lastPathComponent): \(error)")
            return nil
        }
        var result = raw
        if srcFormat != format {
            guard let converted = convert(raw) else { return nil }
            result = converted
        }
        lock.lock()
        decodedCache.setObject(result, forKey: key, cost: byteSize(of: result))
        lock.unlock()
        return result
    }

    private func byteSize(of buffer: AVAudioPCMBuffer) -> Int {
        Int(buffer.frameCapacity) * Int(format.channelCount) * MemoryLayout<Float>.size
    }

    private func convert(_ src: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter = AVAudioConverter(from: src.format, to: format) else { return nil }
        let ratio = Self.sampleRate / src.format.sampleRate
        let capacity = AVAudioFrameCount((Double(src.frameLength) * ratio).rounded(.up)) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            return nil
        }
        out.frameLength = out.frameCapacity   // declares writable space for the converter
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .endOfStream
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return src
        }
        guard error == nil, out.frameLength > 0 else { return nil }
        return out
    }

    /// Linear-interpolation pitch shift. Positive semitones shorten the buffer.
    private func resample(_ src: AVAudioPCMBuffer, semitones: Int) -> AVAudioPCMBuffer {
        let ratio = pow(2.0, Double(semitones) / 12.0)      // inFrames / outFrames
        let inFrames = Int(src.frameLength)
        let outFrames = max(1, Int((Double(inFrames) / ratio).rounded()))
        guard let out = AVAudioPCMBuffer(pcmFormat: format,
                                         frameCapacity: AVAudioFrameCount(outFrames)) else {
            return src
        }
        out.frameLength = AVAudioFrameCount(outFrames)
        for channel in 0..<Int(format.channelCount) {
            let s = src.floatChannelData![channel]
            let d = out.floatChannelData![channel]
            for i in 0..<outFrames {
                let pos = Double(i) * ratio
                let i0 = Int(pos)
                let frac = Float(pos - Double(i0))
                if i0 + 1 < inFrames {
                    d[i] = s[i0] * (1 - frac) + s[i0 + 1] * frac
                } else {
                    d[i] = s[min(i0, inFrames - 1)]
                }
            }
        }
        return out
    }
}
