import AVFoundation
import Foundation

/// Renders every note of each bundled instrument from a SoundFont (.sf2) into
/// per-note .m4a files:  SoundFont/<dir>/<NoteName>.m4a  (C4 = MIDI 60).
///
/// Each note is played through AVAudioUnitSampler inside an offline
/// AVAudioEngine, so the rendered audio carries the soundfont's real velocity
/// response, sustain loops and natural release — unlike the old 64 kbps MP3
/// slices. Decaying instruments are recorded until they fade to silence;
/// sustained instruments hold a fixed sustain then release.
///
/// Usage:
///   swift scripts/render_soundfont.swift <path-to-FluidR3_GM.sf2> [SoundFont-dir]
/// Recommended source (MIT license, see SoundFont/SOUNDFONT-ATTRIBUTION.md):
///   https://ftp.debian.org/debian/pool/main/f/fluid-soundfont/fluid-soundfont_3.1.orig.tar.gz

let sampleRate: Double = 44100
let chunk: AVAudioFrameCount = 4096
let velocity: UInt8 = 110
let aacBitrate = 144_000

struct Job {
    let dir: String
    let program: UInt8
    let percussion: Bool
    /// nil = render while the note keeps sounding (decaying instruments);
    /// otherwise the fixed sustain seconds before note-off.
    let sustain: Double?
    let range: ClosedRange<Int>
    /// Max seconds of rendered audio kept per note.
    let cap: Double
}

let jobs: [Job] = [
    Job(dir: "acoustic_grand_piano",  program: 0,  percussion: false, sustain: nil,  range: 21...108, cap: 12),
    Job(dir: "acoustic_guitar_nylon", program: 24, percussion: false, sustain: nil,  range: 21...108, cap: 8),
    Job(dir: "violin",                program: 40, percussion: false, sustain: 5.0,  range: 21...108, cap: 8),
    Job(dir: "flute",                 program: 73, percussion: false, sustain: 5.0,  range: 21...108, cap: 8),
    Job(dir: "trumpet",               program: 56, percussion: false, sustain: 5.0,  range: 21...108, cap: 8),
    Job(dir: "electric_bass_finger",  program: 33, percussion: false, sustain: nil,  range: 21...108, cap: 8),
    Job(dir: "choir_aahs",            program: 52, percussion: false, sustain: 5.0,  range: 21...108, cap: 8),
    Job(dir: "percussion",            program: 0,  percussion: true,  sustain: nil,  range: 27...87,  cap: 6),
]

// Flat-style note names, matching MIDINoteName in Instruments.swift.
func noteName(_ midi: Int) -> String {
    let names = ["C", "Db", "D", "Eb", "E", "F", "Gb", "G", "Ab", "A", "Bb", "B"]
    return names[midi % 12] + String(midi / 12 - 1)
}

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write("usage: render_soundfont.swift <sf2> [outDir]\n".data(using: .utf8)!)
    exit(2)
}
let sf2URL = URL(fileURLWithPath: CommandLine.arguments[1])
let outRoot = CommandLine.arguments.count >= 3
    ? URL(fileURLWithPath: CommandLine.arguments[2])
    : URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
          .appendingPathComponent("SoundFont")

// Optional filters: [dir] [loMidi-hiMidi]
let dirFilter = CommandLine.arguments.count >= 4 ? CommandLine.arguments[3] : nil
var noteFilter: ClosedRange<Int>? = nil
if CommandLine.arguments.count >= 5 {
    let parts = CommandLine.arguments[4].split(separator: "-")
    if parts.count == 2, let lo = Int(parts[0]), let hi = Int(parts[1]) {
        noteFilter = lo...hi
    }
}

guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
    fatalError("cannot create audio format")
}

let engine = AVAudioEngine()
let sampler = AVAudioUnitSampler()
try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: chunk)
engine.attach(sampler)
engine.connect(sampler, to: engine.mainMixerNode, format: format)
try engine.start()

