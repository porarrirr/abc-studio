import Foundation
import AVFoundation
import Combine
import Darwin

/// Native playback engine: one AVAudioPlayerNode per track → mainMixer.
/// Beats are mapped to seconds via the sequence's tempo map, then compressed by
/// the speed factor (100 = nominal). Buffers are scheduled at absolute
/// player-timeline (or host-time) anchors so pause/seek/speed can reschedule.
public final class PlaybackEngine: ObservableObject {
    @Published public private(set) var isPlaying = false
    @Published public private(set) var progress: Double = 0   // 0...1 of totalBeats
    /// Total duration in seconds at speed=100.
    public private(set) var duration: TimeInterval = 0

    /// (active element ids, anchor element id for cursor) on the main queue.
    public var onCursor: ((Set<Int>, Int?) -> Void)?
    /// On the main queue, when playback reaches the end.
    public var onFinish: (() -> Void)?

    private let engine = AVAudioEngine()
    private var playerNodes: [AVAudioPlayerNode] = []
    private var sequence: PlaybackSequence?
    private var trackInstruments: [Instrument] = []
    private let soundFont = SoundFontPlayer()
    /// Shared ambience: playerNodes → auxMixer → reverb → mainMixer.
    /// Effects have a single input bus, so the tracks must be summed by a
    /// mixer node first; a light hall makes the dry samples sit in a room.
    private let auxMixer = AVAudioMixerNode()
    private let reverb = AVAudioUnitReverb()
    private var effectsConnected = false
    private var speedPercent = 100
    private var positionBeat: Double = 0     // committed position (pause/seek/load)

    // Timing state for the current run (since last scheduleEvents).
    private var anchorPlayerSample: AVAudioFramePosition?  // in playerNodes[0]'s timeline
    private var anchorUptime: TimeInterval = 0             // fallback clock basis
    private var startSec100: TimeInterval = 0              // seconds(forBeat: run start)
    private var timer: DispatchSourceTimer?
    private var sessionConfigured = false
    private let leadIn: TimeInterval = 0.08

