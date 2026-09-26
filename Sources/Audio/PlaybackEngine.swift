import Foundation
import AVFoundation
import Combine
import Darwin

/// Native playback engine: one AVAudioPlayerNode per track → auxMixer → reverb
/// → mainMixer. Beats are mapped to seconds via the sequence's tempo map, then
/// compressed by the speed factor (100 = nominal). Buffers are scheduled at
/// absolute player-timeline (or host-time) anchors so pause/seek/speed can
/// reschedule, and only a lookahead window is kept scheduled so memory and
/// startup cost stay bounded for long tunes.
public final class PlaybackEngine: ObservableObject {
    @Published public private(set) var isPlaying = false
    @Published public private(set) var progress: Double = 0   // 0...1 of totalBeats
    /// Total duration in seconds at speed=100.
    public private(set) var duration: TimeInterval = 0

    /// (active element ids, anchor element id for cursor) on the main queue.
    public var onCursor: ((Set<Int>, Int?) -> Void)?
    /// On the main queue, when playback reaches the end.
    public var onFinish: (() -> Void)?
    /// On the main queue, when an audio interruption (call, Siri…) or route
    /// loss pauses playback. Lets the UI update its status text.
    public var onAutoPause: (() -> Void)?

    /// 曲の末尾で先頭に戻って繰り返す。
    public var loopEnabled = false

    private let engine = AVAudioEngine()
    private var playerNodes: [AVAudioPlayerNode] = []
    private var sequence: PlaybackSequence?
    private var trackInstruments: [Instrument] = []
    /// voiceID → 0.0...1.0 (ミュート/ソロ反映済み)
    private var trackGains: [String: Float] = [:]
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

    /// 先読みスケジューリングの窓(出力秒)。この先のイベントは随時追加される。
    private let lookaheadSec: TimeInterval = 12
    /// トラックごとの次にスケジュールするイベント index(events は時系列順)。
    private var schedIdx: [Int] = []
    /// すでにスケジュール済みの範囲(sec100 領域の上限)。
    private var schedHorizon: TimeInterval = 0

    /// 直近の再生位置(割り込み時に lastRenderTime が死んだ後でも退避できるよう)。
    private var lastBeat: Double = 0
    /// アイドル時のエンジン停止ディレイ(リバーブの残響を切らないよう猶予を持たせる)。
    private var shutdownWork: DispatchWorkItem?
    /// 割り込み開始時に再生中だった(終了時に自動再開するかの判定用)。
    private var resumeAfterInterrupt = false
    private var observersInstalled = false