let scratch = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk)!

/// Peak over both channels of a render chunk.
func chunkPeak(_ buf: AVAudioPCMBuffer) -> Float {
    var peak: Float = 0
    for ch in 0..<Int(format.channelCount) {
        let p = buf.floatChannelData![ch]
        for i in 0..<Int(buf.frameLength) { peak = max(peak, abs(p[i])) }
    }
    return peak
}

/// Renders one note and returns interleaved float32 stereo PCM.
/// The note starts at `leadIn` seconds; `sustain` nil = keep sounding until
/// the level drops below -66 dB (decaying sources), then note-off and capture
/// the release tail; everything is silence-trimmed afterwards.
func renderNote(job: Job, midi: Int) throws -> [Float] {
    let leadIn: Double = 0.03
    let releaseCap: Double = 2.5
    let quietFloor = Float(pow(10.0, -66.0 / 20.0))   // -66 dBFS
    var pcm: [Float] = []
    var quietStart: Double? = nil
    var rendered = 0.0

    /// Renders one chunk and appends it interleaved; false when render ends.
    func pull() throws -> Bool {
        try engine.renderOffline(chunk, to: scratch)
        let n = Int(scratch.frameLength)
        guard n > 0 else { return false }
        let l = scratch.floatChannelData![0]
        let r = scratch.floatChannelData![1]
        pcm.reserveCapacity(pcm.count + n * 2)
        for i in 0..<n { pcm.append(l[i]); pcm.append(r[i]) }
        rendered += Double(n) / sampleRate
        return true
    }

    while rendered < leadIn { if try !pull() { break } }

    sampler.sendMIDIEvent(0x90, data1: UInt8(midi), data2: velocity)

    // Sustain phase.
    let sustainSec = job.sustain ?? .infinity
    while rendered < leadIn + min(sustainSec, job.cap) {
        if try !pull() { break }
        if job.sustain == nil {
            let t = rendered - leadIn
            if chunkPeak(scratch) < quietFloor, t > 1.0 {
                if quietStart == nil { quietStart = t }
                if t - quietStart! > 0.4 { break }
            } else { quietStart = nil }
        }
    }

    if !job.percussion {
        sampler.sendMIDIEvent(0x80, data1: UInt8(midi), data2: 0)
    }

    // Release tail: render until quiet or cap.
    let tailEnd = min(rendered + releaseCap, leadIn + job.cap)
    quietStart = nil
    while rendered < tailEnd {
        if try !pull() { break }
        if chunkPeak(scratch) < quietFloor {
            if quietStart == nil { quietStart = rendered }
            if rendered - quietStart! > 0.3 { break }
        } else { quietStart = nil }
    }

    // Trim leading silence: keep ~4 ms before the first audible frame.
    let headPad = Int(0.004 * sampleRate)
    let floorLin = Float(pow(10.0, -60.0 / 20.0))
    var head = 0
    for i in 0..<(pcm.count / 2) {
        if abs(pcm[2 * i]) > floorLin || abs(pcm[2 * i + 1]) > floorLin {
            head = max(0, i - headPad)
            break
        }
    }
    if head > 0 { pcm.removeFirst(head * 2) }

    // Trim trailing silence: keep ~0.15 s after the last audible frame.
    let tailPad = Int(0.15 * sampleRate)
    var end = pcm.count / 2
    for i in stride(from: pcm.count / 2 - 1, through: 0, by: -1) {
        if abs(pcm[2 * i]) > floorLin || abs(pcm[2 * i + 1]) > floorLin {
            end = min(pcm.count / 2, i + tailPad)
            break
        }
    }
    pcm = Array(pcm[0 ..< end * 2])

    // Kill any residual ringing so nothing bleeds into the next note, then
    // render a discarded flush so the hard kill lands outside this file.
    sampler.sendMIDIEvent(0xB0, data1: 120, data2: 0)
    sampler.sendMIDIEvent(0xB0, data1: 123, data2: 0)
    var flushed = 0.0
    while flushed < 0.05 {
        try engine.renderOffline(chunk, to: scratch)
        if scratch.frameLength == 0 { break }
        flushed += Double(scratch.frameLength) / sampleRate
    }
    return pcm
}