    private static let sampleRate = SoundFontPlayer.sampleRate
    private static let hostTicksPerSecond: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return 1e9 * Double(info.denom) / Double(info.numer)
    }()

    public init() {}

    // MARK: - Loading

    /// Prepares audio for a sequence. `instruments` maps voiceID → Instrument;
    /// missing voices fall back to piano (drums for percussion tracks).
    public func load(_ sequence: PlaybackSequence, instruments: [String: Instrument]) {
        haltNodes()
        stopTimer()
        isPlaying = false
        self.sequence = sequence
        for node in playerNodes { engine.detach(node) }
        if !effectsConnected {
            reverb.loadFactoryPreset(.mediumHall)
            reverb.wetDryMix = 16
            engine.attach(auxMixer)
            engine.attach(reverb)
            engine.connect(auxMixer, to: reverb, format: soundFont.format)
            engine.connect(reverb, to: engine.mainMixerNode, format: soundFont.format)
            effectsConnected = true
        }
        playerNodes = sequence.tracks.map { _ in AVAudioPlayerNode() }
        for node in playerNodes {
            engine.attach(node)
            engine.connect(node, to: auxMixer, format: soundFont.format)
        }
        trackInstruments = sequence.tracks.map { track in
            instruments[track.voiceID]
                ?? (track.isPercussion
                    ? (Instruments.byID("drums") ?? Instruments.all[0])
                    : Instruments.all[0])
        }
        duration = seconds(forBeat: sequence.totalBeats)
        positionBeat = 0
        progress = 0
    }

    // MARK: - Transport

    /// Start or resume from the current position.
    public func play() {
        guard let seq = sequence, seq.totalBeats > 0, !isPlaying else { return }
        configureSession()
        startEngineIfNeeded()
        if positionBeat >= seq.totalBeats { positionBeat = 0 }
        for node in playerNodes { node.play() }
        scheduleEvents(fromBeat: positionBeat)
        isPlaying = true
        startTimer()
    }

    public func pause() {
        guard isPlaying else { return }
        positionBeat = currentBeat()
        haltNodes()
        isPlaying = false
        stopTimer()
        emitCursor(at: positionBeat)
    }

    /// Reset to 0.
    public func stop() {
        haltNodes()
        stopTimer()
        isPlaying = false
        positionBeat = 0
        progress = 0
        emitCursor(at: nil)
    }

    /// Works while playing or paused.
    public func seek(toFraction fraction: Double) {
        guard let seq = sequence, seq.totalBeats > 0 else { return }
        let beat = min(1, max(0, fraction)) * seq.totalBeats
        positionBeat = beat
        progress = beat / seq.totalBeats
        if isPlaying {
            haltNodes()
            for node in playerNodes { node.play() }
            scheduleEvents(fromBeat: beat)
        }
        emitCursor(at: beat)
    }

    /// 75...150, preserves position (reschedules while playing).
    public func setSpeed(_ percent: Int) {
        speedPercent = min(150, max(75, percent))
        guard isPlaying else { return }
        let beat = currentBeat()
        positionBeat = beat
        haltNodes()
        for node in playerNodes { node.play() }
        scheduleEvents(fromBeat: beat)
    }

    // MARK: - Tempo map (piecewise-linear beats ↔ seconds at speed 100)

    private func seconds(forBeat beat: Double) -> TimeInterval {
        guard let seq = sequence, let first = seq.tempoMap.first else {
            return beat * 0.5   // 120 qnBPM default
        }
        var seconds = 0.0
        var prev = first
        if beat <= prev.beat {
            return (beat - prev.beat) * 60.0 / prev.quarterNoteBPM
        }
        for point in seq.tempoMap.dropFirst() {
            if beat <= point.beat {
                return seconds + (beat - prev.beat) * 60.0 / prev.quarterNoteBPM
            }
            seconds += (point.beat - prev.beat) * 60.0 / prev.quarterNoteBPM
            prev = point
        }
        return seconds + (beat - prev.beat) * 60.0 / prev.quarterNoteBPM
    }

    private func beat(forSeconds sec100: TimeInterval) -> Double {
        guard let seq = sequence, let first = seq.tempoMap.first else {
            return sec100 * 2
        }
        var seconds = 0.0
        var prev = first
        for point in seq.tempoMap.dropFirst() {
            let segment = (point.beat - prev.beat) * 60.0 / prev.quarterNoteBPM
            if sec100 <= seconds + segment {
                return prev.beat + (sec100 - seconds) * prev.quarterNoteBPM / 60.0
            }
            seconds += segment
            prev = point
        }
        return prev.beat + (sec100 - seconds) * prev.quarterNoteBPM / 60.0
    }

    // MARK: - Scheduling

    private func scheduleEvents(fromBeat beat: Double) {
        guard let seq = sequence else { return }
        let rate = Double(speedPercent) / 100
        startSec100 = seconds(forBeat: beat)
        anchorUptime = ProcessInfo.processInfo.systemUptime + leadIn
        anchorPlayerSample = nil
        if let node = playerNodes.first,
           let renderTime = node.lastRenderTime,
           let playerTime = node.playerTime(forNodeTime: renderTime) {
            anchorPlayerSample = playerTime.sampleTime
                + AVAudioFramePosition((leadIn * Self.sampleRate).rounded())
        }
        let hostAnchor = mach_absolute_time() &+ UInt64(leadIn * Self.hostTicksPerSecond)

        for (index, track) in seq.tracks.enumerated() {
            let node = playerNodes[index]
            let instrument = trackInstruments[index]
            for event in track.events {
                let endBeat = event.startBeat + event.durationBeats
                guard endBeat > beat else { continue }
                let offsetSec = (seconds(forBeat: event.startBeat) - startSec100) / rate
                let eventSec = (seconds(forBeat: endBeat) - seconds(forBeat: event.startBeat)) / rate
                guard let buffer = soundFont.makeBuffer(dir: instrument.soundFontDir,
                                                        midi: event.midi,
                                                        seconds: eventSec,
                                                        velocity: event.velocity) else {
                    continue    // missing soundfont → skip this event's audio
                }
                let time = scheduledTime(offset: max(0, offsetSec), hostAnchor: hostAnchor)
                if event.startBeat < beat {
                    // Event overlaps the position: play the remaining subrange.
                    // (AVAudioPlayerNode has no buffer-based scheduleSegment, so
                    // we slice off the elapsed head ourselves.)
                    let elapsedSec = (startSec100 - seconds(forBeat: event.startBeat)) / rate
                    let startFrame = AVAudioFramePosition((elapsedSec * Self.sampleRate).rounded())
                    guard startFrame >= 0, startFrame < AVAudioFramePosition(buffer.frameLength),
                          let tail = subBuffer(buffer, from: startFrame) else {
                        continue
                    }
                    node.scheduleBuffer(tail, at: time, options: [], completionHandler: nil)
                } else {
                    node.scheduleBuffer(buffer, at: time, options: [], completionHandler: nil)
                }
            }
        }
    }

    private func scheduledTime(offset: TimeInterval, hostAnchor: UInt64) -> AVAudioTime {
        if let anchor = anchorPlayerSample {
            return AVAudioTime(sampleTime: anchor + AVAudioFramePosition((offset * Self.sampleRate).rounded()),
                               atRate: Self.sampleRate)
        }
        return AVAudioTime(hostTime: hostAnchor &+ UInt64(offset * Self.hostTicksPerSecond))
    }

    /// Current playhead position in beats, from the player node's audio timeline
    /// (falling back to the wall clock if the render timeline isn't up yet).
    private func currentBeat() -> Double {
        var elapsed = ProcessInfo.processInfo.systemUptime - anchorUptime
        if let anchor = anchorPlayerSample,
           let node = playerNodes.first,
           let renderTime = node.lastRenderTime,
           let playerTime = node.playerTime(forNodeTime: renderTime) {
            elapsed = TimeInterval(playerTime.sampleTime - anchor) / Self.sampleRate
        }
        if elapsed < 0 { elapsed = 0 }
        let rate = Double(speedPercent) / 100
        return beat(forSeconds: startSec100 + elapsed * rate)
    }

    // MARK: - Cursor timer (~30Hz on main)

    private func startTimer() {
        stopTimer()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1.0 / 30.0,
                       repeating: 1.0 / 30.0, leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in self?.timerTick() }
        self.timer = timer
        timer.resume()
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    private func timerTick() {
        guard isPlaying, let seq = sequence else { return }
        let beat = currentBeat()
        if beat >= seq.totalBeats {
            haltNodes()
            isPlaying = false
            stopTimer()
            positionBeat = seq.totalBeats
            progress = 1
            emitCursor(at: seq.totalBeats)
            let finish = onFinish
            DispatchQueue.main.async { finish?() }
            return
        }
        progress = beat / seq.totalBeats
        emitCursor(at: beat)
    }

    /// Emits (active ids, anchor). Pass nil beat for an empty cursor.
    private func emitCursor(at beat: Double?) {
        var ids = Set<Int>()
        var anchor: Int?
        if let seq = sequence, let beat = beat {
            var latestStart = -Double.infinity
            var recent: Int?
            for track in seq.tracks {
                for event in track.events {
                    if event.startBeat <= beat && beat < event.startBeat + event.durationBeats {
                        ids.insert(event.elementID)
                        if anchor == nil { anchor = event.elementID }
                    }
                    if event.startBeat <= beat && event.startBeat >= latestStart {
                        latestStart = event.startBeat
                        recent = event.elementID
                    }
                }
            }
            if anchor == nil { anchor = recent }
        }
        let callback = onCursor
        let deliver: () -> Void = { callback?(ids, anchor) }
        if Thread.isMainThread { deliver() }
        else { DispatchQueue.main.async(execute: deliver) }
    }

    /// Copies frames [start, end) of a buffer into a fresh buffer.
    private func subBuffer(_ buffer: AVAudioPCMBuffer, from start: AVAudioFramePosition)
        -> AVAudioPCMBuffer? {
        let frames = AVAudioFramePosition(buffer.frameLength) - start
        guard frames > 0,
              let out = AVAudioPCMBuffer(pcmFormat: soundFont.format,
                                         frameCapacity: AVAudioFrameCount(frames)) else {
            return nil
        }
        out.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<Int(soundFont.format.channelCount) {
            memcpy(out.floatChannelData![channel],
                   buffer.floatChannelData![channel] + Int(start),
                   Int(frames) * MemoryLayout<Float>.size)
        }
        return out
    }

    // MARK: - Engine plumbing

    private func haltNodes() {
        for node in playerNodes { node.stop() }   // clears pending buffers
    }

    private func startEngineIfNeeded() {
        guard !engine.isRunning else { return }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            print("[PlaybackEngine] engine failed to start: \(error)")
        }
    }

    private func configureSession() {
        #if os(iOS)
        guard !sessionConfigured else { return }
        sessionConfigured = true
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("[PlaybackEngine] audio session configuration failed: \(error)")
        }
        #endif
    }
}
