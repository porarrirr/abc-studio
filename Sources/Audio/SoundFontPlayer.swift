import Foundation
import AVFoundation

/// Turns bundled MP3 soundfont directories (`<dir>/<NoteName>.mp3`, C4=60) into
/// ready-to-schedule AVAudioPCMBuffers: the nearest available sample is decoded,
/// pitch-shifted by linear resampling, truncated to the note length with a
/// baked release fade, and scaled by velocity.
public final class SoundFontPlayer {
    public static let sampleRate: Double = 44100
    public let format = AVAudioFormat(standardFormatWithSampleRate: SoundFontPlayer.sampleRate,
                                      channels: 2)!

    /// Overall gain (abcjs used soundFontVolumeMultiplier = 2.4; piano samples are quiet).
    public var volumeMultiplier: Float = 2.4
    /// Fade baked into the tail of every generated buffer (abcjs fadeLength = 120ms).
    public var releaseFade: TimeInterval = 0.12
    /// Very short notes (grace notes, 32nds) still need enough sample to speak.
    public var minimumDuration: TimeInterval = 0.30
    /// Caps per-event buffer memory (8s stereo ≈ 2.8MB per event).
    public var maximumDuration: TimeInterval = 8.0
    /// Hard clamp to avoid clipping after the gain stage.
    public var clipLevel: Float = 0.95

    private struct DirIndex {
        var midis: [Int]                 // sorted
        var fileNames: [Int: String]     // midi → file name on disk
    }
    private var dirIndex: [String: DirIndex] = [:]
    private var dirURLs: [String: URL?] = [:]
    private var missingDirs = Set<String>()
    /// Decoded (format-converted) source samples, keyed "dir|fileMidi".
    private let decodedCache = NSCache<NSString, AVAudioPCMBuffer>()
    /// Pitch-shifted samples, keyed "dir|targetMidi".
    private let pitchedCache = NSCache<NSString, AVAudioPCMBuffer>()
    private let lock = NSLock()

    public init() {
        decodedCache.countLimit = 320
        pitchedCache.countLimit = 320
    }

    // MARK: - Public API

    /// Builds a buffer for one event: `seconds` long (in output time), velocity gain.
    /// Returns nil when the soundfont dir is missing or undecodable.
    public func makeBuffer(dir: String, midi: Int, seconds: TimeInterval, velocity: Double)
        -> AVAudioPCMBuffer? {
        guard let source = pitchedBuffer(dir: dir, midi: midi) else { return nil }
        let clamped = min(max(seconds, minimumDuration), maximumDuration)
        let wanted = max(1, AVAudioFrameCount((clamped * Self.sampleRate).rounded(.up)))
        let frames = min(wanted, source.frameLength)
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            return nil
        }
        out.frameLength = frames
        let gain = Float(velocity / 127.0) * volumeMultiplier
        let fadeFrames = AVAudioFrameCount((releaseFade * Self.sampleRate).rounded(.down))
        let fadeStart = frames > fadeFrames ? Int(frames - fadeFrames) : 0
        let fadeLen = max(1, Int(frames) - fadeStart)
        for channel in 0..<Int(format.channelCount) {
            let src = source.floatChannelData![channel]
            let dst = out.floatChannelData![channel]
            for i in 0..<Int(frames) {
                var sample = src[i] * gain
                if sample > clipLevel { sample = clipLevel }
                else if sample < -clipLevel { sample = -clipLevel }
                if i >= fadeStart {
                    let t = Double(i - fadeStart) / Double(fadeLen)
                    sample *= Float(0.5 * (1 + cos(Double.pi * min(1, t))))
                }
                dst[i] = sample
            }
        }
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
    private func directoryURL(_ dir: String) -> URL? {
        if let cached = dirURLs[dir] { return cached }
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
        dirURLs[dir] = found
        if found == nil && !missingDirs.contains(dir) {
            missingDirs.insert(dir)
            print("[SoundFontPlayer] soundfont directory not found in bundle: \(dir)")
        }
        return found
    }

    private func index(for dir: String) -> DirIndex {
        if let cached = dirIndex[dir] { return cached }
        var result = DirIndex(midis: [], fileNames: [:])
        if let url = directoryURL(dir),
           let files = try? FileManager.default.contentsOfDirectory(atPath: url.path) {
            for file in files where file.lowercased().hasSuffix(".mp3") {
                let stem = String(file.dropLast(4))
                if let midi = Self.midi(forNoteName: stem) {
                    result.fileNames[midi] = file
                }
            }
            result.midis = result.fileNames.keys.sorted()
        }
        if result.midis.isEmpty && !missingDirs.contains(dir) {
            missingDirs.insert(dir)
            print("[SoundFontPlayer] no usable .mp3 files in \(dir)")
        }
        dirIndex[dir] = result
        return result
    }

    // MARK: - Buffer pipeline

    /// Resampled (pitch-shifted) buffer for a target midi, cached per (dir, midi).
    private func pitchedBuffer(dir: String, midi: Int) -> AVAudioPCMBuffer? {
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
        lock.lock()
        pitchedCache.setObject(result, forKey: key)
        lock.unlock()
        return result
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
        decodedCache.setObject(result, forKey: key)
        lock.unlock()
        return result
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