/// Writes float32 stereo samples to a 16-bit WAV, scaling by `gain`.
func writeWAV(_ pcm: [Float], gain: Float, to url: URL) throws {
    let frames = pcm.count / 2
    let header = WavHeader(frames: UInt32(frames), sampleRate: UInt32(sampleRate))
    var data = Data()
    data.append(header.bytes)
    pcm.withUnsafeBufferPointer { ptr in
        var out = [Int16](repeating: 0, count: pcm.count)
        for i in 0..<pcm.count {
            let v = max(-1, min(1, ptr[i] * gain))
            out[i] = Int16(v * 32767)
        }
        out.withUnsafeBufferPointer { data.append(contentsOf: UnsafeRawBufferPointer($0)) }
    }
    try data.write(to: url)
}

struct WavHeader {
    let frames: UInt32
    let sampleRate: UInt32
    var bytes: Data {
        var d = Data()
        let dataSize = frames * 4
        func push(_ s: String) { d.append(s.data(using: .ascii)!) }
        func push32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func push16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        push("RIFF"); push32(36 + dataSize); push("WAVE")
        push("fmt "); push32(16); push16(1); push16(2)
        push32(sampleRate); push32(sampleRate * 4); push16(4); push16(16)
        push("data"); push32(dataSize)
        return d
    }
}

let fm = FileManager.default
for job in jobs {
    if let dirFilter, job.dir != dirFilter { continue }
    let dir = outRoot.appendingPathComponent(job.dir, isDirectory: true)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let bankMSB: UInt8 = job.percussion
        ? UInt8(kAUSampler_DefaultPercussionBankMSB)
        : UInt8(kAUSampler_DefaultMelodicBankMSB)
    try sampler.loadSoundBankInstrument(at: sf2URL, program: job.program,
                                        bankMSB: bankMSB, bankLSB: 0)
    sampler.sendProgramChange(job.program, bankMSB: bankMSB, bankLSB: 0, onChannel: 0)

    // Pass 1: render all notes, remember per-instrument peak.
    var rendered: [(midi: Int, pcm: [Float])] = []
    var peak: Float = 0
    let range = noteFilter.map { job.range.clamped(to: $0) } ?? job.range
    for midi in range {
        let pcm = try renderNote(job: job, midi: midi)
        for v in pcm { peak = max(peak, abs(v)) }
        rendered.append((midi, pcm))
    }
    // Per-instrument normalisation to a common ceiling keeps relative
    // dynamics between notes while giving every instrument the same headroom.
    let gain: Float = peak > 0 ? min(4.0, 0.82 / peak) : 1
    print("\(job.dir): peak \(String(format: "%.3f", peak)) -> gain \(String(format: "%.2f", gain))")

    // Pass 2: wav → m4a via afconvert.
    let tmp = fm.temporaryDirectory.appendingPathComponent("sfnote.wav")
    for (midi, pcm) in rendered {
        try writeWAV(pcm, gain: gain, to: tmp)
        let dst = dir.appendingPathComponent(noteName(midi) + ".m4a")
        try? fm.removeItem(at: dst)
        let conv = Process()
        conv.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        conv.arguments = ["-f", "m4af", "-d", "aac", "-b", String(aacBitrate),
                          tmp.path, dst.path]
        try conv.run()
        conv.waitUntilExit()
        guard conv.terminationStatus == 0 else {
            FileHandle.standardError.write("afconvert failed for \(dst.path)\n".data(using: .utf8)!)
            continue
        }
    }
    print("\(job.dir): \(rendered.count) notes -> \(dir.path)")
}
engine.stop()
print("done")
