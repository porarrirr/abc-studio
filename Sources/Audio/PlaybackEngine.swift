import Foundation
import AVFoundation
import Combine
import Darwin

/// Native playback engine: one AVAudioPlayerNode per track → auxMixer → reverb
/// → mainMixer. Beats are mapped to seconds via the sequence's tempo map, then
/// compressed by the speed factor (100 = nominal). Buffers are scheduled at
/// a shared player timeline so pause/seek/speed can
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
    private var makePlayerNode: () -> AVAudioPlayerNode = { AVAudioPlayerNode() }
    private var makeBufferOverride: ((String, Int, TimeInterval, Double) -> AVAudioPCMBuffer?)?
    private var playerNodes: [AVAudioPlayerNode] = []
    private var sequence: PlaybackSequence?
    private var trackInstruments: [Instrument] = []
    /// voiceID → 0.0...1.0 (パート音量とミュート/ソロ反映済み)
    private var trackGains: [String: Float] = [:]
    private let soundFont = SoundFontPlayer()
    private let spatializer = OrchestraSpatializer()
    private var headphoneSettings = HeadphoneSettings()
    private var trackPositions: [StagePosition] = []
    /// Shared ambience: playerNodes → auxMixer → reverb → limiter → mainMixer.
    /// Effects have a single input bus, so the tracks must be summed by a
    /// mixer node first; a light hall makes the dry samples sit in a room,
    /// and the dynamics processor keeps dense passages from clipping.
    private let auxMixer = AVAudioMixerNode()
    private let reverb = AVAudioUnitReverb()
    private let limiter = AVAudioUnitEffect(audioComponentDescription:
        AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_DynamicsProcessor,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0))
    private var effectsConnected = false
    private var speedPercent = 100
    private var positionBeat: Double = 0     // committed position (pause/seek/load)

    // Timing state for the current run (since last scheduleEvents).
    private var anchorUptime: TimeInterval = 0             // fallback clock basis
    private var startSec100: TimeInterval = 0              // seconds(forBeat: run start)
    private var timer: DispatchSourceTimer?
    private var sessionConfigured = false
    // All buffers are queued before this common host-clock start is chosen.
    private let leadIn: TimeInterval = 0.01

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
    /// ブロックベースのセッション監視トークン(deinit で正しく解除するため保持)。
    private var sessionObservers: [NSObjectProtocol] = []
    /// トラックごとの最長イベント拍数(emitCursor の走査窓の下限計算用)。
    private var maxDurBeats: [Double] = []

    // Decode and shape audio away from UI work. Each transport change cancels
    // pending work before it can enqueue buffers on a new player timeline.
    private let prepQueue = DispatchQueue(label: "jp.porari.abcstudio.bufferprep",
                                          qos: .userInitiated)
    private let prepLock = NSLock()
    private var prepGeneration = 0
    private var prepInFlight = false
    private var starting = false
    private let startupSec: TimeInterval = 0.5
    private let preparationBatchSec: TimeInterval = 1

    private struct BufferRequest {
        let track: Int
        let event: PlaybackEvent
        let instrument: Instrument
        let position: StagePosition
        let seconds: Double
        let offset: Double
        let elapsed: Double
    }

    private static let sampleRate = SoundFontPlayer.sampleRate
    private static let hostTicksPerSecond: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return 1e9 * Double(info.denom) / Double(info.numer)
    }()

    public init() {}

    /// Allows scheduling to be observed without depending on audio output latency.
    init(makePlayerNode: @escaping () -> AVAudioPlayerNode,
         makeBuffer: ((String, Int, TimeInterval, Double) -> AVAudioPCMBuffer?)? = nil) {
        self.makePlayerNode = makePlayerNode
        self.makeBufferOverride = makeBuffer
    }

    deinit {
        stopTimer()
        shutdownWork?.cancel()
        // addObserver(forName:...using:) は返り値のトークンで解除する
        for o in sessionObservers { NotificationCenter.default.removeObserver(o) }
    }

    // MARK: - Loading

    /// Prepares audio for a sequence. `instruments` maps voiceID → Instrument;
    /// missing voices fall back to piano (drums for percussion tracks).
    public func load(_ sequence: PlaybackSequence, instruments: [String: Instrument],
                     positions: [String: StagePosition] = [:]) {
        haltNodes()
        stopTimer()
        isPlaying = false
        self.sequence = sequence
        for node in playerNodes { engine.detach(node) }
        if !effectsConnected {
            reverb.loadFactoryPreset(.mediumHall)
            reverb.wetDryMix = headphoneSettings.reverbMix
            engine.attach(auxMixer)
            engine.attach(reverb)
            engine.attach(limiter)
            engine.connect(auxMixer, to: reverb, format: soundFont.format)
            engine.connect(reverb, to: limiter, format: soundFont.format)
            engine.connect(limiter, to: engine.mainMixerNode, format: soundFont.format)
            configureLimiter()
            effectsConnected = true
        }
        playerNodes = sequence.tracks.map { _ in makePlayerNode() }
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
        trackPositions = sequence.tracks.enumerated().map { index, track in
            positions[track.voiceID] ?? .orchestral(instrument: trackInstruments[index], partName: track.name)
        }
        applyTrackGains()
        duration = seconds(forBeat: sequence.totalBeats)
        positionBeat = 0
        lastBeat = 0
        progress = 0
        schedIdx = []
        schedHorizon = 0
        maxDurBeats = sequence.tracks.map { $0.events.map(\.durationBeats).max() ?? 0 }
        invalidatePrepared()
    }

    /// 読み込み失敗時に旧曲の再生状態を完全に破棄する。
    public func unload() {
        stop()
        sequence = nil
        for node in playerNodes { engine.detach(node) }
        playerNodes = []
        trackInstruments = []
        trackPositions = []
        trackGains = [:]
        schedIdx = []
        schedHorizon = 0
        maxDurBeats = []
        invalidatePrepared()
        duration = 0
    }

    /// Gentle master-bus limiting: only catches peaks that would clip,
    /// leaving normal passages untouched (compression threshold ≈ -6 dBFS,
    /// ceiling ≈ -1 dBFS, fast attack / moderate release).
    private func configureLimiter() {
        func set(_ address: AUParameterAddress, _ value: Float) {
            limiter.auAudioUnit.parameterTree?
                .parameter(withAddress: address)?.value = value
        }
        set(0, -6)      // Compression Threshold (dB)
        set(1, 5)       // Headroom (dB): output ceiling = threshold + headroom
        set(4, 0.004)   // Attack Time (s)
        set(5, 0.12)    // Release Time (s)
        set(6, 0)       // Master Gain (dB)
    }

    /// Rebuild the lookahead at the current beat after a stage edit. Slider
    /// edits commit on release, avoiding repeated restarts during a drag.
    public func setTrackPositions(_ positions: [String: StagePosition]) {
        guard let sequence else { return }
        let next = sequence.tracks.enumerated().map { index, track in
            positions[track.voiceID] ?? .orchestral(instrument: trackInstruments[index], partName: track.name)
        }
        guard next != trackPositions else { return }
        let beat = isPlaying ? currentBeat() : positionBeat
        trackPositions = next
        if isPlaying {
            haltNodes()
            scheduleEvents(fromBeat: beat)
        }
    }

    public func setHeadphoneSettings(_ settings: HeadphoneSettings) {
        guard settings != headphoneSettings else { return }
        let beat = isPlaying ? currentBeat() : positionBeat
        headphoneSettings = settings
        reverb.wetDryMix = settings.reverbMix
        if isPlaying {
            haltNodes()
            scheduleEvents(fromBeat: beat)
        }
    }

    /// Pause the main graph before a separate audition uses the audio session.
    /// Its delayed session release must not interrupt the audition midway.
    func suspendForAudition() {
        if isPlaying { pause() }
        shutdownWork?.cancel()
        haltNodes()
        engine.stop()
    }

    /// End an audition before returning control to the main player. Release
    /// now, not on a delayed timer that could deactivate the next playback.
    func finishAudition() {
        stop()
        shutdownWork?.cancel()
        engine.stop()
        onCursor = nil
        onFinish = nil
        #if os(iOS)
        if sessionConfigured {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        #endif
    }

    // MARK: - Volume

    /// voiceID → 0...1。パート音量とミュート/ソロを反映した値を受け取る。
    public func setTrackGains(_ gains: [String: Float]) {
        trackGains = gains
        applyTrackGains()
    }

    private func applyTrackGains() {
        guard let seq = sequence else { return }
        for (i, track) in seq.tracks.enumerated() where i < playerNodes.count {
            let gain = trackGains[track.voiceID] ?? 1
            playerNodes[i].volume = gain.isFinite ? min(1, max(0, gain)) : 1
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
        if positionBeat >= seq.totalBeats { positionBeat = 0 }
        haltNodes()   // 自然終了直後の余韻バッファなど、残っている queue を掃除
        // Decode while the main thread activates the audio session and engine.
        // Scheduling completion returns to main, after the engine has started.
        scheduleEvents(fromBeat: positionBeat)
        isPlaying = true
        activateSession()
        startEngineIfNeeded()
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
        let nextSpeed = min(200, max(50, percent))
        guard nextSpeed != speedPercent else { return }
        guard isPlaying else {
            speedPercent = nextSpeed
            return
        }
        let beat = currentBeat() // 変更前の速度で再生位置を確定する
        speedPercent = nextSpeed
        positionBeat = beat
        haltNodes()
        scheduleEvents(fromBeat: beat)
    }

    // MARK: - Tempo map (piecewise-linear beats ↔ seconds at speed 100)

    private func seconds(forBeat beat: Double) -> TimeInterval {
        sequence?.seconds(forBeat: beat) ?? beat * 0.5
    }

    private func beat(forSeconds sec100: TimeInterval) -> Double {
        sequence?.beat(forSeconds: sec100) ?? sec100 * 2
    }

    // MARK: - Scheduling (lookahead window)

    /// Only prepare the first half-second before starting. Later windows are built
    /// asynchronously, keeping play, seek and speed changes responsive.
    private func scheduleEvents(fromBeat beat: Double) {
        guard let seq = sequence else { return }
        stopTimer()
        starting = true
        positionBeat = beat
        startSec100 = seconds(forBeat: beat)
        schedHorizon = startSec100
        schedIdx = seq.tracks.map { track in
            track.events.firstIndex {
                $0.startBeat + $0.durationBeats > beat
            } ?? track.events.count
        }
        prepareWindow(until: startSec100 + startupSec * Double(speedPercent) / 100,
                      startPlayback: true)
    }

    private func topUp() {
        guard !starting, !prepInFlight else { return }
        let rate = Double(speedPercent) / 100
        let horizon = seconds(forBeat: currentBeat()) + lookaheadSec * rate
        guard horizon > schedHorizon else { return }
        // Grow the lookahead in small batches so seeks can cancel promptly and
        // the next imminent notes are ready before distant notes are decoded.
        prepareWindow(until: min(horizon, schedHorizon + preparationBatchSec * rate),
                      startPlayback: false)
    }

    private func prepareWindow(until horizon: Double, startPlayback: Bool) {
        guard let seq = sequence, !prepInFlight else { return }
        let rate = Double(speedPercent) / 100
        var requests: [BufferRequest] = []
        for (index, track) in seq.tracks.enumerated() {
            var k = schedIdx[index]
            while k < track.events.count,
                  seconds(forBeat: track.events[k].startBeat) < horizon {
                let event = track.events[k]
                let start = seconds(forBeat: event.startBeat)
                requests.append(BufferRequest(
                    track: index, event: event, instrument: trackInstruments[index],
                    position: trackPositions[index],
                    seconds: (seconds(forBeat: event.startBeat + event.durationBeats) - start) / rate,
                    offset: max(0, (start - startSec100) / rate),
                    elapsed: max(0, (startSec100 - start) / rate)))
                k += 1
            }
            schedIdx[index] = k
        }
        requests.sort { $0.offset < $1.offset }
        schedHorizon = horizon
        prepInFlight = true
        let generation = prepGeneration
        let trackCount = playerNodes.count
        let settings = headphoneSettings
        prepQueue.async { [weak self] in
            guard let self else { return }
            var buffers: [(Int, AVAudioPCMBuffer, AVAudioTime)] = []
            if startPlayback {
                let audibleTracks = Set(requests.map(\.track))
                // Give resting tracks a timeline before play(at:), even when
                // their first real note lies beyond the startup window.
                for track in 0..<trackCount where !audibleTracks.contains(track) {
                    if let silence = AVAudioPCMBuffer(pcmFormat: self.soundFont.format,
                                                       frameCapacity: 1) {
                        silence.frameLength = 1
                        for channel in 0..<Int(silence.format.channelCount) {
                            silence.floatChannelData![channel][0] = 0
                        }
                        buffers.append((track, silence,
                                        AVAudioTime(sampleTime: 0, atRate: Self.sampleRate)))
                    }
                }
            }
            // Four independent decoders bound both peak memory and thread use.
            // Keep injected generators serial so transport tests can gate a run.
            let workers = self.makeBufferOverride == nil ? min(4, requests.count) : min(1, requests.count)
            let resultLock = NSLock()
            var prepared = Array<(Int, AVAudioPCMBuffer, AVAudioTime)?>(repeating: nil,
                                                                      count: requests.count)
            if workers > 0 {
                DispatchQueue.concurrentPerform(iterations: workers) { worker in
                    for index in stride(from: worker, to: requests.count, by: workers) {
                        self.prepLock.lock()
                        let stale = self.prepGeneration != generation
                        self.prepLock.unlock()
                        if stale { return }
                        let request = requests[index]
                        let inst = request.instrument
                        let generated: AVAudioPCMBuffer?
                        if let makeBuffer = self.makeBufferOverride {
                            generated = makeBuffer(inst.soundFontDir, inst.soundingNote(request.event.midi),
                                                   request.seconds, request.event.velocity)
                        } else {
                            generated = self.soundFont.makeBuffer(
                                dir: inst.soundFontDir, midi: inst.soundingNote(request.event.midi),
                                seconds: request.seconds, velocity: request.event.velocity)
                        }
                        guard let generated else { continue }
                        var buffer = self.spatializer.render(generated, at: request.position, settings: settings)
                        if request.elapsed > 0 {
                            let frame = AVAudioFramePosition((request.elapsed * Self.sampleRate).rounded())
                            guard let tail = self.subBuffer(buffer, from: frame) else { continue }
                            buffer = tail
                        }
                        let time = AVAudioTime(
                            sampleTime: AVAudioFramePosition((request.offset * Self.sampleRate).rounded()),
                            atRate: Self.sampleRate)
                        resultLock.lock()
                        prepared[index] = (request.track, buffer, time)
                        resultLock.unlock()
                    }
                }
            }
            // Preserve event order regardless of which decoder finished first.
            buffers.append(contentsOf: prepared.compactMap { $0 })
            DispatchQueue.main.async { [weak self] in
                guard let self, self.prepGeneration == generation, self.isPlaying else { return }
                self.prepInFlight = false
                for (track, buffer, time) in buffers {
                    self.playerNodes[track].scheduleBuffer(buffer, at: time, options: [],
                                                           completionHandler: nil)
                }
                if startPlayback {
                    self.anchorUptime = ProcessInfo.processInfo.systemUptime + self.leadIn
                    let start = AVAudioTime(hostTime: mach_absolute_time()
                        &+ UInt64(self.leadIn * Self.hostTicksPerSecond))
                    for node in self.playerNodes { node.play(at: start) }
                    self.starting = false
                    self.startTimer()
                }
                // Continue filling without waiting for a UI timer tick.
                // A small tolerance prevents chasing a moving horizon forever.
                let target = self.seconds(forBeat: self.currentBeat()) + self.lookaheadSec * rate
                if self.schedHorizon + 0.25 * rate < target { self.topUp() }
            }
        }
    }

    /// Current playhead position in beats, from the player node's audio timeline
    /// (falling back to the wall clock if the render timeline isn't up yet).
    private func currentBeat() -> Double {
        if starting { return positionBeat }
        var elapsed = ProcessInfo.processInfo.systemUptime - anchorUptime
        if let node = playerNodes.first,
           let renderTime = node.lastRenderTime,
           let playerTime = node.playerTime(forNodeTime: renderTime) {
            elapsed = TimeInterval(playerTime.sampleTime) / playerTime.sampleRate
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
                scheduleEvents(fromBeat: 0)
                progress = 0
                emitCursor(at: nil)
                return
            }
            // 自然終了: 最終音のバッファ末尾(サステイン+フェード+リバーブ)を
            // 鳴らし切るため、ノード停止・エンジン停止・セッション解放を遅らせる。
            // 残りはスケジュール済みバッファが自然に鳴り終わるのに任せる。
            isPlaying = false
            stopTimer()
            positionBeat = seq.totalBeats
            progress = 1
            emitCursor(at: seq.totalBeats)
            releaseAudio(after: soundFont.sustainTail + soundFont.releaseFade + 0.3)
            let finish = onFinish
            DispatchQueue.main.async { finish?() }
            return
        }
        progress = beat / seq.totalBeats
        emitCursor(at: beat)
    }

    /// Emits (active ids, anchor). Pass nil beat for an empty cursor.
    /// イベントは startBeat 昇順。最長音価を下限として二分探索で走査範囲を絞り、
    /// 長い曲でも 30Hz のタイマーが全イベントを舐めないようにする。
    private func emitCursor(at beat: Double?) {
        var ids = Set<Int>()
        var anchor: Int?
        if let seq = sequence, let beat = beat {
            var latestStart = -Double.infinity
            var recent: Int?
            for (ti, track) in seq.tracks.enumerated() {
                let events = track.events
                let maxDur = ti < maxDurBeats.count ? maxDurBeats[ti] : 0
                // startBeat <= beat - maxDur のイベントは既に終了している
                let lo = events.lowerBound { $0.startBeat >= beat - maxDur }
                // startBeat <= beat の末尾(最後に開始したイベント)
                let hi = events.lowerBound { $0.startBeat > beat }
                var k = lo
                while k < hi {
                    let e = events[k]
                    if beat < e.startBeat + e.durationBeats {
                        ids.insert(e.elementID)
                        if anchor == nil { anchor = e.elementID }
                    }
                    k += 1
                }
                if hi > 0 {
                    let e = events[hi - 1]
                    if e.startBeat >= latestStart {
                        latestStart = e.startBeat
                        recent = e.elementID
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

    private func invalidatePrepared() {
        prepLock.lock()
        prepGeneration += 1
        prepLock.unlock()
        prepInFlight = false
        starting = false
    }

    // MARK: - Engine plumbing

    private func haltNodes() {
        invalidatePrepared()
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

    /// 再生が止まったらセッションを解放し、エンジンを停止する。
    /// `delay` は残響・バッファ末尾を鳴らし切るための追加猶予(曲の自然終了用)。
    private func releaseAudio(after delay: TimeInterval = 0) {
        shutdownWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isPlaying else { return }
            #if os(iOS)
            if self.sessionConfigured {
                try? AVAudioSession.sharedInstance()
                    .setActive(false, options: .notifyOthersOnDeactivation)
            }
            #endif
            if self.engine.isRunning { self.engine.stop() }
        }
        shutdownWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 + delay, execute: work)
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
        sessionObservers.append(
            center.addObserver(forName: AVAudioSession.interruptionNotification,
                               object: nil, queue: .main) { [weak self] note in
                guard let self,
                      let typeValue = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
                switch type {
                case .began:
                    // 描画系のクロックは既に止まっているので、直近タイマー値を退避
                    let wasPlaying = self.isPlaying
                    self.resumeAfterInterrupt = wasPlaying
                    self.pauseInternal(at: self.lastBeat)
                    if wasPlaying { self.onAutoPause?() }
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
            })
        sessionObservers.append(
            center.addObserver(forName: AVAudioSession.routeChangeNotification,
                               object: nil, queue: .main) { [weak self] note in
                guard let self,
                      let reasonValue = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                      let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }
                // 停止中のルート変更で「一時停止」表示にならないよう再生中のみ報告
                if reason == .oldDeviceUnavailable, self.isPlaying {
                    self.pauseInternal(at: self.lastBeat)
                    self.onAutoPause?()
                }
            })
        #endif
    }
}

private extension Array where Element == PlaybackEvent {
    /// startBeat 昇順の配列で、述語が初めて真になる index(二分探索)。
    /// 返り値は「第2区画の先頭」— それより前は全て述語が偽。
    func lowerBound(_ belongsInSecondPartition: (PlaybackEvent) -> Bool) -> Int {
        var lo = 0, hi = count
        while lo < hi {
            let mid = (lo + hi) / 2
            if belongsInSecondPartition(self[mid]) { hi = mid } else { lo = mid + 1 }
        }
        return lo
    }
}