    private static let sampleRate = SoundFontPlayer.sampleRate
    private static let hostTicksPerSecond: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return 1e9 * Double(info.denom) / Double(info.numer)
    }()

    public init() {}

    deinit {
        stopTimer()
        shutdownWork?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

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
        applyTrackGains()
        duration = seconds(forBeat: sequence.totalBeats)
        positionBeat = 0
        lastBeat = 0
        progress = 0
        schedIdx = []
    }

    // MARK: - Volume

    /// voiceID → 0...1。ミュート/ソロは呼び出し側で計算して渡す。
    public func setTrackGains(_ gains: [String: Float]) {
        trackGains = gains
        applyTrackGains()
    }

    private func applyTrackGains() {
        guard let seq = sequence else { return }
        for (i, track) in seq.tracks.enumerated() where i < playerNodes.count {
            playerNodes[i].volume = trackGains[track.voiceID] ?? 1
        }
    }

    /// マスター音量 0...1(デフォルト 1)
    public func setMasterVolume(_ volume: Float) {
        engine.mainMixerNode.outputVolume = min(1, max(0, volume))
    }

    // MARK: - Transport

    /// Start or resume from the current position.
    public func play() {
        guard let seq = sequence, seq.totalBeats > 0, !isPlaying else { return }
        shutdownWork?.cancel()
        activateSession()
        startEngineIfNeeded()
        if positionBeat >= seq.totalBeats { positionBeat = 0 }
        for node in playerNodes { node.play() }
        scheduleEvents(fromBeat: positionBeat)
        isPlaying = true
        startTimer()
    }

    public func pause() {
        pauseInternal(at: currentBeat())
    }

    /// 指定拍での一時停止(割り込み時は clock が死んでいることがあるので明示する)
    private func pauseInternal(at beat: Double) {
        guard isPlaying else { return }
        if let seq = sequence {
            positionBeat = min(max(0, beat), seq.totalBeats)
        } else {
            positionBeat = 0
        }
        haltNodes()
        isPlaying = false
        stopTimer()
        emitCursor(at: positionBeat)
        releaseAudio()
    }

    /// Reset to 0.
    public func stop() {
        haltNodes()
        stopTimer()
        isPlaying = false
        positionBeat = 0
        lastBeat = 0
        progress = 0
        anchorPlayerSample = nil
        emitCursor(at: nil)
        releaseAudio()
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

    /// 楽譜上の音符(要素ID)の位置へシークする。再生中・停止中の両方で動作。
    public func seekToElement(_ elementID: Int) {
        guard let seq = sequence, seq.totalBeats > 0 else { return }
        var found: Double?
        for track in seq.tracks {
            for event in track.events where event.elementID == elementID {
                found = min(found ?? .infinity, event.startBeat)
            }
        }
        if let beat = found { seek(toFraction: beat / seq.totalBeats) }
    }

    /// 50...200, preserves position (reschedules while playing).
    public func setSpeed(_ percent: Int) {
        speedPercent = min(200, max(50, percent))
        guard isPlaying else { return }
        let beat = currentBeat()
        positionBeat = beat
        haltNodes()
        for node in playerNodes { node.play() }
        scheduleEvents(fromBeat: beat)
    }

    // MARK: - Tempo map (piecewise-linear beats ↔ seconds at speed 100)

    private func seconds(forBeat beat: Double) -> TimeInterval {
        sequence?.seconds(forBeat: beat) ?? beat * 0.5
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

    // MARK: - Scheduling (lookahead window)

    /// (Re)starts scheduling at `beat`: slices overlapping events, then fills
    /// only the lookahead window; `timerTick` tops the window up as it slides.
    private func scheduleEvents(fromBeat beat: Double) {
        guard let seq = sequence else { return }
        let rate = Double(speedPercent) / 100
        startSec100 = seconds(forBeat: beat)
        schedHorizon = startSec100 + lookaheadSec * rate
        anchorUptime = ProcessInfo.processInfo.systemUptime + leadIn
        anchorPlayerSample = nil
        if let node = playerNodes.first,
           let renderTime = node.lastRenderTime,
           let playerTime = node.playerTime(forNodeTime: renderTime) {
            anchorPlayerSample = playerTime.sampleTime
                + AVAudioFramePosition((leadIn * Self.sampleRate).rounded())
        }
        let hostAnchor = mach_absolute_time() &+ UInt64(leadIn * Self.hostTicksPerSecond)

        schedIdx = []
        for (index, track) in seq.tracks.enumerated() {
            var k = 0
            // events are emitted in start order; skip everything fully past.
            while k < track.events.count
                    && track.events[k].startBeat + track.events[k].durationBeats <= beat {
                k += 1
            }
            // Events overlapping the position: play the remaining subrange.
            while k < track.events.count && track.events[k].startBeat < beat {
                schedule(track.events[k], track: index, hostAnchor: hostAnchor, tailOf: beat)
                k += 1
            }
            // Fill the lookahead window.
            while k < track.events.count
                    && seconds(forBeat: track.events[k].startBeat) < schedHorizon {
                schedule(track.events[k], track: index, hostAnchor: hostAnchor, tailOf: nil)
                k += 1
            }
            schedIdx.append(k)
        }
    }

    /// 再生中にタイマーから呼ばれ、lookahead 窓の先までイベントを追加する。
    private func topUp() {
        guard let seq = sequence else { return }
        let rate = Double(speedPercent) / 100
        let horizon = seconds(forBeat: currentBeat()) + lookaheadSec * rate
        guard horizon > schedHorizon else { return }
        schedHorizon = horizon
        let hostAnchor = mach_absolute_time() &+ UInt64(leadIn * Self.hostTicksPerSecond)
        for (index, track) in seq.tracks.enumerated() where index < schedIdx.count {
            var k = schedIdx[index]
            while k < track.events.count
                    && seconds(forBeat: track.events[k].startBeat) < horizon {
                schedule(track.events[k], track: index, hostAnchor: hostAnchor, tailOf: nil)
                k += 1
            }
            schedIdx[index] = k
        }
    }

    /// Schedules one event on its track's player node. `tailOf` is set when the
    /// event started before the play position — only its remaining part plays.
    private func schedule(_ event: PlaybackEvent, track index: Int,
                          hostAnchor: UInt64, tailOf beat: Double?) {
        guard index < playerNodes.count, index < trackInstruments.count else { return }
        let rate = Double(speedPercent) / 100
        let instrument = trackInstruments[index]
        let endBeat = event.startBeat + event.durationBeats
        let offsetSec = (seconds(forBeat: event.startBeat) - startSec100) / rate
        let eventSec = (seconds(forBeat: endBeat) - seconds(forBeat: event.startBeat)) / rate
        guard let buffer = soundFont.makeBuffer(dir: instrument.soundFontDir,
                                                midi: event.midi,
                                                seconds: eventSec,
                                                velocity: event.velocity) else {
            return    // missing soundfont → skip this event's audio
        }
        let time = scheduledTime(offset: max(0, offsetSec), hostAnchor: hostAnchor)
        if let beat = beat, event.startBeat < beat {
            // Event overlaps the position: play the remaining subrange.
            // (AVAudioPlayerNode has no buffer-based scheduleSegment, so
            // we slice off the elapsed head ourselves.)
            let elapsedSec = (startSec100 - seconds(forBeat: event.startBeat)) / rate
            let startFrame = AVAudioFramePosition((elapsedSec * Self.sampleRate).rounded())
            guard startFrame >= 0, startFrame < AVAudioFramePosition(buffer.frameLength),
                  let tail = subBuffer(buffer, from: startFrame) else {
                return
            }
            playerNodes[index].scheduleBuffer(tail, at: time, options: [],
                                              completionHandler: nil)
        } else {
            playerNodes[index].scheduleBuffer(buffer, at: time, options: [],
                                              completionHandler: nil)
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
        topUp()
        let beat = currentBeat()
        lastBeat = beat
        if beat >= seq.totalBeats {
            if loopEnabled {
                // 末尾で先頭へ: スケジュール状態をリセットして続行
                positionBeat = 0
                lastBeat = 0
                haltNodes()
                for node in playerNodes { node.play() }
                scheduleEvents(fromBeat: 0)
                progress = 0
                emitCursor(at: nil)
                return
            }
            haltNodes()
            isPlaying = false
            stopTimer()
            positionBeat = seq.totalBeats
            progress = 1
            emitCursor(at: seq.totalBeats)
            releaseAudio()
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

    /// Copies frames [start, end) of a buffer into a fresh buffer, applying a
    /// short fade-in so a mid-sample cut doesn't click.
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
        // ~6ms のフェードインを先頭に焼いてクリック音を防ぐ
        let ramp = min(Int(frames), 256)
        for channel in 0..<Int(soundFont.format.channelCount) {
            let data = out.floatChannelData![channel]
            for i in 0..<ramp { data[i] *= Float(i) / Float(ramp) }
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

    /// 再生が止まったらセッションを解放(他アプリの音楽を解放し、
    /// 残響が鳴り終わる頃にエンジンを停止してバッテリーを節約する)。
    private func releaseAudio() {
        #if os(iOS)
        if sessionConfigured {
            try? AVAudioSession.sharedInstance()
                .setActive(false, options: .notifyOthersOnDeactivation)
        }
        #endif
        shutdownWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isPlaying else { return }
            if self.engine.isRunning { self.engine.stop() }
        }
        shutdownWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func configureSession() {
        #if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        } catch {
            print("[PlaybackEngine] audio session configuration failed: \(error)")
        }
        installSessionObservers()
        #endif
    }

    private func activateSession() {
        #if os(iOS)
        configureSession()
        sessionConfigured = true
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("[PlaybackEngine] audio session activation failed: \(error)")
        }
        #endif
    }

    /// 電話・Siri 等の割り込みと、イヤホン抜去等のルート変更で一時停止する。
    /// 割り込み終了時に shouldResume が立っていれば自動再開する。
    private func installSessionObservers() {
        #if os(iOS)
        guard !observersInstalled else { return }
        observersInstalled = true
        let center = NotificationCenter.default
        center.addObserver(forName: AVAudioSession.interruptionNotification,
                           object: nil, queue: .main) { [weak self] note in
            guard let self,
                  let typeValue = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
            switch type {
            case .began:
                // 描画系のクロックは既に止まっているので、直近タイマー値を退避
                self.resumeAfterInterrupt = self.isPlaying
                self.pauseInternal(at: self.lastBeat)
                self.onAutoPause?()
            case .ended:
                let options = AVAudioSession.InterruptionOptions(
                    rawValue: note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
                if self.resumeAfterInterrupt, options.contains(.shouldResume) {
                    self.play()
                }
                self.resumeAfterInterrupt = false
            @unknown default:
                break
            }
        }
        center.addObserver(forName: AVAudioSession.routeChangeNotification,
                           object: nil, queue: .main) { [weak self] note in
            guard let self,
                  let reasonValue = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }
            if reason == .oldDeviceUnavailable {
                self.pauseInternal(at: self.lastBeat)
                self.onAutoPause?()
            }
        }
        #endif
    }
}
